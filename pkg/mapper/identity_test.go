package mapper

import "testing"

func TestGenerateDeviceIDNormalizesMAC(t *testing.T) {
	id1 := GenerateDeviceID("AA:BB:CC:DD:EE:FF")
	id2 := GenerateDeviceID("aa-bb-cc-dd-ee-ff")

	if id1 != "mac-aabbccddeeff" {
		t.Fatalf("unexpected normalized ID: %q", id1)
	}

	if id1 != id2 {
		t.Fatalf("expected equivalent MAC encodings to match: %q vs %q", id1, id2)
	}
}

func TestGenerateDeviceIDFromIPPrefix(t *testing.T) {
	id := GenerateDeviceIDFromIP("192.168.1.10")
	if id != "ip-192.168.1.10" {
		t.Fatalf("unexpected IP fallback ID: %q", id)
	}
}

func TestIsDeviceMatchFallsBackToMAC(t *testing.T) {
	engine := &DiscoveryEngine{}

	existing := &DiscoveredDevice{MAC: "AA:BB:CC:DD:EE:FF"}
	incoming := &DiscoveredDevice{MAC: "aa-bb-cc-dd-ee-ff"}

	if !engine.isDeviceMatch(existing, incoming) {
		t.Fatalf("expected normalized MAC match to be treated as same device")
	}
}

func TestIsDeviceMatchDoesNotMatchOnIPOnly(t *testing.T) {
	engine := &DiscoveryEngine{}

	existing := &DiscoveredDevice{IP: "192.168.1.1", DeviceID: "ip-192.168.1.1"}
	incoming := &DiscoveredDevice{IP: "192.168.1.2", DeviceID: "ip-192.168.1.2"}

	if engine.isDeviceMatch(existing, incoming) {
		t.Fatalf("did not expect IP-only identity mismatch to merge")
	}
}

func TestApplyTopologyEvidenceClassAssignsConfidenceTier(t *testing.T) {
	link := &TopologyLink{
		Protocol: "lldp",
		Metadata: map[string]string{},
	}

	applyTopologyEvidenceClass(link)

	if link.Metadata["evidence_class"] != "direct" {
		t.Fatalf("expected direct evidence class, got %q", link.Metadata["evidence_class"])
	}

	if link.Metadata["confidence_tier"] != "high" {
		t.Fatalf("expected high confidence tier, got %q", link.Metadata["confidence_tier"])
	}
}
