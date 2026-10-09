package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// runDownload fetches the plan from the relay, downloads every object to a
// staging area, verifies each file's sha256, and only then publishes it into
// local_path (atomic rename) so a failed transfer can never leave a partial
// session visible to the app.
//
// Mirrors oss_download.go in the darwin build: the plan arrives from
// /objects/downloads, files land via signed URLs, and /objects/download-complete
// acknowledges the result.

type objectTransferDownloadsResponse struct {
	Files               []objectTransferDownloadFile `json:"files"`
	PlanHash            string                       `json:"plan_hash"`
	VerifiedFilesDigest string                       `json:"verified_files_digest"`
}

type objectTransferDownloadFile struct {
	RelativePath string `json:"relative_path"`
	URL          string `json:"url"`
	SizeBytes    int64  `json:"size_bytes"`
	SHA256       string `json:"sha256"`
}

type objectTransferDownloadCompleteRequest struct {
	TransferID          string `json:"transfer_id"`
	VerifiedFilesDigest string `json:"verified_files_digest"`
}

func runDownload(ctx context.Context, cfg *Configuration, control *transferControlClient, report uploadProgress) error {
	plan, err := fetchDownloadPlan(ctx, control, cfg)
	if err != nil {
		return err
	}
	if len(plan.Files) == 0 {
		return fmt.Errorf("OSS bundle plan mismatch: plan contains no files")
	}

	total := int64(0)
	for _, f := range plan.Files {
		total += f.SizeBytes
	}
	report(0, total)

	destination, err := resolveDownloadRoot(cfg.LocalPath)
	if err != nil {
		return err
	}
	staging, err := os.MkdirTemp(filepath.Dir(destination), ".mavis-download-")
	if err != nil {
		return fmt.Errorf("unable to create download staging file: %w", err)
	}
	defer os.RemoveAll(staging)

	done := map[string]bool{}
	if err := restoreDownloadCheckpoint(cfg, staging, done); err != nil {
		return err
	}

	var downloaded int64
	for _, file := range plan.Files {
		if done[file.RelativePath] {
			downloaded += file.SizeBytes
			report(downloaded, total)
			continue
		}
		if err := downloadFile(ctx, file, staging); err != nil {
			return err
		}
		downloaded += file.SizeBytes
		report(downloaded, total)
	}

	digest, err := verifiedFilesDigest(plan.Files)
	if err != nil {
		return err
	}
	if err := publishDownload(staging, destination); err != nil {
		return fmt.Errorf("unable to publish download staging file: %w", err)
	}
	return acknowledgeDownload(ctx, control, cfg, digest)
}

func fetchDownloadPlan(ctx context.Context, control *transferControlClient, cfg *Configuration) (*objectTransferDownloadsResponse, error) {
	var resp objectTransferDownloadsResponse
	req := objectTransferBeginRequest{
		Direction:        cfg.Direction,
		RemoteRoot:       cfg.RemoteRoot,
		SourceRevisionID: cfg.SourceRevisionID,
	}
	err := withRetry(ctx, 4, func(ctx context.Context) error {
		return control.do(ctx, "/objects/downloads", req, &resp)
	})
	if err != nil {
		return nil, fmt.Errorf("unable to resolve download root: %w", err)
	}
	return &resp, nil
}

func downloadFile(ctx context.Context, file objectTransferDownloadFile, staging string) error {
	target, err := resolveWithinRoot(staging, file.RelativePath)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return fmt.Errorf("unable to prepare download directory: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, file.URL, nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 30 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		return retryableError("OSS file download failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &controlError{status: resp.StatusCode, body: "download rejected"}
	}

	// Download to a temporary name and only rename after the digest matches,
	// so an interrupted transfer never leaves a corrupt file behind.
	tmp := target + ".partial"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("unable to create download staging file: %w", err)
	}
	hasher := sha256.New()
	written, err := io.Copy(io.MultiWriter(out, hasher), resp.Body)
	if closeErr := out.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		os.Remove(tmp)
		return fmt.Errorf("OSS file download failed: %w", err)
	}
	if file.SHA256 != "" {
		if got := hex.EncodeToString(hasher.Sum(nil)); got != file.SHA256 {
			os.Remove(tmp)
			return fmt.Errorf("OSS downloaded file verification failed: %s", file.RelativePath)
		}
	}
	if file.SizeBytes > 0 && written != file.SizeBytes {
		os.Remove(tmp)
		return fmt.Errorf("OSS downloaded file verification failed: %s", file.RelativePath)
	}
	if err := os.Rename(tmp, target); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func verifiedFilesDigest(files []objectTransferDownloadFile) (string, error) {
	hasher := sha256.New()
	for _, f := range files {
		// Length-prefix each field so concatenations cannot collide.
		fmt.Fprintf(hasher, "%d:%s%d:%s", len(f.RelativePath), f.RelativePath, len(f.SHA256), f.SHA256)
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func acknowledgeDownload(ctx context.Context, control *transferControlClient, cfg *Configuration, digest string) error {
	var resp objectTransferCompleteResponse
	req := objectTransferDownloadCompleteRequest{
		TransferID:          cfg.SourceRevisionID,
		VerifiedFilesDigest: digest,
	}
	err := withRetry(ctx, 4, func(ctx context.Context) error {
		return control.do(ctx, "/objects/download-complete", req, &resp)
	})
	if err != nil {
		return fmt.Errorf("unable to write download checkpoint: %w", err)
	}
	return nil
}

// resolveWithinRoot joins rel onto root, refusing anything that escapes it.
func resolveWithinRoot(root, rel string) (string, error) {
	clean := filepath.Clean(filepath.Join(root, filepath.FromSlash(rel)))
	if clean != root && !hasPathPrefix(clean, root) {
		return "", fmt.Errorf("snapshot path escapes root: %s", rel)
	}
	return clean, nil
}

func hasPathPrefix(path, root string) bool {
	return len(path) > len(root) && path[:len(root)] == root
}

func publishDownload(staging, destination string) error {
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		return err
	}
	if err := os.RemoveAll(destination); err != nil {
		return err
	}
	return os.Rename(staging, destination)
}

func restoreDownloadCheckpoint(cfg *Configuration, staging string, done map[string]bool) error {
	raw, err := os.ReadFile(downloadCheckpointPath(cfg))
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("unable to read download checkpoint: %w", err)
	}
	var checkpoint struct {
		SourceRevisionID string   `json:"source_revision_id"`
		Files            []string `json:"files"`
	}
	if err := json.Unmarshal(raw, &checkpoint); err != nil {
		return fmt.Errorf("download checkpoint invalid: %w", err)
	}
	if checkpoint.SourceRevisionID != cfg.SourceRevisionID {
		return nil
	}
	for _, name := range checkpoint.Files {
		done[name] = true
	}
	return nil
}
