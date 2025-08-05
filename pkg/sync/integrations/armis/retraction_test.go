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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestArmisIntegration_Reconcile_SimpleUpdate(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockQuerier := NewMockSRQLQuerier(ctrl)
	mockUpdater := NewMockArmisUpdater(ctrl)

	// Test data
	ctx := context.Background()

	// Existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition/192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "1",
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.2",
			IP:          "192.168.1.2",
			IsAvailable: false,
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
		},
		SweepQuerier: mockQuerier,
		Updater:      mockUpdater,
		Logger:       logger.NewTestLogger(),
	}

	// Setup expectations
	mockQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(existingDeviceStates, nil)

	// Mock the Armis updater to verify the updates
	mockUpdater.EXPECT().
		UpdateDeviceStatus(ctx, gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []ArmisDeviceStatus) error {
			require.Len(t, updates, 2)

			// Device 1 is available in ServiceRadar, so it should be marked as NOT available in Armis
			assert.Equal(t, 1, updates[0].DeviceID)
			assert.Equal(t, "192.168.1.1", updates[0].IP)
			assert.False(t, updates[0].Available)

			// Device 2 is NOT available in ServiceRadar, so it should be marked as available in Armis
			assert.Equal(t, 2, updates[1].DeviceID)
			assert.Equal(t, "192.168.1.2", updates[1].IP)
			assert.True(t, updates[1].Available)

			return nil
		})

	// Execute the reconcile operation
	err := integration.Reconcile(ctx)
	require.NoError(t, err)
}

func TestArmisIntegration_Reconcile_EmptyDeviceStates(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockQuerier := NewMockSRQLQuerier(ctrl)
	mockUpdater := NewMockArmisUpdater(ctrl)

	// Test data
	ctx := context.Background()

	// No existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{}

	// Setup the integration
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
		},
		SweepQuerier: mockQuerier,
		Updater:      mockUpdater,
		Logger:       logger.NewTestLogger(),
	}

	// Setup expectations
	mockQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(existingDeviceStates, nil)

	// Updater should not be called since there are no device states

	// Execute the reconcile operation
	err := integration.Reconcile(ctx)
	require.NoError(t, err)
}

func TestArmisIntegration_Reconcile_UpdaterError(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockQuerier := NewMockSRQLQuerier(ctrl)
	mockUpdater := NewMockArmisUpdater(ctrl)

	// Test data
	ctx := context.Background()
	expectedError := assert.AnError

	// Existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition/192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"armis_device_id": "1",
			},
		},
	}

	// Setup the integration
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
		},
		SweepQuerier: mockQuerier,
		Updater:      mockUpdater,
		Logger:       logger.NewTestLogger(),
	}

	// Setup expectations
	mockQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(existingDeviceStates, nil)

	// Mock the updater to return an error
	mockUpdater.EXPECT().
		UpdateDeviceStatus(ctx, gomock.Any()).
		Return(expectedError)

	// Execute the reconcile operation - should return error
	err := integration.Reconcile(ctx)
	require.Error(t, err)
	assert.Equal(t, expectedError, err)
}

func TestArmisIntegration_Reconcile_NoUpdater(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockQuerier := NewMockSRQLQuerier(ctrl)

	// Setup the integration WITHOUT Updater
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
		},
		SweepQuerier: mockQuerier,
		Updater:      nil, // No updater configured
		Logger:       logger.NewTestLogger(),
	}

	// No expectations needed - should return early

	// Execute the reconcile operation - should succeed with early return
	err := integration.Reconcile(context.Background())
	require.NoError(t, err)
}

func TestArmisIntegration_Reconcile_QueryError(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockQuerier := NewMockSRQLQuerier(ctrl)
	mockUpdater := NewMockArmisUpdater(ctrl)

	// Test data
	ctx := context.Background()
	expectedError := assert.AnError

	// Setup the integration
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
		},
		SweepQuerier: mockQuerier,
		Updater:      mockUpdater,
		Logger:       logger.NewTestLogger(),
	}

	// Setup expectations - querier returns error
	mockQuerier.EXPECT().
		GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis)).
		Return(nil, expectedError)

	// Execute the reconcile operation - should return error
	err := integration.Reconcile(ctx)
	require.Error(t, err)
	assert.Equal(t, expectedError, err)
}
