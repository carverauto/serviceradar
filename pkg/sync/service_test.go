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
	"math"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

func TestSafeIntToInt32(t *testing.T) {
	tests := []struct {
		name     string
		input    int
		expected int32
	}{
		{
			name:     "normal value",
			input:    100,
			expected: 100,
		},
		{
			name:     "max int32",
			input:    math.MaxInt32,
			expected: math.MaxInt32,
		},
		{
			name:     "above max int32",
			input:    int(math.MaxInt32) + 1,
			expected: math.MaxInt32,
		},
		{
			name:     "min int32",
			input:    math.MinInt32,
			expected: math.MinInt32,
		},
		{
			name:     "below min int32",
			input:    int(math.MinInt32) - 1,
			expected: math.MinInt32,
		},
		{
			name:     "zero",
			input:    0,
			expected: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := safeIntToInt32(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestNewSimpleSyncService(t *testing.T) {
	tests := []struct {
		name          string
		config        *Config
		expectError   bool
		errorContains string
	}{
		{
			name: "valid config",
			config: &Config{
				AgentID:           "test-agent",
				PollerID:          "test-poller",
				DiscoveryInterval: models.Duration(time.Minute),
				UpdateInterval:    models.Duration(time.Minute),
				Sources: map[string]*models.SourceConfig{
					"test": {
						Type:     "test",
						Endpoint: "test",
					},
				},
				ListenAddr: "localhost:0",
			},
			expectError: false,
		},
		{
			name: "invalid config",
			config: &Config{
				AgentID:           "",
				PollerID:          "",
				DiscoveryInterval: 0,
				UpdateInterval:    0,
				Sources:           nil,
				ListenAddr:        "",
			},
			expectError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx := context.Background()

			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockKV := NewMockKVClient(ctrl)
			mockGRPC := NewMockGRPCClient(ctrl)
			registry := make(map[string]IntegrationFactory)
			log := logger.NewTestLogger()

			service, err := NewSimpleSyncService(ctx, tt.config, mockKV, registry, mockGRPC, log)

			if tt.expectError {
				require.Error(t, err)
				assert.Nil(t, service)
			} else {
				require.NoError(t, err)
				assert.NotNil(t, service)
				assert.Equal(t, tt.config.AgentID, service.config.AgentID)
				assert.Equal(t, tt.config.PollerID, service.config.PollerID)
				assert.NotNil(t, service.resultsStore)
				assert.NotNil(t, service.resultsStore.results)
			}
		})
	}
}

func TestSimpleSyncService_Stop(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "test",
				Prefix:   "test",
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockGRPC.EXPECT().Close().Return(nil)

	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	err = service.Stop(ctx)
	assert.NoError(t, err)
}

func TestSimpleSyncService_GetStatus(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "test",
				Prefix:   "test",
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	req := &proto.StatusRequest{
		ServiceName: "test-service",
		ServiceType: "sync",
	}

	resp, err := service.GetStatus(ctx, req)
	require.NoError(t, err)
	assert.NotNil(t, resp)
	assert.True(t, resp.Available)
	assert.Equal(t, "test-agent", resp.AgentId)
	assert.Equal(t, "test-service", resp.ServiceName)
	assert.Equal(t, "sync", resp.ServiceType)

	var healthData map[string]interface{}

	err = json.Unmarshal(resp.Message, &healthData)
	require.NoError(t, err)
	assert.Equal(t, "healthy", healthData["status"])
	assert.InDelta(t, float64(0), healthData["sources"], 0.0001)
	assert.InEpsilon(t, time.Now().Unix(), healthData["timestamp"].(float64), 1e-5)
}

func TestSimpleSyncService_GetResults(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "test",
				Prefix:   "test",
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	devices := []*models.DeviceUpdate{
		{
			DeviceID:    "device-1",
			IP:          "192.168.1.1",
			Source:      models.DiscoverySourceIntegration,
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Timestamp:   time.Now(),
			IsAvailable: true,
			Confidence:  100,
		},
		{
			DeviceID:    "device-2",
			IP:          "192.168.1.2",
			Source:      models.DiscoverySourceIntegration,
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Timestamp:   time.Now(),
			IsAvailable: true,
			Confidence:  100,
		},
	}

	service.resultsStore.mu.Lock()
	service.resultsStore.results["test-source"] = devices
	service.resultsStore.updated = time.Now()
	service.resultsStore.mu.Unlock()

	req := &proto.ResultsRequest{
		ServiceName: "test-service",
		ServiceType: "sync",
		PollerId:    "test-poller",
	}

	resp, err := service.GetResults(ctx, req)
	require.NoError(t, err)
	assert.NotNil(t, resp)
	assert.True(t, resp.Available)
	assert.Equal(t, "test-agent", resp.AgentId)
	assert.Equal(t, "test-service", resp.ServiceName)
	assert.Equal(t, "sync", resp.ServiceType)
	assert.Equal(t, "test-poller", resp.PollerId)
	assert.True(t, resp.HasNewData)

	var resultDevices []*models.DeviceUpdate

	err = json.Unmarshal(resp.Data, &resultDevices)
	require.NoError(t, err)
	assert.Len(t, resultDevices, 2)
	assert.Equal(t, "device-1", resultDevices[0].DeviceID)
	assert.Equal(t, "device-2", resultDevices[1].DeviceID)
}

func TestSimpleSyncService_writeToKV(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test-source": {
				Type:     "test",
				Endpoint: "test",
				AgentID:  "test-agent",
				Prefix:   "test-prefix",
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	data := map[string][]byte{
		"key1": []byte("value1"),
		"key2": []byte("value2"),
	}

	mockKV.EXPECT().PutMany(
		ctx, gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, req *proto.PutManyRequest, _ ...grpc.CallOption) (*proto.PutManyResponse, error) {
			if len(req.Entries) != 2 {
				t.Fatalf("expected 2 entries, got %d", len(req.Entries))
			}

			expectedEntries := map[string][]byte{
				"test-prefix/key1": []byte("value1"),
				"test-prefix/key2": []byte("value2"),
			}

			for _, entry := range req.Entries {
				expectedValue, exists := expectedEntries[entry.Key]

				if !exists || string(entry.Value) != string(expectedValue) {
					t.Fatalf("unexpected entry: key=%s, value=%s", entry.Key, string(entry.Value))
				}
			}

			return &proto.PutManyResponse{}, nil
		})

	err = service.writeToKV(ctx, "test-source", data)
	assert.NoError(t, err)
}

func TestSimpleSyncService_writeToKV_WithDefaultPrefix(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test-source": {
				Type:     "test",
				Endpoint: "test",
				AgentID:  "test-agent",
				Prefix:   "", // Testing default prefix behavior
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	data := map[string][]byte{
		"key1": []byte("value1"),
	}

	expectedPrefix := "agents/test-agent/checkers/sweep"

	mockKV.EXPECT().PutMany(ctx, gomock.Any(), gomock.Any()).
		DoAndReturn(func(
			_ context.Context, req *proto.PutManyRequest, _ ...grpc.CallOption) (*proto.PutManyResponse, error) {
			if len(req.Entries) != 1 || req.Entries[0].Key != expectedPrefix+"/key1" {
				t.Fatalf("unexpected entry: key=%s", req.Entries[0].Key)
			}

			return &proto.PutManyResponse{}, nil
		})

	err = service.writeToKV(ctx, "test-source", data)
	assert.NoError(t, err)
}

func TestSimpleSyncService_writeToKV_EmptyData(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "test",
				Prefix:   "test",
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	err = service.writeToKV(ctx, "test-source", map[string][]byte{})
	assert.NoError(t, err)
}

func TestSimpleSyncService_writeToKV_NilKVClient(t *testing.T) {
	ctx := context.Background()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "test",
				Prefix:   "test",
			},
		},
		ListenAddr: "localhost:0",
	}

	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, nil, registry, nil, log)
	require.NoError(t, err)

	data := map[string][]byte{
		"key1": []byte("value1"),
	}

	err = service.writeToKV(ctx, "test-source", data)
	assert.NoError(t, err)
}

func TestSimpleSyncService_shouldProceedWithUpdates(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "test",
				Prefix:   "test",
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	should := service.shouldProceedWithUpdates()
	assert.False(t, should)

	service.markSweepStarted()
	should = service.shouldProceedWithUpdates()
	assert.False(t, should)

	service.markSweepCompleted()
	should = service.shouldProceedWithUpdates()
	assert.False(t, should)

	service.mu.Lock()
	service.lastSweepCompleted = time.Now().Add(-31 * time.Minute)
	service.mu.Unlock()

	should = service.shouldProceedWithUpdates()
	assert.True(t, should)
}

func TestSimpleSyncService_markSweepOperations(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "test",
				Prefix:   "test",
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	assert.False(t, service.sweepInProgress)
	assert.True(t, service.lastSweepCompleted.IsZero())

	service.markSweepStarted()
	assert.True(t, service.sweepInProgress)

	service.markSweepCompleted()
	assert.False(t, service.sweepInProgress)
	assert.False(t, service.lastSweepCompleted.IsZero())
}

func TestSimpleSyncService_createIntegration(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "test",
				Prefix:   "test",
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	mockIntegration := NewMockIntegration(ctrl)
	factory := func(_ context.Context, cfg *models.SourceConfig, _ logger.Logger) Integration {
		assert.Equal(t, "test-agent", cfg.AgentID)
		assert.Equal(t, "test-poller", cfg.PollerID)
		assert.Equal(t, "default", cfg.Partition)

		return mockIntegration
	}

	src := &models.SourceConfig{
		Type: "test-type",
	}

	integration := service.createIntegration(ctx, src, factory)
	assert.Equal(t, mockIntegration, integration)
}

func TestSimpleSyncService_createIntegration_WithExistingValues(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "test",
				Prefix:   "test",
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	mockIntegration := NewMockIntegration(ctrl)
	factory := func(_ context.Context, cfg *models.SourceConfig, _ logger.Logger) Integration {
		assert.Equal(t, "existing-agent", cfg.AgentID)
		assert.Equal(t, "existing-poller", cfg.PollerID)
		assert.Equal(t, "existing-partition", cfg.Partition)

		return mockIntegration
	}

	src := &models.SourceConfig{
		Type:      "test-type",
		AgentID:   "existing-agent",
		PollerID:  "existing-poller",
		Partition: "existing-partition",
	}

	integration := service.createIntegration(ctx, src, factory)
	assert.Equal(t, mockIntegration, integration)
}

// MockResultsStream implements the proto.AgentService_StreamResultsServer interface
type MockResultsStream struct {
	ctx     context.Context
	chunks  []*proto.ResultsChunk
	sendErr error
}

func (m *MockResultsStream) Send(chunk *proto.ResultsChunk) error {
	if m.sendErr != nil {
		return m.sendErr
	}

	m.chunks = append(m.chunks, chunk)

	return nil
}

func (*MockResultsStream) SetHeader(metadata.MD) error  { return nil }
func (*MockResultsStream) SendHeader(metadata.MD) error { return nil }
func (*MockResultsStream) SetTrailer(metadata.MD)       {}
func (m *MockResultsStream) Context() context.Context   { return m.ctx }
func (*MockResultsStream) SendMsg(_ interface{}) error  { return nil }
func (*MockResultsStream) RecvMsg(_ interface{}) error  { return nil }

func TestSimpleSyncService_StreamResults(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "test",
				Prefix:   "test",
			},
		},
		ListenAddr: "localhost:0",
	}

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, mockKV, registry, mockGRPC, log)
	require.NoError(t, err)

	t.Run("empty results", func(t *testing.T) {
		req := &proto.ResultsRequest{
			ServiceName: "test-service",
			ServiceType: "sync",
		}

		stream := &MockResultsStream{ctx: ctx}
		err := service.StreamResults(req, stream)
		require.NoError(t, err)
		assert.Len(t, stream.chunks, 1)
		assert.True(t, stream.chunks[0].IsFinal)
		assert.Equal(t, []byte("[]"), stream.chunks[0].Data)
	})

	t.Run("with devices", func(t *testing.T) {
		// Create many devices to test chunking
		var devices []*models.DeviceUpdate

		for i := 0; i < 2000; i++ {
			devices = append(devices, &models.DeviceUpdate{
				DeviceID:    fmt.Sprintf("device-%d", i),
				IP:          fmt.Sprintf("192.168.1.%d", i%255),
				Source:      models.DiscoverySourceIntegration,
				AgentID:     "test-agent",
				PollerID:    "test-poller",
				Timestamp:   time.Now(),
				IsAvailable: true,
				Confidence:  100,
			})
		}

		service.resultsStore.mu.Lock()
		service.resultsStore.results["test-source"] = devices
		service.resultsStore.updated = time.Now()
		service.resultsStore.mu.Unlock()

		req := &proto.ResultsRequest{
			ServiceName: "test-service",
			ServiceType: "sync",
		}

		stream := &MockResultsStream{ctx: ctx}
		err := service.StreamResults(req, stream)
		require.NoError(t, err)
		assert.Greater(t, len(stream.chunks), 1) // Should have multiple chunks

		// Verify last chunk is marked as final
		lastChunk := stream.chunks[len(stream.chunks)-1]
		assert.True(t, lastChunk.IsFinal)

		// Verify all chunks have the same sequence
		firstSequence := stream.chunks[0].CurrentSequence
		for _, chunk := range stream.chunks {
			assert.Equal(t, firstSequence, chunk.CurrentSequence)
		}

		// Verify chunk indices
		for i, chunk := range stream.chunks {
			assert.Equal(t, safeIntToInt32(i), chunk.ChunkIndex)
			assert.Equal(t, safeIntToInt32(len(stream.chunks)), chunk.TotalChunks)
		}
	})

	t.Run("stream error", func(t *testing.T) {
		devices := []*models.DeviceUpdate{
			{
				DeviceID:    "device-1",
				IP:          "192.168.1.1",
				Source:      models.DiscoverySourceIntegration,
				AgentID:     "test-agent",
				PollerID:    "test-poller",
				Timestamp:   time.Now(),
				IsAvailable: true,
				Confidence:  100,
			},
		}

		service.resultsStore.mu.Lock()
		service.resultsStore.results["test-source"] = devices
		service.resultsStore.updated = time.Now()
		service.resultsStore.mu.Unlock()

		req := &proto.ResultsRequest{
			ServiceName: "test-service",
			ServiceType: "sync",
		}

		expectedErr := errors.New("stream send error")
		stream := &MockResultsStream{ctx: ctx, sendErr: expectedErr}

		err := service.StreamResults(req, stream)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "failed to send chunk")
	})
}
