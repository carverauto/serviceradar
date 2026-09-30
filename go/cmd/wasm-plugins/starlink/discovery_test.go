package main

import (
	"strings"
	"testing"
	"time"
)

var testObservedAt = time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC)

func snapshotFixture(complete bool) *inventorySnapshot {
	return &inventorySnapshot{
		Account:  account{Number: testAccountNumber},
		Complete: complete,
		Terminals: []terminal{
			{
				ID: testTerminalA, Nickname: "Unit A", KitSerial: "KITTEST0000001", ServiceLine: testServiceLine,
				Routers: []router{{ID: testRouterA, Nickname: "Router A", TerminalID: testTerminalA}},
			},
			// The same router reported under a second terminal (a transient
			// upstream inconsistency) must still yield one router device.
			{ID: testTerminalB, Routers: []router{{ID: testRouterA, TerminalID: testTerminalB}}},
		},
		ServiceLines: map[string]serviceLine{
			testServiceLine: {Number: testServiceLine, Product: "example-product", Active: true},
		},
	}
}

func TestBuildDiscoveryIdentityAndMetadata(t *testing.T) {
	d := buildDiscovery(snapshotFixture(true), testObservedAt)

	if d.Source != sourceName || len(d.Devices) != 3 {
		t.Fatalf("source %q devices %d, want starlink with 3 devices", d.Source, len(d.Devices))
	}
	if d.Metadata["snapshot_complete"] != true {
		t.Fatalf("snapshot_complete = %v", d.Metadata["snapshot_complete"])
	}
	instance, _ := d.Metadata["source_instance"].(string)
	if instance == "" || strings.Contains(instance, testAccountNumber) {
		t.Fatalf("source_instance must be set and must not expose the account number: %q", instance)
	}

	for _, dev := range d.Devices {
		if dev.Metadata["integration_id"] != dev.DeviceID {
			t.Fatalf("integration_id %v must equal device_id %q", dev.Metadata["integration_id"], dev.DeviceID)
		}
		if !strings.HasPrefix(dev.DeviceID, "starlink:") {
			t.Fatalf("device id %q not source-prefixed", dev.DeviceID)
		}
		if dev.IP != "" || dev.MAC != "" {
			t.Fatalf("addresses must never be emitted as identity: %+v", dev)
		}
	}

	terminalA := d.Devices[0]
	if terminalA.DeviceID != "starlink:ut:"+testTerminalA || terminalA.Status != "active" {
		t.Fatalf("terminal A = %+v", terminalA)
	}
	if terminalA.Metadata["product_reference_id"] != "example-product" {
		t.Fatalf("service line metadata missing: %v", terminalA.Metadata)
	}
	if terminalB := d.Devices[2]; terminalB.Status != "no_service_line" {
		t.Fatalf("terminal B status = %q", terminalB.Status)
	}
	if _, blank := d.Devices[2].Metadata["nickname"]; blank {
		t.Fatal("empty values must be dropped from metadata")
	}
}

func TestBuildDiscoveryIncompleteSnapshot(t *testing.T) {
	d := buildDiscovery(snapshotFixture(false), testObservedAt)
	if d.Metadata["snapshot_complete"] != false {
		t.Fatal("incomplete inventory must not be presented as a complete snapshot")
	}
}

func TestBuildDiscoveryHashStable(t *testing.T) {
	a := buildDiscovery(snapshotFixture(true), testObservedAt)
	b := buildDiscovery(snapshotFixture(true), testObservedAt.Add(time.Hour))
	if a.ReferenceHash != b.ReferenceHash || a.CollectionID != b.CollectionID {
		t.Fatal("unchanged inventory must hash identically regardless of observation time")
	}
	changed := snapshotFixture(true)
	changed.Terminals[0].Nickname = "Unit A renamed"
	if buildDiscovery(changed, testObservedAt).ReferenceHash == a.ReferenceHash {
		t.Fatal("a renamed terminal must change the reference hash")
	}
}
