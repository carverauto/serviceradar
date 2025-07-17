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

package armis

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestArmisIntegration_Reconcile_WithRetractionEvents(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockTokenProvider := NewMockTokenProvider(ctrl)
	mockDeviceFetcher := NewMockDeviceFetcher(ctrl)
	mockQuerier := NewMockSRQLQuerier(ctrl)
	mockUpdater := NewMockArmisUpdater(ctrl)
	mockSubmitter := NewMockResultSubmitter(ctrl)

	// Test data
	accessToken := "test-token"
	ctx := context.Background()

	// Current devices from Armis API (device 1 is missing, indicating it was deleted)
	currentDevices := []Device{
		{
			ID:         2,
			IPAddress:  "192.168.1.2",
			Name:       "Device 2",
			FirstSeen:  time.Now().Add(-24 * time.Hour),
			LastSeen:   time.Now(),
			MacAddress: "bb:bb:bb:bb:bb:bb",
		},
	}

	// Existing device states from ServiceRadar (includes both devices)
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition:192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "1",
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.2",
			IP:          "192.168.1.2",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "2",
			},
		},
	}

	// Setup the integration
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
			Queries: []models.QueryConfig{
				{Label: "test", Query: "in:devices"},
			},
		},
		PageSize:        100,
		TokenProvider:   mockTokenProvider,
		DeviceFetcher:   mockDeviceFetcher,
		SweepQuerier:    mockQuerier,
		Updater:         mockUpdater,
		ResultSubmitter: mockSubmitter,
	}

	// Setup expectations
	mockTokenProvider.EXPECT().
		GetAccessToken(ctx).
		Return(accessToken, nil)

	mockQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(existingDeviceStates, nil)

	// Mock the device fetching (returns only device 2, device 1 is missing)
	firstPageResp := &SearchResponse{
		Data: struct {
			Count   int         `json:"count"`
			Next    int         `json:"next"`
			Prev    interface{} `json:"prev"`
			Results []Device    `json:"results"`
			Total   int         `json:"total"`
		}{
			Count:   1,
			Next:    0, // No next page
			Results: currentDevices,
			Total:   1,
		},
		Success: true,
	}

	mockDeviceFetcher.EXPECT().
		FetchDevicesPage(ctx, accessToken, "in:devices", 0, 100).
		Return(firstPageResp, nil)

	// Mock the result submitter to capture retraction events
	mockSubmitter.EXPECT().
		SubmitBatchSweepResults(ctx, gomock.Any()).
		DoAndReturn(func(_ context.Context, results []*models.DeviceUpdate) error {
			require.Len(t, results, 1)
			result := results[0]

			// Verify retraction event structure
			assert.Equal(t, "test-partition:192.168.1.1", result.DeviceID)
			assert.Equal(t, models.DiscoverySourceArmis, result.Source)
			assert.Equal(t, "192.168.1.1", result.IP)
			assert.False(t, result.IsAvailable)
			assert.Equal(t, "true", result.Metadata["_deleted"])
			assert.Equal(t, "test-agent", result.AgentID)
			assert.Equal(t, "test-poller", result.PollerID)
			assert.Equal(t, "test-partition", result.Partition)

			return nil
		})

	// Mock the Armis updater (for both devices - device 1 will be marked as unavailable since it's missing)
	mockUpdater.EXPECT().
		UpdateDeviceStatus(ctx, gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []ArmisDeviceStatus) error {
			require.Len(t, updates, 2)
			// Both devices will be in the update list from existing device states
			// We don't need to check specific values since this test is focused on retraction events
			return nil
		})

	// Execute the reconcile operation
	err := integration.Reconcile(ctx)
	require.NoError(t, err)
}

func TestArmisIntegration_Reconcile_NoRetractionEvents(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockTokenProvider := NewMockTokenProvider(ctrl)
	mockDeviceFetcher := NewMockDeviceFetcher(ctrl)
	mockQuerier := NewMockSRQLQuerier(ctrl)
	mockUpdater := NewMockArmisUpdater(ctrl)
	mockSubmitter := NewMockResultSubmitter(ctrl)

	// Test data
	accessToken := "test-token"
	ctx := context.Background()

	// Current devices from Armis API (all devices still present)
	currentDevices := []Device{
		{
			ID:         1,
			IPAddress:  "192.168.1.1",
			Name:       "Device 1",
			FirstSeen:  time.Now().Add(-48 * time.Hour),
			LastSeen:   time.Now(),
			MacAddress: "aa:aa:aa:aa:aa:aa",
		},
		{
			ID:         2,
			IPAddress:  "192.168.1.2",
			Name:       "Device 2",
			FirstSeen:  time.Now().Add(-24 * time.Hour),
			LastSeen:   time.Now(),
			MacAddress: "bb:bb:bb:bb:bb:bb",
		},
	}

	// Existing device states from ServiceRadar (same devices)
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition:192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "1",
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.2",
			IP:          "192.168.1.2",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "2",
			},
		},
	}

	// Setup the integration
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
			Queries: []models.QueryConfig{
				{Label: "test", Query: "in:devices"},
			},
		},
		PageSize:        100,
		TokenProvider:   mockTokenProvider,
		DeviceFetcher:   mockDeviceFetcher,
		SweepQuerier:    mockQuerier,
		Updater:         mockUpdater,
		ResultSubmitter: mockSubmitter,
	}

	// Setup expectations
	mockTokenProvider.EXPECT().
		GetAccessToken(ctx).
		Return(accessToken, nil)

	mockQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(existingDeviceStates, nil)

	// Mock the device fetching (returns both devices)
	firstPageResp := &SearchResponse{
		Data: struct {
			Count   int         `json:"count"`
			Next    int         `json:"next"`
			Prev    interface{} `json:"prev"`
			Results []Device    `json:"results"`
			Total   int         `json:"total"`
		}{
			Count:   2,
			Next:    0, // No next page
			Results: currentDevices,
			Total:   2,
		},
		Success: true,
	}

	mockDeviceFetcher.EXPECT().
		FetchDevicesPage(ctx, accessToken, "in:devices", 0, 100).
		Return(firstPageResp, nil)

	// No retraction events should be submitted (no missing devices)
	// ResultSubmitter should not be called

	// Mock the Armis updater (for both devices)
	mockUpdater.EXPECT().
		UpdateDeviceStatus(ctx, gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []ArmisDeviceStatus) error {
			require.Len(t, updates, 2)
			return nil
		})

	// Execute the reconcile operation
	err := integration.Reconcile(ctx)
	require.NoError(t, err)
}

func TestArmisIntegration_Reconcile_ResultSubmitterError(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockTokenProvider := NewMockTokenProvider(ctrl)
	mockDeviceFetcher := NewMockDeviceFetcher(ctrl)
	mockQuerier := NewMockSRQLQuerier(ctrl)
	mockSubmitter := NewMockResultSubmitter(ctrl)

	// Test data
	accessToken := "test-token"
	ctx := context.Background()

	// Current devices from Armis API (device 1 is missing)
	currentDevices := []Device{
		{
			ID:         2,
			IPAddress:  "192.168.1.2",
			Name:       "Device 2",
			FirstSeen:  time.Now().Add(-24 * time.Hour),
			LastSeen:   time.Now(),
			MacAddress: "bb:bb:bb:bb:bb:bb",
		},
	}

	// Existing device states from ServiceRadar (includes both devices)
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition:192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "1",
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.2",
			IP:          "192.168.1.2",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "2",
			},
		},
	}

	// Create additional mock for updater
	mockUpdater := NewMockArmisUpdater(ctrl)

	// Setup the integration
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
			Queries: []models.QueryConfig{
				{Label: "test", Query: "in:devices"},
			},
		},
		PageSize:        100,
		TokenProvider:   mockTokenProvider,
		DeviceFetcher:   mockDeviceFetcher,
		SweepQuerier:    mockQuerier,
		Updater:         mockUpdater,
		ResultSubmitter: mockSubmitter,
	}

	// Setup expectations
	mockTokenProvider.EXPECT().
		GetAccessToken(ctx).
		Return(accessToken, nil)

	mockQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(existingDeviceStates, nil)

	// Mock the device fetching (returns only device 2)
	firstPageResp := &SearchResponse{
		Data: struct {
			Count   int         `json:"count"`
			Next    int         `json:"next"`
			Prev    interface{} `json:"prev"`
			Results []Device    `json:"results"`
			Total   int         `json:"total"`
		}{
			Count:   1,
			Next:    0,
			Results: currentDevices,
			Total:   1,
		},
		Success: true,
	}

	mockDeviceFetcher.EXPECT().
		FetchDevicesPage(ctx, accessToken, "in:devices", 0, 100).
		Return(firstPageResp, nil)

	// Mock the result submitter to return an error
	expectedError := assert.AnError
	mockSubmitter.EXPECT().
		SubmitBatchSweepResults(ctx, gomock.Any()).
		Return(expectedError)

	// The error should be returned before updater is called
	// But if updater is called, we need to mock it
	mockUpdater.EXPECT().
		UpdateDeviceStatus(ctx, gomock.Any()).
		Return(nil).
		MaxTimes(1)

	// Execute the reconcile operation - should return error
	err := integration.Reconcile(ctx)
	require.Error(t, err)
	assert.Equal(t, expectedError, err)
}

func TestArmisIntegration_Reconcile_NoResultSubmitter(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockTokenProvider := NewMockTokenProvider(ctrl)
	mockDeviceFetcher := NewMockDeviceFetcher(ctrl)
	mockQuerier := NewMockSRQLQuerier(ctrl)
	mockUpdater := NewMockArmisUpdater(ctrl)

	// Test data
	accessToken := "test-token"
	ctx := context.Background()

	// Current devices from Armis API (device 1 is missing)
	currentDevices := []Device{
		{
			ID:         2,
			IPAddress:  "192.168.1.2",
			Name:       "Device 2",
			FirstSeen:  time.Now().Add(-24 * time.Hour),
			LastSeen:   time.Now(),
			MacAddress: "bb:bb:bb:bb:bb:bb",
		},
	}

	// Existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition:192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "1",
			},
		},
	}

	// Setup the integration WITHOUT ResultSubmitter
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
			Queries: []models.QueryConfig{
				{Label: "test", Query: "in:devices"},
			},
		},
		PageSize:        100,
		TokenProvider:   mockTokenProvider,
		DeviceFetcher:   mockDeviceFetcher,
		SweepQuerier:    mockQuerier,
		Updater:         mockUpdater,
		ResultSubmitter: nil, // No result submitter configured
	}

	// Setup expectations
	mockTokenProvider.EXPECT().
		GetAccessToken(ctx).
		Return(accessToken, nil)

	mockQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(existingDeviceStates, nil)

	// Mock the device fetching
	firstPageResp := &SearchResponse{
		Data: struct {
			Count   int         `json:"count"`
			Next    int         `json:"next"`
			Prev    interface{} `json:"prev"`
			Results []Device    `json:"results"`
			Total   int         `json:"total"`
		}{
			Count:   1,
			Next:    0,
			Results: currentDevices,
			Total:   1,
		},
		Success: true,
	}

	mockDeviceFetcher.EXPECT().
		FetchDevicesPage(ctx, accessToken, "in:devices", 0, 100).
		Return(firstPageResp, nil)

	// Mock the Armis updater
	mockUpdater.EXPECT().
		UpdateDeviceStatus(ctx, gomock.Any()).
		Return(nil)

	// Execute the reconcile operation - should succeed but log warning
	err := integration.Reconcile(ctx)
	require.NoError(t, err)
}

func TestArmisIntegration_generateRetractionEvents(t *testing.T) {
	// Setup test data
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
		},
	}

	// Current devices from API
	currentDevices := []Device{
		{ID: 2, IPAddress: "192.168.1.2", Name: "Device 2"},
		{ID: 3, IPAddress: "192.168.1.3", Name: "Device 3"},
	}

	// Existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition:192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "1", // This device is missing from current devices
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.2",
			IP:          "192.168.1.2",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "2", // This device is still present
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.4",
			IP:          "192.168.1.4",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "4", // This device is missing from current devices
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.5",
			IP:          "192.168.1.5",
			IsAvailable: true,
			Metadata:    map[string]interface{}{
				// Missing armis_device_id - should be skipped
			},
		},
	}

	// Execute
	retractionEvents := integration.generateRetractionEvents(currentDevices, existingDeviceStates)

	// Verify
	require.Len(t, retractionEvents, 2) // Only devices 1 and 4 should be retracted

	// Check first retraction event
	event1 := retractionEvents[0]
	assert.Equal(t, "test-partition:192.168.1.1", event1.DeviceID)
	assert.Equal(t, models.DiscoverySourceArmis, event1.Source)
	assert.Equal(t, "192.168.1.1", event1.IP)
	assert.False(t, event1.IsAvailable)
	assert.Equal(t, "true", event1.Metadata["_deleted"])
	assert.Equal(t, "test-agent", event1.AgentID)
	assert.Equal(t, "test-poller", event1.PollerID)
	assert.Equal(t, "test-partition", event1.Partition)

	// Check second retraction event
	event2 := retractionEvents[1]
	assert.Equal(t, "test-partition:192.168.1.4", event2.DeviceID)
	assert.Equal(t, models.DiscoverySourceArmis, event2.Source)
	assert.Equal(t, "192.168.1.4", event2.IP)
	assert.False(t, event2.IsAvailable)
	assert.Equal(t, "true", event2.Metadata["_deleted"])
	assert.Equal(t, "test-agent", event2.AgentID)
	assert.Equal(t, "test-poller", event2.PollerID)
	assert.Equal(t, "test-partition", event2.Partition)

	// Verify timestamps are recent
	assert.WithinDuration(t, time.Now(), event1.Timestamp, time.Second)
	assert.WithinDuration(t, time.Now(), event2.Timestamp, time.Second)
}
