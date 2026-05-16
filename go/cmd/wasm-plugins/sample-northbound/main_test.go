package main

import (
	"encoding/json"
	"testing"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

func TestDeviceLookupAction(t *testing.T) {
	hostConfig := mustParseActionConfig(t, `{
		"api_base_url": "mock://lab-nms",
		"inventory_prefix": "lab",
		"action_invocation": {
			"schema": "serviceradar.northbound_action_invocation.v1",
			"invocation_id": "inv-device-1",
			"action_id": "sample.device.lookup",
			"targets": [{
				"kind": "device",
				"device_uid": "sr:device-1",
				"device_name": "edge-sw01",
				"device_ip": "192.0.2.10",
				"model": "EX4300"
			}],
			"input_values": {
				"query_mode": "full",
				"include_neighbors": true
			}
		}
	}`)

	result := handleAction(hostConfig, decodePluginConfig(hostConfig))

	if result.Status != sdk.ActionStatusSucceeded {
		t.Fatalf("status = %s", result.Status)
	}
	if len(result.Targets) != 1 {
		t.Fatalf("target count = %d", len(result.Targets))
	}

	target := result.Targets[0]
	if target.DeviceUID != "sr:device-1" {
		t.Fatalf("device uid = %q", target.DeviceUID)
	}
	if target.Result["api_query"] != "GET /devices/192.0.2.10?mode=full" {
		t.Fatalf("api query = %v", target.Result["api_query"])
	}
	if target.Result["external_inventory_id"] != "lab-sr-device-1" {
		t.Fatalf("inventory id = %v", target.Result["external_inventory_id"])
	}
	if target.Result["neighbors_included"] != true {
		t.Fatalf("neighbors_included = %v", target.Result["neighbors_included"])
	}
}

func TestInterfaceAuditAction(t *testing.T) {
	hostConfig := mustParseActionConfig(t, `{
		"inventory_prefix": "lab",
		"interface_default_vlan": 410,
		"action_invocation": {
			"schema": "serviceradar.northbound_action_invocation.v1",
			"invocation_id": "inv-interface-1",
			"action_id": "sample.interface.audit",
			"targets": [{
				"kind": "interface",
				"device_uid": "sr:device-2",
				"device_ip": "198.51.100.20",
				"interface_uid": "if-2",
				"if_name": "Gi1/0/12",
				"if_admin_status": "up",
				"if_oper_status": "down"
			}],
			"input_values": {
				"operation": "simulate_remediation",
				"dry_run": true,
				"change_ticket": "CHG-123"
			}
		}
	}`)

	result := handleAction(hostConfig, decodePluginConfig(hostConfig))

	if result.Status != sdk.ActionStatusSucceeded {
		t.Fatalf("status = %s", result.Status)
	}

	target := result.Targets[0]
	if target.InterfaceUID != "if-2" {
		t.Fatalf("interface uid = %q", target.InterfaceUID)
	}
	if target.Result["api_query"] != "POST /devices/198.51.100.20/interfaces/Gi1/0/12/actions/simulate_remediation" {
		t.Fatalf("api query = %v", target.Result["api_query"])
	}
	if target.Result["vlan"] != 410 {
		t.Fatalf("vlan = %v", target.Result["vlan"])
	}
	if target.Result["remediation_preview"] != "would run simulate_remediation for Gi1/0/12" {
		t.Fatalf("preview = %v", target.Result["remediation_preview"])
	}
}

func TestUnsupportedAction(t *testing.T) {
	hostConfig := mustParseActionConfig(t, `{
		"action_invocation": {
			"invocation_id": "inv-unknown",
			"action_id": "sample.unknown",
			"targets": []
		}
	}`)

	result := handleAction(hostConfig, decodePluginConfig(hostConfig))
	if result.Status != sdk.ActionStatusFailed {
		t.Fatalf("status = %s", result.Status)
	}
	if result.ErrorClass != "unsupported_action" {
		t.Fatalf("error class = %q", result.ErrorClass)
	}
}

func TestActionResultSerializes(t *testing.T) {
	hostConfig := mustParseActionConfig(t, `{
		"action_invocation": {
			"invocation_id": "inv-device-1",
			"action_id": "sample.device.lookup",
			"targets": [{"kind": "device", "device_uid": "sr:device-1", "device_ip": "192.0.2.10"}]
		}
	}`)

	payload, err := handleAction(hostConfig, decodePluginConfig(hostConfig)).Serialize()
	if err != nil {
		t.Fatalf("serialize result: %v", err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if decoded["schema"] != sdk.ActionResultSchemaV1 {
		t.Fatalf("schema = %v", decoded["schema"])
	}
	if decoded["status"] != string(sdk.ActionStatusSucceeded) {
		t.Fatalf("status = %v", decoded["status"])
	}
}

func mustParseActionConfig(t *testing.T, payload string) *sdk.ActionHostConfig {
	t.Helper()

	hostConfig, err := sdk.ParseActionConfig([]byte(payload))
	if err != nil {
		t.Fatalf("parse action config: %v", err)
	}

	return hostConfig
}
