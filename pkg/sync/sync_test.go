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
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/poller"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

// testLogger creates a no-op logger for tests
func testLogger() logger.Logger {
	config := &logger.Config{
		Level:  "disabled",
		Output: "stderr",
	}

	log, err := lifecycle.CreateLogger(context.Background(), config)
	if err != nil {
		panic(err)
	}

	return log
}

func TestNew_ValidConfig(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	// Expect GetConnection call for integration initialization
	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:        "armis",
				Endpoint:    "http://example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50053",
		PollInterval: models.Duration(1 * time.Second),
		Security:     &models.SecurityConfig{},
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return NewMockIntegration(ctrl)
		},
	}

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)
	assert.NotNil(t, syncer)
	assert.NotEmpty(t, syncer.pollers)
	// Check that at least one poller was created
	for _, p := range syncer.pollers {
		assert.NotNil(t, p.PollFunc)
		break
	}
}

func TestSync_Success(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:        "armis",
				Endpoint:    "http://example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50052",
		PollInterval: models.Duration(1 * time.Second),
		Security:     &models.SecurityConfig{},
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	data := map[string][]byte{"devices": []byte("data")}
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil, nil)
	mockKV.EXPECT().PutMany(gomock.Any(), &proto.PutManyRequest{
		Entries: []*proto.KeyValueEntry{{Key: "armis/devices", Value: []byte("data")}},
	}, gomock.Any()).Return(&proto.PutManyResponse{}, nil)

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)

	// Test the syncSourceDiscovery method for the armis source
	err = syncer.syncSourceDiscovery(context.Background(), "armis")
	assert.NoError(t, err)
}

func TestStartAndStop(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)
	mockTicker := poller.NewMockTicker(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:        "armis",
				Endpoint:    "http://example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50054",
		PollInterval: models.Duration(500 * time.Millisecond),
		Security:     &models.SecurityConfig{},
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	tickChan := make(chan time.Time, 1)

	mockClock.EXPECT().Ticker(500 * time.Millisecond).Return(mockTicker)

	mockTicker.EXPECT().Chan().Return(tickChan).AnyTimes()
	mockTicker.EXPECT().Stop().AnyTimes()

	data := map[string][]byte{"devices": []byte("data")}

	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil, nil).Times(2) // Initial poll + 1 tick
	mockKV.EXPECT().PutMany(gomock.Any(), gomock.Any(), gomock.Any()).Return(&proto.PutManyResponse{}, nil).Times(2)

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	startDone := make(chan struct{})
	tickProcessed := make(chan struct{})

	var startErr error

	// Get the first poller (there should be one for 'armis')
	var firstPoller *poller.Poller
	for _, p := range syncer.pollers {
		firstPoller = p
		break
	}

	require.NotNil(t, firstPoller)

	originalPollFunc := firstPoller.PollFunc
	firstPoller.PollFunc = func(ctx context.Context) error {
		err := originalPollFunc(ctx)
		if err == nil {
			select {
			case tickProcessed <- struct{}{}:
			default:
			}
		}

		return err
	}

	go func() {
		startErr = syncer.Start(ctx)
		assert.Equal(t, context.Canceled, startErr)
		close(startDone)
	}()

	time.Sleep(10 * time.Millisecond) // Allow initial poll
	tickChan <- time.Now()            // Trigger a tick

	<-tickProcessed // Wait for tick to process

	cancel()    // Stop the poller
	<-startDone // Wait for Start to exit

	stopErr := syncer.Stop(context.Background())
	assert.NoError(t, stopErr)
}

func TestStart_ContextCancellation(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)
	mockTicker := poller.NewMockTicker(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:        "armis",
				Endpoint:    "http://example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50053",
		PollInterval: models.Duration(1 * time.Second),
		Security:     &models.SecurityConfig{},
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	tickChan := make(chan time.Time)

	mockClock.EXPECT().Ticker(1 * time.Second).Return(mockTicker)
	mockTicker.EXPECT().Chan().Return(tickChan).AnyTimes()
	mockTicker.EXPECT().Stop()

	data := map[string][]byte{"devices": []byte("data")}

	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil, nil)
	mockKV.EXPECT().PutMany(gomock.Any(), &proto.PutManyRequest{
		Entries: []*proto.KeyValueEntry{{Key: "armis/devices", Value: []byte("data")}},
	}, gomock.Any()).Return(&proto.PutManyResponse{}, nil)

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel() // Defer for safety, even with explicit calls

	lifecycleDone := make(chan struct{})
	initialPollDone := make(chan struct{})

	// Wrap the poller's PollFunc to signal when the initial poll is done
	var p *poller.Poller
	for _, pollerInstance := range syncer.pollers {
		p = pollerInstance
		break
	}

	require.NotNil(t, p, "No poller was created")

	originalPollFunc := p.PollFunc
	p.PollFunc = func(ctx context.Context) error {
		err := originalPollFunc(ctx)
		select {
		case initialPollDone <- struct{}{}:
		default:
		}

		return err
	}

	// Run the full lifecycle (Start and Stop) in a goroutine
	go func() {
		defer close(lifecycleDone)

		// Start returns when the context is canceled
		startErr := syncer.Start(ctx)
		assert.ErrorIs(t, startErr, context.Canceled)

		// Immediately stop the syncer. This is where the ticker.Stop() is called.
		stopErr := syncer.Stop(context.Background())
		assert.NoError(t, stopErr)
	}()

	// 1. Wait for the poller to run its first poll.
	<-initialPollDone

	// 2. Cancel the context to stop the syncer's Start loop.
	cancel()

	// 3. Wait for the goroutine (including the Stop call) to complete.
	<-lifecycleDone
}

func TestSync_NetboxSuccess(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:        "netbox",
				Endpoint:    "https://netbox.example.com",
				Prefix:      "netbox/",
				Credentials: map[string]string{"api_token": "token"},
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50055",
		PollInterval: models.Duration(1 * time.Second),
	}

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	data := map[string][]byte{"1": []byte(`{"id":1,"name":"device1","primary_ip4":{"address":"192.168.1.1/24"}}`)}
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil, nil)
	mockKV.EXPECT().PutMany(gomock.Any(), &proto.PutManyRequest{
		Entries: []*proto.KeyValueEntry{{Key: "netbox/1", Value: []byte(`{"id":1,"name":"device1","primary_ip4":{"address":"192.168.1.1/24"}}`)}},
	}, gomock.Any()).Return(&proto.PutManyResponse{}, nil)

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)

	// Test the syncSourceDiscovery method for the netbox source
	err = syncer.syncSourceDiscovery(context.Background(), "netbox")
	assert.NoError(t, err)
}

func TestCreateIntegrationAppliesDefaults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	var gotAgent, gotPoller string

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, cfg *models.SourceConfig) Integration {
			gotAgent = cfg.AgentID
			gotPoller = cfg.PollerID
			return NewMockIntegration(ctrl)
		},
	}

	c := &Config{
		AgentID:      "global-agent",
		PollerID:     "global-poller",
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50056",
		PollInterval: models.Duration(1 * time.Second),
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:     "netbox",
				Endpoint: "https://netbox.example.com",
				Prefix:   "netbox/",
				AgentID:  "source-agent",
				PollerID: "source-poller",
			},
		},
	}

	_, err := New(context.Background(), c, mockKV, registry, mockGRPC, mockClock, testLogger())
	require.NoError(t, err)

	assert.Equal(t, "source-agent", gotAgent)
	assert.Equal(t, "source-poller", gotPoller)
}

func TestCreateIntegrationUsesGlobalDefaults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	var gotAgent, gotPoller string

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, cfg *models.SourceConfig) Integration {
			gotAgent = cfg.AgentID
			gotPoller = cfg.PollerID
			return NewMockIntegration(ctrl)
		},
	}

	c := &Config{
		AgentID:      "global-agent",
		PollerID:     "global-poller",
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50057",
		PollInterval: models.Duration(1 * time.Second),
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:     "netbox",
				Endpoint: "https://netbox.example.com",
				Prefix:   "netbox/",
			},
		},
	}

	_, err := New(context.Background(), c, mockKV, registry, mockGRPC, nil, testLogger())
	require.NoError(t, err)

	assert.Equal(t, "global-agent", gotAgent)
	assert.Equal(t, "global-poller", gotPoller)
}

func TestWriteToKVTransformsDeviceID(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)

	s := &PollerService{
		config: Config{
			Sources: map[string]*models.SourceConfig{
				"netbox": {
					Prefix:   "netbox/",
					AgentID:  "agent1",
					PollerID: "poller1",
				},
			},
			AgentID:    "agent1",
			PollerID:   "poller1",
			ListenAddr: ":50058",
		},
		kvClient: mockKV,
		logger:   testLogger(),
	}

	data := map[string][]byte{
		"partition1:10.0.0.1": []byte("val"),
	}

	mockKV.EXPECT().PutMany(gomock.Any(), &proto.PutManyRequest{
		Entries: []*proto.KeyValueEntry{{Key: "netbox/agent1/poller1/partition1/10.0.0.1", Value: []byte("val")}},
	}, gomock.Any()).Return(&proto.PutManyResponse{}, nil)

	s.writeToKV(context.Background(), "netbox", data)
}

func TestWriteToKVBatchesLargeDataSets(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)

	s := &PollerService{
		config: Config{
			Sources: map[string]*models.SourceConfig{
				"armis": {
					Prefix:   "armis/",
					AgentID:  "agent1",
					PollerID: "poller1",
				},
			},
			AgentID:    "agent1",
			PollerID:   "poller1",
			ListenAddr: ":50058",
		},
		kvClient: mockKV,
		logger:   testLogger(),
	}

	// Create a large dataset that would exceed the 4MB limit if sent as one batch
	data := make(map[string][]byte)
	largeValue := make([]byte, 2*1024) // 2KB per entry

	for i := 0; i < 1600; i++ { // 1600 * 2KB = 3.2MB of values alone
		key := fmt.Sprintf("partition1:10.0.%d.%d", i/256, i%256)
		data[key] = largeValue
	}

	// Expect multiple PutMany calls due to batching
	// With 500 entries per batch, we should see 4 batches (1600 / 500 = 3.2, so 4 batches)
	batchCount := 0

	mockKV.EXPECT().PutMany(gomock.Any(), gomock.Any(), gomock.Any()).DoAndReturn(
		func(_ context.Context, req *proto.PutManyRequest, _ ...interface{}) (*proto.PutManyResponse, error) {
			batchCount++
			// Verify batch size constraints
			assert.LessOrEqual(t, len(req.Entries), 500, "Batch should not exceed 500 entries")

			// Calculate approximate size of this batch
			batchSize := 0
			for _, entry := range req.Entries {
				batchSize += len(entry.Key) + len(entry.Value) + 32
			}

			assert.Less(t, batchSize, 3*1024*1024, "Batch size should be less than 3MB")

			return &proto.PutManyResponse{}, nil
		},
	).Times(4)

	s.writeToKV(context.Background(), "armis", data)

	assert.Equal(t, 4, batchCount, "Should have created 4 batches")
}

func TestCreateIntegrationSetsDefaultPartition(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	var gotPartition string

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, cfg *models.SourceConfig) Integration {
			gotPartition = cfg.Partition
			return NewMockIntegration(ctrl)
		},
	}

	c := &Config{
		AgentID:      "global-agent",
		PollerID:     "global-poller",
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50057",
		PollInterval: models.Duration(1 * time.Second),
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:     "netbox",
				Endpoint: "https://netbox.example.com",
				Prefix:   "netbox/",
			},
		},
	}

	_, err := New(context.Background(), c, mockKV, registry, mockGRPC, nil, testLogger())
	require.NoError(t, err)

	assert.Equal(t, "default", gotPartition)
}

func TestSeparateSyncAndSweepPollers(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	// Expect GetConnection call for integration initialization
	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:          "armis",
				Endpoint:      "http://example.com",
				Prefix:        "armis/",
				Credentials:   map[string]string{"api_key": "key"},
				PollInterval:  models.Duration(15 * time.Minute), // Sync every 15 minutes
				SweepInterval: "10m",                             // Sweep every 10 minutes
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50053",
		PollInterval: models.Duration(5 * time.Minute), // Default poll interval
		Security:     &models.SecurityConfig{},
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return NewMockIntegration(ctrl)
		},
	}

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)
	assert.NotNil(t, syncer)

	// Should have created two pollers: one for sync, one for sweep
	assert.Len(t, syncer.pollers, 2)

	// Check that both pollers exist with correct names
	_, hasSyncPoller := syncer.pollers["armis-sync"]
	_, hasSweepPoller := syncer.pollers["armis-sweep"]

	assert.True(t, hasSyncPoller, "Should have created sync poller")
	assert.True(t, hasSweepPoller, "Should have created sweep poller")
}

func TestSyncWithoutSweepInterval(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:         "netbox",
				Endpoint:     "https://netbox.example.com",
				Prefix:       "netbox/",
				Credentials:  map[string]string{"api_token": "token"},
				PollInterval: models.Duration(15 * time.Minute),
				// No SweepInterval configured
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50055",
		PollInterval: models.Duration(5 * time.Minute),
	}

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, _ *models.SourceConfig) Integration {
			return NewMockIntegration(ctrl)
		},
	}

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)
	assert.NotNil(t, syncer)

	// Should have created only one poller for sync (no sweep interval configured)
	assert.Len(t, syncer.pollers, 1)

	_, hasSyncPoller := syncer.pollers["netbox-sync"]
	_, hasSweepPoller := syncer.pollers["netbox-sweep"]

	assert.True(t, hasSyncPoller, "Should have created sync poller")
	assert.False(t, hasSweepPoller, "Should not have created sweep poller when sweep_interval not configured")
}

func TestGetResultsClearsCache(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:          "armis",
				Endpoint:      "http://example.com",
				Prefix:        "armis/",
				Credentials:   map[string]string{"api_key": "key"},
				PollInterval:  models.Duration(15 * time.Minute),
				SweepInterval: "10m",
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50053",
		PollInterval: models.Duration(5 * time.Minute),
		Security:     &models.SecurityConfig{},
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return NewMockIntegration(ctrl)
		},
	}

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)

	// Manually add some sweep results to the cache
	sweepResult := &models.SweepResult{
		IP:              "192.168.1.1",
		AgentID:         "test-agent",
		PollerID:        "test-poller",
		DiscoverySource: "armis",
		Available:       true,
	}

	syncer.resultsMu.Lock()
	syncer.resultsCache["armis"] = &CachedResults{
		Results:   []*models.SweepResult{sweepResult},
		Sequence:  "test-sequence-123",
		Timestamp: time.Now(),
	}
	syncer.resultsMu.Unlock()

	// First GetResults call should return the result
	ctx := context.Background()
	req := &proto.ResultsRequest{
		ServiceName: "sync",
		ServiceType: "grpc",
		PollerId:    "test-poller",
	}

	resp1, err := syncer.GetResults(ctx, req)
	require.NoError(t, err)
	assert.True(t, resp1.Available)

	var results1 []*models.SweepResult
	err = json.Unmarshal(resp1.Data, &results1)
	require.NoError(t, err)
	assert.Len(t, results1, 1)
	assert.Equal(t, "192.168.1.1", results1[0].IP)

	// Second GetResults call with same sequence should return empty results
	req2 := &proto.ResultsRequest{
		ServiceName:  "sync",
		ServiceType:  "grpc",
		PollerId:     "test-poller",
		LastSequence: resp1.CurrentSequence, // Use sequence from first response
	}

	resp2, err := syncer.GetResults(ctx, req2)
	require.NoError(t, err)
	assert.True(t, resp2.Available)
	assert.False(t, resp2.HasNewData)                             // No new data
	assert.Equal(t, resp1.CurrentSequence, resp2.CurrentSequence) // Same sequence

	var results2 []*models.SweepResult

	err = json.Unmarshal(resp2.Data, &results2)
	require.NoError(t, err)
	assert.Empty(t, results2, "Should return empty results when sequence matches")
}
