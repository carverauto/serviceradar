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
	"testing"
	"time"

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
		PollInterval: models.Duration(1 * time.Second),
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
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return NewMockIntegration(ctrl)
		},
	}

	syncer, err := New(context.Background(), c, mockKV, nil, nil, registry, nil, mockClock)
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
		PollInterval: models.Duration(1 * time.Second),
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
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	data := map[string][]byte{"devices": []byte("data")}
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil, nil)
	mockKV.EXPECT().Put(gomock.Any(), &proto.PutRequest{
		Key:   "armis/devices",
		Value: []byte("data"),
	}, gomock.Any()).Return(&proto.PutResponse{}, nil)

	syncer, err := New(context.Background(), c, mockKV, nil, nil, registry, nil, mockClock)
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
	mockKV.EXPECT().Put(gomock.Any(), gomock.Any(), gomock.Any()).Return(&proto.PutResponse{}, nil).Times(2)

	syncer, err := New(context.Background(), c, mockKV, nil, nil, registry, nil, mockClock)
	require.NoError(t, err)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	startDone := make(chan struct{})
	tickProcessed := make(chan struct{})

	var startErr error

	originalPollFunc := syncer.poller.PollFunc
	syncer.poller.PollFunc = func(ctx context.Context) error {
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
		PollInterval: models.Duration(1 * time.Second),
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
	mockKV.EXPECT().Put(gomock.Any(), &proto.PutRequest{
		Key:   "armis/devices",
		Value: []byte("data"),
	}, gomock.Any()).Return(&proto.PutResponse{}, nil)

	syncer, err := New(context.Background(), c, mockKV, nil, nil, registry, nil, mockClock)
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
		PollInterval: models.Duration(1 * time.Second),
	}

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	data := map[string][]byte{"1": []byte(`{"id":1,"name":"device1","primary_ip4":{"address":"192.168.1.1/24"}}`)}
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, nil, nil)
	mockKV.EXPECT().Put(gomock.Any(), &proto.PutRequest{
		Key:   "netbox/1",
		Value: []byte(`{"id":1,"name":"device1","primary_ip4":{"address":"192.168.1.1/24"}}`),
	}, gomock.Any()).Return(&proto.PutResponse{}, nil)

	syncer, err := New(context.Background(), c, mockKV, nil, nil, registry, nil, mockClock)
	require.NoError(t, err)

	err = syncer.Sync(context.Background())
	assert.NoError(t, err)
}
