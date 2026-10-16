package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// uploadBundle streams the snapshot at local_path as an uncompressed tar and
// uploads it to the relay-signed object in PartSize chunks.
//
// The flow mirrors the darwin binary's oss_upload.go / multipart.go:
//  1. POST /objects/begin   -> upload_id, part_size, part_count
//  2. POST /objects/sign    -> signed URLs for the parts that are still missing
//  3. PUT each part          -> collect the ETag returned by the object store
//  4. POST /objects/complete-> hand the part list back to the relay

type uploadProgress func(uploaded, total int64)

func runUpload(ctx context.Context, cfg *Configuration, control *transferControlClient, report uploadProgress) error {
	snapshotRoot, err := resolveSnapshotRoot(cfg.LocalPath)
	if err != nil {
		return err
	}

	begin, err := beginUpload(ctx, control, cfg)
	if err != nil {
		return err
	}
	if begin.PartSize <= 0 {
		return fmt.Errorf("multipart part size invalid: %d", begin.PartSize)
	}

	// Build the bundle ONCE and derive the part layout from the measured byte
	// length of the finished stream. Planning the parts from a separate walk
	// plus header arithmetic used to disagree with archive/tar whenever an
	// entry needed PAX extended headers (long or non-ASCII paths), which
	// silently corrupted every part boundary after that entry.
	stream, err := newBundle(snapshotRoot)
	if err != nil {
		return err
	}
	defer stream.Close()

	plan := planUploadParts(stream.total, begin.PartSize)
	total := plan.totalSize
	report(0, total)

	completed, err := reconcileUploadCheckpoint(cfg, begin, plan)
	if err != nil {
		return err
	}

	if err := uploadParts(ctx, control, cfg, begin, stream, plan, completed, report); err != nil {
		return err
	}

	return completeUpload(ctx, control, cfg, begin, plan, completed)
}

func beginUpload(ctx context.Context, control *transferControlClient, cfg *Configuration) (*objectTransferBeginResponse, error) {
	var resp objectTransferBeginResponse
	req := objectTransferBeginRequest{
		Direction:        cfg.Direction,
		RemoteRoot:       cfg.RemoteRoot,
		SourceRevisionID: cfg.SourceRevisionID,
		ManifestHash:     cfg.ManifestHash,
		Files:            cfg.Files,
	}
	err := withRetry(ctx, 4, func(ctx context.Context) error {
		return control.do(ctx, "/objects/begin", req, &resp)
	})
	if err != nil {
		return nil, fmt.Errorf("unable to create OSS upload request: %w", err)
	}
	return &resp, nil
}

// filePartPlan describes one contiguous slice of the concatenated tar stream.
type filePartPlan struct {
	partNumber int
	offset     int64
	size       int64
	sha256     string
}

type uploadPlan struct {
	partSize  int64
	parts     []filePartPlan
	totalSize int64
}

// planUploadParts tiles the tar stream [0,totalSize) into contiguous, evenly
// bounded parts that cover it exactly once. It deliberately knows nothing
// about tar internals: the caller must pass the measured size of the real
// bundle (tarStreamReader.total), so part boundaries always match the bytes
// that are actually uploaded.
func planUploadParts(totalSize, partSize int64) *uploadPlan {
	plan := &uploadPlan{partSize: partSize, totalSize: totalSize}
	offset := int64(0)
	for offset < totalSize {
		take := min64(partSize, totalSize-offset)
		plan.parts = append(plan.parts, filePartPlan{
			partNumber: len(plan.parts) + 1,
			offset:     offset,
			size:       take,
		})
		offset += take
	}
	return plan
}

// uploadParts walks the plan, asks the relay to sign the parts we still need,
// and PUTs them concurrently. The stream must be the same bundle whose measured
// size produced the plan; parts are read from it at their planned offsets.
func uploadParts(
	ctx context.Context,
	control *transferControlClient,
	cfg *Configuration,
	begin *objectTransferBeginResponse,
	stream *tarStreamReader,
	plan *uploadPlan,
	completed map[int]string,
	report uploadProgress,
) error {
	byNumber := make(map[int]filePartPlan, len(plan.parts))
	var pending []filePartPlan
	for _, part := range plan.parts {
		byNumber[part.partNumber] = part
		if _, done := completed[part.partNumber]; done {
			continue
		}
		pending = append(pending, part)
	}

	// Resume accounting: bytes already accepted by a previous attempt.
	var uploaded int64
	for _, part := range plan.parts {
		if _, done := completed[part.partNumber]; done {
			uploaded += part.size
		}
	}
	report(uploaded, plan.totalSize)

	if len(pending) > 0 {
		const maxConcurrency = 4
		sem := make(chan struct{}, maxConcurrency)
		var (
			mu       sync.Mutex
			firstErr error
			wg       sync.WaitGroup
		)
		for _, part := range pending {
			part := part
			wg.Add(1)
			sem <- struct{}{}
			go func() {
				defer wg.Done()
				defer func() { <-sem }()
				etag, err := uploadOnePart(ctx, control, cfg, begin, stream, part)
				mu.Lock()
				if err != nil {
					if firstErr == nil {
						firstErr = err
					}
					mu.Unlock()
					return
				}
				completed[part.partNumber] = etag
				uploaded += part.size
				report(min64(uploaded, plan.totalSize), plan.totalSize)
				mu.Unlock()
			}()
			// firstErr is written by the workers under mu; the spawn loop must
			// read it under the same lock (previously this was a data race).
			mu.Lock()
			err := firstErr
			mu.Unlock()
			if err != nil {
				break
			}
		}
		wg.Wait()
		if firstErr != nil {
			return firstErr
		}
	}

	// Persist the checkpoint so an interrupted upload can resume.
	if err := writeUploadCheckpoint(cfg, begin, completed, plan); err != nil {
		return err
	}
	report(plan.totalSize, plan.totalSize)
	return nil
}

func writeUploadCheckpoint(cfg *Configuration, begin *objectTransferBeginResponse, completed map[int]string, plan *uploadPlan) error {
	parts := make([]completedPart, 0, len(completed))
	for number, etag := range completed {
		parts = append(parts, completedPart{PartNumber: number, ETag: etag})
	}
	// Stable ordering keeps the checkpoint diffable between attempts.
	sort.Slice(parts, func(i, j int) bool { return parts[i].PartNumber < parts[j].PartNumber })
	payload, err := json.Marshal(struct {
		SourceRevisionID string          `json:"source_revision_id"`
		UploadID         string          `json:"upload_id"`
		PartSize         int64           `json:"part_size"`
		CompletedParts   []completedPart `json:"completed_parts"`
	}{
		SourceRevisionID: cfg.SourceRevisionID,
		UploadID:         begin.UploadID,
		PartSize:         begin.PartSize,
		CompletedParts:   parts,
	})
	if err != nil {
		return fmt.Errorf("unable to encode upload checkpoint: %w", err)
	}
	path := uploadCheckpointPath(cfg)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, payload, 0o600); err != nil {
		return fmt.Errorf("unable to create upload checkpoint: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("unable to publish upload checkpoint: %w", err)
	}
	return nil
}

func uploadOnePart(
	ctx context.Context,
	control *transferControlClient,
	cfg *Configuration,
	begin *objectTransferBeginResponse,
	stream *tarStreamReader,
	part filePartPlan,
) (string, error) {
	var signed objectTransferSignResponse
	signReq := objectTransferSignRequest{
		TransferID:  begin.TransferID,
		UploadID:    begin.UploadID,
		PartNumbers: []int{part.partNumber},
	}
	err := withRetry(ctx, 4, func(ctx context.Context) error {
		return control.do(ctx, "/objects/sign", signReq, &signed)
	})
	if err != nil {
		return "", fmt.Errorf("unable to create OSS upload request: %w", err)
	}
	if len(signed.Parts) == 0 {
		return "", fmt.Errorf("OSS signed part plan invalid: part %d", part.partNumber)
	}
	target := signed.Parts[0]

	// ReadAt may legally return a short read together with io.EOF; uploading
	// such a buffer would ship zero-filled tail bytes to the object store, so
	// loop until the planned slice is fully read and fail on any shortfall.
	buffer := make([]byte, part.size)
	if err := readFullAt(stream, buffer, part.offset); err != nil {
		return "", fmt.Errorf("unable to hash multipart source: %w", err)
	}

	client := &http.Client{Timeout: 10 * time.Minute}
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, target.URL, bytes.NewReader(buffer))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Content-Length", itoa(part.size))
	for k, v := range target.Headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", retryableError("OSS part upload failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, resp.Body)
		return "", &controlError{status: resp.StatusCode, body: "part upload rejected"}
	}
	etag := resp.Header.Get("ETag")
	if etag == "" {
		// Some gateways only expose it in the JSON body; fall back to hashing.
		sum := sha256.Sum256(buffer)
		etag = `"` + hex.EncodeToString(sum[:]) + `"`
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	return etag, nil
}

func completeUpload(ctx context.Context, control *transferControlClient, cfg *Configuration, begin *objectTransferBeginResponse, plan *uploadPlan, completed map[int]string) error {
	parts := make([]completedPart, 0, len(plan.parts))
	for _, part := range plan.parts {
		etag, ok := completed[part.partNumber]
		if !ok {
			return fmt.Errorf("multipart upload incomplete: part %d missing", part.partNumber)
		}
		parts = append(parts, completedPart{PartNumber: part.partNumber, ETag: etag})
	}

	var resp objectTransferCompleteResponse
	req := objectTransferCompleteRequest{
		TransferID: begin.TransferID,
		UploadID:   begin.UploadID,
		Parts:      parts,
	}
	err := withRetry(ctx, 4, func(ctx context.Context) error {
		return control.do(ctx, "/objects/complete", req, &resp)
	})
	if err != nil {
		return fmt.Errorf("unable to publish upload checkpoint: %w", err)
	}
	if !resp.Accepted {
		return fmt.Errorf("transfer control rejected completion: %s", resp.Error)
	}
	return nil
}

// reconcileUploadCheckpoint re-uses parts already accepted by a previous run of
// the same transfer, so an interrupted upload can resume. The checkpoint is
// only trusted when it matches the current session exactly: multipart ETags
// are scoped to a specific upload_id, and part boundaries only line up when
// part_size is unchanged. Anything else starts over.
func reconcileUploadCheckpoint(cfg *Configuration, begin *objectTransferBeginResponse, plan *uploadPlan) (map[int]string, error) {
	completed := map[int]string{}
	raw, err := os.ReadFile(uploadCheckpointPath(cfg))
	if err != nil {
		if os.IsNotExist(err) {
			return completed, nil
		}
		return nil, fmt.Errorf("unable to read upload checkpoint: %w", err)
	}
	var checkpoint struct {
		SourceRevisionID string          `json:"source_revision_id"`
		UploadID         string          `json:"upload_id"`
		PartSize         int64           `json:"part_size"`
		Parts            []completedPart `json:"completed_parts"`
	}
	if err := json.Unmarshal(raw, &checkpoint); err != nil {
		return nil, fmt.Errorf("upload checkpoint invalid: %w", err)
	}
	if checkpoint.SourceRevisionID != cfg.SourceRevisionID ||
		checkpoint.UploadID != begin.UploadID ||
		checkpoint.PartSize != begin.PartSize {
		// A checkpoint from a different snapshot, upload session, or part
		// layout is meaningless; start over.
		return completed, nil
	}
	for _, part := range checkpoint.Parts {
		if part.ETag == "" {
			continue
		}
		// Ignore part numbers that no longer exist in the plan rather than
		// carrying them into completion.
		if part.PartNumber < 1 || part.PartNumber > len(plan.parts) {
			continue
		}
		completed[part.PartNumber] = part.ETag
	}
	return completed, nil
}

func uploadCheckpointPath(cfg *Configuration) string {
	return filepath.Join(cfg.DataDirectory, "upload-checkpoint.json")
}

func downloadCheckpointPath(cfg *Configuration) string {
	return filepath.Join(cfg.DataDirectory, "download-checkpoint.json")
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

// readFullAt fills buf completely from r starting at off. Unlike a bare
// ReadAt, it treats short reads (even with io.EOF) as an error: a part that is
// not fully covered by real file bytes must never be uploaded.
func readFullAt(r io.ReaderAt, buf []byte, off int64) error {
	read := 0
	for read < len(buf) {
		n, err := r.ReadAt(buf[read:], off+int64(read))
		read += n
		if n == 0 && err == nil {
			return fmt.Errorf("short read at offset %d: got %d of %d bytes: %w", off, read, len(buf), io.ErrNoProgress)
		}
		if err != nil {
			return fmt.Errorf("short read at offset %d: got %d of %d bytes: %w", off, read, len(buf), err)
		}
	}
	return nil
}
