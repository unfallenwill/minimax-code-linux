package main

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// buildTar renders the snapshot exactly the way newTarStreamReader describes it,
// so the byte-for-byte comparison in TestPartPlanMatchesRealTar is meaningful.
// It goes through the same writeTarHeader as the real bundle, so the two cannot
// diverge.
func buildTar(t *testing.T, root string, entries []snapshotEntry) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := tar.NewWriter(&buf)
	for _, entry := range entries {
		if err := writeTarHeader(w, entry); err != nil {
			t.Fatalf("header %s: %v", entry.relative, err)
		}
		data, err := os.ReadFile(entry.absolute)
		if err != nil {
			t.Fatalf("read %s: %v", entry.absolute, err)
		}
		if _, err := w.Write(data); err != nil {
			t.Fatalf("write %s: %v", entry.relative, err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	return buf.Bytes()
}

func makeSnapshot(t *testing.T, files map[string][]byte) string {
	t.Helper()
	root := t.TempDir()
	for name, data := range files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// The critical invariant: every part must be a contiguous, exact slice of the
// tar stream, and concatenating the parts must reproduce that stream byte for
// byte. The plan must be derived from the measured bundle size, not from
// header arithmetic -- see the long-filename regression below.
func TestPartPlanMatchesRealTar(t *testing.T) {
	root := makeSnapshot(t, map[string][]byte{
		"session/meta.json":     []byte(`{"v":1}`),
		"session/messages.json": bytes.Repeat([]byte("m"), 5000),
		"session/blob.bin":      bytes.Repeat([]byte("b"), 4096),
	})

	entries, err := collectSnapshotFiles(root)
	if err != nil {
		t.Fatalf("collect: %v", err)
	}
	realTar := buildTar(t, root, entries)

	for _, partSize := range []int64{512, 1024, 4096, 65536} {
		stream, err := newTarStreamReader(root, entries)
		if err != nil {
			t.Fatalf("stream(%d): %v", partSize, err)
		}
		if stream.total != int64(len(realTar)) {
			t.Fatalf("partSize=%d: bundle total=%d, real tar=%d", partSize, stream.total, len(realTar))
		}
		plan := planUploadParts(stream.total, partSize)
		if len(plan.parts) == 0 {
			t.Fatalf("partSize=%d: no parts", partSize)
		}
		// Parts must tile [0,total) exactly once, in order, no gaps/overlap.
		var cursor int64
		for i, part := range plan.parts {
			if part.partNumber != i+1 {
				t.Fatalf("partSize=%d: part %d numbered %d", partSize, i, part.partNumber)
			}
			if part.offset != cursor {
				t.Fatalf("partSize=%d: part %d offset=%d, want %d", partSize, part.partNumber, part.offset, cursor)
			}
			if part.size <= 0 {
				t.Fatalf("partSize=%d: part %d size=%d", partSize, part.partNumber, part.size)
			}
			if partSize > 0 && part.size > partSize {
				t.Fatalf("partSize=%d: part %d size=%d exceeds part size", partSize, part.partNumber, part.size)
			}
			cursor += part.size
		}
		if cursor != int64(len(realTar)) {
			t.Fatalf("partSize=%d: parts cover %d bytes, tar is %d", partSize, cursor, len(realTar))
		}

		// Re-read each part through the same ReaderAt path the uploader uses.
		var assembled bytes.Buffer
		for _, part := range plan.parts {
			buf := make([]byte, part.size)
			if err := readFullAt(stream, buf, part.offset); err != nil {
				t.Fatalf("read part %d: %v", part.partNumber, err)
			}
			assembled.Write(buf)
		}
		stream.Close()
		if !bytes.Equal(assembled.Bytes(), realTar) {
			t.Fatalf("partSize=%d: reassembled bundle differs from tar stream", partSize)
		}
	}
}

// Regression: archive/tar emits a PAX extended header sub-entry (an extra
// header block plus record payload) for names that do not fit the ustar
// 100-byte field. The old planner assumed one flat 512-byte header per entry,
// so every part boundary after such an entry was shifted and the uploaded
// bundle was silently corrupt. The plan must come from the measured stream.
func TestPlanHandlesPaxLongPath(t *testing.T) {
	longName := strings.Repeat("l", 150) + ".json"
	root := makeSnapshot(t, map[string][]byte{
		longName:            []byte("payload-of-the-long-file"),
		"session/meta.json": []byte(`{"v":1}`),
	})

	entries, err := collectSnapshotFiles(root)
	if err != nil {
		t.Fatalf("collect: %v", err)
	}
	realTar := buildTar(t, root, entries)

	stream, err := newTarStreamReader(root, entries)
	if err != nil {
		t.Fatalf("bundle: %v", err)
	}
	defer stream.Close()

	plan := planUploadParts(stream.total, 512)
	var assembled bytes.Buffer
	for _, part := range plan.parts {
		buf := make([]byte, part.size)
		if err := readFullAt(stream, buf, part.offset); err != nil {
			t.Fatalf("read part %d: %v", part.partNumber, err)
		}
		assembled.Write(buf)
	}
	if !bytes.Equal(assembled.Bytes(), realTar) {
		t.Fatalf("reassembled bundle differs from real tar (plan total=%d, tar=%d)", plan.totalSize, len(realTar))
	}
}

// A resumed upload must not re-send parts the checkpoint already recorded --
// and must discard checkpoints that do not describe this exact upload session.
func TestReconcileUploadCheckpoint(t *testing.T) {
	dir := t.TempDir()
	cfg := &Configuration{
		DataDirectory:    dir,
		SourceRevisionID: "rev-1",
	}
	plan := planUploadParts(4*512, 512)
	begin := &objectTransferBeginResponse{UploadID: "up-1", PartSize: 512}

	completed, err := reconcileUploadCheckpoint(cfg, begin, plan)
	if err != nil {
		t.Fatalf("fresh reconcile: %v", err)
	}
	if len(completed) != 0 {
		t.Fatalf("expected no completed parts, got %v", completed)
	}

	if err := writeUploadCheckpoint(cfg, begin, map[int]string{1: "\"etag-1\""}, plan); err != nil {
		t.Fatalf("write checkpoint: %v", err)
	}
	completed, err = reconcileUploadCheckpoint(cfg, begin, plan)
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if completed[1] != `"etag-1"` {
		t.Fatalf("part 1 not restored: %v", completed)
	}

	// A checkpoint from a different revision must be discarded outright.
	other := &Configuration{DataDirectory: dir, SourceRevisionID: "rev-2"}
	completed, err = reconcileUploadCheckpoint(other, begin, plan)
	if err != nil {
		t.Fatalf("reconcile other: %v", err)
	}
	if len(completed) != 0 {
		t.Fatalf("stale checkpoint was reused: %v", completed)
	}

	// Regression: multipart ETags are scoped to a specific upload_id, so a
	// checkpoint from a different begin must never be reused.
	otherBegin := &objectTransferBeginResponse{UploadID: "up-OTHER", PartSize: 512}
	completed, err = reconcileUploadCheckpoint(cfg, otherBegin, plan)
	if err != nil {
		t.Fatalf("reconcile other upload: %v", err)
	}
	if len(completed) != 0 {
		t.Fatalf("checkpoint with mismatched upload_id was reused: %v", completed)
	}

	// Regression: a checkpoint recorded with a different part_size describes
	// different byte ranges; reusing its parts would corrupt the object.
	otherPartSize := &objectTransferBeginResponse{UploadID: "up-1", PartSize: 1024}
	completed, err = reconcileUploadCheckpoint(cfg, otherPartSize, plan)
	if err != nil {
		t.Fatalf("reconcile other part size: %v", err)
	}
	if len(completed) != 0 {
		t.Fatalf("checkpoint with mismatched part_size was reused: %v", completed)
	}

	// Regression: part numbers outside the current plan are ignored rather
	// than carried into completion.
	if err := writeUploadCheckpoint(cfg, begin, map[int]string{1: "\"ok\"", 99: "\"stale\""}, plan); err != nil {
		t.Fatalf("write checkpoint: %v", err)
	}
	completed, err = reconcileUploadCheckpoint(cfg, begin, plan)
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if _, ok := completed[99]; ok {
		t.Fatalf("out-of-range part was restored: %v", completed)
	}
	if completed[1] != `"ok"` {
		t.Fatalf("valid part lost: %v", completed)
	}
}

// shortReadReader emulates a ReaderAt (or file) that returns fewer bytes than
// requested together with io.EOF -- the documented ReadAt contract for reads
// that run past the end of the data.
type shortReadReader struct {
	data    []byte
	maxStep int
}

func (r *shortReadReader) ReadAt(p []byte, off int64) (int, error) {
	if off >= int64(len(r.data)) {
		return 0, io.EOF
	}
	end := int64(len(r.data))
	if limit := off + int64(r.maxStep); limit < end {
		end = limit
	}
	n := copy(p, r.data[off:end])
	if off+int64(n) >= int64(len(r.data)) {
		return n, io.EOF
	}
	return n, nil
}

// Regression: uploadOnePart used to ignore short reads (err == io.EOF) and PUT
// the zero-padded buffer anyway. readFullAt must reject any shortfall.
func TestReadFullAtRejectsShortRead(t *testing.T) {
	r := &shortReadReader{data: []byte("only-eight-bytes"), maxStep: 3}
	buf := make([]byte, 16) // longer than the underlying data
	err := readFullAt(r, buf, 0)
	if err == nil {
		t.Fatal("short read was not rejected")
	}
	if !errors.Is(err, io.EOF) {
		t.Fatalf("error should wrap the underlying EOF: %v", err)
	}
	// A read that fits must succeed even with a stammering reader.
	small := make([]byte, 8)
	if err := readFullAt(r, small, 0); err != nil {
		t.Fatalf("in-range read failed: %v", err)
	}
	if string(small) != "only-eig" {
		t.Fatalf("wrong bytes: %q", small)
	}
}

// Integration through uploadOnePart: the bytes PUT to the object store must be
// exactly the planned slice of the tar stream, and a part whose planned range
// extends past the bundle must fail instead of uploading zero padding.
func TestUploadOnePartUploadsExactBytes(t *testing.T) {
	root := makeSnapshot(t, map[string][]byte{
		"session/blob.bin": bytes.Repeat([]byte("z"), 3000),
	})
	stream, err := newBundle(root)
	if err != nil {
		t.Fatalf("bundle: %v", err)
	}
	defer stream.Close()

	var mu sync.Mutex
	putBody := []byte{}
	var control *httptest.Server
	control = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/objects/sign":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"parts":[{"part_number":1,"url":%q}]}`, control.URL+"/put")
		case r.URL.Path == "/put":
			body, _ := io.ReadAll(r.Body)
			mu.Lock()
			putBody = body
			mu.Unlock()
			w.Header().Set("ETag", `"etag-1"`)
			w.WriteHeader(200)
		default:
			http.NotFound(w, r)
		}
	}))
	defer control.Close()

	cfg := &Configuration{Relay: RelayConfiguration{EndpointURL: control.URL}}
	client, err := newTransferControlClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	begin := &objectTransferBeginResponse{TransferID: "t-1", UploadID: "up-1", PartSize: 1024}

	part := filePartPlan{partNumber: 1, offset: 512, size: 1024}
	etag, err := uploadOnePart(context.Background(), client, cfg, begin, stream, part)
	if err != nil {
		t.Fatalf("uploadOnePart: %v", err)
	}
	if etag != `"etag-1"` {
		t.Fatalf("etag = %q", etag)
	}
	want := make([]byte, part.size)
	if err := readFullAt(stream, want, part.offset); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(putBody, want) {
		t.Fatalf("uploaded %d bytes, planned slice is %d bytes", len(putBody), len(want))
	}

	// A part reaching past the bundle must be rejected, not zero-filled.
	beyond := filePartPlan{partNumber: 2, offset: stream.total - 100, size: 1000}
	if _, err := uploadOnePart(context.Background(), client, cfg, begin, stream, beyond); err == nil {
		t.Fatal("out-of-bounds part was accepted")
	}
}

// Regression: the spawn loop read firstErr without holding the mutex while
// workers wrote it. With many parts and a control plane that rejects signing,
// uploadParts must fail cleanly (and stay race-free under -race).
func TestUploadPartsStopsOnFailure(t *testing.T) {
	root := makeSnapshot(t, map[string][]byte{
		"session/a.bin": bytes.Repeat([]byte("a"), 4096),
		"session/b.bin": bytes.Repeat([]byte("b"), 4096),
	})
	stream, err := newBundle(root)
	if err != nil {
		t.Fatalf("bundle: %v", err)
	}
	defer stream.Close()

	var calls int
	var mu sync.Mutex
	control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/objects/sign" {
			mu.Lock()
			calls++
			mu.Unlock()
			http.Error(w, "no sign for you", http.StatusBadRequest) // non-retryable
			return
		}
		http.NotFound(w, r)
	}))
	defer control.Close()

	cfg := &Configuration{Relay: RelayConfiguration{EndpointURL: control.URL}}
	client, err := newTransferControlClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	begin := &objectTransferBeginResponse{TransferID: "t-1", UploadID: "up-1", PartSize: 512}
	plan := planUploadParts(stream.total, 512)

	err = uploadParts(context.Background(), client, cfg, begin, stream, plan, map[int]string{}, func(uploaded, total int64) {})
	if err == nil {
		t.Fatal("uploadParts should fail when signing is rejected")
	}
	mu.Lock()
	defer mu.Unlock()
	if calls == 0 {
		t.Fatal("no sign attempts were made")
	}
}

// The host rejects any relative path that escapes the destination root.
func TestResolveWithinRootRejectsTraversal(t *testing.T) {
	root := t.TempDir()
	if _, err := resolveWithinRoot(root, "../escape"); err == nil {
		t.Fatal("expected traversal to be rejected")
	}
	if _, err := resolveWithinRoot(root, "nested/ok.json"); err != nil {
		t.Fatalf("expected nested path to be accepted: %v", err)
	}
}

// Progress must never go backwards or exceed the total, or the host aborts.
func TestProgressReporterIsMonotonic(t *testing.T) {
	r := newProgressReporter()
	r.throttle = 0
	r.report(0, 100)
	r.report(50, 100)
	r.report(20, 100) // regression: must be ignored
	if r.lastSent != 50 {
		t.Fatalf("regression was not suppressed: lastSent=%d", r.lastSent)
	}
	r.report(150, 100) // overflow: must be ignored
	if r.lastSent != 50 {
		t.Fatalf("overflow was not suppressed: lastSent=%d", r.lastSent)
	}
	r.report(100, 100)
	if r.lastSent != 100 {
		t.Fatalf("final progress not recorded: lastSent=%d", r.lastSent)
	}
}
