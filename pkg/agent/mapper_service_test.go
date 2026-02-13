package agent

import (
	"context"
	"testing"

	"github.com/carverauto/serviceradar/pkg/mapper"
)

const networkOpsContact = "Network Operations"

func TestBuildMapperDeviceMetadataAddsSysOwnerAlias(t *testing.T) {
	device := &mapper.DiscoveredDevice{
		DeviceID:    "sr:test-device",
		SysContact:  networkOpsContact,
		SysDescr:    "Ubiquiti UniFi UDM-Pro",
		SysLocation: "Rack A",
	}

	metadata := buildMapperDeviceMetadata(device)

	if got := metadata["sys_contact"]; got != networkOpsContact {
		t.Fatalf("expected sys_contact to be populated, got %q", got)
	}

	if got := metadata["sys_owner"]; got != networkOpsContact {
		t.Fatalf("expected sys_owner alias to be populated, got %q", got)
	}

	if got := metadata["sys_descr"]; got != "Ubiquiti UniFi UDM-Pro" {
		t.Fatalf("expected sys_descr to be populated, got %q", got)
	}
	if got := metadata["snmp_description"]; got != "Ubiquiti UniFi UDM-Pro" {
		t.Fatalf("expected snmp_description to be populated, got %q", got)
	}

	if got := metadata["sys_location"]; got != "Rack A" {
		t.Fatalf("expected sys_location to be populated, got %q", got)
	}
	if got := metadata["snmp_location"]; got != "Rack A" {
		t.Fatalf("expected snmp_location to be populated, got %q", got)
	}
	if got := metadata["snmp_owner"]; got != networkOpsContact {
		t.Fatalf("expected snmp_owner alias to be populated, got %q", got)
	}
}

func TestPublishDeviceIncludesSNMPFingerprint(t *testing.T) {
	publisher := NewMapperResultPublisher()
	device := &mapper.DiscoveredDevice{
		DeviceID: "sr:test-device",
		IP:       "192.168.1.1",
		SNMPFingerprint: &mapper.SNMPFingerprint{
			System: &mapper.SNMPSystemFingerprint{
				SysName:      "farm01",
				SysDescr:     "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
				SysObjectID:  ".1.3.6.1.4.1.8072.3.2.10",
				SysContact:   "ops",
				SysLocation:  "lab",
				IPForwarding: 1,
			},
			Bridge: &mapper.SNMPBridgeFingerprint{
				BridgeBaseMAC:          "F4:92:BF:75:C7:2B",
				BridgePortCount:        8,
				STPForwardingPortCount: 6,
			},
		},
	}

	if err := publisher.PublishDevice(context.Background(), device); err != nil {
		t.Fatalf("expected PublishDevice to succeed, got error: %v", err)
	}

	updates, ok := publisher.Drain(1)
	if !ok || len(updates) != 1 {
		t.Fatalf("expected one published device update")
	}

	fp, ok := updates[0]["snmp_fingerprint"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected snmp_fingerprint map in update")
	}

	system, ok := fp["system"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected snmp_fingerprint.system map in update")
	}

	if got := system["sys_name"]; got != "farm01" {
		t.Fatalf("expected sys_name=farm01, got %v", got)
	}

	if got := system["ip_forwarding"]; got != int32(1) {
		t.Fatalf("expected ip_forwarding=1, got %v", got)
	}
}
