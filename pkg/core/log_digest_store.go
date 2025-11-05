package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// FileLogDigestStore persists log digest snapshots to a local JSON file.
type FileLogDigestStore struct {
	path   string
	logger logger.Logger
	mu     sync.Mutex
}

// NewFileLogDigestStore constructs a file-backed log digest store.
func NewFileLogDigestStore(path string, log logger.Logger) (*FileLogDigestStore, error) {
	if path == "" {
		return nil, errors.New("log digest store path is required")
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, serviceradarDirPerms); err != nil {
		return nil, fmt.Errorf("create log digest directory: %w", err)
	}

	return &FileLogDigestStore{
		path:   path,
		logger: log,
	}, nil
}

// Load restores the most recent snapshot from disk.
func (s *FileLogDigestStore) Load() (*models.LogDigestSnapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("read log digest snapshot: %w", err)
	}

	var snapshot models.LogDigestSnapshot
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return nil, fmt.Errorf("decode log digest snapshot: %w", err)
	}

	return &snapshot, nil
}

// Save writes the provided snapshot to disk.
func (s *FileLogDigestStore) Save(snapshot *models.LogDigestSnapshot) error {
	if snapshot == nil {
		return nil
	}

	payload, err := json.Marshal(snapshot)
	if err != nil {
		return fmt.Errorf("encode log digest snapshot: %w", err)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	tmpPath := s.path + ".tmp"
	if err := os.WriteFile(tmpPath, payload, 0o600); err != nil {
		return fmt.Errorf("write temporary log digest snapshot: %w", err)
	}

	if err := os.Rename(tmpPath, s.path); err != nil {
		_ = os.Remove(tmpPath) // best-effort cleanup
		return fmt.Errorf("persist log digest snapshot: %w", err)
	}

	return nil
}
