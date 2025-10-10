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

package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/protobuf/types/known/wrapperspb"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
)

// Test errors - static errors for err113 compliance
var (
	errRegistryTest = errors.New("registry error")
)

func TestNewDiscoveryService(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)
	testLogger := logger.NewTestLogger()

	svc := NewDiscoveryService(mockDB, mockRegistry, testLogger)
	assert.NotNil(t, svc)

	// Verify it implements the interface
	var _ = svc
}

func TestProcessSyncResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	ctx := context.Background()
	timestamp := time.Now()

	tests := []struct {
		name          string
		setupMocks    func(*db.MockService, *registry.MockManager)
		deviceUpdates []*models.DeviceUpdate
		svc           *proto.ServiceStatus
		expectError   bool
		errorContains string
	}{
		{
			name: "successful processing with sightings",
			setupMocks: func(_ *db.MockService, mockReg *registry.MockManager) {
				mockReg.EXPECT().
					ProcessBatchDeviceUpdates(gomock.Any(), gomock.Len(1)).
					Return(nil)
			},
			deviceUpdates: []*models.DeviceUpdate{
				{
					AgentID:     "agent1",
					PollerID:    "poller1",
					DeviceID:    "partition1:192.168.1.1",
					Partition:   "partition1",
					Source:      models.DiscoverySourceIntegration,
					IP:          "192.168.1.1",
					Timestamp:   timestamp,
					IsAvailable: true,
					Metadata:    map[string]string{"test": "data"},
				},
			},
			svc: &proto.ServiceStatus{
				ServiceName: "sync",
				AgentId:     "agent1",
			},
			expectError: false,
		},
		{
			name: "no sightings found",
			setupMocks: func(_ *db.MockService, _ *registry.MockManager) {
				// No expectations - ProcessBatchDeviceUpdates should not be called
			},
			deviceUpdates: []*models.DeviceUpdate{},
			svc: &proto.ServiceStatus{
				ServiceName: "sync",
				AgentId:     "agent1",
			},
			expectError: false,
		},
		{
			name: "invalid JSON data",
			setupMocks: func(_ *db.MockService, _ *registry.MockManager) {
				// No expectations
			},
			deviceUpdates: nil, // This will cause JSON decode to fail
			svc:           &proto.ServiceStatus{ServiceName: "sync"},
			expectError:   true,
			errorContains: "read sync payload token",
		},
		{
			name: "registry error",
			setupMocks: func(_ *db.MockService, mockReg *registry.MockManager) {
				mockReg.EXPECT().
					ProcessBatchDeviceUpdates(gomock.Any(), gomock.Len(1)).
					Return(errRegistryTest)
			},
			deviceUpdates: []*models.DeviceUpdate{
				{
					Source: models.DiscoverySourceIntegration,
					IP:     "192.168.1.1",
				},
			},
			svc:           &proto.ServiceStatus{ServiceName: "sync"},
			expectError:   true,
			errorContains: "registry error",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockDB := db.NewMockService(ctrl)
			mockRegistry := registry.NewMockManager(ctrl)
			testLogger := logger.NewTestLogger()

			if tt.setupMocks != nil {
				tt.setupMocks(mockDB, mockRegistry)
			}

			svc := &discoveryService{
				db:     mockDB,
				reg:    mockRegistry,
				logger: testLogger,
			}

			var details json.RawMessage

			if tt.deviceUpdates != nil {
				data, err := json.Marshal(tt.deviceUpdates)
				require.NoError(t, err)

				details = data
			} else {
				details = []byte("invalid json")
			}

			err := svc.ProcessSyncResults(ctx, "poller1", "partition1", tt.svc, details, timestamp)

			if tt.expectError {
				require.Error(t, err)

				if tt.errorContains != "" {
					assert.Contains(t, err.Error(), tt.errorContains)
				}
			} else {
				require.NoError(t, err)
			}
		})
	}
}

func TestProcessSyncResults_NilRegistry(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	testLogger := logger.NewTestLogger()

	svc := &discoveryService{
		db:     mockDB,
		reg:    nil, // Nil registry
		logger: testLogger,
	}

	deviceUpdates := []*models.DeviceUpdate{
		{
			Source: models.DiscoverySourceIntegration,
			IP:     "192.168.1.1",
		},
	}

	details, err := json.Marshal(deviceUpdates)
	require.NoError(t, err)

	// Should not error when registry is nil, just log a warning
	err = svc.ProcessSyncResults(context.Background(), "poller1", "partition1",
		&proto.ServiceStatus{ServiceName: "sync"}, details, time.Now())
	assert.NoError(t, err)
}

func TestProcessSyncResults_StreamChunking(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	if testing.Short() {
		t.Skip("skipping chunk chunking integration in short mode")
	}

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)
	testLogger := logger.NewTestLogger()

	total := syncDeviceChunkSize*2 + 123
	details := getSyncTestPayload(t, total)
	var err error

	expectedChunks := (total + syncDeviceChunkSize - 1) / syncDeviceChunkSize
	var lengths []int

	mockRegistry.EXPECT().
		ProcessBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			lengths = append(lengths, len(updates))
			return nil
		}).
		Times(expectedChunks)

	svc := &discoveryService{
		db:     mockDB,
		reg:    mockRegistry,
		logger: testLogger,
	}

	err = svc.ProcessSyncResults(
		context.Background(),
		"poller1",
		"partition",
		&proto.ServiceStatus{ServiceName: "sync"},
		details,
		time.Now(),
	)
	require.NoError(t, err)

	require.Len(t, lengths, expectedChunks)
	sum := 0
	for _, l := range lengths {
		require.Positive(t, l)
		require.LessOrEqual(t, l, syncDeviceChunkSize)
		sum += l
	}
	require.Equal(t, total, sum)
}

type syncPayloadCache struct {
	once sync.Once
	data json.RawMessage
	err  error
}

var (
	shortSyncPayload syncPayloadCache
	fullSyncPayload  syncPayloadCache
)

func getSyncTestPayload(t *testing.T, total int) json.RawMessage {
	cache := &fullSyncPayload
	if testing.Short() {
		cache = &shortSyncPayload
	}

	cache.once.Do(func() {
		cache.data, cache.err = buildSyncPayload(total)
	})

	require.NoError(t, cache.err)
	return cache.data
}

func buildSyncPayload(total int) (json.RawMessage, error) {
	updates := make([]*models.DeviceUpdate, total)
	for i := 0; i < total; i++ {
		updates[i] = &models.DeviceUpdate{
			AgentID:     "agent1",
			PollerID:    "poller1",
			DeviceID:    fmt.Sprintf("partition:%d", i),
			Partition:   "partition",
			Source:      models.DiscoverySourceIntegration,
			IP:          fmt.Sprintf("10.0.0.%d", i%255),
			Timestamp:   time.Unix(int64(i), 0),
			IsAvailable: true,
		}
	}

	data, err := json.Marshal(updates)
	if err != nil {
		return nil, err
	}
	return data, nil
}

func TestProcessSNMPDiscoveryResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	ctx := context.Background()
	timestamp := time.Now()

	tests := []struct {
		name          string
		setupMocks    func(*db.MockService, *registry.MockManager)
		payload       models.SNMPDiscoveryDataPayload
		svc           *proto.ServiceStatus
		expectError   bool
		errorContains string
	}{
		{
			name: "successful processing with devices and interfaces",
			setupMocks: func(mockDB *db.MockService, mockReg *registry.MockManager) {
				// Expect device processing
				mockReg.EXPECT().ProcessBatchDeviceUpdates(gomock.Any(), gomock.Len(1)).Return(nil)
				// Expect interface storage
				mockDB.EXPECT().PublishBatchDiscoveredInterfaces(gomock.Any(), gomock.Len(2)).Return(nil)
				// Expect interface correlation processing
				mockReg.EXPECT().ProcessBatchDeviceUpdates(gomock.Any(), gomock.Len(1)).Return(nil)
			},
			payload: models.SNMPDiscoveryDataPayload{
				AgentID:  "agent1",
				PollerID: "poller1",
				Devices: []*discoverypb.DiscoveredDevice{
					{
						Ip:          "192.168.1.1",
						Hostname:    "device1",
						Mac:         "00:11:22:33:44:55",
						SysDescr:    "Test Device",
						SysObjectId: "1.3.6.1.4.1.9.1.1",
						Metadata:    map[string]string{"vendor": "cisco"},
					},
				},
				Interfaces: []*discoverypb.DiscoveredInterface{
					{
						DeviceIp:      "192.168.1.1",
						IfIndex:       1,
						IfName:        "eth0",
						IfDescr:       "Ethernet Interface",
						IfSpeed:       wrapperspb.UInt64(1000000000),
						IpAddresses:   []string{"192.168.1.1", "10.0.0.1"},
						IfAdminStatus: 1,
						IfOperStatus:  1,
					},
					{
						DeviceIp:    "192.168.1.1",
						IfIndex:     2,
						IfName:      "eth1",
						IpAddresses: []string{"192.168.2.1"},
					},
				},
			},
			svc: &proto.ServiceStatus{
				ServiceName: "mapper",
				AgentId:     "agent1",
			},
			expectError: false,
		},
		{
			name: "empty payload IDs use fallbacks",
			setupMocks: func(_ *db.MockService, mockReg *registry.MockManager) {
				mockReg.EXPECT().ProcessBatchDeviceUpdates(gomock.Any(), gomock.Any()).Return(nil)
			},
			payload: models.SNMPDiscoveryDataPayload{
				// AgentID and PollerID are empty - should fall back to svc values
				Devices: []*discoverypb.DiscoveredDevice{
					{
						Ip:       "192.168.1.1",
						Hostname: "device1",
					},
				},
			},
			svc: &proto.ServiceStatus{
				ServiceName: "mapper",
				AgentId:     "fallback-agent",
			},
			expectError: false,
		},
		{
			name: "invalid JSON data",
			setupMocks: func(_ *db.MockService, _ *registry.MockManager) {
				// No expectations
			},
			payload:       models.SNMPDiscoveryDataPayload{}, // This will be overridden
			svc:           &proto.ServiceStatus{ServiceName: "mapper"},
			expectError:   true,
			errorContains: "failed to parse SNMP discovery data",
		},
		{
			name: "topology processing",
			setupMocks: func(mockDB *db.MockService, _ *registry.MockManager) {
				mockDB.EXPECT().PublishBatchTopologyDiscoveryEvents(gomock.Any(), gomock.Len(1)).Return(nil)
			},
			payload: models.SNMPDiscoveryDataPayload{
				Topology: []*discoverypb.TopologyLink{
					{
						LocalDeviceIp:      "192.168.1.1",
						LocalDeviceId:      "device1",
						LocalIfIndex:       1,
						LocalIfName:        "eth0",
						Protocol:           "LLDP",
						NeighborChassisId:  "neighbor1",
						NeighborPortId:     "port1",
						NeighborSystemName: "Neighbor Device",
						NeighborMgmtAddr:   "192.168.1.2",
						Metadata:           map[string]string{"test": "data"},
					},
				},
			},
			svc:         &proto.ServiceStatus{ServiceName: "mapper"},
			expectError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockDB := db.NewMockService(ctrl)
			mockRegistry := registry.NewMockManager(ctrl)
			testLogger := logger.NewTestLogger()

			if tt.setupMocks != nil {
				tt.setupMocks(mockDB, mockRegistry)
			}

			svc := &discoveryService{
				db:     mockDB,
				reg:    mockRegistry,
				logger: testLogger,
			}

			var details json.RawMessage
			if tt.name == "invalid JSON data" {
				details = []byte("invalid json")
			} else {
				data, err := json.Marshal(tt.payload)
				require.NoError(t, err)

				details = data
			}

			err := svc.ProcessSNMPDiscoveryResults(ctx, "poller1", "partition1", tt.svc, details, timestamp)

			if tt.expectError {
				require.Error(t, err)

				if tt.errorContains != "" {
					assert.Contains(t, err.Error(), tt.errorContains)
				}
			} else {
				require.NoError(t, err)
			}
		})
	}
}

func TestExtractDeviceMetadata(t *testing.T) {
	svc := &discoveryService{
		logger: logger.NewTestLogger(),
	}

	tests := []struct {
		name     string
		device   *discoverypb.DiscoveredDevice
		expected map[string]string
	}{
		{
			name: "full device metadata",
			device: &discoverypb.DiscoveredDevice{
				Hostname:    "USW-Switch-01",
				SysDescr:    "Ubiquiti UniFi Switch",
				SysObjectId: "1.3.6.1.4.1.41112",
				SysContact:  "admin@example.com",
				SysLocation: "Server Room",
				Uptime:      86400,
				Metadata: map[string]string{
					"custom": "value",
				},
			},
			expected: map[string]string{
				"custom":        "value",
				"sys_descr":     "Ubiquiti UniFi Switch",
				"sys_object_id": "1.3.6.1.4.1.41112",
				"sys_contact":   "admin@example.com",
				"sys_location":  "Server Room",
				"uptime":        "86400",
				"device_type":   "switch",
			},
		},
		{
			name:   "empty device",
			device: &discoverypb.DiscoveredDevice{},
			expected: map[string]string{
				"device_type": "network_device",
			},
		},
		{
			name: "device with only hostname",
			device: &discoverypb.DiscoveredDevice{
				Hostname: "nano-hd-ap",
			},
			expected: map[string]string{
				"device_type": "wireless_ap",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := svc.extractDeviceMetadata(tt.device)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestClassifyDeviceType(t *testing.T) {
	tests := []struct {
		name        string
		hostname    string
		sysDescr    string
		sysObjectID string
		expected    string
	}{
		{
			name:     "Ubiquiti switch by hostname",
			hostname: "USW-24-POE",
			expected: "switch_poe",
		},
		{
			name:     "Ubiquiti AP by hostname",
			hostname: "U6-Pro",
			expected: "wireless_ap",
		},
		{
			name:        "Cisco device by OID",
			sysObjectID: "1.3.6.1.4.1.9.1.1",
			expected:    "cisco_device",
		},
		{
			name:     "Generic switch by description",
			sysDescr: "Managed Ethernet Switch",
			expected: "switch",
		},
		{
			name:     "Firewall by description",
			sysDescr: "FortiGate Firewall Appliance",
			expected: "firewall",
		},
		{
			name:     "Linux host",
			sysDescr: "Linux debian 5.4.0",
			expected: "host",
		},
		{
			name:     "Unknown device",
			hostname: "unknown-device",
			expected: "network_device",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := classifyDeviceType(tt.hostname, tt.sysDescr, tt.sysObjectID)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestIsLoopbackIP(t *testing.T) {
	tests := []struct {
		ip       string
		expected bool
	}{
		{"127.0.0.1", true},
		{"::1", true},
		{"192.168.1.1", false},
		{"10.0.0.1", false},
		{"invalid-ip", false},
		{"", false},
	}

	for _, tt := range tests {
		t.Run(tt.ip, func(t *testing.T) {
			result := isLoopbackIP(tt.ip)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestGroupInterfacesByDevice(t *testing.T) {
	svc := &discoveryService{
		logger: logger.NewTestLogger(),
	}

	interfaces := []*discoverypb.DiscoveredInterface{
		{DeviceIp: "192.168.1.1", IfIndex: 1},
		{DeviceIp: "192.168.1.1", IfIndex: 2},
		{DeviceIp: "192.168.1.2", IfIndex: 1},
		nil,                        // Nil interface should be skipped
		{DeviceIp: "", IfIndex: 3}, // Empty IP should be skipped
	}

	result := svc.groupInterfacesByDevice(interfaces)

	assert.Len(t, result, 2)
	assert.Len(t, result["192.168.1.1"], 2)
	assert.Len(t, result["192.168.1.2"], 1)
}

func TestCollectDeviceIPs(t *testing.T) {
	svc := &discoveryService{
		logger: logger.NewTestLogger(),
	}

	interfaces := []*discoverypb.DiscoveredInterface{
		{IpAddresses: []string{"192.168.1.1", "10.0.0.1"}},
		{IpAddresses: []string{"192.168.1.1", "172.16.0.1"}}, // Duplicate IP
		{IpAddresses: []string{"127.0.0.1"}},                 // Loopback should be excluded
		{IpAddresses: []string{""}},                          // Empty IP should be excluded
	}

	result := svc.collectDeviceIPs("192.168.1.1", interfaces)

	// Should have 2 alternate IPs (10.0.0.1 and 172.16.0.1)
	// Primary IP (192.168.1.1) is not included in alternates
	assert.Len(t, result, 2)
	assert.Contains(t, result, "10.0.0.1")
	assert.Contains(t, result, "172.16.0.1")
}

func TestPrepareInterfaceMetadata(t *testing.T) {
	svc := &discoveryService{
		logger: logger.NewTestLogger(),
	}

	tests := []struct {
		name      string
		iface     *discoverypb.DiscoveredInterface
		wantEmpty bool
	}{
		{
			name: "interface with metadata",
			iface: &discoverypb.DiscoveredInterface{
				DeviceIp: "192.168.1.1",
				IfIndex:  1,
				IfType:   6, // Ethernet
				Metadata: map[string]string{
					"custom": "value",
				},
			},
			wantEmpty: false,
		},
		{
			name: "interface without metadata",
			iface: &discoverypb.DiscoveredInterface{
				DeviceIp: "192.168.1.1",
				IfIndex:  1,
			},
			wantEmpty: false, // Should have empty JSON object
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := svc.prepareInterfaceMetadata(tt.iface)
			assert.NotNil(t, result)

			var metadata map[string]string

			err := json.Unmarshal(result, &metadata)
			require.NoError(t, err)

			if tt.iface.IfType != 0 {
				assert.Equal(t, "6", metadata["if_type"])
			}

			if tt.iface.Metadata != nil {
				assert.Equal(t, tt.iface.Metadata["custom"], metadata["custom"])
			}
		})
	}
}

func TestGetOrGenerateLocalDeviceID(t *testing.T) {
	svc := &discoveryService{
		logger: logger.NewTestLogger(),
	}

	tests := []struct {
		name      string
		link      *discoverypb.TopologyLink
		partition string
		expected  string
	}{
		{
			name: "link with device ID",
			link: &discoverypb.TopologyLink{
				LocalDeviceId: "existing-id",
				LocalDeviceIp: "192.168.1.1",
			},
			partition: "partition1",
			expected:  "existing-id",
		},
		{
			name: "link without device ID",
			link: &discoverypb.TopologyLink{
				LocalDeviceId: "",
				LocalDeviceIp: "192.168.1.1",
			},
			partition: "partition1",
			expected:  "partition1:192.168.1.1",
		},
		{
			name: "link without device ID or IP",
			link: &discoverypb.TopologyLink{
				LocalDeviceId: "",
				LocalDeviceIp: "",
			},
			partition: "partition1",
			expected:  "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := svc.getOrGenerateLocalDeviceID(tt.link, tt.partition)
			assert.Equal(t, tt.expected, result)
		})
	}
}
