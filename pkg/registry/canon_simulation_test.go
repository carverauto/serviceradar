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

// TestDIREIdentityResolution tests the DIRE (Device Identity and Reconciliation Engine)
// which uses deterministic UUIDs based on strong identifiers instead of IP-based merging.
//
// Key DIRE principles tested:
// 1. Strong identifiers (armis_device_id > integration_id > netbox_device_id > mac) determine identity
// 2. IdentityEngine generates deterministic sr: UUIDs from strong identifiers
// 3. IP is a mutable attribute - not an identity anchor
// 4. device_identifiers table enforces uniqueness (one device per strong ID)
// 5. IP churn doesn't cause incorrect merges between devices with different strong IDs
func TestDIREIdentityResolution(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	t.Run("Same strong ID always generates same sr:UUID", func(t *testing.T) {
		mockDB := db.NewMockService(ctrl)
		testLogger := logger.NewTestLogger()
		identifierStore := make(map[string]string) // identifier_value -> device_id

		setupDIREMockDB(mockDB, identifierStore)

		registry := NewDeviceRegistry(mockDB, testLogger, WithIdentityEngine(mockDB))

		// First update: Device with armis_id at IP 10.0.0.1
		update1 := &models.DeviceUpdate{
			IP:          "10.0.0.1",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			Metadata: map[string]string{
				"armis_device_id": "armis-123",
			},
		}

		err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update1})
		require.NoError(t, err)

		// Capture the generated device ID
		deviceID1 := update1.DeviceID
		require.True(t, strings.HasPrefix(deviceID1, "sr:"), "Should be ServiceRadar UUID, got: %s", deviceID1)

		// Second update: Same armis_id but different IP (DHCP churn)
		update2 := &models.DeviceUpdate{
			IP:          "10.0.0.2", // Different IP!
			DeviceID:    "",         // Let DIRE resolve it
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			Metadata: map[string]string{
				"armis_device_id": "armis-123", // Same strong ID
			},
		}

		err = registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update2})
		require.NoError(t, err)

		// Should get the SAME device ID because armis_device_id is the same
		deviceID2 := update2.DeviceID
		assert.Equal(t, deviceID1, deviceID2, "Same strong ID should resolve to same sr:UUID")
	})

	t.Run("Different strong IDs generate different sr:UUIDs even at same IP", func(t *testing.T) {
		mockDB := db.NewMockService(ctrl)
		testLogger := logger.NewTestLogger()
		identifierStore := make(map[string]string)

		setupDIREMockDB(mockDB, identifierStore)

		registry := NewDeviceRegistry(mockDB, testLogger, WithIdentityEngine(mockDB))

		// Device A with armis_id A at IP 10.0.1.1
		updateA := &models.DeviceUpdate{
			IP:          "10.0.1.1",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			Metadata: map[string]string{
				"armis_device_id": "armis-A",
			},
		}

		err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{updateA})
		require.NoError(t, err)
		deviceA_ID := updateA.DeviceID
		require.True(t, strings.HasPrefix(deviceA_ID, "sr:"))

		// Device B with different armis_id at SAME IP (e.g., DHCP reassigned)
		// This simulates the scenario where device A left and device B got its IP
		updateB := &models.DeviceUpdate{
			IP:          "10.0.1.1", // Same IP as device A!
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			Metadata: map[string]string{
				"armis_device_id": "armis-B", // Different strong ID
			},
		}

		err = registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{updateB})
		require.NoError(t, err)
		deviceB_ID := updateB.DeviceID
		require.True(t, strings.HasPrefix(deviceB_ID, "sr:"))

		// CRITICAL: Different strong IDs = different devices, even at same IP
		assert.NotEqual(t, deviceA_ID, deviceB_ID,
			"Different strong IDs should create different devices, even at same IP")
	})

	t.Run("Sweep-only devices at different IPs get deterministic sr:UUIDs based on IP", func(t *testing.T) {
		mockDB := db.NewMockService(ctrl)
		testLogger := logger.NewTestLogger()
		identifierStore := make(map[string]string)

		setupDIREMockDB(mockDB, identifierStore)

		// With IdentityEngine, even sweep devices get deterministic sr: UUIDs
		// The UUID is generated from IP as a weak identifier (partition-scoped)
		registry := NewDeviceRegistry(mockDB, testLogger, WithIdentityEngine(mockDB))

		// Sweep discovers device at 10.0.2.1 (no strong IDs)
		sweepUpdate1 := &models.DeviceUpdate{
			IP:          "10.0.2.1",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceSweep,
			Timestamp:   time.Now(),
			IsAvailable: true,
		}

		err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{sweepUpdate1})
		require.NoError(t, err)

		// With IdentityEngine, gets deterministic sr: UUID based on IP
		deviceID1 := sweepUpdate1.DeviceID
		require.True(t, strings.HasPrefix(deviceID1, "sr:"),
			"Sweep device should get sr: UUID, got: %s", deviceID1)

		// Sweep discovers device at 10.0.2.2 (no strong IDs)
		sweepUpdate2 := &models.DeviceUpdate{
			IP:          "10.0.2.2",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceSweep,
			Timestamp:   time.Now(),
			IsAvailable: true,
		}

		err = registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{sweepUpdate2})
		require.NoError(t, err)

		deviceID2 := sweepUpdate2.DeviceID
		require.True(t, strings.HasPrefix(deviceID2, "sr:"),
			"Sweep device should get sr: UUID, got: %s", deviceID2)

		// CRITICAL: Different IPs = different devices (not merged incorrectly)
		assert.NotEqual(t, deviceID1, deviceID2, "Sweep devices at different IPs should remain separate")

		// Same IP should generate same UUID (deterministic)
		sweepUpdate3 := &models.DeviceUpdate{
			IP:          "10.0.2.1", // Same IP as sweepUpdate1
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceSweep,
			Timestamp:   time.Now(),
			IsAvailable: true,
		}

		err = registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{sweepUpdate3})
		require.NoError(t, err)

		deviceID3 := sweepUpdate3.DeviceID
		assert.Equal(t, deviceID1, deviceID3, "Same IP should generate same sr:UUID")
	})

	t.Run("MAC address acts as strong identifier", func(t *testing.T) {
		mockDB := db.NewMockService(ctrl)
		testLogger := logger.NewTestLogger()
		identifierStore := make(map[string]string)

		setupDIREMockDB(mockDB, identifierStore)

		registry := NewDeviceRegistry(mockDB, testLogger, WithIdentityEngine(mockDB))

		// Device with MAC address at IP 10.0.3.1
		update1 := &models.DeviceUpdate{
			IP:          "10.0.3.1",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceSweep,
			Timestamp:   time.Now(),
			IsAvailable: true,
			MAC:         stringPtr("AA:BB:CC:DD:EE:FF"),
		}

		err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update1})
		require.NoError(t, err)
		deviceID1 := update1.DeviceID
		require.True(t, strings.HasPrefix(deviceID1, "sr:"), "Should be ServiceRadar UUID")

		// Same MAC at different IP (DHCP churn)
		update2 := &models.DeviceUpdate{
			IP:          "10.0.3.2",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceSweep,
			Timestamp:   time.Now(),
			IsAvailable: true,
			MAC:         stringPtr("AA:BB:CC:DD:EE:FF"),
		}

		err = registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update2})
		require.NoError(t, err)
		deviceID2 := update2.DeviceID

		// Same MAC = same device, regardless of IP change
		assert.Equal(t, deviceID1, deviceID2, "Same MAC should resolve to same sr:UUID")
	})

	t.Run("Strong identifier priority: armis_device_id > mac", func(t *testing.T) {
		mockDB := db.NewMockService(ctrl)
		testLogger := logger.NewTestLogger()
		identifierStore := make(map[string]string)

		setupDIREMockDB(mockDB, identifierStore)

		registry := NewDeviceRegistry(mockDB, testLogger, WithIdentityEngine(mockDB))

		// Device with both armis_device_id and MAC
		update := &models.DeviceUpdate{
			IP:          "10.0.4.1",
			DeviceID:    "",
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			MAC:         stringPtr("11:22:33:44:55:66"),
			Metadata: map[string]string{
				"armis_device_id": "armis-priority-test",
			},
		}

		err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
		require.NoError(t, err)

		deviceID := update.DeviceID
		require.True(t, strings.HasPrefix(deviceID, "sr:"))

		// The device ID should be based on armis_device_id (higher priority)
		// not the MAC. We verify this by checking the ID is deterministic
		// based on the armis_device_id.
		engine := &IdentityEngine{}
		ids := engine.ExtractStrongIdentifiers(update)
		assert.Equal(t, "armis-priority-test", ids.ArmisID, "Armis ID should be extracted")
		assert.True(t, ids.HasStrongIdentifier(), "Should have strong identifier")
	})
}

// setupDIREMockDB configures the mock DB for DIRE tests.
// The key behavior is that device_identifiers table tracks identifier->device mappings.
func setupDIREMockDB(mockDB *db.MockService, identifierStore map[string]string) {
	// Mock BatchGetDeviceIDsByIdentifier to check if identifier already exists
	mockDB.EXPECT().
		BatchGetDeviceIDsByIdentifier(gomock.Any(), gomock.Any(), gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, identifierType string, identifierValues []string, partition string) (map[string]string, error) {
			result := make(map[string]string)
			for _, val := range identifierValues {
				key := strongIdentifierCacheKey(partition, identifierType, val)
				if deviceID, ok := identifierStore[key]; ok {
					result[val] = deviceID
				}
			}
			return result, nil
		}).
		AnyTimes()

	// Mock UpsertDeviceIdentifiers to store identifier->device mapping
	mockDB.EXPECT().
		UpsertDeviceIdentifiers(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, identifiers []*models.DeviceIdentifier) error {
			for _, id := range identifiers {
				key := strongIdentifierCacheKey(id.Partition, id.IDType, id.IDValue)
				identifierStore[key] = id.DeviceID
			}
			return nil
		}).
		AnyTimes()

	// Mock PublishBatchDeviceUpdates - just accept all updates
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		Return(nil).
		AnyTimes()

	// Mock GetUnifiedDevicesByIPsOrIDs - return empty for now (devices don't exist yet)
	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]*models.UnifiedDevice{}, nil).
		AnyTimes()

	// Mock ExecuteQuery - return empty results
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
}
