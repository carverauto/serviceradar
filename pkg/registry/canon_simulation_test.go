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
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// TestCanonicalizationSimulation simulates real-world scenarios of device discovery
// to verify canonicalization behavior, particularly around DHCP churn and late-arriving strong identifiers.
func TestCanonicalizationSimulation(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().WithTx(gomock.Any(), gomock.Any()).DoAndReturn(func(ctx context.Context, fn func(db.Service) error) error {
		return fn(mockDB)
	}).AnyTimes()
	mockDB.EXPECT().LockUnifiedDevices(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	testLogger := logger.NewTestLogger()

	// We need to mock the DB behavior for device lookups to simulate state persistence
	// Since we can't use a real DB, we'll use an in-memory map to store "persisted" devices
	persistedDevices := make(map[string]*models.UnifiedDevice)

	// Setup common mock expectations
	setupMockDB(mockDB, persistedDevices)

	registry := NewDeviceRegistry(mockDB, testLogger, WithDeviceIdentityResolver(mockDB))

	t.Run("Scenario 1: Sweep First, Then Armis (Happy Path)", func(t *testing.T) {
		// 1. Sweep discovers device at 10.0.0.1 (No strong IDs)
		sweepUpdate := &models.DeviceUpdate{
			IP:          "10.0.0.1",
			DeviceID:    "", // Empty, let registry generate
			Partition:   "default",
			Source:      models.DiscoverySourceSweep,
			Timestamp:   time.Now(),
			IsAvailable: true,
		}

		err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{sweepUpdate})
		require.NoError(t, err)

		// Verify we have a device with sr: UUID and IP 10.0.0.1
		var sweepDeviceID string
		for id, dev := range persistedDevices {
			if dev.IP == "10.0.0.1" {
				sweepDeviceID = id
				break
			}
		}
		require.NotEmpty(t, sweepDeviceID, "Sweep device should be persisted")
		require.True(t, strings.HasPrefix(sweepDeviceID, "sr:"), "Should be ServiceRadar UUID")

		// 2. Armis discovers same device at 10.0.0.1 with MAC and Armis ID
		armisUpdate := &models.DeviceUpdate{
			IP:          "10.0.0.1",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			MAC:         stringPtr("AA:BB:CC:DD:EE:FF"),
			Metadata: map[string]string{
				"armis_device_id": "armis-1",
			},
		}

		err = registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{armisUpdate})
		require.NoError(t, err)

		// Verify Armis update merged into existing device (same UUID)
		updatedDevice := persistedDevices[sweepDeviceID]
		require.NotNil(t, updatedDevice)
		assert.Equal(t, "AA:BB:CC:DD:EE:FF", updatedDevice.MAC.Value)
		assert.Equal(t, "armis-1", updatedDevice.Metadata.Value["armis_device_id"])
	})

	t.Run("Scenario 2: DHCP Churn (Sweep -> IP Change -> Armis)", func(t *testing.T) {
		// Clear state for this run
		// Note: In a real test we might want separate registry instances, but here we share mockDB logic
		// so we just need to be careful with IP overlaps between scenarios. Using 10.0.1.x here.

		// 1. Sweep discovers device at 10.0.1.1
		sweepUpdate1 := &models.DeviceUpdate{
			IP:          "10.0.1.1",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceSweep,
			Timestamp:   time.Now(),
			IsAvailable: true,
		}
		require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{sweepUpdate1}))

		// Capture ID of first device
		var deviceA_ID string
		for id, dev := range persistedDevices {
			if dev.IP == "10.0.1.1" {
				deviceA_ID = id
				break
			}
		}
		require.NotEmpty(t, deviceA_ID)

		// 2. Device changes IP to 10.0.1.2. Sweep sees it there.
		// Since there are no strong IDs linking it to 10.0.1.1, this MUST create a NEW device.
		sweepUpdate2 := &models.DeviceUpdate{
			IP:          "10.0.1.2",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceSweep,
			Timestamp:   time.Now(),
			IsAvailable: true,
		}
		require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{sweepUpdate2}))

		// Capture ID of second device
		var deviceB_ID string
		for id, dev := range persistedDevices {
			if dev.IP == "10.0.1.2" {
				deviceB_ID = id
				break
			}
		}
		require.NotEmpty(t, deviceB_ID)
		assert.NotEqual(t, deviceA_ID, deviceB_ID, "Should create new device for new IP when no strong IDs exist")

		// 3. Armis sees device at 10.0.1.2 with MAC.
		// This should attach to Device B (10.0.1.2).
		armisUpdate := &models.DeviceUpdate{
			IP:          "10.0.1.2",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			MAC:         stringPtr("11:22:33:44:55:66"),
			Metadata: map[string]string{
				"armis_device_id": "armis-2",
			},
		}
		require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{armisUpdate}))

		// Verify Device B got the strong IDs
		deviceB := persistedDevices[deviceB_ID]
		assert.Equal(t, "11:22:33:44:55:66", deviceB.MAC.Value)
		assert.Equal(t, "armis-2", deviceB.Metadata.Value["armis_device_id"])

		// Verify Device A is still there, but stale (no strong IDs).
		// This confirms the "orphan" problem that the Reaper is designed to solve.
		deviceA := persistedDevices[deviceA_ID]
		t.Logf("Device A: %+v", deviceA)
		if deviceA.MAC != nil {
			t.Logf("Device A MAC: %+v", deviceA.MAC)
		}
		assert.Nil(t, deviceA.MAC)
		assert.Empty(t, deviceA.Metadata.Value["armis_device_id"])
	})
}

// setupMockDB configures the mock to act like a simple in-memory DB
func setupMockDB(mockDB *db.MockService, store map[string]*models.UnifiedDevice) {
	// Mock PublishBatchDeviceUpdates to "persist" devices
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			for _, u := range updates {
				// Simulate upsert
				if u.DeviceID == "" {
					continue // Should have ID by now
				}

				existing, exists := store[u.DeviceID]
				if !exists {
					existing = &models.UnifiedDevice{
						DeviceID: u.DeviceID,
						Metadata: &models.DiscoveredField[map[string]string]{Value: make(map[string]string)},
					}
					store[u.DeviceID] = existing
				}

				existing.IP = u.IP
				if u.MAC != nil {
					existing.MAC = &models.DiscoveredField[string]{Value: *u.MAC}
				}
				if u.Metadata != nil {
					for k, v := range u.Metadata {
						existing.Metadata.Value[k] = v
					}
				}
			}
			return nil
		}).AnyTimes()

	// Mock GetUnifiedDevicesByIPsOrIDs to return from store
	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, ips []string, ids []string) ([]*models.UnifiedDevice, error) {
			var results []*models.UnifiedDevice
			seen := make(map[string]bool)

			// Find by IDs
			for _, id := range ids {
				if dev, ok := store[id]; ok {
					if !seen[dev.DeviceID] {
						results = append(results, dev)
						seen[dev.DeviceID] = true
					}
				}
			}

			// Find by IPs
			for _, ip := range ips {
				for _, dev := range store {
					if dev.IP == ip {
						if !seen[dev.DeviceID] {
							results = append(results, dev)
							seen[dev.DeviceID] = true
						}
					}
				}
			}
			return results, nil
		}).AnyTimes()

	// Mock other queries needed by registry but not critical for this simulation
	mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).Return(nil, nil).AnyTimes()
	mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any()).Return(nil, nil).AnyTimes()
}
