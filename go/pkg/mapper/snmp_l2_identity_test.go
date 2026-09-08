package mapper

import "testing"

func TestDescribeSNMPTarget(t *testing.T) {
	t.Parallel()

	if got := describeSNMPTarget("192.168.2.55", ""); got != "192.168.2.55" {
		t.Fatalf("expected bare IP, got %q", got)
	}

	if got := describeSNMPTarget("192.168.2.55", "Cisco SG 300-10MPP"); got != "192.168.2.55 (Cisco SG 300-10MPP)" {
		t.Fatalf("expected IP with hostname, got %q", got)
	}
}

func TestLookupKnownDeviceNameUsesPrimaryAndAliasIP(t *testing.T) {
	t.Parallel()

	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			Devices: []*DiscoveredDevice{
				{
					IP:       "152.117.116.178",
					Hostname: "farm01",
					Metadata: map[string]string{"alt_ip:192.168.1.1": "1"},
				},
				{
					IP:      "192.168.1.131",
					SysName: "USW Pro 24",
				},
			},
		},
	}

	if got := engine.lookupKnownDeviceName(job, "192.168.1.131"); got != "USW Pro 24" {
		t.Fatalf("expected sysName for primary IP, got %q", got)
	}

	if got := engine.lookupKnownDeviceName(job, "192.168.1.1"); got != "farm01" {
		t.Fatalf("expected hostname for alias IP, got %q", got)
	}

	if got := engine.lookupKnownDeviceName(job, "192.168.2.55"); got != "" {
		t.Fatalf("expected empty name for unknown IP, got %q", got)
	}
}
