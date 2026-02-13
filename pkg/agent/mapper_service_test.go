package agent

import (
	"testing"

	"github.com/carverauto/serviceradar/pkg/mapper"
)

func TestBuildMapperDeviceMetadataAddsSysOwnerAlias(t *testing.T) {
	device := &mapper.DiscoveredDevice{
		DeviceID:    "sr:test-device",
		SysContact:  "Network Operations",
		SysDescr:    "Ubiquiti UniFi UDM-Pro",
		SysLocation: "Rack A",
	}

	metadata := buildMapperDeviceMetadata(device)

	if got := metadata["sys_contact"]; got != "Network Operations" {
		t.Fatalf("expected sys_contact to be populated, got %q", got)
	}

	if got := metadata["sys_owner"]; got != "Network Operations" {
		t.Fatalf("expected sys_owner alias to be populated, got %q", got)
	}

	if got := metadata["sys_descr"]; got != "Ubiquiti UniFi UDM-Pro" {
		t.Fatalf("expected sys_descr to be populated, got %q", got)
	}

	if got := metadata["sys_location"]; got != "Rack A" {
		t.Fatalf("expected sys_location to be populated, got %q", got)
	}
}
