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
// based only on IP + partition, regardless of what strong identifiers are present.
// This is the core fix for the device count growth issue.
func TestGenerateServiceRadarDeviceID_Determinism(t *testing.T) {
	t.Parallel()

	t.Run("same IP and partition always produces same UUID", func(t *testing.T) {
		// Base case: IP only
		update1 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
			Source:    models.DiscoverySourceSweep,
		}

		// With MAC address (strong identifier)
		mac := "AA:BB:CC:DD:EE:FF"
		update2 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			MAC:       &mac,
		}

		// With Armis ID (strong identifier)
		update3 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			Metadata: map[string]string{
				"armis_device_id": "12345",
			},
		}

		// With both MAC and Armis ID
		update4 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			MAC:       &mac,
			Metadata: map[string]string{
				"armis_device_id": "12345",
				"netbox_device_id": "nb-999",
			},
		}

		uuid1 := generateServiceRadarDeviceID(update1)
		uuid2 := generateServiceRadarDeviceID(update2)
		uuid3 := generateServiceRadarDeviceID(update3)
		uuid4 := generateServiceRadarDeviceID(update4)

		// All UUIDs should be identical because IP + partition are the same
		assert.Equal(t, uuid1, uuid2, "UUID should be same regardless of MAC")
		assert.Equal(t, uuid1, uuid3, "UUID should be same regardless of armis_device_id")
		assert.Equal(t, uuid1, uuid4, "UUID should be same regardless of all strong identifiers")

		// Verify it's a valid ServiceRadar UUID
		assert.True(t, isServiceRadarUUID(uuid1), "Should be a valid sr: UUID")
	})

	t.Run("different IPs produce different UUIDs", func(t *testing.T) {
		update1 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
		}
		update2 := &models.DeviceUpdate{
			IP:        "10.0.0.2",
			Partition: "default",
		}

		uuid1 := generateServiceRadarDeviceID(update1)
		uuid2 := generateServiceRadarDeviceID(update2)

		assert.NotEqual(t, uuid1, uuid2, "Different IPs should produce different UUIDs")
	})

	t.Run("different partitions produce different UUIDs", func(t *testing.T) {
		update1 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
		}
		update2 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "production",
		}

		uuid1 := generateServiceRadarDeviceID(update1)
		uuid2 := generateServiceRadarDeviceID(update2)

		assert.NotEqual(t, uuid1, uuid2, "Different partitions should produce different UUIDs")
	})

	t.Run("empty partition defaults to 'default'", func(t *testing.T) {
		update1 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "",
		}
		update2 := &models.DeviceUpdate{
			IP:        "10.0.0.1",
			Partition: "default",
		}

		uuid1 := generateServiceRadarDeviceID(update1)
		uuid2 := generateServiceRadarDeviceID(update2)

		assert.Equal(t, uuid1, uuid2, "Empty partition should default to 'default'")
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

func TestDeviceIdentityResolver_IPFallbackWhenStrongUnknown(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

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
			Source:    models.DiscoverySourceArmis,
			Metadata: map[string]string{
				"armis_device_id": "armis-1",
			},
		},
	}

	err := resolver.ResolveDeviceIDs(ctx, updates)
	require.NoError(t, err)
	require.Len(t, updates, 1)

	assert.Equal(t, "sr:existing-1234", updates[0].DeviceID)
}
