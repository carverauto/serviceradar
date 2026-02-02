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

// Package agent pkg/agent/snmp_service.go
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

	"github.com/carverauto/serviceradar/pkg/agent/snmp"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	// SNMPServiceName is the name used for SNMP in status reports.
	SNMPServiceName = "snmp"

	// SNMPServiceType is the type identifier for SNMP services.
	SNMPServiceType = "snmp"

	// Default config paths
	snmpLinuxConfigPath  = "/etc/serviceradar/snmp.json"
	snmpDarwinConfigPath = "/usr/local/etc/serviceradar/snmp.json"

	// Cache paths
	snmpLinuxCachePath  = "/var/lib/serviceradar/cache/snmp-config.json"
	snmpDarwinCachePath = "/usr/local/var/serviceradar/cache/snmp-config.json"

	// Config refresh settings for SNMP
	snmpDefaultRefreshInterval = 5 * time.Minute
	snmpRefreshJitterMax       = 30 * time.Second

	// Config source values
	snmpConfigSourceDefault = "default"
	snmpConfigSourceTest    = "test"

	// Platform constants
	snmpPlatformDarwin = "darwin"
)

// ErrSNMPServiceNotInitialized is returned when attempting to reconfigure before starting.
var ErrSNMPServiceNotInitialized = fmt.Errorf("SNMP service not initialized")

// ErrNilProtoConfig is returned when a nil proto config is passed to ApplyProtoConfig.
var ErrNilProtoConfig = fmt.Errorf("nil proto config")

// SNMPAgentService wraps the SNMP service as an agent Service.
type SNMPAgentService struct {
	mu        sync.RWMutex
	service   *snmp.SNMPService
	config    *snmp.SNMPConfig
	agentID   string
	partition string
	logger    logger.Logger
	started   bool
	configDir string
	baseCtx   context.Context

	// Config refresh
	configHash   string        // Hash of current config for change detection
	stopRefresh  chan struct{} // Signal to stop refresh loop
	refreshDone  chan struct{} // Signal that refresh loop has stopped
	configSource string        // Source of current config (local/cache/default)

	// Test support
	testConfig     *snmp.SNMPConfig   // Override config for testing
	serviceFactory SNMPServiceFactory // Factory for creating SNMP services
}

// SNMPServiceFactory creates SNMP services for the agent.
// This interface allows injection of mock services for testing.
type SNMPServiceFactory interface {
	// CreateService creates an SNMP service from the given config.
	CreateService(config *snmp.SNMPConfig, log logger.Logger) (*snmp.SNMPService, error)
}

// defaultSNMPServiceFactory is the production service factory.
type defaultSNMPServiceFactory struct{}

func (f *defaultSNMPServiceFactory) CreateService(config *snmp.SNMPConfig, log logger.Logger) (*snmp.SNMPService, error) {
	return snmp.NewSNMPServiceForAgent(config, log)
}

// SNMPAgentServiceConfig holds configuration for the SNMP agent service.
type SNMPAgentServiceConfig struct {
	AgentID   string
	Partition string
	ConfigDir string
	Logger    logger.Logger
	// TestConfig overrides the default SNMP config for testing.
	TestConfig *snmp.SNMPConfig
	// ServiceFactory allows injection of mock services for testing.
	// If nil, the default factory is used.
	ServiceFactory SNMPServiceFactory
}

// NewSNMPAgentService creates a new SNMP agent service.
func NewSNMPAgentService(cfg SNMPAgentServiceConfig) (*SNMPAgentService, error) {
	s := &SNMPAgentService{
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

	// Use default factory if none provided
	if s.serviceFactory == nil {
		s.serviceFactory = &defaultSNMPServiceFactory{}
	}

	return s, nil
}

// Name returns the service name.
func (s *SNMPAgentService) Name() string {
	return SNMPServiceName
}

// Start initializes and starts the SNMP service.
func (s *SNMPAgentService) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.started {
		return nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	s.baseCtx = ctx

	// Use test config if provided (for fast test execution)
	var config *snmp.SNMPConfig
	var source string
	if s.testConfig != nil {
		config = s.testConfig
		source = snmpConfigSourceTest
	} else {
		// Load configuration (local file takes precedence)
		var err error
		config, source, err = s.loadConfig(ctx)
		if err != nil {
			s.logger.Warn().Err(err).Msg("Failed to load SNMP config, using defaults")
			config = snmp.DefaultConfig()
			source = snmpConfigSourceDefault
		}
	}

	// Check if SNMP is enabled
	if !config.Enabled {
		s.logger.Info().Msg("SNMP is disabled in configuration")
		s.started = true // Mark as started to prevent re-initialization
		return nil
	}

	s.config = config
	s.configHash = computeSNMPConfigHash(config)
	s.configSource = source

	// Create the SNMP service using the factory
	service, err := s.serviceFactory.CreateService(config, s.logger)
	if err != nil {
		return fmt.Errorf("failed to create SNMP service: %w", err)
	}

	s.service = service

	// Start the SNMP service
	if err := service.Start(s.baseCtx); err != nil {
		return fmt.Errorf("failed to start SNMP service: %w", err)
	}

	// Cache the config for resilience (best effort)
	if err := s.cacheConfig(config); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to cache SNMP config")
	}

	// Initialize and start the config refresh loop
	s.stopRefresh = make(chan struct{})
	s.refreshDone = make(chan struct{})
	go s.configRefreshLoop(ctx)

	s.started = true
	s.logger.Info().
		Str("source", source).
		Str("config_hash", s.configHash[:min(8, len(s.configHash))]).
		Int("target_count", len(config.Targets)).
		Msg("SNMP agent service started")

	return nil
}

// Stop halts the SNMP service and config refresh loop.
//
//nolint:dupl // Intentional parallel structure with SysmonService.Stop
func (s *SNMPAgentService) Stop(ctx context.Context) error {
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
			s.logger.Warn().Msg("Timeout waiting for SNMP config refresh loop to stop")
		case <-time.After(5 * time.Second):
			s.logger.Warn().Msg("Timeout waiting for SNMP config refresh loop to stop")
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.service != nil {
		if err := s.service.Stop(); err != nil {
			return fmt.Errorf("failed to stop SNMP service: %w", err)
		}
	}

	s.logger.Info().Msg("SNMP agent service stopped")
	return nil
}

// GetStatus returns the current SNMP status as a StatusResponse.
func (s *SNMPAgentService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	start := time.Now()

	if !s.started || s.service == nil {
		return &proto.StatusResponse{
			Available:    false,
			ServiceName:  SNMPServiceName,
			ServiceType:  SNMPServiceType,
			ResponseTime: time.Since(start).Nanoseconds(),
		}, nil
	}

	// Get status from the underlying SNMP service
	statusMap, err := s.service.GetStatus(ctx)
	if err != nil {
		return &proto.StatusResponse{
			Available:    false,
			Message:      []byte(fmt.Sprintf(`{"error": %q}`, err.Error())),
			ServiceName:  SNMPServiceName,
			ServiceType:  SNMPServiceType,
			ResponseTime: time.Since(start).Nanoseconds(),
		}, nil
	}

	// Determine overall availability
	available := true
	for _, targetStatus := range statusMap {
		if !targetStatus.Available {
			available = false
			break
		}
	}

	// Build the response payload
	payload := struct {
		Available    bool                         `json:"available"`
		ResponseTime int64                        `json:"response_time"`
		Targets      map[string]snmp.TargetStatus `json:"targets"`
	}{
		Available:    available,
		ResponseTime: time.Since(start).Nanoseconds(),
		Targets:      statusMap,
	}

	messageBytes, err := json.Marshal(payload)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to marshal SNMP payload")
		return &proto.StatusResponse{
			Available:    false,
			Message:      []byte(fmt.Sprintf(`{"error": "serialization error: %s"}`, err.Error())),
			ServiceName:  SNMPServiceName,
			ServiceType:  SNMPServiceType,
			ResponseTime: time.Since(start).Nanoseconds(),
		}, nil
	}

	return &proto.StatusResponse{
		Available:    available,
		Message:      messageBytes,
		ServiceName:  SNMPServiceName,
		ServiceType:  SNMPServiceType,
		ResponseTime: time.Since(start).Nanoseconds(),
	}, nil
}

// GetTargetStatuses returns the raw SNMP target status map, including target config.
func (s *SNMPAgentService) GetTargetStatuses(ctx context.Context) (map[string]snmp.TargetStatus, error) {
	s.mu.RLock()
	started := s.started
	svc := s.service
	s.mu.RUnlock()

	if !started || svc == nil {
		return nil, nil
	}

	return svc.GetStatus(ctx)
}

// DrainMetrics returns all data points collected since the last Drain call.
func (s *SNMPAgentService) DrainMetrics(ctx context.Context) (map[string][]snmp.DataPoint, error) {
	s.mu.RLock()
	started := s.started
	svc := s.service
	s.mu.RUnlock()

	if !started || svc == nil {
		return nil, nil
	}

	return svc.DrainMetrics(ctx)
}

// loadConfig loads the SNMP configuration from local file or defaults.
//
//nolint:unparam // error return reserved for future remote config fetching
func (s *SNMPAgentService) loadConfig(_ context.Context) (*snmp.SNMPConfig, string, error) {
	// Try local config file first (highest priority)
	localPath := s.getSNMPLocalConfigPath()
	if localPath != "" {
		if cfg, err := snmp.LoadConfigFromFile(localPath); err == nil {
			s.logger.Info().Str("path", localPath).Msg("Loaded SNMP config from local file")
			return cfg, "local:" + localPath, nil
		}
	}

	// Try config directory if specified
	if s.configDir != "" {
		configPath := filepath.Join(s.configDir, "snmp.json")
		if cfg, err := snmp.LoadConfigFromFile(configPath); err == nil {
			s.logger.Info().Str("path", configPath).Msg("Loaded SNMP config from config directory")
			return cfg, "local:" + configPath, nil
		}
	}

	// Try cached config
	cachePath := s.getSNMPCachePath()
	if cachePath != "" {
		if cfg, err := snmp.LoadConfigFromFile(cachePath); err == nil {
			s.logger.Info().Str("path", cachePath).Msg("Loaded SNMP config from cache")
			return cfg, "cache:" + cachePath, nil
		}
	}

	// Fall back to defaults
	s.logger.Info().Msg("Using default SNMP configuration")
	return snmp.DefaultConfig(), snmpConfigSourceDefault, nil
}

// cacheConfig writes the current config to the cache file for resilience.
func (s *SNMPAgentService) cacheConfig(cfg *snmp.SNMPConfig) error {
	cachePath := s.getSNMPCachePath()
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

	s.logger.Debug().Str("path", cachePath).Msg("Cached SNMP config")
	return nil
}

// computeSNMPConfigHash generates a hash of the config for change detection.
func computeSNMPConfigHash(cfg *snmp.SNMPConfig) string {
	data, err := json.Marshal(cfg)
	if err != nil {
		return ""
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

// configRefreshLoop periodically checks for config updates.
func (s *SNMPAgentService) configRefreshLoop(ctx context.Context) {
	defer close(s.refreshDone)

	// Add jitter to avoid thundering herd
	jitter := time.Duration(rand.Int63n(int64(snmpRefreshJitterMax)))
	interval := snmpDefaultRefreshInterval + jitter

	s.logger.Info().
		Dur("interval", interval).
		Dur("jitter", jitter).
		Msg("Starting SNMP config refresh loop")

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			s.logger.Debug().Msg("SNMP config refresh loop stopping due to context cancellation")
			return
		case <-s.stopRefresh:
			s.logger.Debug().Msg("SNMP config refresh loop stopping due to stop signal")
			return
		case <-ticker.C:
			s.checkConfigUpdate(ctx)
		}
	}
}

// checkConfigUpdate checks for config changes and reconfigures if needed.
func (s *SNMPAgentService) checkConfigUpdate(ctx context.Context) {
	// Load fresh config
	newConfig, source, err := s.loadConfig(ctx)
	if err != nil {
		s.logger.Warn().Err(err).Msg("Failed to load SNMP config during refresh")
		return
	}

	// Compute hash of new config
	newHash := computeSNMPConfigHash(newConfig)

	s.mu.RLock()
	currentHash := s.configHash
	s.mu.RUnlock()

	// Check if config changed
	if newHash == currentHash {
		s.logger.Debug().Msg("SNMP config unchanged")
		return
	}

	s.logger.Info().
		Str("source", source).
		Str("old_hash", currentHash[:min(8, len(currentHash))]).
		Str("new_hash", newHash[:min(8, len(newHash))]).
		Msg("SNMP config changed, reconfiguring")

	// Check if SNMP should be disabled
	if !newConfig.Enabled {
		s.logger.Info().Msg("SNMP disabled in new config")
		// Stop the service
		s.mu.Lock()
		if s.service != nil {
			if err := s.service.Stop(); err != nil {
				s.logger.Error().Err(err).Msg("Failed to stop SNMP service")
			}
			s.service = nil
		}
		s.config = newConfig
		s.configHash = newHash
		s.configSource = source
		s.mu.Unlock()
		return
	}

	// Reconfigure by stopping and restarting with new config
	s.mu.Lock()
	defer s.mu.Unlock()

	// Stop current service
	if s.service != nil {
		if err := s.service.Stop(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop SNMP service for reconfiguration")
			return
		}
	}

	// Create new service with new config using factory
	service, err := s.serviceFactory.CreateService(newConfig, s.logger)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to create new SNMP service")
		return
	}

	if err := service.Start(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Failed to start new SNMP service")
		return
	}

	s.service = service
	s.config = newConfig
	s.configHash = newHash
	s.configSource = source

	// Cache the new config (best effort)
	if err := s.cacheConfig(newConfig); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to cache new SNMP config")
	}

	s.logger.Info().Msg("SNMP service reconfigured successfully")
}

// getSNMPLocalConfigPath returns the platform-specific local config path.
func (s *SNMPAgentService) getSNMPLocalConfigPath() string {
	switch runtime.GOOS {
	case snmpPlatformDarwin:
		// Try Linux path first, then macOS-specific path
		if _, err := os.Stat(snmpLinuxConfigPath); err == nil {
			return snmpLinuxConfigPath
		}
		return snmpDarwinConfigPath
	default:
		return snmpLinuxConfigPath
	}
}

// getSNMPCachePath returns the platform-specific cache path.
func (s *SNMPAgentService) getSNMPCachePath() string {
	switch runtime.GOOS {
	case snmpPlatformDarwin:
		return snmpDarwinCachePath
	default:
		return snmpLinuxCachePath
	}
}

// IsEnabled returns whether SNMP collection is enabled.
func (s *SNMPAgentService) IsEnabled() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.started && s.config != nil && s.config.Enabled
}

// GetConfigSource returns the source of the current configuration.
func (s *SNMPAgentService) GetConfigSource() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configSource
}

// GetConfigHash returns the hash of the current configuration.
func (s *SNMPAgentService) GetConfigHash() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configHash
}

// ApplyProtoConfig applies configuration from the protobuf SNMPConfig message.
// This is used when receiving config from the control plane.
func (s *SNMPAgentService) ApplyProtoConfig(ctx context.Context, protoConfig *proto.SNMPConfig) error {
	if protoConfig == nil {
		return ErrNilProtoConfig
	}

	// Convert proto config to internal config format
	config := protoToSNMPConfig(protoConfig)

	// Compute hash of new config
	newHash := computeSNMPConfigHash(config)

	s.mu.RLock()
	currentHash := s.configHash
	s.mu.RUnlock()

	// Check if config changed
	if newHash == currentHash {
		s.logger.Debug().Msg("SNMP proto config unchanged")
		return nil
	}

	s.logger.Info().
		Str("old_hash", currentHash[:min(8, len(currentHash))]).
		Str("new_hash", newHash[:min(8, len(newHash))]).
		Msg("Applying new SNMP proto config")

	s.mu.Lock()
	defer s.mu.Unlock()

	serviceCtx := s.baseCtx
	if serviceCtx == nil {
		serviceCtx = context.Background()
	}

	// Handle disabled state
	if !config.Enabled {
		if s.service != nil {
			if err := s.service.Stop(); err != nil {
				return fmt.Errorf("failed to stop SNMP service: %w", err)
			}
			s.service = nil
		}
		s.config = config
		s.configHash = newHash
		s.configSource = "remote"
		return nil
	}

	// Stop current service
	if s.service != nil {
		if err := s.service.Stop(); err != nil {
			return fmt.Errorf("failed to stop SNMP service: %w", err)
		}
	}

	// Create and start new service using factory
	service, err := s.serviceFactory.CreateService(config, s.logger)
	if err != nil {
		return fmt.Errorf("failed to create SNMP service: %w", err)
	}

	if err := service.Start(serviceCtx); err != nil {
		return fmt.Errorf("failed to start SNMP service: %w", err)
	}

	s.service = service
	s.config = config
	s.configHash = newHash
	s.configSource = "remote"

	// Cache the new config for resilience
	if err := s.cacheConfig(config); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to cache new SNMP config")
	}

	return nil
}

// protoToSNMPConfig converts a proto.SNMPConfig to snmp.SNMPConfig.
func protoToSNMPConfig(p *proto.SNMPConfig) *snmp.SNMPConfig {
	if p == nil {
		return snmp.DefaultConfig()
	}

	config := &snmp.SNMPConfig{
		Enabled: p.Enabled,
		Targets: make([]snmp.Target, 0, len(p.Targets)),
	}

	for _, t := range p.Targets {
		target := snmp.Target{
			Name:      t.Name,
			Host:      t.Host,
			Port:      uint16(t.Port),
			Community: t.Community,
			Version:   protoToSNMPVersion(t.Version),
			Interval:  snmp.Duration(time.Duration(t.PollIntervalSeconds) * time.Second),
			Timeout:   snmp.Duration(time.Duration(t.TimeoutSeconds) * time.Second),
			Retries:   int(t.Retries),
			OIDs:      make([]snmp.OIDConfig, 0, len(t.Oids)),
			MaxPoints: 1000, // Default value
		}

		// Handle SNMPv3 auth
		if t.V3Auth != nil {
			target.Community = "" // Clear community for v3
			target.V3Auth = &snmp.V3Auth{
				Username:      t.V3Auth.Username,
				SecurityLevel: protoToSNMPSecurityLevel(t.V3Auth.SecurityLevel),
				AuthProtocol:  protoToSNMPAuthProtocol(t.V3Auth.AuthProtocol),
				AuthPassword:  t.V3Auth.AuthPassword,
				PrivProtocol:  protoToSNMPPrivProtocol(t.V3Auth.PrivProtocol),
				PrivPassword:  t.V3Auth.PrivPassword,
			}
		}

		for _, oid := range t.Oids {
			target.OIDs = append(target.OIDs, snmp.OIDConfig{
				OID:      oid.Oid,
				Name:     oid.Name,
				DataType: protoToSNMPDataType(oid.DataType),
				Scale:    float64(oid.Scale),
				Delta:    oid.Delta,
			})
		}

		config.Targets = append(config.Targets, target)
	}

	return config
}

// protoToSNMPVersion converts proto SNMPVersion to snmp.SNMPVersion.
func protoToSNMPVersion(v proto.SNMPVersion) snmp.SNMPVersion {
	switch v {
	case proto.SNMPVersion_SNMP_VERSION_V1:
		return snmp.Version1
	case proto.SNMPVersion_SNMP_VERSION_V2C:
		return snmp.Version2c
	case proto.SNMPVersion_SNMP_VERSION_V3:
		return snmp.Version3
	case proto.SNMPVersion_SNMP_VERSION_UNSPECIFIED:
		return snmp.Version2c
	}
	return snmp.Version2c
}

// protoToSNMPDataType converts proto SNMPDataType to snmp.DataType.
func protoToSNMPDataType(dt proto.SNMPDataType) snmp.DataType {
	switch dt {
	case proto.SNMPDataType_SNMP_DATA_TYPE_COUNTER:
		return snmp.TypeCounter
	case proto.SNMPDataType_SNMP_DATA_TYPE_GAUGE:
		return snmp.TypeGauge
	case proto.SNMPDataType_SNMP_DATA_TYPE_BOOLEAN:
		return snmp.TypeBoolean
	case proto.SNMPDataType_SNMP_DATA_TYPE_STRING:
		return snmp.TypeString
	case proto.SNMPDataType_SNMP_DATA_TYPE_FLOAT:
		return snmp.TypeFloat
	case proto.SNMPDataType_SNMP_DATA_TYPE_BYTES:
		return snmp.TypeString // Map bytes to string type
	case proto.SNMPDataType_SNMP_DATA_TYPE_TIMETICKS:
		return snmp.TypeCounter // Timeticks are counter-like
	case proto.SNMPDataType_SNMP_DATA_TYPE_UNSPECIFIED:
		return snmp.TypeGauge
	}
	return snmp.TypeGauge
}

// protoToSNMPSecurityLevel converts proto SNMPSecurityLevel to snmp.SecurityLevel.
func protoToSNMPSecurityLevel(sl proto.SNMPSecurityLevel) snmp.SecurityLevel {
	switch sl {
	case proto.SNMPSecurityLevel_SNMP_SECURITY_LEVEL_NO_AUTH_NO_PRIV:
		return snmp.SecurityLevelNoAuthNoPriv
	case proto.SNMPSecurityLevel_SNMP_SECURITY_LEVEL_AUTH_NO_PRIV:
		return snmp.SecurityLevelAuthNoPriv
	case proto.SNMPSecurityLevel_SNMP_SECURITY_LEVEL_AUTH_PRIV:
		return snmp.SecurityLevelAuthPriv
	case proto.SNMPSecurityLevel_SNMP_SECURITY_LEVEL_UNSPECIFIED:
		return snmp.SecurityLevelNoAuthNoPriv
	}
	return snmp.SecurityLevelNoAuthNoPriv
}

// protoToSNMPAuthProtocol converts proto SNMPAuthProtocol to snmp.AuthProtocol.
func protoToSNMPAuthProtocol(ap proto.SNMPAuthProtocol) snmp.AuthProtocol {
	switch ap {
	case proto.SNMPAuthProtocol_SNMP_AUTH_PROTOCOL_MD5:
		return snmp.AuthProtocolMD5
	case proto.SNMPAuthProtocol_SNMP_AUTH_PROTOCOL_SHA:
		return snmp.AuthProtocolSHA
	case proto.SNMPAuthProtocol_SNMP_AUTH_PROTOCOL_SHA224:
		return snmp.AuthProtocolSHA224
	case proto.SNMPAuthProtocol_SNMP_AUTH_PROTOCOL_SHA256:
		return snmp.AuthProtocolSHA256
	case proto.SNMPAuthProtocol_SNMP_AUTH_PROTOCOL_SHA384:
		return snmp.AuthProtocolSHA384
	case proto.SNMPAuthProtocol_SNMP_AUTH_PROTOCOL_SHA512:
		return snmp.AuthProtocolSHA512
	case proto.SNMPAuthProtocol_SNMP_AUTH_PROTOCOL_UNSPECIFIED:
		return snmp.AuthProtocolMD5
	}
	return snmp.AuthProtocolMD5
}

// protoToSNMPPrivProtocol converts proto SNMPPrivProtocol to snmp.PrivProtocol.
func protoToSNMPPrivProtocol(pp proto.SNMPPrivProtocol) snmp.PrivProtocol {
	switch pp {
	case proto.SNMPPrivProtocol_SNMP_PRIV_PROTOCOL_DES:
		return snmp.PrivProtocolDES
	case proto.SNMPPrivProtocol_SNMP_PRIV_PROTOCOL_AES:
		return snmp.PrivProtocolAES
	case proto.SNMPPrivProtocol_SNMP_PRIV_PROTOCOL_AES192,
		proto.SNMPPrivProtocol_SNMP_PRIV_PROTOCOL_AES192C:
		return snmp.PrivProtocolAES192
	case proto.SNMPPrivProtocol_SNMP_PRIV_PROTOCOL_AES256,
		proto.SNMPPrivProtocol_SNMP_PRIV_PROTOCOL_AES256C:
		return snmp.PrivProtocolAES256
	case proto.SNMPPrivProtocol_SNMP_PRIV_PROTOCOL_UNSPECIFIED:
		return snmp.PrivProtocolDES
	}
	return snmp.PrivProtocolDES
}
