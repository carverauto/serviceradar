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

	log, err := lifecycle.CreateLogger(config)
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

	// Test the syncSource method for the armis source
	err = syncer.syncSource(context.Background(), "armis")
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
	mockTicker.EXPECT().Stop()

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
	startDone := make(chan struct{})

	go func() {
		err = syncer.Start(ctx)
		assert.Equal(t, context.Canceled, err)
		close(startDone)
	}()

	time.Sleep(100 * time.Millisecond) // Allow initial poll
	cancel()                           // Cancel context
	<-startDone                        // Wait for Start to exit

	err = syncer.Stop(context.Background())
	assert.NoError(t, err)
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

	// Test the syncSource method for the netbox source
	err = syncer.syncSource(context.Background(), "netbox")
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
