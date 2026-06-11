package main

import "testing"

// TestPrimaryIPPrefersConfiguredNIC reproduces a Kubernetes node: the guest
// agent reports the real NIC (ens18/net0) alongside kube-ipvs0 (ClusterIP VIPs)
// and a calico veth. The configured NIC is intentionally placed LAST so the old
// "first usable IP in interface order" logic would have returned a ClusterIP
// VIP. primaryIP must deterministically pick the configured NIC's address.
func TestPrimaryIPPrefersConfiguredNIC(t *testing.T) {
	interfaces := []proxmoxGuestNetworkInterface{
		{Name: "lo", IPAddresses: []string{"127.0.0.1"}},
		{Name: "kube-ipvs0", MACAddress: "ba:af:15:b4:ef:e7", IPAddresses: []string{"10.43.72.27", "10.43.0.1"}},
		{Name: "calia71fc5b4a95", MACAddress: "ee:ee:ee:ee:ee:ee", IPAddresses: []string{"169.254.0.179"}},
		{Name: "ens18", ConfigKey: "net0", MACAddress: "BC:24:11:A2:CD:85", IPAddresses: []string{"10.0.2.9/24"}},
	}

	if got := primaryIP(interfaces); got != "10.0.2.9" {
		t.Fatalf("primaryIP = %q, want 10.0.2.9 (the configured NIC, not a ClusterIP VIP)", got)
	}

	if got := primaryMAC(interfaces); got != "BC:24:11:A2:CD:85" {
		t.Fatalf("primaryMAC = %q, want the configured NIC MAC", got)
	}
}

// TestPrimaryIPFallsBackWhenNoConfiguredNIC ensures non-Kubernetes guests (no
// ConfigKey on any interface) still resolve an IP via the fallback path.
func TestPrimaryIPFallsBackWhenNoConfiguredNIC(t *testing.T) {
	interfaces := []proxmoxGuestNetworkInterface{
		{Name: "lo", IPAddresses: []string{"127.0.0.1"}},
		{Name: "eth0", MACAddress: "aa:bb:cc:dd:ee:ff", IPAddresses: []string{"192.168.5.10"}},
	}

	if got := primaryIP(interfaces); got != "192.168.5.10" {
		t.Fatalf("primaryIP = %q, want 192.168.5.10 (fallback)", got)
	}
}
