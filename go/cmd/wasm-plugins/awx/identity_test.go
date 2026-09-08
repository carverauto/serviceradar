package main

import (
	"reflect"
	"testing"
)

func TestAWXIntegrationIDIsControllerScoped(t *testing.T) {
	// The whole point: two hosts named the same on different controllers must
	// not collapse. Under the old hostname-derived key both minted
	// "awx:host:pve01".
	a := awxIntegrationID("farm01", 7)
	b := awxIntegrationID("tonka01", 7)

	if a != "awx:v2:farm01:host:7" {
		t.Fatalf("unexpected integration id: %q", a)
	}

	if a == b {
		t.Fatalf("controllers must not share an integration id: %q", a)
	}

	if got := awxIntegrationID("", 7); got != "" {
		t.Fatalf("blank controller must not mint an id, got %q", got)
	}

	if got := awxIntegrationID("farm01", 0); got != "" {
		t.Fatalf("missing host id must not mint an id, got %q", got)
	}
}

func TestAWXLegacyIDsBridgeTheHostnameKey(t *testing.T) {
	// buildDiscoveredHost substitutes ansible_host when the AWX name is blank,
	// so both spellings have to be offered or the existing row will not bridge.
	got := awxLegacyIDs("db01.example.org", "db01", "awx:v2:farm01:host:7")
	want := []string{"awx:host:db01.example.org", "awx:host:db01"}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("legacy ids = %#v, want %#v", got, want)
	}

	// Identical names collapse to one entry.
	if got := awxLegacyIDs("db01", "db01", "awx:v2:farm01:host:7"); len(got) != 1 {
		t.Fatalf("duplicate names must dedupe, got %#v", got)
	}

	// A legacy key equal to the canonical one is never emitted.
	if got := awxLegacyIDs("x", "x", "awx:host:x"); len(got) != 0 {
		t.Fatalf("canonical id must not be listed as legacy, got %#v", got)
	}
}

func TestAWXHostMACsFromProxmoxConfigString(t *testing.T) {
	vars := `{"ansible_host":"192.168.2.44",
	          "proxmox_net0":"virtio=BC:24:11:53:84:67,bridge=vmbr0,tag=10",
	          "proxmox_net1":"virtio=bc:24:11:d4:f6:81,bridge=vmbr1"}`

	got := awxHostMACs(vars)
	want := []string{"BC:24:11:53:84:67", "BC:24:11:D4:F6:81"}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("macs = %#v, want %#v", got, want)
	}
}

func TestAWXHostMACsFromMapping(t *testing.T) {
	vars := `{"proxmox_net0":{"hwaddr":"bc-24-11-53-84-67","bridge":"vmbr0"}}`

	got := awxHostMACs(vars)
	if !reflect.DeepEqual(got, []string{"BC:24:11:53:84:67"}) {
		t.Fatalf("macs = %#v", got)
	}
}

func TestAWXHostMACsIgnoresEverythingElse(t *testing.T) {
	cases := map[string]string{
		"empty":            "",
		"yaml not json":    "ansible_host: 10.0.0.1\n",
		"malformed json":   `{"proxmox_net0":`,
		"no nic keys":      `{"ansible_host":"10.0.0.1","ansible_user":"root"}`,
		"invalid mac":      `{"proxmox_net0":"virtio=not-a-mac,bridge=vmbr0"}`,
		"non-contiguous":   `{"proxmox_net1":"virtio=BC:24:11:53:84:67"}`,
		"loopback listing": `{"proxmox_lxc_interfaces":[{"name":"lo","hwaddr":"00:00:00:00:00:00"}]}`,
	}

	for name, vars := range cases {
		t.Run(name, func(t *testing.T) {
			if got := awxHostMACs(vars); len(got) != 0 {
				t.Fatalf("expected no macs, got %#v", got)
			}
		})
	}
}

func TestAWXHostMACsDedupes(t *testing.T) {
	vars := `{"proxmox_net0":"virtio=BC:24:11:53:84:67","proxmox_net1":"virtio=bc:24:11:53:84:67"}`

	if got := awxHostMACs(vars); len(got) != 1 {
		t.Fatalf("expected one deduped mac, got %#v", got)
	}
}

func TestBuildDiscoveredHostEmitsIdentityChannels(t *testing.T) {
	cfg := InventorySyncControllerConfig{ControllerID: "farm01", ControllerName: "Farm"}
	inv := awxInventoryRow{ID: 3, Name: "prod"}
	host := awxHostRow{
		ID:        7,
		Name:      "ns01",
		Enabled:   true,
		Variables: `{"ansible_host":"192.168.2.44","proxmox_net0":"virtio=BC:24:11:53:84:67"}`,
	}

	device := buildDiscoveredHost(cfg, inv, host)

	if got := device.Metadata["integration_id"]; got != "awx:v2:farm01:host:7" {
		t.Fatalf("integration_id = %#v", got)
	}

	legacy, ok := device.Metadata["legacy_integration_ids"].([]string)
	if !ok || len(legacy) != 1 || legacy[0] != "awx:host:ns01" {
		t.Fatalf("legacy_integration_ids = %#v", device.Metadata["legacy_integration_ids"])
	}

	macs, ok := device.Metadata["mac_addresses"].([]string)
	if !ok || !reflect.DeepEqual(macs, []string{"BC:24:11:53:84:67"}) {
		t.Fatalf("mac_addresses = %#v", device.Metadata["mac_addresses"])
	}

	// The AWX join block the reconciler resolves against must survive intact.
	awxBlock, ok := device.Metadata["awx"].(map[string]any)
	if !ok || awxBlock["host_id"] != 7 || awxBlock["controller_id"] != "farm01" {
		t.Fatalf("awx metadata block = %#v", device.Metadata["awx"])
	}
}

// Hosts from static or SCM inventories carry no NIC data anywhere. They must
// still get a source key, and must NOT get a fabricated hardware anchor -- there
// is no honest way to link those to an agent-discovered twin.
func TestBuildDiscoveredHostWithoutNICDataEmitsNoMAC(t *testing.T) {
	cfg := InventorySyncControllerConfig{ControllerID: "farm01"}
	host := awxHostRow{ID: 9, Name: "sr-win-test01", Variables: `{"ansible_host":"192.168.2.126"}`}

	device := buildDiscoveredHost(cfg, awxInventoryRow{ID: 1}, host)

	if _, present := device.Metadata["mac_addresses"]; present {
		t.Fatalf("must not invent a MAC: %#v", device.Metadata["mac_addresses"])
	}

	if got := device.Metadata["integration_id"]; got != "awx:v2:farm01:host:9" {
		t.Fatalf("integration_id = %#v", got)
	}
}
