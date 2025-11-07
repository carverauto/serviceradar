package registry

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestDeviceRecordFromUpdate_NewRecord(t *testing.T) {
	now := time.Unix(1710000000, 0).UTC()
	hostname := "edge-gw"
	mac := "00:11:22:33:44:55"

	update := &models.DeviceUpdate{
		DeviceID:    "default:10.0.0.5",
		IP:          "10.0.0.5",
		PollerID:    "poller-1",
		AgentID:     "agent-1",
		Source:      models.DiscoverySourceSNMP,
		Timestamp:   now,
		IsAvailable: true,
		Hostname:    &hostname,
		MAC:         &mac,
		Metadata: map[string]string{
			"_first_seen":        now.Format(time.RFC3339Nano),
			"integration_id":     "armis-123",
			"collector_agent_id": "agent-collector",
			"device_type":        "router",
		},
	}

	record := deviceRecordFromUpdate(update, nil)
	require.NotNil(t, record)

	assert.Equal(t, "default:10.0.0.5", record.DeviceID)
	assert.Equal(t, "10.0.0.5", record.IP)
	assert.Equal(t, "poller-1", record.PollerID)
	assert.Equal(t, "agent-1", record.AgentID)
	require.NotNil(t, record.Hostname)
	assert.Equal(t, "edge-gw", *record.Hostname)
	require.NotNil(t, record.MAC)
	assert.Equal(t, "00:11:22:33:44:55", *record.MAC)
	assert.Equal(t, []string{"snmp"}, record.DiscoverySources)
	assert.Equal(t, now, record.FirstSeen)
	assert.Equal(t, now, record.LastSeen)
	assert.Equal(t, "router", record.DeviceType)
	require.NotNil(t, record.IntegrationID)
	assert.Equal(t, "armis-123", *record.IntegrationID)
	require.NotNil(t, record.CollectorAgentID)
	assert.Equal(t, "agent-collector", *record.CollectorAgentID)
	assert.True(t, record.IsAvailable)
}

func TestDeviceRecordFromUpdate_MergesExisting(t *testing.T) {
	now := time.Unix(1710003600, 0).UTC()
	earlier := now.Add(-10 * time.Minute)

	existing := &DeviceRecord{
		DeviceID:         "default:10.0.0.6",
		IP:               "10.0.0.6",
		PollerID:         "poller-old",
		AgentID:          "agent-old",
		DiscoverySources: []string{"snmp"},
		IsAvailable:      true,
		FirstSeen:        earlier,
		LastSeen:         now,
		Metadata: map[string]string{
			"integration_id": "armis-existing",
			"region":         "us-east-1",
		},
	}
	integration := "armis-existing"
	existing.IntegrationID = &integration

	update := &models.DeviceUpdate{
		DeviceID:  "default:10.0.0.6",
		IP:        "10.0.0.6",
		PollerID:  "poller-new",
		AgentID:   "agent-new",
		Source:    models.DiscoverySourceMapper,
		Timestamp: earlier,
		Metadata: map[string]string{
			"collector_agent_id": "agent-collector",
		},
	}

	record := deviceRecordFromUpdate(update, existing)
	require.NotNil(t, record)

	assert.Equal(t, "poller-new", record.PollerID)
	assert.Equal(t, "agent-new", record.AgentID)
	assert.ElementsMatch(t, []string{"snmp", "mapper"}, record.DiscoverySources)
	assert.Equal(t, now, record.LastSeen, "older update should not regress last_seen")
	assert.Equal(t, earlier, record.FirstSeen)
	require.NotNil(t, record.IntegrationID)
	assert.Equal(t, "armis-existing", *record.IntegrationID, "integration_id should persist from existing metadata")
	require.NotNil(t, record.CollectorAgentID)
	assert.Equal(t, "agent-collector", *record.CollectorAgentID)
}

func TestIsDeletionMetadata(t *testing.T) {
	assert.False(t, isDeletionMetadata(nil))
	assert.False(t, isDeletionMetadata(map[string]string{"other": "value"}))
	assert.True(t, isDeletionMetadata(map[string]string{"_deleted": "true"}))
	assert.True(t, isDeletionMetadata(map[string]string{"deleted": "TRUE"}))
}
