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
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// StreamingResultsStore holds discovery results for streaming
type StreamingResultsStore struct {
	mu      sync.RWMutex
	results map[string][]*models.Device
	updated time.Time
}

// SimpleSyncService manages discovery and serves results via streaming gRPC interface
type SimpleSyncService struct {
	proto.UnimplementedAgentServiceServer
	
	config       Config
	kvClient     KVClient
	sources      map[string]Integration
	registry     map[string]IntegrationFactory
	grpcClient   GRPCClient
	grpcServer   *grpc.Server
	
	// Simplified results storage
	resultsStore *StreamingResultsStore
	
	// Simple interval timers
	discoveryInterval time.Duration
	armisUpdateInterval time.Duration
	
	// Context for managing service lifecycle
	ctx    context.Context
	cancel context.CancelFunc
	
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
			results: make(map[string][]*models.Device),
		},
		discoveryInterval:   6 * time.Hour,
		armisUpdateInterval: 24 * time.Hour,
		ctx:                 serviceCtx,
		cancel:              cancel,
		logger:              log,
	}

	s.initializeIntegrations(ctx)
	
	return s, nil
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
	go func() {
		if err := s.runDiscovery(ctx); err != nil {
			s.logger.Error().Err(err).Msg("Initial discovery failed")
		}
	}()
	
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.ctx.Done():
			return s.ctx.Err()
		case <-discoveryTicker.C:
			go func() {
				if err := s.runDiscovery(ctx); err != nil {
					s.logger.Error().Err(err).Msg("Discovery failed")
				}
			}()
		case <-armisUpdateTicker.C:
			go func() {
				if err := s.runArmisUpdates(ctx); err != nil {
					s.logger.Error().Err(err).Msg("Armis updates failed")
				}
			}()
		}
	}
}

// Stop gracefully stops the sync service
func (s *SimpleSyncService) Stop(ctx context.Context) error {
	s.logger.Info().Msg("Stopping simplified sync service")
	
	if s.cancel != nil {
		s.cancel()
	}
	
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
	s.logger.Info().Msg("Starting discovery cycle")
	
	allDevices := make(map[string][]*models.Device)
	
	for sourceName, integration := range s.sources {
		s.logger.Info().Str("source", sourceName).Msg("Running discovery for source")
		
		// Fetch devices from integration (simplified - no sweep results)
		kvData, devices, err := integration.Fetch(ctx)
		if err != nil {
			s.logger.Error().Err(err).Str("source", sourceName).Msg("Discovery failed for source")
			continue
		}
		
		// Immediately write device data to KV store
		if err := s.writeToKV(ctx, sourceName, kvData); err != nil {
			s.logger.Error().Err(err).Str("source", sourceName).Msg("Failed to write to KV")
		}
		
		// Convert sweep results to devices for storage
		discoveredDevices := make([]*models.Device, len(devices))
		now := time.Now()
		for i, result := range devices {
			// Convert string metadata to interface{} metadata
			metadata := make(map[string]interface{})
			if result.Metadata != nil {
				for k, v := range result.Metadata {
					metadata[k] = v
				}
			}
			
			discoveredDevices[i] = &models.Device{
				DeviceID:         fmt.Sprintf("%s-%s", sourceName, result.IP),
				AgentID:          result.AgentID,
				PollerID:         result.PollerID,
				DiscoverySources: []string{sourceName},
				IP:               result.IP,
				FirstSeen:        now,
				LastSeen:         now,
				IsAvailable:      result.Available,
				Metadata:         metadata,
			}
		}
		
		allDevices[sourceName] = discoveredDevices
		
		s.logger.Info().
			Str("source", sourceName).
			Int("devices_discovered", len(discoveredDevices)).
			Int("kv_entries_written", len(kvData)).
			Msg("Discovery completed for source")
	}
	
	// Store results for GetResults calls
	s.resultsStore.mu.Lock()
	s.resultsStore.results = allDevices
	s.resultsStore.updated = time.Now()
	s.resultsStore.mu.Unlock()
	
	var totalDevices int
	for _, devices := range allDevices {
		totalDevices += len(devices)
	}
	
	s.logger.Info().
		Int("total_devices", totalDevices).
		Int("sources", len(allDevices)).
		Msg("Discovery cycle completed")
	
	return nil
}

// runArmisUpdates queries SRQL and updates Armis with device availability
func (s *SimpleSyncService) runArmisUpdates(ctx context.Context) error {
	s.logger.Info().Msg("Starting Armis update cycle")
	
	for sourceName, integration := range s.sources {
		if err := integration.Reconcile(ctx); err != nil {
			s.logger.Error().Err(err).Str("source", sourceName).Msg("Armis update failed for source")
		}
	}
	
	s.logger.Info().Msg("Armis update cycle completed")
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
		"status":          "healthy",
		"sources":         len(s.resultsStore.results),
		"devices":         deviceCount,
		"last_discovery":  s.resultsStore.updated.Unix(),
		"timestamp":       time.Now().Unix(),
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
		ServiceType: req.ServiceType,
	}, nil
}

// GetResults implements legacy non-streaming interface for backward compatibility
func (s *SimpleSyncService) GetResults(_ context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.resultsStore.mu.RLock()
	defer s.resultsStore.mu.RUnlock()

	var allDevices []*models.Device
	for _, devices := range s.resultsStore.results {
		allDevices = append(allDevices, devices...)
	}

	resultsJSON, err := json.Marshal(allDevices)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to marshal results: %v", err)
	}

	return &proto.ResultsResponse{
		Available:       true,
		Data:            resultsJSON,
		ServiceName:     req.ServiceName,
		ServiceType:     req.ServiceType,
		AgentId:         s.config.AgentID,
		PollerId:        req.PollerId,
		Timestamp:       time.Now().Unix(),
		CurrentSequence: fmt.Sprintf("%d", s.resultsStore.updated.Unix()),
		HasNewData:      true,
	}, nil
}

// StreamResults implements streaming interface for large datasets
func (s *SimpleSyncService) StreamResults(req *proto.ResultsRequest, stream proto.AgentService_StreamResultsServer) error {
	s.resultsStore.mu.RLock()
	defer s.resultsStore.mu.RUnlock()

	var allDevices []*models.Device
	for _, devices := range s.resultsStore.results {
		allDevices = append(allDevices, devices...)
	}

	if len(allDevices) == 0 {
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

	// Calculate chunk size to keep each chunk under ~1MB
	const maxChunkSize = 1024 * 1024 // 1MB
	const avgDeviceSize = 512        // Estimated average device JSON size
	chunkDeviceCount := maxChunkSize / avgDeviceSize

	if chunkDeviceCount == 0 {
		chunkDeviceCount = 1
	}

	totalChunks := (len(allDevices) + chunkDeviceCount - 1) / chunkDeviceCount
	sequence := fmt.Sprintf("%d", s.resultsStore.updated.Unix())

	for chunkIndex := 0; chunkIndex < totalChunks; chunkIndex++ {
		start := chunkIndex * chunkDeviceCount
		end := start + chunkDeviceCount
		if end > len(allDevices) {
			end = len(allDevices)
		}

		chunkDevices := allDevices[start:end]
		chunkData, err := json.Marshal(chunkDevices)
		if err != nil {
			return status.Errorf(codes.Internal, "failed to marshal chunk: %v", err)
		}

		chunk := &proto.ResultsChunk{
			Data:            chunkData,
			IsFinal:         chunkIndex == totalChunks-1,
			ChunkIndex:      int32(chunkIndex),
			TotalChunks:     int32(totalChunks),
			CurrentSequence: sequence,
			Timestamp:       time.Now().Unix(),
		}

		if err := stream.Send(chunk); err != nil {
			if err == io.EOF {
				s.logger.Info().Msg("Client closed stream")
				return nil
			}
			return status.Errorf(codes.Internal, "failed to send chunk: %v", err)
		}
	}

	s.logger.Info().
		Int("total_devices", len(allDevices)).
		Int("total_chunks", totalChunks).
		Str("sequence", sequence).
		Msg("Completed streaming results")

	return nil
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