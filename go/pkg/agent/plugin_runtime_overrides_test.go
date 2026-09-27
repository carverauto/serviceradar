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

package agent

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/tetratelabs/wazero"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

var overrideTestNow = time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)

func overrideConfigJSON(t *testing.T, overrides ...pluginRunOverride) []byte {
	t.Helper()
	raw, err := json.Marshal(runOverrideEnvelope{Schema: runOverridesSchema, Overrides: overrides})
	if err != nil {
		t.Fatalf("marshal overrides: %v", err)
	}
	return raw
}

func overrideAt(id string, start, end time.Time) pluginRunOverride {
	return pluginRunOverride{ID: id, Kind: "channel_saturation", Target: "ap-1", StartsAt: start, ExpiresAt: end}
}

func assignmentWithOverrides(t *testing.T, id string, overrides ...pluginRunOverride) *pluginAssignment {
	t.Helper()
	parsed, err := parseRunOverridesConfig(overrideConfigJSON(t, overrides...))
	if err != nil {
		t.Fatalf("parse overrides: %v", err)
	}
	return &pluginAssignment{AssignmentID: id, runOverrides: parsed}
}

func deliveredIDs(overrides []pluginRunOverride) map[string]bool {
	ids := make(map[string]bool, len(overrides))
	for _, override := range overrides {
		ids[override.ID] = override.Expired
	}
	return ids
}

func TestParseRunOverridesConfigRejectsWrongSchemaAndInvalidEntries(t *testing.T) {
	if _, err := parseRunOverridesConfig([]byte(`{"schema":"other","overrides":[]}`)); err == nil {
		t.Fatal("expected an error for an unexpected schema")
	}

	start := overrideTestNow
	parsed, err := parseRunOverridesConfig(overrideConfigJSON(t,
		overrideAt("good", start, start.Add(time.Minute)),
		overrideAt("", start, start.Add(time.Minute)),
		overrideAt("backwards", start, start.Add(-time.Minute)),
	))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(parsed) != 1 || parsed[0].ID != "good" {
		t.Fatalf("parsed = %+v, want only the valid override", parsed)
	}
}

func TestRunOverrideDeliveryMarksExpiredUntilAcknowledged(t *testing.T) {
	store := newRunOverrideStore()
	start := overrideTestNow.Add(-5 * time.Minute)
	store.applyConfig([]*pluginAssignment{assignmentWithOverrides(t, "a1",
		overrideAt("active", start, overrideTestNow.Add(time.Minute)),
		overrideAt("expired", start, overrideTestNow.Add(-time.Second)),
		overrideAt("future", overrideTestNow.Add(time.Hour), overrideTestNow.Add(2*time.Hour)),
	)}, overrideTestNow)

	delivered, expired := store.deliver("a1", overrideTestNow)
	got := deliveredIDs(delivered)
	if expiredFlag, ok := got["active"]; !ok || expiredFlag {
		t.Fatalf("active override: delivered=%v expired=%v", ok, expiredFlag)
	}
	if expiredFlag, ok := got["expired"]; !ok || !expiredFlag {
		t.Fatalf("expired override: delivered=%v expired=%v", ok, expiredFlag)
	}
	if _, ok := got["future"]; ok {
		t.Fatal("an override that has not started must not be delivered")
	}
	if len(expired) != 1 || expired[0] != "expired" {
		t.Fatalf("expired ids = %v", expired)
	}

	// A run that fails never acknowledges, so the next run receives it again.
	if _, again := store.deliver("a1", overrideTestNow); len(again) != 1 {
		t.Fatalf("unacknowledged expired override not redelivered: %v", again)
	}

	store.acknowledge("a1", expired)
	delivered, expired = store.deliver("a1", overrideTestNow)
	if _, ok := deliveredIDs(delivered)["expired"]; ok || len(expired) != 0 {
		t.Fatalf("acknowledged override still delivered: %+v", delivered)
	}

	// Core forgets the acknowledged override; so does the agent's suppression.
	store.applyConfig([]*pluginAssignment{assignmentWithOverrides(t, "a1",
		overrideAt("active", start, overrideTestNow.Add(time.Minute)),
	)}, overrideTestNow)
	if _, ok := store.assignments["a1"].acked["expired"]; ok {
		t.Fatal("acknowledgement retained after core dropped the override")
	}
}

func TestRunOverrideLocalOverlayFromSucceededActionOnly(t *testing.T) {
	store := newRunOverrideStore()
	store.applyConfig([]*pluginAssignment{{AssignmentID: "a1"}}, overrideTestNow)

	failed := []byte(`{"status":"failed","run_overrides":[{"op":"set","id":"f1","kind":"jam","duration_seconds":60}]}`)
	store.recordActionResult("a1", failed, overrideTestNow)
	if delivered, _ := store.deliver("a1", overrideTestNow); len(delivered) != 0 {
		t.Fatalf("failed action set an override: %+v", delivered)
	}

	succeeded := []byte(`{"status":"succeeded","run_overrides":[{"op":"set","id":"f1","kind":"jam","target":"conveyor-7","duration_seconds":60}]}`)
	store.recordActionResult("a1", succeeded, overrideTestNow)
	delivered, _ := store.deliver("a1", overrideTestNow.Add(time.Second))
	if len(delivered) != 1 || delivered[0].Target != "conveyor-7" || delivered[0].Expired {
		t.Fatalf("local override not delivered: %+v", delivered)
	}

	// The local copy only bridges the gap to the next config poll.
	if delivered, _ := store.deliver("a1", overrideTestNow.Add(runOverrideLocalTTL+time.Second)); len(delivered) != 0 {
		t.Fatalf("local override outlived its TTL: %+v", delivered)
	}
}

func TestRunOverrideConfigSupersedesLocalAndEndIsHonoured(t *testing.T) {
	store := newRunOverrideStore()
	store.applyConfig([]*pluginAssignment{{AssignmentID: "a1"}}, overrideTestNow)
	store.recordActionResult("a1",
		[]byte(`{"status":"succeeded","run_overrides":[{"op":"set","id":"f1","kind":"jam","duration_seconds":3600}]}`),
		overrideTestNow)

	// Core clamped the override to 5 minutes; its copy wins.
	clamped := overrideAt("f1", overrideTestNow, overrideTestNow.Add(5*time.Minute))
	store.applyConfig([]*pluginAssignment{assignmentWithOverrides(t, "a1", clamped)}, overrideTestNow)
	delivered, _ := store.deliver("a1", overrideTestNow)
	if len(delivered) != 1 || !delivered[0].ExpiresAt.Equal(clamped.ExpiresAt) {
		t.Fatalf("config did not supersede the local override: %+v", delivered)
	}

	store.recordActionResult("a1", []byte(`{"status":"succeeded","run_overrides":[{"op":"end","id":"f1"}]}`), overrideTestNow)
	if delivered, _ := store.deliver("a1", overrideTestNow); len(delivered) != 0 {
		t.Fatalf("ended override still delivered before the config caught up: %+v", delivered)
	}
}

func TestRunOverrideStoreForgetsRemovedAssignments(t *testing.T) {
	store := newRunOverrideStore()
	store.applyConfig([]*pluginAssignment{assignmentWithOverrides(t, "a1",
		overrideAt("x", overrideTestNow, overrideTestNow.Add(time.Minute)))}, overrideTestNow)
	store.applyConfig(nil, overrideTestNow)
	if delivered, _ := store.deliver("a1", overrideTestNow); len(delivered) != 0 {
		t.Fatalf("removed assignment still has overrides: %+v", delivered)
	}
}

func TestMergeRunOverridesIntoConfigIsHostOwned(t *testing.T) {
	override := overrideAt("f1", overrideTestNow, overrideTestNow.Add(time.Minute))

	merged, err := mergeRunOverridesIntoConfig([]byte(`{"site":"a"}`), []pluginRunOverride{override})
	if err != nil {
		t.Fatalf("merge: %v", err)
	}
	var config map[string]json.RawMessage
	if err := json.Unmarshal(merged, &config); err != nil {
		t.Fatalf("decode merged: %v", err)
	}
	if string(config["site"]) != `"a"` {
		t.Fatalf("operator params lost: %s", merged)
	}
	var envelope runOverrideEnvelope
	if err := json.Unmarshal(config[runOverridesConfigKey], &envelope); err != nil ||
		envelope.Schema != runOverridesSchema || len(envelope.Overrides) != 1 {
		t.Fatalf("override envelope = %s (%v)", config[runOverridesConfigKey], err)
	}

	// A value the operator smuggled into params is removed even with nothing to deliver.
	stripped, err := mergeRunOverridesIntoConfig([]byte(`{"site":"a","_serviceradar_run_overrides":{"schema":"x"}}`), nil)
	if err != nil {
		t.Fatalf("strip: %v", err)
	}
	strippedConfig := map[string]json.RawMessage{}
	if json.Unmarshal(stripped, &strippedConfig) != nil {
		t.Fatalf("decode stripped: %s", stripped)
	}
	if _, ok := strippedConfig[runOverridesConfigKey]; ok {
		t.Fatalf("operator-supplied override key survived: %s", stripped)
	}

	untouched := []byte(`{"site":"a"}`)
	if got, _ := mergeRunOverridesIntoConfig(untouched, nil); string(got) != string(untouched) {
		t.Fatalf("params rewritten with nothing to deliver: %s", got)
	}
}

func TestPluginResultAcknowledgementIsHostAuthored(t *testing.T) {
	loop := &PushLoop{logger: logger.NewTestLogger()}

	payload, _, err := loop.normalizePluginPayload(PluginResult{
		AssignmentID:             "a1",
		Payload:                  []byte(`{"status":"OK","summary":"fine","run_overrides_acknowledged":["forged"]}`),
		ObservedAt:               overrideTestNow,
		AcknowledgedRunOverrides: []string{"f1"},
	}, "agent-1", "default")
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("decode: %v", err)
	}
	acks, ok := decoded[runOverridesAckKey].([]any)
	if !ok || len(acks) != 1 || acks[0] != "f1" {
		t.Fatalf("ack list = %v, want host-authored [f1]", decoded[runOverridesAckKey])
	}

	payload, _, err = loop.normalizePluginPayload(PluginResult{
		AssignmentID: "a1",
		Payload:      []byte(`{"status":"OK","summary":"fine","run_overrides_acknowledged":["forged"]}`),
		ObservedAt:   overrideTestNow,
	}, "agent-1", "default")
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	decoded = map[string]any{}
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if _, ok := decoded[runOverridesAckKey]; ok {
		t.Fatalf("plugin-supplied acknowledgement forwarded: %s", payload)
	}
}

func TestActionModeCanEmitOCSFEventTelemetry(t *testing.T) {
	manager := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	t.Cleanup(manager.Stop)

	runtime := wazero.NewRuntime(t.Context())
	t.Cleanup(func() { _ = runtime.Close(t.Context()) })
	// One exported memory page; the host function reads the batch from it.
	module, err := runtime.Instantiate(t.Context(), []byte{
		0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
		0x05, 0x03, 0x01, 0x00, 0x01,
		0x07, 0x0a, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
	})
	if err != nil {
		t.Fatalf("instantiate test module: %v", err)
	}

	batch := []byte(`{"records":[{"event_id":"fault-f1-open","payload_kind":"ocsf_event",` +
		`"payload":{"class_uid":1008,"severity_id":4,"message":"conveyor jam"}}]}`)
	if !module.Memory().Write(0, batch) {
		t.Fatal("write batch to Wasm memory")
	}

	emit := func(capabilities map[string]bool) int32 {
		exec := newPluginExecution(manager, &pluginAssignment{
			AssignmentID: "demo-ot", PluginID: "ot-plc", Capabilities: capabilities,
		})
		exec.mode = pluginExecutionModeAction
		return exec.hostEmitTelemetry(t.Context(), module, 0, uint32(len(batch)))
	}

	if got := emit(map[string]bool{}); got != pluginErrDenied {
		t.Fatalf("emit without capability = %d, want denied", got)
	}
	select {
	case signal := <-manager.signals:
		t.Fatalf("denied emission enqueued a signal: %+v", signal)
	default:
	}

	if got := emit(map[string]bool{pluginCapabilityEmitTelemetry: true}); got != pluginErrOK {
		t.Fatalf("emit from action = %d, want OK", got)
	}
	select {
	case signal := <-manager.signals:
		if signal.AssignmentID != "demo-ot" || len(signal.Batch.GetRecords()) != 1 ||
			signal.Batch.GetRecords()[0].GetEventId() != "fault-f1-open" {
			t.Fatalf("unexpected signal: %+v", signal)
		}
	default:
		t.Fatal("action-mode emission did not reach the telemetry path")
	}
}
