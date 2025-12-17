package registry

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
)

const (
	testRegionUSEast1 = "us-east-1"
	testDeviceID1     = "device-1"
)

func newTestDeviceRegistry() *DeviceRegistry {
	return NewDeviceRegistry(nil, logger.NewTestLogger())
}

func TestUpsertAndGetDeviceRecord(t *testing.T) {
	reg := newTestDeviceRegistry()

	hostname := "edge-gw-01"
	mac := "00:11:22:33:44:55"
	integrationID := "armis:1234"
	capabilities := []string{"icmp", "snmp"}
	metadata := map[string]string{"region": testRegionUSEast1}
	firstSeen := time.Unix(1700000000, 0).UTC()
	lastSeen := time.Unix(1700003600, 0).UTC()

	reg.UpsertDeviceRecord(&DeviceRecord{
		DeviceID:         testDeviceID1,
		IP:               "10.0.0.10",
		PollerID:         "poller-a",
		AgentID:          "agent-a",
		Hostname:         &hostname,
		MAC:              &mac,
		DiscoverySources: []string{"sweep", "netbox"},
		IsAvailable:      true,
		FirstSeen:        firstSeen,
		LastSeen:         lastSeen,
		DeviceType:       "router",
		IntegrationID:    &integrationID,
		Capabilities:     capabilities,
		Metadata:         metadata,
	})

	got, ok := reg.GetDeviceRecord(testDeviceID1)
	if !ok {
		t.Fatalf("expected device to be found")
	}

	if got == nil || got.DeviceID != testDeviceID1 {
		t.Fatalf("unexpected device returned: %#v", got)
	}

	if got.Hostname == nil || *got.Hostname != hostname {
		t.Fatalf("expected hostname %q, got %#v", hostname, got.Hostname)
	}

	// Mutate the returned copy to ensure registry state is unaffected.
	got.Metadata["region"] = "us-west-2"
	got.Capabilities[0] = "http"
	newHostname := "mutated"
	got.Hostname = &newHostname

	original, ok := reg.GetDeviceRecord(testDeviceID1)
	if !ok {
		t.Fatalf("expected device to remain in registry")
	}
	if original.Metadata["region"] != testRegionUSEast1 {
		t.Fatalf("expected original metadata to remain unchanged, got %q", original.Metadata["region"])
	}
	if original.Capabilities[0] != "icmp" {
		t.Fatalf("expected original capabilities to remain unchanged, got %q", original.Capabilities[0])
	}
	if original.Hostname == nil || *original.Hostname != hostname {
		t.Fatalf("expected original hostname to remain %q, got %#v", hostname, original.Hostname)
	}
}

func TestCloneDeviceRecord_EmptyMetadataMapDoesNotAlias(t *testing.T) {
	original := &DeviceRecord{
		DeviceID: testDeviceID1,
		IP:       "10.0.0.1",
		Metadata: map[string]string{},
	}

	clone1 := cloneDeviceRecord(original)
	if clone1 == nil {
		t.Fatalf("expected clone to be non-nil")
	}

	clone1.Metadata["k"] = "v1"

	if len(original.Metadata) != 0 {
		t.Fatalf("expected original metadata to remain empty, got %#v", original.Metadata)
	}

	clone2 := cloneDeviceRecord(original)
	if clone2 == nil {
		t.Fatalf("expected second clone to be non-nil")
	}
	if _, ok := clone2.Metadata["k"]; ok {
		t.Fatalf("expected second clone metadata to not include prior clone mutation, got %#v", clone2.Metadata)
	}
}

func TestCloneDeviceRecord_EmptySlicesWithCapacityDoNotAlias(t *testing.T) {
	original := &DeviceRecord{
		DeviceID:         testDeviceID1,
		IP:               "10.0.0.1",
		DiscoverySources: make([]string, 0, 1),
		Capabilities:     make([]string, 0, 1),
	}

	clone1 := cloneDeviceRecord(original)
	if clone1 == nil {
		t.Fatalf("expected clone to be non-nil")
	}
	clone1.DiscoverySources = append(clone1.DiscoverySources, "a")
	clone1.Capabilities = append(clone1.Capabilities, "icmp")

	clone2 := cloneDeviceRecord(original)
	if clone2 == nil {
		t.Fatalf("expected second clone to be non-nil")
	}
	clone2.DiscoverySources = append(clone2.DiscoverySources, "b")
	clone2.Capabilities = append(clone2.Capabilities, "snmp")

	if got := clone1.DiscoverySources[0]; got != "a" {
		t.Fatalf("expected clone1 discovery source to remain %q, got %q", "a", got)
	}
	if got := clone1.Capabilities[0]; got != "icmp" {
		t.Fatalf("expected clone1 capability to remain %q, got %q", "icmp", got)
	}
}

func TestUpsertUpdatesIndexes(t *testing.T) {
	reg := newTestDeviceRegistry()

	device := &DeviceRecord{
		DeviceID: "device-2",
		IP:       "10.0.0.20",
	}
	reg.UpsertDeviceRecord(device)

	device.IP = "10.0.0.30"
	reg.UpsertDeviceRecord(device)

	if got := reg.FindDevicesByIP("10.0.0.20"); len(got) != 0 {
		t.Fatalf("expected old IP index to be cleared, found %d records", len(got))
	}

	if got := reg.FindDevicesByIP("10.0.0.30"); len(got) != 1 {
		t.Fatalf("expected new IP index to contain record, found %d", len(got))
	}
}

func TestFindDevicesByIPMultiple(t *testing.T) {
	reg := newTestDeviceRegistry()

	reg.UpsertDeviceRecord(&DeviceRecord{DeviceID: "device-3", IP: "10.0.0.40"})
	reg.UpsertDeviceRecord(&DeviceRecord{DeviceID: "device-4", IP: "10.0.0.40"})

	results := reg.FindDevicesByIP("10.0.0.40")
	if len(results) != 2 {
		t.Fatalf("expected 2 results, got %d", len(results))
	}

	deviceIDs := map[string]struct{}{}
	for _, r := range results {
		deviceIDs[r.DeviceID] = struct{}{}
	}
	if _, ok := deviceIDs["device-3"]; !ok {
		t.Fatalf("expected device-3 in results")
	}
	if _, ok := deviceIDs["device-4"]; !ok {
		t.Fatalf("expected device-4 in results")
	}
}

func TestFindDevicesByMACAndDelete(t *testing.T) {
	reg := newTestDeviceRegistry()

	multiMAC := "00:AA:BB:CC:DD:EE, 00:AA:BB:CC:DD:FF"
	reg.UpsertDeviceRecord(&DeviceRecord{
		DeviceID: "device-5",
		MAC:      &multiMAC,
	})

	results := reg.FindDevicesByMAC("00:aa:bb:cc:dd:ee")
	if len(results) != 1 || results[0].DeviceID != "device-5" {
		t.Fatalf("expected lookup to return device-5, got %#v", results)
	}

	results = reg.FindDevicesByMAC("00:AA:BB:CC:DD:FF")
	if len(results) != 1 || results[0].DeviceID != "device-5" {
		t.Fatalf("expected lookup to return device-5 for second MAC, got %#v", results)
	}

	reg.DeleteDeviceRecord("device-5")

	if got := reg.FindDevicesByMAC("00:AA:BB:CC:DD:EE"); len(got) != 0 {
		t.Fatalf("expected MAC index to be cleared after delete, found %d", len(got))
	}
	if _, ok := reg.GetDeviceRecord("device-5"); ok {
		t.Fatalf("expected device to be removed from primary index")
	}
}
