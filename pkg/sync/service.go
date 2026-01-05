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
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	agentpkg "github.com/carverauto/serviceradar/pkg/agent"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	syncServiceName   = "sync"
	syncServiceType   = "sync"
	syncResultsSource = "results"
)

var (
	errTaskPanic = errors.New("panic in sync task")
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

// StreamingResultsStore holds discovery results for streaming
type StreamingResultsStore struct {
	mu      sync.RWMutex
	results map[string][]*models.DeviceUpdate
	updated time.Time
}

// SimpleSyncService manages discovery and serves results via streaming gRPC interface
type SimpleSyncService struct {
	proto.UnimplementedAgentServiceServer

	config     Config
	sources    map[string]Integration
	registry   map[string]IntegrationFactory
	grpcServer *grpc.Server

	// Simplified results storage
	resultsStore *StreamingResultsStore

	// Simple interval timers
	discoveryInterval   time.Duration
	armisUpdateInterval time.Duration

	// Context for managing service lifecycle
	ctx    context.Context
	cancel context.CancelFunc

	// Error handling
	errorChan chan error
	wg        sync.WaitGroup

	// Metrics and monitoring
	metrics Metrics

	// Atomic flags to prevent overlapping operations
	armisUpdateRunning int32

	logger logger.Logger

	// Gateway push support (push-first architecture)
	gatewayClient     *agentpkg.GatewayClient
	gatewayEnrolled   int32
	gatewayTenantID   string
	gatewayTenantSlug string
	gatewayMu         sync.RWMutex

	configMu      sync.RWMutex
	configVersion string

	// Hot-reload support
	discoveryTicker   *time.Ticker
	armisUpdateTicker *time.Ticker
	reloadChan        chan struct{}
}

// NewSimpleSyncService creates a new simplified sync service
func NewSimpleSyncService(
	ctx context.Context,
	config *Config,
	registry map[string]IntegrationFactory,
	log logger.Logger,
) (*SimpleSyncService, error) {
	return NewSimpleSyncServiceWithMetrics(ctx, config, registry, NewInMemoryMetrics(log), log)
}

// NewSimpleSyncServiceWithMetrics creates a new simplified sync service with custom metrics
func NewSimpleSyncServiceWithMetrics(
	ctx context.Context,
	config *Config,
	registry map[string]IntegrationFactory,
	metrics Metrics,
	log logger.Logger,
) (*SimpleSyncService, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}

	serviceCtx, cancel := context.WithCancel(ctx)

	s := &SimpleSyncService{
		config:   *config,
		sources:  make(map[string]Integration),
		registry: registry,
		resultsStore: &StreamingResultsStore{
			results: make(map[string][]*models.DeviceUpdate),
		},
		discoveryInterval:   time.Duration(config.DiscoveryInterval),
		armisUpdateInterval: time.Duration(config.UpdateInterval),
		ctx:                 serviceCtx,
		cancel:              cancel,
		errorChan:           make(chan error, 10), // Buffered channel for error collection
		metrics:             metrics,
		logger:              log,
		reloadChan:          make(chan struct{}, 1),
	}

	if config.GatewayAddr != "" {
		gatewaySecurity := config.GatewaySecurity
		if gatewaySecurity == nil {
			gatewaySecurity = config.Security
		}
		s.gatewayClient = agentpkg.NewGatewayClient(config.GatewayAddr, gatewaySecurity, log)
	}

	s.initializeIntegrations(ctx)

	return s, nil
}

// safelyRunTask executes a task function with proper error handling and panic recovery
func (s *SimpleSyncService) safelyRunTask(ctx context.Context, taskName string, task func(context.Context) error) {
	defer s.wg.Done()
	defer func() {
		if r := recover(); r != nil {
			var panicErr = fmt.Errorf("panic in %s: %v: %w", taskName, r, errTaskPanic)
			s.logger.Error().Err(panicErr).Msg("Recovered from panic")
			s.sendError(panicErr)
		}
	}()

	if err := task(ctx); err != nil {
		s.sendError(fmt.Errorf("%s error: %w", taskName, err))
	}
}

// sendError safely sends an error to the error channel, logging if the channel is full
func (s *SimpleSyncService) sendError(err error) {
	select {
	case s.errorChan <- err:
	default:
		s.logger.Error().Err(err).Msg("Error channel full, dropping error")
	}
}

// launchTask adds to the wait group and launches a goroutine to execute the given task
// It uses the service's internal context to ensure proper cancellation when Stop() is called
func (s *SimpleSyncService) launchTask(_ context.Context, taskName string, task func(context.Context) error) {
	s.wg.Add(1)
	// Use the service's internal context to ensure proper cancellation during Stop()
	go s.safelyRunTask(s.ctx, taskName, task)
}

// Start begins the simple interval-based discovery and Armis update cycles
func (s *SimpleSyncService) Start(ctx context.Context) error {
	s.logger.Info().Msg("Starting simplified sync service")

	if err := s.bootstrapGatewayConfig(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Failed to bootstrap sync config from gateway")
		if len(s.sources) == 0 {
			return err
		}
	}

	// Start discovery/update timers
	s.discoveryTicker = time.NewTicker(s.discoveryInterval)
	defer s.discoveryTicker.Stop()
	s.armisUpdateTicker = time.NewTicker(s.armisUpdateInterval)
	defer s.armisUpdateTicker.Stop()

	// Run initial discovery immediately
	s.launchTask(ctx, "discovery", s.runDiscovery)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.ctx.Done():
			return s.ctx.Err()
		case err := <-s.errorChan:
			// Log critical errors but continue running
			s.logger.Error().Err(err).Msg("Critical error in sync service")
			// Optionally, you can return the error to stop the service on critical errors
			// return fmt.Errorf("critical error in sync service: %w", err)
		case <-s.discoveryTicker.C:
			s.launchTask(ctx, "discovery", s.runDiscovery)
		case <-s.armisUpdateTicker.C:
			s.launchTask(ctx, "armis updates", s.runArmisUpdates)
		case <-s.reloadChan:
			s.logger.Info().Msg("Reloading sync timers with updated intervals")
			s.discoveryTicker.Stop()
			s.armisUpdateTicker.Stop()
			s.discoveryTicker = time.NewTicker(s.discoveryInterval)
			s.armisUpdateTicker = time.NewTicker(s.armisUpdateInterval)
		}
	}
}

// Stop gracefully stops the sync service
func (s *SimpleSyncService) Stop(_ context.Context) error {
	s.logger.Info().Msg("Stopping simplified sync service")

	if s.cancel != nil {
		s.cancel()
	}

	// Wait for all goroutines to finish with a timeout
	done := make(chan struct{})

	go func() {
		s.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		// All goroutines finished
	case <-time.After(2 * time.Second):
		s.logger.Warn().Msg("Timeout waiting for goroutines to finish during stop")
	}

	// Close error channel
	close(s.errorChan)

	if s.grpcServer != nil {
		s.grpcServer.GracefulStop()
		s.logger.Info().Msg("gRPC server stopped")
	}

	if s.gatewayClient != nil {
		if err := s.gatewayClient.Disconnect(); err != nil {
			s.logger.Error().Err(err).Msg("Error disconnecting gateway client")
			return err
		}
	}

	return nil
}

// UpdateConfig applies updated intervals and source registry; triggers timer reload if intervals changed.
func (s *SimpleSyncService) UpdateConfig(newCfg *Config) {
	if newCfg == nil {
		return
	}
	// Check interval changes
	newDisc := time.Duration(newCfg.DiscoveryInterval)
	newUpd := time.Duration(newCfg.UpdateInterval)
	intervalsChanged := (newDisc != s.discoveryInterval) || (newUpd != s.armisUpdateInterval)
	s.discoveryInterval = newDisc
	s.armisUpdateInterval = newUpd
	// Rebuild integrations if sources changed
	// For simplicity, rebuild from registry factories using new config
	if len(newCfg.Sources) > 0 {
		s.sources = make(map[string]Integration)
		for name, src := range newCfg.Sources {
			if f, ok := s.registry[src.Type]; ok {
				s.sources[name] = s.createIntegration(s.ctx, src, f)
			}
		}
	}
	if intervalsChanged {
		select {
		case s.reloadChan <- struct{}{}:
		default:
		}
	}
	s.config = *newCfg
}

// runDiscovery executes discovery for all integrations and stores results in memory.
func (s *SimpleSyncService) runDiscovery(ctx context.Context) error {
	start := time.Now()
	s.logger.Info().
		Time("started_at", start).
		Msg("Starting discovery cycle")

	allDeviceUpdates := make(map[string][]*models.DeviceUpdate)

	var discoveryErrors []error

	for sourceName, integration := range s.sources {
		s.logger.Info().Str("source", sourceName).Msg("Running discovery for source")
		s.metrics.RecordDiscoveryAttempt(sourceName)

		sourceStart := time.Now()

		// Fetch devices from integration. `devices` is now `[]*models.DeviceUpdate`.
		devices, err := integration.Fetch(ctx)
		if err != nil {
			s.logger.Error().Err(err).Str("source", sourceName).Msg("Discovery failed for source")
			s.metrics.RecordDiscoveryFailure(sourceName, err, time.Since(sourceStart))
			discoveryErrors = append(discoveryErrors, fmt.Errorf("source %s: %w", sourceName, err))

			continue
		}

		// Apply source-specific network blacklist filtering if configured
		devices = s.applySourceBlacklist(sourceName, devices)
		s.metrics.RecordDiscoverySuccess(sourceName, len(devices), time.Since(sourceStart))

		allDeviceUpdates[sourceName] = devices

		s.logger.Info().
			Str("source", sourceName).
			Int("devices_discovered", len(devices)).
			Msg("Discovery completed for source")
	}

	// iterate through allDeviceUpdates and print the device names
	for sourceName, devices := range allDeviceUpdates {
		s.logger.Debug().
			Str("source", sourceName).
			Int("device_count", len(devices)).
			Msg("Devices discovered in source")

		for _, device := range devices {
			logEvent := s.logger.Debug().
				Str("source", sourceName).
				Str("device_ip", device.IP)

			// Add hostname if available
			if device.Hostname != nil && *device.Hostname != "" {
				logEvent = logEvent.Str("device_name", *device.Hostname)
			}

			// Add query label if present in metadata (primarily for Armis)
			if queryLabel, ok := device.Metadata["query_label"]; ok && queryLabel != "" {
				logEvent = logEvent.Str("query_label", queryLabel)
			}

			// Add integration type if present
			if integrationType, ok := device.Metadata["integration_type"]; ok && integrationType != "" {
				logEvent = logEvent.Str("integration_type", integrationType)
			}

			logEvent.Msg("Discovered device")
		}
	}

	// Store results for GetResults calls
	s.resultsStore.mu.Lock()
	s.resultsStore.results = allDeviceUpdates
	s.resultsStore.updated = time.Now()
	s.resultsStore.mu.Unlock()

	if err := s.pushResults(ctx, allDeviceUpdates); err != nil {
		s.logger.Error().Err(err).Msg("Failed to push sync results to gateway")
	}

	var totalDevices int

	for _, devices := range allDeviceUpdates {
		totalDevices += len(devices)
	}

	// Record overall metrics
	s.metrics.RecordActiveIntegrations(len(s.sources))
	s.metrics.RecordTotalDevicesDiscovered(totalDevices)

	s.logger.Info().
		Int("total_devices", totalDevices).
		Int("sources", len(allDeviceUpdates)).
		Msg("Discovery cycle completed")

	// Return aggregated errors if any occurred
	if len(discoveryErrors) > 0 {
		return fmt.Errorf("discovery completed with %d errors: %w", len(discoveryErrors), errors.Join(discoveryErrors...))
	}

	return nil
}

// runArmisUpdates queries SRQL and updates Armis with device availability
func (s *SimpleSyncService) runArmisUpdates(ctx context.Context) error {
	// Skip if already running to prevent overlapping operations
	if !atomic.CompareAndSwapInt32(&s.armisUpdateRunning, 0, 1) {
		s.logger.Warn().Msg("Armis update already running, skipping this cycle")
		return nil
	}
	defer atomic.StoreInt32(&s.armisUpdateRunning, 0)

	s.logger.Info().Msg("Starting Armis update cycle")

	var updateErrors []error

	for sourceName, integration := range s.sources {
		s.metrics.RecordReconciliationAttempt(sourceName)

		sourceStart := time.Now()

		if err := integration.Reconcile(ctx); err != nil {
			s.logger.Error().Err(err).Str("source", sourceName).Msg("Armis update failed for source")
			s.metrics.RecordReconciliationFailure(sourceName, err, time.Since(sourceStart))
			updateErrors = append(updateErrors, fmt.Errorf("reconcile source %s: %w", sourceName, err))
		} else {
			s.metrics.RecordReconciliationSuccess(sourceName, 0, time.Since(sourceStart)) // updateCount will be 0 for now
		}
	}

	s.logger.Info().Msg("Armis update cycle completed")

	// Return aggregated errors if any occurred
	if len(updateErrors) > 0 {
		return fmt.Errorf("armis updates completed with %d errors: %w", len(updateErrors), errors.Join(updateErrors...))
	}

	return nil
}

// GetStatus implements simple health check
func (s *SimpleSyncService) GetStatus(_ context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	s.resultsStore.mu.RLock()
	defer s.resultsStore.mu.RUnlock()

	var deviceCount int

	for _, devices := range s.resultsStore.results {
		deviceCount += len(devices)
	}

	healthData := map[string]interface{}{
		"status":         "healthy",
		"sources":        len(s.resultsStore.results),
		"devices":        deviceCount,
		"last_discovery": s.resultsStore.updated.Unix(),
		"timestamp":      time.Now().Unix(),
	}

	healthJSON, err := json.Marshal(healthData)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to marshal health data: %v", err)
	}

	return &proto.StatusResponse{
		Available:   true,
		AgentId:     s.config.AgentID,
		Message:     healthJSON,
		ServiceName: req.ServiceName,
		ServiceType: syncServiceType, // Always return "sync" as service type regardless of request
	}, nil
}

// GetResults implements legacy non-streaming interface for backward compatibility
func (s *SimpleSyncService) GetResults(_ context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.resultsStore.mu.RLock()
	defer s.resultsStore.mu.RUnlock()

	var allDeviceUpdates []*models.DeviceUpdate

	s.logger.Debug().
		Int("total_sources", len(s.resultsStore.results)).
		Msg("SYNC DEBUG: GetResults called")

	for sourceName, devices := range s.resultsStore.results {
		s.logger.Debug().
			Str("source_name", sourceName).
			Int("device_count", len(devices)).
			Msg("SYNC DEBUG: Source devices")

		if len(devices) > 0 {
			s.logger.Debug().
				Str("source_name", sourceName).
				Str("sample_device_ip", devices[0].IP).
				Str("sample_device_source", string(devices[0].Source)).
				Int("sample_device_metadata_keys", len(devices[0].Metadata)).
				Msg("SYNC DEBUG: Sample device summary")
		}

		allDeviceUpdates = append(allDeviceUpdates, devices...)
	}

	s.logger.Debug().
		Int("total_device_updates", len(allDeviceUpdates)).
		Msg("SYNC DEBUG: About to marshal DeviceUpdate array")

	resultsJSON, err := json.Marshal(allDeviceUpdates)
	if err != nil {
		s.logger.Error().
			Err(err).
			Int("device_count", len(allDeviceUpdates)).
			Msg("SYNC DEBUG: Failed to marshal DeviceUpdate array")

		return nil, status.Errorf(codes.Internal, "failed to marshal results: %v", err)
	}

	s.logger.Debug().
		Int("json_bytes", len(resultsJSON)).
		Int("device_count", len(allDeviceUpdates)).
		Msg("SYNC DEBUG: Successfully marshaled DeviceUpdate array")

	return &proto.ResultsResponse{
		Available:       true,
		Data:            resultsJSON,
		ServiceName:     req.ServiceName,
		ServiceType:     syncServiceType, // Always return "sync" as service type regardless of request
		AgentId:         s.config.AgentID,
		PollerId:        req.PollerId,
		Timestamp:       time.Now().Unix(),
		CurrentSequence: fmt.Sprintf("%d", s.resultsStore.updated.Unix()),
		HasNewData:      true,
	}, nil
}

// GetServiceMetrics returns current service metrics for monitoring
func (s *SimpleSyncService) GetServiceMetrics() map[string]interface{} {
	return s.metrics.GetMetrics()
}

// collectDeviceUpdates gathers all device updates from the results store
func (s *SimpleSyncService) collectDeviceUpdates(results map[string][]*models.DeviceUpdate) []*models.DeviceUpdate {
	var allDeviceUpdates []*models.DeviceUpdate

	for sourceName, devices := range results {
		s.logger.Info().
			Str("source_name", sourceName).
			Int("device_count", len(devices)).
			Msg("StreamResults - processing devices from source")

		if len(devices) > 0 {
			// Log sample device for debugging
			sampleDevice := devices[0]
			s.logger.Debug().
				Str("source_name", sourceName).
				Str("sample_device_ip", sampleDevice.IP).
				Str("sample_device_source", string(sampleDevice.Source)).
				Int("sample_device_metadata_keys", len(sampleDevice.Metadata)).
				Msg("StreamResults - sample device from source")
		}

		allDeviceUpdates = append(allDeviceUpdates, devices...)
	}

	s.logger.Info().
		Int("total_device_updates", len(allDeviceUpdates)).
		Msg("StreamResults - total devices to stream")

	return allDeviceUpdates
}

func (s *SimpleSyncService) ensureGatewayConnected(ctx context.Context) error {
	if s.gatewayClient == nil {
		return nil
	}

	if s.gatewayClient.IsConnected() {
		return nil
	}

	return s.gatewayClient.Connect(ctx)
}

func (s *SimpleSyncService) ensureGatewayEnrolled(ctx context.Context) error {
	if s.gatewayClient == nil {
		return nil
	}

	if atomic.LoadInt32(&s.gatewayEnrolled) == 1 {
		return nil
	}

	req := &proto.AgentHelloRequest{
		AgentId:       s.config.AgentID,
		Version:       "",
		Capabilities:  []string{"sync"},
		Partition:     s.config.Partition,
		ConfigVersion: s.getConfigVersion(),
	}

	resp, err := s.gatewayClient.Hello(ctx, req)
	if err != nil {
		return err
	}

	s.gatewayMu.Lock()
	if s.gatewayTenantID == "" && resp.TenantId != "" {
		s.gatewayTenantID = resp.TenantId
	}
	if s.gatewayTenantSlug == "" && resp.TenantSlug != "" {
		s.gatewayTenantSlug = resp.TenantSlug
	}
	s.gatewayMu.Unlock()

	atomic.StoreInt32(&s.gatewayEnrolled, 1)

	return nil
}

type gatewaySyncConfig struct {
	SyncServiceID string                          `json:"sync_service_id"`
	ComponentID   string                          `json:"component_id"`
	Scope         string                          `json:"scope"`
	Sources       map[string]*models.SourceConfig `json:"sources"`
}

func (s *SimpleSyncService) bootstrapGatewayConfig(ctx context.Context) error {
	if s.gatewayClient == nil {
		return nil
	}

	if err := s.ensureGatewayConnected(ctx); err != nil {
		return err
	}

	if err := s.ensureGatewayEnrolled(ctx); err != nil {
		return err
	}

	return s.fetchAndApplyConfig(ctx)
}

func (s *SimpleSyncService) fetchAndApplyConfig(ctx context.Context) error {
	if s.gatewayClient == nil {
		return nil
	}

	configReq := &proto.AgentConfigRequest{
		AgentId:       s.config.AgentID,
		ConfigVersion: s.getConfigVersion(),
	}

	configCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	configResp, err := s.gatewayClient.GetConfig(configCtx, configReq)
	if err != nil {
		return err
	}

	if configResp.NotModified {
		s.logger.Debug().Str("version", s.getConfigVersion()).Msg("Sync config not modified")
		return nil
	}

	if len(configResp.ConfigJson) == 0 {
		s.logger.Warn().Msg("Gateway returned empty sync config payload")
		return nil
	}

	var payload gatewaySyncConfig
	if err := json.Unmarshal(configResp.ConfigJson, &payload); err != nil {
		return fmt.Errorf("failed to parse sync config payload: %w", err)
	}

	if len(payload.Sources) == 0 {
		s.logger.Warn().Msg("Gateway sync config contained no sources")
		return nil
	}

	updatedCfg := s.config
	updatedCfg.Sources = payload.Sources
	s.UpdateConfig(&updatedCfg)
	s.setConfigVersion(configResp.ConfigVersion)

	s.logger.Info().
		Str("config_version", configResp.ConfigVersion).
		Int("source_count", len(payload.Sources)).
		Msg("Applied sync config from gateway")

	return nil
}

func (s *SimpleSyncService) getConfigVersion() string {
	s.configMu.RLock()
	defer s.configMu.RUnlock()
	return s.configVersion
}

func (s *SimpleSyncService) setConfigVersion(version string) {
	s.configMu.Lock()
	s.configVersion = version
	s.configMu.Unlock()
}

func (s *SimpleSyncService) tenantInfo() (string, string) {
	s.gatewayMu.RLock()
	tenantID := s.gatewayTenantID
	tenantSlug := s.gatewayTenantSlug
	s.gatewayMu.RUnlock()

	if tenantID != "" || tenantSlug != "" {
		return tenantID, tenantSlug
	}

	return s.config.TenantID, s.config.TenantSlug
}

func (s *SimpleSyncService) buildResultsChunks(
	allDeviceUpdates []*models.DeviceUpdate,
	sequence string,
) ([]*proto.ResultsChunk, error) {
	// Calculate chunk size to keep each chunk under ~1MB
	const maxChunkSize = 1024 * 1024 // 1MB
	const avgDeviceSize = 768        // DeviceUpdate is a bit larger, adjust estimate

	if len(allDeviceUpdates) == 0 {
		return []*proto.ResultsChunk{{
			Data:            []byte("[]"),
			IsFinal:         true,
			ChunkIndex:      0,
			TotalChunks:     1,
			CurrentSequence: sequence,
			Timestamp:       time.Now().Unix(),
		}}, nil
	}

	chunkDeviceCount := maxChunkSize / avgDeviceSize
	if chunkDeviceCount <= 0 {
		chunkDeviceCount = 1
	}

	totalChunks := (len(allDeviceUpdates) + chunkDeviceCount - 1) / chunkDeviceCount
	chunks := make([]*proto.ResultsChunk, 0, totalChunks)

	for chunkIndex := 0; chunkIndex < totalChunks; chunkIndex++ {
		start := chunkIndex * chunkDeviceCount
		end := start + chunkDeviceCount

		if end > len(allDeviceUpdates) {
			end = len(allDeviceUpdates)
		}

		chunkDevices := allDeviceUpdates[start:end]
		chunkData, err := json.Marshal(chunkDevices)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal chunk: %w", err)
		}

		chunks = append(chunks, &proto.ResultsChunk{
			Data:            chunkData,
			IsFinal:         chunkIndex == totalChunks-1,
			ChunkIndex:      safeIntToInt32(chunkIndex),
			TotalChunks:     safeIntToInt32(totalChunks),
			CurrentSequence: sequence,
			Timestamp:       time.Now().Unix(),
		})
	}

	return chunks, nil
}

func (s *SimpleSyncService) buildGatewayStatusChunks(
	chunks []*proto.ResultsChunk,
) []*proto.GatewayStatusChunk {
	tenantID, tenantSlug := s.tenantInfo()
	statusChunks := make([]*proto.GatewayStatusChunk, 0, len(chunks))

	for _, chunk := range chunks {
		if chunk == nil {
			continue
		}

		status := &proto.GatewayServiceStatus{
			ServiceName:  syncServiceName,
			Available:    true,
			Message:      chunk.Data,
			ServiceType:  syncServiceType,
			ResponseTime: 0,
			AgentId:      s.config.AgentID,
			GatewayId:    "",
			Partition:    s.config.Partition,
			Source:       syncResultsSource,
			KvStoreId:    "",
			TenantId:     tenantID,
			TenantSlug:   tenantSlug,
		}

		statusChunks = append(statusChunks, &proto.GatewayStatusChunk{
			Services:    []*proto.GatewayServiceStatus{status},
			GatewayId:   "",
			AgentId:     s.config.AgentID,
			Timestamp:   chunk.Timestamp,
			Partition:   s.config.Partition,
			IsFinal:     chunk.IsFinal,
			ChunkIndex:  chunk.ChunkIndex,
			TotalChunks: chunk.TotalChunks,
			KvStoreId:   "",
			TenantId:    tenantID,
			TenantSlug:  tenantSlug,
		})
	}

	return statusChunks
}

func (s *SimpleSyncService) pushResults(
	ctx context.Context,
	allDeviceUpdates map[string][]*models.DeviceUpdate,
) error {
	if s.gatewayClient == nil {
		return nil
	}

	if err := s.ensureGatewayConnected(ctx); err != nil {
		return err
	}

	if err := s.ensureGatewayEnrolled(ctx); err != nil {
		return err
	}

	updates := s.collectDeviceUpdates(allDeviceUpdates)

	s.resultsStore.mu.RLock()
	sequence := fmt.Sprintf("%d", s.resultsStore.updated.Unix())
	s.resultsStore.mu.RUnlock()

	chunks, err := s.buildResultsChunks(updates, sequence)
	if err != nil {
		return err
	}

	statusChunks := s.buildGatewayStatusChunks(chunks)
	if len(statusChunks) == 0 {
		return nil
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	_, err = s.gatewayClient.StreamStatus(pushCtx, statusChunks)
	return err
}

// sendEmptyResultsChunk sends an empty chunk when there are no device updates
func (s *SimpleSyncService) sendEmptyResultsChunk(stream proto.AgentService_StreamResultsServer) error {
	s.logger.Warn().Msg("StreamResults - no device updates to send, sending empty array")
	// Send empty final chunk
	return stream.Send(&proto.ResultsChunk{
		Data:            []byte("[]"),
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: fmt.Sprintf("%d", s.resultsStore.updated.Unix()),
		Timestamp:       time.Now().Unix(),
	})
}

// sendDeviceChunks splits device updates into chunks and sends them to the client
func (s *SimpleSyncService) sendDeviceChunks(
	allDeviceUpdates []*models.DeviceUpdate,
	stream proto.AgentService_StreamResultsServer,
) error {
	// Calculate chunk size to keep each chunk under ~1MB
	const maxChunkSize = 1024 * 1024 // 1MB

	const avgDeviceSize = 768 // DeviceUpdate is a bit larger, adjust estimate

	chunkDeviceCount := maxChunkSize / avgDeviceSize
	totalChunks := (len(allDeviceUpdates) + chunkDeviceCount - 1) / chunkDeviceCount
	sequence := fmt.Sprintf("%d", s.resultsStore.updated.Unix())

	for chunkIndex := 0; chunkIndex < totalChunks; chunkIndex++ {
		if err := s.sendSingleChunk(allDeviceUpdates, chunkIndex, chunkDeviceCount, totalChunks, sequence, stream); err != nil {
			return err
		}
	}

	s.logger.Info().
		Int("total_devices", len(allDeviceUpdates)).
		Int("total_chunks", totalChunks).
		Str("sequence", sequence).
		Msg("Completed streaming results")

	return nil
}

// sendSingleChunk prepares and sends a single chunk of device updates
func (s *SimpleSyncService) sendSingleChunk(
	allDeviceUpdates []*models.DeviceUpdate,
	chunkIndex, chunkDeviceCount, totalChunks int,
	sequence string,
	stream proto.AgentService_StreamResultsServer,
) error {
	start := chunkIndex * chunkDeviceCount
	end := start + chunkDeviceCount

	if end > len(allDeviceUpdates) {
		end = len(allDeviceUpdates)
	}

	chunkDevices := allDeviceUpdates[start:end]

	chunkData, err := json.Marshal(chunkDevices)
	if err != nil {
		s.logger.Error().
			Err(err).
			Int("chunk_index", chunkIndex).
			Int("device_count", len(chunkDevices)).
			Msg("SYNC DEBUG: Failed to marshal chunk")

		return status.Errorf(codes.Internal, "failed to marshal chunk: %v", err)
	}

	s.logger.Debug().
		Int("chunk_index", chunkIndex).
		Int("chunk_bytes", len(chunkData)).
		Int("device_count", len(chunkDevices)).
		Msg("SYNC DEBUG: Successfully marshaled chunk")

	if len(chunkDevices) > 0 {
		sample := chunkDevices[0]
		s.logger.Debug().
			Int("chunk_index", chunkIndex).
			Str("sample_device_ip", sample.IP).
			Str("sample_device_source", string(sample.Source)).
			Int("sample_device_metadata_keys", len(sample.Metadata)).
			Msg("SYNC DEBUG: Sample device summary in chunk")
	}

	chunk := &proto.ResultsChunk{
		Data:            chunkData,
		IsFinal:         chunkIndex == totalChunks-1,
		ChunkIndex:      safeIntToInt32(chunkIndex),
		TotalChunks:     safeIntToInt32(totalChunks),
		CurrentSequence: sequence,
		Timestamp:       time.Now().Unix(),
	}

	s.logger.Info().
		Int("chunk_index", chunkIndex).
		Int("chunk_data_size", len(chunkData)).
		Bool("is_final", chunk.IsFinal).
		Msg("StreamResults - sending chunk to poller")

	if err := stream.Send(chunk); err != nil {
		if errors.Is(err, io.EOF) {
			s.logger.Info().Msg("StreamResults - client closed stream")
			return nil
		}

		s.logger.Error().Err(err).Msg("StreamResults - failed to send chunk")

		return status.Errorf(codes.Internal, "failed to send chunk: %v", err)
	}

	return nil
}

// StreamResults implements streaming interface for large datasets
func (s *SimpleSyncService) StreamResults(req *proto.ResultsRequest, stream proto.AgentService_StreamResultsServer) error {
	s.logger.Info().
		Str("service_name", req.ServiceName).
		Str("service_type", req.ServiceType).
		Str("agent_id", req.AgentId).
		Str("poller_id", req.PollerId).
		Msg("StreamResults called - sync service received request")

	s.resultsStore.mu.RLock()
	defer s.resultsStore.mu.RUnlock()

	allDeviceUpdates := s.collectDeviceUpdates(s.resultsStore.results)

	if len(allDeviceUpdates) == 0 {
		return s.sendEmptyResultsChunk(stream)
	}

	return s.sendDeviceChunks(allDeviceUpdates, stream)
}

// initializeIntegrations creates integrations for all configured sources
func (s *SimpleSyncService) initializeIntegrations(ctx context.Context) {
	for name, src := range s.config.Sources {
		factory, ok := s.registry[src.Type]
		if !ok {
			s.logger.Warn().Str("source_type", src.Type).Msg("Unknown source type")
			continue
		}

		s.sources[name] = s.createIntegration(ctx, src, factory)
	}
}

// applySourceBlacklist applies source-specific network blacklist filtering to devices.
func (s *SimpleSyncService) applySourceBlacklist(
	sourceName string,
	devices []*models.DeviceUpdate,
) (filteredDevices []*models.DeviceUpdate) {
	sourceConfig := s.config.Sources[sourceName]
	if sourceConfig == nil || len(sourceConfig.NetworkBlacklist) == 0 {
		return devices
	}

	networkBlacklist, err := NewNetworkBlacklist(sourceConfig.NetworkBlacklist, s.logger)
	if err != nil {
		s.logger.Error().Err(err).Str("source", sourceName).Msg("Failed to create network blacklist for source")
		return devices
	}

	originalCount := len(devices)
	filteredDevices = networkBlacklist.FilterDevices(devices)

	if filteredCount := originalCount - len(filteredDevices); filteredCount > 0 {
		s.logger.Info().
			Str("source", sourceName).
			Int("filtered_count", filteredCount).
			Int("remaining_count", len(filteredDevices)).
			Msg("Applied source-specific network blacklist filtering to devices")
	}
	return filteredDevices
}

// createIntegration creates a single integration instance
func (s *SimpleSyncService) createIntegration(ctx context.Context, src *models.SourceConfig, factory IntegrationFactory) Integration {
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

	return factory(ctx, &cfgCopy, s.logger)
}
