package mapper

import "testing"

func TestRecursiveSNMPTargetsEnabledDefaultsFalse(t *testing.T) {
	if !recursiveSNMPTargetsEnabled(nil) {
		t.Fatal("expected nil job to enable recursive SNMP targets by default")
	}

	job := &DiscoveryJob{
		Params: &DiscoveryParams{},
	}

	if !recursiveSNMPTargetsEnabled(job) {
		t.Fatal("expected recursive SNMP targets to default enabled")
	}
}

func TestRecursiveSNMPTargetsEnabledHonorsJobOption(t *testing.T) {
	job := &DiscoveryJob{
		Params: &DiscoveryParams{
			Options: map[string]string{
				"recursive_snmp_targets_enabled": "true",
			},
		},
	}

	if !recursiveSNMPTargetsEnabled(job) {
		t.Fatal("expected recursive SNMP targets to enable from job option")
	}
}

func TestRecursiveSNMPTargetsEnabledHonorsFalseJobOption(t *testing.T) {
	job := &DiscoveryJob{
		Params: &DiscoveryParams{
			Options: map[string]string{
				"recursive_snmp_targets_enabled": "false",
			},
		},
	}

	if recursiveSNMPTargetsEnabled(job) {
		t.Fatal("expected recursive SNMP targets to disable from job option")
	}
}

func TestRecursiveTopologyLinkEligibleAcceptsDirectLLDP(t *testing.T) {
	link := &TopologyLink{
		Protocol: "LLDP",
		Metadata: map[string]string{},
	}

	if !recursiveTopologyLinkEligible(link) {
		t.Fatal("expected LLDP direct link to be recursive target eligible")
	}
}

func TestRecursiveTopologyLinkEligibleRejectsCandidateOnly(t *testing.T) {
	link := &TopologyLink{
		Protocol: "SNMP-L2",
		Metadata: map[string]string{
			"candidate_only": "true",
		},
	}

	if recursiveTopologyLinkEligible(link) {
		t.Fatal("expected candidate_only link to be ineligible for recursion")
	}
}

func TestRecursiveTopologyLinkEligibleRejectsEndpointAttachment(t *testing.T) {
	link := &TopologyLink{
		Protocol: "UniFi-API",
		Metadata: map[string]string{
			"evidence_class":  "inferred-segment",
			"relation_family": "ATTACHED_TO",
		},
	}

	if recursiveTopologyLinkEligible(link) {
		t.Fatal("expected endpoint attachment link to be ineligible for recursion")
	}
}

func TestRecursiveTopologyLinkEligibleRejectsWeakInference(t *testing.T) {
	link := &TopologyLink{
		Protocol: "SNMP-L2",
		Metadata: map[string]string{
			"source":            "snmp-arp-fdb",
			"confidence_reason": "single_identifier_inference",
			"evidence_class":    "inferred-segment",
			"relation_family":   "OBSERVED_TO",
		},
	}

	if recursiveTopologyLinkEligible(link) {
		t.Fatal("expected weak inference link to be ineligible for recursion")
	}
}

func TestCollectRecursiveSNMPTargetsUsesNeighborMgmtAddr(t *testing.T) {
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			TopologyLinks: []*TopologyLink{
				{
					Protocol:         "LLDP",
					Metadata:         map[string]string{},
					NeighborMgmtAddr: "192.168.10.10",
				},
			},
		},
	}

	targets := engine.collectRecursiveSNMPTargets(job, map[string]bool{})
	if !targets["192.168.10.10"] {
		t.Fatalf("expected recursive target 192.168.10.10, got %#v", targets)
	}
}

func TestCollectRecursiveSNMPTargetsResolvesNeighborIdentityToKnownDeviceIP(t *testing.T) {
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			Devices: []*DiscoveredDevice{
				{
					IP:       "192.168.1.233",
					MAC:      "d0:21:f9:b4:32:79",
					Hostname: "uap-nanohd.local",
				},
			},
			TopologyLinks: []*TopologyLink{
				{
					Protocol:           "LLDP",
					Metadata:           map[string]string{},
					NeighborChassisID:  "d0:21:f9:b4:32:79",
					NeighborSystemName: "UAP-nanoHD",
				},
			},
		},
	}

	targets := engine.collectRecursiveSNMPTargets(job, map[string]bool{})
	if !targets["192.168.1.233"] {
		t.Fatalf("expected recursive target resolved from identity, got %#v", targets)
	}
}

func TestCollectRecursiveSNMPTargetsSkipsKnownTargets(t *testing.T) {
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			Devices: []*DiscoveredDevice{
				{
					IP:       "192.168.1.233",
					MAC:      "d0:21:f9:b4:32:79",
					Hostname: "uap-nanohd",
				},
			},
			TopologyLinks: []*TopologyLink{
				{
					Protocol:           "LLDP",
					Metadata:           map[string]string{},
					NeighborSystemName: "uap-nanohd",
				},
			},
		},
	}

	targets := engine.collectRecursiveSNMPTargets(job, map[string]bool{"192.168.1.233": true})
	if len(targets) != 0 {
		t.Fatalf("expected no new targets, got %#v", targets)
	}
}

func TestCollectRecursiveSNMPTargetsSkipsWeakInferredLinks(t *testing.T) {
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			TopologyLinks: []*TopologyLink{
				{
					Protocol:         "SNMP-L2",
					NeighborMgmtAddr: "192.168.10.10",
					Metadata: map[string]string{
						"source":            "snmp-arp-fdb",
						"confidence_reason": "single_identifier_inference",
						"evidence_class":    "inferred-segment",
						"relation_family":   "OBSERVED_TO",
					},
				},
			},
		},
	}

	targets := engine.collectRecursiveSNMPTargets(job, map[string]bool{})
	if len(targets) != 0 {
		t.Fatalf("expected no recursive targets from weak inferred link, got %#v", targets)
	}
}
