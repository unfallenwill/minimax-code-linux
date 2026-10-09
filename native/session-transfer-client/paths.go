package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// resolveSnapshotRoot validates the directory that an upload reads from.
// The host passes an approved snapshot root; refuse anything that is not an
// existing directory so we never silently upload the wrong tree.
func resolveSnapshotRoot(localPath string) (string, error) {
	if localPath == "" {
		return "", fmt.Errorf("unable to resolve snapshot roots")
	}
	abs, err := filepath.Abs(localPath)
	if err != nil {
		return "", fmt.Errorf("unable to resolve snapshot root: %w", err)
	}
	info, err := os.Stat(abs)
	if err != nil {
		return "", fmt.Errorf("unable to resolve snapshot root: %w", err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("unable to resolve snapshot root: %s is not a directory", abs)
	}
	return abs, nil
}

// resolveDownloadRoot validates the destination for a download. The parent
// must exist; the leaf may not (we publish into it atomically).
func resolveDownloadRoot(localPath string) (string, error) {
	if localPath == "" {
		return "", fmt.Errorf("unable to resolve download root")
	}
	abs, err := filepath.Abs(localPath)
	if err != nil {
		return "", fmt.Errorf("unable to resolve download root: %w", err)
	}
	parent := filepath.Dir(abs)
	info, err := os.Stat(parent)
	if err != nil {
		return "", fmt.Errorf("unable to prepare download root: %w", err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("unable to prepare download root: %s is not a directory", parent)
	}
	return abs, nil
}

func jsonUnmarshal(data []byte, v any) error { return json.Unmarshal(data, v) }
