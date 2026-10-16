package main

import (
	"archive/tar"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Bundle construction
// -------------------
// Everything about turning a snapshot directory into the exact tar byte stream
// that gets uploaded lives here. The plan in upload.go derives its part
// boundaries from the *measured* size of this stream (tarStreamReader.total),
// never from its own header arithmetic: archive/tar may emit extra blocks per
// entry (PAX/GNU extended headers for long or non-ASCII paths), so any
// arithmetic duplicated here is guaranteed to drift eventually. See the
// long-filename regression test in upload_test.go.

type snapshotEntry struct {
	absolute string
	relative string
	size     int64
}

func pathEscapesRoot(rel string) bool {
	return rel == ".." || strings.HasPrefix(rel, "../")
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

// newBundle materialises the snapshot as a seekable tar bundle in one walk.
// The returned reader exposes the finished stream; its total size is the
// authoritative byte length that part planning must tile.
func newBundle(root string) (*tarStreamReader, error) {
	entries, err := collectSnapshotFiles(root)
	if err != nil {
		return nil, err
	}
	return newTarStreamReader(root, entries)
}

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

func newTarStreamReader(root string, entries []snapshotEntry) (*tarStreamReader, error) {
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
	// Unlink immediately: the open fd stays readable on Linux, and the file
	// now disappears even if the process is killed, so Kill can never leave
	// session content on disk. Later os.Remove calls in the error paths below
	// become harmless no-ops.
	if err := os.Remove(path); err != nil {
		file.Close()
		return nil, fmt.Errorf("unable to unlink multipart source: %w", err)
	}

	// tar.Writer exposes no position, so track it ourselves: the counter sits
	// between the tar writer and the file so every byte the tar emits is
	// measured. total is measured, never predicted: with FormatPAX an entry
	// whose name needs PAX records is written as an extended header sub-entry
	// PLUS the real header, so the "one 512-byte block per entry" shortcut
	// under-counts long paths.
	tracker := &countingWriter{w: file}
	writer := tar.NewWriter(tracker)

	starts := make([]int64, 0, len(entries))
	offsets := make([]int64, 0, len(entries))
	for _, entry := range entries {
		starts = append(starts, tracker.n)
		if err := writeTarHeader(writer, entry); err != nil {
			file.Close()
			os.Remove(path)
			return nil, fmt.Errorf("unable to prepare bundle directory: %w", err)
		}
		// payloadStart is measured after WriteHeader so PAX sub-entries are
		// accounted for; starts[i]+512 would be wrong for such entries.
		offsets = append(offsets, tracker.n)
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

// writeTarHeader is the single header-construction path; both the real bundle
// and the test helper buildTar go through it so they cannot diverge.
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
