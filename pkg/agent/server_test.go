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

package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker"
	cconfig "github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type mockKVStore struct{}

func (*mockKVStore) Get(_ context.Context, _ string) (data []byte, found bool, err error) {
	data = nil
	found = false
	err = nil

	return data, found, err
}

func (*mockKVStore) Put(_ context.Context, _ string, _ []byte, _ time.Duration) (err error) {
	err = nil

	return err
}

func (*mockKVStore) Delete(_ context.Context, _ string) error {
	return nil
}

func (*mockKVStore) Watch(_ context.Context, _ string) (<-chan []byte, error) {
	ch := make(chan []byte)
	close(ch)

	return ch, nil
}

func (*mockKVStore) Close() error {
	return nil
}

var _ KVStore = (*mockKVStore)(nil)

type mockService struct{}

func (*mockService) Start(context.Context) error       { return nil }
func (*mockService) Stop(context.Context) error        { return nil }
func (*mockService) Name() string                      { return "mock_sweep" }
func (*mockService) UpdateConfig(*models.Config) error { return nil }

func setupTempDir(t *testing.T) (tmpDir string, cleanup func()) {
	t.Helper()

	tmpDir, err := os.MkdirTemp("", "serviceradar-test")
	require.NoError(t, err)

	cleanup = func() {
		err := os.RemoveAll(tmpDir)
		if err != nil {
			t.Logf("Failed to remove temp dir %s: %v", tmpDir, err)
		}
	}

	return tmpDir, cleanup
}

func setupServerConfig() *ServerConfig {
	return &ServerConfig{
		ListenAddr: ":50051",
		Security:   &models.SecurityConfig{},
	}
}

// In server_test.go

func TestNewServerBasic(t *testing.T) {
	tmpDir, cleanup := setupTempDir(t)
	defer cleanup()

	config := setupServerConfig()
	kvStore := &mockKVStore{}
	testLogger := createTestLogger()

	s := &Server{
		configDir:    tmpDir,
		config:       config,
		kvStore:      kvStore,
		services:     make([]Service, 0),
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]*CheckerConfig),
		registry:     initRegistry(testLogger),
		errChan:      make(chan error, defaultErrChansize),
		done:         make(chan struct{}),
		connections:  make(map[string]*CheckerConnection),
		logger:       testLogger,
	}

	s.setupKVStore = func(_ context.Context, _ *cconfig.Config, _ *ServerConfig) (KVStore, error) {
		t.Log("KVAddress not set, using mock KV store")

		return kvStore, nil
	}

	s.createSweepService = func(_ *SweepConfig, _ KVStore) (Service, error) {
		return nil, errSweepConfigNil // Default behavior for this test
	}

	cfgLoader := cconfig.NewConfig(nil)

	err := s.loadConfigurations(context.Background(), cfgLoader)
	require.NoError(t, err)

	server, err := NewServer(context.Background(), tmpDir, config, createTestLogger())

	require.NoError(t, err)
	require.NotNil(t, server)

	assert.Equal(t, config.ListenAddr, server.ListenAddr())
	assert.Equal(t, config.Security, server.SecurityConfig())

	t.Logf("server.kvStore = %v", server.kvStore)
}

func TestNewServerWithSweepConfig(t *testing.T) {
	tmpDir, cleanup := setupTempDir(t)
	defer cleanup()

	config := setupServerConfig()
	kvStore := &mockKVStore{}

	sweepDir := filepath.Join(tmpDir, "sweep")
	require.NoError(t, os.MkdirAll(sweepDir, 0755))

	sweepConfig := SweepConfig{
		Networks:   []string{"192.168.1.0/24"},
		Ports:      []int{80, 443},
		SweepModes: []models.SweepMode{models.ModeTCP},
		Interval:   Duration(time.Minute),
	}

	data, err := json.Marshal(sweepConfig)
	require.NoError(t, err)

	err = os.WriteFile(filepath.Join(sweepDir, "sweep.json"), data, 0600)
	require.NoError(t, err)

	testLogger := createTestLogger()
	s := &Server{
		configDir:    tmpDir,
		config:       config,
		kvStore:      kvStore,
		services:     make([]Service, 0),
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]*CheckerConfig),
		registry:     initRegistry(testLogger),
		errChan:      make(chan error, defaultErrChansize),
		done:         make(chan struct{}),
		connections:  make(map[string]*CheckerConnection),
		logger:       testLogger,
	}

	s.setupKVStore = func(_ context.Context, _ *cconfig.Config, _ *ServerConfig) (KVStore, error) {
		t.Log("KVAddress not set, using mock KV store")

		return kvStore, nil
	}

	s.createSweepService = func(sweepConfig *SweepConfig, _ KVStore) (Service, error) {
		t.Logf("Using mock createSweepService for sweep config: %+v", sweepConfig)

		return &mockService{}, nil
	}

	cfgLoader := cconfig.NewConfig(nil)
	cfgLoader.SetKVStore(kvStore)

	err = s.loadConfigurations(context.Background(), cfgLoader)
	require.NoError(t, err)

	assert.Equal(t, config.ListenAddr, s.ListenAddr())
	assert.Equal(t, config.Security, s.SecurityConfig())
	assert.Len(t, s.services, 1)
	assert.Equal(t, "mock_sweep", s.services[0].Name())

	t.Logf("server.kvStore = %v", s.kvStore)
}

func TestServerGetStatus(t *testing.T) {
	tmpDir, cleanup := setupTempDir(t)
	defer cleanup()

	server, err := NewServer(context.Background(), tmpDir, &ServerConfig{ListenAddr: ":50051"}, createTestLogger())
	require.NoError(t, err)

	tests := []struct {
		name        string
		req         *proto.StatusRequest
		wantErr     bool
		checkStatus func(*testing.T, *proto.StatusResponse)
	}{
		{
			name: "sweep status request",
			req: &proto.StatusRequest{
				ServiceType: "sweep",
				PollerId:    "test-poller",
			},
			wantErr: false,
			checkStatus: func(t *testing.T, resp *proto.StatusResponse) {
				t.Helper()
				assert.True(t, resp.Available)
				assert.Equal(t, "network_sweep", resp.ServiceName)

				// Unmarshal the JSON message and verify it
				var message map[string]string
				err := json.Unmarshal(resp.Message, &message)
				require.NoError(t, err, "Failed to unmarshal response message")
				assert.Equal(t, map[string]string{"error": "No sweep service configured"}, message)
			},
		},
		{
			name: "port check request",
			req: &proto.StatusRequest{
				ServiceType: "port",
				ServiceName: "test-port",
				Details:     "localhost:8080",
			},
			wantErr: false,
			checkStatus: func(t *testing.T, resp *proto.StatusResponse) {
				t.Helper()
				assert.NotNil(t, resp)
				assert.Equal(t, "port", resp.ServiceType)
				assert.Equal(t, "test-port", resp.ServiceName)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp, err := server.GetStatus(context.Background(), tt.req)
			if tt.wantErr {
				assert.Error(t, err)
				return
			}

			require.NoError(t, err)
			require.NotNil(t, resp)

			tt.checkStatus(t, resp)
		})
	}
}

func TestServerLifecycle(t *testing.T) {
	tmpDir, cleanup := setupTempDir(t)
	defer cleanup()

	server, err := NewServer(context.Background(), tmpDir, &ServerConfig{ListenAddr: ":50051"}, createTestLogger())
	require.NoError(t, err)

	ctx := context.Background()
	err = server.Start(ctx)
	require.NoError(t, err)

	err = server.Close(ctx)
	require.NoError(t, err)
}

func TestServerListServices(t *testing.T) {
	tmpDir, cleanup := setupTempDir(t)
	defer cleanup()

	checkerConfig := CheckerConfig{
		Name:    "test-checker",
		Type:    "port",
		Address: "localhost",
		Port:    8080,
	}
	data, err := json.Marshal(checkerConfig)
	require.NoError(t, err)
	err = os.WriteFile(filepath.Join(tmpDir, "test-checker.json"), data, 0600)
	require.NoError(t, err)

	server, err := NewServer(context.Background(), tmpDir, &ServerConfig{ListenAddr: ":50051"}, createTestLogger())
	require.NoError(t, err)

	services := server.ListServices()
	assert.NotEmpty(t, services)
	assert.Contains(t, services, "test-checker")
}

func TestGetCheckerCaching(t *testing.T) {
	testLogger := createTestLogger()
	s := &Server{
		checkers: make(map[string]checker.Checker),
		registry: initRegistry(testLogger),
		config: &ServerConfig{
			Security: &models.SecurityConfig{},
		},
		logger: testLogger,
		mu:     sync.RWMutex{},
	}

	ctx := context.Background()

	req1 := &proto.StatusRequest{
		ServiceName: "SSH",
		ServiceType: "port",
		Details:     "127.0.0.1:22",
	}
	req2 := &proto.StatusRequest{
		ServiceName: "SSH",
		ServiceType: "port",
		Details:     "192.168.1.1:22",
	}

	checker1a, err := s.getChecker(ctx, req1)
	require.NoError(t, err)
	checker1b, err := s.getChecker(ctx, req1)
	require.NoError(t, err)
	assert.Equal(t, checker1a, checker1b, "repeated call with the same request should yield the same checker instance")

	checker2, err := s.getChecker(ctx, req2)
	require.NoError(t, err)
	assert.NotEqual(t, checker1a, checker2, "requests with different details should yield different checker instances")
}

// TestServerGetResults tests the GetResults method for various scenarios
func TestServerGetResults(t *testing.T) {
	tmpDir, cleanup := setupTempDir(t)
	defer cleanup()

	server, err := NewServer(context.Background(), tmpDir, &ServerConfig{
		ListenAddr: ":50051",
		AgentID:    "test-agent",
	}, createTestLogger())
	require.NoError(t, err)

	tests := []struct {
		name          string
		req           *proto.ResultsRequest
		wantErr       bool
		checkResponse func(*testing.T, *proto.ResultsResponse)
	}{
		{
			name: "non-grpc service GetResults - should return not supported",
			req: &proto.ResultsRequest{
				ServiceName: "ping",
				ServiceType: "icmp",
				AgentId:     "test-agent",
				PollerId:    "test-poller",
				Details:     "1.1.1.1",
			},
			wantErr: true,
			checkResponse: func(t *testing.T, resp *proto.ResultsResponse) {
				t.Helper()
				// Response should be nil for Unimplemented error
				assert.Nil(t, resp)
			},
		},
		{
			name: "sweep service GetResults - should return not supported",
			req: &proto.ResultsRequest{
				ServiceName: "network_sweep",
				ServiceType: "sweep",
				AgentId:     "test-agent",
				PollerId:    "test-poller",
				Details:     "",
			},
			wantErr: true,
			checkResponse: func(t *testing.T, resp *proto.ResultsResponse) {
				t.Helper()
				// Response should be nil for Unimplemented error
				assert.Nil(t, resp)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx := context.Background()
			resp, err := server.GetResults(ctx, tt.req)

			if tt.wantErr {
				require.Error(t, err)

				// Check for Unimplemented status code
				assert.Equal(t, codes.Unimplemented, status.Code(err))

				if tt.checkResponse != nil {
					tt.checkResponse(t, resp)
				}

				return
			}

			require.NoError(t, err)
			require.NotNil(t, resp)
			assert.Positive(t, resp.Timestamp, "Timestamp should be set")

			if tt.checkResponse != nil {
				tt.checkResponse(t, resp)
			}
		})
	}
}

// TestGetResultsConsistencyWithGetStatus tests that GetResults and GetStatus
// handle grpc services consistently
func TestGetResultsConsistencyWithGetStatus(t *testing.T) {
	tmpDir, cleanup := setupTempDir(t)
	defer cleanup()

	server, err := NewServer(context.Background(), tmpDir, &ServerConfig{
		ListenAddr: ":50051",
		AgentID:    "test-agent",
	}, createTestLogger())
	require.NoError(t, err)

	// Test that both GetStatus and GetResults handle grpc services consistently
	// We use a mock checker to avoid actual network calls

	// For non-grpc services, GetResults should return "not supported"
	icmpResultsReq := &proto.ResultsRequest{
		ServiceName: "ping",
		ServiceType: "icmp",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Details:     "1.1.1.1",
	}

	ctx := context.Background()

	// Test that GetResults returns Unimplemented error for non-grpc services
	resultsResp, err := server.GetResults(ctx, icmpResultsReq)
	require.Error(t, err)
	require.Nil(t, resultsResp)

	// Verify it's an Unimplemented error
	require.Equal(t, codes.Unimplemented, status.Code(err))
	assert.Contains(t, err.Error(), "GetResults not supported for service type 'icmp'")

	// Test that sweep service also returns "not supported"
	sweepResultsReq := &proto.ResultsRequest{
		ServiceName: "network_sweep",
		ServiceType: "sweep",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Details:     "",
	}

	sweepResp, err := server.GetResults(ctx, sweepResultsReq)
	require.Error(t, err)
	require.Nil(t, sweepResp)

	// Verify it's an Unimplemented error
	require.Equal(t, codes.Unimplemented, status.Code(err))
	assert.Contains(t, err.Error(), "GetResults not supported for service type 'sweep'")
}
