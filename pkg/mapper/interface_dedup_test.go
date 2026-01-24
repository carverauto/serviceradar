package mapper

import "testing"

func TestUpsertInterfaceMergesByDeviceIPAndIdentifier(t *testing.T) {
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{Interfaces: []*DiscoveredInterface{}},
	}

	first := &DiscoveredInterface{
		DeviceIP:    "10.0.0.1",
		DeviceID:    "dev-1",
		IfIndex:     1,
		IfName:      "eth0",
		IPAddresses: []string{"10.0.0.1"},
		Metadata: map[string]string{
			"source": "snmp",
		},
		AvailableMetrics: []InterfaceMetric{{
			Name: "ifInOctets",
			OID:  ".1.2.3",
		}},
	}

	second := &DiscoveredInterface{
		DeviceIP:    "10.0.0.2",
		DeviceID:    "dev-1",
		IfIndex:     1,
		IfAlias:     "uplink",
		IPAddresses: []string{"10.0.0.2"},
		Metadata: map[string]string{
			"source": "api",
		},
		AvailableMetrics: []InterfaceMetric{
			{
				Name: "ifInOctets",
				OID:  ".9.9.9",
			},
			{
				Name: "ifOutOctets",
				OID:  ".1.2.4",
			},
		},
	}

	engine.upsertInterface(job, first)
	engine.upsertInterface(job, second)

	if len(job.Results.Interfaces) != 1 {
		t.Fatalf("expected 1 merged interface, got %d", len(job.Results.Interfaces))
	}

	merged := job.Results.Interfaces[0]
	if merged.IfAlias != "uplink" {
		t.Fatalf("expected alias to be merged, got %q", merged.IfAlias)
	}

	if merged.DeviceID != "dev-1" {
		t.Fatalf("expected device_id to remain canonical, got %q", merged.DeviceID)
	}

	if !containsString(merged.IPAddresses, "10.0.0.1") || !containsString(merged.IPAddresses, "10.0.0.2") {
		t.Fatalf("expected merged IP addresses, got %#v", merged.IPAddresses)
	}

	if len(merged.AvailableMetrics) != 2 {
		t.Fatalf("expected 2 metrics after merge, got %d", len(merged.AvailableMetrics))
	}

	metric := findMetric(merged.AvailableMetrics, "ifInOctets")
	if metric == nil || metric.OID != ".9.9.9" {
		t.Fatalf("expected ifInOctets metric to be updated, got %#v", metric)
	}
}

func TestInterfaceDedupKeyPrefersDeviceID(t *testing.T) {
	iface := &DiscoveredInterface{
		DeviceID: "dev-only",
		IfName:   "eth9",
	}

	key := interfaceDedupKey(iface)
	if key != "dev-only|ifname:eth9" {
		t.Fatalf("unexpected dedup key %q", key)
	}
}

func TestInterfaceDedupKeyFallsBackToDeviceIP(t *testing.T) {
	iface := &DiscoveredInterface{
		DeviceIP: "10.0.0.9",
		IfName:   "eth9",
	}

	key := interfaceDedupKey(iface)
	if key != "10.0.0.9|ifname:eth9" {
		t.Fatalf("unexpected dedup key %q", key)
	}
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func findMetric(metrics []InterfaceMetric, name string) *InterfaceMetric {
	for i := range metrics {
		if metrics[i].Name == name {
			return &metrics[i]
		}
	}
	return nil
}
