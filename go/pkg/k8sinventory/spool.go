package k8sinventory

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

const (
	// LatestFileName is the atomic snapshot file read by the cluster agent.
	LatestFileName = "latest.json"
	// DefaultSpoolDir is the shared emptyDir path used by helm/serviceradar-k8s-edge.
	DefaultSpoolDir = "/var/lib/serviceradar/k8s-inventory/spool"
	// MaxSpoolPayloadBytes bounds agent_spool payloads (agent StreamStatus budget).
	MaxSpoolPayloadBytes = 4 * 1024 * 1024
)

var (
	errSpoolDirRequired      = errors.New("K8S_INVENTORY_SPOOL_DIR is required when PUBLISH_MODE=agent_spool")
	errSpoolPayloadTooLarge  = errors.New("k8s inventory spool payload exceeds size budget")
	errSpoolPublisherClosed  = errors.New("spool publisher is closed")
)

// SpoolPublisher atomically writes inventory snapshots for the co-located agent.
type SpoolPublisher struct {
	dir    string
	mu     sync.Mutex
	closed bool
}

// NewSpoolPublisher creates a publisher that writes latest.json under dir.
func NewSpoolPublisher(dir string) (*SpoolPublisher, error) {
	dir = filepath.Clean(dir)
	if dir == "" || dir == "." {
		return nil, errSpoolDirRequired
	}
	if err := os.MkdirAll(dir, 0o770); err != nil {
		return nil, fmt.Errorf("create k8s inventory spool dir: %w", err)
	}
	return &SpoolPublisher{dir: dir}, nil
}

// LatestPath returns absolute path to latest.json under spoolDir.
func LatestPath(spoolDir string) string {
	return filepath.Join(filepath.Clean(spoolDir), LatestFileName)
}

// LatestPath returns the path of the current snapshot file.
func (p *SpoolPublisher) LatestPath() string {
	if p == nil {
		return ""
	}
	return LatestPath(p.dir)
}

// Publish writes payload to latest.json via temp file + rename.
func (p *SpoolPublisher) Publish(_ context.Context, _ string, payload []byte) error {
	if p == nil {
		return errSpoolPublisherClosed
	}
	if len(payload) > MaxSpoolPayloadBytes {
		return fmt.Errorf("%w: %d > %d", errSpoolPayloadTooLarge, len(payload), MaxSpoolPayloadBytes)
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return errSpoolPublisherClosed
	}

	if err := os.MkdirAll(p.dir, 0o770); err != nil {
		return fmt.Errorf("ensure spool dir: %w", err)
	}

	tmp, err := os.CreateTemp(p.dir, "latest-*.json.tmp")
	if err != nil {
		return fmt.Errorf("create spool temp: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpName)
		}
	}()

	if _, err := tmp.Write(payload); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write spool temp: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("sync spool temp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close spool temp: %w", err)
	}
	if err := os.Chmod(tmpName, 0o640); err != nil {
		return fmt.Errorf("chmod spool temp: %w", err)
	}

	final := p.LatestPath()
	if err := os.Rename(tmpName, final); err != nil {
		return fmt.Errorf("rename spool latest: %w", err)
	}
	cleanup = false
	return nil
}

// Close marks the publisher closed (no more writes).
func (p *SpoolPublisher) Close() {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.closed = true
}

// IsConnected reports whether the spool publisher can accept writes.
func (p *SpoolPublisher) IsConnected() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return !p.closed
}

// ReadLatestSpool reads latest.json from dir (used by unit tests and agent).
func ReadLatestSpool(dir string) ([]byte, error) {
	path := filepath.Join(filepath.Clean(dir), LatestFileName)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(data) > MaxSpoolPayloadBytes {
		return nil, fmt.Errorf("%w: %d > %d", errSpoolPayloadTooLarge, len(data), MaxSpoolPayloadBytes)
	}
	return data, nil
}
