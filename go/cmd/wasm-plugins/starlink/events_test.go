package main

import (
	"encoding/json"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func decodeRecord(t *testing.T, r sdk.TelemetryRecord) map[string]any {
	t.Helper()
	if r.PayloadKind != sdk.SignalSchemaPayloadKindOCSFEvent {
		t.Fatalf("payload kind = %q", r.PayloadKind)
	}
	raw, err := json.Marshal(r.Payload)
	if err != nil {
		t.Fatalf("payload does not serialize: %v", err)
	}
	var event map[string]any
	if err := json.Unmarshal(raw, &event); err != nil {
		t.Fatalf("payload is not an OCSF JSON event: %v", err)
	}
	return event
}

func TestBuildAlertRecordsEmitsActiveAlertsAndMarker(t *testing.T) {
	snap := alertSnapshot{Complete: true, Devices: []deviceAlerts{
		{DeviceRef: "starlink:ut:" + testTerminalA, Kind: "user_terminal", Active: []string{"thermal_shutdown", "pop_change"}},
		{DeviceRef: "starlink:ut:" + testTerminalB, Kind: "user_terminal"},
	}}
	records := buildAlertRecords(snap, "starlink-test", cloudPluginID)
	if len(records) != 3 {
		t.Fatalf("records = %d, want 2 active alerts + 1 marker (healthy devices emit nothing)", len(records))
	}

	first := decodeRecord(t, records[0])
	unmapped := first["unmapped"].(map[string]any)
	if unmapped["condition_key"] != "starlink:ut:"+testTerminalA+":thermal_shutdown" ||
		unmapped["condition_scope"] != "starlink:starlink-test:alerts" || unmapped["level"] != "critical" {
		t.Fatalf("condition fields = %v", unmapped)
	}
	if first["device"].(map[string]any)["uid"] != "starlink:ut:"+testTerminalA {
		t.Fatalf("device.uid = %v", first["device"])
	}
	if lvl := decodeRecord(t, records[1])["unmapped"].(map[string]any)["level"]; lvl != "warning" {
		t.Fatalf("informational alert level = %v, want warning (the debounce has no info band)", lvl)
	}

	marker := decodeRecord(t, records[2])["unmapped"].(map[string]any)
	keys, _ := marker["active_condition_keys"].([]any)
	if marker["condition_scope_complete"] != "starlink:starlink-test:alerts" || len(keys) != 2 {
		t.Fatalf("marker = %v", marker)
	}
	if _, isCondition := marker["condition_key"]; isCondition {
		t.Fatal("the marker must not itself be a condition event")
	}
}

func TestBuildAlertRecordsIncompleteSnapshotHasNoMarker(t *testing.T) {
	snap := alertSnapshot{Complete: false, Devices: []deviceAlerts{
		{DeviceRef: "starlink:ut:" + testTerminalA, Kind: "user_terminal", Active: []string{"thermal_shutdown"}},
	}}
	records := buildAlertRecords(snap, "starlink-test", cloudPluginID)
	if len(records) != 1 {
		t.Fatalf("an incomplete snapshot must emit active alerts but no marker, got %d records", len(records))
	}
}

func TestBuildAlertRecordsEmptyCompleteScopeStillMarks(t *testing.T) {
	records := buildAlertRecords(alertSnapshot{Complete: true}, "starlink-test", cloudPluginID)
	if len(records) != 1 {
		t.Fatalf("a complete scope with no alerts must still send the marker so earlier alerts clear, got %d", len(records))
	}
	keys := decodeRecord(t, records[0])["unmapped"].(map[string]any)["active_condition_keys"]
	if list, ok := keys.([]any); !ok || len(list) != 0 {
		t.Fatalf("active_condition_keys = %#v, want an empty array (not null)", keys)
	}
}
