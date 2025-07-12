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

package sync

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/poller"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/armis"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/netbox"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

const (
	integrationTypeArmis  = "armis"
	integrationTypeNetbox = "netbox"
)

// New creates a new PollerService with explicit dependencies.
func New(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	registry map[string]IntegrationFactory,
	grpcClient GRPCClient,
	clock poller.Clock,
	log logger.Logger,
) (*PollerService, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}

	if clock == nil {
		clock = poller.Clock(realClock{})
	}

	s := &PollerService{
		pollers:      make(map[string]*poller.Poller),
		config:       *config,
		kvClient:     kvClient,
		sources:      make(map[string]Integration),
		registry:     registry,
		grpcClient:   grpcClient,
		resultsCache: make(map[string][]*models.SweepResult),
		logger:       log,
	}

	s.initializeIntegrations(ctx)

	// Create dedicated pollers for each integration source.
	for name, sourceCfg := range config.Sources {
		// Create discovery poller (sync operations)
		syncInterval := time.Duration(config.PollInterval)
		if sourceCfg.PollInterval > 0 {
			syncInterval = time.Duration(sourceCfg.PollInterval)
		}

		syncPollerConfig := &poller.Config{
			PollInterval: models.Duration(syncInterval),
			Security:     config.Security,
			PollerID:     fmt.Sprintf("sync-%s", name),
		}

		syncPoller, err := poller.New(ctx, syncPollerConfig, clock, log)
		if err != nil {
			return nil, fmt.Errorf("failed to create sync poller for source '%s': %w", name, err)
		}

		sourceName := name
		syncPoller.PollFunc = func(ctx context.Context) error {
			return s.syncSourceDiscovery(ctx, sourceName)
		}

		s.pollers[sourceName+"-sync"] = syncPoller

		// Create sweep poller if sweep interval is configured
		if sourceCfg.SweepInterval != "" {
			sweepInterval, err := time.ParseDuration(sourceCfg.SweepInterval)
			if err != nil {
				log.Warn().Str("source", name).Str("sweep_interval", sourceCfg.SweepInterval).Err(err).Msg("Invalid sweep interval, skipping sweep poller")
				continue
			}

			sweepPollerConfig := &poller.Config{
				PollInterval: models.Duration(sweepInterval),
				Security:     config.Security,
				PollerID:     fmt.Sprintf("sweep-%s", name),
			}

			sweepPoller, err := poller.New(ctx, sweepPollerConfig, clock, log)
			if err != nil {
				return nil, fmt.Errorf("failed to create sweep poller for source '%s': %w", name, err)
			}

			sweepPoller.PollFunc = func(ctx context.Context) error {
				return s.syncSourceSweep(ctx, sourceName)
			}

			s.pollers[sourceName+"-sweep"] = sweepPoller
		}
	}

	return s, nil
}

// Start starts the integration polling loops and the gRPC server.
func (s *PollerService) Start(ctx context.Context) error {
	var wg sync.WaitGroup

	errChan := make(chan error, len(s.pollers))

	for name, p := range s.pollers {
		wg.Add(1)

		go func(name string, p *poller.Poller) {
			defer wg.Done()
			s.logger.Info().Str("source", name).Msg("Starting poller for source")

			if err := p.Start(ctx); err != nil {
				if !errors.Is(err, context.Canceled) {
					s.logger.Error().Err(err).Str("source", name).Msg("Poller for source stopped with error")
				}
				errChan <- err
			}
		}(name, p)
	}

	go func() {
		wg.Wait()
		close(errChan)
	}()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case err := <-errChan:
		if err != nil {
			return err
		}

		return nil
	}
}

// Stop stops the internal pollers, the gRPC server, and closes the gRPC client connection.
func (s *PollerService) Stop(ctx context.Context) error {
	if s.grpcServer != nil {
		s.grpcServer.GracefulStop()
		s.logger.Info().Msg("gRPC server stopped")
	}

	var lastErr error

	for name, p := range s.pollers {
		if err := p.Stop(ctx); err != nil {
			s.logger.Error().Err(err).Str("source", name).Msg("Error stopping poller")
			lastErr = err
		}
	}

	if s.grpcClient != nil {
		if errClose := s.grpcClient.Close(); errClose != nil {
			s.logger.Error().Err(errClose).Msg("Error closing gRPC client")

			if lastErr == nil {
				lastErr = errClose
			}
		}
	}

	return lastErr
}

// syncSourceDiscovery performs discovery/sync operations for a single data source.
func (s *PollerService) syncSourceDiscovery(ctx context.Context, sourceName string) error {
	integration, ok := s.sources[sourceName]
	if !ok {
		return fmt.Errorf("integration not found for source: %s", sourceName)
	}

	s.logger.Info().Str("source", sourceName).Msg("Starting discovery sync for source")

	// For discovery, we only want the KV data, not sweep results
	data, _, err := integration.Fetch(ctx)
	if err != nil {
		s.logger.Warn().Err(err).Str("source", sourceName).Msg("Error fetching from source during discovery")
		return nil
	}

	s.writeToKV(ctx, sourceName, data)

	s.logger.Info().
		Str("source", sourceName).
		Int("kv_entries", len(data)).
		Msg("Completed discovery sync for source")

	return nil
}

// syncSourceSweep performs sweep operations for a single data source.
func (s *PollerService) syncSourceSweep(ctx context.Context, sourceName string) error {
	integration, ok := s.sources[sourceName]
	if !ok {
		return fmt.Errorf("integration not found for source: %s", sourceName)
	}

	s.logger.Info().Str("source", sourceName).Msg("Starting sweep for source")

	// For sweeps, we only want the sweep results, not KV data
	_, events, err := integration.Fetch(ctx)
	if err != nil {
		s.logger.Warn().Err(err).Str("source", sourceName).Msg("Error fetching from source during sweep")
		return nil
	}

	// Update the cache for this specific source.
	s.resultsMu.Lock()
	s.resultsCache[sourceName] = events
	s.resultsMu.Unlock()

	// Recalculate total devices for logging.
	var totalDevices int

	s.resultsMu.RLock()
	for _, results := range s.resultsCache {
		totalDevices += len(results)
	}
	s.resultsMu.RUnlock()

	s.logger.Info().
		Str("source", sourceName).
		Int("source_device_count", len(events)).
		Int("total_cached_devices", totalDevices).
		Msg("Completed sweep for source")

	return nil
}

// NewDefault provides a production-ready constructor with default settings.
func NewDefault(ctx context.Context, config *Config, log logger.Logger) (*PollerService, error) {
	return NewWithGRPC(ctx, config, log)
}

// NewWithGRPC sets up the gRPC client for production use with default integrations.
func NewWithGRPC(ctx context.Context, config *Config, log logger.Logger) (*PollerService, error) {
	// Setup gRPC client for KV Store, if configured
	kvClient, grpcClient, err := setupGRPCClient(ctx, config, log)
	if err != nil {
		return nil, err
	}

	// Create syncer instance
	syncer, err := createSyncer(ctx, config, kvClient, grpcClient, log)
	if err != nil {
		if grpcClient != nil {
			_ = grpcClient.Close()
		}

		return nil, err
	}

	return syncer, nil
}

// createSyncer creates a new PollerService instance with the provided dependencies.
func createSyncer(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	grpcClient GRPCClient,
	log logger.Logger,
) (*PollerService, error) {
	serverName := getServerName(config)

	return New(
		ctx,
		config,
		kvClient,
		defaultIntegrationRegistry(kvClient, grpcClient, serverName),
		grpcClient,
		nil,
		log,
	)
}

func (s *PollerService) initializeIntegrations(ctx context.Context) {
	for name, src := range s.config.Sources {
		factory, ok := s.registry[src.Type]
		if !ok {
			s.logger.Warn().Str("source_type", src.Type).Msg("Unknown source type")
			continue
		}

		s.sources[name] = s.createIntegration(ctx, src, factory)
	}
}

func (s *PollerService) createIntegration(ctx context.Context, src *models.SourceConfig, factory IntegrationFactory) Integration {
	cfgCopy := *src
	if cfgCopy.AgentID == "" {
		cfgCopy.AgentID = s.config.AgentID
	}

	if cfgCopy.PollerID == "" {
		cfgCopy.PollerID = s.config.PollerID
	}

	if cfgCopy.Partition == "" {
		cfgCopy.Partition = "default"
	}

	return factory(ctx, &cfgCopy)
}

func (s *PollerService) writeToKV(ctx context.Context, sourceName string, data map[string][]byte) {
	if s.kvClient == nil || len(data) == 0 {
		return
	}

	prefix := strings.TrimSuffix(s.config.Sources[sourceName].Prefix, "/")
	source := s.config.Sources[sourceName]
	entries := make([]*proto.KeyValueEntry, 0, len(data))

	for key, value := range data {
		var fullKey string

		// Check if key is in partition:ip format and transform it
		if strings.Contains(key, ":") {
			parts := strings.SplitN(key, ":", 2)
			if len(parts) == 2 {
				partition := parts[0]
				ip := parts[1]
				// Build key as prefix/agentID/pollerID/partition/ip
				fullKey = fmt.Sprintf("%s/%s/%s/%s/%s", prefix, source.AgentID, source.PollerID, partition, ip)
			} else {
				fullKey = prefix + "/" + key
			}
		} else {
			fullKey = prefix + "/" + key
		}

		entries = append(entries, &proto.KeyValueEntry{Key: fullKey, Value: value})
	}

	if len(entries) > 0 {
		s.writeBatchedEntries(ctx, sourceName, entries)
	}
}

// writeBatchedEntries writes entries to KV store in batches to avoid exceeding gRPC message size limits
func (s *PollerService) writeBatchedEntries(ctx context.Context, sourceName string, entries []*proto.KeyValueEntry) {
	// Batch entries to avoid exceeding gRPC message size limit
	const maxBatchSize = 500 // Adjust based on average entry size

	const maxBatchBytes = 3 * 1024 * 1024 // 3MB to stay under 4MB limit

	currentBatch := make([]*proto.KeyValueEntry, 0, maxBatchSize)

	var currentBatchSize int

	var batchCount int

	var successfulWrites int

	for _, entry := range entries {
		// Estimate size: key length + value length + some overhead for protobuf encoding
		entrySize := len(entry.Key) + len(entry.Value) + 32

		// If adding this entry would exceed size limits, flush current batch
		if len(currentBatch) > 0 && (len(currentBatch) >= maxBatchSize || currentBatchSize+entrySize > maxBatchBytes) {
			batchCount++
			if _, err := s.kvClient.PutMany(ctx, &proto.PutManyRequest{Entries: currentBatch}); err != nil {
				s.logger.Error().Err(err).
					Int("batch_number", batchCount).
					Str("source", sourceName).
					Int("batch_size", len(currentBatch)).
					Int("batch_bytes", currentBatchSize).
					Msg("Failed to write batch to KV")
			} else {
				successfulWrites += len(currentBatch)
			}

			currentBatch = nil
			currentBatchSize = 0
		}

		currentBatch = append(currentBatch, entry)
		currentBatchSize += entrySize
	}

	// Flush remaining entries
	if len(currentBatch) > 0 {
		batchCount++

		if _, err := s.kvClient.PutMany(ctx, &proto.PutManyRequest{Entries: currentBatch}); err != nil {
			s.logger.Error().Err(err).
				Int("batch_number", batchCount).
				Str("source", sourceName).
				Int("batch_size", len(currentBatch)).
				Int("batch_bytes", currentBatchSize).
				Msg("Failed to write batch to KV")
		} else {
			successfulWrites += len(currentBatch)
		}
	}

	s.logger.Info().
		Int("successful_writes", successfulWrites).
		Int("total_entries", len(entries)).
		Str("source", sourceName).
		Int("batch_count", batchCount).
		Msg("Wrote entries to KV")
}

func defaultIntegrationRegistry(
	kvClient proto.KVServiceClient,
	grpcClient GRPCClient,
	serverName string,
) map[string]IntegrationFactory {
	return map[string]IntegrationFactory{
		integrationTypeArmis: func(ctx context.Context, config *models.SourceConfig) Integration {
			var conn *grpc.ClientConn

			if grpcClient != nil {
				conn = grpcClient.GetConnection()
			}

			return NewArmisIntegration(ctx, config, kvClient, conn, serverName)
		},
		integrationTypeNetbox: func(ctx context.Context, config *models.SourceConfig) Integration {
			var conn *grpc.ClientConn

			if grpcClient != nil {
				conn = grpcClient.GetConnection()
			}

			integ := NewNetboxIntegration(ctx, config, kvClient, conn, serverName)
			if val, ok := config.Credentials["expand_subnets"]; ok && val == "true" {
				integ.ExpandSubnets = true
			}

			return integ
		},
	}
}

func setupGRPCClient(ctx context.Context, config *Config, log logger.Logger) (proto.KVServiceClient, GRPCClient, error) {
	if config.KVAddress == "" {
		return nil, nil, nil
	}

	clientCfg := ggrpc.ClientConfig{
		Address:    config.KVAddress,
		MaxRetries: 3,
		Logger:     log,
	}

	if config.Security != nil {
		provider, errSec := ggrpc.NewSecurityProvider(ctx, config.Security, log)
		if errSec != nil {
			return nil, nil, fmt.Errorf("failed to create security provider: %w", errSec)
		}

		clientCfg.SecurityProvider = provider
	}

	c, errCli := ggrpc.NewClient(ctx, clientCfg)
	if errCli != nil {
		if clientCfg.SecurityProvider != nil {
			_ = clientCfg.SecurityProvider.Close()
		}

		return nil, nil, fmt.Errorf("failed to create KV gRPC client: %w", errCli)
	}

	grpcClient := GRPCClient(c)
	kvClient := proto.NewKVServiceClient(c.GetConnection())

	return kvClient, grpcClient, nil
}

func getServerName(config *Config) string {
	if config.Security != nil {
		return config.Security.ServerName
	}

	return ""
}

// armisDeviceStateAdapter adapts sync.DeviceState to armis.DeviceState
type armisDeviceStateAdapter struct {
	querier SRQLQuerier
}

func (a *armisDeviceStateAdapter) GetDeviceStatesBySource(ctx context.Context, source string) ([]armis.DeviceState, error) {
	states, err := a.querier.GetDeviceStatesBySource(ctx, source)
	if err != nil {
		return nil, err
	}

	result := make([]armis.DeviceState, len(states))
	for i, state := range states {
		result[i] = armis.DeviceState{
			DeviceID:    state.DeviceID,
			IP:          state.IP,
			IsAvailable: state.IsAvailable,
			Metadata:    state.Metadata,
		}
	}

	return result, nil
}

// netboxDeviceStateAdapter adapts sync.DeviceState to netbox.DeviceState
type netboxDeviceStateAdapter struct {
	querier SRQLQuerier
}

func (n *netboxDeviceStateAdapter) GetDeviceStatesBySource(ctx context.Context, source string) ([]netbox.DeviceState, error) {
	states, err := n.querier.GetDeviceStatesBySource(ctx, source)
	if err != nil {
		return nil, err
	}

	result := make([]netbox.DeviceState, len(states))
	for i, state := range states {
		result[i] = netbox.DeviceState{
			DeviceID:    state.DeviceID,
			IP:          state.IP,
			IsAvailable: state.IsAvailable,
			Metadata:    state.Metadata,
		}
	}

	return result, nil
}

// NewArmisIntegration creates a new ArmisIntegration with a gRPC client.
func NewArmisIntegration(
	_ context.Context,
	config *models.SourceConfig,
	kvClient proto.KVServiceClient,
	grpcConn *grpc.ClientConn,
	serverName string,
) *armis.ArmisIntegration {
	// Extract page size if specified
	pageSize := 100 // default

	if val, ok := config.Credentials["page_size"]; ok {
		if size, err := strconv.Atoi(val); err == nil && size > 0 {
			pageSize = size
		}
	}

	// Create the default HTTP client
	httpClient := &http.Client{
		Timeout: 30 * time.Second,
	}

	// Create the default implementations
	defaultImpl := &armis.DefaultArmisIntegration{
		Config:     config,
		HTTPClient: httpClient,
	}

	// Create the default KV writer
	kvWriter := &armis.DefaultKVWriter{
		KVClient:   kvClient,
		ServerName: serverName,
		AgentID:    config.AgentID,
	}

	interval := config.SweepInterval
	if interval == "" {
		interval = "10m"
	}

	defaultSweepCfg := &models.SweepConfig{
		Ports:         []int{22, 80, 443, 3389, 445, 5985, 5986, 8080},
		SweepModes:    []string{"icmp", "tcp"},
		Interval:      interval,
		Concurrency:   100,
		Timeout:       "15s",
		IcmpCount:     1,
		HighPerfIcmp:  true,
		IcmpRateLimit: 5000,
	}

	// Initialize SweepResultsQuerier if ServiceRadar API credentials are provided
	var sweepQuerier armis.SRQLQuerier

	serviceRadarAPIKey := config.Credentials["api_key"]
	serviceRadarEndpoint := config.Credentials["serviceradar_endpoint"]

	// If no specific ServiceRadar endpoint is provided, assume it's on the same host
	if serviceRadarEndpoint == "" && serviceRadarAPIKey != "" {
		// Extract host from Armis endpoint if possible, otherwise use localhost
		serviceRadarEndpoint = "http://localhost:8080"
	}

	if serviceRadarAPIKey != "" && serviceRadarEndpoint != "" {
		baseSweepQuerier := NewSweepResultsQuery(
			serviceRadarEndpoint,
			serviceRadarAPIKey,
			httpClient,
		)
		sweepQuerier = &armisDeviceStateAdapter{querier: baseSweepQuerier}
	}

	// Initialize ArmisUpdater (placeholder - needs actual implementation based on Armis API)
	var armisUpdater armis.ArmisUpdater

	if config.Credentials["enable_status_updates"] == "true" {
		armisUpdater = armis.NewArmisUpdater(
			config,
			httpClient,
			defaultImpl, // Using defaultImpl as TokenProvider
		)
	}

	return &armis.ArmisIntegration{
		Config:        config,
		KVClient:      kvClient,
		GRPCConn:      grpcConn,
		ServerName:    serverName,
		PageSize:      pageSize,
		HTTPClient:    httpClient,
		TokenProvider: defaultImpl,
		DeviceFetcher: defaultImpl,
		KVWriter:      kvWriter,
		SweeperConfig: defaultSweepCfg,
		SweepQuerier:  sweepQuerier,
		Updater:       armisUpdater,
	}
}

// NewNetboxIntegration creates a new NetboxIntegration instance.
func NewNetboxIntegration(
	_ context.Context,
	config *models.SourceConfig,
	kvClient proto.KVServiceClient,
	grpcConn *grpc.ClientConn,
	serverName string,
) *netbox.NetboxIntegration {
	// Add SRQL Querier for retraction logic, if configured
	var sweepQuerier netbox.SRQLQuerier

	serviceRadarAPIKey := config.Credentials["api_key"]
	serviceRadarEndpoint := config.Credentials["serviceradar_endpoint"]

	if serviceRadarEndpoint == "" && serviceRadarAPIKey != "" {
		serviceRadarEndpoint = "http://localhost:8080"
	}

	if serviceRadarAPIKey != "" && serviceRadarEndpoint != "" {
		httpClient := &http.Client{Timeout: 30 * time.Second}
		baseSweepQuerier := NewSweepResultsQuery(
			serviceRadarEndpoint,
			serviceRadarAPIKey,
			httpClient,
		)
		sweepQuerier = &netboxDeviceStateAdapter{querier: baseSweepQuerier}
	}

	return &netbox.NetboxIntegration{
		Config:        config,
		KvClient:      kvClient,
		GrpcConn:      grpcConn,
		ServerName:    serverName,
		ExpandSubnets: false, // Default: treat as /32 //TODO: make this configurable
		Querier:       sweepQuerier,
	}
}
