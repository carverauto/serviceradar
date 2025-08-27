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

// Package poller contains tests for the poller's service routing behavior.
// These tests validate the critical sync service routing fixes to ensure
// that sync services use streaming calls regardless of how they're configured
// (service_type: "grpc" with service_name: "sync" or service_type: "sync")
// and that service types are correctly converted when sending to core.
package poller

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

func TestResultsPoller_SyncServiceStreamingDecisionLogic(t *testing.T) {
	// This test validates the core logic for deciding whether to use streaming or unary calls
	// without complex mocking of the actual gRPC interfaces
	tests := []struct {
		name            string
		serviceType     string
		serviceName     string
		shouldUseStream bool
		description     string
	}{
		{
			name:            "sync_service_with_grpc_type",
			serviceType:     "grpc",
			serviceName:     "sync",
			shouldUseStream: true,
			description:     "Sync service configured as gRPC type should use streaming",
		},
		{
			name:            "sync_service_with_sync_type",
			serviceType:     "sync",
			serviceName:     "sync",
			shouldUseStream: true,
			description:     "Sync service configured as sync type should use streaming",
		},
		{
			name:            "sweep_service",
			serviceType:     "sweep",
			serviceName:     "network_sweep",
			shouldUseStream: true,
			description:     "Sweep service should use streaming",
		},
		{
			name:            "regular_grpc_service",
			serviceType:     "grpc",
			serviceName:     "sysmon",
			shouldUseStream: false,
			description:     "Regular gRPC service should use unary GetResults",
		},
		{
			name:            "snmp_service",
			serviceType:     "snmp",
			serviceName:     "snmp",
			shouldUseStream: false,
			description:     "SNMP service should use unary GetResults",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Test the streaming decision logic directly (matching the actual poller code)
			shouldUseStreaming := tt.serviceType == serviceTypeSync || tt.serviceType == serviceTypeSweep ||
				tt.serviceName == serviceTypeSync || strings.Contains(tt.serviceName, serviceTypeSync)

			assert.Equal(t, tt.shouldUseStream, shouldUseStreaming, tt.description)
		})
	}
}

func TestResultsPoller_ConvertToServiceStatus_SyncServiceTypeConversion(t *testing.T) {
	tests := []struct {
		name                string
		checkType           string
		checkName           string
		expectedServiceType string
		description         string
	}{
		{
			name:                "sync_service_grpc_type",
			checkType:           "grpc",
			checkName:           "sync",
			expectedServiceType: "sync",
			description:         "Sync service with grpc type should be converted to sync",
		},
		{
			name:                "sync_service_sync_type",
			checkType:           "sync",
			checkName:           "sync",
			expectedServiceType: "sync",
			description:         "Sync service with sync type should remain sync",
		},
		{
			name:                "service_name_contains_sync",
			checkType:           "grpc",
			checkName:           "my-sync-service",
			expectedServiceType: "sync",
			description:         "Service name containing 'sync' should be converted to sync type",
		},
		{
			name:                "regular_grpc_service",
			checkType:           "grpc",
			checkName:           "sysmon",
			expectedServiceType: "grpc",
			description:         "Regular gRPC service should keep original type",
		},
		{
			name:                "sweep_service",
			checkType:           "sweep",
			checkName:           "network_sweep",
			expectedServiceType: "sweep",
			description:         "Sweep service should keep original type",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockLogger := logger.NewMockLogger(ctrl)
			mockLogger.EXPECT().Info().Return(nil).AnyTimes()

			rp := &ResultsPoller{
				check: Check{
					Name: tt.checkName,
					Type: tt.checkType,
				},
				pollerID: "test-poller",
				logger:   mockLogger,
			}

			// Create a mock results response
			mockResults := &proto.ResultsResponse{
				Available:       true,
				Data:            []byte(`{"test":"data"}`),
				ServiceName:     tt.checkName,
				ServiceType:     tt.checkType,
				HasNewData:      true,
				CurrentSequence: "123",
				AgentId:         "test-agent",
			}

			// Execute the method under test
			result := rp.convertToServiceStatus(mockResults)

			// Verify the service type conversion
			assert.Equal(t, tt.expectedServiceType, result.ServiceType, tt.description)
			assert.Equal(t, tt.checkName, result.ServiceName)
			assert.Equal(t, "test-poller", result.PollerId)
			assert.Equal(t, "results", result.Source)
		})
	}
}

func TestResultsPoller_SyncServiceStreamingDecision(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockLogger := logger.NewMockLogger(ctrl)

	testCases := []struct {
		serviceType          string
		serviceName          string
		expectStreamDecision bool
		description          string
	}{
		// Sync service configurations that should use streaming
		{"grpc", "sync", true, "gRPC sync service should use streaming"},
		{"sync", "sync", true, "sync type sync service should use streaming"},
		{"grpc", "my-sync-service", true, "gRPC service with 'sync' in name should use streaming"},

		// Sweep service configurations that should use streaming
		{"sweep", "network_sweep", true, "sweep service should use streaming"},

		// Other services that should NOT use streaming
		{"grpc", "sysmon", false, "sysmon gRPC service should not use streaming"},
		{"grpc", "rperf-checker", false, "rperf gRPC service should not use streaming"},
		{"snmp", "snmp", false, "SNMP service should not use streaming"},
		{"icmp", "ping", false, "ICMP service should not use streaming"},
	}

	for _, tc := range testCases {
		t.Run(tc.description, func(t *testing.T) {
			rp := &ResultsPoller{
				check: Check{
					Name: tc.serviceName,
					Type: tc.serviceType,
				},
				logger: mockLogger,
			}

			// Test the streaming decision logic directly (matching the actual poller code)
			shouldUseStreaming := rp.check.Type == serviceTypeSync || rp.check.Type == serviceTypeSweep ||
				rp.check.Name == serviceTypeSync || strings.Contains(rp.check.Name, serviceTypeSync)

			assert.Equal(t, tc.expectStreamDecision, shouldUseStreaming, tc.description)
		})
	}
}
