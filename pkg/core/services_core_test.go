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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestGetCoreServiceType(t *testing.T) {
	tests := []struct {
		name        string
		serviceType string
		expected    models.ServiceType
	}{
		{
			name:        "datasvc service type",
			serviceType: "datasvc",
			expected:    models.ServiceTypeDatasvc,
		},
		{
			name:        "kv service type",
			serviceType: "kv",
			expected:    models.ServiceTypeKV,
		},
		{
			name:        "sync service type",
			serviceType: "sync",
			expected:    models.ServiceTypeSync,
		},
		{
			name:        "mapper service type",
			serviceType: "mapper",
			expected:    models.ServiceTypeMapper,
		},
		{
			name:        "otel service type",
			serviceType: "otel",
			expected:    models.ServiceTypeOtel,
		},
		{
			name:        "zen service type",
			serviceType: "zen",
			expected:    models.ServiceTypeZen,
		},
		{
			name:        "core service type",
			serviceType: "core",
			expected:    models.ServiceTypeCore,
		},
		{
			name:        "grpc is not a core service",
			serviceType: "grpc",
			expected:    "",
		},
		{
			name:        "snmp is not a core service",
			serviceType: "snmp",
			expected:    "",
		},
		{
			name:        "sysmon is not a core service",
			serviceType: "sysmon",
			expected:    "",
		},
		{
			name:        "empty string is not a core service",
			serviceType: "",
			expected:    "",
		},
		{
			name:        "random string is not a core service",
			serviceType: "random-service",
			expected:    "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := getCoreServiceType(tt.serviceType)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestFindCoreServiceType(t *testing.T) {
	tests := []struct {
		name              string
		services          []*proto.GatewayServiceStatus
		expectedType      models.ServiceType
		expectedServiceID string
	}{
		{
			name: "finds datasvc in services list",
			services: []*proto.GatewayServiceStatus{
				{ServiceName: "datasvc-primary", ServiceType: "datasvc"},
			},
			expectedType:      models.ServiceTypeDatasvc,
			expectedServiceID: "datasvc-primary",
		},
		{
			name: "finds sync in services list",
			services: []*proto.GatewayServiceStatus{
				{ServiceName: "sync-01", ServiceType: "sync"},
			},
			expectedType:      models.ServiceTypeSync,
			expectedServiceID: "sync-01",
		},
		{
			name: "finds core service among multiple services",
			services: []*proto.GatewayServiceStatus{
				{ServiceName: "sysmon-checker", ServiceType: "grpc"},
				{ServiceName: "otel-collector", ServiceType: "otel"},
				{ServiceName: "snmp-gateway", ServiceType: "snmp"},
			},
			expectedType:      models.ServiceTypeOtel,
			expectedServiceID: "otel-collector",
		},
		{
			name: "returns first core service when multiple present",
			services: []*proto.GatewayServiceStatus{
				{ServiceName: "datasvc-01", ServiceType: "datasvc"},
				{ServiceName: "sync-01", ServiceType: "sync"},
			},
			expectedType:      models.ServiceTypeDatasvc,
			expectedServiceID: "datasvc-01",
		},
		{
			name: "returns empty for non-core services",
			services: []*proto.GatewayServiceStatus{
				{ServiceName: "sysmon-checker", ServiceType: "grpc"},
				{ServiceName: "snmp-gateway", ServiceType: "snmp"},
			},
			expectedType:      "",
			expectedServiceID: "",
		},
		{
			name:              "returns empty for empty services list",
			services:          []*proto.GatewayServiceStatus{},
			expectedType:      "",
			expectedServiceID: "",
		},
		{
			name:              "returns empty for nil services list",
			services:          nil,
			expectedType:      "",
			expectedServiceID: "",
		},
		{
			name: "handles nil service in list",
			services: []*proto.GatewayServiceStatus{
				nil,
				{ServiceName: "mapper-01", ServiceType: "mapper"},
			},
			expectedType:      models.ServiceTypeMapper,
			expectedServiceID: "mapper-01",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			serviceType, serviceID := findCoreServiceType(tt.services)
			assert.Equal(t, tt.expectedType, serviceType)
			assert.Equal(t, tt.expectedServiceID, serviceID)
		})
	}
}

func TestRegisterCoreServiceDevice(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	now := time.Now()

	// Expect device update to be processed
	mockRegistry.EXPECT().
		ProcessDeviceUpdate(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, update *models.DeviceUpdate) error {
			// Verify the device update has correct format
			require.Equal(t, "serviceradar:datasvc:datasvc-primary", update.DeviceID)
			require.Equal(t, "10.0.0.10", update.IP)
			require.Equal(t, "core", update.Partition)
			require.Equal(t, models.DiscoverySourceServiceRadar, update.Source)
			require.NotNil(t, update.ServiceType)
			require.Equal(t, models.ServiceTypeDatasvc, *update.ServiceType)
			require.Equal(t, "datasvc-primary", update.ServiceID)
			return nil
		})

	err := server.registerCoreServiceDevice(
		context.Background(),
		models.ServiceTypeDatasvc,
		"datasvc-primary",
		"core",
		"10.0.0.10",
		now,
	)

	require.NoError(t, err)
}

func TestRegisterCoreServiceDevice_MissingPartition(t *testing.T) {
	server := &Server{
		logger: logger.NewTestLogger(),
	}

	err := server.registerCoreServiceDevice(
		context.Background(),
		models.ServiceTypeDatasvc,
		"datasvc-primary",
		"", // empty partition
		"10.0.0.10",
		time.Now(),
	)

	require.Error(t, err)
	assert.ErrorIs(t, err, ErrMissingLocationData)
}

func TestRegisterCoreServiceDevice_MissingIP(t *testing.T) {
	server := &Server{
		logger: logger.NewTestLogger(),
	}

	err := server.registerCoreServiceDevice(
		context.Background(),
		models.ServiceTypeDatasvc,
		"datasvc-primary",
		"core",
		"", // empty IP
		time.Now(),
	)

	require.Error(t, err)
	assert.ErrorIs(t, err, ErrMissingLocationData)
}

func TestRegisterServiceOrCoreDevice_CoreService(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	now := time.Now()

	// Expect core service device registration
	mockRegistry.EXPECT().
		ProcessDeviceUpdate(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, update *models.DeviceUpdate) error {
			// Verify it's a service device ID, not partition:IP
			require.Equal(t, "serviceradar:datasvc:datasvc-primary", update.DeviceID)
			return nil
		})

	services := []*proto.GatewayServiceStatus{
		{ServiceName: "datasvc-primary", ServiceType: "datasvc"},
	}

	server.registerServiceOrCoreDevice(
		context.Background(),
		"datasvc-primary", // gatewayID
		"core",            // partition
		"172.18.0.5",      // Docker IP - should still work for core service
		services,
		now,
	)
}

func TestRegisterServiceOrCoreDevice_RegularGateway(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	now := time.Now()

	// Expect regular gateway device registration (partition:IP format)
	mockRegistry.EXPECT().
		ProcessDeviceUpdate(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, update *models.DeviceUpdate) error {
			// Verify it's partition:IP format, not a service device ID
			require.Equal(t, "edge:192.168.1.100", update.DeviceID)
			return nil
		})

	services := []*proto.GatewayServiceStatus{
		{ServiceName: "sysmon-checker", ServiceType: "grpc"},
		{ServiceName: "snmp-gateway", ServiceType: "snmp"},
	}

	server.registerServiceOrCoreDevice(
		context.Background(),
		"edge-gateway-01", // gatewayID
		"edge",            // partition
		"192.168.1.100",   // regular IP
		services,
		now,
	)
}

func TestRegisterServiceOrCoreDevice_SkipsEmptyPartition(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	// No expectations - should not call ProcessDeviceUpdate

	services := []*proto.GatewayServiceStatus{
		{ServiceName: "datasvc-primary", ServiceType: "datasvc"},
	}

	server.registerServiceOrCoreDevice(
		context.Background(),
		"datasvc-primary",
		"", // empty partition - should skip
		"10.0.0.10",
		services,
		time.Now(),
	)
}

func TestRegisterServiceOrCoreDevice_SkipsEmptyIP(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	// No expectations - should not call ProcessDeviceUpdate

	services := []*proto.GatewayServiceStatus{
		{ServiceName: "datasvc-primary", ServiceType: "datasvc"},
	}

	server.registerServiceOrCoreDevice(
		context.Background(),
		"datasvc-primary",
		"core",
		"", // empty IP - should skip
		services,
		time.Now(),
	)
}

func TestCoreServiceDeviceIDFormat(t *testing.T) {
	// Verify that core services get the expected device ID format
	tests := []struct {
		serviceType models.ServiceType
		serviceID   string
		expectedID  string
	}{
		{models.ServiceTypeDatasvc, "datasvc-01", "serviceradar:datasvc:datasvc-01"},
		{models.ServiceTypeKV, "kv-primary", "serviceradar:kv:kv-primary"},
		{models.ServiceTypeSync, "sync-service", "serviceradar:sync:sync-service"},
		{models.ServiceTypeMapper, "mapper-01", "serviceradar:mapper:mapper-01"},
		{models.ServiceTypeOtel, "otel-collector", "serviceradar:otel:otel-collector"},
		{models.ServiceTypeZen, "zen-primary", "serviceradar:zen:zen-primary"},
		{models.ServiceTypeCore, "core-main", "serviceradar:core:core-main"},
	}

	for _, tt := range tests {
		t.Run(string(tt.serviceType), func(t *testing.T) {
			deviceID := models.GenerateServiceDeviceID(tt.serviceType, tt.serviceID)
			assert.Equal(t, tt.expectedID, deviceID)
		})
	}
}
