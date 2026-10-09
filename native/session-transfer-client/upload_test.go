package main

import (
	"archive/tar"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// buildTar renders the snapshot exactly the way newTarStreamReader describes it,
// so the byte-for-byte comparison in TestPartPlanMatchesRealTar is meaningful.
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
// byte. If the arithmetic in planFileParts drifts from archive/tar's layout,
// uploaded sessions would be silently corrupt.
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

	// Exercise several part sizes, including ones that split mid-file.
	for _, partSize := range []int64{512, 1024, 4096, 65536} {
		plan, err := planFileParts(root, partSize)
		if err != nil {
			t.Fatalf("plan(%d): %v", partSize, err)
		}
		if plan.totalSize != int64(len(realTar)) {
			t.Fatalf("partSize=%d: totalSize=%d, want %d", partSize, plan.totalSize, len(realTar))
		}
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
		stream, err := newTarStreamReader(root, entries, plan.totalSize)
		if err != nil {
			t.Fatalf("stream(%d): %v", partSize, err)
		}
		var assembled bytes.Buffer
		for _, part := range plan.parts {
			buf := make([]byte, part.size)
			if _, err := stream.ReadAt(buf, part.offset); err != nil && err != io.EOF {
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

// A resumed upload must not re-send parts the checkpoint already recorded.
func TestReconcileUploadCheckpoint(t *testing.T) {
	dir := t.TempDir()
	cfg := &Configuration{
		DataDirectory:    dir,
		SourceRevisionID: "rev-1",
	}
	plan := &uploadPlan{parts: []filePartPlan{{partNumber: 1}, {partNumber: 2}}}

	completed, err := reconcileUploadCheckpoint(cfg, plan)
	if err != nil {
		t.Fatalf("fresh reconcile: %v", err)
	}
	if len(completed) != 0 {
		t.Fatalf("expected no completed parts, got %v", completed)
	}

	begin := &objectTransferBeginResponse{UploadID: "up-1"}
	if err := writeUploadCheckpoint(cfg, begin, map[int]string{1: "\"etag-1\""}, plan); err != nil {
		t.Fatalf("write checkpoint: %v", err)
	}
	completed, err = reconcileUploadCheckpoint(cfg, plan)
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if completed[1] != `"etag-1"` {
		t.Fatalf("part 1 not restored: %v", completed)
	}

	// A checkpoint from a different revision must be discarded outright.
	other := &Configuration{DataDirectory: dir, SourceRevisionID: "rev-2"}
	completed, err = reconcileUploadCheckpoint(other, plan)
	if err != nil {
		t.Fatalf("reconcile other: %v", err)
	}
	if len(completed) != 0 {
		t.Fatalf("stale checkpoint was reused: %v", completed)
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
