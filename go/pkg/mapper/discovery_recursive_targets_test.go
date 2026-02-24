package mapper

import "testing"

func TestCollectRecursiveSNMPTargetsUsesNeighborMgmtAddr(t *testing.T) {
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			TopologyLinks: []*TopologyLink{
				{
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
