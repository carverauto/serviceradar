/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package armis

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

const managedQueryLabel = "managed"

// buildNormalizedUpdate composes the driver's raw API-to-update mapping with
// the generic runtime normalization step, mirroring the full pipeline an
// update passes through before reaching the gateway. The assertions below are
// byte-identical to the wire format the Elixir core consumed before the
// driver was extracted from the sync runtime.
func buildNormalizedUpdate(item device) map[string]interface{} {
	return buildNormalizedUpdateWithSource(item, models.SourceConfig{})
}

func buildNormalizedUpdateWithSource(item device, source models.SourceConfig) map[string]interface{} {
	run := syncsources.RunContext{
		AgentID:   "agent-1",
		GatewayID: "agent-1",
		Partition: "default",
		Source:    source,
	}

	update := buildUpdate(run, item, managedQueryLabel)
	if update != nil {
		syncsources.NormalizeUpdate(update)
	}
	return update
}

func TestFilterDevicesNormalizesCommaSeparatedIPs(t *testing.T) {
	got := filterDevices([]device{
		{ID: 101, IPAddress: "192.0.2.227, 198.51.100.86", Name: "multi-ip"},
	}, nil)

	if len(got) != 1 {
		t.Fatalf("filtered device count = %d, want 1", len(got))
	}
	if got[0].IPAddress != "192.0.2.227" {
		t.Fatalf("filtered IP = %q, want first valid IP", got[0].IPAddress)
	}
	if got[0].ID != 101 {
		t.Fatalf("expected normalized device to preserve Armis identity: %#v", got)
	}
}

func TestFilterDevicesDropsBlacklistedCommaSeparatedIPs(t *testing.T) {
	got := filterDevices([]device{
		{ID: 101, IPAddress: "192.0.2.227, 198.51.100.86", Name: "all-blacklisted"},
		{ID: 102, IPAddress: "192.0.2.228, 203.0.113.10", Name: "mixed"},
		{ID: 103, IPAddress: "not-an-ip", Name: "invalid"},
	}, []string{"192.0.2.0/24", "198.51.100.0/24"})

	if len(got) != 1 {
		t.Fatalf("filtered device count = %d, want 1: %#v", len(got), got)
	}
	if got[0].ID != 102 || got[0].IPAddress != "203.0.113.10" {
		t.Fatalf("filtered device = %#v, want allowed IP from mixed device", got[0])
	}
}

func TestBuildUpdateMapsSdkAttributesToInventoryFields(t *testing.T) {
	purdue := 2.5
	firstSeen := time.Date(2026, 5, 14, 1, 2, 3, 246357000, time.UTC)
	lastSeen := time.Date(2026, 5, 14, 4, 5, 6, 987654321, time.UTC)

	update := buildNormalizedUpdate(device{
		ID:                18497,
		DeviceID:          42,
		Display:           "PLC-01",
		Type:              "PLC",
		Category:          "OT",
		Brand:             "Axis Communications",
		Model:             "P1375",
		OSName:            "Linux",
		OSVersion:         "5.15",
		IPv4Addresses:     []string{"10.0.0.2", "10.0.0.3"},
		MacAddresses:      []string{"00:11:22:33:44:55"},
		FirstSeenSnake:    firstSeen,
		LastSeenSnake:     lastSeen,
		RiskLevelSnake:    72,
		Tags:              []string{"managed", "ot"},
		Boundaries:        []map[string]interface{}{{"id": float64(7), "name": "All OT Boundaries"}},
		SerialNumbers:     []string{"SN-123"},
		PurdueLevel:       &purdue,
		Visibility:        "Full",
		NetworkInterfaces: []map[string]interface{}{{"name": "eth0", "mac": "00:11:22:33:44:55"}},
	})

	if update["ip"] != "10.0.0.2" {
		t.Fatalf("ip = %q, want first IPv4 address", update["ip"])
	}
	if update["device_id"] != "default:10.0.0.2" {
		t.Fatalf("device_id = %q, want partition-scoped device id", update["device_id"])
	}
	if update["agent_id"] != "agent-1" {
		t.Fatalf("agent_id = %q", update["agent_id"])
	}
	if update["source"] != "armis" {
		t.Fatalf("source = %q, want armis", update["source"])
	}
	if update["hostname"] != "PLC-01" {
		t.Fatalf("hostname = %q, want display name", update["hostname"])
	}
	if update["type"] != "PLC" {
		t.Fatalf("type = %q, want PLC", update["type"])
	}
	if update["vendor_name"] != "Axis Communications" {
		t.Fatalf("vendor_name = %q, want Axis Communications", update["vendor_name"])
	}
	if update["model"] != "P1375" {
		t.Fatalf("model = %q, want P1375", update["model"])
	}

	metadata, ok := update["metadata"].(map[string]string)
	if !ok {
		t.Fatalf("metadata has type %T, want map[string]string", update["metadata"])
	}

	for key, want := range map[string]string{
		"integration_type": "armis",
		"armis_device_id":  "18497",
		"source_device_id": "42",
		"integration_id":   "18497",
		"type":             "PLC",
		"device_type":      "PLC",
		"category":         "OT",
		"ipv4_addresses":   "10.0.0.2,10.0.0.3",
		"mac_addresses":    "001122334455",
		"brand":            "Axis Communications",
		"manufacturer":     "Axis Communications",
		"model":            "P1375",
		"os_name":          "Linux",
		"os_version":       "5.15",
		"risk_score":       "72",
		"query_label":      "managed",
		"source_tags":      "managed,ot",
		"boundary_names":   "All OT Boundaries",
		"serial_number":    "SN-123",
		"serial_numbers":   "SN-123",
		"purdue_level":     "2.5",
		"visibility":       "Full",
	} {
		if got := metadata[key]; got != want {
			t.Fatalf("metadata[%q] = %q, want %q", key, got, want)
		}
	}

	for _, key := range []string{
		"armis_type",
		"armis_category",
		"armis_risk_level",
		"armis_tags",
		"armis_boundary_names",
		"armis_serial_numbers",
		"armis_purdue_level",
		"armis_visibility",
	} {
		if _, ok := metadata[key]; ok {
			t.Fatalf("metadata[%q] should not be emitted; use normalized inventory fields", key)
		}
	}

	if update["first_seen_time"] != "2026-05-14T01:02:03Z" {
		t.Fatalf("first_seen_time = %q", update["first_seen_time"])
	}
	if update["last_seen_time"] != "2026-05-14T04:05:06Z" {
		t.Fatalf("last_seen_time = %q", update["last_seen_time"])
	}
	timestamp, ok := update["timestamp"].(string)
	if !ok {
		t.Fatalf("timestamp has type %T, want string", update["timestamp"])
	}
	if strings.Contains(timestamp, ".") {
		t.Fatalf("timestamp = %q, want second precision", timestamp)
	}
}

func TestBuildUpdatePreservesArmisAttachmentMetadataFromRawFields(t *testing.T) {
	var item device
	if err := json.Unmarshal([]byte(`{
		"id": 18497,
		"ipAddress": "10.0.4.40",
		"display": "fsfo027c.global.example.com",
		"Access Switch": "nsfocs-idfer1-asw001:2/20",
		"Connection Type": "Wired",
		"DHCP Lease Type": "Dynamic",
		"VLAN": 3006,
		"vlans": [3006],
		"networkInterfaces": [
			{"name": "Ethernet", "mac": "7C:57:58:18:18:EC"}
		]
	}`), &item); err != nil {
		t.Fatalf("unmarshal device: %v", err)
	}

	update := buildNormalizedUpdate(item)
	metadata, ok := update["metadata"].(map[string]string)
	if !ok {
		t.Fatalf("metadata has type %T, want map[string]string", update["metadata"])
	}

	for key, want := range map[string]string{
		"armis_access_switch":   "nsfocs-idfer1-asw001:2/20",
		"armis_connection_type": "Wired",
		"armis_dhcp_lease_type": "Dynamic",
		"armis_vlan":            "3006",
		"armis_vlans":           "[3006]",
	} {
		if got := metadata[key]; got != want {
			t.Fatalf("metadata[%q] = %q, want %q", key, got, want)
		}
	}

	if _, ok := update["network_interfaces"]; !ok {
		t.Fatal("networkInterfaces alias should still populate endpoint NIC inventory")
	}
}

func TestBuildUpdatePreservesConfiguredArmisMetadataFields(t *testing.T) {
	var item device
	if err := json.Unmarshal([]byte(`{
		"id": 42,
		"ipAddress": "10.0.0.2",
		"customAccessPort": "GigabitEthernet1/0/48"
	}`), &item); err != nil {
		t.Fatalf("unmarshal device: %v", err)
	}

	update := buildNormalizedUpdateWithSource(item, models.SourceConfig{
		Settings: map[string]any{
			"extra_metadata_fields": []any{"customAccessPort"},
		},
	})
	metadata, ok := update["metadata"].(map[string]string)
	if !ok {
		t.Fatalf("metadata has type %T, want map[string]string", update["metadata"])
	}

	if got := metadata["armis_custom_access_port"]; got != "GigabitEthernet1/0/48" {
		t.Fatalf("metadata[armis_custom_access_port] = %q", got)
	}
}

func TestBuildUpdateSplitsMultiMACField(t *testing.T) {
	update := buildNormalizedUpdate(device{
		DeviceID:   42,
		IPAddress:  "10.0.0.2",
		MacAddress: "junk,00:1A:A0:B9:40:40,001422F42A2A",
	})

	if update["mac"] != "00:1A:A0:B9:40:40" {
		t.Fatalf("update[mac] = %q, want first valid atomic MAC", update["mac"])
	}

	metadata, ok := update["metadata"].(map[string]string)
	if !ok {
		t.Fatalf("metadata has type %T, want map[string]string", update["metadata"])
	}
	if got := metadata["mac_addresses"]; got != "001AA0B94040,001422F42A2A" {
		t.Fatalf("metadata[mac_addresses] = %q, want validated normalized MAC list", got)
	}
}

func TestBuildUpdateOmitsMACWhenFieldHasNoValidMAC(t *testing.T) {
	for name, item := range map[string]device{
		"empty":        {DeviceID: 42, IPAddress: "10.0.0.2"},
		"garbage-only": {DeviceID: 42, IPAddress: "10.0.0.2", MacAddress: "unknown, n/a ,00:11:22:33:44"},
	} {
		update := buildNormalizedUpdate(item)

		if mac, ok := update["mac"]; ok {
			t.Fatalf("%s: update[mac] = %q, want key omitted", name, mac)
		}

		metadata, ok := update["metadata"].(map[string]string)
		if !ok {
			t.Fatalf("%s: metadata has type %T, want map[string]string", name, update["metadata"])
		}
		if value, ok := metadata["mac_addresses"]; ok {
			t.Fatalf("%s: metadata[mac_addresses] = %q, want key omitted", name, value)
		}
	}
}

func TestBuildUpdateFallsBackToMACListWhenMACFieldIsGarbage(t *testing.T) {
	update := buildNormalizedUpdate(device{
		DeviceID:     42,
		IPAddress:    "10.0.0.2",
		MacAddress:   "n/a, also not a mac",
		MacAddresses: []string{"bogus", "00:1A:A0:B9:40:42"},
	})

	if update["mac"] != "00:1A:A0:B9:40:42" {
		t.Fatalf("update[mac] = %q, want first valid MAC from mac_addresses list", update["mac"])
	}
}

func TestBuildUpdateSkipsDevicesWithoutIP(t *testing.T) {
	if update := buildNormalizedUpdate(device{DeviceID: 42}); update != nil {
		t.Fatalf("update = %#v, want nil for device without IP", update)
	}
}
