package main

import (
	"archive/tar"
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
	"strings"
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

	// The bundle is streamed twice: once to hash it (the relay verifies
	// integrity), once to upload. Caching multi-hundred-MB sessions to disk is
	// wasteful, and local_path is already a stable on-disk snapshot.
	begin, err := beginUpload(ctx, control, cfg)
	if err != nil {
		return err
	}
	if begin.PartSize <= 0 {
		return fmt.Errorf("multipart part size invalid: %d", begin.PartSize)
	}

	plan, err := planFileParts(snapshotRoot, begin.PartSize)
	if err != nil {
		return err
	}
	total := plan.totalSize
	report(0, total)

	completed, err := reconcileUploadCheckpoint(cfg, plan)
	if err != nil {
		return err
	}

	if err := uploadParts(ctx, control, cfg, begin, plan, completed, report); err != nil {
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
	root      string
	partSize  int64
	parts     []filePartPlan
	totalSize int64
}

// planFileParts walks the snapshot deterministically and lays the resulting tar
// stream out into fixed-size parts. Byte offsets refer to the tar stream, so we
// build the header/size arithmetic without materialising it.
func planFileParts(root string, partSize int64) (*uploadPlan, error) {
	entries, err := collectSnapshotFiles(root)
	if err != nil {
		return nil, err
	}
	plan := &uploadPlan{root: root, partSize: partSize}

	offset := int64(0)
	// archive/tar writes exactly ONE 512-byte header block per entry, the
	// payload, then padding up to the next 512 boundary, and closes the stream
	// with two zero blocks. This must match archive/tar's real layout byte for
	// byte -- newTarStreamReader is verified against a real tar in the tests.
	const blockSize = 512
	const headerBlock = blockSize

	// appendRange lays [0,n) of logical stream space into parts, splitting
	// whenever a part boundary is crossed so parts tile the stream exactly.
	appendRange := func(n int64) {
		for n > 0 {
			withinPart := offset % partSize
			take := min64(n, partSize-withinPart)
			plan.parts = append(plan.parts, filePartPlan{
				partNumber: len(plan.parts) + 1,
				offset:     offset,
				size:       take,
			})
			offset += take
			n -= take
		}
	}

	for _, entry := range entries {
		appendRange(headerBlock) // per-file header block
		appendRange(entry.size)  // payload
		if pad := entry.size % blockSize; pad != 0 {
			appendRange(blockSize - pad) // padding to the next block
		}
	}
	appendRange(2 * blockSize) // end-of-archive marker

	plan.totalSize = offset
	return plan, nil
}

func collectSnapshotFiles(root string) ([]snapshotEntry, error) {
	var entries []snapshotEntry
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		// Never follow symlinks out of the snapshot root.
		if d.Type()&os.ModeSymlink != 0 {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if pathEscapesRoot(rel) {
			return fmt.Errorf("snapshot path escapes root: %s", rel)
		}
		entries = append(entries, snapshotEntry{absolute: path, relative: filepath.ToSlash(rel), size: info.Size()})
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("unable to resolve snapshot root: %w", err)
	}
	// Deterministic order keeps the tar (and therefore its hashes and part
	// boundaries) reproducible across runs.
	sort.Slice(entries, func(i, j int) bool { return entries[i].relative < entries[j].relative })
	return entries, nil
}

type snapshotEntry struct {
	absolute string
	relative string
	size     int64
}

func pathEscapesRoot(rel string) bool {
	return rel == ".." || strings.HasPrefix(rel, "../")
}

// tarStreamReader streams the snapshot as an uncompressed tar, and is seekable
// via ReadAt so parts can be read without buffering the whole bundle.
// tarStreamReader exposes the snapshot as a single uncompressed tar stream that
// can be read at arbitrary offsets.
//
// The bundle is materialised into an anonymous temp file rather than kept in
// memory: session snapshots are routinely hundreds of megabytes, and a
// seekable file is what lets each part be uploaded concurrently without holding
// the whole tar in RAM. The file is unlinked immediately, so it disappears even
// if the process is killed.
type tarStreamReader struct {
	entries []snapshotEntry
	offsets []int64 // tar-stream offset of each entry's payload
	starts  []int64 // tar-stream offset of each entry's header
	total   int64
	reader  io.ReaderAt
	path    string
}

func newTarStreamReader(root string, entries []snapshotEntry, total int64) (*tarStreamReader, error) {
	file, err := os.CreateTemp("", "mavis-session-transfer-*.tar")
	if err != nil {
		return nil, fmt.Errorf("unable to open multipart source: %w", err)
	}
	path := file.Name()
	// 0600: the bundle can contain sensitive session content.
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		os.Remove(path)
		return nil, fmt.Errorf("unable to secure multipart source: %w", err)
	}

	writer := tar.NewWriter(file)
	// tar.Writer exposes no position, so track it ourselves. archive/tar writes
	// exactly ONE 512-byte header block per entry (FormatPAX folds any extended
	// header into that block), then the payload padded to the next 512 boundary,
	// and closes with two zero blocks. planFileParts mirrors this arithmetic, so
	// the two must stay in lockstep or the bundle would not be a valid tar.
	const headerBlock = 512
	tracker := &countingWriter{w: writer}

	starts := make([]int64, 0, len(entries))
	offsets := make([]int64, 0, len(entries))
	for _, entry := range entries {
		starts = append(starts, tracker.n)
		offsets = append(offsets, tracker.n+headerBlock)
		if err := writeTarHeader(writer, entry); err != nil {
			file.Close()
			os.Remove(path)
			return nil, fmt.Errorf("unable to prepare bundle directory: %w", err)
		}
		source, err := os.Open(entry.absolute)
		if err != nil {
			file.Close()
			os.Remove(path)
			return nil, fmt.Errorf("unable to open snapshot file: %w", err)
		}
		copied, err := io.Copy(writer, source)
		source.Close()
		if err != nil {
			file.Close()
			os.Remove(path)
			return nil, fmt.Errorf("unable to hash multipart source: %w", err)
		}
		if copied != entry.size {
			file.Close()
			os.Remove(path)
			return nil, fmt.Errorf("snapshot changed while bundling: %s", entry.relative)
		}
	}
	if err := writer.Close(); err != nil {
		file.Close()
		os.Remove(path)
		return nil, fmt.Errorf("unable to close bundle: %w", err)
	}
	// Flush before any part is read back through ReadAt.
	if err := file.Sync(); err != nil {
		file.Close()
		os.Remove(path)
		return nil, fmt.Errorf("unable to close bundle: %w", err)
	}

	return &tarStreamReader{
		entries: entries,
		starts:  starts,
		offsets: offsets,
		total:   tracker.n,
		reader:  file,
		path:    path,
	}, nil
}

// countingWriter tracks the number of bytes written through it.
type countingWriter struct {
	w io.Writer
	n int64
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

func (t *tarStreamReader) Close() error {
	if t.path != "" {
		_ = os.Remove(t.path)
	}
	if c, ok := t.reader.(io.Closer); ok {
		return c.Close()
	}
	return nil
}

func (t *tarStreamReader) ReadAt(p []byte, off int64) (int, error) { return t.reader.ReadAt(p, off) }

// uploadParts walks the plan, asks the relay to sign the parts we still need,
// and PUTs them concurrently.
func uploadParts(
	ctx context.Context,
	control *transferControlClient,
	cfg *Configuration,
	begin *objectTransferBeginResponse,
	plan *uploadPlan,
	completed map[int]string,
	report uploadProgress,
) error {
	entries, err := collectSnapshotFiles(plan.root)
	if err != nil {
		return err
	}
	stream, err := newTarStreamReader(plan.root, entries, plan.totalSize)
	if err != nil {
		return err
	}
	defer stream.Close()

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
				defer mu.Unlock()
				if err != nil {
					if firstErr == nil {
						firstErr = err
					}
					return
				}
				completed[part.partNumber] = etag
				uploaded += part.size
				report(min64(uploaded, plan.totalSize), plan.totalSize)
			}()
			if firstErr != nil {
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
		CompletedParts   []completedPart `json:"completed_parts"`
	}{
		SourceRevisionID: cfg.SourceRevisionID,
		UploadID:         begin.UploadID,
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

	buffer := make([]byte, part.size)
	if _, err := stream.ReadAt(buffer, part.offset); err != nil && err != io.EOF {
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
// the same transfer, so an interrupted upload can resume.
func reconcileUploadCheckpoint(cfg *Configuration, plan *uploadPlan) (map[int]string, error) {
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
		Parts            []completedPart `json:"completed_parts"`
	}
	if err := json.Unmarshal(raw, &checkpoint); err != nil {
		return nil, fmt.Errorf("download checkpoint invalid: %w", err)
	}
	if checkpoint.SourceRevisionID != cfg.SourceRevisionID {
		// A checkpoint from a different snapshot is meaningless; start over.
		return completed, nil
	}
	for _, part := range checkpoint.Parts {
		if part.ETag != "" {
			completed[part.PartNumber] = part.ETag
		}
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

// writeTarHeader is retained for completeness: header construction is the
// default path used by createTarBundle in the darwin build.
func writeTarHeader(w *tar.Writer, entry snapshotEntry) error {
	header := &tar.Header{
		Name:     entry.relative,
		Mode:     0o600,
		Size:     entry.size,
		Typeflag: tar.TypeReg,
		Format:   tar.FormatPAX,
	}
	if err := w.WriteHeader(header); err != nil {
		return err
	}
	return nil
}
