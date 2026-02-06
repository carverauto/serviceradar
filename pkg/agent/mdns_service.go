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

// Package agent pkg/agent/mdns_service.go
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

	"github.com/carverauto/serviceradar/pkg/agent/mdns"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	// MdnsServiceName is the name used for mDNS in status reports.
	MdnsServiceName = "mdns"

	// MdnsServiceType is the type identifier for mDNS services.
	MdnsServiceType = "mdns"

	// Default config paths
	mdnsLinuxConfigPath  = "/etc/serviceradar/mdns.json"
	mdnsDarwinConfigPath = "/usr/local/etc/serviceradar/mdns.json"

	// Cache paths
	mdnsLinuxCachePath  = "/var/lib/serviceradar/cache/mdns-config.json"
	mdnsDarwinCachePath = "/usr/local/var/serviceradar/cache/mdns-config.json"

	// Config refresh settings for mDNS
	mdnsDefaultRefreshInterval = 5 * time.Minute
	mdnsRefreshJitterMax       = 30 * time.Second

	// Config source values
	mdnsConfigSourceDefault = "default"
	mdnsConfigSourceTest    = "test"

	// Platform constants
	mdnsPlatformDarwin = "darwin"
)

// MdnsAgentService wraps the mDNS service as an agent Service.
type MdnsAgentService struct {
	mu        sync.RWMutex
	service   *mdns.MdnsService
	config    *mdns.Config
	agentID   string
	partition string
	logger    logger.Logger
	started   bool
	configDir string
	baseCtx   context.Context

	// Config refresh
	configHash   string
	stopRefresh  chan struct{}
	refreshDone  chan struct{}
	configSource string

	// Test support
	testConfig     *mdns.Config
	serviceFactory MdnsServiceFactory
}

// MdnsServiceFactory creates mDNS services for the agent.
type MdnsServiceFactory interface {
	CreateService(config *mdns.Config, log logger.Logger) (*mdns.MdnsService, error)
}

// defaultMdnsServiceFactory is the production service factory.
type defaultMdnsServiceFactory struct{}

func (f *defaultMdnsServiceFactory) CreateService(config *mdns.Config, log logger.Logger) (*mdns.MdnsService, error) {
	return mdns.NewMdnsService(config, log)
}

// MdnsAgentServiceConfig holds configuration for the mDNS agent service.
type MdnsAgentServiceConfig struct {
	AgentID        string
	Partition      string
	ConfigDir      string
	Logger         logger.Logger
	TestConfig     *mdns.Config
	ServiceFactory MdnsServiceFactory
}

// NewMdnsAgentService creates a new mDNS agent service.
func NewMdnsAgentService(cfg MdnsAgentServiceConfig) (*MdnsAgentService, error) {
	s := &MdnsAgentService{
		agentID:        cfg.AgentID,
		partition:      cfg.Partition,
		configDir:      cfg.ConfigDir,
		logger:         cfg.Logger,
		testConfig:     cfg.TestConfig,
		serviceFactory: cfg.ServiceFactory,
	}

	if s.logger == nil {
		s.logger = logger.NewTestLogger()
	}

	if s.serviceFactory == nil {
		s.serviceFactory = &defaultMdnsServiceFactory{}
	}

	return s, nil
}

// Name returns the service name.
func (s *MdnsAgentService) Name() string {
	return MdnsServiceName
}

// Start initializes and starts the mDNS service.
func (s *MdnsAgentService) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.started {
		return nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	s.baseCtx = ctx

	var config *mdns.Config
	var source string
	if s.testConfig != nil {
		config = s.testConfig
		source = mdnsConfigSourceTest
	} else {
		var err error
		config, source, err = s.loadConfig(ctx)
		if err != nil {
			s.logger.Warn().Err(err).Msg("Failed to load mDNS config, using defaults")
			config = mdns.DefaultConfig()
			source = mdnsConfigSourceDefault
		}
	}

	if !config.Enabled {
		s.logger.Info().Msg("mDNS is disabled in configuration")
		s.started = true
		return nil
	}

	s.config = config
	s.configHash = computeMdnsConfigHash(config)
	s.configSource = source

	service, err := s.serviceFactory.CreateService(config, s.logger)
	if err != nil {
		return fmt.Errorf("failed to create mDNS service: %w", err)
	}

	s.service = service

	if err := service.Start(s.baseCtx); err != nil {
		return fmt.Errorf("failed to start mDNS service: %w", err)
	}

	if err := s.cacheConfig(config); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to cache mDNS config")
	}

	s.stopRefresh = make(chan struct{})
	s.refreshDone = make(chan struct{})
	go s.configRefreshLoop(ctx)

	s.started = true
	s.logger.Info().
		Str("source", source).
		Str("config_hash", s.configHash[:min(8, len(s.configHash))]).
		Msg("mDNS agent service started")

	return nil
}

// Stop halts the mDNS service and config refresh loop.
//
//nolint:dupl // Intentional parallel structure with SNMPAgentService.Stop
func (s *MdnsAgentService) Stop(ctx context.Context) error {
	s.mu.Lock()

	if !s.started {
		s.mu.Unlock()
		return nil
	}

	s.started = false

	if s.stopRefresh != nil {
		close(s.stopRefresh)
	}
	s.mu.Unlock()

	if s.refreshDone != nil {
		select {
		case <-s.refreshDone:
		case <-ctx.Done():
			s.logger.Warn().Msg("Timeout waiting for mDNS config refresh loop to stop")
		case <-time.After(5 * time.Second):
			s.logger.Warn().Msg("Timeout waiting for mDNS config refresh loop to stop")
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.service != nil {
		if err := s.service.Stop(); err != nil {
			return fmt.Errorf("failed to stop mDNS service: %w", err)
		}
	}

	s.logger.Info().Msg("mDNS agent service stopped")
	return nil
}

// GetStatus returns the current mDNS status as a StatusResponse.
func (s *MdnsAgentService) GetStatus(_ context.Context) (*proto.StatusResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	start := time.Now()

	if !s.started || s.service == nil {
		return &proto.StatusResponse{
			Available:    false,
			ServiceName:  MdnsServiceName,
			ServiceType:  MdnsServiceType,
			ResponseTime: time.Since(start).Nanoseconds(),
		}, nil
	}

	return &proto.StatusResponse{
		Available:    true,
		ServiceName:  MdnsServiceName,
		ServiceType:  MdnsServiceType,
		ResponseTime: time.Since(start).Nanoseconds(),
	}, nil
}

// loadConfig loads the mDNS configuration from local file or defaults.
//
//nolint:unparam // error return reserved for future remote config fetching
func (s *MdnsAgentService) loadConfig(_ context.Context) (*mdns.Config, string, error) {
	localPath := s.getMdnsLocalConfigPath()
	if localPath != "" {
		if cfg, err := mdns.LoadConfigFromFile(localPath); err == nil {
			s.logger.Info().Str("path", localPath).Msg("Loaded mDNS config from local file")
			return cfg, "local:" + localPath, nil
		}
	}

	if s.configDir != "" {
		configPath := filepath.Join(s.configDir, "mdns.json")
		if cfg, err := mdns.LoadConfigFromFile(configPath); err == nil {
			s.logger.Info().Str("path", configPath).Msg("Loaded mDNS config from config directory")
			return cfg, "local:" + configPath, nil
		}
	}

	cachePath := s.getMdnsCachePath()
	if cachePath != "" {
		if cfg, err := mdns.LoadConfigFromFile(cachePath); err == nil {
			s.logger.Info().Str("path", cachePath).Msg("Loaded mDNS config from cache")
			return cfg, "cache:" + cachePath, nil
		}
	}

	s.logger.Info().Msg("Using default mDNS configuration")
	return mdns.DefaultConfig(), mdnsConfigSourceDefault, nil
}

// cacheConfig writes the current config to the cache file for resilience.
func (s *MdnsAgentService) cacheConfig(cfg *mdns.Config) error {
	cachePath := s.getMdnsCachePath()
	if cachePath == "" {
		return nil
	}

	cacheDir := filepath.Dir(cachePath)
	if err := os.MkdirAll(cacheDir, 0755); err != nil {
		return fmt.Errorf("failed to create cache directory: %w", err)
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	if err := os.WriteFile(cachePath, data, 0644); err != nil {
		return fmt.Errorf("failed to write cache file: %w", err)
	}

	s.logger.Debug().Str("path", cachePath).Msg("Cached mDNS config")
	return nil
}

// computeMdnsConfigHash generates a hash of the config for change detection.
func computeMdnsConfigHash(cfg *mdns.Config) string {
	data, err := json.Marshal(cfg)
	if err != nil {
		return ""
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

// configRefreshLoop periodically checks for config updates.
func (s *MdnsAgentService) configRefreshLoop(ctx context.Context) {
	defer close(s.refreshDone)

	jitter := time.Duration(rand.Int63n(int64(mdnsRefreshJitterMax)))
	interval := mdnsDefaultRefreshInterval + jitter

	s.logger.Info().
		Dur("interval", interval).
		Dur("jitter", jitter).
		Msg("Starting mDNS config refresh loop")

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			s.logger.Debug().Msg("mDNS config refresh loop stopping due to context cancellation")
			return
		case <-s.stopRefresh:
			s.logger.Debug().Msg("mDNS config refresh loop stopping due to stop signal")
			return
		case <-ticker.C:
			s.checkConfigUpdate(ctx)
		}
	}
}

// checkConfigUpdate checks for config changes and reconfigures if needed.
func (s *MdnsAgentService) checkConfigUpdate(ctx context.Context) {
	newConfig, source, err := s.loadConfig(ctx)
	if err != nil {
		s.logger.Warn().Err(err).Msg("Failed to load mDNS config during refresh")
		return
	}

	newHash := computeMdnsConfigHash(newConfig)

	s.mu.RLock()
	currentHash := s.configHash
	s.mu.RUnlock()

	if newHash == currentHash {
		s.logger.Debug().Msg("mDNS config unchanged")
		return
	}

	s.logger.Info().
		Str("source", source).
		Str("old_hash", currentHash[:min(8, len(currentHash))]).
		Str("new_hash", newHash[:min(8, len(newHash))]).
		Msg("mDNS config changed, reconfiguring")

	if !newConfig.Enabled {
		s.logger.Info().Msg("mDNS disabled in new config")
		s.mu.Lock()
		if s.service != nil {
			if err := s.service.Stop(); err != nil {
				s.logger.Error().Err(err).Msg("Failed to stop mDNS service")
			}
			s.service = nil
		}
		s.config = newConfig
		s.configHash = newHash
		s.configSource = source
		s.mu.Unlock()
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.service != nil {
		if err := s.service.Stop(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop mDNS service for reconfiguration")
			return
		}
	}

	service, err := s.serviceFactory.CreateService(newConfig, s.logger)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to create new mDNS service")
		return
	}

	if err := service.Start(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Failed to start new mDNS service")
		return
	}

	s.service = service
	s.config = newConfig
	s.configHash = newHash
	s.configSource = source

	if err := s.cacheConfig(newConfig); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to cache new mDNS config")
	}

	s.logger.Info().Msg("mDNS service reconfigured successfully")
}

// getMdnsLocalConfigPath returns the platform-specific local config path.
func (s *MdnsAgentService) getMdnsLocalConfigPath() string {
	switch runtime.GOOS {
	case mdnsPlatformDarwin:
		if _, err := os.Stat(mdnsLinuxConfigPath); err == nil {
			return mdnsLinuxConfigPath
		}
		return mdnsDarwinConfigPath
	default:
		return mdnsLinuxConfigPath
	}
}

// getMdnsCachePath returns the platform-specific cache path.
func (s *MdnsAgentService) getMdnsCachePath() string {
	switch runtime.GOOS {
	case mdnsPlatformDarwin:
		return mdnsDarwinCachePath
	default:
		return mdnsLinuxCachePath
	}
}

// DrainRecords returns and clears the buffered mDNS records.
// Called by the push loop to collect records for gRPC streaming.
func (s *MdnsAgentService) DrainRecords() []mdns.MdnsRecordJSON {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.service == nil {
		return nil
	}
	return s.service.DrainRecords()
}

// IsEnabled returns whether mDNS collection is enabled.
func (s *MdnsAgentService) IsEnabled() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.started && s.config != nil && s.config.Enabled
}

// GetConfigSource returns the source of the current configuration.
func (s *MdnsAgentService) GetConfigSource() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configSource
}

// GetConfigHash returns the hash of the current configuration.
func (s *MdnsAgentService) GetConfigHash() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configHash
}
