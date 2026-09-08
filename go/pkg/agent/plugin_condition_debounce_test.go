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

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
)

func conditionRecord(t *testing.T, key, level string, ratio float64) *addonpb.TelemetryRecord {
	t.Helper()
	payload, err := json.Marshal(map[string]any{
		"message": "Proxmox guest memory bottleneck (" + level + ")",
		"unmapped": map[string]any{
			"condition_key": key,
			"level":         level,
			"ratio":         ratio,
			"warn":          0.80,
			"crit":          0.90,
		},
	})
	if err != nil {
		t.Fatalf("marshal condition payload: %v", err)
	}
	return &addonpb.TelemetryRecord{
		PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		Payload:     payload,
	}
}

// feedOne runs a single-record batch through the debouncer and reports whether
// the record was forwarded (survived) this cycle.
func feedOne(d *pluginConditionDebouncer, assignment string, record *addonpb.TelemetryRecord) bool {
	batch := &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{record}}
	out := d.filter(assignment, batch)
	return out != nil && len(out.Records) == 1
}

// A resource that ENTERS critical alerts once; while it stays critical (or
// sawtooths within the critical band) it emits nothing.
func TestConditionDebouncerTransitionEmitsOnceThenSilent(t *testing.T) {
	clock := time.Unix(0, 0)
	d := newPluginConditionDebouncer(func() time.Time { return clock })

	const key = "proxmox:guest_memory:cluster:vm:100"

	// First critical reading is forwarded (the alert).
	if !feedOne(d, "a1", conditionRecord(t, key, "critical", 0.91)) {
		t.Fatal("first critical reading should be forwarded")
	}

	// Sawtooth WITHIN the critical band across subsequent cycles: all suppressed.
	for i, ratio := range []float64{0.92, 0.93, 0.94, 0.95, 0.91} {
		clock = clock.Add(time.Minute)
		if feedOne(d, "a1", conditionRecord(t, key, "critical", ratio)) {
			t.Fatalf("cycle %d (ratio %v): staying critical must not re-emit", i, ratio)
		}
	}
}

// Escalation and de-escalation each cross a level boundary and must be
// forwarded, so operators still see the condition change.
func TestConditionDebouncerForwardsLevelChanges(t *testing.T) {
	clock := time.Unix(0, 0)
	d := newPluginConditionDebouncer(func() time.Time { return clock })
	const key = "proxmox:node_cpu:pve-a"

	// ok -> warning: forwarded.
	if !feedOne(d, "a1", conditionRecord(t, key, "warning", 0.83)) {
		t.Fatal("entering warning should be forwarded")
	}
	// staying warning: suppressed.
	clock = clock.Add(time.Minute)
	if feedOne(d, "a1", conditionRecord(t, key, "warning", 0.84)) {
		t.Fatal("staying warning should be suppressed")
	}
	// warning -> critical: forwarded.
	clock = clock.Add(time.Minute)
	if !feedOne(d, "a1", conditionRecord(t, key, "critical", 0.95)) {
		t.Fatal("escalation to critical should be forwarded")
	}
	// critical -> warning (well below crit-margin): forwarded.
	clock = clock.Add(time.Minute)
	if !feedOne(d, "a1", conditionRecord(t, key, "warning", 0.82)) {
		t.Fatal("de-escalation to warning should be forwarded")
	}
}

// A value hovering right at the 90% critical boundary must not flap between
// warning and critical and re-alert every cycle.
func TestConditionDebouncerHysteresisPreventsBoundaryFlap(t *testing.T) {
	clock := time.Unix(0, 0)
	d := newPluginConditionDebouncer(func() time.Time { return clock })
	const key = "proxmox:guest_cpu:cluster:vm:200"

	// Warm up into critical.
	if !feedOne(d, "a1", conditionRecord(t, key, "critical", 0.91)) {
		t.Fatal("initial critical should be forwarded")
	}

	// Now oscillate 0.89 / 0.91 around the boundary. 0.89 is above crit-margin
	// (0.90 - 0.05 = 0.85), so hysteresis holds it at critical -> no re-emits.
	for i, ratio := range []float64{0.89, 0.91, 0.89, 0.91, 0.89} {
		clock = clock.Add(time.Minute)
		// The plugin naively labels 0.89 as "warning" and 0.91 as "critical";
		// the debouncer's hysteresis must ignore that flip.
		level := "critical"
		if ratio < 0.90 {
			level = "warning"
		}
		if feedOne(d, "a1", conditionRecord(t, key, level, ratio)) {
			t.Fatalf("cycle %d (ratio %v): boundary flap must not re-emit", i, ratio)
		}
	}
}

// After the refresh interval, an unchanged level heartbeats once so a
// long-running condition is not silent forever.
func TestConditionDebouncerRefreshHeartbeat(t *testing.T) {
	clock := time.Unix(0, 0)
	d := newPluginConditionDebouncer(func() time.Time { return clock })
	const key = "proxmox:node_storage:pve-a:local"

	if !feedOne(d, "a1", conditionRecord(t, key, "warning", 0.85)) {
		t.Fatal("first warning should be forwarded")
	}
	clock = clock.Add(time.Minute)
	if feedOne(d, "a1", conditionRecord(t, key, "warning", 0.85)) {
		t.Fatal("within refresh window should be suppressed")
	}
	clock = clock.Add(conditionRefreshInterval)
	if !feedOne(d, "a1", conditionRecord(t, key, "warning", 0.85)) {
		t.Fatal("after refresh interval an unchanged level should heartbeat")
	}
}

// Distinct assignments and distinct condition keys keep independent state.
func TestConditionDebouncerScopesByAssignmentAndKey(t *testing.T) {
	clock := time.Unix(0, 0)
	d := newPluginConditionDebouncer(func() time.Time { return clock })

	if !feedOne(d, "a1", conditionRecord(t, "proxmox:node_cpu:pve-a", "critical", 0.95)) {
		t.Fatal("a1 first should forward")
	}
	// Same key on a DIFFERENT assignment is independent -> forwarded.
	if !feedOne(d, "a2", conditionRecord(t, "proxmox:node_cpu:pve-a", "critical", 0.95)) {
		t.Fatal("a2 first should forward independently")
	}
	// Different key on a1 -> forwarded.
	if !feedOne(d, "a1", conditionRecord(t, "proxmox:node_cpu:pve-b", "critical", 0.95)) {
		t.Fatal("different key should forward")
	}
	// Repeat of the original a1 key -> suppressed.
	clock = clock.Add(time.Minute)
	if feedOne(d, "a1", conditionRecord(t, "proxmox:node_cpu:pve-a", "critical", 0.96)) {
		t.Fatal("repeat of a1 key should be suppressed")
	}
}

// Non-condition telemetry (no condition_key/level) is never suppressed.
func TestConditionDebouncerPassesThroughNonConditionRecords(t *testing.T) {
	d := newPluginConditionDebouncer(func() time.Time { return time.Unix(0, 0) })

	plain := &addonpb.TelemetryRecord{
		PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		Payload:     []byte(`{"message":"camera motion","unmapped":{"camera_id":"c1"}}`),
	}
	otelLog := &addonpb.TelemetryRecord{
		PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTEL_LOG,
		Payload:     []byte(`{"body":"hello"}`),
	}

	batch := &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{plain, otelLog}}
	out := d.filter("a1", batch)
	if out == nil || len(out.Records) != 2 {
		t.Fatalf("non-condition records must pass through, got %d", len(out.GetRecords()))
	}
	// Even repeated, they always pass through.
	batch2 := &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{plain, otelLog}}
	if out2 := d.filter("a1", batch2); len(out2.Records) != 2 {
		t.Fatalf("repeated non-condition records must still pass, got %d", len(out2.Records))
	}
}

// A nil debouncer is a no-op (callers need not special-case construction).
func TestConditionDebouncerNilIsNoOp(t *testing.T) {
	var d *pluginConditionDebouncer
	batch := &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{
		conditionRecord(t, "proxmox:node_cpu:pve-a", "critical", 0.95),
	}}
	if out := d.filter("a1", batch); out == nil || len(out.Records) != 1 {
		t.Fatal("nil debouncer must pass records through unchanged")
	}
}
