package sync

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/poller" // Import poller for mocks
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestNew_ValidConfig(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := poller.NewMockClock(ctrl) // Use poller.Clock mock

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
		Security: &models.SecurityConfig{
			Mode: "mtls",
			Role: models.RolePoller,
			TLS: struct {
				CertFile     string `json:"cert_file"`
				KeyFile      string `json:"key_file"`
				CAFile       string `json:"ca_file"`
				ClientCAFile string `json:"client_ca_file"`
			}{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ models.SourceConfig) Integration {
			return NewMockIntegration(ctrl)
		},
	}

	syncer, err := New(context.Background(), c, mockKV, mockGRPC, registry, mockClock)
	require.NoError(t, err)
	assert.NotNil(t, syncer)
	assert.NotNil(t, syncer.poller)
	assert.NotNil(t, syncer.poller.PollFunc)
}

func TestSync_Success(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)

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
		Security: &models.SecurityConfig{
			Mode: "mtls",
			Role: models.RolePoller,
			TLS: struct {
				CertFile     string `json:"cert_file"`
				KeyFile      string `json:"key_file"`
				CAFile       string `json:"ca_file"`
				ClientCAFile string `json:"client_ca_file"`
			}{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ models.SourceConfig) Integration {
			return mockInteg
		},
	}

	data := map[string][]byte{"devices": []byte("data")}
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil)
	mockKV.EXPECT().Put(gomock.Any(), &proto.PutRequest{
		Key:   "armis/devices",
		Value: []byte("data"),
	}, gomock.Any()).Return(&proto.PutResponse{}, nil)

	syncer, err := New(context.Background(), c, mockKV, mockGRPC, registry, mockClock)
	require.NoError(t, err)

	err = syncer.Sync(context.Background())
	assert.NoError(t, err)
}

func TestStartAndStop(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)
	mockTicker := poller.NewMockTicker(ctrl) // Use poller.Ticker mock

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
		PollInterval: config.Duration(500 * time.Millisecond),
		Security: &models.SecurityConfig{
			Mode: "mtls",
			Role: models.RolePoller,
			TLS: struct {
				CertFile     string `json:"cert_file"`
				KeyFile      string `json:"key_file"`
				CAFile       string `json:"ca_file"`
				ClientCAFile string `json:"client_ca_file"`
			}{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ models.SourceConfig) Integration {
			return mockInteg
		},
	}

	// Mock ticker behavior
	tickChan := make(chan time.Time, 1)

	mockClock.EXPECT().Ticker(500 * time.Millisecond).Return(mockTicker)
	mockTicker.EXPECT().Chan().Return(tickChan).AnyTimes()
	mockTicker.EXPECT().Stop()

	// Mock initial Sync and one tick-triggered Sync
	data := map[string][]byte{"devices": []byte("data")}
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil).Times(2) // Initial + 1 tick
	mockKV.EXPECT().Put(gomock.Any(), &proto.PutRequest{
		Key:   "armis/devices",
		Value: []byte("data"),
	}, gomock.Any()).Return(&proto.PutResponse{}, nil).Times(2)

	mockGRPC.EXPECT().Close().Return(nil)

	syncer, err := New(context.Background(), c, mockKV, mockGRPC, registry, mockClock)
	require.NoError(t, err)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan struct{})
	go func() {
		// Simulate one tick
		tickChan <- time.Now()

		// Allow the tick to be processed
		time.Sleep(10 * time.Millisecond)

		err = syncer.Stop(context.Background())
		assert.NoError(t, err)

		close(done)
	}()

	err = syncer.Start(ctx)
	assert.NoError(t, err)

	<-done
}

func TestStart_ContextCancellation(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)
	mockTicker := poller.NewMockTicker(ctrl)

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
		Security: &models.SecurityConfig{
			Mode: "mtls",
			Role: models.RolePoller,
			TLS: struct {
				CertFile     string `json:"cert_file"`
				KeyFile      string `json:"key_file"`
				CAFile       string `json:"ca_file"`
				ClientCAFile string `json:"client_ca_file"`
			}{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		},
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

	mockGRPC.EXPECT().Close().Return(nil)

	syncer, err := New(context.Background(), c, mockKV, mockGRPC, registry, mockClock)
	require.NoError(t, err)

	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})

	go func() {
		time.Sleep(100 * time.Millisecond)
		cancel()

		err = syncer.Stop(context.Background())
		assert.NoError(t, err)

		close(done)
	}()

	err = syncer.Start(ctx)
	assert.Equal(t, context.Canceled, err)

	<-done
}
