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
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/checker"
	cconfig "github.com/carverauto/serviceradar/pkg/config"
	kvpkg "github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
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

func (*mockKVStore) Create(_ context.Context, _ string, _ []byte, _ time.Duration) error {
	return nil
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

func TestResolveKVConnectionSettingsPrefersConfig(t *testing.T) {
	t.Setenv("KV_ADDRESS", "env-kv:50057")
	t.Setenv("KV_SEC_MODE", "spiffe")

	cfg := &ServerConfig{
		KVAddress: "config-kv:50057",
		KVSecurity: &models.SecurityConfig{
			Mode:           "spiffe",
			ServerSPIFFEID: "spiffe://example.org/ns/demo/sa/serviceradar-datasvc",
		},
	}

	addr, sec, err := resolveKVConnectionSettings(cfg)
	require.NoError(t, err)
	assert.Equal(t, "config-kv:50057", addr)
	assert.Equal(t, cfg.KVSecurity, sec)
}

func TestResolveKVConnectionSettingsEnvFallback(t *testing.T) {
	t.Setenv("KV_ADDRESS", "env-kv:50057")
	t.Setenv("KV_SEC_MODE", "spiffe")
	t.Setenv("KV_TRUST_DOMAIN", "example.org")
	t.Setenv("KV_SERVER_SPIFFE_ID", "spiffe://example.org/ns/demo/sa/serviceradar-datasvc")
	t.Setenv("KV_WORKLOAD_SOCKET", "unix:/tmp/spire-agent.sock")

	addr, sec, err := resolveKVConnectionSettings(&ServerConfig{})
	require.NoError(t, err)
	assert.Equal(t, "env-kv:50057", addr)
	require.NotNil(t, sec)
	assert.Equal(t, models.SecurityMode("spiffe"), sec.Mode)
	assert.Equal(t, "spiffe://example.org/ns/demo/sa/serviceradar-datasvc", sec.ServerSPIFFEID)
	assert.Equal(t, "unix:/tmp/spire-agent.sock", sec.WorkloadSocket)
	assert.Equal(t, models.RoleAgent, sec.Role)
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
		configStore:  kvStore,
		services:     make([]Service, 0),
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]*CheckerConfig),
		registry:     initRegistry(testLogger),
		errChan:      make(chan error, defaultErrChansize),
		done:         make(chan struct{}),
		connections:  make(map[string]*CheckerConnection),
		logger:       testLogger,
	}

	s.setupDataStores = func(_ context.Context, _ *cconfig.Config, _ *ServerConfig, _ logger.Logger) (KVStore, ObjectStore, error) {
		t.Log("KVAddress not set, using mock KV store")

		return kvStore, nil, nil
	}

	s.createSweepService = func(_ context.Context, _ *SweepConfig, _ KVStore, _ ObjectStore) (Service, error) {
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

	t.Logf("server.configStore = %v", server.configStore)
}

func TestServer_HandleSweepGetResults_Success(t *testing.T) {
	// Setup mock sweep service
	mockSweepService := &SweepService{
		sweeper: &mockSweeper{
			summary: &models.SweepSummary{
				TotalHosts:     10,
				AvailableHosts: 8,
				LastSweep:      time.Now().Unix(),
				Hosts: []models.HostResult{
					{Host: "192.168.1.1", Available: true},
					{Host: "192.168.1.2", Available: true},
				},
			},
		},
		config:             &models.Config{},
		stats:              newScanStats(),
		logger:             createTestLogger(),
		cachedResults:      nil,
		lastSweepTimestamp: 0,
		currentSequence:    0,
	}

	// Setup server with sweep service
	server := &Server{
		config: &ServerConfig{
			AgentID: "test-agent",
		},
		services: []Service{mockSweepService},
		logger:   createTestLogger(),
	}

	ctx := context.Background()
	req := &proto.ResultsRequest{
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		AgentId:      "test-agent",
		PollerId:     "test-poller",
		LastSequence: "",
	}

	// Test successful GetResults call
	response, err := server.handleSweepGetResults(ctx, req)
	require.NoError(t, err)
	require.NotNil(t, response)

	// Verify response
	assert.True(t, response.HasNewData)
	assert.Equal(t, "1", response.CurrentSequence)
	assert.Equal(t, "network_sweep", response.ServiceName)
	assert.Equal(t, "sweep", response.ServiceType)
	assert.Equal(t, "test-agent", response.AgentId)
	assert.Equal(t, "test-poller", response.PollerId)
	assert.True(t, response.Available)
	assert.NotEmpty(t, response.Data)
}

func TestServer_HandleSweepGetResults_NoNewData(t *testing.T) {
	// Setup mock sweep service with existing sequence
	sweepTimestamp := time.Now().Unix()
	mockSweepService := &SweepService{
		sweeper: &mockSweeper{
			summary: &models.SweepSummary{
				TotalHosts:     5,
				AvailableHosts: 4,
				LastSweep:      sweepTimestamp,
				Hosts: []models.HostResult{
					{Host: "192.168.1.1", Available: true},
				},
			},
		},
		config: &models.Config{},
		stats:  newScanStats(),
		logger: createTestLogger(),
		cachedResults: &models.SweepSummary{
			TotalHosts:     5,
			AvailableHosts: 4,
			LastSweep:      sweepTimestamp,
			Hosts: []models.HostResult{
				{Host: "192.168.1.1", Available: true},
			},
		},
		lastSweepTimestamp: sweepTimestamp,
		currentSequence:    1,
	}

	server := &Server{
		config: &ServerConfig{
			AgentID: "test-agent",
		},
		services: []Service{mockSweepService},
		logger:   createTestLogger(),
	}

	ctx := context.Background()
	req := &proto.ResultsRequest{
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		AgentId:      "test-agent",
		PollerId:     "test-poller",
		LastSequence: "1", // Current sequence
	}

	// Test call with current sequence
	response, err := server.handleSweepGetResults(ctx, req)
	require.NoError(t, err)
	require.NotNil(t, response)

	// Should return no new data
	assert.False(t, response.HasNewData)
	assert.Equal(t, "1", response.CurrentSequence)
	assert.Equal(t, "network_sweep", response.ServiceName)
	assert.Equal(t, "sweep", response.ServiceType)
	assert.Equal(t, "test-agent", response.AgentId)
	assert.Equal(t, "test-poller", response.PollerId)
}

func TestServer_HandleSweepGetResults_NoSweepService(t *testing.T) {
	// Setup server without sweep service
	server := &Server{
		config: &ServerConfig{
			AgentID: "test-agent",
		},
		services: []Service{}, // No sweep service
		logger:   createTestLogger(),
	}

	ctx := context.Background()
	req := &proto.ResultsRequest{
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		AgentId:      "test-agent",
		PollerId:     "test-poller",
		LastSequence: "",
	}

	// Test call with no sweep service
	response, err := server.handleSweepGetResults(ctx, req)
	require.NoError(t, err)
	require.NotNil(t, response)

	// Should return error response
	assert.False(t, response.Available)
	assert.Equal(t, "network_sweep", response.ServiceName)
	assert.Equal(t, "sweep", response.ServiceType)
	assert.Equal(t, "test-agent", response.AgentId)
	assert.Equal(t, "test-poller", response.PollerId)
	assert.Contains(t, string(response.Data), "No sweep service configured")
}

func TestServer_GetResults_SweepService(t *testing.T) {
	// Setup mock sweep service
	mockSweepService := &SweepService{
		sweeper: &mockSweeper{
			summary: &models.SweepSummary{
				TotalHosts:     3,
				AvailableHosts: 2,
				LastSweep:      time.Now().Unix(),
				Hosts: []models.HostResult{
					{Host: "192.168.1.1", Available: true},
				},
			},
		},
		config:             &models.Config{},
		stats:              newScanStats(),
		logger:             createTestLogger(),
		cachedResults:      nil,
		lastSweepTimestamp: 0,
		currentSequence:    0,
	}

	server := &Server{
		config: &ServerConfig{
			AgentID: "test-agent",
		},
		services: []Service{mockSweepService},
		logger:   createTestLogger(),
	}

	ctx := context.Background()
	req := &proto.ResultsRequest{
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		AgentId:      "test-agent",
		PollerId:     "test-poller",
		LastSequence: "",
	}

	// Test GetResults routing to sweep service
	response, err := server.GetResults(ctx, req)
	require.NoError(t, err)
	require.NotNil(t, response)

	// Verify it routes to sweep service correctly
	assert.True(t, response.HasNewData)
	assert.Equal(t, "1", response.CurrentSequence)
	assert.Equal(t, "network_sweep", response.ServiceName)
	assert.Equal(t, "sweep", response.ServiceType)
	assert.True(t, response.Available)
}

func TestServer_GetResults_UnsupportedServiceType(t *testing.T) {
	server := &Server{
		config: &ServerConfig{
			AgentID: "test-agent",
		},
		services: []Service{},
		logger:   createTestLogger(),
	}

	ctx := context.Background()
	req := &proto.ResultsRequest{
		ServiceName:  "some_service",
		ServiceType:  "unsupported",
		AgentId:      "test-agent",
		PollerId:     "test-poller",
		LastSequence: "",
	}

	// Test unsupported service type
	response, err := server.GetResults(ctx, req)
	require.Error(t, err)
	require.Nil(t, response)

	// Should return Unimplemented error
	st, ok := status.FromError(err)
	require.True(t, ok)
	assert.Equal(t, codes.Unimplemented, st.Code())
	assert.Contains(t, st.Message(), "GetResults not supported for service type 'unsupported'")
}

// mockSweeper for testing - implements sweeper.SweepService interface
type mockSweeper struct {
	summary     *models.SweepSummary
	updateCount int
}

func (*mockSweeper) Start(_ context.Context) error {
	return nil
}

func (*mockSweeper) Stop() error {
	return nil
}

func (*mockSweeper) UpdateConfig(_ *models.Config) error {
	return nil
}

func (m *mockSweeper) GetStatus(_ context.Context) (*models.SweepSummary, error) {
	return m.summary, nil
}

func (m *mockSweeper) updateSummary(newSummary *models.SweepSummary) {
	// Ensure LastSweep timestamp is different to trigger change detection
	if newSummary.LastSweep == m.summary.LastSweep {
		newSummary.LastSweep = time.Now().Unix()
	}

	m.summary = newSummary
	m.updateCount++
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
		configStore:  kvStore,
		services:     make([]Service, 0),
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]*CheckerConfig),
		registry:     initRegistry(testLogger),
		errChan:      make(chan error, defaultErrChansize),
		done:         make(chan struct{}),
		connections:  make(map[string]*CheckerConnection),
		logger:       testLogger,
	}

	s.setupDataStores = func(_ context.Context, _ *cconfig.Config, _ *ServerConfig, _ logger.Logger) (KVStore, ObjectStore, error) {
		t.Log("KVAddress not set, using mock KV store")

		return kvStore, nil, nil
	}

	s.createSweepService = func(_ context.Context, sweepConfig *SweepConfig, _ KVStore, _ ObjectStore) (Service, error) {
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

	t.Logf("server.configStore = %v", s.configStore)
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
			name: "sweep service GetResults - should return proper response",
			req: &proto.ResultsRequest{
				ServiceName: "network_sweep",
				ServiceType: "sweep",
				AgentId:     "test-agent",
				PollerId:    "test-poller",
				Details:     "",
			},
			wantErr: false,
			checkResponse: func(t *testing.T, resp *proto.ResultsResponse) {
				t.Helper()
				// Should return response indicating no sweep service configured
				assert.NotNil(t, resp)
				assert.False(t, resp.Available)
				assert.Contains(t, string(resp.Data), "No sweep service configured")
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

// TestGetResultsConsistencyWithGetStatus tests that GetResults handles different service types correctly
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

	// Test that sweep service returns proper response (but no sweep service configured in this test)
	sweepResultsReq := &proto.ResultsRequest{
		ServiceName: "network_sweep",
		ServiceType: "sweep",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Details:     "",
	}

	sweepResp, err := server.GetResults(ctx, sweepResultsReq)
	require.NoError(t, err) // Should not error since sweep services are supported
	require.NotNil(t, sweepResp)

	// Should return response indicating no sweep service configured
	assert.False(t, sweepResp.Available)
	assert.Contains(t, string(sweepResp.Data), "No sweep service configured")
}

func TestServer_mergeKVUpdates_DeviceTargets(t *testing.T) {
	tests := []struct {
		name                  string
		fileConfig            *SweepConfig
		kvConfig              *SweepConfig
		kvStoreFound          bool
		expectedDeviceTargets []models.DeviceTarget
		expectError           bool
	}{
		{
			name: "merge device targets from KV into empty file config",
			fileConfig: &SweepConfig{
				Networks:      []string{"192.168.1.0/24"},
				DeviceTargets: []models.DeviceTarget{},
			},
			kvConfig: &SweepConfig{
				Networks: []string{"192.168.1.0/24"},
				DeviceTargets: []models.DeviceTarget{
					{
						Network:    "192.168.1.10/32",
						SweepModes: []models.SweepMode{models.ModeTCP},
						QueryLabel: "tcp_devices",
						Source:     "armis",
						Metadata: map[string]string{
							"armis_device_id": "123",
						},
					},
					{
						Network:    "192.168.1.20/32",
						SweepModes: []models.SweepMode{models.ModeICMP},
						QueryLabel: "icmp_devices",
						Source:     "armis",
						Metadata: map[string]string{
							"armis_device_id": "456",
						},
					},
				},
			},
			kvStoreFound: true,
			expectedDeviceTargets: []models.DeviceTarget{
				{
					Network:    "192.168.1.10/32",
					SweepModes: []models.SweepMode{models.ModeTCP},
					QueryLabel: "tcp_devices",
					Source:     "armis",
					Metadata: map[string]string{
						"armis_device_id": "123",
					},
				},
				{
					Network:    "192.168.1.20/32",
					SweepModes: []models.SweepMode{models.ModeICMP},
					QueryLabel: "icmp_devices",
					Source:     "armis",
					Metadata: map[string]string{
						"armis_device_id": "456",
					},
				},
			},
		},
		{
			name: "KV device targets override file device targets",
			fileConfig: &SweepConfig{
				Networks: []string{"192.168.1.0/24"},
				DeviceTargets: []models.DeviceTarget{
					{
						Network:    "10.0.0.10/32",
						SweepModes: []models.SweepMode{models.ModeTCP},
						QueryLabel: "old_devices",
						Source:     "netbox",
					},
				},
			},
			kvConfig: &SweepConfig{
				Networks: []string{"192.168.1.0/24"},
				DeviceTargets: []models.DeviceTarget{
					{
						Network:    "192.168.1.10/32",
						SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
						QueryLabel: "new_devices",
						Source:     "armis",
						Metadata: map[string]string{
							"armis_device_id": "789",
						},
					},
				},
			},
			kvStoreFound: true,
			expectedDeviceTargets: []models.DeviceTarget{
				{
					Network:    "192.168.1.10/32",
					SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
					QueryLabel: "new_devices",
					Source:     "armis",
					Metadata: map[string]string{
						"armis_device_id": "789",
					},
				},
			},
		},
		{
			name: "no KV config found, use file config only",
			fileConfig: &SweepConfig{
				Networks: []string{"192.168.1.0/24"},
				DeviceTargets: []models.DeviceTarget{
					{
						Network:    "192.168.1.30/32",
						SweepModes: []models.SweepMode{models.ModeTCP},
						QueryLabel: "file_devices",
						Source:     "static",
					},
				},
			},
			kvStoreFound: false,
			expectedDeviceTargets: []models.DeviceTarget{
				{
					Network:    "192.168.1.30/32",
					SweepModes: []models.SweepMode{models.ModeTCP},
					QueryLabel: "file_devices",
					Source:     "static",
				},
			},
		},
		{
			name: "empty KV device targets, keep file device targets",
			fileConfig: &SweepConfig{
				Networks: []string{"192.168.1.0/24"},
				DeviceTargets: []models.DeviceTarget{
					{
						Network:    "192.168.1.40/32",
						SweepModes: []models.SweepMode{models.ModeICMP},
						QueryLabel: "file_devices",
						Source:     "static",
					},
				},
			},
			kvConfig: &SweepConfig{
				Networks:      []string{"192.168.1.0/24"},
				DeviceTargets: []models.DeviceTarget{}, // Empty
			},
			kvStoreFound: true,
			expectedDeviceTargets: []models.DeviceTarget{
				{
					Network:    "192.168.1.40/32",
					SweepModes: []models.SweepMode{models.ModeICMP},
					QueryLabel: "file_devices",
					Source:     "static",
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create mock KV store that implements the agent's KVStore interface
			mockKVStore := &testKVStore{data: make(map[string][]byte)}

			if tt.kvStoreFound {
				kvData, err := json.Marshal(tt.kvConfig)
				require.NoError(t, err)

				mockKVStore.data["test/sweep.json"] = kvData
			}

			// Create server with mock KV store
			server := &Server{
				configStore: mockKVStore,
				objectStore: mockKVStore,
				config:      &ServerConfig{},
				logger:      createTestLogger(),
			}

			// Execute merge
			result, err := server.mergeKVUpdates(context.Background(), "test/sweep.json", tt.fileConfig)

			if tt.expectError {
				require.Error(t, err)
				return
			}

			require.NoError(t, err)

			if !tt.kvStoreFound {
				// No KV config found, should return nil
				assert.Nil(t, result)
				return
			}

			// Verify merged config
			require.NotNil(t, result)
			assert.Equal(t, tt.expectedDeviceTargets, result.DeviceTargets)

			// Verify other fields from file config are preserved
			assert.Equal(t, tt.fileConfig.Networks, result.Networks)
		})
	}
}

func TestServer_mergeKVUpdates_DataServiceObject(t *testing.T) {
	objectKey := "agents/test/checkers/sweep/sweep.json"

	objectConfig := SweepConfig{
		Networks: []string{"10.255.0.0/16"},
		DeviceTargets: []models.DeviceTarget{
			{
				Network:    "10.255.1.10/32",
				SweepModes: []models.SweepMode{models.ModeICMP},
				QueryLabel: "armis_sweep",
				Source:     "armis",
			},
		},
	}

	objectBytes, err := json.Marshal(objectConfig)
	require.NoError(t, err)

	sha := sha256.Sum256(objectBytes)

	metadata := map[string]any{
		"storage":    "data_service",
		"object_key": objectKey,
		"sha256":     base64.StdEncoding.EncodeToString(sha[:]),
		"overrides": map[string]any{
			"interval": "2m0s",
		},
	}

	metaBytes, err := json.Marshal(metadata)
	require.NoError(t, err)

	store := &testKVStore{
		data:       map[string][]byte{objectKey: metaBytes},
		objectData: map[string][]byte{objectKey: objectBytes},
	}

	server := &Server{
		configStore: store,
		objectStore: store,
		config:      &ServerConfig{},
		logger:      createTestLogger(),
	}

	fileConfig := &SweepConfig{
		Networks: []string{"172.16.0.0/16"},
		Interval: 0,
		Timeout:  0,
	}

	result, err := server.mergeKVUpdates(context.Background(), objectKey, fileConfig)
	require.NoError(t, err)
	require.NotNil(t, result)

	assert.Equal(t, []string{"10.255.0.0/16"}, result.Networks)
	require.Len(t, result.DeviceTargets, 1)
	assert.Equal(t, "armis", result.DeviceTargets[0].Source)
	assert.Equal(t, Duration(2*time.Minute), result.Interval)
}

func TestServer_mergeKVUpdates_DataServiceUnavailable(t *testing.T) {
	objectKey := "agents/test/checkers/sweep/sweep.json"

	metadata := map[string]any{
		"storage":    "data_service",
		"object_key": objectKey,
	}

	metaBytes, err := json.Marshal(metadata)
	require.NoError(t, err)

	store := &testKVStore{
		data:        map[string][]byte{objectKey: metaBytes},
		downloadErr: errDataServiceUnavailable,
	}

	server := &Server{
		configStore: store,
		objectStore: store,
		config:      &ServerConfig{},
		logger:      createTestLogger(),
	}

	fileConfig := &SweepConfig{
		Networks: []string{"192.168.0.0/24"},
	}

	result, err := server.mergeKVUpdates(context.Background(), objectKey, fileConfig)
	require.NoError(t, err)
	require.NotNil(t, result)

	assert.Equal(t, fileConfig.Networks, result.Networks)
	assert.Empty(t, result.DeviceTargets)
}

func TestServer_mergeDeviceTargets(t *testing.T) {
	server := &Server{
		config: &ServerConfig{},
		logger: createTestLogger(),
	}

	tests := []struct {
		name              string
		fileDeviceTargets []models.DeviceTarget
		kvDeviceTargets   []models.DeviceTarget
		expectedTargets   []models.DeviceTarget
	}{
		{
			name:              "empty file, non-empty KV",
			fileDeviceTargets: []models.DeviceTarget{},
			kvDeviceTargets: []models.DeviceTarget{
				{
					Network:    "192.168.1.10/32",
					SweepModes: []models.SweepMode{models.ModeTCP},
					QueryLabel: "kv_devices",
					Source:     "armis",
				},
			},
			expectedTargets: []models.DeviceTarget{
				{
					Network:    "192.168.1.10/32",
					SweepModes: []models.SweepMode{models.ModeTCP},
					QueryLabel: "kv_devices",
					Source:     "armis",
				},
			},
		},
		{
			name: "non-empty file, non-empty KV - KV overrides",
			fileDeviceTargets: []models.DeviceTarget{
				{
					Network:    "10.0.0.10/32",
					SweepModes: []models.SweepMode{models.ModeICMP},
					QueryLabel: "file_devices",
					Source:     "static",
				},
			},
			kvDeviceTargets: []models.DeviceTarget{
				{
					Network:    "192.168.1.20/32",
					SweepModes: []models.SweepMode{models.ModeTCP},
					QueryLabel: "kv_devices",
					Source:     "armis",
				},
			},
			expectedTargets: []models.DeviceTarget{
				{
					Network:    "192.168.1.20/32",
					SweepModes: []models.SweepMode{models.ModeTCP},
					QueryLabel: "kv_devices",
					Source:     "armis",
				},
			},
		},
		{
			name: "non-empty file, empty KV - file preserved",
			fileDeviceTargets: []models.DeviceTarget{
				{
					Network:    "192.168.1.30/32",
					SweepModes: []models.SweepMode{models.ModeICMP},
					QueryLabel: "file_devices",
					Source:     "static",
				},
			},
			kvDeviceTargets: []models.DeviceTarget{},
			expectedTargets: []models.DeviceTarget{
				{
					Network:    "192.168.1.30/32",
					SweepModes: []models.SweepMode{models.ModeICMP},
					QueryLabel: "file_devices",
					Source:     "static",
				},
			},
		},
		{
			name:              "empty file, empty KV",
			fileDeviceTargets: []models.DeviceTarget{},
			kvDeviceTargets:   []models.DeviceTarget{},
			expectedTargets:   []models.DeviceTarget{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mergedConfig := &SweepConfig{
				DeviceTargets: tt.fileDeviceTargets,
			}

			server.mergeDeviceTargets(tt.fileDeviceTargets, tt.kvDeviceTargets, mergedConfig)

			assert.Equal(t, tt.expectedTargets, mergedConfig.DeviceTargets)
		})
	}
}

// testKVStore implements KVStore interface for testing
type testKVStore struct {
	data        map[string][]byte
	objectData  map[string][]byte
	downloadErr error
}

func (t *testKVStore) Get(_ context.Context, key string) ([]byte, bool, error) {
	value, found := t.data[key]
	return value, found, nil
}

func (t *testKVStore) Put(_ context.Context, key string, value []byte, _ time.Duration) error {
	t.data[key] = value
	return nil
}

func (t *testKVStore) Create(_ context.Context, key string, value []byte, _ time.Duration) error {
	if _, exists := t.data[key]; exists {
		return kvpkg.ErrKeyExists
	}
	t.data[key] = value
	return nil
}

func (t *testKVStore) Delete(_ context.Context, key string) error {
	delete(t.data, key)
	return nil
}

func (*testKVStore) Watch(context.Context, string) (<-chan []byte, error) {
	ch := make(chan []byte)
	close(ch)

	return ch, nil
}

func (t *testKVStore) DownloadObject(_ context.Context, key string) ([]byte, error) {
	if t.downloadErr != nil {
		return nil, t.downloadErr
	}

	if t.objectData != nil {
		if value, found := t.objectData[key]; found {
			return value, nil
		}
	}

	if value, found := t.data[key]; found {
		return value, nil
	}

	return nil, fmt.Errorf("%w: %s", errTestObjectNotFound, key)
}

func (*testKVStore) Close() error {
	return nil
}

var _ KVStore = (*testKVStore)(nil)
var _ ObjectStore = (*testKVStore)(nil)

var errTestObjectNotFound = errors.New("object not found")
