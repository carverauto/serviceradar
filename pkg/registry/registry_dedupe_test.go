package registry

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestDeduplicateBatchMergesStrongIdentityByIP(t *testing.T) {
	registry := NewDeviceRegistry(nil, logger.NewTestLogger())

	mac := "aa:bb:cc:dd:ee:ff"
	updates := []*models.DeviceUpdate{
		{
			DeviceID: "sr:uuid-1",
			IP:       "10.0.0.1",
			Metadata: map[string]string{"armis_device_id": "armis-1"},
		},
		{
			DeviceID: "sr:uuid-2",
			IP:       "10.0.0.1",
			MAC:      &mac,
			Hostname: func() *string {
				host := "shared-host"
				return &host
			}(),
			Metadata: map[string]string{"armis_device_id": "armis-2"},
		},
	}

	deduped := registry.deduplicateBatch(updates)

	// Should have 2 items: the canonical device and the tombstone
	require.Len(t, deduped, 2, "should have canonical device + tombstone")

	// First device becomes canonical and receives merged metadata
	require.Equal(t, "sr:uuid-1", deduped[0].DeviceID)
	require.Equal(t, "armis-1", deduped[0].Metadata["armis_device_id"])
	require.Equal(t, &mac, deduped[0].MAC, "MAC should be merged from second device")

	// Second device becomes a tombstone pointing to the first
	require.Equal(t, "sr:uuid-2", deduped[1].DeviceID)
	require.Equal(t, "sr:uuid-1", deduped[1].Metadata["_merged_into"], "second device should be tombstoned into first")
}

func TestDeduplicateBatchMergesWeakSightings(t *testing.T) {
	registry := NewDeviceRegistry(nil, logger.NewTestLogger())

	updates := []*models.DeviceUpdate{
		{
			DeviceID: "sr:weak-1",
			IP:       "10.0.0.2",
			Metadata: map[string]string{"first": "sighting"},
		},
		{
			DeviceID: "sr:weak-2",
			IP:       "10.0.0.2",
			Metadata: map[string]string{"second": "dupe"},
		},
	}

	deduped := registry.deduplicateBatch(updates)

	// Should have 2 items: the canonical device and the tombstone
	require.Len(t, deduped, 2, "should have canonical device + tombstone")

	// First device becomes canonical and receives merged metadata
	require.Equal(t, "sr:weak-1", deduped[0].DeviceID)
	require.Equal(t, "sighting", deduped[0].Metadata["first"])
	require.Equal(t, "dupe", deduped[0].Metadata["second"], "metadata should be merged from second device")

	// Second device becomes a tombstone
	require.Equal(t, "sr:weak-2", deduped[1].DeviceID)
	require.Equal(t, "sr:weak-1", deduped[1].Metadata["_merged_into"])
}

func TestDeduplicateBatchSkipsServiceDeviceIDs(t *testing.T) {
	registry := NewDeviceRegistry(nil, logger.NewTestLogger())

	// Service device IDs (serviceradar:*) should not be deduplicated by IP
	// because they use device_id as their identity
	updates := []*models.DeviceUpdate{
		{
			DeviceID: "serviceradar:poller:k8s-poller",
			IP:       "10.0.0.3",
			Metadata: map[string]string{"type": "poller"},
		},
		{
			DeviceID: "serviceradar:agent:docker-agent",
			IP:       "10.0.0.3", // Same IP but different service
			Metadata: map[string]string{"type": "agent"},
		},
	}

	deduped := registry.deduplicateBatch(updates)

	// Both should remain as they are service device IDs
	require.Len(t, deduped, 2, "service device IDs should not be deduplicated by IP")
	require.Equal(t, "serviceradar:poller:k8s-poller", deduped[0].DeviceID)
	require.Equal(t, "serviceradar:agent:docker-agent", deduped[1].DeviceID)
	// Neither should have _merged_into
	require.Empty(t, deduped[0].Metadata["_merged_into"])
	require.Empty(t, deduped[1].Metadata["_merged_into"])
}

func TestDeduplicateBatchSkipsExistingTombstones(t *testing.T) {
	registry := NewDeviceRegistry(nil, logger.NewTestLogger())

	// Devices that are already tombstones should pass through unchanged
	updates := []*models.DeviceUpdate{
		{
			DeviceID: "sr:canonical-device",
			IP:       "10.0.0.4",
			Metadata: map[string]string{"status": "active"},
		},
		{
			DeviceID: "sr:already-merged",
			IP:       "10.0.0.4",
			Metadata: map[string]string{"_merged_into": "sr:some-other-device"},
		},
	}

	deduped := registry.deduplicateBatch(updates)

	// Both should remain - existing tombstones are not re-processed
	require.Len(t, deduped, 2, "existing tombstones should pass through unchanged")
	require.Equal(t, "sr:canonical-device", deduped[0].DeviceID)
	require.Equal(t, "sr:already-merged", deduped[1].DeviceID)
	require.Equal(t, "sr:some-other-device", deduped[1].Metadata["_merged_into"])
}

func TestDeduplicateBatchSkipsEmptyIP(t *testing.T) {
	registry := NewDeviceRegistry(nil, logger.NewTestLogger())

	// Devices without IPs should not be deduplicated
	updates := []*models.DeviceUpdate{
		{
			DeviceID: "sr:no-ip-1",
			IP:       "",
			Metadata: map[string]string{"info": "first"},
		},
		{
			DeviceID: "sr:no-ip-2",
			IP:       "",
			Metadata: map[string]string{"info": "second"},
		},
	}

	deduped := registry.deduplicateBatch(updates)

	require.Len(t, deduped, 2, "devices without IPs should not be deduplicated")
}

func TestDeduplicateBatchMultipleCollisions(t *testing.T) {
	registry := NewDeviceRegistry(nil, logger.NewTestLogger())

	// Test handling of multiple IP collisions in a single batch
	updates := []*models.DeviceUpdate{
		{DeviceID: "sr:device-1a", IP: "10.0.0.5", Metadata: map[string]string{"group": "a"}},
		{DeviceID: "sr:device-1b", IP: "10.0.0.5", Metadata: map[string]string{"group": "a-dup"}},
		{DeviceID: "sr:device-2a", IP: "10.0.0.6", Metadata: map[string]string{"group": "b"}},
		{DeviceID: "sr:device-2b", IP: "10.0.0.6", Metadata: map[string]string{"group": "b-dup"}},
		{DeviceID: "sr:device-3", IP: "10.0.0.7", Metadata: map[string]string{"group": "c"}}, // No collision
	}

	deduped := registry.deduplicateBatch(updates)

	// Should have 5 items: 3 canonical + 2 tombstones
	require.Len(t, deduped, 5, "should have 3 canonical devices + 2 tombstones")

	// Verify canonical devices come first (indices 0, 1, 2)
	require.Equal(t, "sr:device-1a", deduped[0].DeviceID)
	require.Equal(t, "sr:device-2a", deduped[1].DeviceID)
	require.Equal(t, "sr:device-3", deduped[2].DeviceID)

	// Verify tombstones come last (indices 3, 4)
	require.Equal(t, "sr:device-1b", deduped[3].DeviceID)
	require.Equal(t, "sr:device-1a", deduped[3].Metadata["_merged_into"])
	require.Equal(t, "sr:device-2b", deduped[4].DeviceID)
	require.Equal(t, "sr:device-2a", deduped[4].Metadata["_merged_into"])
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
