package registry

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestDeviceRecordFromUnified(t *testing.T) {
	first := time.Unix(1700000000, 0).UTC()
	last := first.Add(5 * time.Minute)

	device := &models.UnifiedDevice{
		DeviceID:    "device-primary ",
		IP:          " 10.0.0.50 ",
		IsAvailable: true,
		FirstSeen:   first,
		LastSeen:    last,
		DeviceType:  "router",
		Hostname: &models.DiscoveredField[string]{
			Value:    " edge-gw ",
			PollerID: "poller-hostname",
			AgentID:  "agent-hostname",
		},
		MAC: &models.DiscoveredField[string]{
			Value:    "00:aa:bb:cc:dd:ee",
			PollerID: "poller-mac",
			AgentID:  "agent-mac",
		},
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"integration_id":     " armis-123 ",
				"collector_agent_id": "agent-collector",
				"region":             "us-east-1",
			},
		},
		DiscoverySources: []models.DiscoverySourceInfo{
			{
				Source:     models.DiscoverySourceSweep,
				AgentID:    "agent-sweep",
				PollerID:   "poller-sweep",
				Confidence: 5,
				LastSeen:   last.Add(-5 * time.Minute),
			},
			{
				Source:     models.DiscoverySourceNetbox,
				AgentID:    "agent-netbox",
				PollerID:   "poller-netbox",
				Confidence: 7,
				LastSeen:   last,
			},
			{
				Source:     models.DiscoverySourceNetbox,
				AgentID:    "agent-netbox",
				PollerID:   "poller-netbox",
				Confidence: 7,
				LastSeen:   last,
			},
		},
	}

	record := DeviceRecordFromUnified(device)
	if record == nil {
		t.Fatal("expected record to be created")
	}

	if record.DeviceID != "device-primary" {
		t.Fatalf("expected device ID to be trimmed, got %q", record.DeviceID)
	}
	if record.IP != "10.0.0.50" {
		t.Fatalf("expected IP to be trimmed, got %q", record.IP)
	}
	if record.PollerID != "poller-netbox" {
		t.Fatalf("expected poller ID from highest confidence source, got %q", record.PollerID)
	}
	if record.AgentID != "agent-netbox" {
		t.Fatalf("expected agent ID from highest confidence source, got %q", record.AgentID)
	}
	if record.Hostname == nil || *record.Hostname != "edge-gw" {
		t.Fatalf("expected trimmed hostname, got %#v", record.Hostname)
	}
	if record.MAC == nil || *record.MAC != "00:AA:BB:CC:DD:EE" {
		t.Fatalf("expected uppercase MAC, got %#v", record.MAC)
	}
	if len(record.DiscoverySources) != 2 {
		t.Fatalf("expected deduplicated discovery sources, got %v", record.DiscoverySources)
	}
	if record.IntegrationID == nil || *record.IntegrationID != "armis-123" {
		t.Fatalf("expected integration ID pointer, got %#v", record.IntegrationID)
	}
	if record.CollectorAgentID == nil || *record.CollectorAgentID != "agent-collector" {
		t.Fatalf("expected collector agent ID pointer, got %#v", record.CollectorAgentID)
	}
	if record.Metadata["region"] != "us-east-1" {
		t.Fatalf("expected metadata to include region, got %v", record.Metadata)
	}

	// Mutate copy to ensure original metadata not modified.
	record.Metadata["region"] = "us-west-2"
	if original := device.Metadata.Value["region"]; original != "us-east-1" {
		t.Fatalf("expected original metadata to remain unchanged, got %q", original)
	}
}

func TestDeviceRecordFromUnifiedRequiresDeviceID(t *testing.T) {
	device := &models.UnifiedDevice{
		IP: "10.0.0.60",
	}
	if record := DeviceRecordFromUnified(device); record != nil {
		t.Fatalf("expected nil record, got %#v", record)
	}
}

func TestUnifiedDeviceFromRecord(t *testing.T) {
	now := time.Now().UTC()
	hostname := "edge-gateway"
	record := &DeviceRecord{
		DeviceID:         "default:10.0.0.70",
		IP:               "10.0.0.70",
		PollerID:         "poller-x",
		AgentID:          "agent-x",
		Hostname:         &hostname,
		DiscoverySources: []string{"snmp"},
		IsAvailable:      true,
		FirstSeen:        now.Add(-time.Hour),
		LastSeen:         now,
		Metadata: map[string]string{
			"region": "us-west-2",
		},
	}

	unified := UnifiedDeviceFromRecord(record)
	require.NotNil(t, unified)
	assert.Equal(t, record.DeviceID, unified.DeviceID)
	assert.Equal(t, record.IP, unified.IP)
	assert.Equal(t, record.LastSeen, unified.LastSeen)
	require.NotNil(t, unified.Hostname)
	assert.Equal(t, hostname, unified.Hostname.Value)
	require.NotNil(t, unified.Metadata)
	assert.Equal(t, "us-west-2", unified.Metadata.Value["region"])
	require.Len(t, unified.DiscoverySources, 1)
	assert.Equal(t, models.DiscoverySource("snmp"), unified.DiscoverySources[0].Source)
}

func TestLegacyDeviceFromRecord(t *testing.T) {
	record := &DeviceRecord{
		DeviceID:         "default:10.0.0.80",
		IP:               "10.0.0.80",
		PollerID:         "poller-z",
		AgentID:          "agent-z",
		DiscoverySources: []string{"mapper", "armis"},
		IsAvailable:      true,
		FirstSeen:        time.Unix(1700000000, 0).UTC(),
		LastSeen:         time.Unix(1700003600, 0).UTC(),
		Metadata: map[string]string{
			"owner": "ops",
		},
	}

	device := LegacyDeviceFromRecord(record)
	require.NotNil(t, device)
	assert.Equal(t, record.DeviceID, device.DeviceID)
	assert.ElementsMatch(t, record.DiscoverySources, device.DiscoverySources)
	assert.Equal(t, record.IP, device.IP)
	assert.Equal(t, "ops", device.Metadata["owner"])
}
