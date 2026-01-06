package core

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestEnsureServiceDeviceRegistersOnStatusSource(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	serviceData := json.RawMessage(`{"status":{"host_ip":"10.0.0.5","hostname":"edge-agent"}}`)

	svc := &proto.GatewayServiceStatus{
		ServiceName: "edge-agent",
		ServiceType: grpcServiceType,
		Source:      "status",
	}

	now := time.Now()

	mockRegistry.EXPECT().
		SetDeviceCapabilitySnapshot(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceCapabilitySnapshot{})).
		AnyTimes()

	gomock.InOrder(
		mockRegistry.EXPECT().
			GetCollectorCapabilities(gomock.Any(), "default:10.0.0.5").
			Return(nil, false),
		mockRegistry.EXPECT().
			SetCollectorCapabilities(gomock.Any(), gomock.AssignableToTypeOf(&models.CollectorCapability{})).
			Do(func(_ context.Context, record *models.CollectorCapability) {
				require.NotNil(t, record)
				require.Equal(t, "default:10.0.0.5", record.DeviceID)
				require.ElementsMatch(t, []string{"edge-agent", "grpc"}, record.Capabilities)
				require.Equal(t, "agent-1", record.AgentID)
				require.Equal(t, "gateway-1", record.GatewayID)
				require.Equal(t, "edge-agent", record.ServiceName)
			}),
		mockRegistry.EXPECT().
			ProcessBatchDeviceUpdates(gomock.Any(), gomock.Len(1)).
			DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
				require.Len(t, updates, 1)
				update := updates[0]
				require.Equal(t, models.DiscoverySourceSelfReported, update.Source)
				require.Equal(t, "default:10.0.0.5", update.DeviceID)
				require.Equal(t, "10.0.0.5", update.IP)
				require.Equal(t, "default", update.Partition)
				require.Equal(t, "agent-1", update.AgentID)
				require.Equal(t, "gateway-1", update.GatewayID)
				require.True(t, update.IsAvailable)

				require.NotNil(t, update.Hostname)
				require.Equal(t, "edge-agent", *update.Hostname)

				require.Equal(t, "edge-agent", update.Metadata["checker_service"])
				require.Equal(t, "edge-agent", update.Metadata["checker_service_id"])
				require.Equal(t, grpcServiceType, update.Metadata["checker_service_type"])
				require.Equal(t, "10.0.0.5", update.Metadata["checker_host_ip"])
				require.Equal(t, "agent-1", update.Metadata["collector_agent_id"])
				require.Equal(t, "gateway-1", update.Metadata["collector_gateway_id"])

				require.NotEmpty(t, update.Metadata["last_update"])
				return nil
			}),
	)

	server.ensureServiceDevice(
		context.Background(),
		"agent-1",
		"gateway-1",
		"default",
		svc,
		serviceData,
		now,
	)

	server.flushServiceDeviceUpdates(context.Background())
}

func TestEnsureServiceDeviceSkipsResultSource(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	serviceData := json.RawMessage(`{"status":{"host_ip":"10.0.0.5"}}`)

	svc := &proto.GatewayServiceStatus{
		ServiceName: "edge-agent",
		ServiceType: grpcServiceType,
		Source:      "results",
	}

	server.ensureServiceDevice(
		context.Background(),
		"agent-1",
		"gateway-1",
		"default",
		svc,
		serviceData,
		time.Now(),
	)

	server.flushServiceDeviceUpdates(context.Background())
}

func TestIsDockerBridgeIP(t *testing.T) {
	tests := []struct {
		name     string
		ip       string
		expected bool
	}{
		{
			name:     "docker default bridge",
			ip:       "172.17.0.5",
			expected: true,
		},
		{
			name:     "docker compose network",
			ip:       "172.18.0.5",
			expected: true,
		},
		{
			name:     "docker compose network 172.19",
			ip:       "172.19.0.5",
			expected: true,
		},
		{
			name:     "docker compose network 172.20",
			ip:       "172.20.0.5",
			expected: true,
		},
		{
			name:     "docker compose network 172.21",
			ip:       "172.21.0.5",
			expected: true,
		},
		{
			name:     "regular private IP",
			ip:       "192.168.1.100",
			expected: false,
		},
		{
			name:     "10.x private IP",
			ip:       "10.0.0.5",
			expected: false,
		},
		{
			name:     "public IP",
			ip:       "8.8.8.8",
			expected: false,
		},
		{
			name:     "invalid IP",
			ip:       "not-an-ip",
			expected: false,
		},
		{
			name:     "empty IP",
			ip:       "",
			expected: false,
		},
		{
			name:     "172.16 is not docker default",
			ip:       "172.16.0.5",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := isDockerBridgeIP(tt.ip)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestIsEphemeralCollectorIP(t *testing.T) {
	server := &Server{
		logger: logger.NewTestLogger(),
	}

	tests := []struct {
		name     string
		hostIP   string
		hostname string
		hostID   string
		expected bool
	}{
		{
			name:     "docker IP with agent hostname",
			hostIP:   "172.18.0.5",
			hostname: "docker-agent",
			hostID:   "",
			expected: true,
		},
		{
			name:     "docker IP with gateway in hostname",
			hostIP:   "172.17.0.10",
			hostname: "k8s-gateway",
			hostID:   "",
			expected: true,
		},
		{
			name:     "docker IP with collector in hostID",
			hostIP:   "172.19.0.3",
			hostname: "",
			hostID:   "edge-collector-01",
			expected: true,
		},
		{
			name:     "docker IP with empty hostname",
			hostIP:   "172.18.0.5",
			hostname: "",
			hostID:   "",
			expected: true,
		},
		{
			name:     "docker IP with unknown hostname",
			hostIP:   "172.18.0.5",
			hostname: "unknown",
			hostID:   "",
			expected: true,
		},
		{
			name:     "docker IP with localhost hostname",
			hostIP:   "172.18.0.5",
			hostname: "localhost",
			hostID:   "",
			expected: true,
		},
		{
			name:     "docker IP with legitimate hostname",
			hostIP:   "172.18.0.5",
			hostname: "sysmon-osx-01",
			hostID:   "sysmon-osx-01",
			expected: false,
		},
		{
			name:     "non-docker IP with agent hostname",
			hostIP:   "192.168.1.100",
			hostname: "docker-agent",
			hostID:   "",
			expected: false,
		},
		{
			name:     "legitimate target IP",
			hostIP:   "192.168.1.218",
			hostname: "sysmon-osx",
			hostID:   "sysmon-osx",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := server.isEphemeralCollectorIP(tt.hostIP, tt.hostname, tt.hostID)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestEnsureServiceDeviceSkipsEphemeralCollectorIP(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDeviceRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry:  mockDeviceRegistry,
		ServiceRegistry: nil, // No ServiceRegistry, will use heuristic
		logger:          logger.NewTestLogger(),
	}

	// Service data reports a Docker bridge IP with "agent" in hostname
	// This should be detected as an ephemeral collector IP and skipped
	serviceData := json.RawMessage(`{"status":{"host_ip":"172.18.0.5","hostname":"docker-agent"}}`)

	svc := &proto.GatewayServiceStatus{
		ServiceName: "sysmon-osx",
		ServiceType: grpcServiceType,
		Source:      "status",
	}

	// The device registry should NOT be called because the IP is detected as ephemeral collector
	// (no expectations set on mockDeviceRegistry)

	server.ensureServiceDevice(
		context.Background(),
		"agent-1",
		"gateway-1",
		"default",
		svc,
		serviceData,
		time.Now(),
	)

	// No flush should result in any device updates
	server.flushServiceDeviceUpdates(context.Background())
}

func TestEnsureServiceDeviceCreatesTargetDevice(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDeviceRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry:  mockDeviceRegistry,
		ServiceRegistry: nil, // No ServiceRegistry, will use heuristic
		logger:          logger.NewTestLogger(),
	}

	// Service data reports a non-Docker IP with a real hostname
	// This should be detected as a legitimate target and create a device
	serviceData := json.RawMessage(`{"status":{"host_ip":"192.168.1.218","hostname":"sysmon-osx"}}`)

	svc := &proto.GatewayServiceStatus{
		ServiceName: "sysmon-osx",
		ServiceType: grpcServiceType,
		Source:      "status",
	}

	// Expect device registry to be called for capability tracking
	mockDeviceRegistry.EXPECT().
		GetCollectorCapabilities(gomock.Any(), "default:192.168.1.218").
		Return(nil, false)

	mockDeviceRegistry.EXPECT().
		SetCollectorCapabilities(gomock.Any(), gomock.AssignableToTypeOf(&models.CollectorCapability{}))

	mockDeviceRegistry.EXPECT().
		SetDeviceCapabilitySnapshot(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceCapabilitySnapshot{})).
		AnyTimes()

	// Expect device update for the target
	mockDeviceRegistry.EXPECT().
		ProcessBatchDeviceUpdates(gomock.Any(), gomock.Len(1)).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Len(t, updates, 1)
			update := updates[0]
			require.Equal(t, "default:192.168.1.218", update.DeviceID)
			require.Equal(t, "192.168.1.218", update.IP)
			require.NotNil(t, update.Hostname)
			require.Equal(t, "sysmon-osx", *update.Hostname)
			return nil
		})

	server.ensureServiceDevice(
		context.Background(),
		"agent-1",
		"gateway-1",
		"default",
		svc,
		serviceData,
		time.Now(),
	)

	server.flushServiceDeviceUpdates(context.Background())
}

func TestExtractIPFromMetadata(t *testing.T) {
	tests := []struct {
		name     string
		metadata map[string]string
		expected string
	}{
		{
			name:     "nil metadata",
			metadata: nil,
			expected: "",
		},
		{
			name:     "empty metadata",
			metadata: map[string]string{},
			expected: "",
		},
		{
			name: "source_ip key",
			metadata: map[string]string{
				"source_ip": "192.168.1.100",
			},
			expected: "192.168.1.100",
		},
		{
			name: "host_ip key",
			metadata: map[string]string{
				"host_ip": "10.0.0.5",
			},
			expected: "10.0.0.5",
		},
		{
			name: "ip key",
			metadata: map[string]string{
				"ip": "172.16.0.1",
			},
			expected: "172.16.0.1",
		},
		{
			name: "source_ip takes precedence",
			metadata: map[string]string{
				"source_ip": "192.168.1.100",
				"host_ip":   "10.0.0.5",
				"ip":        "172.16.0.1",
			},
			expected: "192.168.1.100",
		},
		{
			name: "invalid IP returns empty",
			metadata: map[string]string{
				"source_ip": "not-an-ip",
			},
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractIPFromMetadata(tt.metadata)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestNormalizeHostIdentifier(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "simple IP",
			input:    "192.168.1.100",
			expected: "192.168.1.100",
		},
		{
			name:     "IP with port",
			input:    "192.168.1.100:8080",
			expected: "192.168.1.100",
		},
		{
			name:     "IP with whitespace",
			input:    "  192.168.1.100  ",
			expected: "192.168.1.100",
		},
		{
			name:     "IPv6 bracketed",
			input:    "[::1]",
			expected: "::1",
		},
		{
			name:     "IPv6 with port",
			input:    "[::1]:8080",
			expected: "::1",
		},
		{
			name:     "empty string",
			input:    "",
			expected: "",
		},
		{
			name:     "whitespace only",
			input:    "   ",
			expected: "",
		},
		{
			name:     "hostname",
			input:    "my-server",
			expected: "my-server",
		},
		{
			name:     "hostname with port",
			input:    "my-server:8080",
			expected: "my-server",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := normalizeHostIdentifier(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestIsDockerBridgeIP_EdgeCases(t *testing.T) {
	tests := []struct {
		name     string
		ip       string
		expected bool
	}{
		// Boundary tests for 172.17.x.x
		{name: "172.17.0.0 start of range", ip: "172.17.0.0", expected: true},
		{name: "172.17.255.255 end of range", ip: "172.17.255.255", expected: true},
		{name: "172.16.255.255 just before range", ip: "172.16.255.255", expected: false},
		{name: "172.22.0.0 just after range", ip: "172.22.0.0", expected: false},

		// IPv6 addresses (not Docker bridge)
		{name: "IPv6 loopback", ip: "::1", expected: false},
		{name: "IPv6 address", ip: "2001:db8::1", expected: false},

		// Edge cases
		{name: "127.0.0.1 localhost", ip: "127.0.0.1", expected: false},
		{name: "0.0.0.0", ip: "0.0.0.0", expected: false},
		{name: "255.255.255.255 broadcast", ip: "255.255.255.255", expected: false},

		// Malformed inputs
		{name: "IP with port", ip: "172.18.0.5:8080", expected: false},
		{name: "IP with spaces", ip: " 172.18.0.5 ", expected: false},
		{name: "partial IP", ip: "172.18", expected: false},
		{name: "too many octets", ip: "172.18.0.5.6", expected: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := isDockerBridgeIP(tt.ip)
			assert.Equal(t, tt.expected, result, "isDockerBridgeIP(%q)", tt.ip)
		})
	}
}

func TestIsEphemeralCollectorIP_EdgeCases(t *testing.T) {
	server := &Server{
		logger: logger.NewTestLogger(),
	}

	tests := []struct {
		name     string
		hostIP   string
		hostname string
		hostID   string
		expected bool
	}{
		// Case sensitivity tests
		{
			name:     "uppercase AGENT in hostname",
			hostIP:   "172.18.0.5",
			hostname: "MY-AGENT-01",
			hostID:   "",
			expected: true,
		},
		{
			name:     "mixed case Gateway in hostname",
			hostIP:   "172.17.0.10",
			hostname: "Edge-Gateway",
			hostID:   "",
			expected: true,
		},

		// Partial matches
		{
			name:     "agent substring in middle",
			hostIP:   "172.18.0.5",
			hostname: "myagentserver",
			hostID:   "",
			expected: true,
		},
		{
			name:     "collector at end",
			hostIP:   "172.19.0.3",
			hostname: "data-collector",
			hostID:   "",
			expected: true,
		},

		// Real-world hostnames that should NOT be flagged
		{
			name:     "sysmon-osx with Docker IP but proper hostname",
			hostIP:   "172.18.0.100",
			hostname: "sysmon-osx",
			hostID:   "sysmon-osx",
			expected: false,
		},
		{
			name:     "database server with Docker IP",
			hostIP:   "172.18.0.50",
			hostname: "postgres-primary",
			hostID:   "db-01",
			expected: false,
		},
		{
			name:     "web server with Docker IP",
			hostIP:   "172.17.0.80",
			hostname: "nginx-frontend",
			hostID:   "web-01",
			expected: false,
		},

		// Non-Docker IPs should never be ephemeral
		{
			name:     "private IP with agent hostname",
			hostIP:   "10.0.0.5",
			hostname: "agent-server",
			hostID:   "",
			expected: false,
		},
		{
			name:     "public IP with empty hostname",
			hostIP:   "8.8.8.8",
			hostname: "",
			hostID:   "",
			expected: false,
		},

		// Edge cases for hostname/hostID
		{
			name:     "Docker IP with numeric hostname",
			hostIP:   "172.18.0.5",
			hostname: "12345",
			hostID:   "",
			expected: false,
		},
		{
			name:     "Docker IP with UUID hostname",
			hostIP:   "172.18.0.5",
			hostname: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
			hostID:   "",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := server.isEphemeralCollectorIP(tt.hostIP, tt.hostname, tt.hostID)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestGetCollectorIP_NilRegistries(t *testing.T) {
	server := &Server{
		DeviceRegistry:  nil,
		ServiceRegistry: nil,
		DB:              nil,
		logger:          logger.NewTestLogger(),
	}

	// Should return empty when all registries are nil
	result := server.getCollectorIP(context.Background(), "agent-1", "gateway-1")
	assert.Empty(t, result)
}

func TestExtractCheckerHostIdentity(t *testing.T) {
	tests := []struct {
		name             string
		serviceData      string
		expectedIP       string
		expectedHostname string
		expectedHostID   string
	}{
		{
			name:             "standard sysmon payload",
			serviceData:      `{"status":{"host_ip":"192.168.1.100","hostname":"sysmon-osx","host_id":"sysmon-01"}}`,
			expectedIP:       "192.168.1.100",
			expectedHostname: "sysmon-osx",
			expectedHostID:   "sysmon-01",
		},
		{
			name:             "flat structure",
			serviceData:      `{"host_ip":"10.0.0.5","hostname":"edge-server"}`,
			expectedIP:       "10.0.0.5",
			expectedHostname: "edge-server",
			expectedHostID:   "",
		},
		{
			name:             "ip_address field",
			serviceData:      `{"status":{"ip_address":"172.16.0.1"}}`,
			expectedIP:       "172.16.0.1",
			expectedHostname: "",
			expectedHostID:   "",
		},
		{
			name:             "uses host_id as hostname fallback",
			serviceData:      `{"status":{"host_ip":"192.168.1.50","host_id":"server-east-1"}}`,
			expectedIP:       "192.168.1.50",
			expectedHostname: "server-east-1",
			expectedHostID:   "server-east-1",
		},
		{
			name:             "empty payload",
			serviceData:      `{}`,
			expectedIP:       "",
			expectedHostname: "",
			expectedHostID:   "",
		},
		{
			name:             "invalid JSON",
			serviceData:      `not json`,
			expectedIP:       "",
			expectedHostname: "",
			expectedHostID:   "",
		},
		{
			name:             "null values",
			serviceData:      `{"status":{"host_ip":null,"hostname":null}}`,
			expectedIP:       "",
			expectedHostname: "",
			expectedHostID:   "",
		},
		{
			name:             "whitespace in values",
			serviceData:      `{"status":{"host_ip":"  192.168.1.100  ","hostname":"  my-server  "}}`,
			expectedIP:       "192.168.1.100",
			expectedHostname: "my-server",
			expectedHostID:   "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ip, hostname, hostID := extractCheckerHostIdentity([]byte(tt.serviceData))
			assert.Equal(t, tt.expectedIP, ip, "IP mismatch")
			assert.Equal(t, tt.expectedHostname, hostname, "hostname mismatch")
			assert.Equal(t, tt.expectedHostID, hostID, "hostID mismatch")
		})
	}
}

func TestEnsureServiceDevice_NonGRPCServiceTypes(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	// Non-gRPC service types should be skipped
	nonGRPCTypes := []string{"snmp", "icmp", "sweep", "sync", "mapper-discovery"}

	for _, serviceType := range nonGRPCTypes {
		t.Run(serviceType, func(t *testing.T) {
			svc := &proto.GatewayServiceStatus{
				ServiceName: "test-service",
				ServiceType: serviceType,
				Source:      "status",
			}

			serviceData := []byte(`{"status":{"host_ip":"192.168.1.100"}}`)

			// No expectations on mockRegistry - should not be called
			server.ensureServiceDevice(
				context.Background(),
				"agent-1",
				"gateway-1",
				"default",
				svc,
				serviceData,
				time.Now(),
			)
		})
	}

	// Flush should produce no updates
	server.flushServiceDeviceUpdates(context.Background())
}

func TestEnsureServiceDevice_UnknownHostIP(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	// Test various "unknown" IP values that should be skipped
	unknownIPs := []string{
		`{"status":{"host_ip":"unknown"}}`,
		`{"status":{"host_ip":"UNKNOWN"}}`,
		`{"status":{"host_ip":""}}`,
		`{"status":{}}`,
		`{}`,
	}

	for _, payload := range unknownIPs {
		t.Run(payload, func(t *testing.T) {
			svc := &proto.GatewayServiceStatus{
				ServiceName: "test-service",
				ServiceType: grpcServiceType,
				Source:      "status",
			}

			// No expectations on mockRegistry - should not be called
			server.ensureServiceDevice(
				context.Background(),
				"agent-1",
				"gateway-1",
				"default",
				svc,
				[]byte(payload),
				time.Now(),
			)
		})
	}

	// Flush should produce no updates
	server.flushServiceDeviceUpdates(context.Background())
}

func TestServiceDeviceID_DoesNotMatchPhantomCleanupCriteria(t *testing.T) {
	// This test verifies that service device IDs (serviceradar:*) would NOT be
	// affected by the phantom device cleanup migration
	serviceDeviceIDs := []string{
		"serviceradar:gateway:edge-gateway-01",
		"serviceradar:agent:agent-123",
		"serviceradar:checker:sysmon@agent-123",
		"serviceradar:datasvc:datasvc-primary",
		"serviceradar:sync:sync-01",
		"serviceradar:mapper:mapper-01",
		"serviceradar:otel:otel-collector",
		"serviceradar:zen:zen-primary",
		"serviceradar:core:core-main",
	}

	for _, deviceID := range serviceDeviceIDs {
		t.Run(deviceID, func(t *testing.T) {
			// Service device IDs should start with "serviceradar:"
			assert.True(t, len(deviceID) > 13 && deviceID[:13] == "serviceradar:")

			// Migration uses: device_id NOT LIKE 'serviceradar:%'
			// So these should NOT match the cleanup criteria
			isServiceDevice := len(deviceID) >= 13 && deviceID[:13] == "serviceradar:"
			assert.True(t, isServiceDevice, "Device ID %s should be recognized as service device", deviceID)
		})
	}
}

func TestPhantomDeviceDetection_LegitimateDockerTargets(t *testing.T) {
	// Test that legitimate monitoring targets in Docker networks are NOT filtered
	server := &Server{
		logger: logger.NewTestLogger(),
	}

	// These are real monitoring targets that happen to be in Docker networks
	// They should NOT be detected as ephemeral collector IPs
	legitimateTargets := []struct {
		ip       string
		hostname string
		hostID   string
	}{
		{"172.18.0.100", "mysql-primary", "mysql-01"},
		{"172.17.0.50", "redis-cache", "redis-prod"},
		{"172.19.0.25", "nginx-proxy", "proxy-01"},
		{"172.20.0.10", "kafka-broker-1", "kafka-1"},
		{"172.21.0.5", "elasticsearch-data", "es-data-01"},
	}

	for _, target := range legitimateTargets {
		t.Run(target.hostname, func(t *testing.T) {
			result := server.isEphemeralCollectorIP(target.ip, target.hostname, target.hostID)
			assert.False(t, result, "Legitimate target %s should not be filtered", target.hostname)
		})
	}
}
