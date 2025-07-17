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
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestProcessMetrics_SyncService_PayloadDetection(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)
	mockDiscovery := NewMockDiscoveryService(ctrl)

	server := &Server{
		DB:               mockDB,
		DeviceRegistry:   mockRegistry,
		discoveryService: mockDiscovery,
		metricBuffers:    make(map[string][]*models.TimeseriesMetric),
		sysmonBuffers:    make(map[string][]*sysmonMetricBuffer),
	}

	ctx := context.Background()
	pollerID := "test-poller"
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

			if tt.expectProcess {
				// Expect ProcessSyncResults to be called when payload is valid SweepResult array
				mockDiscovery.EXPECT().
					ProcessSyncResults(ctx, pollerID, partition, svc, tt.message, timestamp).
					Return(tt.expectedError)
			}
			// If !expectProcess, we expect NO call to ProcessSyncResults

			err := server.processMetrics(ctx, pollerID, partition, sourceIP, svc, tt.message, timestamp)

			if tt.expectedError != nil {
				require.Error(t, err)
				assert.Equal(t, tt.expectedError, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestProcessMetrics_SyncService_WithEnhancedPayload(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)
	mockDiscovery := NewMockDiscoveryService(ctrl)

	server := &Server{
		DB:               mockDB,
		DeviceRegistry:   mockRegistry,
		discoveryService: mockDiscovery,
		metricBuffers:    make(map[string][]*models.TimeseriesMetric),
		sysmonBuffers:    make(map[string][]*sysmonMetricBuffer),
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

	err = server.processMetrics(ctx, "original-poller", "original-partition", "192.168.1.100", svc, enhancedMessage, timestamp)
	require.NoError(t, err)
}

func TestProcessMetrics_SyncService_HealthCheckNotProcessed(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)
	mockDiscovery := NewMockDiscoveryService(ctrl)

	server := &Server{
		DB:               mockDB,
		DeviceRegistry:   mockRegistry,
		discoveryService: mockDiscovery,
		metricBuffers:    make(map[string][]*models.TimeseriesMetric),
		sysmonBuffers:    make(map[string][]*sysmonMetricBuffer),
	}

	ctx := context.Background()
	pollerID := "test-poller"
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

	// Should NOT call ProcessSyncResults because payload doesn't unmarshal as SweepResult array
	// No mock expectation set = test will fail if ProcessSyncResults is called

	err := server.processMetrics(ctx, pollerID, partition, sourceIP, svc, healthCheckMessage, timestamp)
	require.NoError(t, err)
}
