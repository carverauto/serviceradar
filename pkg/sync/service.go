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
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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

	// Sweep completion tracking
	lastSweepCompleted time.Time
	sweepInProgress    bool
	mu                 sync.RWMutex // Protects sweep completion state

	// Context for managing service lifecycle
	ctx    context.Context
	cancel context.CancelFunc

	// Error handling
	errorChan chan error
	wg        sync.WaitGroup

	logger logger.Logger
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
		logger:              log,
	}

	s.initializeIntegrations(ctx)

	return s, nil
}

// safelyRunTask executes a task function with proper error handling and panic recovery
func (s *SimpleSyncService) safelyRunTask(ctx context.Context, taskName string, task func(context.Context) error) {
	defer s.wg.Done()
	defer func() {
		if r := recover(); r != nil {
			err := fmt.Errorf("panic in %s: %v", taskName, r)
			s.logger.Error().Err(err).Msg("Recovered from panic")
			s.sendError(err)
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
func (s *SimpleSyncService) launchTask(ctx context.Context, taskName string, task func(context.Context) error) {
	s.wg.Add(1)
	go s.safelyRunTask(ctx, taskName, task)
}

// Start begins the simple interval-based discovery and Armis update cycles
func (s *SimpleSyncService) Start(ctx context.Context) error {
	s.logger.Info().Msg("Starting simplified sync service")

	// Start discovery timer
	discoveryTicker := time.NewTicker(s.discoveryInterval)
	defer discoveryTicker.Stop()

	// Start Armis update timer
	armisUpdateTicker := time.NewTicker(s.armisUpdateInterval)
	defer armisUpdateTicker.Stop()

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
		case <-discoveryTicker.C:
			s.launchTask(ctx, "discovery", s.runDiscovery)
		case <-armisUpdateTicker.C:
			s.launchTask(ctx, "armis updates", s.runArmisUpdates)
		}
	}
}

// Stop gracefully stops the sync service
func (s *SimpleSyncService) Stop(_ context.Context) error {
	s.logger.Info().Msg("Stopping simplified sync service")

	if s.cancel != nil {
		s.cancel()
	}

	// Wait for all goroutines to finish
	s.wg.Wait()

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

// runDiscovery executes discovery for all integrations and immediately writes to KV
func (s *SimpleSyncService) runDiscovery(ctx context.Context) error {
	s.logger.Info().
		Time("started_at", time.Now()).
		Msg("Starting discovery cycle")
	s.markSweepStarted()

	allDeviceUpdates := make(map[string][]*models.DeviceUpdate)

	var discoveryErrors []error

	for sourceName, integration := range s.sources {
		s.logger.Info().Str("source", sourceName).Msg("Running discovery for source")

		// Fetch devices from integration. `devices` is now `[]*models.DeviceUpdate`.
		kvData, devices, err := integration.Fetch(ctx)
		if err != nil {
			s.logger.Error().Err(err).Str("source", sourceName).Msg("Discovery failed for source")
			discoveryErrors = append(discoveryErrors, fmt.Errorf("source %s: %w", sourceName, err))

			continue
		}

		// Immediately write device data to KV store
		if err := s.writeToKV(ctx, sourceName, kvData); err != nil {
			s.logger.Error().Err(err).Str("source", sourceName).Msg("Failed to write to KV")
			discoveryErrors = append(discoveryErrors, fmt.Errorf("KV write for source %s: %w", sourceName, err))
		}

		allDeviceUpdates[sourceName] = devices

		s.logger.Info().
			Str("source", sourceName).
			Int("devices_discovered", len(devices)).
			Int("kv_entries_written", len(kvData)).
			Msg("Discovery completed for source")
	}

	// iterate through allDeviceUpdates and print the device names
	for sourceName, devices := range allDeviceUpdates {
		s.logger.Info().
			Str("source", sourceName).
			Int("device_count", len(devices)).
			Msg("Devices discovered in source")

		for _, device := range devices {
			s.logger.Info().
				Str("source", sourceName).
				Str("device_name", device.IP).
				Msg("Discovered device")
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

	s.logger.Info().
		Int("total_devices", totalDevices).
		Int("sources", len(allDeviceUpdates)).
		Msg("Discovery cycle completed")

	s.markSweepCompleted()

	// Return aggregated errors if any occurred
	if len(discoveryErrors) > 0 {
		return fmt.Errorf("discovery completed with %d errors: %w", len(discoveryErrors), errors.Join(discoveryErrors...))
	}

	return nil
}

// runArmisUpdates queries SRQL and updates Armis with device availability
func (s *SimpleSyncService) runArmisUpdates(ctx context.Context) error {
	// Check if we should wait for sweep completion
	if !s.shouldProceedWithUpdates() {
		s.logger.Info().Msg("Waiting for sweep completion before running updates")
		return nil
	}

	s.logger.Info().Msg("Starting Armis update cycle")

	var updateErrors []error

	for sourceName, integration := range s.sources {
		if err := integration.Reconcile(ctx); err != nil {
			s.logger.Error().Err(err).Str("source", sourceName).Msg("Armis update failed for source")
			updateErrors = append(updateErrors, fmt.Errorf("reconcile source %s: %w", sourceName, err))
		}
	}

	s.logger.Info().Msg("Armis update cycle completed")

	// Return aggregated errors if any occurred
	if len(updateErrors) > 0 {
		return fmt.Errorf("armis updates completed with %d errors: %w", len(updateErrors), errors.Join(updateErrors...))
	}

	return nil
}

// shouldProceedWithUpdates checks if enough time has passed since last sweep completion
func (s *SimpleSyncService) shouldProceedWithUpdates() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// If sweep is currently in progress, wait
	if s.sweepInProgress {
		return false
	}

	// If no sweep has completed yet, don't update
	if s.lastSweepCompleted.IsZero() {
		return false
	}

	// Wait at least 30 minutes after sweep completion to ensure data is settled
	minWaitTime := 30 * time.Minute

	return time.Since(s.lastSweepCompleted) >= minWaitTime
}

// markSweepStarted marks that a sweep operation has started
func (s *SimpleSyncService) markSweepStarted() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sweepInProgress = true
	s.logger.Info().Msg("Sweep operation started")
}

// markSweepCompleted marks that a sweep operation has completed
func (s *SimpleSyncService) markSweepCompleted() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sweepInProgress = false
	s.lastSweepCompleted = time.Now()
	s.logger.Info().Time("completed_at", s.lastSweepCompleted).Msg("Sweep operation completed")
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

	const maxBatchSize = 500

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

	logger.Info().
		Int("total_sources", len(s.resultsStore.results)).
		Msg("SYNC DEBUG: GetResults called")

	for sourceName, devices := range s.resultsStore.results {
		logger.Info().
			Str("source_name", sourceName).
			Int("device_count", len(devices)).
			Msg("SYNC DEBUG: Source devices")

		if len(devices) > 0 {
			if jsonBytes, err := json.Marshal(devices[0]); err == nil {
				logger.Debug().
					Str("source_name", sourceName).
					Str("sample_device", string(jsonBytes)).
					Msg("SYNC DEBUG: Sample device JSON")
			}
		}

		allDeviceUpdates = append(allDeviceUpdates, devices...)
	}

	logger.Info().
		Int("total_device_updates", len(allDeviceUpdates)).
		Msg("SYNC DEBUG: About to marshal DeviceUpdate array")

	resultsJSON, err := json.Marshal(allDeviceUpdates)
	if err != nil {
		logger.Error().
			Err(err).
			Int("device_count", len(allDeviceUpdates)).
			Msg("SYNC DEBUG: Failed to marshal DeviceUpdate array")

		return nil, status.Errorf(codes.Internal, "failed to marshal results: %v", err)
	}

	logger.Info().
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

	s.logger.Info().
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

	return factory(ctx, &cfgCopy)
}
