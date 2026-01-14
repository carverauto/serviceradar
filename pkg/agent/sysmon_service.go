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

// Package agent pkg/agent/sysmon_service.go
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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/sysmon"
	"github.com/carverauto/serviceradar/proto"
)

const (
	// SysmonServiceName is the name used for sysmon in status reports.
	SysmonServiceName = "sysmon"

	// SysmonServiceType is the type identifier for sysmon services.
	SysmonServiceType = "sysmon"

	// Default config paths
	linuxConfigPath  = "/etc/serviceradar/sysmon.json"
	darwinConfigPath = "/usr/local/etc/serviceradar/sysmon.json"

	// Cache paths
	linuxCachePath  = "/var/lib/serviceradar/cache/sysmon-config.json"
	darwinCachePath = "/usr/local/var/serviceradar/cache/sysmon-config.json"

	// Config refresh settings
	defaultRefreshInterval = 5 * time.Minute
	refreshJitterMax       = 30 * time.Second

	// Config source values
	configSourceDefault = "default"
)

// ErrCollectorNotInitialized is returned when attempting to reconfigure before starting.
var ErrCollectorNotInitialized = fmt.Errorf("collector not initialized")

// SysmonService wraps the sysmon collector as an agent Service.
type SysmonService struct {
	mu        sync.RWMutex
	collector sysmon.Collector
	config    *sysmon.ParsedConfig
	agentID   string
	partition string
	logger    logger.Logger
	started   bool
	configDir string

	// Config refresh
	rawConfig    sysmon.Config // Original config for hash comparison
	configHash   string        // Hash of current config for change detection
	stopRefresh  chan struct{} // Signal to stop refresh loop
	refreshDone  chan struct{} // Signal that refresh loop has stopped
	configSource string        // Source of current config (local/cache/default)

	// Test support
	testConfig *sysmon.Config // Override config for testing (uses faster intervals)
}

// SysmonServiceConfig holds configuration for the sysmon service.
type SysmonServiceConfig struct {
	AgentID   string
	Partition string
	ConfigDir string
	Logger    logger.Logger
	// TestConfig overrides the default sysmon config for testing.
	// Use this in tests to set a fast sample interval (e.g., 100ms).
	TestConfig *sysmon.Config
}

// NewSysmonService creates a new sysmon service.
func NewSysmonService(cfg SysmonServiceConfig) (*SysmonService, error) {
	s := &SysmonService{
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
func (s *SysmonService) Name() string {
	return SysmonServiceName
}

// Start initializes and starts the sysmon collector.
func (s *SysmonService) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.started {
		return nil
	}

	// Use test config if provided (for fast test execution)
	var config sysmon.Config
	var source string
	if s.testConfig != nil {
		config = *s.testConfig
		source = "test"
	} else {
		// Load configuration (local file takes precedence)
		var err error
		config, source, err = s.loadConfig(ctx)
		if err != nil {
			s.logger.Warn().Err(err).Msg("Failed to load sysmon config, using defaults")
			config = sysmon.DefaultConfig()
			source = configSourceDefault
		}
	}

	// Check if sysmon is enabled
	if !config.Enabled {
		s.logger.Info().Msg("Sysmon is disabled in configuration")
		return nil
	}

	// Parse the config
	parsed, err := config.Parse()
	if err != nil {
		return fmt.Errorf("failed to parse sysmon config: %w", err)
	}

	s.config = parsed
	s.rawConfig = config
	s.configHash = computeConfigHash(config)
	s.configSource = source

	// Create collector options
	opts := []sysmon.CollectorOption{
		sysmon.WithLogger(s.logger),
		sysmon.WithAgentID(s.agentID),
	}

	if s.partition != "" {
		opts = append(opts, sysmon.WithPartition(s.partition))
	}

	// Create the collector
	collector, err := sysmon.NewCollector(parsed, opts...)
	if err != nil {
		return fmt.Errorf("failed to create sysmon collector: %w", err)
	}

	s.collector = collector

	// Start the collector
	if err := collector.Start(ctx); err != nil {
		return fmt.Errorf("failed to start sysmon collector: %w", err)
	}

	// Cache the config for resilience (best effort)
	if err := s.cacheConfig(config); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to cache sysmon config")
	}

	// Initialize and start the config refresh loop
	s.stopRefresh = make(chan struct{})
	s.refreshDone = make(chan struct{})
	go s.configRefreshLoop(ctx)

	s.started = true
	s.logger.Info().
		Str("source", source).
		Str("config_hash", s.configHash[:min(8, len(s.configHash))]).
		Str("sample_interval", parsed.SampleInterval.String()).
		Bool("cpu", parsed.CollectCPU).
		Bool("memory", parsed.CollectMemory).
		Bool("disk", parsed.CollectDisk).
		Bool("network", parsed.CollectNetwork).
		Bool("processes", parsed.CollectProcesses).
		Msg("Sysmon service started")

	return nil
}

// Stop halts the sysmon collector and config refresh loop.
func (s *SysmonService) Stop(ctx context.Context) error {
	s.mu.Lock()

	if !s.started {
		s.mu.Unlock()
		return nil
	}

	// Mark as stopping to prevent concurrent Stop() calls from re-entering
	// and attempting to close an already-closed channel
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
			s.logger.Warn().Msg("Timeout waiting for config refresh loop to stop")
		case <-time.After(5 * time.Second):
			s.logger.Warn().Msg("Timeout waiting for config refresh loop to stop")
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.collector != nil {
		if err := s.collector.Stop(); err != nil {
			return fmt.Errorf("failed to stop sysmon collector: %w", err)
		}
	}

	s.logger.Info().Msg("Sysmon service stopped")
	return nil
}

// GetStatus returns the current sysmon status as a StatusResponse.
func (s *SysmonService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	start := time.Now()

	if !s.started || s.collector == nil {
		return &proto.StatusResponse{
			Available:    false,
			ServiceName:  SysmonServiceName,
			ServiceType:  SysmonServiceType,
			ResponseTime: time.Since(start).Nanoseconds(),
		}, nil
	}

	// Get latest metrics
	sample := s.collector.Latest()
	if sample == nil {
		// Try a fresh collection
		var err error
		sample, err = s.collector.Collect(ctx)
		if err != nil {
			return &proto.StatusResponse{
				Available:    false,
				Message:      []byte(fmt.Sprintf(`{"error": %q}`, err.Error())),
				ServiceName:  SysmonServiceName,
				ServiceType:  SysmonServiceType,
				ResponseTime: time.Since(start).Nanoseconds(),
			}, nil
		}
	}

	// Build the response payload matching the existing sysmon format
	payload := struct {
		Available    bool                 `json:"available"`
		ResponseTime int64                `json:"response_time"`
		Status       *sysmon.MetricSample `json:"status"`
	}{
		Available:    true,
		ResponseTime: time.Since(start).Nanoseconds(),
		Status:       sample,
	}

	messageBytes, err := json.Marshal(payload)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to marshal sysmon payload")
		return &proto.StatusResponse{
			Available:    false,
			Message:      []byte(fmt.Sprintf(`{"error": "serialization error: %s"}`, err.Error())),
			ServiceName:  SysmonServiceName,
			ServiceType:  SysmonServiceType,
			ResponseTime: time.Since(start).Nanoseconds(),
		}, nil
	}

	return &proto.StatusResponse{
		Available:    true,
		Message:      messageBytes,
		ServiceName:  SysmonServiceName,
		ServiceType:  SysmonServiceType,
		ResponseTime: time.Since(start).Nanoseconds(),
	}, nil
}

// loadConfig loads the sysmon configuration from local file or defaults.
// It also tracks the source of the config for logging/debugging.
// The ctx parameter and error return are kept for future remote config fetching support.
//
//nolint:unparam // error return reserved for future remote config fetching
func (s *SysmonService) loadConfig(_ context.Context) (sysmon.Config, string, error) {
	// Try local config file first (highest priority)
	localPath := s.getLocalConfigPath()
	if localPath != "" {
		if cfg, err := sysmon.LoadConfigFromFile(localPath); err == nil {
			s.logger.Info().Str("path", localPath).Msg("Loaded sysmon config from local file")
			return *cfg, "local:" + localPath, nil
		}
	}

	// Try config directory if specified
	if s.configDir != "" {
		configPath := filepath.Join(s.configDir, "sysmon.json")
		if cfg, err := sysmon.LoadConfigFromFile(configPath); err == nil {
			s.logger.Info().Str("path", configPath).Msg("Loaded sysmon config from config directory")
			return *cfg, "local:" + configPath, nil
		}
	}

	// Try cached config
	cachePath := s.getCachePath()
	if cachePath != "" {
		if cfg, err := sysmon.LoadConfigFromFile(cachePath); err == nil {
			s.logger.Info().Str("path", cachePath).Msg("Loaded sysmon config from cache")
			return *cfg, "cache:" + cachePath, nil
		}
	}

	// Fall back to defaults
	s.logger.Info().Msg("Using default sysmon configuration")
	return sysmon.DefaultConfig(), configSourceDefault, nil
}

// cacheConfig writes the current config to the cache file for resilience.
func (s *SysmonService) cacheConfig(cfg sysmon.Config) error {
	cachePath := s.getCachePath()
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

	s.logger.Debug().Str("path", cachePath).Msg("Cached sysmon config")
	return nil
}

// computeConfigHash generates a hash of the config for change detection.
func computeConfigHash(cfg sysmon.Config) string {
	data, err := json.Marshal(cfg)
	if err != nil {
		return ""
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

// configRefreshLoop periodically checks for config updates.
func (s *SysmonService) configRefreshLoop(ctx context.Context) {
	defer close(s.refreshDone)

	// Add jitter to avoid thundering herd
	jitter := time.Duration(rand.Int63n(int64(refreshJitterMax)))
	interval := defaultRefreshInterval + jitter

	s.logger.Info().
		Dur("interval", interval).
		Dur("jitter", jitter).
		Msg("Starting sysmon config refresh loop")

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			s.logger.Debug().Msg("Config refresh loop stopping due to context cancellation")
			return
		case <-s.stopRefresh:
			s.logger.Debug().Msg("Config refresh loop stopping due to stop signal")
			return
		case <-ticker.C:
			s.checkConfigUpdate(ctx)
		}
	}
}

// checkConfigUpdate checks for config changes and reconfigures if needed.
func (s *SysmonService) checkConfigUpdate(ctx context.Context) {
	// Load fresh config
	newConfig, source, err := s.loadConfig(ctx)
	if err != nil {
		s.logger.Warn().Err(err).Msg("Failed to load config during refresh")
		return
	}

	// Compute hash of new config
	newHash := computeConfigHash(newConfig)

	s.mu.RLock()
	currentHash := s.configHash
	s.mu.RUnlock()

	// Check if config changed
	if newHash == currentHash {
		s.logger.Debug().Msg("Sysmon config unchanged")
		return
	}

	s.logger.Info().
		Str("source", source).
		Str("old_hash", currentHash[:min(8, len(currentHash))]).
		Str("new_hash", newHash[:min(8, len(newHash))]).
		Msg("Sysmon config changed, reconfiguring")

	// Parse new config
	parsed, err := newConfig.Parse()
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to parse new config")
		return
	}

	// Check if sysmon should be disabled
	if !parsed.Enabled {
		s.logger.Info().Msg("Sysmon disabled in new config")
		// Don't stop the collector here, just log - let admin explicitly stop if needed
	}

	// Reconfigure the collector
	if err := s.Reconfigure(parsed); err != nil {
		s.logger.Error().Err(err).Msg("Failed to reconfigure collector")
		return
	}

	// Update stored state
	s.mu.Lock()
	s.rawConfig = newConfig
	s.configHash = newHash
	s.configSource = source
	s.mu.Unlock()

	// Cache the new config (best effort)
	if err := s.cacheConfig(newConfig); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to cache new config")
	}
}

// getLocalConfigPath returns the platform-specific local config path.
func (s *SysmonService) getLocalConfigPath() string {
	switch runtime.GOOS {
	case "darwin":
		// Try Linux path first, then macOS-specific path
		if _, err := os.Stat(linuxConfigPath); err == nil {
			return linuxConfigPath
		}
		return darwinConfigPath
	default:
		return linuxConfigPath
	}
}

// getCachePath returns the platform-specific cache path.
func (s *SysmonService) getCachePath() string {
	switch runtime.GOOS {
	case "darwin":
		return darwinCachePath
	default:
		return linuxCachePath
	}
}

// Reconfigure updates the sysmon configuration at runtime.
func (s *SysmonService) Reconfigure(config *sysmon.ParsedConfig) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.collector == nil {
		return ErrCollectorNotInitialized
	}

	if err := s.collector.Reconfigure(config); err != nil {
		return fmt.Errorf("failed to reconfigure collector: %w", err)
	}

	s.config = config
	s.logger.Info().Msg("Sysmon service reconfigured")
	return nil
}

// IsEnabled returns whether sysmon collection is enabled.
func (s *SysmonService) IsEnabled() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.started && s.config != nil && s.config.Enabled
}

// GetLatestSample returns the most recent metric sample.
func (s *SysmonService) GetLatestSample() *sysmon.MetricSample {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.collector == nil {
		return nil
	}
	return s.collector.Latest()
}

// GetConfigSource returns the source of the current configuration.
// Returns one of: "local:<path>", "cache:<path>", "default", or "" if not started.
func (s *SysmonService) GetConfigSource() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configSource
}

// GetConfigHash returns the hash of the current configuration.
func (s *SysmonService) GetConfigHash() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configHash
}
