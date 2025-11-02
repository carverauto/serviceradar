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

package registry

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestServiceDeviceRegistration_PollerDeviceUpdate(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	// Track published updates
	var publishedUpdates []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			publishedUpdates = append(publishedUpdates, updates...)
			return nil
		}).
		AnyTimes()

	pollerUpdate := models.CreatePollerDeviceUpdate("k8s-poller", "", nil)

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{pollerUpdate})
	require.NoError(t, err)

	require.Len(t, publishedUpdates, 1)
	result := publishedUpdates[0]

	assert.Equal(t, "serviceradar:poller:k8s-poller", result.DeviceID)
	assert.Equal(t, models.ServiceTypePoller, *result.ServiceType)
	assert.Equal(t, "k8s-poller", result.ServiceID)
	assert.Equal(t, models.ServiceDevicePartition, result.Partition)
	assert.Equal(t, models.DiscoverySourceServiceRadar, result.Source)
	assert.True(t, result.IsAvailable)
	assert.Equal(t, "poller", result.Metadata["component_type"])
	assert.Equal(t, "k8s-poller", result.Metadata["poller_id"])
}

func TestServiceDeviceRegistration_AgentDeviceUpdate(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	var publishedUpdates []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			publishedUpdates = append(publishedUpdates, updates...)
			return nil
		}).
		AnyTimes()

	agentUpdate := models.CreateAgentDeviceUpdate("agent-123", "k8s-poller", "", nil)

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{agentUpdate})
	require.NoError(t, err)

	require.Len(t, publishedUpdates, 1)
	result := publishedUpdates[0]

	assert.Equal(t, "serviceradar:agent:agent-123", result.DeviceID)
	assert.Equal(t, models.ServiceTypeAgent, *result.ServiceType)
	assert.Equal(t, "agent-123", result.ServiceID)
	assert.Equal(t, "agent-123", result.AgentID)
	assert.Equal(t, "k8s-poller", result.PollerID)
	assert.Equal(t, models.ServiceDevicePartition, result.Partition)
	assert.Equal(t, models.DiscoverySourceServiceRadar, result.Source)
	assert.True(t, result.IsAvailable)
	assert.Equal(t, "agent", result.Metadata["component_type"])
	assert.Equal(t, "agent-123", result.Metadata["agent_id"])
	assert.Equal(t, "k8s-poller", result.Metadata["poller_id"])
}

func TestServiceDeviceRegistration_CheckerDeviceUpdate(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	var publishedUpdates []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			publishedUpdates = append(publishedUpdates, updates...)
			return nil
		}).
		AnyTimes()

	checkerUpdate := models.CreateCheckerDeviceUpdate("sysmon@agent-123", "sysmon", "agent-123", "k8s-poller", "", nil)

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{checkerUpdate})
	require.NoError(t, err)

	require.Len(t, publishedUpdates, 1)
	result := publishedUpdates[0]

	assert.Equal(t, "serviceradar:checker:sysmon@agent-123", result.DeviceID)
	assert.Equal(t, models.ServiceTypeChecker, *result.ServiceType)
	assert.Equal(t, "sysmon@agent-123", result.ServiceID)
	assert.Equal(t, "agent-123", result.AgentID)
	assert.Equal(t, "k8s-poller", result.PollerID)
	assert.Equal(t, models.ServiceDevicePartition, result.Partition)
	assert.Equal(t, models.DiscoverySourceServiceRadar, result.Source)
	assert.True(t, result.IsAvailable)
	assert.Equal(t, "checker", result.Metadata["component_type"])
	assert.Equal(t, "sysmon@agent-123", result.Metadata["checker_id"])
	assert.Equal(t, "sysmon", result.Metadata["checker_kind"])
	assert.Equal(t, "agent-123", result.Metadata["agent_id"])
	assert.Equal(t, "k8s-poller", result.Metadata["poller_id"])
}

func TestServiceDeviceRegistration_MultipleServicesOnSameIP(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	var publishedUpdates []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			publishedUpdates = append(publishedUpdates, updates...)
			return nil
		}).
		AnyTimes()

	// Create multiple services all running on the same IP
	hostIP := "192.168.1.100"
	updates := []*models.DeviceUpdate{
		models.CreatePollerDeviceUpdate("poller-1", hostIP, nil),
		models.CreateAgentDeviceUpdate("agent-1", "poller-1", hostIP, nil),
		models.CreateCheckerDeviceUpdate("sysmon@agent-1", "sysmon", "agent-1", "poller-1", hostIP, nil),
		models.CreateCheckerDeviceUpdate("rperf@agent-1", "rperf", "agent-1", "poller-1", hostIP, nil),
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, updates)
	require.NoError(t, err)

	require.Len(t, publishedUpdates, 4, "All 4 services should be published as distinct devices")

	// Verify all have the same IP but different device IDs
	deviceIDs := make(map[string]bool)
	for _, update := range publishedUpdates {
		assert.Equal(t, hostIP, update.IP, "All should have the same IP")
		assert.False(t, deviceIDs[update.DeviceID], "Device ID should be unique: %s", update.DeviceID)
		deviceIDs[update.DeviceID] = true
		assert.True(t, models.IsServiceDevice(update.DeviceID), "Should be recognized as service device: %s", update.DeviceID)
	}

	// Verify expected device IDs
	expectedDeviceIDs := map[string]bool{
		"serviceradar:poller:poller-1":         false,
		"serviceradar:agent:agent-1":           false,
		"serviceradar:checker:sysmon@agent-1":  false,
		"serviceradar:checker:rperf@agent-1":   false,
	}

	for _, update := range publishedUpdates {
		_, exists := expectedDeviceIDs[update.DeviceID]
		assert.True(t, exists, "Unexpected device ID: %s", update.DeviceID)
		expectedDeviceIDs[update.DeviceID] = true
	}

	// All expected device IDs should have been seen
	for deviceID, seen := range expectedDeviceIDs {
		assert.True(t, seen, "Expected device ID not found: %s", deviceID)
	}
}

func TestServiceDeviceRegistration_EmptyIPAllowed(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	var publishedUpdates []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			publishedUpdates = append(publishedUpdates, updates...)
			return nil
		}).
		AnyTimes()

	// Service devices with empty IPs should be allowed
	pollerUpdate := models.CreatePollerDeviceUpdate("k8s-poller", "", nil)

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{pollerUpdate})
	require.NoError(t, err)

	require.Len(t, publishedUpdates, 1, "Service device with empty IP should be published")
	assert.Equal(t, "", publishedUpdates[0].IP)
	assert.Equal(t, "serviceradar:poller:k8s-poller", publishedUpdates[0].DeviceID)
}

func TestServiceDeviceRegistration_NetworkDeviceEmptyIPDropped(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	var publishedUpdates []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			publishedUpdates = append(publishedUpdates, updates...)
			return nil
		}).
		AnyTimes()

	// Network device without IP should be dropped
	networkUpdate := &models.DeviceUpdate{
		IP:          "",
		DeviceID:    "default:",
		Partition:   "default",
		Source:      models.DiscoverySourceMapper,
		Timestamp:   time.Now(),
		IsAvailable: true,
		Metadata:    map[string]string{},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{networkUpdate})
	require.NoError(t, err)

	assert.Len(t, publishedUpdates, 0, "Network device with empty IP should be dropped")
}

func TestServiceDeviceRegistration_DeviceIDGeneration(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	var publishedUpdates []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			publishedUpdates = append(publishedUpdates, updates...)
			return nil
		}).
		AnyTimes()

	tests := []struct {
		name            string
		update          *models.DeviceUpdate
		expectedDeviceID string
	}{
		{
			name: "Service device with empty DeviceID gets generated",
			update: &models.DeviceUpdate{
				ServiceType: func() *models.ServiceType { st := models.ServiceTypePoller; return &st }(),
				ServiceID:   "test-poller",
				IP:          "192.168.1.100",
				Source:      models.DiscoverySourceServiceRadar,
				Timestamp:   time.Now(),
				IsAvailable: true,
				Metadata:    map[string]string{},
			},
			expectedDeviceID: "serviceradar:poller:test-poller",
		},
		{
			name: "Network device with empty DeviceID gets generated",
			update: &models.DeviceUpdate{
				IP:          "10.0.0.1",
				Partition:   "network",
				Source:      models.DiscoverySourceMapper,
				Timestamp:   time.Now(),
				IsAvailable: true,
				Metadata:    map[string]string{},
			},
			expectedDeviceID: "network:10.0.0.1",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			publishedUpdates = nil // Reset

			err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{tt.update})
			require.NoError(t, err)

			require.Len(t, publishedUpdates, 1)
			assert.Equal(t, tt.expectedDeviceID, publishedUpdates[0].DeviceID)
		})
	}
}

func TestServiceDeviceRegistration_HighCardinalityCheckers(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	var publishedUpdates []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			publishedUpdates = append(publishedUpdates, updates...)
			return nil
		}).
		AnyTimes()

	// Create 100 checker instances for a single agent
	agentID := "agent-123"
	pollerID := "poller-1"
	hostIP := "192.168.1.100"
	updates := make([]*models.DeviceUpdate, 0, 100)

	checkerTypes := []string{"sysmon", "rperf", "snmp", "mapper"}
	checkerIndex := 0
	for i := 0; i < 25; i++ {
		for _, checkerType := range checkerTypes {
			checkerID := fmt.Sprintf("%s-%d@%s", checkerType, checkerIndex, agentID)
			updates = append(updates, models.CreateCheckerDeviceUpdate(checkerID, checkerType, agentID, pollerID, hostIP, nil))
			checkerIndex++
		}
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, updates)
	require.NoError(t, err)

	require.Len(t, publishedUpdates, 100, "All 100 checkers should be published")

	// Verify all have unique device IDs
	deviceIDs := make(map[string]bool)
	for _, update := range publishedUpdates {
		assert.False(t, deviceIDs[update.DeviceID], "Device ID should be unique: %s", update.DeviceID)
		deviceIDs[update.DeviceID] = true
		assert.Equal(t, hostIP, update.IP, "All should have the same IP")
		assert.True(t, models.IsServiceDevice(update.DeviceID))
	}
}

func TestServiceDeviceRegistration_MixedBatch(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	var publishedUpdates []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			publishedUpdates = append(publishedUpdates, updates...)
			return nil
		}).
		AnyTimes()

	// Create a batch with both service devices and network devices
	updates := []*models.DeviceUpdate{
		// Service devices
		models.CreatePollerDeviceUpdate("poller-1", "", nil),
		models.CreateAgentDeviceUpdate("agent-1", "poller-1", "192.168.1.100", nil),
		// Network devices
		{
			IP:          "192.168.1.10",
			DeviceID:    "network:192.168.1.10",
			Partition:   "network",
			Source:      models.DiscoverySourceMapper,
			Timestamp:   time.Now(),
			IsAvailable: true,
			Metadata:    map[string]string{"type": "router"},
		},
		{
			IP:          "192.168.1.11",
			DeviceID:    "network:192.168.1.11",
			Partition:   "network",
			Source:      models.DiscoverySourceSNMP,
			Timestamp:   time.Now(),
			IsAvailable: true,
			Metadata:    map[string]string{"type": "switch"},
		},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, updates)
	require.NoError(t, err)

	require.Len(t, publishedUpdates, 4, "All updates should be published")

	serviceDeviceCount := 0
	networkDeviceCount := 0

	for _, update := range publishedUpdates {
		if models.IsServiceDevice(update.DeviceID) {
			serviceDeviceCount++
			assert.Equal(t, models.ServiceDevicePartition, update.Partition)
			assert.Equal(t, models.DiscoverySourceServiceRadar, update.Source)
		} else {
			networkDeviceCount++
			assert.Equal(t, "network", update.Partition)
		}
	}

	assert.Equal(t, 2, serviceDeviceCount, "Should have 2 service devices")
	assert.Equal(t, 2, networkDeviceCount, "Should have 2 network devices")
}
