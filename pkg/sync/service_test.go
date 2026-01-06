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
	"math"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	testOperationDelay = 5 * time.Millisecond
	testWaitTimeout    = 250 * time.Millisecond
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

			registry := make(map[string]IntegrationFactory)
			log := logger.NewTestLogger()

			service, err := NewSimpleSyncService(ctx, tt.config, registry, log)

			if tt.expectError {
				require.Error(t, err)
				assert.Nil(t, service)
			} else {
				require.NoError(t, err)
				assert.NotNil(t, service)

				defer func() { _ = service.Stop(context.Background()) }()

				assert.Equal(t, tt.config.AgentID, service.config.AgentID)
				assert.Equal(t, tt.config.PollerID, service.config.PollerID)
				assert.NotNil(t, service.resultsStore)
			}
		})
	}
}

func TestSimpleSyncService_Stop(t *testing.T) {
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

	service, err := NewSimpleSyncService(ctx, config, registry, log)
	require.NoError(t, err)

	err = service.Stop(ctx)
	assert.NoError(t, err)
}

func TestSimpleSyncService_GetStatus(t *testing.T) {
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

	service, err := NewSimpleSyncService(ctx, config, registry, log)
	require.NoError(t, err)

	defer func() { _ = service.Stop(context.Background()) }()

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

// Removed TestSimpleSyncService_GetResults - GetResults is deprecated (pull-based polling)
// Removed TestSimpleSyncService_shouldProceedWithUpdates and TestSimpleSyncService_markSweepOperations
// as the sweep timing logic was removed

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

	registry := make(map[string]IntegrationFactory)

	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, registry, log)
	require.NoError(t, err)

	defer func() { _ = service.Stop(context.Background()) }()

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

	registry := make(map[string]IntegrationFactory)

	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, registry, log)
	require.NoError(t, err)

	defer func() { _ = service.Stop(context.Background()) }()

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

func TestSimpleSyncService_StreamResultsDeprecated(t *testing.T) {
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

	registry := make(map[string]IntegrationFactory)

	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, config, registry, log)
	require.NoError(t, err)

	defer func() { _ = service.Stop(context.Background()) }()

	req := &proto.ResultsRequest{
		ServiceName: "test-service",
		ServiceType: "sync",
	}

	err = service.StreamResults(req, nil)
	require.Error(t, err)
	assert.Equal(t, codes.Unimplemented, status.Code(err))
}

func TestBuildResultsChunks(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, &Config{
		ListenAddr: "localhost:0",
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "http://example.com",
			},
		},
	}, nil, log)
	require.NoError(t, err)

	t.Run("empty", func(t *testing.T) {
		chunks, err := service.buildResultsChunks(nil, "seq-0")
		require.NoError(t, err)
		require.Len(t, chunks, 1)
		assert.True(t, chunks[0].IsFinal)
		assert.Equal(t, []byte("[]"), chunks[0].Data)
	})

	t.Run("splits large payloads", func(t *testing.T) {
		chunkLimit := resultsChunkMaxSize
		if testing.Short() {
			originalLimit := resultsChunkMaxSize
			chunkLimit = 256 * 1024
			resultsChunkMaxSize = chunkLimit
			t.Cleanup(func() { resultsChunkMaxSize = originalLimit })
		}

		payloadSize := chunkLimit / 64
		deviceCount := (chunkLimit / payloadSize) + 2
		largePayload := strings.Repeat("a", payloadSize)
		var devices []*models.DeviceUpdate
		for i := 0; i < deviceCount; i++ {
			devices = append(devices, &models.DeviceUpdate{
				DeviceID:    fmt.Sprintf("device-%d", i),
				IP:          fmt.Sprintf("192.168.1.%d", i%255),
				Source:      models.DiscoverySourceIntegration,
				AgentID:     "test-agent",
				PollerID:    "test-poller",
				Timestamp:   time.Now(),
				IsAvailable: true,
				Confidence:  100,
				Metadata: map[string]string{
					"blob": largePayload,
				},
			})
		}

		chunks, err := service.buildResultsChunks(devices, "seq-1")
		require.NoError(t, err)
		require.Greater(t, len(chunks), 1)

		for i, chunk := range chunks {
			assert.Equal(t, safeIntToInt32(i), chunk.ChunkIndex)
			assert.Equal(t, safeIntToInt32(len(chunks)), chunk.TotalChunks)
			assert.LessOrEqual(t, len(chunk.Data), chunkLimit)
		}
	})
}

func TestBuildGatewayStatusChunks(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, &Config{
		ListenAddr: "localhost:0",
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "http://example.com",
			},
		},
	}, nil, log)
	require.NoError(t, err)

	payload := []byte(`[{"device_id":"dev-1"}]`)
	chunk := &proto.ResultsChunk{
		Data:            payload,
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: "seq-42",
		Timestamp:       12345,
	}

	statusChunks := service.buildGatewayStatusChunks([]*proto.ResultsChunk{chunk}, "tenant-1", "tenant-slug")
	require.Len(t, statusChunks, 1)

	statusChunk := statusChunks[0]
	require.Len(t, statusChunk.Services, 1)

	serviceStatus := statusChunk.Services[0]
	assert.Equal(t, syncServiceName, serviceStatus.ServiceName)
	assert.Equal(t, syncServiceType, serviceStatus.ServiceType)
	assert.Equal(t, syncResultsSource, serviceStatus.Source)
	assert.Equal(t, payload, serviceStatus.Message)
	assert.Equal(t, "tenant-1", serviceStatus.TenantId)
	assert.Equal(t, "tenant-slug", serviceStatus.TenantSlug)
	assert.Equal(t, chunk.Timestamp, statusChunk.Timestamp)
	assert.Equal(t, chunk.ChunkIndex, statusChunk.ChunkIndex)
	assert.Equal(t, chunk.TotalChunks, statusChunk.TotalChunks)
	assert.True(t, statusChunk.IsFinal)
}

func TestBuildResultsChunksSizeBudget(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	service, err := NewSimpleSyncService(ctx, &Config{
		ListenAddr: "localhost:0",
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				Endpoint: "http://example.com",
			},
		},
	}, nil, log)
	require.NoError(t, err)

	chunkLimit := resultsChunkMaxSize
	if testing.Short() {
		originalLimit := resultsChunkMaxSize
		chunkLimit = 256 * 1024
		resultsChunkMaxSize = chunkLimit
		t.Cleanup(func() { resultsChunkMaxSize = originalLimit })
	}

	payloadSize := chunkLimit / 4
	deviceCount := 5
	largeValue := strings.Repeat("a", payloadSize)

	var devices []*models.DeviceUpdate
	for i := 0; i < deviceCount; i++ {
		devices = append(devices, &models.DeviceUpdate{
			DeviceID:    fmt.Sprintf("device-%d", i),
			IP:          fmt.Sprintf("10.0.0.%d", i+1),
			Source:      models.DiscoverySourceIntegration,
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Timestamp:   time.Now(),
			IsAvailable: true,
			Confidence:  100,
			Metadata: map[string]string{
				"blob": fmt.Sprintf("%s-%d", largeValue, i),
			},
		})
	}

	chunks, err := service.buildResultsChunks(devices, "seq-blob")
	require.NoError(t, err)
	require.Greater(t, len(chunks), 1)

	var decodedCount int
	for _, chunk := range chunks {
		require.LessOrEqual(t, len(chunk.Data), chunkLimit)

		var updates []*models.DeviceUpdate
		require.NoError(t, json.Unmarshal(chunk.Data, &updates))
		decodedCount += len(updates)
	}

	assert.Equal(t, len(devices), decodedCount)
}

func TestGroupSourcesByTenantScope(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	config := &Config{
		AgentID:      "test-agent",
		TenantID:     "tenant-default",
		TenantSlug:   "default",
		ListenAddr:   "localhost:0",
		PollInterval: models.Duration(time.Minute),
		Sources: map[string]*models.SourceConfig{
			"source-a": {
				Type:     "armis",
				Endpoint: "https://example.com",
			},
		},
	}

	service, err := NewSimpleSyncService(ctx, config, map[string]IntegrationFactory{}, log)
	require.NoError(t, err)

	t.Run("platform scope requires tenant ids", func(t *testing.T) {
		grouped, slugs := service.groupSourcesByTenant(config.Sources, "platform")
		assert.Empty(t, grouped)
		assert.Empty(t, slugs)
	})

	t.Run("tenant scope defaults to service tenant", func(t *testing.T) {
		grouped, slugs := service.groupSourcesByTenant(config.Sources, "tenant")
		assert.Len(t, grouped, 1)
		assert.Contains(t, grouped, "tenant-default")
		assert.Equal(t, "default", slugs["tenant-default"])
	})
}

func TestSourceSpecificNetworkBlacklist(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create a mock integration that returns devices with various IPs
	mockIntegration := NewMockIntegration(ctrl)
	mockIntegration.EXPECT().Fetch(gomock.Any()).Return(
		[]*models.DeviceUpdate{
			{IP: "192.168.1.100", Source: models.DiscoverySourceNetbox}, // Should be filtered for netbox
			{IP: "10.0.0.50", Source: models.DiscoverySourceNetbox},     // Should be filtered for netbox
			{IP: "8.8.8.8", Source: models.DiscoverySourceNetbox},       // Should pass for netbox
			{IP: "172.16.0.1", Source: models.DiscoverySourceNetbox},    // Should be filtered for armis
		},
		nil,
	).AnyTimes()

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, _ *models.SourceConfig, _ logger.Logger) Integration {
			return mockIntegration
		},
	}

	config := &Config{
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:     "netbox",
				Endpoint: "http://example.com",
				// Netbox has its own blacklist - should filter 192.168.0.0/16 and 10.0.0.0/8
				NetworkBlacklist: []string{"192.168.0.0/16", "10.0.0.0/8"},
			},
		},
		ListenAddr:        ":8080",
		DiscoveryInterval: models.Duration(1 * time.Minute),
		UpdateInterval:    models.Duration(5 * time.Minute),
	}

	service, err := NewSimpleSyncService(
		context.Background(),
		config,
		registry,
		logger.NewTestLogger(),
	)
	require.NoError(t, err)

	defer func() { _ = service.Stop(context.Background()) }()

	// Run discovery
	ctx := context.Background()
	allDeviceUpdates, discoveryErrors := service.runDiscoveryForIntegrations(ctx, "", "", service.sources)
	require.Empty(t, discoveryErrors)

	// Verify that results were filtered
	results := allDeviceUpdates["netbox"]

	// Should only have devices that passed the blacklist filter
	assert.Len(t, results, 2, "Should have 2 devices after blacklist filtering")

	// Verify the remaining devices are the non-blacklisted ones
	deviceIPs := make([]string, len(results))
	for i, device := range results {
		deviceIPs[i] = device.IP
	}

	assert.ElementsMatch(t, []string{"8.8.8.8", "172.16.0.1"}, deviceIPs, "Should only contain non-blacklisted IPs")
}

func TestSimpleSyncService_runArmisUpdates_OverlapPrevention(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockIntegration := NewMockIntegration(ctrl)

	log := logger.NewTestLogger()

	registry := map[string]IntegrationFactory{
		"test": func(_ context.Context, _ *models.SourceConfig, _ logger.Logger) Integration {
			return mockIntegration
		},
	}

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(time.Minute),
		UpdateInterval:    models.Duration(time.Minute),
		ListenAddr:        ":9090",
		Sources: map[string]*models.SourceConfig{
			"test": {
				Type:     "test",
				AgentID:  "test-agent",
				Endpoint: "http://test.example.com",
			},
		},
	}

	ctx := context.Background()
	service, err := NewSimpleSyncService(ctx, config, registry, log)
	require.NoError(t, err)

	defer func() { _ = service.Stop(context.Background()) }()

	reconcileCallCount := 0
	reconcileStarted := make(chan struct{})
	reconcileFinished := make(chan struct{})

	// Mock the integration to simulate a slow reconcile operation
	// Due to overlap prevention, this should only be called once
	mockIntegration.EXPECT().Reconcile(gomock.Any()).DoAndReturn(func(ctx context.Context) error {
		reconcileCallCount++
		reconcileStarted <- struct{}{}

		// Simulate slow operation - use shorter duration for tests
		select {
		case <-time.After(testOperationDelay):
		case <-ctx.Done():
			return ctx.Err()
		}

		reconcileFinished <- struct{}{}
		return nil
	}).Times(1) // Expect exactly one call due to overlap prevention

	firstCallDone := make(chan error, 1)
	secondCallDone := make(chan error, 1)

	// Start first Armis update
	go func() {
		err := service.runArmisUpdates(ctx)
		firstCallDone <- err
	}()

	// Wait for first reconcile to start
	<-reconcileStarted

	// Start second Armis update while first is still running
	go func() {
		err := service.runArmisUpdates(ctx)
		secondCallDone <- err
	}()

	// Wait for first reconcile to finish
	<-reconcileFinished

	// Wait for both calls to complete with generous timeout
	select {
	case err := <-firstCallDone:
		require.NoError(t, err, "First call should succeed")
	case <-time.After(testWaitTimeout):
		t.Fatal("First call did not complete in time")
	}

	select {
	case err := <-secondCallDone:
		require.NoError(t, err, "Second call should return nil (skipped due to overlap prevention)")
	case <-time.After(testWaitTimeout):
		t.Fatal("Second call did not complete in time")
	}

	// Verify only one reconcile was called (overlap prevented)
	assert.Equal(t, 1, reconcileCallCount, "Should have called reconcile only once due to overlap prevention")
}
