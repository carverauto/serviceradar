package registry

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestDeduplicateBatchSkipsStrongIdentityUpdates(t *testing.T) {
	registry := NewDeviceRegistry(nil, logger.NewTestLogger())

	mac := "aa:bb:cc:dd:ee:ff"
	updates := []*models.DeviceUpdate{
		{
			IP:       "10.0.0.1",
			Metadata: map[string]string{"armis_device_id": "armis-1"},
		},
		{
			IP:  "10.0.0.1",
			MAC: &mac,
			Hostname: func() *string {
				host := "shared-host"
				return &host
			}(),
			Metadata: map[string]string{"armis_device_id": "armis-2"},
		},
	}

	deduped := registry.deduplicateBatch(updates)

	require.Len(t, deduped, 2, "strong-identity updates sharing an IP must not be collapsed")
}

func TestDeduplicateBatchMergesWeakSightings(t *testing.T) {
	registry := NewDeviceRegistry(nil, logger.NewTestLogger())

	updates := []*models.DeviceUpdate{
		{
			IP:       "10.0.0.2",
			Metadata: map[string]string{"first": "sighting"},
		},
		{
			IP:       "10.0.0.2",
			Metadata: map[string]string{"second": "dupe"},
		},
	}

	deduped := registry.deduplicateBatch(updates)

	require.Len(t, deduped, 1, "weak sightings on the same IP should merge into one update")
	require.Equal(t, "sighting", deduped[0].Metadata["first"])
	require.Equal(t, "dupe", deduped[0].Metadata["second"])
}

func TestScrubArmisCanonicalDropsHintsAndDeviceID(t *testing.T) {
	deviceID := "sr:canonical-from-armis"
	update := &models.DeviceUpdate{
		DeviceID: deviceID,
		Metadata: map[string]string{
			"integration_type":        "armis",
			"canonical_device_id":     deviceID,
			"canonical_partition":     "default",
			"canonical_metadata_hash": "deadbeef",
			"canonical_revision":      "42",
		},
	}

	scrubArmisCanonical(update)

	require.Empty(t, update.DeviceID)
	require.NotContains(t, update.Metadata, "canonical_device_id")
	require.NotContains(t, update.Metadata, "canonical_partition")
	require.NotContains(t, update.Metadata, "canonical_metadata_hash")
	require.NotContains(t, update.Metadata, "canonical_revision")
}
