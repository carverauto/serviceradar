package main

import (
	"reflect"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func TestClusterScopeName(t *testing.T) {
	clustered := []proxmoxClusterNode{
		{ID: "cluster/lab", Name: "lab", Type: "cluster"},
		{ID: "node/pve-a", Type: "node"},
	}

	if got := clusterScopeName(clustered, nil, "pve-a"); got != "lab" {
		t.Fatalf("clustered scope = %q, want lab", got)
	}

	// Standalone node: no cluster entry and the cluster-status fetch succeeded
	// (no warning), so the node name is the scope.
	if got := clusterScopeName(nil, map[string]string{}, "pve1"); got != "pve1" {
		t.Fatalf("standalone scope = %q, want pve1", got)
	}

	// Cluster-status fetch failed: we cannot tell standalone from clustered, so
	// no scope is minted and the caller falls back to the provider ref.
	failed := map[string]string{"cluster_status": "timeout"}
	if got := clusterScopeName(nil, failed, "pve1"); got != "" {
		t.Fatalf("failed-status scope = %q, want empty", got)
	}
}

func TestProxmoxClusterNameFallsBackToID(t *testing.T) {
	if got := proxmoxClusterName([]proxmoxClusterNode{{ID: "cluster/lab", Type: "cluster"}}); got != "cluster/lab" {
		t.Fatalf("cluster name = %q, want cluster/lab (id fallback)", got)
	}

	if got := proxmoxClusterName([]proxmoxClusterNode{{Type: "node", Name: "pve-a"}}); got != "" {
		t.Fatalf("cluster name = %q, want empty when no cluster entry", got)
	}
}

func TestProxmoxSegmentNormalizes(t *testing.T) {
	cases := map[string]string{
		"Lab":        "lab",
		"My Cluster": "my-cluster",
		"a::b  c":    "a-b-c",
		"pve-a":      "pve-a",
	}

	for in, want := range cases {
		if got := proxmoxSegment(in); got != want {
			t.Fatalf("segment(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestProxmoxGuestV2ID(t *testing.T) {
	if got := proxmoxGuestV2ID("Lab", "qemu", 100); got != "proxmox:v2:lab:vm:100" {
		t.Fatalf("qemu v2 = %q", got)
	}
	if got := proxmoxGuestV2ID("lab", "lxc", 200); got != "proxmox:v2:lab:lxc:200" {
		t.Fatalf("lxc v2 = %q", got)
	}
	// No scope -> no id.
	if got := proxmoxGuestV2ID("", "qemu", 100); got != "" {
		t.Fatalf("empty scope should not mint, got %q", got)
	}
	// Zero/unset vmid must not mint (it would collapse distinct guests onto
	// :vm:0).
	if got := proxmoxGuestV2ID("lab", "qemu", 0); got != "" {
		t.Fatalf("zero vmid should not mint, got %q", got)
	}
}

func TestProxmoxNodeV2ID(t *testing.T) {
	if got := proxmoxNodeV2ID("lab", "pve-a"); got != "proxmox:v2:lab:node:pve-a" {
		t.Fatalf("node v2 = %q", got)
	}
	if got := proxmoxNodeV2ID("", "pve-a"); got != "" {
		t.Fatalf("empty scope should not mint, got %q", got)
	}
}

func TestProxmoxGuestIntegrationIDFallsBackToProviderRef(t *testing.T) {
	guest := proxmoxResource{ID: "qemu/100", Node: "pve-a", Type: "qemu", VMID: 100}

	// Scope known -> v2.
	if got := proxmoxGuestIntegrationID(guest, "lab"); got != "proxmox:v2:lab:vm:100" {
		t.Fatalf("v2 integration id = %q", got)
	}
	// Scope unknown -> node+vmid provider ref (never a bare name).
	if got := proxmoxGuestIntegrationID(guest, ""); got != "proxmox:guest:pve-a:qemu:100" {
		t.Fatalf("provider ref integration id = %q", got)
	}
	// No node and no scope -> "" so the ingestor falls back to its own minting.
	if got := proxmoxGuestIntegrationID(proxmoxResource{Type: "qemu", VMID: 100}, ""); got != "" {
		t.Fatalf("no-node integration id = %q, want empty", got)
	}
}

func TestProxmoxNodeIntegrationID(t *testing.T) {
	if got := proxmoxNodeIntegrationID("pve-a", "lab"); got != "proxmox:v2:lab:node:pve-a" {
		t.Fatalf("node v2 integration id = %q", got)
	}
	if got := proxmoxNodeIntegrationID("pve-a", ""); got != "proxmox:node:pve-a" {
		t.Fatalf("node provider ref = %q", got)
	}
}

func TestProxmoxGuestLegacyIDsBridgesVmidNotName(t *testing.T) {
	guest := proxmoxResource{ID: "qemu/100", Node: "pve-a", Name: "web01", Type: "qemu", VMID: 100}
	integrationID := "proxmox:v2:lab:vm:100"
	macs := []string{"BC:24:11:76:DF:7E"}

	legacy := proxmoxGuestLegacyIDs(guest, integrationID, macs)

	mustContain(t, legacy,
		"proxmox:guest:pve-a:qemu:100", // provider ref (node+vmid scoped)
		"proxmox:qemu:pve-a:100",
		"proxmox:vm:pve-a:100",
		"proxmox:qemu:100",
		"proxmox:vm:100",
		"proxmox:vm:qemu/100",          // gen-1 id-as-name (vmid scoped)
		"proxmox:vm:BC:24:11:76:DF:7E", // gen-2 mac-keyed
	)

	// The pure guest-name form must NOT be a bridge: names are not unique
	// across clusters and bridging on one would risk collapsing distinct guests.
	mustNotContain(t, legacy, "proxmox:vm:web01")

	// The canonical id itself is never repeated as a legacy bridge.
	mustNotContain(t, legacy, integrationID)
}

func TestProxmoxGuestLegacyIDsLXC(t *testing.T) {
	guest := proxmoxResource{ID: "lxc/201", Node: "pve-a", Name: "traefik", Type: "lxc", VMID: 201}
	legacy := proxmoxGuestLegacyIDs(guest, "proxmox:v2:lab:lxc:201", nil)

	mustContain(t, legacy,
		"proxmox:guest:pve-a:lxc:201",
		"proxmox:lxc:pve-a:201",
		"proxmox:container:pve-a:201",
		"proxmox:lxc:201",
		"proxmox:container:201",
		"proxmox:container:lxc/201",
	)
	mustNotContain(t, legacy, "proxmox:container:traefik")
}

func TestProxmoxNodeLegacyIDs(t *testing.T) {
	legacy := proxmoxNodeLegacyIDs("pve-a", "pve-a.example", "proxmox:v2:lab:node:pve-a")

	mustContain(t, legacy,
		"proxmox:node:pve-a",
		"proxmox:pve:pve-a",
		"proxmox:hypervisor:pve-a",
		"proxmox:hypervisor:pve-a.example",
	)
}

func TestConfiguredGuestMACsExcludesUnconfiguredNICs(t *testing.T) {
	interfaces := []proxmoxGuestNetworkInterface{
		{ConfigKey: "net0", MACAddress: "BC:24:11:76:DF:7E"},
		{ConfigKey: "net1", MACAddress: "bc-24-11-aa-bb-cc"},
		// Guest-agent CNI interface (no config key) must be excluded so its
		// ephemeral/locally-administered MAC never becomes an identifier.
		{ConfigKey: "", Name: "cali123", MACAddress: "EE:EE:EE:EE:EE:EE"},
		// Duplicate of net0 in a different format -> deduped.
		{ConfigKey: "net2", MACAddress: "BC241176DF7E"},
	}

	got := configuredGuestMACs(interfaces)
	want := []string{"BC:24:11:76:DF:7E", "BC:24:11:AA:BB:CC"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("configuredGuestMACs = %#v, want %#v", got, want)
	}
}

func TestNodeManagementMACs(t *testing.T) {
	node := proxmoxNode{
		Network: []proxmoxNetworkInterface{
			{Iface: "eno1", MACAddress: "AA:BB:CC:00:11:22"},
			{Iface: "vmbr0", MACAddress: "aa:bb:cc:00:11:22"}, // bridge clones eno1 -> dedup
			{Iface: "lo"}, // no MAC
		},
	}

	got := nodeManagementMACs(node)
	want := []string{"AA:BB:CC:00:11:22"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("nodeManagementMACs = %#v, want %#v", got, want)
	}
}

func TestProxmoxDeviceMetadataNilWhenEmpty(t *testing.T) {
	if md := proxmoxDeviceMetadata("", nil, nil); md != nil {
		t.Fatalf("expected nil metadata, got %#v", md)
	}

	md := proxmoxDeviceMetadata("proxmox:v2:lab:vm:100", []string{"proxmox:vm:100"}, []string{"BC:24:11:76:DF:7E"})
	if md["integration_id"] != "proxmox:v2:lab:vm:100" {
		t.Fatalf("integration_id = %#v", md["integration_id"])
	}
	if _, ok := md["legacy_integration_ids"].([]string); !ok {
		t.Fatalf("legacy_integration_ids type = %T", md["legacy_integration_ids"])
	}
	if _, ok := md["mac_addresses"].([]string); !ok {
		t.Fatalf("mac_addresses type = %T", md["mac_addresses"])
	}
}

func TestAddGuestDiscoveriesEmitsCanonicalIdentity(t *testing.T) {
	discovery := sdk.NewDeviceDiscovery(discoverySource)

	guests := []proxmoxGuest{
		{
			proxmoxResource: proxmoxResource{ID: "qemu/100", Node: "pve-a", Name: "web01", Type: "qemu", VMID: 100, Status: "running"},
			Interfaces: []proxmoxGuestNetworkInterface{
				{ConfigKey: "net0", MACAddress: "BC:24:11:76:DF:7E", IPAddresses: []string{"192.168.2.15/24"}},
				{ConfigKey: "", Name: "cali9", MACAddress: "EE:EE:EE:EE:EE:EE", IPAddresses: []string{"10.42.0.5"}},
			},
		},
	}

	addGuestDiscoveries(discovery, guests, []proxmoxClusterNode{{Name: "lab", Type: "cluster"}}, nil)

	if len(discovery.Devices) != 1 {
		t.Fatalf("expected one guest device, got %d", len(discovery.Devices))
	}

	device := discovery.Devices[0]
	if device.Metadata["integration_id"] != "proxmox:v2:lab:vm:100" {
		t.Fatalf("guest integration_id = %#v", device.Metadata["integration_id"])
	}

	macs, _ := device.Metadata["mac_addresses"].([]string)
	if !reflect.DeepEqual(macs, []string{"BC:24:11:76:DF:7E"}) {
		t.Fatalf("guest mac_addresses = %#v (CNI MAC must be excluded)", macs)
	}

	legacy, _ := device.Metadata["legacy_integration_ids"].([]string)
	mustNotContain(t, legacy, "proxmox:vm:web01")
}

func TestAddNodeDiscoveriesEmitsHostMacs(t *testing.T) {
	discovery := sdk.NewDeviceDiscovery(discoverySource)

	addNodeDiscoveries(discovery, Target{}, []proxmoxNode{
		{
			Node:   "pve-a",
			Status: "online",
			IP:     "192.0.2.10/24",
			Network: []proxmoxNetworkInterface{
				{Iface: "vmbr0", MACAddress: "AA:BB:CC:00:11:22"},
			},
		},
	}, []proxmoxClusterNode{{Name: "lab", Type: "cluster"}}, nil)

	device := discovery.Devices[0]
	if device.Metadata["integration_id"] != "proxmox:v2:lab:node:pve-a" {
		t.Fatalf("node integration_id = %#v", device.Metadata["integration_id"])
	}
	if device.MAC != "AA:BB:CC:00:11:22" {
		t.Fatalf("node MAC = %q, want the host NIC MAC", device.MAC)
	}
	macs, _ := device.Metadata["mac_addresses"].([]string)
	if !reflect.DeepEqual(macs, []string{"AA:BB:CC:00:11:22"}) {
		t.Fatalf("node mac_addresses = %#v", macs)
	}
}

func mustContain(t *testing.T, values []string, wanted ...string) {
	t.Helper()

	set := make(map[string]bool, len(values))
	for _, v := range values {
		set[v] = true
	}

	for _, w := range wanted {
		if !set[w] {
			t.Fatalf("expected %q in %#v", w, values)
		}
	}
}

func mustNotContain(t *testing.T, values []string, unwanted ...string) {
	t.Helper()

	for _, v := range values {
		for _, u := range unwanted {
			if v == u {
				t.Fatalf("did not expect %q in %#v", u, values)
			}
		}
	}
}
