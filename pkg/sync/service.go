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
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	// MaxBatchSize defines the maximum number of entries to write to KV in a single batch
	MaxBatchSize = 500
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
	kvClient   KVClient
	sources    map[string]Integration
	registry   map[string]IntegrationFactory
	grpcClient GRPCClient
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

	// Hot-reload support
	discoveryTicker   *time.Ticker
	armisUpdateTicker *time.Ticker
	reloadChan        chan struct{}
}

// NewSimpleSyncService creates a new simplified sync service
func NewSimpleSyncService(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	registry map[string]IntegrationFactory,
	grpcClient GRPCClient,
	log logger.Logger,
) (*SimpleSyncService, error) {
	return NewSimpleSyncServiceWithMetrics(ctx, config, kvClient, registry, grpcClient, NewInMemoryMetrics(log), log)
}

// NewSimpleSyncServiceWithMetrics creates a new simplified sync service with custom metrics
func NewSimpleSyncServiceWithMetrics(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	registry map[string]IntegrationFactory,
	grpcClient GRPCClient,
	metrics Metrics,
	log logger.Logger,
) (*SimpleSyncService, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}

	serviceCtx, cancel := context.WithCancel(ctx)

	s := &SimpleSyncService{
		config:     *config,
		kvClient:   kvClient,
		sources:    make(map[string]Integration),
		registry:   registry,
		grpcClient: grpcClient,
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

	if s.grpcClient != nil {
		if err := s.grpcClient.Close(); err != nil {
			s.logger.Error().Err(err).Msg("Error closing gRPC client")
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

// runDiscovery executes discovery for all integrations and immediately writes to KV
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
		kvData, devices, err := integration.Fetch(ctx)
		if err != nil {
			s.logger.Error().Err(err).Str("source", sourceName).Msg("Discovery failed for source")
			s.metrics.RecordDiscoveryFailure(sourceName, err, time.Since(sourceStart))
			discoveryErrors = append(discoveryErrors, fmt.Errorf("source %s: %w", sourceName, err))

			continue
		}

		// Apply source-specific network blacklist filtering if configured
		devices, kvData = s.applySourceBlacklist(sourceName, devices, kvData)

		// Immediately write device data to KV store
		if err := s.writeToKV(ctx, sourceName, kvData); err != nil {
			s.logger.Error().Err(err).Str("source", sourceName).Msg("Failed to write to KV")
			s.metrics.RecordDiscoveryFailure(sourceName, err, time.Since(sourceStart))
			discoveryErrors = append(discoveryErrors, fmt.Errorf("KV write for source %s: %w", sourceName, err))
		} else {
			s.metrics.RecordDiscoverySuccess(sourceName, len(devices), time.Since(sourceStart))
		}

		allDeviceUpdates[sourceName] = devices

		s.logger.Info().
			Str("source", sourceName).
			Int("devices_discovered", len(devices)).
			Int("kv_entries_written", len(kvData)).
			Msg("Discovery completed for source")
	}

	if err := s.hydrateCanonicalUpdates(ctx, allDeviceUpdates); err != nil {
		s.logger.Warn().Err(err).Msg("Failed to hydrate canonical metadata from KV")
	}

	// iterate through allDeviceUpdates and print the device names
	for sourceName, devices := range allDeviceUpdates {
		s.logger.Info().
			Str("source", sourceName).
			Int("device_count", len(devices)).
			Msg("Devices discovered in source")

		for _, device := range devices {
			logEvent := s.logger.Info().
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

// writeToKV writes device data to the KV store
func (s *SimpleSyncService) writeToKV(ctx context.Context, sourceName string, data map[string][]byte) error {
	if s.kvClient == nil || len(data) == 0 {
		return nil
	}

	source := s.config.Sources[sourceName]

	prefix := source.Prefix
	if prefix == "" {
		prefix = fmt.Sprintf("agents/%s/checkers/sweep", source.AgentID)
	}

	entries := make([]*proto.KeyValueEntry, 0, len(data))

	for key, value := range data {
		fullKey := fmt.Sprintf("%s/%s", prefix, key)
		entries = append(entries, &proto.KeyValueEntry{
			Key:   fullKey,
			Value: value,
		})
	}

	const maxBatchSize = MaxBatchSize

	for i := 0; i < len(entries); i += maxBatchSize {
		end := i + maxBatchSize
		if end > len(entries) {
			end = len(entries)
		}

		batch := entries[i:end]
		if _, err := s.kvClient.PutMany(ctx, &proto.PutManyRequest{Entries: batch}); err != nil {
			s.logger.Error().Err(err).
				Str("source", sourceName).
				Int("batch_size", len(batch)).
				Msg("Failed to write batch to KV")

			return err
		}
	}

	s.logger.Info().
		Str("source", sourceName).
		Int("entries_written", len(entries)).
		Msg("Successfully wrote entries to KV")

	return nil
}

func (s *SimpleSyncService) hydrateCanonicalUpdates(ctx context.Context, updates map[string][]*models.DeviceUpdate) error {
	if s.kvClient == nil || len(updates) == 0 {
		return nil
	}

	paths := s.collectUniqueIdentityPaths(updates)
	if len(paths) == 0 {
		return nil
	}

	entries, errs := s.fetchCanonicalEntries(ctx, paths)
	if len(entries) == 0 {
		return errs
	}

	hydrated := s.applyCanonicalMetadata(updates, entries)

	if hydrated > 0 {
		s.logger.Debug().
			Int("updates", hydrated).
			Msg("Hydrated discovery payloads with canonical identity metadata")
	}

	return errs
}

// collectUniqueIdentityPaths extracts all unique identity key paths from device updates
func (s *SimpleSyncService) collectUniqueIdentityPaths(updates map[string][]*models.DeviceUpdate) []string {
	uniquePaths := make(map[string]struct{})
	paths := make([]string, 0)

	for _, list := range updates {
		for _, update := range list {
			if update == nil {
				continue
			}
			s.addIdentityPathsFromUpdate(update, uniquePaths, &paths)
		}
	}

	return paths
}

// addIdentityPathsFromUpdate adds all identity key path variants from a single update
func (s *SimpleSyncService) addIdentityPathsFromUpdate(
	update *models.DeviceUpdate,
	uniquePaths map[string]struct{},
	paths *[]string,
) {
	keys := identitymap.BuildKeys(update)
	if len(keys) == 0 {
		return
	}

	for _, key := range keys {
		for _, variant := range key.KeyPathVariants(identitymap.DefaultNamespace) {
			sanitized := identitymap.SanitizeKeyPath(variant)
			if sanitized == "" || s.pathExists(sanitized, uniquePaths) {
				continue
			}
			uniquePaths[sanitized] = struct{}{}
			*paths = append(*paths, sanitized)
		}
	}
}

// pathExists checks if a path has already been collected
func (s *SimpleSyncService) pathExists(path string, uniquePaths map[string]struct{}) bool {
	_, exists := uniquePaths[path]
	return exists
}

type canonicalEntry struct {
	record   *identitymap.Record
	revision uint64
}

// fetchCanonicalEntries retrieves canonical identity records from KV store in batches
func (s *SimpleSyncService) fetchCanonicalEntries(ctx context.Context, paths []string) (map[string]canonicalEntry, error) {
	const chunkSize = 512
	entries := make(map[string]canonicalEntry, len(paths))
	var errs error

	if len(paths) == 0 {
		return entries, nil
	}

	g, ctx := errgroup.WithContext(ctx)
	g.SetLimit(8)

	var mu sync.Mutex
	var errMu sync.Mutex

	for start := 0; start < len(paths); start += chunkSize {
		end := start + chunkSize
		if end > len(paths) {
			end = len(paths)
		}

		batch := append([]string(nil), paths[start:end]...)
		batchStart := start

		g.Go(func() error {
			batchEntries, err := s.fetchBatchEntries(ctx, batch, batchStart)
			if len(batchEntries) > 0 {
				mu.Lock()
				for k, v := range batchEntries {
					entries[k] = v
				}
				mu.Unlock()
			}
			if err != nil {
				errMu.Lock()
				errs = errors.Join(errs, err)
				errMu.Unlock()
			}
			return err
		})
	}

	if err := g.Wait(); err != nil {
		return entries, errs
	}

	return entries, errs
}

// fetchBatchEntries fetches a single batch of canonical entries from KV
func (s *SimpleSyncService) fetchBatchEntries(
	ctx context.Context,
	keys []string,
	batchStart int,
) (map[string]canonicalEntry, error) {
	resp, err := s.kvClient.BatchGet(ctx, &proto.BatchGetRequest{Keys: keys})
	if err != nil {
		s.logger.Debug().
			Err(err).
			Int("batch_start", batchStart).
			Int("batch_size", len(keys)).
			Msg("canonical KV batch lookup failed")
		return nil, err
	}

	var errs error
	results := make(map[string]canonicalEntry, len(resp.GetResults()))
	for _, entry := range resp.GetResults() {
		if entry == nil || !entry.GetFound() || len(entry.GetValue()) == 0 {
			continue
		}

		record, err := identitymap.UnmarshalRecord(entry.GetValue())
		if err != nil {
			errs = errors.Join(errs, err)
			s.logger.Debug().
				Err(err).
				Str("key", entry.GetKey()).
				Msg("Failed to unmarshal canonical identity record")
			continue
		}

		results[entry.GetKey()] = canonicalEntry{
			record:   record,
			revision: entry.GetRevision(),
		}
	}

	return results, errs
}

// applyCanonicalMetadata applies canonical identity metadata to device updates
func (s *SimpleSyncService) applyCanonicalMetadata(
	updates map[string][]*models.DeviceUpdate,
	entries map[string]canonicalEntry,
) int {
	var hydrated int

	for _, list := range updates {
		for _, update := range list {
			if update == nil {
				continue
			}

			if s.hydrateUpdate(update, entries) {
				hydrated++
			}
		}
	}

	return hydrated
}

// hydrateUpdate applies canonical metadata to a single update if a matching record exists
func (s *SimpleSyncService) hydrateUpdate(update *models.DeviceUpdate, entries map[string]canonicalEntry) bool {
	keys := identitymap.BuildKeys(update)
	if len(keys) == 0 {
		return false
	}

	record, revision := s.findMatchingCanonicalRecord(keys, entries)
	if record == nil {
		return false
	}

	attachCanonicalMetadataToUpdate(update, record, revision)
	return true
}

// findMatchingCanonicalRecord searches for a canonical record matching any of the given keys
func (s *SimpleSyncService) findMatchingCanonicalRecord(
	keys []identitymap.Key,
	entries map[string]canonicalEntry,
) (*identitymap.Record, uint64) {
	ordered := identitymap.PrioritizeKeys(keys)

	for _, key := range ordered {
		for _, variant := range key.KeyPathVariants(identitymap.DefaultNamespace) {
			if entry, ok := entries[variant]; ok && entry.record != nil {
				return entry.record, entry.revision
			}
		}
	}

	return nil, 0
}

func attachCanonicalMetadataToUpdate(update *models.DeviceUpdate, record *identitymap.Record, revision uint64) {
	if update == nil || record == nil {
		return
	}

	if update.Metadata == nil {
		update.Metadata = make(map[string]string)
	}

	if record.CanonicalDeviceID != "" {
		update.Metadata["canonical_device_id"] = record.CanonicalDeviceID
	}
	if record.Partition != "" {
		update.Metadata["canonical_partition"] = record.Partition
	}
	if record.MetadataHash != "" {
		update.Metadata["canonical_metadata_hash"] = record.MetadataHash
	}
	if hostname, ok := record.Attributes["hostname"]; ok && hostname != "" {
		update.Metadata["canonical_hostname"] = hostname
	}
	if revision != 0 {
		update.Metadata["canonical_revision"] = strconv.FormatUint(revision, 10)
	}
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
		ServiceType: "sync", // Always return "sync" as service type regardless of request
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
			if jsonBytes, err := json.Marshal(devices[0]); err == nil {
				s.logger.Debug().
					Str("source_name", sourceName).
					Str("sample_device", string(jsonBytes)).
					Msg("SYNC DEBUG: Sample device JSON")
			}
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
		ServiceType:     "sync", // Always return "sync" as service type regardless of request
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
func (s *SimpleSyncService) collectDeviceUpdates() []*models.DeviceUpdate {
	var allDeviceUpdates []*models.DeviceUpdate

	for sourceName, devices := range s.resultsStore.results {
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
				Interface("sample_device_metadata", sampleDevice.Metadata).
				Msg("StreamResults - sample device from source")
		}

		allDeviceUpdates = append(allDeviceUpdates, devices...)
	}

	s.logger.Info().
		Int("total_device_updates", len(allDeviceUpdates)).
		Msg("StreamResults - total devices to stream")

	return allDeviceUpdates
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
		if sampleJSON, err := json.Marshal(chunkDevices[0]); err == nil {
			s.logger.Debug().
				Int("chunk_index", chunkIndex).
				Str("sample_device", string(sampleJSON)).
				Msg("SYNC DEBUG: Sample device in chunk")
		}
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

	allDeviceUpdates := s.collectDeviceUpdates()

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

// applySourceBlacklist applies source-specific network blacklist filtering to devices and KV data
func (s *SimpleSyncService) applySourceBlacklist(
	sourceName string,
	devices []*models.DeviceUpdate,
	kvData map[string][]byte) (filteredDevices []*models.DeviceUpdate, filteredKVData map[string][]byte) {
	sourceConfig := s.config.Sources[sourceName]
	if sourceConfig == nil || len(sourceConfig.NetworkBlacklist) == 0 {
		return devices, kvData
	}

	networkBlacklist, err := NewNetworkBlacklist(sourceConfig.NetworkBlacklist, s.logger)
	if err != nil {
		s.logger.Error().Err(err).Str("source", sourceName).Msg("Failed to create network blacklist for source")
		return devices, kvData
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

	// Also filter KV data to remove blacklisted entries
	originalKVCount := len(kvData)
	filteredKVData = networkBlacklist.FilterKVData(kvData, filteredDevices)

	if kvFilteredCount := originalKVCount - len(filteredKVData); kvFilteredCount > 0 {
		s.logger.Info().
			Str("source", sourceName).
			Int("filtered_count", kvFilteredCount).
			Int("remaining_count", len(filteredKVData)).
			Msg("Applied source-specific network blacklist filtering to KV data")
	}

	return filteredDevices, filteredKVData
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
