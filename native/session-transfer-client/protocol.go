package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
)

// Wire protocol
// -------------
// stdin  (host -> client): exactly one configuration object on the first line.
//        When the host advertises auth_refresh, stdin stays OPEN afterwards and
//        may receive {"type":"auth_headers",...} lines at any time.
// stdout (client -> host): zero or more progress messages, then exactly one
//        terminal result object.
// stderr: ignored by the host.
//
// The host's validation rules (transfer-client.ts) that we must respect:
//   - Every stdout line must parse as a JSON object (not array/scalar).
//   - A message carrying a "type" field is either "refresh_auth" or "progress";
//     anything else is a protocol error.
//   - The terminal result must NOT carry a "type" field, and must carry a
//     boolean "success"; "retryable" is optional but must not be true when
//     success is true.
//   - progress.uploaded_bytes/total_bytes must be non-negative safe integers
//     with uploaded <= total.
//   - Total stdout volume must stay under 64 KiB, so progress is throttled.
//   - refresh_auth is only valid while the current generation matches the one
//     the host last sent, and only before a result has been emitted.

// Configuration is the first stdin line.
type Configuration struct {
	Direction        string             `json:"direction"` // "upload" | "download"
	LocalPath        string             `json:"local_path"`
	RemoteRoot       string             `json:"remote_root"`
	DataDirectory    string             `json:"data_directory"`
	SourceRevisionID string             `json:"source_revision_id"`
	ManifestHash     string             `json:"manifest_hash,omitempty"`
	Files            []SnapshotFile     `json:"files,omitempty"`
	Relay            RelayConfiguration `json:"relay"`
}

type SnapshotFile struct {
	RelativePath string `json:"relative_path"`
	SHA256       string `json:"sha256"`
	SizeBytes    int64  `json:"size_bytes"`
	Sensitive    bool   `json:"sensitive"`
}

type RelayConfiguration struct {
	EndpointURL string            `json:"endpoint_url"`
	AccessToken string            `json:"access_token"`
	Headers     map[string]string `json:"headers"`
	AuthRefresh bool              `json:"auth_refresh,omitempty"`
}

// Messages we emit.
type progressMessage struct {
	Type          string `json:"type"`
	UploadedBytes int64  `json:"uploaded_bytes"`
	TotalBytes    int64  `json:"total_bytes"`
}

type refreshAuthMessage struct {
	Type       string `json:"type"`
	Generation int    `json:"generation"`
}

// Terminal result. "type" must be absent so the host treats it as the result
// rather than a protocol error.
type resultMessage struct {
	Success   bool  `json:"success"`
	Retryable *bool `json:"retryable,omitempty"`
}

// Messages we receive on stdin after the configuration.
type authHeadersMessage struct {
	Type       string            `json:"type"`
	Generation int               `json:"generation"`
	Headers    map[string]string `json:"headers"`
}

// errWriter returns the process stderr. The host discards it, but keeping the
// writes in one place makes them easy to redirect in tests.
func errWriter() io.Writer { return os.Stderr }

// emitResult writes the terminal result line exactly once.
func emitResult(success, retryable bool) {
	msg := resultMessage{Success: success}
	// The host rejects `retryable: true` alongside `success: true`, so only
	// send the field when it is meaningful.
	if !success {
		r := retryable
		msg.Retryable = &r
	}
	writeJSONLine(os.Stdout, msg)
}

func writeJSONLine(w io.Writer, v any) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	data = append(data, '\n')
	_, _ = w.Write(data)
}

// readConfiguration consumes the first stdin line and decodes it.
func readConfiguration(r *bufio.Reader) (*Configuration, error) {
	line, err := readLine(r)
	if err != nil {
		return nil, fmt.Errorf("reading configuration: %w", err)
	}
	var cfg Configuration
	if err := json.Unmarshal([]byte(line), &cfg); err != nil {
		return nil, fmt.Errorf("configuration is not valid JSON: %w", err)
	}
	if cfg.Direction != "upload" && cfg.Direction != "download" {
		return nil, fmt.Errorf("transfer direction invalid: %q", cfg.Direction)
	}
	if cfg.Relay.EndpointURL == "" {
		return nil, errors.New("transfer control credentials missing")
	}
	return &cfg, nil
}

// readLine returns the next newline-terminated line. The host always terminates
// the configuration with a newline, so a final unterminated chunk is treated as
// EOF-with-partial-data rather than a valid line.
func readLine(r *bufio.Reader) (string, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		if errors.Is(err, io.EOF) && line != "" {
			return "", io.ErrUnexpectedEOF
		}
		return "", err
	}
	return line[:len(line)-1], nil
}

// parseInt64Safe mirrors the host's Number.isSafeInteger check.
func parseInt64Safe(v any) (int64, bool) {
	f, ok := v.(float64)
	if !ok {
		return 0, false
	}
	n := int64(f)
	if float64(n) != f {
		return 0, false
	}
	return n, true
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
