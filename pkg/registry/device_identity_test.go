package registry

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// TestGenerateServiceRadarDeviceID_Determinism verifies that UUID generation is deterministic
// and anchored to strong identifiers when present (so IP churn doesn't merge strong IDs),
// falling back to IP + partition only when no strong identifiers exist.
func TestGenerateServiceRadarDeviceID_Determinism(t *testing.T) {
	t.Parallel()

	t.Run("strong identifiers anchor the UUID across IP churn", func(t *testing.T) {
		update1 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			Metadata: map[string]string{
				"armis_device_id": "12345",
			},
		}
		update2 := &models.DeviceUpdate{
			IP:        "10.0.0.99",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			Metadata: map[string]string{
				"armis_device_id": "12345",
			},
		}
		updateOther := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			Metadata: map[string]string{
				"armis_device_id": "99999",
			},
		}

		uuid1 := generateServiceRadarDeviceID(update1)
		uuid2 := generateServiceRadarDeviceID(update2)
		uuidOther := generateServiceRadarDeviceID(updateOther)

		assert.Equal(t, uuid1, uuid2, "Same strong ID should stay stable even if IP changes")
		assert.NotEqual(t, uuid1, uuidOther, "Different strong IDs must not collapse on shared IP")
		assert.True(t, isServiceRadarUUID(uuid1), "Should be a valid sr: UUID")
	})

	t.Run("MAC anchors when no other strong IDs are present", func(t *testing.T) {
		mac1 := "AA:BB:CC:DD:EE:FF"
		mac2 := "11:22:33:44:55:66"
		update1 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
			MAC:       &mac1,
		}
		update2 := &models.DeviceUpdate{
			IP:        "10.0.0.2",
			Partition: "default",
			MAC:       &mac1,
		}
		updateOther := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
			MAC:       &mac2,
		}

		uuid1 := generateServiceRadarDeviceID(update1)
		uuid2 := generateServiceRadarDeviceID(update2)
		uuidOther := generateServiceRadarDeviceID(updateOther)

		assert.Equal(t, uuid1, uuid2, "Same MAC should stay stable across IPs")
		assert.NotEqual(t, uuid1, uuidOther, "Different MACs should not collide")
	})

	t.Run("weak-only updates still use IP+partition deterministically", func(t *testing.T) {
		update1 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
		}
		update2 := &models.DeviceUpdate{
			IP:        "10.0.0.2",
			Partition: "default",
		}
		update3 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "production",
		}
		update4 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "",
		}

		uuid1 := generateServiceRadarDeviceID(update1)
		uuid2 := generateServiceRadarDeviceID(update2)
		uuid3 := generateServiceRadarDeviceID(update3)
		uuid4 := generateServiceRadarDeviceID(update4)

		assert.NotEqual(t, uuid1, uuid2, "Different IPs should produce different UUIDs")
		assert.NotEqual(t, uuid1, uuid3, "Different partitions should produce different UUIDs")
		assert.Equal(t, uuid1, uuid4, "Empty partition should default to 'default'")
	})

	t.Run("UUID is stable across multiple calls", func(t *testing.T) {
		update := &models.DeviceUpdate{
			IP:        "192.168.1.100",
			Partition: "test-partition",
		}

		// Call multiple times
		uuids := make([]string, 100)
		for i := 0; i < 100; i++ {
			uuids[i] = generateServiceRadarDeviceID(update)
		}

		// All should be identical
		for i := 1; i < 100; i++ {
			assert.Equal(t, uuids[0], uuids[i], "UUID should be stable across calls")
		}
	})
}

func TestDeviceIdentityResolver_IPFallbackWhenWeakOnly(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().WithTx(gomock.Any(), gomock.Any()).DoAndReturn(func(ctx context.Context, fn func(db.Service) error) error {
		return fn(mockDB)
	}).AnyTimes()
	mockDB.EXPECT().LockUnifiedDevices(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()

	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), []string{"10.0.0.1"}, gomock.Nil()).
		Return([]*models.UnifiedDevice{
			{
				DeviceID: "sr:existing-1234",
				IP:       "10.0.0.1",
			},
		}, nil)

	resolver := NewDeviceIdentityResolver(mockDB, logger.NewTestLogger())

	updates := []*models.DeviceUpdate{
		{
			IP:        "10.0.0.1",
			DeviceID:  "",
			Partition: "default",
			Source:    models.DiscoverySourceSweep,
		},
	}

	err := resolver.ResolveDeviceIDs(ctx, updates)
	require.NoError(t, err)
	require.Len(t, updates, 1)

	assert.Equal(t, "sr:existing-1234", updates[0].DeviceID)
}

func TestDeviceIdentityResolver_StrongIDSkipsIPFallback(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().WithTx(gomock.Any(), gomock.Any()).DoAndReturn(func(ctx context.Context, fn func(db.Service) error) error {
		return fn(mockDB)
	}).AnyTimes()
	mockDB.EXPECT().LockUnifiedDevices(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()

	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Nil()).
		Return([]*models.UnifiedDevice{
			{
				DeviceID: "sr:existing-1234",
				IP:       "10.0.0.1",
				Metadata: &models.DiscoveredField[map[string]string]{
					Value: map[string]string{
						"armis_device_id": "armis-existing",
					},
				},
			},
		}, nil).
		AnyTimes()

	resolver := NewDeviceIdentityResolver(mockDB, logger.NewTestLogger())

	updates := []*models.DeviceUpdate{
		{
			IP:        "10.0.0.1",
			DeviceID:  "",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			Metadata: map[string]string{
				"armis_device_id": "armis-1",
			},
		},
	}

	err := resolver.ResolveDeviceIDs(ctx, updates)
	require.NoError(t, err)
	require.Len(t, updates, 1)

	assert.True(t, isServiceRadarUUID(updates[0].DeviceID))
	assert.NotEqual(t, "sr:existing-1234", updates[0].DeviceID)
}

func TestDeviceIdentityResolver_StrongIDMergesAcrossIPChurn(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().WithTx(gomock.Any(), gomock.Any()).DoAndReturn(func(ctx context.Context, fn func(db.Service) error) error {
		return fn(mockDB)
	}).AnyTimes()
	mockDB.EXPECT().LockUnifiedDevices(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Nil()).
		Return([]*models.UnifiedDevice{}, nil).
		AnyTimes()

	resolver := NewDeviceIdentityResolver(mockDB, logger.NewTestLogger())

	mac := "aa:bb:cc:dd:ee:ff"
	armisID := "armis-42"

	updates := []*models.DeviceUpdate{
		{
			IP:        "10.0.0.10",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			MAC:       &mac,
			Metadata: map[string]string{
				"armis_device_id": armisID,
			},
		},
		{
			IP:        "10.0.1.20",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			MAC:       &mac,
			Metadata: map[string]string{
				"armis_device_id": armisID,
			},
		},
	}

	err := resolver.ResolveDeviceIDs(ctx, updates)
	require.NoError(t, err)
	require.Len(t, updates, 2)

	require.NotEmpty(t, updates[0].DeviceID)
	assert.Equal(t, updates[0].DeviceID, updates[1].DeviceID, "Strong identifiers must anchor the same device across IP churn")
}
