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
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	agentgateway "github.com/carverauto/serviceradar/pkg/agentgateway"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	syncServiceName            = "sync"
	syncServiceType            = "sync"
	syncResultsSource          = "results"
	syncStatusSource           = "status"
	defaultConfigPollInterval  = 5 * time.Minute
	defaultHeartbeatInterval   = 30 * time.Second
	defaultResultsChunkMaxSize = 3 * 1024 * 1024
)

var (
	errTaskPanic          = errors.New("panic in sync task")
	errGatewayNotEnrolled = errors.New("gateway enrollment pending")
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

// StreamingResultsStore tracks discovery counts for status reporting.
type StreamingResultsStore struct {
	mu          sync.RWMutex
	deviceCount int
	sourceCount int
	updated     time.Time
}

// SimpleSyncService manages discovery and serves results via streaming gRPC interface
type SimpleSyncService struct {
	proto.UnimplementedAgentServiceServer

	config     Config
	sources    map[string]Integration
	registry   map[string]IntegrationFactory
	grpcServer *grpc.Server

	// Simplified results storage
	resultsStore        *StreamingResultsStore
	resultsChunkMaxSize int

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
	gatewayClient       *agentgateway.GatewayClient
	gatewayEnrolled     int32
	sharedGatewayClient bool
	gatewayMu           sync.RWMutex

	configMu           sync.RWMutex
	configVersion      string
	configPollMu       sync.RWMutex
	configPollInterval time.Duration
	heartbeatMu        sync.RWMutex
	heartbeatInterval  time.Duration

	// Hot-reload support
	discoveryTicker   *time.Ticker
	armisUpdateTicker *time.Ticker
	reloadChan        chan struct{}

	// Per-source discovery scheduling
	sourceLastDiscoveryMu sync.RWMutex
	sourceLastDiscovery   map[string]time.Time // key: sourceName
}

// NewSimpleSyncService creates a new simplified sync service
func NewSimpleSyncService(
	ctx context.Context,
	config *Config,
	registry map[string]IntegrationFactory,
	log logger.Logger,
) (*SimpleSyncService, error) {
	return NewSimpleSyncServiceWithMetrics(ctx, config, registry, NewInMemoryMetrics(log), log, nil)
}

// NewSimpleSyncServiceWithMetrics creates a new simplified sync service with custom metrics
func NewSimpleSyncServiceWithMetrics(
	ctx context.Context,
	config *Config,
	registry map[string]IntegrationFactory,
	metrics Metrics,
	log logger.Logger,
	gatewayClient *agentgateway.GatewayClient,
) (*SimpleSyncService, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}

	serviceCtx, cancel := context.WithCancel(ctx)

	s := &SimpleSyncService{
		config:              *config,
		sources:             make(map[string]Integration),
		registry:            registry,
		resultsStore:        &StreamingResultsStore{},
		resultsChunkMaxSize: defaultResultsChunkMaxSize,
		discoveryInterval:   time.Duration(config.DiscoveryInterval),
		armisUpdateInterval: time.Duration(config.UpdateInterval),
		ctx:                 serviceCtx,
		cancel:              cancel,
		errorChan:           make(chan error, 10), // Buffered channel for error collection
		metrics:            metrics,
		logger:             log,
		reloadChan:         make(chan struct{}, 1),
		configPollInterval: defaultConfigPollInterval,
		heartbeatInterval:   defaultHeartbeatInterval,
		sourceLastDiscovery: make(map[string]time.Time),
	}

	if gatewayClient != nil {
		s.gatewayClient = gatewayClient
		s.sharedGatewayClient = true
	} else if config.GatewayAddr != "" {
		gatewaySecurity := config.GatewaySecurity
		if gatewaySecurity == nil {
			gatewaySecurity = config.Security
		}
		s.gatewayClient = agentgateway.NewGatewayClient(config.GatewayAddr, gatewaySecurity, log)
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
		if errors.Is(err, errGatewayNotEnrolled) {
			s.logger.Debug().Msg("Gateway enrollment pending; sync config bootstrap deferred")
		} else {
			s.logger.Error().Err(err).Msg("Failed to bootstrap sync config from gateway")
			if len(s.sources) == 0 {
				return err
			}
		}
	}

	// Start discovery/update timers
	s.discoveryTicker = time.NewTicker(s.discoveryInterval)
	defer s.discoveryTicker.Stop()
	s.armisUpdateTicker = time.NewTicker(s.armisUpdateInterval)
	defer s.armisUpdateTicker.Stop()

	// Run initial discovery immediately
	s.launchTask(ctx, "discovery", s.runDiscovery)
	if s.gatewayClient != nil {
		s.launchTask(ctx, "config poll", s.configPollLoop)
		s.launchTask(ctx, "heartbeat", s.heartbeatLoop)
	}

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

	if s.gatewayClient != nil && !s.sharedGatewayClient {
		if err := s.gatewayClient.Disconnect(); err != nil {
			s.logger.Error().Err(err).Msg("Error disconnecting gateway client")
			return err
		}
	}

	return nil
}

// MarkGatewayEnrolled marks the shared gateway client as enrolled.
func (s *SimpleSyncService) MarkGatewayEnrolled() {
	if s.gatewayClient == nil {
		return
	}

	atomic.StoreInt32(&s.gatewayEnrolled, 1)
}

// MarkGatewayUnenrolled clears the enrollment flag for shared gateway clients.
func (s *SimpleSyncService) MarkGatewayUnenrolled() {
	if s.gatewayClient == nil {
		return
	}

	atomic.StoreInt32(&s.gatewayEnrolled, 0)
}

// ApplyConfigPayload updates sources and scheduling from a JSON payload.
func (s *SimpleSyncService) ApplyConfigPayload(payloadJSON []byte, configVersion string) error {
	if len(payloadJSON) == 0 {
		s.logger.Warn().Msg("Sync config payload empty; clearing sources")
		s.applyConfigPayload(&gatewaySyncPayload{}, configVersion)
		return nil
	}

	var payload gatewaySyncPayload
	if err := json.Unmarshal(payloadJSON, &payload); err != nil {
		return fmt.Errorf("failed to parse sync config payload: %w", err)
	}

	s.applyConfigPayload(&payload, configVersion)
	return nil
}

// UpdateConfig applies updated intervals and source registry; triggers timer reload if intervals changed.
func (s *SimpleSyncService) UpdateConfig(newCfg *Config) {
	if newCfg == nil {
		return
	}

	s.configMu.Lock()
	defer s.configMu.Unlock()

	// Check interval changes
	newDisc := time.Duration(newCfg.DiscoveryInterval)
	newUpd := time.Duration(newCfg.UpdateInterval)
	intervalsChanged := (newDisc != s.discoveryInterval) || (newUpd != s.armisUpdateInterval)
	s.discoveryInterval = newDisc
	s.armisUpdateInterval = newUpd
	// Rebuild integrations even when sources are cleared.
	// Use fallback values from the new config being applied.
	agentID := newCfg.AgentID
	gatewayID := newCfg.GatewayID
	partition := newCfg.Partition
	s.sources = make(map[string]Integration)
	for name, src := range newCfg.Sources {
		if f, ok := s.registry[src.Type]; ok {
			s.sources[name] = s.createIntegration(s.ctx, src, f, agentID, gatewayID, partition)
		}
	}
	if intervalsChanged {
		select {
		case s.reloadChan <- struct{}{}:
		default:
			s.logger.Debug().Msg("Reload channel full; skipping reload trigger")
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

	sourcesSnapshot := s.snapshotSources()
	allDeviceUpdates, discoveryErrors := s.runDiscoveryForIntegrations(ctx, sourcesSnapshot)
	s.updateResultsStore(allDeviceUpdates)

	if err := s.pushResults(ctx, allDeviceUpdates); err != nil {
		s.logger.Error().Err(err).Msg("Failed to push sync results to gateway")
	}

	totalDevices := countDevices(allDeviceUpdates)
	s.metrics.RecordActiveIntegrations(len(sourcesSnapshot))
	s.metrics.RecordTotalDevicesDiscovered(totalDevices)

	s.logger.Info().
		Int("total_devices", totalDevices).
		Int("sources", len(allDeviceUpdates)).
		Msg("Discovery cycle completed")

	if len(discoveryErrors) > 0 {
		return fmt.Errorf("discovery completed with %d errors: %w", len(discoveryErrors), errors.Join(discoveryErrors...))
	}

	return nil
}

func (s *SimpleSyncService) runDiscoveryForIntegrations(
	ctx context.Context,
	integrations map[string]Integration,
) (map[string][]*models.DeviceUpdate, []error) {
	allDeviceUpdates := make(map[string][]*models.DeviceUpdate)
	var discoveryErrors []error

	for sourceName, integration := range integrations {
		// Get source config to check per-source interval
		sourceConfig := s.getSourceConfig(sourceName)

		// Check if this source is due for discovery based on its interval
		if !s.isSourceDueForDiscovery(sourceName, sourceConfig) {
			s.configMu.RLock()
			interval := s.config.GetEffectiveDiscoveryInterval(sourceConfig)
			s.configMu.RUnlock()

			s.logger.Debug().
				Str("source", sourceName).
				Dur("interval", interval).
				Msg("Skipping discovery for source - not due yet")
			continue
		}

		s.configMu.RLock()
		interval := s.config.GetEffectiveDiscoveryInterval(sourceConfig)
		s.configMu.RUnlock()

		s.logger.Info().
			Str("source", sourceName).
			Dur("interval", interval).
			Msg("Running discovery for source")

		s.metrics.RecordDiscoveryAttempt(sourceName)

		sourceStart := time.Now()
		devices, err := integration.Fetch(ctx)
		if err != nil {
			s.logger.Error().Err(err).
				Str("source", sourceName).
				Msg("Discovery failed for source")
			s.metrics.RecordDiscoveryFailure(sourceName, err, time.Since(sourceStart))
			discoveryErrors = append(discoveryErrors, fmt.Errorf("source %s: %w", sourceName, err))
			continue
		}

		// Record successful discovery time for per-source scheduling
		s.recordSourceDiscovery(sourceName)

		devices = s.applySourceBlacklist(sourceName, devices)

		s.metrics.RecordDiscoverySuccess(sourceName, len(devices), time.Since(sourceStart))
		allDeviceUpdates[sourceName] = devices

		s.logger.Info().
			Str("source", sourceName).
			Int("devices_discovered", len(devices)).
			Dur("interval", interval).
			Msg("Discovery completed for source")
	}

	s.logDiscoveredDevices(allDeviceUpdates)

	return allDeviceUpdates, discoveryErrors
}

func (s *SimpleSyncService) logDiscoveredDevices(allDeviceUpdates map[string][]*models.DeviceUpdate) {
	for sourceName, devices := range allDeviceUpdates {
		s.logger.Debug().
			Str("source", sourceName).
			Int("device_count", len(devices)).
			Msg("Devices discovered in source")

		for _, device := range devices {
			entry := s.logger.Debug().
				Str("source", sourceName).
				Str("device_ip", device.IP)

			if device.Hostname != nil && *device.Hostname != "" {
				entry = entry.Str("device_name", *device.Hostname)
			}
			if queryLabel, ok := device.Metadata["query_label"]; ok && queryLabel != "" {
				entry = entry.Str("query_label", queryLabel)
			}
			if integrationType, ok := device.Metadata["integration_type"]; ok && integrationType != "" {
				entry = entry.Str("integration_type", integrationType)
			}

			entry.Msg("Discovered device")
		}
	}
}

func (s *SimpleSyncService) updateResultsStore(allDeviceUpdates map[string][]*models.DeviceUpdate) {
	deviceCount := countDevices(allDeviceUpdates)
	sourceCount := len(allDeviceUpdates)
	s.resultsStore.mu.Lock()
	s.resultsStore.deviceCount = deviceCount
	s.resultsStore.sourceCount = sourceCount
	s.resultsStore.updated = time.Now()
	s.resultsStore.mu.Unlock()
}

func (s *SimpleSyncService) aggregateStatus() (int, int, int64) {
	return statusFromStore(s.resultsStore)
}

func statusFromStore(store *StreamingResultsStore) (int, int, int64) {
	if store == nil {
		return 0, 0, 0
	}
	store.mu.RLock()
	defer store.mu.RUnlock()

	return store.deviceCount, store.sourceCount, store.updated.Unix()
}

func countDevices(allDeviceUpdates map[string][]*models.DeviceUpdate) int {
	total := 0
	for _, devices := range allDeviceUpdates {
		total += len(devices)
	}
	return total
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

	sourcesSnapshot := s.snapshotSources()
	updateErrors := s.runArmisUpdatesForIntegrations(ctx, sourcesSnapshot)

	s.logger.Info().Msg("Armis update cycle completed")

	// Return aggregated errors if any occurred
	if len(updateErrors) > 0 {
		return fmt.Errorf("armis updates completed with %d errors: %w", len(updateErrors), errors.Join(updateErrors...))
	}

	return nil
}

func (s *SimpleSyncService) runArmisUpdatesForIntegrations(
	ctx context.Context,
	integrations map[string]Integration,
) []error {
	var updateErrors []error

	for sourceName, integration := range integrations {
		s.metrics.RecordReconciliationAttempt(sourceName)

		sourceStart := time.Now()

		if err := integration.Reconcile(ctx); err != nil {
			s.logger.Error().Err(err).
				Str("source", sourceName).
				Msg("Armis update failed for source")
			s.metrics.RecordReconciliationFailure(sourceName, err, time.Since(sourceStart))
			updateErrors = append(updateErrors, fmt.Errorf("reconcile source %s: %w", sourceName, err))
		} else {
			s.metrics.RecordReconciliationSuccess(sourceName, 0, time.Since(sourceStart))
		}
	}

	return updateErrors
}

// GetStatus implements simple health check
func (s *SimpleSyncService) GetStatus(_ context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	deviceCount, sourceCount, lastUpdated := s.aggregateStatus()

	healthData := map[string]interface{}{
		"status":         "healthy",
		"sources":        sourceCount,
		"devices":        deviceCount,
		"last_discovery": lastUpdated,
		"timestamp":      time.Now().Unix(),
	}

	healthJSON, err := json.Marshal(healthData)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to marshal health data: %v", err)
	}

	s.configMu.RLock()
	agentID := s.config.AgentID
	s.configMu.RUnlock()

	return &proto.StatusResponse{
		Available:   true,
		AgentId:     agentID,
		Message:     healthJSON,
		ServiceName: req.ServiceName,
		ServiceType: syncServiceType, // Always return "sync" as service type regardless of request
	}, nil
}

// GetResults implements legacy non-streaming interface for backward compatibility
func (s *SimpleSyncService) GetResults(_ context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	return nil, status.Errorf(codes.Unimplemented, "sync pull results are deprecated")
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

	if s.sharedGatewayClient {
		return errGatewayNotEnrolled
	}

	s.configMu.RLock()
	agentID := s.config.AgentID
	partition := s.config.Partition
	s.configMu.RUnlock()

	req := &proto.AgentHelloRequest{
		AgentId:       agentID,
		Version:       "",
		Capabilities:  []string{"sync"},
		Partition:     partition,
		ConfigVersion: s.getConfigVersion(),
	}

	resp, err := s.gatewayClient.Hello(ctx, req)
	if err != nil {
		return err
	}

	if resp.HeartbeatIntervalSec > 0 {
		s.setHeartbeatInterval(time.Duration(resp.HeartbeatIntervalSec) * time.Second)
	}

	atomic.StoreInt32(&s.gatewayEnrolled, 1)

	return nil
}

type gatewaySyncPayload struct {
	AgentID string                          `json:"agent_id,omitempty"`
	Scope   string                          `json:"scope,omitempty"`
	Sources map[string]*models.SourceConfig `json:"sources"`
}

func (s *SimpleSyncService) applyConfigPayload(payload *gatewaySyncPayload, configVersion string) {
	if payload == nil {
		return
	}

	sources := payload.Sources
	if sources == nil {
		sources = map[string]*models.SourceConfig{}
	}

	// Clone config under read lock to prevent race with concurrent updates
	s.configMu.RLock()
	updatedCfg := s.config.Clone()
	s.configMu.RUnlock()

	if payload.AgentID != "" {
		updatedCfg.AgentID = payload.AgentID
	}
	updatedCfg.Sources = sources

	s.UpdateConfig(&updatedCfg)

	if configVersion != "" {
		s.setConfigVersion(configVersion)
	}
}

func (s *SimpleSyncService) bootstrapGatewayConfig(ctx context.Context) error {
	if s.gatewayClient == nil {
		return nil
	}

	if err := s.ensureGatewayConnected(ctx); err != nil {
		return err
	}

	// Propagate enrollment-pending so Start() can defer bootstrap
	if err := s.ensureGatewayEnrolled(ctx); err != nil {
		return err
	}

	return s.fetchAndApplyConfig(ctx)
}

func (s *SimpleSyncService) fetchAndApplyConfig(ctx context.Context) error {
	if s.gatewayClient == nil {
		return nil
	}

	if err := s.ensureGatewayConnected(ctx); err != nil {
		return err
	}

	if err := s.ensureGatewayEnrolled(ctx); err != nil {
		if errors.Is(err, errGatewayNotEnrolled) {
			return nil
		}
		return err
	}

	s.configMu.RLock()
	agentID := s.config.AgentID
	s.configMu.RUnlock()

	configReq := &proto.AgentConfigRequest{
		AgentId:       agentID,
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

	if configResp.ConfigPollIntervalSec > 0 {
		s.setConfigPollInterval(time.Duration(configResp.ConfigPollIntervalSec) * time.Second)
	}

	if configResp.HeartbeatIntervalSec > 0 {
		s.setHeartbeatInterval(time.Duration(configResp.HeartbeatIntervalSec) * time.Second)
	}

	if len(configResp.ConfigJson) == 0 {
		s.logger.Warn().Msg("Gateway returned empty sync config payload")
		s.applyConfigPayload(&gatewaySyncPayload{}, configResp.ConfigVersion)
		return nil
	}

	var payload gatewaySyncPayload
	if err := json.Unmarshal(configResp.ConfigJson, &payload); err != nil {
		return fmt.Errorf("failed to parse sync config payload: %w", err)
	}

	s.applyConfigPayload(&payload, configResp.ConfigVersion)

	sourceCount := 0
	if payload.Sources != nil {
		sourceCount = len(payload.Sources)
	}

	if sourceCount == 0 {
		s.logger.Warn().Msg("Gateway sync config contained no sources; clearing active sources")
	} else {
		s.logger.Info().
			Str("config_version", configResp.ConfigVersion).
			Int("source_count", sourceCount).
			Msg("Applied sync config from gateway")
	}

	return nil
}

func (s *SimpleSyncService) configPollLoop(ctx context.Context) error {
	timer := time.NewTimer(s.getConfigPollInterval())
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
			if err := s.fetchAndApplyConfig(ctx); err != nil {
				if errors.Is(err, errGatewayNotEnrolled) {
					s.logger.Debug().Msg("Sync config poll deferred; gateway enrollment pending")
				} else {
					s.logger.Error().Err(err).Msg("Failed to refresh sync config from gateway")
				}
			}
			timer.Reset(s.getConfigPollInterval())
		}
	}
}

func (s *SimpleSyncService) heartbeatLoop(ctx context.Context) error {
	heartbeatCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	if err := s.pushHeartbeat(heartbeatCtx); err != nil && !errors.Is(err, context.Canceled) {
		s.logger.Error().Err(err).Msg("Failed to push sync heartbeat")
	}
	cancel()

	timer := time.NewTimer(s.getHeartbeatInterval())
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
			if err := s.pushHeartbeat(ctx); err != nil {
				s.logger.Error().Err(err).Msg("Failed to push sync heartbeat")
			}
			timer.Reset(s.getHeartbeatInterval())
		}
	}
}

func (s *SimpleSyncService) getConfigPollInterval() time.Duration {
	s.configPollMu.RLock()
	defer s.configPollMu.RUnlock()
	if s.configPollInterval <= 0 {
		return defaultConfigPollInterval
	}
	return s.configPollInterval
}

func (s *SimpleSyncService) setConfigPollInterval(interval time.Duration) {
	if interval <= 0 {
		return
	}

	const minInterval = 30 * time.Second
	const maxInterval = 24 * time.Hour

	if interval < minInterval {
		interval = minInterval
	} else if interval > maxInterval {
		interval = maxInterval
	}

	s.configPollMu.Lock()
	s.configPollInterval = interval
	s.configPollMu.Unlock()
}

func (s *SimpleSyncService) getHeartbeatInterval() time.Duration {
	s.heartbeatMu.RLock()
	defer s.heartbeatMu.RUnlock()
	if s.heartbeatInterval <= 0 {
		return defaultHeartbeatInterval
	}
	return s.heartbeatInterval
}

func (s *SimpleSyncService) setHeartbeatInterval(interval time.Duration) {
	if interval <= 0 {
		return
	}

	const minInterval = 10 * time.Second
	const maxInterval = 10 * time.Minute

	if interval < minInterval {
		interval = minInterval
	} else if interval > maxInterval {
		interval = maxInterval
	}

	s.heartbeatMu.Lock()
	s.heartbeatInterval = interval
	s.heartbeatMu.Unlock()
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


func (s *SimpleSyncService) buildResultsChunks(
	allDeviceUpdates []*models.DeviceUpdate,
	sequence string,
) ([]*proto.ResultsChunk, error) {
	maxChunkSize := s.resultsChunkMaxSize // keep under default 4MB gRPC limit
	if maxChunkSize <= 0 {
		maxChunkSize = defaultResultsChunkMaxSize
	}

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

	var payloads [][]byte
	var buf bytes.Buffer
	deviceCount := 0

	flush := func() {
		if deviceCount == 0 {
			return
		}
		_ = buf.WriteByte(']')
		payload := make([]byte, buf.Len())
		copy(payload, buf.Bytes())
		payloads = append(payloads, payload)
		buf.Reset()
		deviceCount = 0
	}

	for _, device := range allDeviceUpdates {
		data, err := json.Marshal(device)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal device update: %w", err)
		}

		if buf.Len() == 0 {
			_ = buf.WriteByte('[')
		}

		separatorLen := 0
		if deviceCount > 0 {
			separatorLen = 1
		}

		projectedLen := buf.Len() + separatorLen + len(data) + 1
		if deviceCount > 0 && projectedLen > maxChunkSize {
			flush()
			_ = buf.WriteByte('[')
			separatorLen = 0
		}

		if separatorLen == 1 {
			_ = buf.WriteByte(',')
		}

		_, _ = buf.Write(data)
		deviceCount++
	}

	flush()

	totalChunks := len(payloads)
	chunks := make([]*proto.ResultsChunk, 0, totalChunks)
	timestamp := time.Now().Unix()

	for chunkIndex, payload := range payloads {
		chunks = append(chunks, &proto.ResultsChunk{
			Data:            payload,
			IsFinal:         chunkIndex == totalChunks-1,
			ChunkIndex:      safeIntToInt32(chunkIndex),
			TotalChunks:     safeIntToInt32(totalChunks),
			CurrentSequence: sequence,
			Timestamp:       timestamp,
		})
	}

	return chunks, nil
}

func (s *SimpleSyncService) buildGatewayStatusChunks(
	chunks []*proto.ResultsChunk,
) []*proto.GatewayStatusChunk {
	s.configMu.RLock()
	agentID := s.config.AgentID
	partition := s.config.Partition
	gatewayID := s.config.GatewayID
	s.configMu.RUnlock()

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
			AgentId:      agentID,
			GatewayId:    gatewayID,
			Partition:    partition,
			Source:       syncResultsSource,
		}

		statusChunks = append(statusChunks, &proto.GatewayStatusChunk{
			Services:    []*proto.GatewayServiceStatus{status},
			AgentId:     agentID,
			Timestamp:   chunk.Timestamp,
			Partition:   partition,
			IsFinal:     chunk.IsFinal,
			ChunkIndex:  chunk.ChunkIndex,
			TotalChunks: chunk.TotalChunks,
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
	if len(updates) == 0 {
		return nil
	}

	sequence := s.getSequence()

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

func (s *SimpleSyncService) pushHeartbeat(ctx context.Context) error {
	if s.gatewayClient == nil {
		return nil
	}

	if err := s.ensureGatewayConnected(ctx); err != nil {
		return err
	}

	if err := s.ensureGatewayEnrolled(ctx); err != nil {
		return err
	}

	s.configMu.RLock()
	agentID := s.config.AgentID
	partition := s.config.Partition
	s.configMu.RUnlock()

	status := &proto.GatewayServiceStatus{
		ServiceName:  syncServiceName,
		Available:    true,
		ServiceType:  syncServiceType,
		AgentId:      agentID,
		Partition:    partition,
		Source:       syncStatusSource,
	}

	request := &proto.GatewayStatusRequest{
		Services:  []*proto.GatewayServiceStatus{status},
		AgentId:   agentID,
		Timestamp: time.Now().Unix(),
		Partition: partition,
	}

	pushCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	_, err := s.gatewayClient.PushStatus(pushCtx, request)
	return err
}

func (s *SimpleSyncService) getSequence() string {
	s.resultsStore.mu.RLock()
	sequence := fmt.Sprintf("%d", s.resultsStore.updated.Unix())
	s.resultsStore.mu.RUnlock()
	return sequence
}

// StreamResults implements streaming interface for large datasets
func (s *SimpleSyncService) StreamResults(req *proto.ResultsRequest, stream proto.AgentService_StreamResultsServer) error {
	s.logger.Info().
		Str("service_name", req.ServiceName).
		Str("service_type", req.ServiceType).
		Str("agent_id", req.AgentId).
		Str("gateway_id", req.GatewayId).
		Msg("StreamResults called - sync service received request")

	return status.Errorf(codes.Unimplemented, "sync pull results are deprecated")
}

// initializeIntegrations creates integrations for all configured sources
func (s *SimpleSyncService) initializeIntegrations(ctx context.Context) {
	// At initialization time, no concurrency is possible, but we still
	// access config consistently for future-proofing.
	agentID := s.config.AgentID
	gatewayID := s.config.GatewayID
	partition := s.config.Partition

	for name, src := range s.config.Sources {
		factory, ok := s.registry[src.Type]
		if !ok {
			s.logger.Warn().Str("source_type", src.Type).Msg("Unknown source type")
			continue
		}

		s.sources[name] = s.createIntegration(ctx, src, factory, agentID, gatewayID, partition)
	}
}

func (s *SimpleSyncService) snapshotSources() map[string]Integration {
	s.configMu.RLock()
	defer s.configMu.RUnlock()

	if len(s.sources) == 0 {
		return nil
	}

	snapshot := make(map[string]Integration, len(s.sources))
	for name, integration := range s.sources {
		snapshot[name] = integration
	}

	return snapshot
}

// applySourceBlacklist applies source-specific network blacklist filtering to devices.
func (s *SimpleSyncService) applySourceBlacklist(
	sourceName string,
	devices []*models.DeviceUpdate,
) (filteredDevices []*models.DeviceUpdate) {
	s.configMu.RLock()
	sourceConfig := s.config.Sources[sourceName]
	s.configMu.RUnlock()

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

// isSourceDueForDiscovery checks if a source's discovery interval has elapsed.
func (s *SimpleSyncService) isSourceDueForDiscovery(sourceName string, source *models.SourceConfig) bool {
	s.sourceLastDiscoveryMu.RLock()
	lastRun, exists := s.sourceLastDiscovery[sourceName]
	s.sourceLastDiscoveryMu.RUnlock()

	// If never run, it's due for discovery
	if !exists {
		return true
	}

	s.configMu.RLock()
	interval := s.config.GetEffectiveDiscoveryInterval(source)
	s.configMu.RUnlock()

	return time.Since(lastRun) >= interval
}

// recordSourceDiscovery records the last discovery time for a source.
func (s *SimpleSyncService) recordSourceDiscovery(sourceName string) {
	s.sourceLastDiscoveryMu.Lock()
	s.sourceLastDiscovery[sourceName] = time.Now()
	s.sourceLastDiscoveryMu.Unlock()
}

// getSourceConfig returns the source config for a given source name.
func (s *SimpleSyncService) getSourceConfig(sourceName string) *models.SourceConfig {
	s.configMu.RLock()
	source := s.config.Sources[sourceName]
	s.configMu.RUnlock()
	return source
}

// createIntegration creates a single integration instance.
// agentID, gatewayID, and partition are fallback values if not set in src.
// Callers must ensure these values are obtained under proper synchronization.
func (s *SimpleSyncService) createIntegration(
	ctx context.Context,
	src *models.SourceConfig,
	factory IntegrationFactory,
	agentID, gatewayID, partition string,
) Integration {
	cfgCopy := *src
	if cfgCopy.AgentID == "" {
		cfgCopy.AgentID = agentID
	}

	if cfgCopy.GatewayID == "" {
		cfgCopy.GatewayID = gatewayID
	}

	if cfgCopy.Partition == "" {
		if partition != "" {
			cfgCopy.Partition = partition
		} else {
			cfgCopy.Partition = "default"
		}
	}

	return factory(ctx, &cfgCopy, s.logger)
}
