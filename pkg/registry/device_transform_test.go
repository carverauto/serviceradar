package registry

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestDeviceRecordFromOCSF(t *testing.T) {
	first := time.Unix(1700000000, 0).UTC()
	last := first.Add(5 * time.Minute)
	isAvailable := true

	device := &models.OCSFDevice{
		UID:           "device-primary ",
		IP:            " 10.0.0.50 ",
		Hostname:      " edge-gw ",
		MAC:           "00:aa:bb:cc:dd:ee",
		FirstSeenTime: &first,
		LastSeenTime:  &last,
		IsAvailable:   &isAvailable,
		Type:          "router",
		PollerID:      "poller-x",
		AgentID:       "agent-x",
		DiscoverySources: []string{
			string(models.DiscoverySourceSweep),
			string(models.DiscoverySourceNetbox),
		},
		Metadata: map[string]string{
			"integration_id":     " armis-123 ",
			"collector_agent_id": "agent-collector",
			"region":             "us-east-1",
		},
	}

	record := DeviceRecordFromOCSF(device)
	if record == nil {
		t.Fatal("expected record to be created")
	}

	if record.DeviceID != "device-primary" {
		t.Fatalf("expected device ID to be trimmed, got %q", record.DeviceID)
	}
	if record.IP != "10.0.0.50" {
		t.Fatalf("expected IP to be trimmed, got %q", record.IP)
	}
	if record.PollerID != "poller-x" {
		t.Fatalf("expected poller ID, got %q", record.PollerID)
	}
	if record.AgentID != "agent-x" {
		t.Fatalf("expected agent ID, got %q", record.AgentID)
	}
	if record.Hostname == nil || *record.Hostname != "edge-gw" {
		t.Fatalf("expected trimmed hostname, got %#v", record.Hostname)
	}
	if record.MAC == nil || *record.MAC != "00:AA:BB:CC:DD:EE" {
		t.Fatalf("expected uppercase MAC, got %#v", record.MAC)
	}
	if len(record.DiscoverySources) != 2 {
		t.Fatalf("expected 2 discovery sources, got %v", record.DiscoverySources)
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
	if !record.IsAvailable {
		t.Fatal("expected IsAvailable to be true")
	}

	// Mutate copy to ensure original metadata not modified.
	record.Metadata["region"] = "us-west-2"
	if original := device.Metadata["region"]; original != "us-east-1" {
		t.Fatalf("expected original metadata to remain unchanged, got %q", original)
	}
}

func TestDeviceRecordFromOCSFRequiresDeviceID(t *testing.T) {
	device := &models.OCSFDevice{
		IP: "10.0.0.60",
	}
	if record := DeviceRecordFromOCSF(device); record != nil {
		t.Fatalf("expected nil record, got %#v", record)
	}
}

func TestDeviceRecordFromOCSFNil(t *testing.T) {
	if record := DeviceRecordFromOCSF(nil); record != nil {
		t.Fatalf("expected nil record, got %#v", record)
	}
}

func TestOCSFDeviceFromRecord(t *testing.T) {
	now := time.Now().UTC()
	hostname := "edge-gateway"
	mac := "00:AA:BB:CC:DD:EE"
	record := &DeviceRecord{
		DeviceID:         "default:10.0.0.70",
		IP:               "10.0.0.70",
		PollerID:         "poller-x",
		AgentID:          "agent-x",
		Hostname:         &hostname,
		MAC:              &mac,
		DiscoverySources: []string{"snmp"},
		IsAvailable:      true,
		FirstSeen:        now.Add(-time.Hour),
		LastSeen:         now,
		DeviceType:       "router",
		Metadata: map[string]string{
			"region": "us-west-2",
		},
	}

	device := OCSFDeviceFromRecord(record)
	require.NotNil(t, device)
	assert.Equal(t, record.DeviceID, device.UID)
	assert.Equal(t, record.IP, device.IP)
	assert.Equal(t, hostname, device.Hostname)
	assert.Equal(t, mac, device.MAC)
	require.NotNil(t, device.LastSeenTime)
	assert.Equal(t, record.LastSeen, *device.LastSeenTime)
	require.NotNil(t, device.FirstSeenTime)
	assert.Equal(t, record.FirstSeen, *device.FirstSeenTime)
	require.NotNil(t, device.IsAvailable)
	assert.True(t, *device.IsAvailable)
	assert.Equal(t, "router", device.Type)
	assert.Equal(t, models.OCSFDeviceTypeRouter, device.TypeID)
	require.Len(t, device.DiscoverySources, 1)
	assert.Equal(t, "snmp", device.DiscoverySources[0])
	assert.Equal(t, "us-west-2", device.Metadata["region"])
}

func TestOCSFDeviceFromRecordNil(t *testing.T) {
	if device := OCSFDeviceFromRecord(nil); device != nil {
		t.Fatalf("expected nil device, got %#v", device)
	}
}

func TestOCSFDeviceSlice(t *testing.T) {
	now := time.Now().UTC()
	hostname := "host1"
	records := []*DeviceRecord{
		{
			DeviceID:    "device-1",
			IP:          "10.0.0.1",
			Hostname:    &hostname,
			IsAvailable: true,
			FirstSeen:   now.Add(-time.Hour),
			LastSeen:    now,
		},
		{
			DeviceID:    "device-2",
			IP:          "10.0.0.2",
			IsAvailable: false,
			FirstSeen:   now.Add(-2 * time.Hour),
			LastSeen:    now.Add(-30 * time.Minute),
		},
		nil, // should be skipped
	}

	devices := OCSFDeviceSlice(records)
	require.Len(t, devices, 2)
	assert.Equal(t, "device-1", devices[0].UID)
	assert.Equal(t, "device-2", devices[1].UID)
}

func TestOCSFDeviceSliceEmpty(t *testing.T) {
	assert.Nil(t, OCSFDeviceSlice(nil))
	assert.Nil(t, OCSFDeviceSlice([]*DeviceRecord{}))
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

func TestInferTypeIDFromName(t *testing.T) {
	tests := []struct {
		name     string
		expected int
	}{
		{"server", models.OCSFDeviceTypeServer},
		{"Server", models.OCSFDeviceTypeServer},
		{"SERVER", models.OCSFDeviceTypeServer},
		{"desktop", models.OCSFDeviceTypeDesktop},
		{"laptop", models.OCSFDeviceTypeLaptop},
		{"tablet", models.OCSFDeviceTypeTablet},
		{"mobile", models.OCSFDeviceTypeMobile},
		{"virtual", models.OCSFDeviceTypeVirtual},
		{"iot", models.OCSFDeviceTypeIOT},
		{"browser", models.OCSFDeviceTypeBrowser},
		{"firewall", models.OCSFDeviceTypeFirewall},
		{"switch", models.OCSFDeviceTypeSwitch},
		{"hub", models.OCSFDeviceTypeHub},
		{"router", models.OCSFDeviceTypeRouter},
		{"ids", models.OCSFDeviceTypeIDS},
		{"ips", models.OCSFDeviceTypeIPS},
		{"load balancer", models.OCSFDeviceTypeLoadBalancer},
		{"other", models.OCSFDeviceTypeOther},
		{"unknown", models.OCSFDeviceTypeUnknown},
		{"", models.OCSFDeviceTypeUnknown},
		{"random", models.OCSFDeviceTypeUnknown},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.expected, inferTypeIDFromName(tc.name))
		})
	}
}
