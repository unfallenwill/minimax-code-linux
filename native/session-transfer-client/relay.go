package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// transferControlClient speaks the relay "control plane" discovered from the
// darwin binary:
//
//	POST {endpoint}/objects/begin            -> {upload_id, part_size, part_count, ...}
//	POST {endpoint}/objects/sign             -> signed upload/download URLs per part
//	POST {endpoint}/objects/complete         -> finalises an upload
//	POST {endpoint}/objects/downloads        -> the download plan (files + urls)
//	POST {endpoint}/objects/download-complete -> acknowledges a finished download
//
// Control requests carry the host-supplied headers plus a bearer access token.
type transferControlClient struct {
	endpoint    string
	headers     map[string]string
	accessToken string
	http        *http.Client

	// headerMu guards headers, which the auth-refresh callback may replace
	// while requests are in flight.
	headerMu sync.RWMutex
}

type objectTransferBeginRequest struct {
	Direction        string         `json:"direction"`
	RemoteRoot       string         `json:"remote_root"`
	SourceRevisionID string         `json:"source_revision_id"`
	ManifestHash     string         `json:"manifest_hash,omitempty"`
	Files            []SnapshotFile `json:"files,omitempty"`
}

type objectTransferBeginResponse struct {
	TransferID      string `json:"transfer_id"`
	UploadID        string `json:"upload_id"`
	PartSize        int64  `json:"part_size"`
	PartCount       int    `json:"part_count"`
	Identity        string `json:"identity"`
	BaseRevisionID  string `json:"base_revision_id,omitempty"`
	CloudRevisionID string `json:"cloud_revision_id,omitempty"`
}

type objectTransferSignRequest struct {
	TransferID  string `json:"transfer_id"`
	UploadID    string `json:"upload_id,omitempty"`
	PartNumbers []int  `json:"part_numbers,omitempty"`
}

type objectTransferSignResponse struct {
	Parts []objectTransferSignedPart `json:"parts"`
}

type objectTransferSignedPart struct {
	PartNumber int               `json:"part_number"`
	URL        string            `json:"url"`
	Headers    map[string]string `json:"headers,omitempty"`
}

type objectTransferCompleteRequest struct {
	TransferID string          `json:"transfer_id"`
	UploadID   string          `json:"upload_id"`
	Parts      []completedPart `json:"parts"`
}

type completedPart struct {
	PartNumber int    `json:"part_number"`
	ETag       string `json:"etag"`
}

type objectTransferCompleteResponse struct {
	Accepted        bool   `json:"accepted"`
	CloudRevisionID string `json:"cloud_revision_id,omitempty"`
	Error           string `json:"error,omitempty"`
}

func newTransferControlClient(cfg *Configuration) (*transferControlClient, error) {
	endpoint, err := normaliseEndpoint(cfg.Relay.EndpointURL)
	if err != nil {
		return nil, err
	}
	headers := make(map[string]string, len(cfg.Relay.Headers))
	for k, v := range cfg.Relay.Headers {
		headers[k] = v
	}
	return &transferControlClient{
		endpoint:    endpoint,
		headers:     headers,
		accessToken: cfg.Relay.AccessToken,
		http: &http.Client{
			Timeout: 60 * time.Second,
			Transport: &http.Transport{
				MaxIdleConnsPerHost: 8,
				IdleConnTimeout:     90 * time.Second,
			},
		},
	}, nil
}

// normaliseEndpoint strips any trailing slash and validates the scheme so a
// malformed ticket fails fast instead of producing a confusing HTTP error.
func normaliseEndpoint(raw string) (string, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", fmt.Errorf("transfer control endpoint invalid: %q", raw)
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", fmt.Errorf("unsupported endpoint scheme: %q", parsed.Scheme)
	}
	return strings.TrimRight(raw, "/"), nil
}

// setHeaders replaces the credential headers (used by the auth-refresh path).
func (c *transferControlClient) setHeaders(headers map[string]string) {
	c.headerMu.Lock()
	defer c.headerMu.Unlock()
	c.headers = make(map[string]string, len(headers))
	for k, v := range headers {
		c.headers[k] = v
	}
}

func (c *transferControlClient) snapshotHeaders() map[string]string {
	c.headerMu.RLock()
	defer c.headerMu.RUnlock()
	out := make(map[string]string, len(c.headers)+1)
	for k, v := range c.headers {
		out[k] = v
	}
	if c.accessToken != "" {
		out["Authorization"] = "Bearer " + c.accessToken
	}
	return out
}

// do performs one control-plane request and decodes the JSON response.
func (c *transferControlClient) do(ctx context.Context, path string, req, resp any) error {
	body, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("transfer control request encoding failed: %w", err)
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint+path, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("transfer control request creation failed: %w", err)
	}
	for k, v := range c.snapshotHeaders() {
		httpReq.Header.Set(k, v)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")

	httpResp, err := c.http.Do(httpReq)
	if err != nil {
		return retryableError("transfer control request failed: %w", err)
	}
	defer httpResp.Body.Close()

	payload, err := io.ReadAll(httpResp.Body)
	if err != nil {
		return retryableError("transfer control request failed: %w", err)
	}
	if httpResp.StatusCode < 200 || httpResp.StatusCode >= 300 {
		return &controlError{status: httpResp.StatusCode, body: trimForError(payload)}
	}
	if resp == nil {
		return nil
	}
	if err := json.Unmarshal(payload, resp); err != nil {
		return fmt.Errorf("transfer control response is invalid: %w", err)
	}
	return nil
}

// controlError distinguishes relay-side rejections (non-retryable as a rule)
// from transport hiccups, which the caller retries.
type controlError struct {
	status int
	body   string
}

func (e *controlError) Error() string {
	return fmt.Sprintf("transfer control HTTP %d: %s", e.status, e.body)
}

func (e *controlError) retryable() bool {
	// 408/429 and all 5xx are worth another attempt; other 4xx mean the
	// ticket or request is wrong and retrying cannot help.
	return e.status == http.StatusRequestTimeout ||
		e.status == http.StatusTooManyRequests ||
		e.status >= 500
}

func trimForError(b []byte) string {
	const limit = 200
	s := strings.TrimSpace(string(b))
	if len(s) > limit {
		return s[:limit] + "..."
	}
	return s
}

func isRetryableError(err error) bool {
	var ce *controlError
	if errorsAs(err, &ce) {
		return ce.retryable()
	}
	return false
}

// errorsAs is a tiny stand-in for errors.As to keep the import list short.
func errorsAs(err error, target **controlError) bool {
	for err != nil {
		if ce, ok := err.(*controlError); ok {
			*target = ce
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

// retryableError wraps a transport failure so the run loop retries it.
func retryableError(format string, args ...any) error {
	return fmt.Errorf(format, args...)
}

// withRetry runs fn, retrying transport/5xx failures with a short backoff.
func withRetry(ctx context.Context, attempts int, fn func(context.Context) error) error {
	var last error
	delay := 500 * time.Millisecond
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(delay):
			}
			delay *= 2
			if delay > 8*time.Second {
				delay = 8 * time.Second
			}
		}
		last = fn(ctx)
		if last == nil {
			return nil
		}
		if !isRetryableError(last) {
			return last
		}
	}
	return last
}
