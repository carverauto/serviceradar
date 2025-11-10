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

// Package agent pkg/agent/server.go
package agent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/checker"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/hashutil"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	// ErrAgentIDRequired indicates agent_id is required in configuration
	ErrAgentIDRequired = errors.New("agent_id is required in configuration")
	// ErrInvalidJSONResponse indicates invalid JSON response from checker
	ErrInvalidJSONResponse = errors.New("invalid JSON response from checker")
	// ErrDataServiceClientInit indicates the DataService client could not be created.
	ErrDataServiceClientInit = errors.New("failed to initialize DataService client")
	// ErrInvalidSweepMetadata signals that stored sweep metadata is malformed.
	ErrInvalidSweepMetadata = errors.New("invalid sweep metadata")
	// ErrObjectStoreUnavailable is returned when the object store client is not available.
	ErrObjectStoreUnavailable = errors.New("object store unavailable")
)

const (
	defaultTimeout     = 30 * time.Second
	jsonSuffix         = ".json"
	fallBackSuffix     = "fallback"
	grpcType           = "grpc"
	sweepType          = "sweep"
	defaultErrChansize = 10
)

// safeIntToInt32 safely converts an int to int32, capping at int32 max value
func safeIntToInt32(val int) int32 {
	if val > math.MaxInt32 {
		return math.MaxInt32
	}

	if val < math.MinInt32 {
		return math.MinInt32
	}

	return int32(val)
}

// NewServer initializes a new Server instance.
func NewServer(ctx context.Context, configDir string, cfg *ServerConfig, log logger.Logger) (*Server, error) {
	cfgLoader := config.NewConfig(log)

	s := initializeServer(configDir, cfg, log)

	configStore, objectStore, err := s.setupDataStores(ctx, cfgLoader, cfg, log)
	if err != nil {
		return nil, err
	}

	s.configStore = configStore
	s.objectStore = objectStore

	s.createSweepService = func(ctx context.Context, sweepConfig *SweepConfig, configStore KVStore, objectStore ObjectStore) (Service, error) {
		return createSweepService(ctx, sweepConfig, configStore, objectStore, cfg, log)
	}

	if err := s.loadConfigurations(ctx, cfgLoader); err != nil {
		return nil, fmt.Errorf("failed to load configurations: %w", err)
	}

	// Bootstrap default configs for common services in KV (PutIfAbsent), best-effort.
	if s.configStore != nil && cfg.AgentID != "" {
		s.bootstrapKVDefaults(ctx, cfg.AgentID)
	}

	return s, nil
}

// bootstrapKVDefaults writes minimal default configs for standard services if missing.
func (s *Server) bootstrapKVDefaults(ctx context.Context, agentID string) {
	type putIfAbsent interface {
		PutIfAbsent(ctx context.Context, key string, value []byte, ttl time.Duration) error
	}
	pfa, hasPFA := any(s.configStore).(putIfAbsent)
	// Conventional keys for agent-local checkers
	entries := map[string][]byte{
		fmt.Sprintf("agents/%s/checkers/snmp/snmp.json", agentID):     []byte(`{"enabled": false, "targets": []}`),
		fmt.Sprintf("agents/%s/checkers/mapper/mapper.json", agentID): []byte(`{"enabled": false, "address": "serviceradar-mapper:50056"}`),
		fmt.Sprintf("agents/%s/checkers/trapd/trapd.json", agentID):   []byte(`{"enabled": false, "listen_addr": ":50043"}`),
		fmt.Sprintf("agents/%s/checkers/rperf/rperf.json", agentID):   []byte(`{"enabled": false, "targets": []}`),
		fmt.Sprintf("agents/%s/checkers/sysmon/sysmon.json", agentID): []byte(`{"enabled": true, "interval": "10s"}`),
	}

	for key, val := range entries {
		// Try atomic create first
		if hasPFA {
			if err := pfa.PutIfAbsent(ctx, key, val, 0); err == nil {
				s.logger.Info().Str("key", key).Msg("Bootstrapped default config in KV (created)")
				continue
			}
		}
		// Fallback: check then put
		if _, found, err := s.configStore.Get(ctx, key); err == nil && !found {
			if err := s.configStore.Put(ctx, key, val, 0); err == nil {
				s.logger.Info().Str("key", key).Msg("Bootstrapped default config in KV (fallback)")
			}
		}
	}
}

// initializeServer creates a new Server struct with default values.
func initializeServer(configDir string, cfg *ServerConfig, log logger.Logger) *Server {
	return &Server{
		checkers:        make(map[string]checker.Checker),
		checkerConfs:    make(map[string]*CheckerConfig),
		configDir:       configDir,
		services:        make([]Service, 0),
		listenAddr:      cfg.ListenAddr,
		registry:        initRegistry(log),
		errChan:         make(chan error, defaultErrChansize),
		done:            make(chan struct{}),
		config:          cfg,
		connections:     make(map[string]*CheckerConnection),
		logger:          log,
		setupDataStores: setupDataStores,
	}
}

// setupDataStores configures the KV and object stores if an address is provided.
func setupDataStores(ctx context.Context, cfgLoader *config.Config, cfg *ServerConfig, log logger.Logger) (KVStore, ObjectStore, error) {
	kvAddress, securityConfig, err := resolveKVConnectionSettings(cfg)
	if err != nil {
		return nil, nil, err
	}

	if kvAddress == "" {
		log.Info().Msg("KVAddress not set via config or environment, skipping KV store setup")
		return nil, nil, nil
	}

	if securityConfig == nil {
		return nil, nil, errNoSecurityConfigKV
	}

	cfg.KVAddress = kvAddress
	if cfg.KVSecurity == nil && securityConfig != cfg.Security {
		cfg.KVSecurity = securityConfig
	}

	clientCfg := grpc.ClientConfig{
		Address:          kvAddress,
		MaxRetries:       3,
		Logger:           log,
		DisableTelemetry: true,
	}

	log.Info().
		Str("kv_address", kvAddress).
		Str("kv_server_spiffe_id", securityConfig.ServerSPIFFEID).
		Str("kv_trust_domain", securityConfig.TrustDomain).
		Msg("Initializing KV security provider")

	provider, err := grpc.NewSecurityProvider(ctx, securityConfig, log)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create KV security provider: %w", err)
	}

	clientCfg.SecurityProvider = provider

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create KV gRPC client: %w", err)
	}

	conn := client.GetConnection()
	store := &grpcRemoteStore{
		configClient: proto.NewKVServiceClient(conn),
		objectClient: proto.NewDataServiceClient(conn),
		conn:         client,
	}

	if store.configClient == nil {
		if err := client.Close(); err != nil {
			log.Error().Err(err).Msg("Error closing client")
			return nil, nil, err
		}

		return nil, nil, errFailedToInitializeKVClient
	}

	if store.objectClient == nil {
		if err := client.Close(); err != nil {
			log.Error().Err(err).Msg("Error closing client")
			return nil, nil, err
		}

		return nil, nil, ErrDataServiceClientInit
	}

	cfgLoader.SetKVStore(store)

	return store, store, nil
}

func resolveKVConnectionSettings(cfg *ServerConfig) (string, *models.SecurityConfig, error) {
	var kvAddress string
	if cfg != nil {
		kvAddress = strings.TrimSpace(cfg.KVAddress)
	}
	if kvAddress == "" {
		kvAddress = strings.TrimSpace(os.Getenv("KV_ADDRESS"))
	}

	var securityConfig *models.SecurityConfig
	switch {
	case cfg != nil && cfg.KVSecurity != nil:
		securityConfig = cfg.KVSecurity
	case cfg != nil && cfg.Security != nil:
		securityConfig = cfg.Security
	default:
		var err error
		securityConfig, err = kvSecurityFromEnv()
		if err != nil {
			return kvAddress, nil, err
		}
	}

	return kvAddress, securityConfig, nil
}

func kvSecurityFromEnv() (*models.SecurityConfig, error) {
	mode := strings.ToLower(strings.TrimSpace(os.Getenv("KV_SEC_MODE")))
	switch mode {
	case "":
		return nil, nil
	case "spiffe":
		socket := strings.TrimSpace(os.Getenv("KV_WORKLOAD_SOCKET"))
		if socket == "" {
			socket = "unix:/run/spire/sockets/agent.sock"
		}

		return &models.SecurityConfig{
			Mode:           "spiffe",
			CertDir:        strings.TrimSpace(os.Getenv("KV_CERT_DIR")),
			Role:           models.RoleAgent,
			TrustDomain:    strings.TrimSpace(os.Getenv("KV_TRUST_DOMAIN")),
			ServerSPIFFEID: strings.TrimSpace(os.Getenv("KV_SERVER_SPIFFE_ID")),
			WorkloadSocket: socket,
		}, nil
	case "mtls":
		cert := strings.TrimSpace(os.Getenv("KV_CERT_FILE"))
		key := strings.TrimSpace(os.Getenv("KV_KEY_FILE"))
		ca := strings.TrimSpace(os.Getenv("KV_CA_FILE"))
		if cert == "" || key == "" || ca == "" {
			return nil, fmt.Errorf("KV_SEC_MODE=mtls requires KV_CERT_FILE, KV_KEY_FILE, and KV_CA_FILE")
		}

		return &models.SecurityConfig{
			Mode:       "mtls",
			CertDir:    strings.TrimSpace(os.Getenv("KV_CERT_DIR")),
			Role:       models.RoleAgent,
			ServerName: strings.TrimSpace(os.Getenv("KV_SERVER_NAME")),
			TLS: models.TLSConfig{
				CertFile: cert,
				KeyFile:  key,
				CAFile:   ca,
			},
		}, nil
	default:
		return nil, fmt.Errorf("unsupported KV_SEC_MODE %q", mode)
	}
}

// createSweepService constructs a new SweepService instance.
func createSweepService(
	ctx context.Context,
	sweepConfig *SweepConfig,
	configStore KVStore,
	objectStore ObjectStore,
	cfg *ServerConfig,
	log logger.Logger,
) (Service, error) {
	if sweepConfig == nil {
		return nil, errSweepConfigNil
	}

	// Validate required configuration
	if cfg.Partition == "" {
		log.Warn().Msg("Partition not configured, using 'default'. Consider setting partition in agent config")

		cfg.Partition = "default"
	}

	if cfg.AgentID == "" {
		return nil, ErrAgentIDRequired
	}

	c := &models.Config{
		Networks:      sweepConfig.Networks,
		Ports:         sweepConfig.Ports,
		SweepModes:    sweepConfig.SweepModes,
		DeviceTargets: sweepConfig.DeviceTargets,
		Interval:      time.Duration(sweepConfig.Interval),
		Concurrency:   sweepConfig.Concurrency,
		Timeout:       time.Duration(sweepConfig.Timeout),
		AgentID:       cfg.AgentID,
		PollerID:      cfg.AgentID, // Use AgentID as PollerID for now
		Partition:     cfg.Partition,
	}

	// Prioritize AgentID as the unique identifier for the KV path.
	// Fall back to AgentName if AgentID is not set.
	serverName := cfg.AgentName
	if cfg.AgentID != "" {
		serverName = cfg.AgentID
	}

	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", serverName)

	return NewSweepService(ctx, c, configStore, objectStore, configKey, log)
}

func (s *Server) loadSweepService(
	ctx context.Context, cfgLoader *config.Config, kvPath, filePath string,
) (Service, error) {
	var sweepConfig SweepConfig

	// Always load from file first (file config is authoritative)
	if err := cfgLoader.LoadAndValidate(ctx, filePath, &sweepConfig); err != nil {
		// If file doesn't exist, try KV as fallback
		if errors.Is(err, os.ErrNotExist) {
			if service, kvErr := s.tryLoadFromKV(ctx, kvPath, &sweepConfig); kvErr == nil && service != nil {
				s.logger.Info().Str("kvPath", kvPath).Msg("Loaded sweep config from KV (no file found)")
				return service, nil
			}
		}

		return nil, fmt.Errorf("failed to load sweep config from file %s: %w", filePath, err)
	}

	suffix := s.getLogSuffix()
	s.logger.Info().Str("path", filePath).Str("suffix", suffix).Msg("Loaded sweep config from file")

	// Merge KV config updates into file-based config
	if mergedConfig, err := s.mergeKVUpdates(ctx, kvPath, &sweepConfig); err != nil {
		s.logger.Warn().Err(err).Str("kvPath", kvPath).Msg("Failed to merge KV updates, using file config only")
	} else if mergedConfig != nil {
		sweepConfig = *mergedConfig

		s.logger.Info().Str("kvPath", kvPath).Msg("Successfully merged KV updates into file config")
	}

	service, err := s.createSweepService(ctx, &sweepConfig, s.configStore, s.objectStore)
	if err != nil {
		return nil, err
	}

	return service, nil
}

func (s *Server) tryLoadFromKV(ctx context.Context, kvPath string, sweepConfig *SweepConfig) (Service, error) {
	if s.configStore == nil {
		s.logger.Info().Msg("KV store not initialized, skipping KV fetch for sweep config")
		return nil, nil
	}

	value, found, err := s.configStore.Get(ctx, kvPath)
	if err != nil {
		s.logger.Error().Err(err).Str("kvPath", kvPath).Msg("Failed to get sweep config from KV")
		return nil, err
	}

	if !found {
		s.logger.Info().Str("kvPath", kvPath).Msg("Sweep config not found in KV")
		return nil, nil
	}

	var metadata map[string]any
	if err := json.Unmarshal(value, &metadata); err == nil {
		if storage, ok := metadata["storage"].(string); ok && storage == "data_service" {
			objectKey, hasKey := metadata["object_key"].(string)
			switch {
			case !hasKey || objectKey == "":
				return nil, fmt.Errorf("%w: missing object_key (kvPath=%s)", ErrInvalidSweepMetadata, kvPath)
			case s.objectStore == nil:
				return nil, fmt.Errorf("%w: sweep metadata at %s", ErrObjectStoreUnavailable, kvPath)
			}

			objectData, err := s.objectStore.DownloadObject(ctx, objectKey)
			if err != nil {
				return nil, fmt.Errorf("failed to download sweep config object %s: %w", objectKey, err)
			}

			payload := objectData
			if overrides, ok := metadata["overrides"]; ok {
				if merged, mergeErr := mergeSweepConfigOverrides(objectData, overrides); mergeErr != nil {
					s.logger.Warn().Err(mergeErr).Str("object_key", objectKey).Msg("Failed to merge sweep overrides; using base object")
				} else {
					payload = merged
				}
			}

			if err := json.Unmarshal(payload, sweepConfig); err != nil {
				return nil, fmt.Errorf("failed to unmarshal sweep object %s: %w", objectKey, err)
			}

			s.logger.Info().
				Str("kvPath", kvPath).
				Str("object_key", objectKey).
				Int("deviceTargets", len(sweepConfig.DeviceTargets)).
				Msg("Loaded sweep config from DataService object")

			service, err := s.createSweepService(ctx, sweepConfig, s.configStore, s.objectStore)
			if err != nil {
				return nil, fmt.Errorf("failed to create sweep service from DataService config: %w", err)
			}

			return service, nil
		}
	}

	if err = json.Unmarshal(value, sweepConfig); err != nil {
		s.logger.Error().Err(err).Str("kvPath", kvPath).Msg("Failed to unmarshal sweep config from KV")
		return nil, err
	}

	s.logger.Info().Str("kvPath", kvPath).Msg("Loaded sweep config from KV")

	service, err := s.createSweepService(ctx, sweepConfig, s.configStore, s.objectStore)
	if err != nil {
		return nil, fmt.Errorf("failed to create sweep service from KV config: %w", err)
	}

	return service, nil
}

// mergeKVUpdates merges updates from KV store into the file-based config.
// The file config is authoritative, but KV can provide updates (especially networks from sync service).
// mergeStringSlice merges a string slice field from KV config to merged config if needed
func (s *Server) mergeStringSlice(fieldName string, fileValue, kvValue []string, mergedConfig *SweepConfig) {
	// For Networks, always merge if KV has values
	// For other fields, only merge if file value is empty and KV value is not empty
	isNetworks := fieldName == "networks"
	shouldMerge := (len(fileValue) == 0 && len(kvValue) > 0) || (isNetworks && len(kvValue) > 0)

	if shouldMerge {
		// Update the field in mergedConfig
		switch fieldName {
		case "networks":
			mergedConfig.Networks = kvValue
		case "ports":
		}

		// Log the merge
		msg := "Used %s from KV config (not set in file)"
		if isNetworks {
			msg = "Merged %s from KV config"
		}

		s.logger.Info().
			Interface(fieldName, kvValue).
			Msgf(msg, fieldName)
	}
}

// mergeSweepModes merges SweepModes from KV config to merged config if needed
func (s *Server) mergeSweepModes(fileValue, kvValue []models.SweepMode, mergedConfig *SweepConfig) {
	if len(fileValue) == 0 && len(kvValue) > 0 {
		mergedConfig.SweepModes = kvValue
		s.logger.Info().
			Interface("sweep_modes", kvValue).
			Msg("Used sweep_modes from KV config (not set in file)")
	}
}

// mergeDeviceTargets merges DeviceTargets from KV config to merged config
// Always merge device targets from KV since they come from sync service discovery
func (s *Server) mergeDeviceTargets(_, kvValue []models.DeviceTarget, mergedConfig *SweepConfig) {
	if len(kvValue) > 0 {
		mergedConfig.DeviceTargets = kvValue
		s.logger.Info().
			Int("device_target_count", len(kvValue)).
			Msg("Merged device_targets from KV config")
	}
}

// mergeIntSlice merges an int slice field from KV config to merged config if needed
func (s *Server) mergeIntSlice(fieldName string, fileValue, kvValue []int, mergedConfig *SweepConfig) {
	if len(fileValue) == 0 && len(kvValue) > 0 {
		// Update the field in mergedConfig
		if fieldName == "ports" {
			mergedConfig.Ports = kvValue
		}

		s.logger.Info().
			Interface(fieldName, kvValue).
			Msgf("Used %s from KV config (not set in file)", fieldName)
	}
}

// mergeInt merges an int field from KV config to merged config if needed
func (s *Server) mergeInt(fieldName string, fileValue, kvValue int, mergedConfig *SweepConfig) {
	if fileValue == 0 && kvValue > 0 {
		// Update the field in mergedConfig
		if fieldName == "concurrency" {
			mergedConfig.Concurrency = kvValue
		}

		s.logger.Info().
			Int(fieldName, kvValue).
			Msgf("Used %s from KV config (not set in file)", fieldName)
	}
}

// mergeDuration merges a Duration field from KV config to merged config if needed
func (s *Server) mergeDuration(fieldName string, fileValue, kvValue Duration, mergedConfig *SweepConfig) {
	if fileValue == 0 && kvValue > 0 {
		// Update the field in mergedConfig
		switch fieldName {
		case "interval":
			mergedConfig.Interval = kvValue
		case "timeout":
			mergedConfig.Timeout = kvValue
		}

		s.logger.Info().
			Dur(fieldName, time.Duration(kvValue)).
			Msgf("Used %s from KV config (not set in file)", fieldName)
	}
}

func mergeSweepConfigOverrides(base []byte, overrides any) ([]byte, error) {
	if overrides == nil {
		return base, nil
	}

	var baseMap map[string]any
	if err := json.Unmarshal(base, &baseMap); err != nil {
		return nil, err
	}

	overrideBytes, err := json.Marshal(overrides)
	if err != nil {
		return nil, err
	}

	var overrideMap map[string]any
	if err := json.Unmarshal(overrideBytes, &overrideMap); err != nil {
		return nil, err
	}

	merged := mergeMapRecursive(baseMap, overrideMap)
	return json.Marshal(merged)
}

func mergeMapRecursive(dst, src map[string]any) map[string]any {
	for k, v := range src {
		if srcMap, ok := v.(map[string]any); ok {
			if dstMap, ok := dst[k].(map[string]any); ok {
				dst[k] = mergeMapRecursive(dstMap, srcMap)
			} else {
				dst[k] = srcMap
			}
			continue
		}

		dst[k] = v
	}

	return dst
}

func (s *Server) mergeKVUpdates(ctx context.Context, kvPath string, fileConfig *SweepConfig) (*SweepConfig, error) {
	s.logger.Info().Str("kvPath", kvPath).Msg("*** ENHANCED DEBUG VERSION: mergeKVUpdates called ***")

	if s.configStore == nil {
		s.logger.Debug().Msg("KV store not initialized, skipping merge")
		return nil, nil
	}

	kvValue, found, err := s.configStore.Get(ctx, kvPath)
	if err != nil {
		return nil, fmt.Errorf("failed to get config from KV store: %w", err)
	}

	if !found {
		s.logger.Debug().Str("kvPath", kvPath).Msg("No KV config found, using file config only")
		return nil, nil
	}

	var (
		objectConfig   *SweepConfig
		overrideConfig *SweepConfig
	)

	var metadata map[string]interface{}
	isDataService := false

	if err := json.Unmarshal(kvValue, &metadata); err == nil {
		s.logger.Info().Interface("metadataCheck", metadata).Msg("DEBUG: Unmarshaled KV value")

		if storage, ok := metadata["storage"].(string); ok && storage == "data_service" {
			isDataService = true

			objectKey, hasKey := metadata["object_key"].(string)
			switch {
			case !hasKey || objectKey == "":
				s.logger.Warn().Str("kvPath", kvPath).Msg("Invalid sweep metadata: missing object_key for DataService storage")
			case s.objectStore == nil:
				s.logger.Warn().
					Str("kvPath", kvPath).
					Str("object_key", objectKey).
					Msg("Object store client unavailable; cannot download sweep config object")
			default:
				objectData, downloadErr := s.objectStore.DownloadObject(ctx, objectKey)
				if downloadErr != nil {
					if errors.Is(downloadErr, errDataServiceUnavailable) {
						s.logger.Warn().
							Str("kvPath", kvPath).
							Str("object_key", objectKey).
							Msg("DataService object unavailable; continuing without sweep object overlay")
					} else {
						return nil, fmt.Errorf("failed to download sweep config object %s: %w", objectKey, downloadErr)
					}
				} else {
					expectedSHA, _ := metadata["sha256"].(string)
					actualHash := sha256.Sum256(objectData)
					actualSHA := hex.EncodeToString(actualHash[:])

					if expectedSHA != "" {
						if canonicalSHA, err := hashutil.CanonicalHexSHA256(expectedSHA); err != nil {
							s.logger.Warn().
								Str("kvPath", kvPath).
								Str("object_key", objectKey).
								Str("expected_sha_raw", expectedSHA).
								Str("actual_sha", actualSHA).
								Err(err).
								Msg("Failed to parse expected checksum for sweep config object")
						} else if !strings.EqualFold(canonicalSHA, actualSHA) {
							s.logger.Warn().
								Str("kvPath", kvPath).
								Str("object_key", objectKey).
								Str("expected_sha", canonicalSHA).
								Str("actual_sha", actualSHA).
								Msg("Checksum mismatch for sweep config object")
						}
					}

					var oc SweepConfig
					if err := json.Unmarshal(objectData, &oc); err != nil {
						return nil, fmt.Errorf("failed to unmarshal sweep config object: %w", err)
					}

					objectConfig = &oc
				}
			}

			if rawOverrides, ok := metadata["overrides"]; ok {
				if overrideBytes, err := json.Marshal(rawOverrides); err != nil {
					s.logger.Warn().Err(err).Msg("Failed to encode sweep overrides from metadata")
				} else {
					var oc SweepConfig
					if err := json.Unmarshal(overrideBytes, &oc); err != nil {
						s.logger.Warn().Err(err).Msg("Failed to unmarshal sweep overrides from metadata")
					} else {
						overrideConfig = &oc
					}
				}
			}
		}
	}

	mergedConfig := *fileConfig

	var kvConfig *SweepConfig
	if !isDataService {
		var cfg SweepConfig
		if err := json.Unmarshal(kvValue, &cfg); err != nil {
			return nil, fmt.Errorf("failed to unmarshal KV config: %w", err)
		}
		kvConfig = &cfg
	}

	mergeFromConfig := func(source *SweepConfig) {
		if source == nil {
			return
		}

		s.mergeStringSlice("networks", mergedConfig.Networks, source.Networks, &mergedConfig)
		s.mergeIntSlice("ports", mergedConfig.Ports, source.Ports, &mergedConfig)
		s.mergeSweepModes(mergedConfig.SweepModes, source.SweepModes, &mergedConfig)
		s.mergeDeviceTargets(mergedConfig.DeviceTargets, source.DeviceTargets, &mergedConfig)
		s.mergeInt("concurrency", mergedConfig.Concurrency, source.Concurrency, &mergedConfig)
		s.mergeDuration("interval", mergedConfig.Interval, source.Interval, &mergedConfig)
		s.mergeDuration("timeout", mergedConfig.Timeout, source.Timeout, &mergedConfig)
	}

	mergeFromConfig(kvConfig)
	mergeFromConfig(overrideConfig)

	if objectConfig != nil {
		s.logger.Info().
			Int("device_target_count", len(objectConfig.DeviceTargets)).
			Msg("Merged device targets from DataService object")

		s.mergeStringSlice("networks", mergedConfig.Networks, objectConfig.Networks, &mergedConfig)
		s.mergeDeviceTargets(mergedConfig.DeviceTargets, objectConfig.DeviceTargets, &mergedConfig)
		s.mergeSweepModes(mergedConfig.SweepModes, objectConfig.SweepModes, &mergedConfig)
	}

	return &mergedConfig, nil
}

func (s *Server) loadConfigurations(ctx context.Context, cfgLoader *config.Config) error {
	if err := s.loadCheckerConfigs(ctx, cfgLoader); err != nil {
		return fmt.Errorf("failed to load checker configs: %w", err)
	}

	// Define paths for sweep config
	fileSweepConfigPath := filepath.Join(s.configDir, sweepType, "sweep.json")

	// Prioritize AgentID as the unique identifier for the KV path.
	// Fall back to AgentName if AgentID is not set.
	serverName := s.config.AgentName // Default to AgentName
	if s.config.AgentID != "" {
		serverName = s.config.AgentID // Prefer AgentID
	}

	if serverName == "" {
		s.logger.Warn().Msg("agent_id and agent_name are not set. KV paths for sweep config will be incorrect.")
	}

	kvSweepConfigPath := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", serverName)

	// Load sweep service
	service, err := s.loadSweepService(ctx, cfgLoader, kvSweepConfigPath, fileSweepConfigPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("failed to load sweep service: %w", err)
	}

	if service != nil {
		s.services = append(s.services, service)
	}

	return nil
}

// getLogSuffix returns appropriate suffix based on KV store availability.
func (s *Server) getLogSuffix() string {
	if s.configStore != nil {
		return " " + fallBackSuffix
	}

	return ""
}

// Start initializes and starts all agent services.
func (s *Server) Start(ctx context.Context) error {
	s.logger.Info().Msg("Starting agent service...")

	if err := s.initializeCheckers(ctx); err != nil {
		return fmt.Errorf("failed to initialize checkers: %w", err)
	}

	s.logger.Info().Int("services", len(s.services)).Msg("Found services to start")

	for i, svc := range s.services {
		s.logger.Info().Int("index", i).Str("service", svc.Name()).Msg("Starting service")

		go func(svc Service) { // Run in goroutine to avoid blocking
			if err := svc.Start(ctx); err != nil {
				s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to start service")
			} else {
				s.logger.Info().Str("service", svc.Name()).Msg("Service started successfully")
			}
		}(svc)
	}

	return nil
}

// Stop gracefully shuts down all agent services.
func (s *Server) Stop(_ context.Context) error {
	s.logger.Info().Msg("Stopping agent service...")

	for _, svc := range s.services {
		if err := svc.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to stop service")
		}
	}

	for name, conn := range s.connections {
		if err := conn.client.Close(); err != nil {
			s.logger.Error().Err(err).Str("checker", name).Msg("Error closing connection to checker")
		}
	}

	close(s.done)

	return nil
}

// UpdateConfig applies logging/security updates at runtime where possible.
// Security changes typically require a restart to fully apply to gRPC servers/clients.
func (s *Server) UpdateConfig(newCfg *ServerConfig) {
	if newCfg == nil {
		return
	}
	// Apply logging level changes if provided
	if newCfg.Logging != nil {
		lvl := strings.ToLower(newCfg.Logging.Level)
		switch lvl {
		case "debug":
			s.logger.SetDebug(true)
		case "info", "":
			s.logger.SetDebug(false)
		}
		s.logger.Info().Str("level", newCfg.Logging.Level).Msg("Agent logger level updated")
	}
	// Security changes: log advisory; full restart may be required
	if newCfg.Security != nil && s.config.Security != nil {
		// naive compare of cert paths
		if newCfg.Security.TLS != s.config.Security.TLS || newCfg.Security.Mode != s.config.Security.Mode {
			s.logger.Warn().Msg("Security config changed; restart recommended to apply TLS changes")
		}
	}
	s.config = newCfg
}

// RestartServices stops and starts all managed services using the current configuration.
func (s *Server) RestartServices(ctx context.Context) {
	s.logger.Info().Msg("Restarting agent services due to config changes")
	for _, svc := range s.services {
		if err := svc.Stop(ctx); err != nil {
			s.logger.Warn().Err(err).Str("service", svc.Name()).Msg("Failed to stop service during restart")
		}
	}
	for _, svc := range s.services {
		if err := svc.Start(ctx); err != nil {
			s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to start service during restart")
		} else {
			s.logger.Info().Str("service", svc.Name()).Msg("Service restarted")
		}
	}
}

// ListenAddr returns the server's listening address.
func (s *Server) ListenAddr() string {
	return s.config.ListenAddr
}

// SecurityConfig returns the server's security configuration.
func (s *Server) SecurityConfig() *models.SecurityConfig {
	return s.config.Security
}

// Error implements the error interface for ServiceError.
func (e *ServiceError) Error() string {
	return fmt.Sprintf("service %s error: %v", e.ServiceName, e.Err)
}

func (s *Server) initializeCheckers(ctx context.Context) error {
	files, err := os.ReadDir(s.configDir)
	if err != nil {
		return fmt.Errorf("failed to read config directory: %w", err)
	}

	s.connections = make(map[string]*CheckerConnection)

	cfgLoader := config.NewConfig(s.logger)

	if s.configStore != nil {
		cfgLoader.SetKVStore(s.configStore)
	}

	for _, file := range files {
		if filepath.Ext(file.Name()) != jsonSuffix {
			continue
		}

		filePath := filepath.Join(s.configDir, file.Name())

		conf, err := s.loadCheckerConfig(ctx, cfgLoader, filePath)
		if err != nil {
			s.logger.Warn().Err(err).Str("file", file.Name()).Msg("Failed to load checker config")

			continue
		}

		// Validate required fields
		if conf.Name == "" {
			s.logger.Warn().Str("file", file.Name()).Msg("Skipping checker config with empty name")
			continue
		}

		if conf.Type == "" {
			s.logger.Warn().Str("file", file.Name()).Str("name", conf.Name).Msg("Skipping checker config with empty type")
			continue
		}

		if conf.Type == grpcType {
			conn, err := s.connectToChecker(ctx, conf)
			if err != nil {
				s.logger.Warn().Err(err).Str("checker", conf.Name).Msg("Failed to connect to checker")
				continue
			}

			s.connections[conf.Name] = conn
		}

		s.checkerConfs[conf.Name] = conf

		s.logger.Info().Str("name", conf.Name).Str("type", conf.Type).Msg("Loaded checker config")
	}

	return nil
}

// EnsureConnected ensures the connection is healthy and returns the gRPC client.
func (c *CheckerConnection) EnsureConnected(ctx context.Context) (*grpc.Client, error) {
	c.mu.RLock()

	if c.healthy && c.client != nil {
		c.mu.RUnlock()
		return c.client, nil
	}

	c.mu.RUnlock()

	c.mu.Lock()
	defer c.mu.Unlock()

	// Double-check after locking
	if c.healthy && c.client != nil {
		return c.client, nil
	}

	// Close existing connection if it exists
	if c.client != nil {
		_ = c.client.Close()
	}

	clientCfg := grpc.ClientConfig{
		Address:    c.address,
		MaxRetries: 3,
		Logger:     c.logger,
	}

	// Add security provider as needed
	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		c.healthy = false

		return nil, fmt.Errorf("failed to reconnect to %s: %w", c.serviceName, err)
	}

	c.client = client
	c.healthy = true

	return client, nil
}

func (s *Server) connectToChecker(ctx context.Context, checkerConfig *CheckerConfig) (*CheckerConnection, error) {
	clientCfg := grpc.ClientConfig{
		Address:    checkerConfig.Address,
		MaxRetries: 3,
		Logger:     s.logger,
	}

	securityConfig := checkerConfig.Security
	if securityConfig == nil {
		securityConfig = s.config.Security
	}

	if securityConfig != nil {
		provider, err := grpc.NewSecurityProvider(ctx, securityConfig, s.logger)
		if err != nil {
			return nil, fmt.Errorf("failed to create security provider: %w", err)
		}

		clientCfg.SecurityProvider = provider
	}

	s.logger.Info().Str("service", checkerConfig.Name).Str("address", checkerConfig.Address).Msg("Connecting to checker service")

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to checker %s: %w", checkerConfig.Name, err)
	}

	return &CheckerConnection{
		client:      client,
		serviceName: checkerConfig.Name,
		serviceType: checkerConfig.Type,
		address:     checkerConfig.Address,
		logger:      s.logger,
	}, nil
}

// GetStatus handles status requests for various service types.
func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	// Ensure AgentId and PollerId are set
	if req.AgentId == "" {
		req.AgentId = s.config.AgentID
	}

	if req.PollerId == "" {
		s.logger.Warn().Interface("request", req).Msg("PollerId is empty in request")
		req.PollerId = "unknown-poller" // Fallback to avoid empty
	}

	var response *proto.StatusResponse

	switch {
	case isRperfCheckerRequest(req):
		response, _ = s.handleRperfChecker(ctx, req)
	case isICMPRequest(req):
		response, _ = s.handleICMPCheck(ctx, req)
	case isSweepRequest(req):
		response, _ = s.getSweepStatus(ctx)
	default:
		response, _ = s.handleDefaultChecker(ctx, req)
	}

	// Include AgentID in the response
	if response != nil {
		response.AgentId = s.config.AgentID
		if response.PollerId == "" {
			response.PollerId = req.PollerId
		}

		response.Available = true
	}

	return response, nil
}

// GetResults implements the AgentService GetResults method.
// For grpc services, this forwards the call to the actual service.
// For sweep services, this calls the local sweep service.
// For other services, this returns a "not supported" response.
// GetResults handles results requests for various service types.
func (s *Server) GetResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.logger.Info().Str("serviceName", req.ServiceName).Str("serviceType", req.ServiceType).Msg("GetResults called")

	// Handle sweep services with local implementation
	if req.ServiceType == sweepType {
		return s.handleSweepGetResults(ctx, req)
	}

	// Handle grpc services by forwarding the call
	if req.ServiceType == grpcType {
		return s.handleGrpcGetResults(ctx, req)
	}

	// For non-grpc services, return "not supported"
	s.logger.Info().Str("serviceType", req.ServiceType).Msg("GetResults not supported for service type")

	return nil, status.Errorf(codes.Unimplemented, "GetResults not supported for service type '%s'", req.ServiceType)
}

// handleGrpcGetResults forwards GetResults calls to grpc services.
// This works similarly to handleDefaultChecker but for GetResults calls.
func (s *Server) handleGrpcGetResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	// Convert ResultsRequest to StatusRequest to reuse existing getChecker logic
	statusReq := &proto.StatusRequest{
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
		AgentId:     req.AgentId,
		PollerId:    req.PollerId,
		Details:     req.Details,
	}

	// Use the same getChecker lookup logic as GetStatus
	statusReq.AgentId = s.config.AgentID

	getChecker, err := s.getChecker(ctx, statusReq)
	if err != nil {
		s.logger.Error().Err(err).Str("serviceName", req.ServiceName).Msg("Failed to get getChecker for service")

		return &proto.ResultsResponse{
			Available:   false,
			Data:        []byte(fmt.Sprintf(`{"error": "Failed to get getChecker: %v"}`, err)),
			ServiceName: req.ServiceName,
			ServiceType: req.ServiceType,
			AgentId:     s.config.AgentID,
			PollerId:    req.PollerId,
			Timestamp:   time.Now().Unix(),
		}, nil
	}

	// For grpc checkers, we need to call GetResults on the underlying service
	// First check if the getChecker is a grpc getChecker that supports GetResults
	if externalChecker, ok := getChecker.(*ExternalChecker); ok {
		// Forward GetResults to the external grpc service
		s.logger.Info().Str("serviceName", req.ServiceName).Str("details", req.Details).Msg("Forwarding GetResults call to service")

		err := externalChecker.ensureConnected(ctx)
		if err != nil {
			s.logger.Error().Err(err).Str("serviceName", req.ServiceName).Msg("Failed to connect to grpc service")

			return &proto.ResultsResponse{
				Available:   false,
				Data:        []byte(fmt.Sprintf(`{"error": "Failed to connect to service: %v"}`, err)),
				ServiceName: req.ServiceName,
				ServiceType: req.ServiceType,
				AgentId:     s.config.AgentID,
				PollerId:    req.PollerId,
				Timestamp:   time.Now().Unix(),
			}, nil
		}

		grpcClient := proto.NewAgentServiceClient(externalChecker.grpcClient.GetConnection())

		// Forward the GetResults call
		response, err := grpcClient.GetResults(ctx, req)
		if err != nil {
			s.logger.Error().Err(err).Str("serviceName", req.ServiceName).Msg("GetResults call to service failed")

			return &proto.ResultsResponse{
				Available:   false,
				Data:        []byte(fmt.Sprintf(`{"error": "GetResults call failed: %v"}`, err)),
				ServiceName: req.ServiceName,
				ServiceType: req.ServiceType,
				AgentId:     s.config.AgentID,
				PollerId:    req.PollerId,
				Timestamp:   time.Now().Unix(),
			}, nil
		}

		return response, nil
	}

	// If it's not a grpc getChecker, return not supported
	s.logger.Info().Str("checkerType", fmt.Sprintf("%T", getChecker)).Msg("GetResults not supported for getChecker type")

	return nil, status.Errorf(codes.Unimplemented, "GetResults not supported by getChecker type %T", getChecker)
}

// StreamResults implements the AgentService StreamResults method for large datasets.
// For sweep services, this calls the local sweep service and streams the results.
// For grpc services, this forwards the streaming call to the actual service.
// For other services, this returns a "not supported" response.
// StreamResults handles streaming results requests for large datasets.
func (s *Server) StreamResults(req *proto.ResultsRequest, stream proto.AgentService_StreamResultsServer) error {
	s.logger.Info().Str("serviceName", req.ServiceName).Str("serviceType", req.ServiceType).Msg("StreamResults called")

	// Handle sweep services with local implementation
	if req.ServiceType == sweepType {
		return s.handleSweepStreamResults(req, stream)
	}

	// Handle grpc services by forwarding the call
	if req.ServiceType == grpcType {
		return s.handleGrpcStreamResults(req, stream)
	}

	// For non-grpc services, return "not supported"
	s.logger.Info().Str("serviceType", req.ServiceType).Msg("StreamResults not supported for service type")

	return status.Errorf(codes.Unimplemented, "StreamResults not supported for service type '%s'", req.ServiceType)
}

// handleGrpcStreamResults forwards StreamResults calls to grpc services.
func (s *Server) handleGrpcStreamResults(req *proto.ResultsRequest, stream proto.AgentService_StreamResultsServer) error {
	ctx := stream.Context()

	// Convert ResultsRequest to StatusRequest to reuse existing getChecker logic
	statusReq := &proto.StatusRequest{
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
		AgentId:     req.AgentId,
		PollerId:    req.PollerId,
		Details:     req.Details,
	}

	statusReq.AgentId = s.config.AgentID

	getChecker, err := s.getChecker(ctx, statusReq)
	if err != nil {
		s.logger.Error().Err(err).Str("serviceName", req.ServiceName).Msg("Failed to get checker for StreamResults")
		return status.Errorf(codes.Internal, "Failed to get checker: %v", err)
	}

	externalChecker, ok := getChecker.(*ExternalChecker)
	if !ok {
		s.logger.Info().
			Str("checkerType", fmt.Sprintf("%T", getChecker)).
			Msg("StreamResults not supported for checker type")
		return status.Errorf(
			codes.Unimplemented, "StreamResults not supported by checker type %T", getChecker,
		)
	}

	// Ensure connection to the external service
	if connectErr := externalChecker.ensureConnected(ctx); connectErr != nil {
		s.logger.Error().Err(connectErr).Str("serviceName", req.ServiceName).Msg("Failed to connect to grpc service for StreamResults")
		return status.Errorf(codes.Unavailable, "Failed to connect to service: %v", connectErr)
	}

	grpcClient := proto.NewAgentServiceClient(externalChecker.grpcClient.GetConnection())

	// Forward the StreamResults call
	upstreamStream, err := grpcClient.StreamResults(ctx, req)
	if err != nil {
		s.logger.Error().Err(err).Str("serviceName", req.ServiceName).Msg("StreamResults call to service failed")
		return status.Errorf(codes.Internal, "StreamResults call failed: %v", err)
	}

	// Forward all chunks from upstream to downstream
	for {
		chunk, err := upstreamStream.Recv()

		if errors.Is(err, io.EOF) {
			break
		}

		if err != nil {
			s.logger.Error().Err(err).Str("serviceName", req.ServiceName).Msg("Error receiving chunk from upstream")
			return status.Errorf(codes.Internal, "Error receiving chunk: %v", err)
		}

		if err := stream.Send(chunk); err != nil {
			s.logger.Error().Err(err).Str("serviceName", req.ServiceName).Msg("Error sending chunk downstream")
			return status.Errorf(codes.Internal, "Error sending chunk: %v", err)
		}
	}

	s.logger.Info().Str("serviceName", req.ServiceName).Msg("StreamResults forwarding completed")

	return nil
}

// findSweepService finds the first sweep service from the server's services
func (s *Server) findSweepService() *SweepService {
	for _, svc := range s.services {
		if sweepSvc, ok := svc.(*SweepService); ok {
			return sweepSvc
		}
	}

	return nil
}

// sendEmptyChunk sends an empty final chunk when there's no new data
func (*Server) sendEmptyChunk(stream proto.AgentService_StreamResultsServer, response *proto.ResultsResponse) error {
	return stream.Send(&proto.ResultsChunk{
		Data:            []byte("{}"),
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: response.CurrentSequence,
		Timestamp:       response.Timestamp,
	})
}

// sendSingleChunk sends a single chunk when data fits in one chunk
func (*Server) sendSingleChunk(stream proto.AgentService_StreamResultsServer, response *proto.ResultsResponse) error {
	return stream.Send(&proto.ResultsChunk{
		Data:            response.Data,
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: response.CurrentSequence,
		Timestamp:       response.Timestamp,
	})
}

// streamMultipleChunks handles streaming when data needs to be split into multiple chunks
func (s *Server) streamMultipleChunks(
	stream proto.AgentService_StreamResultsServer,
	response *proto.ResultsResponse,
	sweepData map[string]interface{},
	hosts []interface{},
) error {
	const maxHostsPerChunk = 1000

	totalHosts := len(hosts)
	totalChunks := (totalHosts + maxHostsPerChunk - 1) / maxHostsPerChunk

	for chunkIndex := 0; chunkIndex < totalChunks; chunkIndex++ {
		start := chunkIndex * maxHostsPerChunk
		end := start + maxHostsPerChunk

		if end > totalHosts {
			end = totalHosts
		}

		// Create chunk with complete host elements and preserve metadata
		chunkHosts := hosts[start:end]

		// Create a new sweep data object with the same metadata but subset of hosts
		chunkData := make(map[string]interface{})

		for key, value := range sweepData {
			if key != "hosts" {
				chunkData[key] = value
			}
		}

		chunkData["hosts"] = chunkHosts

		chunkBytes, err := json.Marshal(chunkData)
		if err != nil {
			s.logger.Error().Err(err).Int("chunk", chunkIndex).Msg("Failed to marshal chunk data")
			return status.Errorf(codes.Internal, "Failed to send chunk: %v", err)
		}

		chunk := &proto.ResultsChunk{
			Data:            chunkBytes,
			IsFinal:         chunkIndex == totalChunks-1,
			ChunkIndex:      safeIntToInt32(chunkIndex),
			TotalChunks:     safeIntToInt32(totalChunks),
			CurrentSequence: response.CurrentSequence,
			Timestamp:       response.Timestamp,
		}

		if err := stream.Send(chunk); err != nil {
			s.logger.Error().Err(err).Int("chunk", chunkIndex).Msg("Error sending sweep results chunk")
			return status.Errorf(codes.Internal, "Failed to send chunk: %v", err)
		}
	}

	s.logger.Info().
		Int("total_chunks", totalChunks).
		Int("total_hosts", totalHosts).
		Str("sequence", response.CurrentSequence).
		Msg("Completed streaming sweep results")

	return nil
}

// handleSweepStreamResults handles StreamResults calls for sweep services with chunking for large datasets.
func (s *Server) handleSweepStreamResults(req *proto.ResultsRequest, stream proto.AgentService_StreamResultsServer) error {
	s.logger.Info().Str("serviceName", req.ServiceName).Str("lastSequence", req.LastSequence).Msg("Handling sweep StreamResults")

	// Find the sweep service
	sweepSvc := s.findSweepService()

	if sweepSvc == nil {
		s.logger.Error().Msg("No sweep service found for StreamResults")
		return status.Errorf(codes.NotFound, "No sweep service configured")
	}

	ctx := stream.Context()

	response, err := sweepSvc.GetSweepResults(ctx, req.LastSequence)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to get sweep results for streaming")
		return status.Errorf(codes.Internal, "Failed to get sweep results: %v", err)
	}

	// Set AgentId and PollerId from the request
	response.AgentId = s.config.AgentID
	response.PollerId = req.PollerId

	// If no new data, send empty final chunk
	if !response.HasNewData || len(response.Data) == 0 {
		return s.sendEmptyChunk(stream, response)
	}

	// Calculate chunk size to keep each chunk under ~1MB
	const maxChunkSize = 1024 * 1024 // 1MB

	totalBytes := len(response.Data)

	if totalBytes <= maxChunkSize {
		// Single chunk case
		return s.sendSingleChunk(stream, response)
	}

	// Multi-chunk case: Parse JSON and chunk by complete elements to avoid corruption
	var sweepData map[string]interface{}
	if err := json.Unmarshal(response.Data, &sweepData); err != nil {
		s.logger.Error().Err(err).Msg("Failed to parse sweep data for chunking")
		return status.Errorf(codes.Internal, "Failed to parse sweep data: %v", err)
	}

	// Extract hosts array from the sweep data
	hostsInterface, ok := sweepData["hosts"]
	if !ok {
		s.logger.Error().Msg("No hosts field found in sweep data")
		return status.Errorf(codes.Internal, "No hosts field found in sweep data")
	}

	hosts, ok := hostsInterface.([]interface{})
	if !ok {
		s.logger.Error().Msg("Hosts field is not an array")
		return status.Errorf(codes.Internal, "Hosts field is not an array")
	}

	return s.streamMultipleChunks(stream, response, sweepData, hosts)
}

// handleSweepGetResults handles GetResults calls for sweep services.
func (s *Server) handleSweepGetResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.logger.Info().Str("serviceName", req.ServiceName).Str("lastSequence", req.LastSequence).Msg("Handling sweep GetResults")

	// Find the sweep service
	for _, svc := range s.services {
		sweepSvc, ok := svc.(*SweepService)
		if !ok {
			continue
		}

		response, err := sweepSvc.GetSweepResults(ctx, req.LastSequence)
		if err != nil {
			s.logger.Error().Err(err).Msg("Failed to get sweep results")

			return &proto.ResultsResponse{
				Available:   false,
				Data:        []byte(fmt.Sprintf(`{"error": "Failed to get sweep results: %v"}`, err)),
				ServiceName: req.ServiceName,
				ServiceType: req.ServiceType,
				AgentId:     s.config.AgentID,
				PollerId:    req.PollerId,
				Timestamp:   time.Now().Unix(),
			}, nil
		}

		// Set AgentId and PollerId from the request
		response.AgentId = s.config.AgentID
		response.PollerId = req.PollerId

		return response, nil
	}

	s.logger.Error().Msg("No sweep service found")

	return &proto.ResultsResponse{
		Available:   false,
		Data:        []byte(`{"error": "No sweep service configured"}`),
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
		AgentId:     s.config.AgentID,
		PollerId:    req.PollerId,
		Timestamp:   time.Now().Unix(),
	}, nil
}

func isRperfCheckerRequest(req *proto.StatusRequest) bool {
	return req.ServiceName == "rperf-checker" && req.ServiceType == grpcType
}

func isICMPRequest(req *proto.StatusRequest) bool {
	return req.ServiceType == "icmp" && req.Details != ""
}

func isSweepRequest(req *proto.StatusRequest) bool {
	return req.ServiceType == sweepType
}

var (
	errNotExternalChecker = errors.New("checker is not an ExternalChecker")
)

func (s *Server) handleRperfChecker(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	c, err := s.getChecker(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("failed to get rperf checker: %w", err)
	}

	extChecker, ok := c.(*ExternalChecker)
	if !ok {
		return nil, errNotExternalChecker
	}

	if err := extChecker.ensureConnected(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Failed to ensure connection for rperf-checker")

		return nil, fmt.Errorf("failed to ensure rperf-checker connection: %w", err)
	}

	agentClient := proto.NewAgentServiceClient(extChecker.grpcClient.GetConnection())

	return agentClient.GetStatus(ctx, &proto.StatusRequest{
		ServiceName: "",
		ServiceType: grpcType,
		Details:     "",
		AgentId:     s.config.AgentID,
	})
}

func (s *Server) handleICMPCheck(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	for _, svc := range s.services {
		sweepSvc, ok := svc.(*SweepService)
		if !ok {
			continue
		}

		result, err := sweepSvc.CheckICMP(ctx, req.Details)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", errICMPCheck, err)
		}

		resp := &ICMPResponse{
			Host:         result.Target.Host,
			ResponseTime: result.RespTime.Nanoseconds(),
			PacketLoss:   result.PacketLoss,
			Available:    result.Available,
		}

		jsonResp, _ := json.Marshal(resp)

		return &proto.StatusResponse{
			Available:    result.Available,
			Message:      jsonResp,
			ServiceName:  "icmp_check",
			ServiceType:  "icmp",
			ResponseTime: result.RespTime.Nanoseconds(),
			AgentId:      s.config.AgentID,
		}, nil
	}

	return nil, errNoSweepService
}

func (s *Server) handleDefaultChecker(
	ctx context.Context, req *proto.StatusRequest,
) (*proto.StatusResponse, error) {
	req.AgentId = s.config.AgentID

	c, err := s.getChecker(ctx, req)
	if err != nil {
		return nil, err
	}

	available, message := c.Check(ctx, req)

	s.logger.Info().Str("type", req.GetServiceType()).Str("name", req.GetServiceName()).Str("details", req.GetDetails()).Msg("Checker request")

	if !json.Valid(message) {
		s.logger.Error().Str("serviceName", req.ServiceName).RawJSON("message", message).Msg("Invalid JSON from checker")
		return nil, errInvalidJSONResponse
	}

	return &proto.StatusResponse{
		Available:   available,
		Message:     message, // json.RawMessage is []byte
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
		AgentId:     req.AgentId,
		PollerId:    req.PollerId,
	}, nil
}

func (s *Server) getSweepStatus(ctx context.Context) (*proto.StatusResponse, error) {
	for _, svc := range s.services {
		if provider, ok := svc.(SweepStatusProvider); ok {
			return provider.GetStatus(ctx)
		}
	}

	message := jsonError("No sweep service configured")

	return &proto.StatusResponse{
		Available:   false,
		Message:     message,
		ServiceName: "network_sweep",
		ServiceType: sweepType,
		AgentId:     s.config.AgentID,
	}, nil
}

func (s *Server) loadCheckerConfig(ctx context.Context, cfgLoader *config.Config, filePath string) (*CheckerConfig, error) {
	var conf CheckerConfig

	// Determine KV path
	kvPath := filepath.Base(filePath)
	if s.config.AgentID != "" {
		kvPath = fmt.Sprintf("agents/%s/checkers/%s", s.config.AgentID, filepath.Base(filePath))
	}

	// Try KV if available
	var err error

	if s.configStore != nil {
		if err = cfgLoader.LoadAndValidate(ctx, kvPath, &conf); err == nil {
			s.logger.Info().Str("kvPath", kvPath).Msg("Loaded checker config from KV")

			return s.applyCheckerDefaults(&conf), nil
		}

		s.logger.Error().Err(err).Str("kvPath", kvPath).Msg("Failed to load checker config from KV")
	}

	// Load from file (either directly or as fallback)
	if err = cfgLoader.LoadAndValidate(ctx, filePath, &conf); err != nil {
		return nil, fmt.Errorf("failed to load checker config %s: %w", filePath, err)
	}

	suffix := ""
	if s.configStore != nil {
		suffix = " " + fallBackSuffix
	}

	s.logger.Info().Str("filePath", filePath).Str("suffix", suffix).Msg("Loaded checker config from file")

	return s.applyCheckerDefaults(&conf), nil
}

// applyCheckerDefaults sets default values for a CheckerConfig.
func (*Server) applyCheckerDefaults(conf *CheckerConfig) *CheckerConfig {
	if conf.Timeout == 0 {
		conf.Timeout = Duration(defaultTimeout)
	}

	if conf.Type == grpcType && conf.Address == "" {
		conf.Address = conf.ListenAddr
	}

	return conf
}

func (s *Server) loadCheckerConfigs(ctx context.Context, cfgLoader *config.Config) error {
	files, err := os.ReadDir(s.configDir)
	if err != nil {
		return fmt.Errorf("failed to read config directory: %w", err)
	}

	for _, file := range files {
		if filepath.Ext(file.Name()) != jsonSuffix {
			continue
		}

		filePath := filepath.Join(s.configDir, file.Name())

		conf, err := s.loadCheckerConfig(ctx, cfgLoader, filePath)
		if err != nil {
			s.logger.Warn().Err(err).Str("file", file.Name()).Msg("Failed to load checker config")

			continue
		}

		// Validate required fields
		if conf.Name == "" {
			s.logger.Warn().Str("file", file.Name()).Msg("Skipping checker config with empty name")
			continue
		}

		if conf.Type == "" {
			s.logger.Warn().Str("file", file.Name()).Str("name", conf.Name).Msg("Skipping checker config with empty type")
			continue
		}

		s.checkerConfs[conf.Name] = conf

		s.logger.Info().Str("name", conf.Name).Str("type", conf.Type).Msg("Loaded checker config")
	}

	return nil
}

func (s *Server) getChecker(ctx context.Context, req *proto.StatusRequest) (checker.Checker, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := fmt.Sprintf("%s:%s:%s", req.GetServiceType(), req.GetServiceName(), req.GetDetails())

	if check, exists := s.checkers[key]; exists {
		return check, nil
	}

	var check checker.Checker

	var err error

	if req.ServiceType == "icmp" {
		s.logger.Info().Str("host", req.Details).Msg("ICMP checker requested")

		host := req.Details
		if host == "" {
			host = "127.0.0.1"
		}

		// Construct device ID for the TARGET being pinged (partition:target_ip)
		var deviceID string

		if s.config.Partition != "" {
			deviceID = fmt.Sprintf("%s:%s", s.config.Partition, s.config.HostIP)
			s.logger.Info().
				Str("deviceID", deviceID).
				Str("partition", s.config.Partition).
				Str("targetIP", host).
				Msg("Creating ICMP checker with target device ID")
		} else {
			s.logger.Info().Str("partition", s.config.Partition).Msg("Creating ICMP checker without device ID - missing partition")
		}

		check, err = NewICMPCheckerWithDeviceID(host, deviceID, s.logger)
	} else {
		// Use registry for other service types
		checkSecurity := s.config.Security

		// Datasvc health checks should reuse the dedicated KV security block so the
		// agent dials the SPIFFE-enabled service with the correct trust settings.
		if req.ServiceName == "kv" && s.config.KVSecurity != nil {
			checkSecurity = s.config.KVSecurity
		}

		if conf, exists := s.checkerConfs[req.ServiceName]; exists && conf.Security != nil {
			s.logger.Info().
				Str("service", req.ServiceName).
				Str("service_type", req.ServiceType).
				Str("security_mode", string(conf.Security.Mode)).
				Msg("Using checker-specific security configuration")

			checkSecurity = conf.Security
		}

		check, err = s.registry.Get(ctx, req.ServiceType, req.ServiceName, req.Details, checkSecurity)
	}

	if err != nil {
		s.logger.Error().Err(err).Str("key", key).Msg("Failed to create checker")
		return nil, fmt.Errorf("failed to create checker: %w", err)
	}

	s.checkers[key] = check

	s.logger.Info().Str("key", key).Msg("Cached new checker")

	return check, nil
}

// ListServices returns a list of all configured service names.
func (s *Server) ListServices() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	services := make([]string, 0, len(s.checkerConfs))
	for name := range s.checkerConfs {
		services = append(services, name)
	}

	return services
}

// Close gracefully shuts down the server and releases resources.
func (s *Server) Close(ctx context.Context) error {
	if err := s.Stop(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Error during stop")

		return err
	}

	close(s.errChan)

	return nil
}
