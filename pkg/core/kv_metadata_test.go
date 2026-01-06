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
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"go.opentelemetry.io/otel"
)

// Test constants
const (
	testPartition = "test-partition"
	testSourceIP  = "192.168.1.100"
)

func TestExtractSafeKVMetadata(t *testing.T) {
	tests := []struct {
		name     string
		svc      *proto.GatewayServiceStatus
		expected map[string]string
	}{
		{
			name: "service with KV store ID",
			svc: &proto.GatewayServiceStatus{
				ServiceName: "test-service",
				ServiceType: "grpc",
				KvStoreId:   "kv-store-123",
				Available:   true,
			},
			expected: map[string]string{
				"service_type":  "grpc",
				"kv_store_id":   "kv-store-123",
				"kv_enabled":    "true",
				"kv_configured": "true",
			},
		},
		{
			name: "service without KV store ID",
			svc: &proto.GatewayServiceStatus{
				ServiceName: "legacy-service",
				ServiceType: "http",
				KvStoreId:   "",
				Available:   false,
			},
			expected: map[string]string{
				"service_type":  "http",
				"kv_enabled":    "false",
				"kv_configured": "false",
			},
		},
		{
			name: "service with empty KV store ID",
			svc: &proto.GatewayServiceStatus{
				ServiceName: "empty-kv-service",
				ServiceType: "tcp",
				Available:   true,
			},
			expected: map[string]string{
				"service_type":  "tcp",
				"kv_enabled":    "false",
				"kv_configured": "false",
			},
		},
	}

	server := &Server{
		logger: logger.NewTestLogger(),
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := server.extractSafeKVMetadata(tt.svc)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestCreateServiceRecords_WithKVMetadata(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	server := &Server{
		DB:     mockDB,
		logger: logger.NewTestLogger(),
		tracer: otel.Tracer("serviceradar-core-test"),
	}

	now := time.Now()
	gatewayID := "test-gateway"
	partition := testPartition
	sourceIP := testSourceIP

	// Mock device lookup calls
	mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).Return([]map[string]interface{}{}, nil).AnyTimes()
	mockDB.EXPECT().GetDeviceByID(gomock.Any(), gomock.Any()).Return(nil, nil).AnyTimes()

	ctx := context.Background()

	// Test KV-enabled service
	protoSvc := &proto.GatewayServiceStatus{
		ServiceName: "kv-enabled-service",
		ServiceType: "grpc",
		AgentId:     "agent-1",
		GatewayId:   gatewayID,
		KvStoreId:   "kv-store-abc",
		Available:   true,
		Message:     []byte(`{"status": "ok"}`),
	}

	apiSvc := &api.ServiceStatus{
		Name:      protoSvc.ServiceName,
		Type:      protoSvc.ServiceType,
		AgentID:   protoSvc.AgentId,
		Available: protoSvc.Available,
		Message:   protoSvc.Message,
	}

	serviceStatus, serviceRecord := server.createServiceRecords(ctx, protoSvc, apiSvc, gatewayID, partition, sourceIP, now)

	// Verify service status record
	assert.Equal(t, "kv-enabled-service", serviceStatus.ServiceName)
	assert.Equal(t, "grpc", serviceStatus.ServiceType)
	assert.Equal(t, gatewayID, serviceStatus.GatewayID)
	assert.Equal(t, "agent-1", serviceStatus.AgentID)
	assert.Equal(t, partition, serviceStatus.Partition)

	// Verify service record with KV metadata
	assert.Equal(t, "kv-enabled-service", serviceRecord.ServiceName)
	assert.Equal(t, "grpc", serviceRecord.ServiceType)

	// Verify KV metadata in config
	require.NotNil(t, serviceRecord.Config)
	assert.Equal(t, "grpc", serviceRecord.Config["service_type"])
	assert.Equal(t, "kv-store-abc", serviceRecord.Config["kv_store_id"])
	assert.Equal(t, "true", serviceRecord.Config["kv_enabled"])
	assert.Equal(t, "true", serviceRecord.Config["kv_configured"])

	// Test legacy service without KV
	legacyProto := &proto.GatewayServiceStatus{
		ServiceName: "legacy-service",
		ServiceType: "http",
		AgentId:     "agent-2",
		GatewayId:   gatewayID,
		KvStoreId:   "", // No KV store
		Available:   false,
		Message:     []byte(`{"error": "service down"}`),
	}

	legacyAPI := &api.ServiceStatus{
		Name:      legacyProto.ServiceName,
		Type:      legacyProto.ServiceType,
		AgentID:   legacyProto.AgentId,
		Available: legacyProto.Available,
		Message:   legacyProto.Message,
	}

	_, legacyRecord := server.createServiceRecords(ctx, legacyProto, legacyAPI, gatewayID, partition, sourceIP, now)

	// Verify legacy service has no KV metadata
	require.NotNil(t, legacyRecord.Config)
	assert.Equal(t, "http", legacyRecord.Config["service_type"])
	assert.Equal(t, "false", legacyRecord.Config["kv_enabled"])
	assert.Equal(t, "false", legacyRecord.Config["kv_configured"])
	_, hasKvStoreId := legacyRecord.Config["kv_store_id"]
	assert.False(t, hasKvStoreId) // Should not be present when empty
}

func TestPushStatus_WithKVStoreId(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	server := &Server{
		DB:                   mockDB,
		config:               &models.CoreServiceConfig{KnownGateways: []string{"test-gateway"}},
		serviceBuffers:       make(map[string][]*models.ServiceStatus),
		serviceListBuffers:   make(map[string][]*models.Service),
		gatewayStatusCache:   make(map[string]*models.GatewayStatus),
		gatewayStatusUpdates: make(map[string]*models.GatewayStatus),
		logger:               logger.NewTestLogger(),
		tracer:               otel.Tracer("serviceradar-core-test"),
	}

	// Mock gateway status
	mockDB.EXPECT().GetGatewayStatus(gomock.Any(), "test-gateway").Return(&models.GatewayStatus{
		GatewayID: "test-gateway",
		IsHealthy: true,
		FirstSeen: time.Now().Add(-1 * time.Hour),
		LastSeen:  time.Now(),
	}, nil).AnyTimes()

	mockDB.EXPECT().UpdateGatewayStatus(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()

	// Mock device lookup
	mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).Return([]map[string]interface{}{}, nil).AnyTimes()
	mockDB.EXPECT().GetDeviceByID(gomock.Any(), gomock.Any()).Return(nil, nil).AnyTimes()

	// Mock UpsertOCSFAgent for agent registration
	mockDB.EXPECT().UpsertOCSFAgent(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()

	// Expect service status updates
	mockDB.EXPECT().UpdateServiceStatuses(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, statuses []*models.ServiceStatus) error {
		require.Len(t, statuses, 1)
		status := statuses[0]

		assert.Equal(t, "kv-service", status.ServiceName)
		assert.Equal(t, "test-gateway", status.GatewayID)
		assert.Equal(t, "agent-kv", status.AgentID)

		return nil
	}).AnyTimes()

	// Expect service records storage with KV metadata
	mockDB.EXPECT().StoreServices(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, services []*models.Service) error {
		require.Len(t, services, 1)
		service := services[0]

		assert.Equal(t, "kv-service", service.ServiceName)
		assert.Equal(t, "grpc", service.ServiceType)

		// Verify KV metadata is present
		require.NotNil(t, service.Config)
		assert.Equal(t, "grpc", service.Config["service_type"])
		assert.Equal(t, "kv-store-xyz", service.Config["kv_store_id"])
		assert.Equal(t, "true", service.Config["kv_enabled"])
		assert.Equal(t, "true", service.Config["kv_configured"])

		return nil
	}).AnyTimes()

	ctx := context.Background()

	// Test request with KV store ID
	req := &proto.GatewayStatusRequest{
		GatewayId: "test-gateway",
		Timestamp: time.Now().Unix(),
		Partition: testPartition,
		SourceIp:  testSourceIP,
		Services: []*proto.GatewayServiceStatus{
			{
				ServiceName: "kv-service",
				ServiceType: "grpc",
				Available:   true,
				AgentId:     "agent-kv",
				GatewayId:   "test-gateway",
				KvStoreId:   "kv-store-xyz", // This should be captured in metadata
			},
		},
	}

	resp, err := server.PushStatus(ctx, req)
	require.NoError(t, err)
	assert.NotNil(t, resp)
	assert.True(t, resp.Received)

	// Trigger flush to store buffered data
	server.flushAllBuffers(ctx)
}

func TestKVMetadataIntegration(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	server := &Server{
		DB:                 mockDB,
		serviceListBuffers: make(map[string][]*models.Service),
		logger:             logger.NewTestLogger(),
		tracer:             otel.Tracer("serviceradar-core-test"),
	}

	// Mock device lookup
	mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).Return([]map[string]interface{}{}, nil).AnyTimes()
	mockDB.EXPECT().GetDeviceByID(gomock.Any(), gomock.Any()).Return(nil, nil).AnyTimes()

	now := time.Now()
	gatewayID := "integration-gateway"
	partition := "integration-partition"
	sourceIP := testSourceIP

	ctx := context.Background()

	// Mix of services with and without KV store IDs
	testCases := []struct {
		name            string
		protoService    *proto.GatewayServiceStatus
		expectedKVID    string
		expectedEnabled string
	}{
		{
			name: "auth-service",
			protoService: &proto.GatewayServiceStatus{
				ServiceName: "auth-service",
				ServiceType: "grpc",
				AgentId:     "auth-agent",
				GatewayId:   gatewayID,
				KvStoreId:   "auth-kv-store",
				Available:   true,
				Message:     []byte(`{"status": "healthy"}`),
			},
			expectedKVID:    "auth-kv-store",
			expectedEnabled: "true",
		},
		{
			name: "legacy-web",
			protoService: &proto.GatewayServiceStatus{
				ServiceName: "legacy-web",
				ServiceType: "http",
				AgentId:     "web-agent",
				GatewayId:   gatewayID,
				KvStoreId:   "",
				Available:   true,
				Message:     []byte(`{"status": "ok"}`),
			},
			expectedKVID:    "",
			expectedEnabled: "false",
		},
		{
			name: "config-service",
			protoService: &proto.GatewayServiceStatus{
				ServiceName: "config-service",
				ServiceType: "grpc",
				AgentId:     "config-agent",
				GatewayId:   gatewayID,
				KvStoreId:   "config-kv-store",
				Available:   false,
				Message:     []byte(`{"error": "connection failed"}`),
			},
			expectedKVID:    "config-kv-store",
			expectedEnabled: "true",
		},
	}

	// Process each service and verify KV metadata
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			apiSvc := &api.ServiceStatus{
				Name:      tc.protoService.ServiceName,
				Type:      tc.protoService.ServiceType,
				AgentID:   tc.protoService.AgentId,
				Available: tc.protoService.Available,
				Message:   tc.protoService.Message,
			}

			_, serviceRecord := server.createServiceRecords(ctx, tc.protoService, apiSvc, gatewayID, partition, sourceIP, now)

			// Verify service record metadata
			require.NotNil(t, serviceRecord.Config)
			assert.Equal(t, tc.protoService.ServiceType, serviceRecord.Config["service_type"])
			assert.Equal(t, tc.expectedEnabled, serviceRecord.Config["kv_enabled"])
			assert.Equal(t, tc.expectedEnabled, serviceRecord.Config["kv_configured"])

			if tc.expectedKVID != "" {
				assert.Equal(t, tc.expectedKVID, serviceRecord.Config["kv_store_id"])
			} else {
				// kv_store_id should not be present when empty
				_, hasKvStoreId := serviceRecord.Config["kv_store_id"]
				assert.False(t, hasKvStoreId)
			}
		})
	}
}
