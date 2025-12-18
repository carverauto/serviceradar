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
	"fmt"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

const (
	testPollerID = "test-poller"
)

func TestProcessServicePayload_SyncService_PayloadDetection(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)
	mockDiscovery := NewMockDiscoveryService(ctrl)

	mockRegistry.EXPECT().
		SetDeviceCapabilitySnapshot(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceCapabilitySnapshot{})).
		AnyTimes()

	server := &Server{
		DB:               mockDB,
		DeviceRegistry:   mockRegistry,
		discoveryService: mockDiscovery,
		metricBuffers:    make(map[string][]*models.TimeseriesMetric),
		sysmonBuffers:    make(map[string][]*sysmonMetricBuffer),
		logger:           logger.NewTestLogger(),
	}

	ctx := context.Background()
	pollerID := testPollerID
	partition := "test-partition"
	sourceIP := "192.168.1.100"
	timestamp := time.Now()

	tests := []struct {
		name          string
		message       json.RawMessage
		expectProcess bool
		expectedError error
	}{
		{
			name: "Health check data should be skipped",
			message: json.RawMessage(`{
				"status": "healthy",
				"cached_sources": 2,
				"cached_devices": 10,
				"timestamp": 1234567890
			}`),
			expectProcess: false,
			expectedError: nil,
		},
		{
			name: "Valid SweepResult array should be processed",
			message: json.RawMessage(`[
				{
					"agent_id": "agent-1",
					"poller_id": "poller-1",
					"partition": "default",
					"device_id": "default:192.168.1.1",
					"discovery_source": "armis",
					"ip": "192.168.1.1",
					"hostname": "device1",
					"timestamp": "2025-01-13T12:00:00Z",
					"available": true
				}
			]`),
			expectProcess: true,
			expectedError: nil,
		},
		{
			name:          "Empty SweepResult array should be skipped",
			message:       json.RawMessage(`[]`),
			expectProcess: false,
			expectedError: nil,
		},
		{
			name:          "Invalid JSON should be skipped",
			message:       json.RawMessage(`invalid json`),
			expectProcess: false,
			expectedError: nil,
		},
		{
			name:          "Non-SweepResult array should be skipped",
			message:       json.RawMessage(`["string1", "string2"]`),
			expectProcess: false,
			expectedError: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svc := &proto.ServiceStatus{
				ServiceName: "sync",
				ServiceType: "grpc",
				Available:   true,
				Message:     tt.message,
				AgentId:     "test-agent",
				PollerId:    pollerID,
				Source:      "results", // Source field doesn't matter anymore
			}

			// ProcessSyncResults is now always called - it internally handles status checks
			mockDiscovery.EXPECT().
				ProcessSyncResults(ctx, pollerID, partition, svc, tt.message, timestamp).
				Return(tt.expectedError)

			err := server.processServicePayload(ctx, pollerID, partition, sourceIP, svc, tt.message, timestamp)

			if tt.expectedError != nil {
				require.Error(t, err)
				assert.Equal(t, tt.expectedError, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestProcessSysmonMetrics_EmitsStallEventAfterEmptyPayloads(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)

	mockRegistry.EXPECT().
		SetDeviceCapabilitySnapshot(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceCapabilitySnapshot{})).
		Do(func(_ context.Context, snapshot *models.DeviceCapabilitySnapshot) {
			require.Equal(t, "sysmon", snapshot.Capability)
			require.True(t, snapshot.Enabled)
			require.Equal(t, "failed", snapshot.State)
		}).
		Times(1)
	mockRegistry.EXPECT().
		GetCollectorCapabilities(gomock.Any(), "default:192.0.2.10").
		Return(nil, false).
		AnyTimes()
	mockRegistry.EXPECT().
		SetCollectorCapabilities(gomock.Any(), gomock.AssignableToTypeOf(&models.CollectorCapability{})).
		AnyTimes()
	mockDB.EXPECT().
		GetOCSFDevicesByIPsOrIDs(gomock.Any(), []string{"192.0.2.10"}, gomock.Nil()).
		Return([]*models.OCSFDevice{}, nil).
		AnyTimes()

	server := &Server{
		DB:             mockDB,
		DeviceRegistry: mockRegistry,
		sysmonBuffers:  make(map[string][]*sysmonMetricBuffer),
		sysmonStall:    make(map[string]*sysmonStreamState),
		logger:         logger.NewTestLogger(),
	}

	now := time.Now().UTC()
	payload := sysmonPayload{
		Available: true,
	}
	payload.Status.Timestamp = now.Format(time.RFC3339Nano)
	payload.Status.HostIP = "192.0.2.10"
	payload.Status.HostID = "sysmon-osx-01"

	raw, err := json.Marshal(payload)
	require.NoError(t, err)

	ctx := context.Background()
	for i := 0; i < sysmonStallPollThreshold; i++ {
		err := server.processSysmonMetrics(ctx, testPollerID, "default", "agent-1", raw, now.Add(time.Duration(i)*time.Second))
		require.NoError(t, err)
	}
}

func TestProcessGRPCService_SysmonPrefixedName(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)

	mockRegistry.EXPECT().
		SetDeviceCapabilitySnapshot(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceCapabilitySnapshot{})).
		AnyTimes()
	mockRegistry.EXPECT().
		GetCollectorCapabilities(gomock.Any(), gomock.Any()).
		Return(nil, false).
		AnyTimes()
	mockRegistry.EXPECT().
		SetCollectorCapabilities(gomock.Any(), gomock.Any()).
		AnyTimes()
	mockDB.EXPECT().
		GetOCSFDevicesByIPsOrIDs(gomock.Any(), []string{"192.0.2.10"}, gomock.Nil()).
		Return([]*models.OCSFDevice{}, nil).
		AnyTimes()

	server := &Server{
		DB:             mockDB,
		DeviceRegistry: mockRegistry,
		sysmonBuffers:  make(map[string][]*sysmonMetricBuffer),
		sysmonStall:    make(map[string]*sysmonStreamState),
		logger:         logger.NewTestLogger(),
	}

	now := time.Now().UTC()
	payload := sysmonPayload{
		Available: true,
	}
	payload.Status.Timestamp = now.Format(time.RFC3339Nano)
	payload.Status.HostIP = "192.0.2.10"
	payload.Status.HostID = "sysmon-ora9"
	payload.Status.Memory.TotalBytes = 1
	payload.Status.Memory.UsedBytes = 1

	raw, err := json.Marshal(payload)
	require.NoError(t, err)

	svc := &proto.ServiceStatus{
		ServiceName: "sysmon-ora9",
		ServiceType: "grpc",
	}

	err = server.processGRPCService(context.Background(), testPollerID, "default", "", "agent-1", svc, raw, now)
	require.NoError(t, err)

	buffers := server.sysmonBuffers[testPollerID]
	require.Len(t, buffers, 1)
	assert.Equal(t, "default", buffers[0].Partition)
}

func TestProcessServicePayload_SyncService_WithEnhancedPayload(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)
	mockDiscovery := NewMockDiscoveryService(ctrl)

	mockRegistry.EXPECT().
		SetDeviceCapabilitySnapshot(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceCapabilitySnapshot{})).
		AnyTimes()

	server := &Server{
		DB:               mockDB,
		DeviceRegistry:   mockRegistry,
		discoveryService: mockDiscovery,
		metricBuffers:    make(map[string][]*models.TimeseriesMetric),
		sysmonBuffers:    make(map[string][]*sysmonMetricBuffer),
		logger:           logger.NewTestLogger(),
	}

	ctx := context.Background()
	timestamp := time.Now()

	// Test with enhanced payload wrapper
	discoveryData := json.RawMessage(`[
		{
			"agent_id": "agent-1",
			"poller_id": "poller-1",
			"partition": "default",
			"device_id": "default:192.168.1.1",
			"discovery_source": "armis",
			"ip": "192.168.1.1",
			"timestamp": "2025-01-13T12:00:00Z",
			"available": true
		}
	]`)

	enhancedPayload := models.ServiceMetricsPayload{
		PollerID:  "enhanced-poller",
		Partition: "enhanced-partition",
		AgentID:   "enhanced-agent",
		Data:      discoveryData,
	}

	enhancedMessage, err := json.Marshal(enhancedPayload)
	require.NoError(t, err)

	svc := &proto.ServiceStatus{
		ServiceName: "sync",
		ServiceType: "grpc",
		Available:   true,
		Message:     enhancedMessage,
		AgentId:     "original-agent",
		PollerId:    "original-poller",
		Source:      "results", // Must be "results" to process
	}

	// Expect ProcessSyncResults to be called with enhanced context
	mockDiscovery.EXPECT().
		ProcessSyncResults(
			ctx,
			"enhanced-poller",    // Should use enhanced context
			"enhanced-partition", // Should use enhanced context
			svc,
			gomock.Any(), // The extracted discovery data (whitespace may vary)
			timestamp,
		).
		Return(nil)

	err = server.processServicePayload(ctx, "original-poller", "original-partition", "192.168.1.100", svc, enhancedMessage, timestamp)
	require.NoError(t, err)
}

func TestBuildHostAliasUpdate(t *testing.T) {
	now := time.Now()
	hostID := "default:10.0.0.8"
	serviceID := "serviceradar:agent:k8s-agent"
	update := buildHostAliasUpdate(
		hostID,
		"",
		"ignored",
		serviceID,
		"agent-1",
		"poller-1",
		"10.0.0.8",
		true,
		now,
	)

	require.NotNil(t, update)
	assert.Equal(t, hostID, update.DeviceID)
	assert.Equal(t, "default", update.Partition)
	assert.Equal(t, models.DiscoverySourceServiceRadar, update.Source)
	assert.True(t, update.IsAvailable)
	assert.Equal(t, "10.0.0.8", update.IP)
	assert.Equal(t, serviceID, update.Metadata["_alias_last_seen_service_id"])
	assert.Equal(t, hostID, update.Metadata["canonical_device_id"])
	assert.Contains(t, update.Metadata, fmt.Sprintf("service_alias:%s", serviceID))
	assert.Contains(t, update.Metadata, fmt.Sprintf("ip_alias:%s", "10.0.0.8"))
}

func TestProcessServicePayload_SyncService_HealthCheckNotProcessed(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)
	mockDiscovery := NewMockDiscoveryService(ctrl)

	mockRegistry.EXPECT().
		SetDeviceCapabilitySnapshot(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceCapabilitySnapshot{})).
		AnyTimes()

	server := &Server{
		DB:               mockDB,
		DeviceRegistry:   mockRegistry,
		discoveryService: mockDiscovery,
		metricBuffers:    make(map[string][]*models.TimeseriesMetric),
		sysmonBuffers:    make(map[string][]*sysmonMetricBuffer),
		logger:           logger.NewTestLogger(),
	}

	ctx := context.Background()
	pollerID := testPollerID
	partition := "test-partition"
	sourceIP := "192.168.1.100"
	timestamp := time.Now()

	// Health check payload should not be processed (doesn't unmarshal as SweepResult array)
	healthCheckMessage := json.RawMessage(`{
		"status": "healthy",
		"cached_sources": 2,
		"cached_devices": 10,
		"timestamp": 1234567890
	}`)

	svc := &proto.ServiceStatus{
		ServiceName: "sync",
		ServiceType: "grpc",
		Available:   true,
		Message:     healthCheckMessage,
		AgentId:     "test-agent",
		PollerId:    pollerID,
		Source:      "status", // Source field is ignored with new payload detection
	}

	// ProcessSyncResults is now always called - it internally checks and skips status payloads
	mockDiscovery.EXPECT().
		ProcessSyncResults(ctx, pollerID, partition, svc, healthCheckMessage, timestamp).
		Return(nil)

	err := server.processServicePayload(ctx, pollerID, partition, sourceIP, svc, healthCheckMessage, timestamp)
	require.NoError(t, err)
}

func TestProcessICMPMetricsPrefersAgentDeviceWhenSourceIPInvalid(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)
	mockRegistry.EXPECT().GetCollectorCapabilities(gomock.Any(), gomock.Any()).Return(nil, false).AnyTimes()
	mockRegistry.EXPECT().SetCollectorCapabilities(gomock.Any(), gomock.Any()).AnyTimes()
	mockRegistry.EXPECT().SetDeviceCapabilitySnapshot(gomock.Any(), gomock.Any()).AnyTimes()

	server := &Server{
		metricBuffers:  make(map[string][]*models.TimeseriesMetric),
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	ctx := context.Background()
	now := time.Now()

	svc := &proto.ServiceStatus{
		ServiceName: "ping",
		ServiceType: "icmp",
		Available:   true,
	}

	payload := []byte(`{"host":"8.8.8.8","response_time":10,"packet_loss":0,"available":true}`)

	err := server.processICMPMetrics(ctx, "k8s-poller", "default", "poller", "k8s-agent", svc, payload, now)
	require.NoError(t, err)

	server.serviceDeviceMu.Lock()
	defer server.serviceDeviceMu.Unlock()

	update, ok := server.serviceDeviceBuffer["serviceradar:agent:k8s-agent"]
	require.True(t, ok, "expected ICMP update to attach to agent service device")
	assert.Equal(t, "serviceradar:agent:k8s-agent", update.DeviceID)
	assert.Equal(t, "default", update.Partition)
	assert.Empty(t, update.IP, "collector IP should be resolved or empty, not a placeholder")
	assert.Empty(t, update.Metadata["collector_ip"], "collector_ip should not contain non-IP placeholders")
}

func TestProcessICMPMetricsIgnoresCanonicalRemapWhenAgentPresent(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)
	mockRegistry.EXPECT().GetCollectorCapabilities(gomock.Any(), gomock.Any()).Return(nil, false).AnyTimes()
	mockRegistry.EXPECT().SetCollectorCapabilities(gomock.Any(), gomock.Any()).AnyTimes()
	mockRegistry.EXPECT().SetDeviceCapabilitySnapshot(gomock.Any(), gomock.Any()).AnyTimes()

	server := &Server{
		metricBuffers:       make(map[string][]*models.TimeseriesMetric),
		logger:              logger.NewTestLogger(),
		DeviceRegistry:      mockRegistry,
		canonicalCache:      newCanonicalCache(time.Minute),
		serviceDeviceBuffer: make(map[string]*models.DeviceUpdate),
	}

	// Seed canonical cache to map collector IP to poller device, which should be ignored for agent ICMP.
	server.canonicalCache.store("10.0.0.10", canonicalSnapshot{
		DeviceID: models.GenerateServiceDeviceID(models.ServiceTypePoller, "k8s-poller"),
		IP:       "10.0.0.10",
	})

	ctx := context.Background()
	now := time.Now()

	svc := &proto.ServiceStatus{
		ServiceName: "ping",
		ServiceType: "icmp",
		Available:   true,
	}

	payload := []byte(`{"host":"8.8.8.8","response_time":10,"packet_loss":0,"available":true}`)

	err := server.processICMPMetrics(ctx, "k8s-poller", "default", "10.0.0.10", "k8s-agent", svc, payload, now)
	require.NoError(t, err)

	server.serviceDeviceMu.Lock()
	defer server.serviceDeviceMu.Unlock()

	update, ok := server.serviceDeviceBuffer["serviceradar:agent:k8s-agent"]
	require.True(t, ok, "expected ICMP update to stay on agent service device")
	assert.Equal(t, "serviceradar:agent:k8s-agent", update.DeviceID)
	assert.Equal(t, "default", update.Partition)
}

func TestProcessICMPMetricsSkipsWhenAgentMissing(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		metricBuffers:       make(map[string][]*models.TimeseriesMetric),
		logger:              logger.NewTestLogger(),
		DeviceRegistry:      mockRegistry,
		canonicalCache:      newCanonicalCache(time.Minute),
		serviceDeviceBuffer: make(map[string]*models.DeviceUpdate),
	}

	ctx := context.Background()
	now := time.Now()

	svc := &proto.ServiceStatus{
		ServiceName: "ping",
		ServiceType: "icmp",
		Available:   true,
	}

	payload := []byte(`{"host":"8.8.8.8","response_time":10,"packet_loss":0,"available":true}`)

	err := server.processICMPMetrics(ctx, "k8s-poller", "default", "10.0.0.10", "", svc, payload, now)
	require.NoError(t, err)

	server.serviceDeviceMu.Lock()
	defer server.serviceDeviceMu.Unlock()

	assert.Empty(t, server.serviceDeviceBuffer, "no device updates should be recorded without agent")
}

func TestProcessICMPMetricsIgnoresPayloadDeviceIDWhenAgentPresent(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)
	mockRegistry.EXPECT().GetCollectorCapabilities(gomock.Any(), gomock.Any()).Return(nil, false).AnyTimes()
	mockRegistry.EXPECT().SetCollectorCapabilities(gomock.Any(), gomock.Any()).AnyTimes()
	mockRegistry.EXPECT().SetDeviceCapabilitySnapshot(gomock.Any(), gomock.Any()).AnyTimes()

	server := &Server{
		metricBuffers:       make(map[string][]*models.TimeseriesMetric),
		logger:              logger.NewTestLogger(),
		DeviceRegistry:      mockRegistry,
		canonicalCache:      newCanonicalCache(time.Minute),
		serviceDeviceBuffer: make(map[string]*models.DeviceUpdate),
	}

	ctx := context.Background()
	now := time.Now()

	svc := &proto.ServiceStatus{
		ServiceName: "ping",
		ServiceType: "icmp",
		Available:   true,
	}

	payload := []byte(`{"host":"8.8.4.4","response_time":25,"packet_loss":0,"available":true,"device_id":"default:agent"}`)

	err := server.processICMPMetrics(ctx, "k8s-poller", "default", "agent", "k8s-agent", svc, payload, now)
	require.NoError(t, err)

	server.serviceDeviceMu.Lock()
	update, ok := server.serviceDeviceBuffer["serviceradar:agent:k8s-agent"]
	server.serviceDeviceMu.Unlock()
	require.True(t, ok, "expected ICMP update to attach to agent service device")
	assert.Equal(t, "serviceradar:agent:k8s-agent", update.DeviceID)
	assert.Equal(t, "k8s-agent", update.AgentID)
	assert.Equal(t, "k8s-poller", update.PollerID)
	assert.Equal(t, "default", update.Partition)

	server.metricBufferMu.Lock()
	metrics := server.metricBuffers["k8s-poller"]
	server.metricBufferMu.Unlock()
	require.Len(t, metrics, 1, "expected one buffered metric")
	assert.Equal(t, "serviceradar:agent:k8s-agent", metrics[0].DeviceID)

	var metadata map[string]string
	require.NoError(t, json.Unmarshal([]byte(metrics[0].Metadata), &metadata))
	assert.Equal(t, "serviceradar:agent:k8s-agent", metadata["device_id"])
	assert.Equal(t, "default:agent", metadata["target_device_id"], "target_device_id should preserve payload device hint")
	assert.Equal(t, "8.8.4.4", metadata["target_host"])
}
