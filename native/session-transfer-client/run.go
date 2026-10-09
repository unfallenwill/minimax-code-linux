package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

// run performs one transfer described by the configuration line on stdin.
//
// When the host advertises relay.auth_refresh it keeps stdin open and expects
// us to ask for refreshed credentials by emitting
// {"type":"refresh_auth","generation":N}; the host answers on stdin with
// {"type":"auth_headers","generation":N,"headers":{...}}. A single reader
// goroutine owns stdin so refresh replies and the control plane never race.
func run() error {
	reader := bufio.NewReader(os.Stdin)

	cfg, err := readConfiguration(reader)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(cfg.DataDirectory, 0o700); err != nil {
		return fmt.Errorf("unable to prepare upload checkpoint: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Ctrl-C / SIGTERM must cancel in-flight HTTP work rather than orphan it.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)
	go func() {
		select {
		case <-signals:
			cancel()
		case <-ctx.Done():
		}
	}()

	control, err := newTransferControlClient(cfg)
	if err != nil {
		return err
	}

	reporter := newProgressReporter()
	defer reporter.flush()

	if cfg.Relay.AuthRefresh {
		watch := startAuthRefreshListener(reader, control)
		defer watch.close()
	}

	switch cfg.Direction {
	case "upload":
		err = runUpload(ctx, cfg, control, reporter.report)
	case "download":
		err = runDownload(ctx, cfg, control, reporter.report)
	default:
		return fmt.Errorf("transfer direction invalid: %q", cfg.Direction)
	}
	reporter.flush()
	return err
}

// progressReporter throttles stdout progress messages. The host caps total
// stdout at 64 KiB and rejects a total that moves backwards, so we only emit on
// meaningful change and never more than once per tick.
type progressReporter struct {
	mu         sync.Mutex
	lastSent   int64
	total      int64
	lastEmitAt time.Time
	throttle   time.Duration
}

func newProgressReporter() *progressReporter {
	return &progressReporter{throttle: 200 * time.Millisecond}
}

func (p *progressReporter) report(uploaded, total int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	// The host rejects progress that exceeds the total or moves backwards,
	// and aborts the whole transfer if we ever send it.
	if uploaded < 0 || total < 0 || uploaded > total {
		return
	}
	if total != p.total {
		p.total = total
		p.lastSent = 0
	}
	// A new phase can legitimately restart the byte count (downloads report
	// per-file totals), but within one total the count must not regress.
	if uploaded < p.lastSent {
		return
	}
	now := time.Now()
	// Always emit the first message and the final one; throttle the rest.
	if p.lastSent > 0 && now.Sub(p.lastEmitAt) < p.throttle {
		return
	}
	if uploaded != p.lastSent {
		p.lastSent = uploaded
		p.lastEmitAt = now
		writeJSONLine(os.Stdout, progressMessage{
			Type:          "progress",
			UploadedBytes: uploaded,
			TotalBytes:    total,
		})
	}
}

func (p *progressReporter) flush() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.total > 0 && p.lastSent != p.total {
		p.lastSent = p.total
		writeJSONLine(os.Stdout, progressMessage{
			Type:          "progress",
			UploadedBytes: p.total,
			TotalBytes:    p.total,
		})
	}
}

// authRefreshWatcher owns stdin while a transfer is running.
type authRefreshWatcher struct {
	once sync.Once
	done chan struct{}
}

func startAuthRefreshListener(reader *bufio.Reader, control *transferControlClient) *authRefreshWatcher {
	watcher := &authRefreshWatcher{done: make(chan struct{})}
	go func() {
		defer close(watcher.done)
		generation := 0
		for {
			line, err := readLine(reader)
			if err != nil {
				return
			}
			var msg authHeadersMessage
			if jsonUnmarshal([]byte(line), &msg) != nil {
				continue
			}
			if msg.Type != "auth_headers" || msg.Generation != generation {
				continue
			}
			control.setHeaders(msg.Headers)
		}
	}()
	return watcher
}

func (w *authRefreshWatcher) close() {
	w.once.Do(func() { close(w.done) })
}
