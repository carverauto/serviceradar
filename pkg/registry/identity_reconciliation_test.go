package registry

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBuildUpdateFromNetworkSighting_DefaultsToUnavailable(t *testing.T) {
	now := time.Now()
	sighting := &models.NetworkSighting{
		SightingID: "s-1",
		Partition:  "default",
		IP:         "10.0.0.1",
		Source:     models.DiscoverySourceSweep,
		Status:     models.SightingStatusActive,
		FirstSeen:  now.Add(-5 * time.Minute),
		LastSeen:   now,
		Metadata: map[string]string{
			"hostname": "host-1",
			"mac":      "aa:bb:cc:dd:ee:ff",
		},
	}

	update := buildUpdateFromNetworkSighting(sighting)
	require.NotNil(t, update)

	assert.Equal(t, "10.0.0.1", update.IP)
	assert.Equal(t, "default", update.Partition)
	assert.False(t, update.IsAvailable, "promoted sightings should start unavailable until probed")
	assert.Equal(t, "true", update.Metadata["_promoted_sighting"])
	assert.Equal(t, "s-1", update.Metadata["sighting_id"])
	require.NotNil(t, update.Hostname)
	assert.Equal(t, "host-1", *update.Hostname)
	require.NotNil(t, update.MAC)
	assert.Equal(t, "aa:bb:cc:dd:ee:ff", *update.MAC)
}
