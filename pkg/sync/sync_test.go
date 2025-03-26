package sync

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

var (
	errFetchFailed = errors.New("fetch failed")
)

func TestNew_ValidConfig(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := NewMockClock(ctrl)

	c := &Config{
		Sources: map[string]models.SourceConfig{
			"armis": {
				Type:        "armis",
				Endpoint:    "http://example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		KVAddress:    "localhost:50051",
		PollInterval: config.Duration(1 * time.Second),
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ models.SourceConfig) Integration {
			return NewMockIntegration(ctrl)
		},
	}

	syncer, err := New(context.Background(), c, mockKV, mockGRPC, mockClock, registry)
	require.NoError(t, err)
	assert.NotNil(t, syncer)
	assert.Equal(t, c, &syncer.config)
	assert.Equal(t, mockKV, syncer.kvClient)
	assert.Equal(t, mockGRPC, syncer.grpcClient)
	assert.Equal(t, mockClock, syncer.clock)
	assert.Len(t, syncer.sources, 1)
}

func TestNew_InvalidConfig(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := NewMockClock(ctrl)

	config := &Config{} // Missing required fields

	registry := map[string]IntegrationFactory{}

	_, err := New(context.Background(), config, mockKV, mockGRPC, mockClock, registry)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "at least one source must be defined")
}

func TestSync_Success(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := NewMockClock(ctrl)
	mockInteg := NewMockIntegration(ctrl)

	c := &Config{
		Sources: map[string]models.SourceConfig{
			"armis": {
				Type:        "armis",
				Endpoint:    "http://example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		KVAddress: "localhost:50051",
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ models.SourceConfig) Integration {
			return mockInteg
		},
	}

	// Mock expectations
	data := map[string][]byte{"devices": []byte("data")}
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil)
	mockKV.EXPECT().Put(gomock.Any(), &proto.PutRequest{
		Key:   "armis/devices",
		Value: []byte("data"),
	}, gomock.Any()).Return(&proto.PutResponse{}, nil)

	syncer, err := New(context.Background(), c, mockKV, mockGRPC, mockClock, registry)
	require.NoError(t, err)

	err = syncer.Sync(context.Background())
	assert.NoError(t, err)
}

func TestSync_IntegrationError(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := NewMockClock(ctrl)
	mockInteg := NewMockIntegration(ctrl)

	c := &Config{
		Sources: map[string]models.SourceConfig{
			"armis": {
				Type:        "armis",
				Endpoint:    "http://example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		KVAddress: "localhost:50051",
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ models.SourceConfig) Integration {
			return mockInteg
		},
	}

	// Mock expectations
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(nil, errFetchFailed)

	syncer, err := New(context.Background(), c, mockKV, mockGRPC, mockClock, registry)
	require.NoError(t, err)

	err = syncer.Sync(context.Background())
	require.Error(t, err)
	assert.Equal(t, "fetch failed", err.Error())
}

func TestStartAndStop(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := NewMockClock(ctrl)
	mockTicker := NewMockTicker(ctrl)
	mockInteg := NewMockIntegration(ctrl)

	c := &Config{
		Sources: map[string]models.SourceConfig{
			"armis": {
				Type:        "armis",
				Endpoint:    "http://example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		KVAddress:    "localhost:50051",
		PollInterval: config.Duration(1 * time.Second),
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ models.SourceConfig) Integration {
			return mockInteg
		},
	}

	// Mock ticker behavior
	tickChan := make(chan time.Time, 1)

	mockClock.EXPECT().Ticker(1 * time.Second).Return(mockTicker)

	mockTicker.EXPECT().Chan().Return(tickChan).AnyTimes()
	mockTicker.EXPECT().Stop()

	// Mock initial Sync and tick-triggered Sync
	data := map[string][]byte{"devices": []byte("data")}
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil).Times(2) // Initial + 1 tick
	mockKV.EXPECT().Put(gomock.Any(), &proto.PutRequest{
		Key:   "armis/devices",
		Value: []byte("data"),
	}, gomock.Any()).Return(&proto.PutResponse{}, nil).Times(2)

	// Expect Close before Stop is called
	mockGRPC.EXPECT().Close().Return(nil)

	syncer, err := New(context.Background(), c, mockKV, mockGRPC, mockClock, registry)
	require.NoError(t, err)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan struct{})

	go func() {
		// Simulate a tick to ensure Sync is called
		tickChan <- time.Now()

		time.Sleep(100 * time.Millisecond)

		err = syncer.Stop(context.Background())
		assert.NoError(t, err)

		close(done)
	}()

	err = syncer.Start(ctx)
	assert.NoError(t, err)

	// Wait for the goroutine to finish to ensure Close is called
	<-done
}

func TestStart_ContextCancellation(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := NewMockClock(ctrl)
	mockTicker := NewMockTicker(ctrl)
	mockInteg := NewMockIntegration(ctrl)

	c := &Config{
		Sources: map[string]models.SourceConfig{
			"armis": {
				Type:        "armis",
				Endpoint:    "http://example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		KVAddress:    "localhost:50051",
		PollInterval: config.Duration(1 * time.Second),
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ models.SourceConfig) Integration {
			return mockInteg
		},
	}

	// Mock ticker behavior
	tickChan := make(chan time.Time)

	mockClock.EXPECT().Ticker(1 * time.Second).Return(mockTicker)
	mockTicker.EXPECT().Chan().Return(tickChan).AnyTimes()
	mockTicker.EXPECT().Stop()

	// Mock initial Sync (before cancellation)
	data := map[string][]byte{"devices": []byte("data")}
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil)
	mockKV.EXPECT().Put(gomock.Any(), &proto.PutRequest{
		Key:   "armis/devices",
		Value: []byte("data"),
	}, gomock.Any()).Return(&proto.PutResponse{}, nil)

	// Expect Close after context cancellation
	mockGRPC.EXPECT().Close().Return(nil)

	syncer, err := New(context.Background(), c, mockKV, mockGRPC, mockClock, registry)
	require.NoError(t, err)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})

	go func() {
		time.Sleep(100 * time.Millisecond)
		cancel()

		// Explicitly call Stop to trigger Close after cancellation
		err = syncer.Stop(context.Background())
		assert.NoError(t, err)

		close(done)
	}()

	err = syncer.Start(ctx)
	assert.Equal(t, context.Canceled, err)

	// Wait for the goroutine to finish to ensure Close is called
	<-done
}
