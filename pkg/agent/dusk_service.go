/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package agent pkg/agent/dusk_service.go
package agent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/dusk"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	// DuskServiceName is the name used for dusk in status reports.
	DuskServiceName = "dusk"

	// DuskServiceType is the type identifier for dusk services.
	DuskServiceType = "dusk"

	// Default config paths
	duskLinuxConfigPath  = "/etc/serviceradar/dusk.json"
	duskDarwinConfigPath = "/usr/local/etc/serviceradar/dusk.json"

	// Cache paths
	duskLinuxCachePath  = "/var/lib/serviceradar/cache/dusk-config.json"
	duskDarwinCachePath = "/usr/local/var/serviceradar/cache/dusk-config.json"

	// Config refresh settings for Dusk
	duskDefaultRefreshInterval = 5 * time.Minute
	duskRefreshJitterMax       = 30 * time.Second

	// Config source values
	duskConfigSourceDefault = "default"
	duskConfigSourceTest    = "test"

	// Platform constants
	duskPlatformDarwin = "darwin"
)

// Dusk service errors.
var (
	// ErrDuskServiceNotInitialized is returned when attempting to reconfigure before starting.
	ErrDuskServiceNotInitialized = fmt.Errorf("dusk service not initialized")

	// ErrDuskNilConfig is returned when a nil config is provided.
	ErrDuskNilConfig = fmt.Errorf("nil dusk config provided")

	// ErrDuskMissingNodeAddress is returned when dusk is enabled but node_address is empty.
	ErrDuskMissingNodeAddress = fmt.Errorf("node_address is required when dusk is enabled")
)

// DuskConfig represents the configuration for the embedded dusk service.
// This extends the base dusk.Config with an enabled flag for agent integration.
type DuskConfig struct {
	Enabled     bool                   `json:"enabled"`
	NodeAddress string                 `json:"node_address"`
	Timeout     models.Duration        `json:"timeout"`
	Security    *models.SecurityConfig `json:"security,omitempty"`
}

// DefaultDuskConfig returns a default disabled dusk configuration.
func DefaultDuskConfig() *DuskConfig {
	return &DuskConfig{
		Enabled:     false,
		NodeAddress: "",
		Timeout:     models.Duration(5 * time.Minute),
	}
}

// LoadDuskConfigFromFile loads dusk configuration from a file.
func LoadDuskConfigFromFile(path string) (*DuskConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var cfg DuskConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	return &cfg, nil
}

// DuskService wraps the dusk checker as an agent Service.
type DuskService struct {
	mu        sync.RWMutex
	checker   *dusk.DuskChecker
	config    *DuskConfig
	agentID   string
	partition string
	logger    logger.Logger
	started   bool
	configDir string

	// Config refresh
	configHash   string        // Hash of current config for change detection
	stopRefresh  chan struct{} // Signal to stop refresh loop
	refreshDone  chan struct{} // Signal that refresh loop has stopped
	configSource string        // Source of current config (local/cache/default)

	// Test support
	testConfig *DuskConfig // Override config for testing
}

// DuskServiceConfig holds configuration for the dusk service.
type DuskServiceConfig struct {
	AgentID   string
	Partition string
	ConfigDir string
	Logger    logger.Logger
	// TestConfig overrides the default dusk config for testing.
	TestConfig *DuskConfig
}

// NewDuskService creates a new dusk service.
func NewDuskService(cfg DuskServiceConfig) (*DuskService, error) {
	s := &DuskService{
		agentID:    cfg.AgentID,
		partition:  cfg.Partition,
		configDir:  cfg.ConfigDir,
		logger:     cfg.Logger,
		testConfig: cfg.TestConfig,
	}

	if s.logger == nil {
		s.logger = logger.NewTestLogger()
	}

	return s, nil
}

// Name returns the service name.
func (s *DuskService) Name() string {
	return DuskServiceName
}

// Start initializes and starts the dusk service.
func (s *DuskService) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.started {
		return nil
	}

	// Use test config if provided (for fast test execution)
	var config *DuskConfig
	var source string
	if s.testConfig != nil {
		config = s.testConfig
		source = duskConfigSourceTest
	} else {
		// Load configuration (local file takes precedence)
		var err error
		config, source, err = s.loadConfig(ctx)
		if err != nil {
			s.logger.Warn().Err(err).Msg("Failed to load dusk config, using defaults")
			config = DefaultDuskConfig()
			source = duskConfigSourceDefault
		}
	}

	s.config = config
	s.configHash = computeDuskConfigHash(config)
	s.configSource = source

	// Check if dusk is enabled
	if !config.Enabled {
		s.logger.Info().Msg("Dusk monitoring is disabled in configuration")
		s.started = true // Mark as started to prevent re-initialization
		return nil
	}

	// Validate required fields
	if config.NodeAddress == "" {
		s.logger.Warn().Msg("Dusk node_address not configured, dusk monitoring disabled")
		s.started = true
		return nil
	}

	// Create the dusk checker
	checker := &dusk.DuskChecker{
		Config: dusk.Config{
			NodeAddress: config.NodeAddress,
			Timeout:     config.Timeout,
			Security:    config.Security,
		},
		Done: make(chan struct{}),
	}

	// Start monitoring
	if err := checker.StartMonitoring(ctx); err != nil {
		return fmt.Errorf("failed to start dusk monitoring: %w", err)
	}

	s.checker = checker

	// Cache the config for resilience (best effort)
	if err := s.cacheConfig(config); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to cache dusk config")
	}

	// Initialize and start the config refresh loop
	s.stopRefresh = make(chan struct{})
	s.refreshDone = make(chan struct{})
	go s.configRefreshLoop(ctx)

	s.started = true
	s.logger.Info().
		Str("source", source).
		Str("config_hash", s.configHash[:min(8, len(s.configHash))]).
		Str("node_address", config.NodeAddress).
		Msg("Dusk service started")

	return nil
}

// Stop halts the dusk service and config refresh loop.
func (s *DuskService) Stop(ctx context.Context) error {
	s.mu.Lock()

	if !s.started {
		s.mu.Unlock()
		return nil
	}

	// Mark as stopping to prevent concurrent Stop() calls
	s.started = false

	// Stop the config refresh loop
	if s.stopRefresh != nil {
		close(s.stopRefresh)
	}
	s.mu.Unlock()

	// Wait for refresh loop to finish (with timeout from context)
	if s.refreshDone != nil {
		select {
		case <-s.refreshDone:
			// Refresh loop stopped
		case <-ctx.Done():
			s.logger.Warn().Msg("Timeout waiting for dusk config refresh loop to stop")
		case <-time.After(5 * time.Second):
			s.logger.Warn().Msg("Timeout waiting for dusk config refresh loop to stop")
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.checker != nil {
		close(s.checker.Done)
		s.checker = nil
	}

	s.logger.Info().Msg("Dusk service stopped")
	return nil
}

// GetStatus returns the current dusk status as a StatusResponse.
func (s *DuskService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	start := time.Now()

	if !s.started || s.checker == nil {
		return &proto.StatusResponse{
			Available:    false,
			ServiceName:  DuskServiceName,
			ServiceType:  DuskServiceType,
			ResponseTime: time.Since(start).Nanoseconds(),
		}, nil
	}

	// Get status data from the checker
	statusData := s.checker.GetStatusData()
	if statusData == nil {
		return &proto.StatusResponse{
			Available:    false,
			Message:      []byte(`{"error": "no status data available"}`),
			ServiceName:  DuskServiceName,
			ServiceType:  DuskServiceType,
			ResponseTime: time.Since(start).Nanoseconds(),
		}, nil
	}

	// Build the response payload
	payload := struct {
		Available    bool            `json:"available"`
		ResponseTime int64           `json:"response_time"`
		Status       json.RawMessage `json:"status"`
	}{
		Available:    true,
		ResponseTime: time.Since(start).Nanoseconds(),
		Status:       statusData,
	}

	messageBytes, err := json.Marshal(payload)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to marshal dusk payload")
		return &proto.StatusResponse{
			Available:    false,
			Message:      []byte(fmt.Sprintf(`{"error": "serialization error: %s"}`, err.Error())),
			ServiceName:  DuskServiceName,
			ServiceType:  DuskServiceType,
			ResponseTime: time.Since(start).Nanoseconds(),
		}, nil
	}

	return &proto.StatusResponse{
		Available:    true,
		Message:      messageBytes,
		ServiceName:  DuskServiceName,
		ServiceType:  DuskServiceType,
		ResponseTime: time.Since(start).Nanoseconds(),
	}, nil
}

// loadConfig loads the dusk configuration from local file or defaults.
//
//nolint:unparam // error return reserved for future remote config fetching
func (s *DuskService) loadConfig(_ context.Context) (*DuskConfig, string, error) {
	// Try local config file first (highest priority)
	localPath := s.getDuskLocalConfigPath()
	if localPath != "" {
		if cfg, err := LoadDuskConfigFromFile(localPath); err == nil {
			s.logger.Info().Str("path", localPath).Msg("Loaded dusk config from local file")
			return cfg, "local:" + localPath, nil
		}
	}

	// Try config directory if specified
	if s.configDir != "" {
		configPath := filepath.Join(s.configDir, "dusk.json")
		if cfg, err := LoadDuskConfigFromFile(configPath); err == nil {
			s.logger.Info().Str("path", configPath).Msg("Loaded dusk config from config directory")
			return cfg, "local:" + configPath, nil
		}
	}

	// Try cached config
	cachePath := s.getDuskCachePath()
	if cachePath != "" {
		if cfg, err := LoadDuskConfigFromFile(cachePath); err == nil {
			s.logger.Info().Str("path", cachePath).Msg("Loaded dusk config from cache")
			return cfg, "cache:" + cachePath, nil
		}
	}

	// Fall back to defaults
	s.logger.Info().Msg("Using default dusk configuration (disabled)")
	return DefaultDuskConfig(), duskConfigSourceDefault, nil
}

// cacheConfig writes the current config to the cache file for resilience.
func (s *DuskService) cacheConfig(cfg *DuskConfig) error {
	cachePath := s.getDuskCachePath()
	if cachePath == "" {
		return nil
	}

	// Ensure cache directory exists
	cacheDir := filepath.Dir(cachePath)
	if err := os.MkdirAll(cacheDir, 0755); err != nil {
		return fmt.Errorf("failed to create cache directory: %w", err)
	}

	// Marshal config to JSON
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	// Write to cache file
	if err := os.WriteFile(cachePath, data, 0644); err != nil {
		return fmt.Errorf("failed to write cache file: %w", err)
	}

	s.logger.Debug().Str("path", cachePath).Msg("Cached dusk config")
	return nil
}

// computeDuskConfigHash generates a hash of the config for change detection.
func computeDuskConfigHash(cfg *DuskConfig) string {
	data, err := json.Marshal(cfg)
	if err != nil {
		return ""
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

// configRefreshLoop periodically checks for config updates.
func (s *DuskService) configRefreshLoop(ctx context.Context) {
	defer close(s.refreshDone)

	// Add jitter to avoid thundering herd
	jitter := time.Duration(rand.Int63n(int64(duskRefreshJitterMax)))
	interval := duskDefaultRefreshInterval + jitter

	s.logger.Info().
		Dur("interval", interval).
		Dur("jitter", jitter).
		Msg("Starting dusk config refresh loop")

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			s.logger.Debug().Msg("Dusk config refresh loop stopping due to context cancellation")
			return
		case <-s.stopRefresh:
			s.logger.Debug().Msg("Dusk config refresh loop stopping due to stop signal")
			return
		case <-ticker.C:
			s.checkConfigUpdate(ctx)
		}
	}
}

// checkConfigUpdate checks for config changes and reconfigures if needed.
func (s *DuskService) checkConfigUpdate(ctx context.Context) {
	// Load fresh config
	newConfig, source, err := s.loadConfig(ctx)
	if err != nil {
		s.logger.Warn().Err(err).Msg("Failed to load dusk config during refresh")
		return
	}

	// Compute hash of new config
	newHash := computeDuskConfigHash(newConfig)

	s.mu.RLock()
	currentHash := s.configHash
	s.mu.RUnlock()

	// Check if config changed
	if newHash == currentHash {
		s.logger.Debug().Msg("Dusk config unchanged")
		return
	}

	s.logger.Info().
		Str("source", source).
		Str("old_hash", currentHash[:min(8, len(currentHash))]).
		Str("new_hash", newHash[:min(8, len(newHash))]).
		Msg("Dusk config changed, reconfiguring")

	// Check if dusk should be disabled
	if !newConfig.Enabled {
		s.logger.Info().Msg("Dusk disabled in new config")
		s.mu.Lock()
		if s.checker != nil {
			close(s.checker.Done)
			s.checker = nil
		}
		s.config = newConfig
		s.configHash = newHash
		s.configSource = source
		s.mu.Unlock()
		return
	}

	// Validate required fields
	if newConfig.NodeAddress == "" {
		s.logger.Warn().Msg("Dusk node_address not configured in new config")
		return
	}

	// Reconfigure by stopping and restarting with new config
	s.mu.Lock()
	defer s.mu.Unlock()

	// Stop current checker
	if s.checker != nil {
		close(s.checker.Done)
		s.checker = nil
	}

	// Create new checker with new config
	checker := &dusk.DuskChecker{
		Config: dusk.Config{
			NodeAddress: newConfig.NodeAddress,
			Timeout:     newConfig.Timeout,
			Security:    newConfig.Security,
		},
		Done: make(chan struct{}),
	}

	if err := checker.StartMonitoring(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Failed to start new dusk checker")
		return
	}

	s.checker = checker
	s.config = newConfig
	s.configHash = newHash
	s.configSource = source

	// Cache the new config (best effort)
	if err := s.cacheConfig(newConfig); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to cache new dusk config")
	}

	s.logger.Info().Msg("Dusk service reconfigured successfully")
}

// getDuskLocalConfigPath returns the platform-specific local config path.
func (s *DuskService) getDuskLocalConfigPath() string {
	switch runtime.GOOS {
	case duskPlatformDarwin:
		// Try Linux path first, then macOS-specific path
		if _, err := os.Stat(duskLinuxConfigPath); err == nil {
			return duskLinuxConfigPath
		}
		return duskDarwinConfigPath
	default:
		return duskLinuxConfigPath
	}
}

// getDuskCachePath returns the platform-specific cache path.
func (s *DuskService) getDuskCachePath() string {
	switch runtime.GOOS {
	case duskPlatformDarwin:
		return duskDarwinCachePath
	default:
		return duskLinuxCachePath
	}
}

// IsEnabled returns whether dusk monitoring is enabled.
func (s *DuskService) IsEnabled() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.started && s.config != nil && s.config.Enabled && s.checker != nil
}

// GetConfigSource returns the source of the current configuration.
func (s *DuskService) GetConfigSource() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configSource
}

// GetConfigHash returns the hash of the current configuration.
func (s *DuskService) GetConfigHash() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configHash
}

// Reconfigure applies a new configuration to the dusk service.
// This is called when the gateway sends a new config.
func (s *DuskService) Reconfigure(cfg *DuskConfig, source string) error {
	if cfg == nil {
		return ErrDuskNilConfig
	}

	// Compute hash of new config
	newHash := computeDuskConfigHash(cfg)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Check if config actually changed
	if newHash == s.configHash {
		s.logger.Debug().Msg("Dusk config unchanged during reconfigure")
		return nil
	}

	s.logger.Info().
		Str("source", source).
		Str("old_hash", s.configHash[:min(8, len(s.configHash))]).
		Str("new_hash", newHash[:min(8, len(newHash))]).
		Msg("Reconfiguring dusk service")

	// Handle disabled state
	if !cfg.Enabled {
		if s.checker != nil {
			close(s.checker.Done)
			s.checker = nil
		}
		s.config = cfg
		s.configHash = newHash
		s.configSource = source
		s.logger.Info().Msg("Dusk monitoring disabled via reconfigure")
		return nil
	}

	// Validate required fields
	if cfg.NodeAddress == "" {
		s.logger.Warn().Msg("Dusk node_address not configured in new config")
		return ErrDuskMissingNodeAddress
	}

	// Stop current checker if running
	if s.checker != nil {
		close(s.checker.Done)
		s.checker = nil
	}

	// Create new checker with new config
	checker := &dusk.DuskChecker{
		Config: dusk.Config{
			NodeAddress: cfg.NodeAddress,
			Timeout:     cfg.Timeout,
			Security:    cfg.Security,
		},
		Done: make(chan struct{}),
	}

	ctx := context.Background()
	if err := checker.StartMonitoring(ctx); err != nil {
		return fmt.Errorf("failed to start new dusk checker: %w", err)
	}

	s.checker = checker
	s.config = cfg
	s.configHash = newHash
	s.configSource = source

	// Cache the new config (best effort)
	if err := s.cacheConfig(cfg); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to cache new dusk config")
	}

	s.logger.Info().
		Str("source", source).
		Str("node_address", cfg.NodeAddress).
		Msg("Dusk service reconfigured successfully")

	return nil
}
