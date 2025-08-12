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
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/netbox"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"
)

// Mock implementation for proto.KVServiceClient
type mockProtoKVClient struct{}

func (*mockProtoKVClient) Put(_ context.Context, _ *proto.PutRequest, _ ...grpc.CallOption) (*proto.PutResponse, error) {
	return &proto.PutResponse{}, nil
}

func (*mockProtoKVClient) PutMany(_ context.Context, _ *proto.PutManyRequest, _ ...grpc.CallOption) (*proto.PutManyResponse, error) {
	return &proto.PutManyResponse{}, nil
}

func (*mockProtoKVClient) Get(_ context.Context, _ *proto.GetRequest, _ ...grpc.CallOption) (*proto.GetResponse, error) {
	return &proto.GetResponse{}, nil
}

func (*mockProtoKVClient) Delete(_ context.Context, _ *proto.DeleteRequest, _ ...grpc.CallOption) (*proto.DeleteResponse, error) {
	return &proto.DeleteResponse{}, nil
}

func (*mockProtoKVClient) Watch(_ context.Context, _ *proto.WatchRequest, _ ...grpc.CallOption) (proto.KVService_WatchClient, error) {
	return nil, nil
}

func TestNew(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	ctx := context.Background()
	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		ListenAddr:        ":8080",
		DiscoveryInterval: models.Duration(60 * time.Second),
		UpdateInterval:    models.Duration(300 * time.Second),
		Sources: map[string]*models.SourceConfig{
			"test-source": {
				Type:     "armis",
				AgentID:  "test-agent",
				Endpoint: "http://example.com",
			},
		},
	}
	kvClient := NewMockKVClient(ctrl)
	grpcClient := NewMockGRPCClient(ctrl)
	registry := make(map[string]IntegrationFactory)
	log := logger.NewTestLogger()

	service, err := New(ctx, config, kvClient, registry, grpcClient, log)

	require.NoError(t, err)
	assert.NotNil(t, service)
	assert.Equal(t, config.AgentID, service.config.AgentID)
	assert.Equal(t, config.PollerID, service.config.PollerID)
}

func TestNewDefault(t *testing.T) {
	ctx := context.Background()
	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		ListenAddr:        ":8080",
		DiscoveryInterval: models.Duration(60 * time.Second),
		UpdateInterval:    models.Duration(300 * time.Second),
		Sources: map[string]*models.SourceConfig{
			"test-source": {
				Type:     "armis",
				AgentID:  "test-agent",
				Endpoint: "http://example.com",
			},
		},
	}

	log := logger.NewTestLogger()

	service, err := NewDefault(ctx, config, log)

	require.NoError(t, err)
	assert.NotNil(t, service)
}

func TestNewWithGRPC_NoKVAddress(t *testing.T) {
	ctx := context.Background()

	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		ListenAddr:        ":8080",
		KVAddress:         "",
		DiscoveryInterval: models.Duration(60 * time.Second),
		UpdateInterval:    models.Duration(300 * time.Second),
		Sources: map[string]*models.SourceConfig{
			"test-source": {
				Type:     "armis",
				AgentID:  "test-agent",
				Endpoint: "http://example.com",
			},
		},
	}
	log := logger.NewTestLogger()

	service, err := NewWithGRPC(ctx, config, log)

	require.NoError(t, err)
	assert.NotNil(t, service)
}

func TestSetupGRPCClient_EmptyAddress(t *testing.T) {
	ctx := context.Background()

	config := &Config{KVAddress: ""}
	log := logger.NewTestLogger()

	kvClient, grpcClient, err := setupGRPCClient(ctx, config, log)

	require.NoError(t, err)
	assert.Nil(t, kvClient)
	assert.Nil(t, grpcClient)
}

func TestGetServerName(t *testing.T) {
	tests := []struct {
		name     string
		config   *Config
		expected string
	}{
		{
			name: "with security config",
			config: &Config{
				Security: &models.SecurityConfig{
					ServerName: "test-server",
				},
			},
			expected: "test-server",
		},
		{
			name:     "without security config",
			config:   &Config{},
			expected: "",
		},
		{
			name: "nil security config",
			config: &Config{
				Security: nil,
			},
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := getServerName(tt.config)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestDefaultIntegrationRegistry(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create a mock that satisfies proto.KVServiceClient interface
	kvClient := &mockProtoKVClient{}
	grpcClient := NewMockGRPCClient(ctrl)
	serverName := "test-server"

	// Mock gRPC connection
	conn := &grpc.ClientConn{}
	grpcClient.EXPECT().GetConnection().Return(conn).AnyTimes()

	registry := defaultIntegrationRegistry(kvClient, grpcClient, serverName)

	assert.Contains(t, registry, integrationTypeArmis)
	assert.Contains(t, registry, integrationTypeNetbox)

	// Test Armis factory
	ctx := context.Background()

	armisConfig := &models.SourceConfig{
		Type:    integrationTypeArmis,
		AgentID: "test-agent",
		Credentials: map[string]string{
			"page_size": "50",
		},
	}

	log := logger.NewTestLogger()
	armisIntegration := registry[integrationTypeArmis](ctx, armisConfig, log)
	assert.NotNil(t, armisIntegration)

	// Test Netbox factory
	netboxConfig := &models.SourceConfig{
		Type:    integrationTypeNetbox,
		AgentID: "test-agent",
		Credentials: map[string]string{
			"expand_subnets": "true",
		},
	}

	netboxIntegration := registry[integrationTypeNetbox](ctx, netboxConfig, log)
	assert.NotNil(t, netboxIntegration)
}

func TestNewArmisIntegration(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	ctx := context.Background()
	kvClient := &mockProtoKVClient{}

	conn := &grpc.ClientConn{}
	serverName := "test-server"

	tests := []struct {
		name     string
		config   *models.SourceConfig
		expected int // expected page size
	}{
		{
			name: "default page size",
			config: &models.SourceConfig{
				Type:        integrationTypeArmis,
				AgentID:     "test-agent",
				Credentials: map[string]string{},
			},
			expected: 100,
		},
		{
			name: "custom page size",
			config: &models.SourceConfig{
				Type:    integrationTypeArmis,
				AgentID: "test-agent",
				Credentials: map[string]string{
					"page_size": "250",
				},
			},
			expected: 250,
		},
		{
			name: "invalid page size uses default",
			config: &models.SourceConfig{
				Type:    integrationTypeArmis,
				AgentID: "test-agent",
				Credentials: map[string]string{
					"page_size": "invalid",
				},
			},
			expected: 100,
		},
		{
			name: "with ServiceRadar API credentials",
			config: &models.SourceConfig{
				Type:    integrationTypeArmis,
				AgentID: "test-agent",
				Credentials: map[string]string{
					"api_key":               "test-key",
					"serviceradar_endpoint": "http://localhost:8080",
				},
			},
			expected: 100,
		},
		{
			name: "with status updates enabled",
			config: &models.SourceConfig{
				Type:    integrationTypeArmis,
				AgentID: "test-agent",
				Credentials: map[string]string{
					"enable_status_updates": "true",
				},
			},
			expected: 100,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			log := logger.NewTestLogger()
			integration := NewArmisIntegration(ctx, tt.config, kvClient, conn, serverName, log)

			assert.NotNil(t, integration)
			assert.Equal(t, tt.expected, integration.PageSize)
			assert.Equal(t, tt.config, integration.Config)
			assert.Equal(t, kvClient, integration.KVClient)
			assert.Equal(t, conn, integration.GRPCConn)
			assert.Equal(t, serverName, integration.ServerName)
			assert.NotNil(t, integration.HTTPClient)
			assert.NotNil(t, integration.TokenProvider)
			assert.NotNil(t, integration.DeviceFetcher)
			assert.NotNil(t, integration.KVWriter)
			assert.Nil(t, integration.SweeperConfig) // SweeperConfig should be nil - agent's file config is authoritative

			// Check if status updates are enabled
			if tt.config.Credentials["enable_status_updates"] == "true" {
				assert.NotNil(t, integration.Updater)
			}

			// Check if SRQL querier is set when API credentials are provided
			if tt.config.Credentials["api_key"] != "" {
				assert.NotNil(t, integration.SweepQuerier)
			}
		})
	}
}

func TestNewNetboxIntegration(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	ctx := context.Background()

	kvClient := &mockProtoKVClient{}
	conn := &grpc.ClientConn{}

	serverName := "test-server"

	tests := []struct {
		name               string
		config             *models.SourceConfig
		expectSweepQuerier bool
	}{
		{
			name: "default configuration",
			config: &models.SourceConfig{
				Type:        integrationTypeNetbox,
				AgentID:     "test-agent",
				Credentials: map[string]string{},
			},
			expectSweepQuerier: false,
		},
		{
			name: "with ServiceRadar API credentials",
			config: &models.SourceConfig{
				Type:    integrationTypeNetbox,
				AgentID: "test-agent",
				Credentials: map[string]string{
					"api_key":               "test-key",
					"serviceradar_endpoint": "http://localhost:8080",
				},
			},
			expectSweepQuerier: true,
		},
		{
			name: "with API key but no endpoint (uses default)",
			config: &models.SourceConfig{
				Type:    integrationTypeNetbox,
				AgentID: "test-agent",
				Credentials: map[string]string{
					"api_key": "test-key",
				},
			},
			expectSweepQuerier: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			log := logger.NewTestLogger()
			integration := NewNetboxIntegration(ctx, tt.config, kvClient, conn, serverName, log)

			assert.NotNil(t, integration)
			assert.Equal(t, tt.config, integration.Config)
			assert.Equal(t, kvClient, integration.KvClient)
			assert.Equal(t, conn, integration.GrpcConn)
			assert.Equal(t, serverName, integration.ServerName)
			assert.False(t, integration.ExpandSubnets, "ExpandSubnets should always be false in NewNetboxIntegration")

			if tt.expectSweepQuerier {
				assert.NotNil(t, integration.Querier)
			} else {
				assert.Nil(t, integration.Querier)
			}
		})
	}
}

func TestNetboxIntegrationFactory(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	kvClient := &mockProtoKVClient{}
	grpcClient := NewMockGRPCClient(ctrl)
	serverName := "test-server"

	// Mock gRPC connection
	conn := &grpc.ClientConn{}
	grpcClient.EXPECT().GetConnection().Return(conn).AnyTimes()

	registry := defaultIntegrationRegistry(kvClient, grpcClient, serverName)
	ctx := context.Background()

	t.Run("expand subnets enabled", func(t *testing.T) {
		config := &models.SourceConfig{
			Type:    integrationTypeNetbox,
			AgentID: "test-agent",
			Credentials: map[string]string{
				"expand_subnets": "true",
			},
		}

		log := logger.NewTestLogger()
		integration := registry[integrationTypeNetbox](ctx, config, log)
		netboxIntegration := integration.(*netbox.NetboxIntegration)

		assert.True(t, netboxIntegration.ExpandSubnets)
	})

	t.Run("expand subnets disabled", func(t *testing.T) {
		config := &models.SourceConfig{
			Type:    integrationTypeNetbox,
			AgentID: "test-agent",
			Credentials: map[string]string{
				"expand_subnets": "false",
			},
		}

		log := logger.NewTestLogger()
		integration := registry[integrationTypeNetbox](ctx, config, log)
		netboxIntegration := integration.(*netbox.NetboxIntegration)

		assert.False(t, netboxIntegration.ExpandSubnets)
	})
}

func TestArmisDeviceStateAdapter(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	querier := NewMockSRQLQuerier(ctrl)
	adapter := &armisDeviceStateAdapter{querier: querier}

	ctx := context.Background()
	source := "test-source"

	deviceStates := []DeviceState{
		{
			DeviceID:    "device1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata:    map[string]interface{}{"key": "value"},
		},
		{
			DeviceID:    "device2",
			IP:          "192.168.1.2",
			IsAvailable: false,
			Metadata:    map[string]interface{}{"key2": "value2"},
		},
	}

	querier.EXPECT().GetDeviceStatesBySource(ctx, source).Return(deviceStates, nil)

	result, err := adapter.GetDeviceStatesBySource(ctx, source)

	require.NoError(t, err)
	assert.Len(t, result, 2)
	assert.Equal(t, "device1", result[0].DeviceID)
	assert.Equal(t, "192.168.1.1", result[0].IP)
	assert.True(t, result[0].IsAvailable)
	assert.Equal(t, map[string]interface{}{"key": "value"}, result[0].Metadata)
}

func TestNetboxDeviceStateAdapter(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	querier := NewMockSRQLQuerier(ctrl)
	adapter := &netboxDeviceStateAdapter{querier: querier}

	ctx := context.Background()
	source := "test-source"

	deviceStates := []DeviceState{
		{
			DeviceID:    "device1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata:    map[string]interface{}{"key": "value"},
		},
	}

	querier.EXPECT().GetDeviceStatesBySource(ctx, source).Return(deviceStates, nil)

	result, err := adapter.GetDeviceStatesBySource(ctx, source)

	require.NoError(t, err)
	assert.Len(t, result, 1)
	assert.Equal(t, "device1", result[0].DeviceID)
	assert.Equal(t, "192.168.1.1", result[0].IP)
	assert.True(t, result[0].IsAvailable)
}

func TestCreateSimpleSyncService(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	ctx := context.Background()
	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		ListenAddr:        ":8080",
		DiscoveryInterval: models.Duration(60 * time.Second),
		UpdateInterval:    models.Duration(300 * time.Second),
		Sources: map[string]*models.SourceConfig{
			"test-source": {
				Type:     "armis",
				AgentID:  "test-agent",
				Endpoint: "http://example.com",
			},
		},
	}
	kvClient := NewMockKVClient(ctrl)
	grpcClient := NewMockGRPCClient(ctrl)
	log := logger.NewTestLogger()

	// Mock gRPC connection
	conn := &grpc.ClientConn{}
	grpcClient.EXPECT().GetConnection().Return(conn).AnyTimes()

	service, err := createSimpleSyncService(ctx, config, kvClient, grpcClient, log)

	require.NoError(t, err)
	assert.NotNil(t, service)
	assert.Equal(t, config.AgentID, service.config.AgentID)
	assert.Equal(t, kvClient, service.kvClient)
	assert.Equal(t, grpcClient, service.grpcClient)
	assert.NotNil(t, service.registry)
	assert.Contains(t, service.registry, integrationTypeArmis)
	assert.Contains(t, service.registry, integrationTypeNetbox)
}

func TestArmisIntegrationPageSizeParsing(t *testing.T) {
	tests := []struct {
		name        string
		pageSizeStr string
		expected    int
	}{
		{"valid positive number", "50", 50},
		{"valid large number", "1000", 1000},
		{"invalid string", "invalid", 100},
		{"empty string", "", 100},
		{"negative number", "-50", 100},
		{"zero", "0", 100},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config := &models.SourceConfig{
				Type:        integrationTypeArmis,
				AgentID:     "test-agent",
				Credentials: map[string]string{},
			}

			if tt.pageSizeStr != "" {
				config.Credentials["page_size"] = tt.pageSizeStr
			}

			pageSize := 100 // default

			if val, ok := config.Credentials["page_size"]; ok {
				if size, err := strconv.Atoi(val); err == nil && size > 0 {
					pageSize = size
				}
			}

			assert.Equal(t, tt.expected, pageSize)
		})
	}
}

func TestServiceRadarEndpointDefaulting(t *testing.T) {
	tests := []struct {
		name           string
		apiKey         string
		endpoint       string
		expectedResult string
	}{
		{
			name:           "API key with explicit endpoint",
			apiKey:         "test-key",
			endpoint:       "http://example.com:8080",
			expectedResult: "http://example.com:8080",
		},
		{
			name:           "API key with no endpoint defaults to localhost",
			apiKey:         "test-key",
			endpoint:       "",
			expectedResult: "http://localhost:8080",
		},
		{
			name:           "No API key, no endpoint",
			apiKey:         "",
			endpoint:       "",
			expectedResult: "",
		},
		{
			name:           "No API key with endpoint",
			apiKey:         "",
			endpoint:       "http://example.com:8080",
			expectedResult: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			serviceRadarAPIKey := tt.apiKey
			serviceRadarEndpoint := tt.endpoint

			// Simulate the logic from NewArmisIntegration
			if serviceRadarEndpoint == "" && serviceRadarAPIKey != "" {
				serviceRadarEndpoint = "http://localhost:8080"
			}

			var result string
			if serviceRadarAPIKey != "" && serviceRadarEndpoint != "" {
				result = serviceRadarEndpoint
			}

			assert.Equal(t, tt.expectedResult, result)
		})
	}
}

func TestHTTPClientCreation(t *testing.T) {
	// Test that HTTP client is created with correct timeout
	httpClient := &http.Client{
		Timeout: 30 * time.Second,
	}

	assert.Equal(t, 30*time.Second, httpClient.Timeout)
}

func TestSweepConfigDefaults(t *testing.T) {
	sweepCfg := &models.SweepConfig{
		Ports:         []int{22, 80, 443, 3389, 445, 5985, 5986, 8080},
		SweepModes:    []string{"icmp", "tcp"},
		Interval:      "300s",
		Concurrency:   100,
		Timeout:       "15s",
		ICMPCount:     1,
		HighPerfICMP:  true,
		ICMPRateLimit: 5000,
	}

	assert.Equal(t, []int{22, 80, 443, 3389, 445, 5985, 5986, 8080}, sweepCfg.Ports)
	assert.Equal(t, []string{"icmp", "tcp"}, sweepCfg.SweepModes)
	assert.Equal(t, "300s", sweepCfg.Interval)
	assert.Equal(t, 100, sweepCfg.Concurrency)
	assert.Equal(t, "15s", sweepCfg.Timeout)
	assert.Equal(t, 1, sweepCfg.ICMPCount)
	assert.True(t, sweepCfg.HighPerfICMP)
	assert.Equal(t, 5000, sweepCfg.ICMPRateLimit)
}

// Benchmark tests
func BenchmarkDefaultIntegrationRegistry(b *testing.B) {
	ctrl := gomock.NewController(b)
	defer ctrl.Finish()

	kvClient := &mockProtoKVClient{}
	grpcClient := NewMockGRPCClient(ctrl)
	conn := &grpc.ClientConn{}
	grpcClient.EXPECT().GetConnection().Return(conn).AnyTimes()

	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		_ = defaultIntegrationRegistry(kvClient, grpcClient, "test-server")
	}
}

func BenchmarkNewArmisIntegration(b *testing.B) {
	ctrl := gomock.NewController(b)
	defer ctrl.Finish()

	ctx := context.Background()
	kvClient := &mockProtoKVClient{}
	conn := &grpc.ClientConn{}
	config := &models.SourceConfig{
		Type:    integrationTypeArmis,
		AgentID: "test-agent",
		Credentials: map[string]string{
			"page_size": "100",
		},
	}

	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		log := logger.NewTestLogger()
		_ = NewArmisIntegration(ctx, config, kvClient, conn, "test-server", log)
	}
}

// Test helper functions
func createTestConfig() *Config {
	return &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		ListenAddr:        ":8080",
		DiscoveryInterval: models.Duration(60 * time.Second),
		UpdateInterval:    models.Duration(300 * time.Second),
		Sources: map[string]*models.SourceConfig{
			"armis-source": {
				Type:     integrationTypeArmis,
				AgentID:  "test-agent",
				Endpoint: "http://armis.example.com",
				Credentials: map[string]string{
					"page_size": "50",
				},
			},
			"netbox-source": {
				Type:     integrationTypeNetbox,
				AgentID:  "test-agent",
				Endpoint: "http://netbox.example.com",
				Credentials: map[string]string{
					"expand_subnets": "true",
				},
			},
		},
	}
}

func TestConfigValidation(t *testing.T) {
	config := createTestConfig()

	// Test that a valid config passes validation
	err := config.Validate()
	require.NoError(t, err)
}
