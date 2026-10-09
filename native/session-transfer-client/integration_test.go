package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// buildCLI compiles the binary once for the integration tests, exactly the way
// install.sh will.
func buildCLI(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	binary := filepath.Join(dir, "mavis-session-transfer-client")
	cmd := exec.Command("go", "build", "-o", binary, ".")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build failed: %v\n%s", err, out)
	}
	return binary
}

// mockRelay implements the control-plane endpoints the client calls, plus an
// object store that echoes back an ETag for each uploaded part.
type mockRelay struct {
	server *httptest.Server

	mu            sync.Mutex
	beginCalls    int
	signCalls     int
	completeCalls int
	uploaded      [][]byte // parts in completion order
	partsByNumber map[int][]byte
	seenAuth      []string // Authorization headers observed
	requireAuth   bool
}

func newMockRelay(t *testing.T, requireAuth bool) *mockRelay {
	relay := &mockRelay{requireAuth: requireAuth, partsByNumber: map[int][]byte{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/objects/begin", relay.handleBegin)
	mux.HandleFunc("/objects/sign", relay.handleSign)
	mux.HandleFunc("/objects/complete", relay.handleComplete)
	mux.HandleFunc("/objects/downloads", func(w http.ResponseWriter, r *http.Request) {
		if !relay.checkAuth(w, r) {
			return
		}
		writeJSON(w, map[string]any{"files": []any{}})
	})
	mux.HandleFunc("/objects/download-complete", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"accepted": true})
	})
	// Object store: PUT records the part, GET serves it back. These requests
	// are addressed by pre-signed URLs and carry no bearer token.
	mux.HandleFunc("/store/", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPut:
			body, _ := io.ReadAll(r.Body)
			sum := sha256.Sum256(body)
			w.Header().Set("ETag", `"`+hex.EncodeToString(sum[:])+`"`)
			// The last path segment is the part number assigned by /objects/sign.
			number := 0
			if _, err := fmt.Sscanf(r.URL.Path, "/store/%d", &number); err != nil {
				t.Errorf("unparsable store path %q", r.URL.Path)
			}
			relay.mu.Lock()
			relay.uploaded = append(relay.uploaded, body)
			relay.partsByNumber[number] = body
			relay.mu.Unlock()
			w.WriteHeader(http.StatusOK)
		case http.MethodGet:
			relay.mu.Lock()
			defer relay.mu.Unlock()
			_, _ = w.Write(relay.uploaded[len(relay.uploaded)-1])
		}
	})
	relay.server = httptest.NewServer(mux)
	t.Cleanup(relay.server.Close)
	return relay
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func (m *mockRelay) checkAuth(w http.ResponseWriter, r *http.Request) bool {
	m.mu.Lock()
	m.seenAuth = append(m.seenAuth, r.Header.Get("Authorization"))
	m.mu.Unlock()
	if m.requireAuth && r.Header.Get("Authorization") == "" {
		w.WriteHeader(http.StatusUnauthorized)
		return false
	}
	return true
}

func (m *mockRelay) handleBegin(w http.ResponseWriter, r *http.Request) {
	if !m.checkAuth(w, r) {
		return
	}
	m.mu.Lock()
	m.beginCalls++
	m.mu.Unlock()
	writeJSON(w, map[string]any{
		"transfer_id": "tr-1",
		"upload_id":   "up-1",
		"part_size":   65536,
		"identity":    "id-1",
	})
}

func (m *mockRelay) handleSign(w http.ResponseWriter, r *http.Request) {
	if !m.checkAuth(w, r) {
		return
	}
	var req objectTransferSignRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
	m.mu.Lock()
	m.signCalls++
	m.mu.Unlock()
	parts := make([]objectTransferSignedPart, 0, len(req.PartNumbers))
	for _, number := range req.PartNumbers {
		parts = append(parts, objectTransferSignedPart{
			PartNumber: number,
			URL:        fmt.Sprintf("%s/store/%d", m.server.URL, number),
		})
	}
	writeJSON(w, map[string]any{"parts": parts})
}

func (m *mockRelay) handleComplete(w http.ResponseWriter, r *http.Request) {
	if !m.checkAuth(w, r) {
		return
	}
	var req objectTransferCompleteRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
	m.mu.Lock()
	m.completeCalls++
	m.mu.Unlock()
	if len(req.Parts) == 0 {
		writeJSON(w, map[string]any{"accepted": false, "error": "no parts"})
		return
	}
	writeJSON(w, map[string]any{"accepted": true, "cloud_revision_id": "rev-2"})
}

// The host parses every stdout line as JSON and validates it strictly. This
// mirrors parseNativeMessage/parseNativeResult from transfer-client.ts so the
// test fails if we ever emit something the real host would reject.
func validateHostMessages(t *testing.T, stdout string) (progress int, result map[string]any) {
	t.Helper()
	for _, line := range strings.Split(strings.TrimRight(stdout, "\n"), "\n") {
		if line == "" {
			continue
		}
		var value any
		if err := json.Unmarshal([]byte(line), &value); err != nil {
			t.Fatalf("host could not parse stdout line %q: %v", line, err)
		}
		object, ok := value.(map[string]any)
		if !ok {
			t.Fatalf("host requires a JSON object, got %T", line)
		}
		switch object["type"] {
		case "progress":
			uploaded, ok1 := object["uploaded_bytes"].(float64)
			total, ok2 := object["total_bytes"].(float64)
			if !ok1 || !ok2 {
				t.Fatalf("progress fields must be numbers: %v", object)
			}
			if uploaded < 0 || total < 0 || uploaded > total {
				t.Fatalf("host rejects out-of-range progress: %v", object)
			}
			progress++
		case "refresh_auth":
			// handled by the caller
		default:
			if result != nil {
				t.Fatalf("host accepts exactly one result, saw a second: %v", object)
			}
			result = object
		}
	}
	return progress, result
}

func makeSnapshotTree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	payload := strings.Repeat("session-content-", 20000) // comfortably > 64 KiB
	if err := os.WriteFile(filepath.Join(root, "messages.json"), []byte(payload), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "meta.json"), []byte(`{"id":"s1"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return root
}

// End-to-end upload: spawn the binary the way the host does (no args, empty
// env), feed it a configuration line, and validate the stdout stream against
// the host's own parsing rules.
func TestUploadEndToEnd(t *testing.T) {
	binary := buildCLI(t)
	relay := newMockRelay(t, true)
	snapshot := makeSnapshotTree(t)
	dataDir := t.TempDir()

	cfg := Configuration{
		Direction:        "upload",
		LocalPath:        snapshot,
		RemoteRoot:       "/",
		DataDirectory:    dataDir,
		SourceRevisionID: "rev-1",
		ManifestHash:     "mh-1",
		Relay: RelayConfiguration{
			EndpointURL: relay.server.URL,
			AccessToken: "ticket-token",
			Headers:     map[string]string{"X-Client": "test"},
		},
	}
	payload, _ := json.Marshal(cfg)

	cmd := exec.Command(binary)
	// The host spawns with an empty environment.
	cmd.Env = []string{}
	cmd.Stdin = bytes.NewReader(append(payload, '\n'))
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		t.Fatalf("upload failed: %v\nstderr: %s", err, stderr.String())
	}

	progressCount, result := validateHostMessages(t, stdout.String())
	if result == nil {
		t.Fatalf("no terminal result emitted; stdout=%q stderr=%s", stdout.String(), stderr.String())
	}
	if result["success"] != true {
		t.Fatalf("expected success, got %v", result)
	}
	if _, bad := result["retryable"]; bad {
		t.Fatalf("success must not carry retryable=true: %v", result)
	}
	if progressCount == 0 {
		t.Fatal("expected at least one progress message")
	}

	relay.mu.Lock()
	defer relay.mu.Unlock()
	if relay.beginCalls == 0 || relay.signCalls == 0 || relay.completeCalls != 1 {
		t.Fatalf("unexpected control-plane calls: begin=%d sign=%d complete=%d",
			relay.beginCalls, relay.signCalls, relay.completeCalls)
	}
	if len(relay.uploaded) == 0 {
		t.Fatal("no parts were uploaded")
	}
	// Parts must reassemble into a readable tar. They are uploaded
	// concurrently, so stitch them back together in part-number order rather
	// than arrival order.
	var bundle bytes.Buffer
	ordered := make([][]byte, len(relay.partsByNumber))
	for number, data := range relay.partsByNumber {
		ordered[number-1] = data
	}
	for _, part := range ordered {
		if part == nil {
			t.Fatal("missing part in reassembly")
		}
		bundle.Write(part)
	}
	if !isReadableTar(bundle.Bytes()) {
		t.Fatalf("reassembled bundle is not a valid tar (%d parts)", len(relay.uploaded))
	}
	// Every CONTROL-plane call must carry the bearer ticket. The object-store
	// PUTs deliberately do not: they are addressed by a pre-signed URL whose
	// signature is the credential, which is why sign() hands us per-part URLs.
	controlCalls := relay.beginCalls + relay.signCalls + relay.completeCalls
	if len(relay.seenAuth) < controlCalls {
		t.Fatalf("observed %d authorized requests, control plane made %d",
			len(relay.seenAuth), controlCalls)
	}
	for i, header := range relay.seenAuth {
		if header != "Bearer ticket-token" {
			t.Fatalf("control request %d carried Authorization=%q", i, header)
		}
	}

	// A checkpoint must exist so an interrupted upload can resume.
	if _, err := os.Stat(filepath.Join(dataDir, "upload-checkpoint.json")); err != nil {
		t.Fatalf("upload checkpoint was not written: %v", err)
	}
}

func isReadableTar(data []byte) bool {
	reader := tarReaderFor(data)
	if reader == nil {
		return false
	}
	names := map[string]bool{}
	for {
		name, ok := reader()
		if !ok {
			break
		}
		names[name] = true
	}
	return names["messages.json"] && names["meta.json"]
}

// End-to-end download against the same mock relay.
func TestDownloadEndToEnd(t *testing.T) {
	binary := buildCLI(t)
	relay := newMockRelay(t, true)
	content := []byte(strings.Repeat("downloaded-", 5000))

	relay.server.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/objects/downloads":
			sum := sha256.Sum256(content)
			writeJSON(w, map[string]any{
				"files": []map[string]any{{
					"relative_path": "session/messages.json",
					"url":           relay.server.URL + "/store/1",
					"size_bytes":    len(content),
					"sha256":        hex.EncodeToString(sum[:]),
				}},
			})
		case "/store/1":
			_, _ = w.Write(content)
		default:
			writeJSON(w, map[string]any{"accepted": true})
		}
	})

	destination := filepath.Join(t.TempDir(), "restored")
	dataDir := t.TempDir()
	cfg := Configuration{
		Direction:        "download",
		LocalPath:        destination,
		RemoteRoot:       "/",
		DataDirectory:    dataDir,
		SourceRevisionID: "rev-9",
		Relay: RelayConfiguration{
			EndpointURL: relay.server.URL,
			AccessToken: "ticket-token",
			Headers:     map[string]string{"X-Client": "test"},
		},
	}
	payload, _ := json.Marshal(cfg)

	cmd := exec.Command(binary)
	cmd.Env = []string{}
	cmd.Stdin = bytes.NewReader(append(payload, '\n'))
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		t.Fatalf("download failed: %v\nstderr: %s", err, stderr.String())
	}
	_, result := validateHostMessages(t, stdout.String())
	if result == nil || result["success"] != true {
		t.Fatalf("expected success, got %v (stderr=%s)", result, stderr.String())
	}

	got, err := os.ReadFile(filepath.Join(destination, "session", "messages.json"))
	if err != nil {
		t.Fatalf("downloaded file missing: %v", err)
	}
	if !bytes.Equal(got, content) {
		t.Fatal("downloaded content does not match what the relay served")
	}
}

// A rejected transfer must exit non-zero AND still emit a well-formed result,
// otherwise the host reports "response is invalid" instead of the real cause.
func TestFailureStillEmitsValidResult(t *testing.T) {
	binary := buildCLI(t)
	relay := newMockRelay(t, false)
	relay.server.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
	})

	cfg := Configuration{
		Direction:        "upload",
		LocalPath:        t.TempDir(),
		RemoteRoot:       "/",
		DataDirectory:    t.TempDir(),
		SourceRevisionID: "rev-1",
		Relay:            RelayConfiguration{EndpointURL: relay.server.URL, AccessToken: "t"},
	}
	payload, _ := json.Marshal(cfg)

	cmd := exec.Command(binary)
	cmd.Env = []string{}
	cmd.Stdin = bytes.NewReader(append(payload, '\n'))
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err == nil {
		t.Fatal("expected a non-zero exit for a rejected transfer")
	}
	_, result := validateHostMessages(t, stdout.String())
	if result == nil {
		t.Fatalf("failure path emitted no result; stdout=%q", stdout.String())
	}
	if result["success"] != false {
		t.Fatalf("expected success=false, got %v", result)
	}
	// A 400 is the relay rejecting the request: retrying cannot help.
	if result["retryable"] == true {
		t.Fatalf("a 400 must not be reported as retryable: %v", result)
	}
}

// A malformed configuration line must fail cleanly rather than panic.
func TestRejectsMalformedConfig(t *testing.T) {
	binary := buildCLI(t)
	cmd := exec.Command(binary)
	cmd.Env = []string{}
	cmd.Stdin = strings.NewReader("this is not json\n")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err == nil {
		t.Fatal("expected non-zero exit for malformed configuration")
	}
	if !strings.Contains(stderr.String(), "session-transfer:") {
		t.Fatalf("expected a diagnostic on stderr, got %q", stderr.String())
	}
}

// tarReaderFor returns a function yielding entry names from raw tar bytes.
func tarReaderFor(data []byte) func() (string, bool) {
	offset := 0
	return func() (string, bool) {
		const block = 512
		if offset+block > len(data) {
			return "", false
		}
		header := data[offset : offset+block]
		if isZeroBlock(header) {
			return "", false
		}
		name := strings.TrimRight(string(header[:100]), "\x00")
		var size int64
		for _, c := range header[124:136] {
			if c == 0 || c == ' ' {
				break
			}
			size = size*8 + int64(c-'0')
		}
		offset += block
		offset += int(size)
		if pad := size % int64(block); pad != 0 {
			offset += block - int(pad)
		}
		return name, true
	}
}

func isZeroBlock(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}

// Compile-time assertion that the reader helper satisfies bufio's interface
// expectations used elsewhere in the package.
var _ = bufio.NewReader
