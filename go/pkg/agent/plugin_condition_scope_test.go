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
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
)

// All values below are invented for these tests.
const (
	testScopeA = "example:src-a:alerts"
	testScopeB = "example:src-b:alerts"
	testKeyHot = "example:dev-01:thermal_throttle"
	testKeyObs = "example:dev-01:obstructed"
	testKeyMot = "example:dev-02:motors_stuck"
)

var testScopeEpoch = time.Date(2026, time.January, 2, 3, 0, 0, 0, time.UTC)

func scopedConditionPayload(key, scope, level string) map[string]any {
	unmapped := map[string]any{
		"condition_key": key,
		"level":         level,
		"alert_name":    key[strings.LastIndex(key, ":")+1:],
	}
	if scope != "" {
		unmapped["condition_scope"] = scope
	}
	return map[string]any{
		"id":            "evt-" + level + "-" + key,
		"time":          "2026-01-02T02:59:00Z",
		"class_uid":     1008,
		"category_uid":  1,
		"type_uid":      100801,
		"activity_id":   1,
		"activity_name": "Create",
		"severity_id":   5,
		"severity":      "Critical",
		"message":       "Example alert " + key + " (" + level + ")",
		"device":        map[string]any{"uid": "example:ut:dev-01", "name": "dish-01"},
		"metadata": map[string]any{
			"version":     "1.7.0",
			"logged_time": "2026-01-02T02:59:00Z",
		},
		"raw_data": "raw capture placeholder",
		"unmapped": unmapped,
	}
}

func ocsfRecord(t *testing.T, eventID string, payload map[string]any) *addonpb.TelemetryRecord {
	t.Helper()
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	return &addonpb.TelemetryRecord{
		EventId:              eventID,
		ObservedTimeUnixNano: testScopeEpoch.Add(-time.Minute).UnixNano(),
		EventTimeUnixNano:    testScopeEpoch.Add(-time.Minute).UnixNano(),
		PayloadKind:          addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		Payload:              raw,
		Metadata:             map[string]string{"schema_id": "example.alert", "schema_version": "1.0.0"},
	}
}

func scopedEvent(t *testing.T, key, scope, level string) *addonpb.TelemetryRecord {
	t.Helper()
	return ocsfRecord(t, "rec-"+level+"-"+key, scopedConditionPayload(key, scope, level))
}

func scopeMarker(t *testing.T, scope string, active ...string) *addonpb.TelemetryRecord {
	t.Helper()
	if active == nil {
		active = []string{}
	}
	return ocsfRecord(t, "rec-marker-"+scope, map[string]any{
		"id":           "evt-marker-" + scope,
		"time":         "2026-01-02T02:59:00Z",
		"class_uid":    1008,
		"category_uid": 1,
		"type_uid":     100801,
		"activity_id":  1,
		"severity_id":  1,
		"message":      "condition scope snapshot",
		"unmapped": map[string]any{
			"condition_scope_complete": scope,
			"active_condition_keys":    active,
		},
	})
}

func decodePayload(t *testing.T, record *addonpb.TelemetryRecord) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(record.GetPayload(), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	return payload
}

// describeRecord renders a forwarded record as a short, comparable label.
func describeRecord(t *testing.T, record *addonpb.TelemetryRecord) string {
	t.Helper()
	unmapped, _ := decodePayload(t, record)["unmapped"].(map[string]any)
	switch {
	case unmapped["condition_scope_complete"] != nil:
		return fmt.Sprintf("marker:%v", unmapped["condition_scope_complete"])
	case unmapped["condition_cleared_by"] != nil:
		return fmt.Sprintf("clear:%v:%v", unmapped["condition_scope"], unmapped["condition_key"])
	case unmapped["condition_key"] != nil:
		return fmt.Sprintf("event:%v:%v", unmapped["condition_key"], unmapped["level"])
	default:
		return "other"
	}
}

func newTestScopeDebouncer(clock *time.Time) *pluginConditionDebouncer {
	d := newPluginConditionDebouncer(func() time.Time { return *clock })
	next := 0
	d.newID = func() string {
		next++
		return fmt.Sprintf("synth-%d", next)
	}
	return d
}

type scopeStep struct {
	assignment string // defaults to "a1"
	advance    time.Duration
	records    []*addonpb.TelemetryRecord
	want       []string
}

func TestConditionScopeSnapshots(t *testing.T) {
	const plain = "other"
	plainRecord := ocsfRecord(t, "rec-plain", map[string]any{"message": "plain event", "class_uid": 1008})

	cases := []struct {
		name  string
		steps []scopeStep
	}{
		{
			name: "raise then marker without the key clears it once",
			steps: []scopeStep{
				{records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical"), scopeMarker(t, testScopeA, testKeyHot)},
					want: []string{"event:" + testKeyHot + ":critical", "marker:" + testScopeA}},
				{advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA)},
					want: []string{"marker:" + testScopeA, "clear:" + testScopeA + ":" + testKeyHot}},
				{advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA)},
					want: []string{"marker:" + testScopeA}},
			},
		},
		{
			name: "marker in a later call of the same run still clears",
			steps: []scopeStep{
				{records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "warning")},
					want: []string{"event:" + testKeyHot + ":warning"}},
				{advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyObs, testScopeA, "critical")},
					want: []string{"event:" + testKeyObs + ":critical"}},
				{records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA, testKeyObs)},
					want: []string{"marker:" + testScopeA, "clear:" + testScopeA + ":" + testKeyHot}},
			},
		},
		{
			name: "ok transition after non-ok is forwarded once and forgets the key",
			steps: []scopeStep{
				{records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical")},
					want: []string{"event:" + testKeyHot + ":critical"}},
				{advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "ok")},
					want: []string{"event:" + testKeyHot + ":ok"}},
				{advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "ok"), scopeMarker(t, testScopeA)},
					want: []string{"marker:" + testScopeA}},
			},
		},
		{
			name: "marker keys the agent never saw are ignored",
			steps: []scopeStep{
				{records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA, testKeyHot, testKeyMot)},
					want: []string{"marker:" + testScopeA}},
				{records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyObs, testScopeA, "critical"), scopeMarker(t, testScopeA, testKeyObs, testKeyMot)},
					want: []string{"event:" + testKeyObs + ":critical", "marker:" + testScopeA}},
			},
		},
		{
			name: "incomplete run without a marker synthesizes nothing",
			steps: []scopeStep{
				{records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical"), scopeMarker(t, testScopeA, testKeyHot)},
					want: []string{"event:" + testKeyHot + ":critical", "marker:" + testScopeA}},
				// The next runs collect partially: no condition events, no marker.
				{advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{plainRecord}, want: []string{plain}},
				{advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{plainRecord}, want: []string{plain}},
			},
		},
		{
			name: "TTL eviction never synthesizes a clear",
			steps: []scopeStep{
				{records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical")},
					want: []string{"event:" + testKeyHot + ":critical"}},
				{advance: conditionTTL + time.Minute, records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA)},
					want: []string{"marker:" + testScopeA}},
			},
		},
		{
			name: "scopes are independent",
			steps: []scopeStep{
				{records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical"), scopedEvent(t, testKeyMot, testScopeB, "warning")},
					want: []string{"event:" + testKeyHot + ":critical", "event:" + testKeyMot + ":warning"}},
				{advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA)},
					want: []string{"marker:" + testScopeA, "clear:" + testScopeA + ":" + testKeyHot}},
				{records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeB, testKeyMot)},
					want: []string{"marker:" + testScopeB}},
				{records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeB)},
					want: []string{"marker:" + testScopeB, "clear:" + testScopeB + ":" + testKeyMot}},
			},
		},
		{
			name: "assignments are independent",
			steps: []scopeStep{
				{assignment: "a1", records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical")},
					want: []string{"event:" + testKeyHot + ":critical"}},
				{assignment: "a2", records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical")},
					want: []string{"event:" + testKeyHot + ":critical"}},
				{assignment: "a2", advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA)},
					want: []string{"marker:" + testScopeA, "clear:" + testScopeA + ":" + testKeyHot}},
				// a1 still remembers its own alert: repeat is suppressed, and its
				// own marker clears it.
				{assignment: "a1", records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical")},
					want: nil},
				{assignment: "a1", records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA)},
					want: []string{"marker:" + testScopeA, "clear:" + testScopeA + ":" + testKeyHot}},
			},
		},
		{
			name: "clears follow their marker sorted by key",
			steps: []scopeStep{
				{records: []*addonpb.TelemetryRecord{
					scopedEvent(t, testKeyObs, testScopeA, "critical"),
					scopedEvent(t, testKeyMot, testScopeA, "critical"),
					scopedEvent(t, testKeyHot, testScopeA, "warning"),
				}, want: []string{
					"event:" + testKeyObs + ":critical",
					"event:" + testKeyMot + ":critical",
					"event:" + testKeyHot + ":warning",
				}},
				{advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA), plainRecord},
					want: []string{
						"marker:" + testScopeA,
						"clear:" + testScopeA + ":" + testKeyObs,
						"clear:" + testScopeA + ":" + testKeyHot,
						"clear:" + testScopeA + ":" + testKeyMot,
						plain,
					}},
			},
		},
		{
			name: "scoped non-ok keeps the refresh heartbeat",
			steps: []scopeStep{
				{records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical")},
					want: []string{"event:" + testKeyHot + ":critical"}},
				{advance: 5 * time.Minute, records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical")},
					want: nil},
				{advance: conditionRefreshInterval, records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical")},
					want: []string{"event:" + testKeyHot + ":critical"}},
			},
		},
		{
			name: "marker without an active key list is forwarded but clears nothing",
			steps: []scopeStep{
				{records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, testScopeA, "critical")},
					want: []string{"event:" + testKeyHot + ":critical"}},
				{records: []*addonpb.TelemetryRecord{ocsfRecord(t, "rec-bad-marker", map[string]any{
					"class_uid": 1008,
					"unmapped":  map[string]any{"condition_scope_complete": testScopeA},
				})}, want: []string{"marker:" + testScopeA}},
				{records: []*addonpb.TelemetryRecord{ocsfRecord(t, "rec-bad-marker", map[string]any{
					"class_uid": 1008,
					"unmapped":  map[string]any{"condition_scope_complete": testScopeA, "active_condition_keys": "not-a-list"},
				})}, want: []string{"marker:" + testScopeA}},
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			clock := testScopeEpoch
			d := newTestScopeDebouncer(&clock)
			for i, step := range tc.steps {
				clock = clock.Add(step.advance)
				assignment := step.assignment
				if assignment == "" {
					assignment = "a1"
				}
				out := d.filter(assignment, &addonpb.TelemetryBatch{Records: step.records})
				var got []string
				for _, record := range out.GetRecords() {
					got = append(got, describeRecord(t, record))
				}
				if !reflect.DeepEqual(got, step.want) {
					t.Fatalf("step %d: forwarded %v, want %v", i, got, step.want)
				}
			}
		})
	}
}

// A device that never alerts must produce no condition events at all, even
// though the plugin reports it ok on every run and the refresh interval passes
// many times over.
func TestConditionScopeHealthyKeysNeverForwarded(t *testing.T) {
	clock := testScopeEpoch
	d := newTestScopeDebouncer(&clock)

	for run := 0; run < 24; run++ {
		batch := &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{
			scopedEvent(t, testKeyHot, testScopeA, "ok"),
			scopedEvent(t, testKeyMot, testScopeA, "ok"),
			scopeMarker(t, testScopeA),
		}}
		out := d.filter("a1", batch)
		if len(out.GetRecords()) != 1 || describeRecord(t, out.GetRecords()[0]) != "marker:"+testScopeA {
			t.Fatalf("run %d at +%s: want only the marker, got %d records", run, clock.Sub(testScopeEpoch), len(out.GetRecords()))
		}
		clock = clock.Add(5 * time.Minute)
	}
	if clock.Sub(testScopeEpoch) <= conditionRefreshInterval {
		t.Fatal("test must span more than one refresh interval")
	}
	if len(d.scopes) != 0 {
		t.Fatalf("healthy keys must not be remembered, got %d scopes", len(d.scopes))
	}
}

// The synthesized clear is a valid event built from the forwarded raise.
func TestConditionScopeClearRecordFields(t *testing.T) {
	clock := testScopeEpoch
	d := newTestScopeDebouncer(&clock)

	raise := scopedEvent(t, testKeyHot, testScopeA, "critical")
	d.filter("a1", &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{raise}})

	clock = clock.Add(7 * time.Minute)
	out := d.filter("a1", &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA)}})
	if len(out.GetRecords()) != 2 {
		t.Fatalf("want marker + one clear, got %d records", len(out.GetRecords()))
	}
	cleared := out.GetRecords()[1]

	if cleared.GetEventId() != "synth-1" {
		t.Errorf("record event_id = %q, want a fresh id", cleared.GetEventId())
	}
	if cleared.GetEventTimeUnixNano() != clock.UnixNano() || cleared.GetObservedTimeUnixNano() != clock.UnixNano() {
		t.Errorf("record times = %d/%d, want %d", cleared.GetEventTimeUnixNano(), cleared.GetObservedTimeUnixNano(), clock.UnixNano())
	}
	if cleared.GetPayloadKind() != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT {
		t.Errorf("payload kind = %v", cleared.GetPayloadKind())
	}
	if !reflect.DeepEqual(cleared.GetMetadata(), raise.GetMetadata()) {
		t.Errorf("record metadata = %v, want the raise's %v", cleared.GetMetadata(), raise.GetMetadata())
	}

	payload := decodePayload(t, cleared)
	wantTop := map[string]any{
		"id":            "synth-1",
		"time":          clock.Format(time.RFC3339Nano),
		"class_uid":     float64(1008),
		"category_uid":  float64(1),
		"type_uid":      float64(100801),
		"activity_id":   float64(1),
		"activity_name": "Create",
		"severity_id":   float64(1),
		"severity":      "Informational",
		"message":       conditionClearedMessagePrefix + testKeyHot,
	}
	for field, want := range wantTop {
		if got := payload[field]; !reflect.DeepEqual(got, want) {
			t.Errorf("payload %s = %#v, want %#v", field, got, want)
		}
	}
	if _, has := payload["raw_data"]; has {
		t.Error("the raise's raw_data must not be copied into the clear")
	}
	if device, _ := payload["device"].(map[string]any); device["uid"] != "example:ut:dev-01" {
		t.Errorf("device = %v, want the raise's device", payload["device"])
	}
	if metadata, _ := payload["metadata"].(map[string]any); metadata["logged_time"] != clock.Format(time.RFC3339Nano) {
		t.Errorf("metadata.logged_time = %v, want the clear time", metadata["logged_time"])
	}
	unmapped, _ := payload["unmapped"].(map[string]any)
	wantUnmapped := map[string]any{
		"condition_key":        testKeyHot,
		"condition_scope":      testScopeA,
		"level":                "ok",
		"alert_name":           "thermal_throttle",
		"condition_cleared_by": conditionClearedBy,
	}
	if !reflect.DeepEqual(unmapped, wantUnmapped) {
		t.Errorf("unmapped = %v, want %v", unmapped, wantUnmapped)
	}
}

// A raise whose time is epoch milliseconds gets a clear in the same form, and an
// oversized raise is reduced to a bounded template that still yields a valid
// clear.
func TestConditionScopeClearTemplateShapes(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(map[string]any)
		checkFn func(t *testing.T, now time.Time, payload map[string]any, cleared *addonpb.TelemetryRecord)
	}{
		{
			name:   "numeric time stays numeric",
			mutate: func(p map[string]any) { p["time"] = testScopeEpoch.Add(-time.Minute).UnixMilli() },
			checkFn: func(t *testing.T, now time.Time, payload map[string]any, _ *addonpb.TelemetryRecord) {
				if payload["time"] != float64(now.UnixMilli()) {
					t.Errorf("time = %#v, want %d", payload["time"], now.UnixMilli())
				}
			},
		},
		{
			name:   "oversized raise is reduced",
			mutate: func(p map[string]any) { p["observables"] = strings.Repeat("x", conditionTemplateMaxBytes) },
			checkFn: func(t *testing.T, _ time.Time, payload map[string]any, cleared *addonpb.TelemetryRecord) {
				if _, has := payload["observables"]; has {
					t.Error("oversized fields must not survive into the template")
				}
				if len(cleared.GetPayload()) > conditionTemplateMaxBytes {
					t.Errorf("clear payload is %d bytes, over the template cap", len(cleared.GetPayload()))
				}
				unmapped, _ := payload["unmapped"].(map[string]any)
				device, _ := payload["device"].(map[string]any)
				if payload["class_uid"] != float64(1008) || payload["type_uid"] != float64(100801) ||
					device["uid"] != "example:ut:dev-01" || unmapped["condition_key"] != testKeyHot ||
					unmapped["condition_scope"] != testScopeA || unmapped["level"] != "ok" || payload["id"] == nil {
					t.Errorf("reduced clear lost required fields: %v", payload)
				}
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			clock := testScopeEpoch
			d := newTestScopeDebouncer(&clock)
			raw := scopedConditionPayload(testKeyHot, testScopeA, "critical")
			tc.mutate(raw)
			d.filter("a1", &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{ocsfRecord(t, "rec-raise", raw)}})

			clock = clock.Add(time.Minute)
			out := d.filter("a1", &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA)}})
			if len(out.GetRecords()) != 2 {
				t.Fatalf("want marker + one clear, got %d records", len(out.GetRecords()))
			}
			cleared := out.GetRecords()[1]
			tc.checkFn(t, clock, decodePayload(t, cleared), cleared)
		})
	}
}

// Unscoped conditions keep their behavior: ok is forwarded on first sight and
// refreshed, and a marker never clears an unscoped key, even one with the same
// condition_key as a scoped key.
func TestConditionScopeLeavesUnscopedConditionsAlone(t *testing.T) {
	clock := testScopeEpoch
	d := newTestScopeDebouncer(&clock)

	steps := []scopeStep{
		{records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, "", "critical"), scopedEvent(t, testKeyObs, "", "ok")},
			want: []string{"event:" + testKeyHot + ":critical", "event:" + testKeyObs + ":ok"}},
		{advance: time.Minute, records: []*addonpb.TelemetryRecord{scopeMarker(t, testScopeA)},
			want: []string{"marker:" + testScopeA}},
		{advance: time.Minute, records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, "", "critical"), scopedEvent(t, testKeyObs, "", "ok")},
			want: nil},
		{advance: conditionRefreshInterval, records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, "", "critical"), scopedEvent(t, testKeyObs, "", "ok")},
			want: []string{"event:" + testKeyHot + ":critical", "event:" + testKeyObs + ":ok"}},
		{advance: time.Minute, records: []*addonpb.TelemetryRecord{scopedEvent(t, testKeyHot, "", "ok")},
			want: []string{"event:" + testKeyHot + ":ok"}},
	}
	for i, step := range steps {
		clock = clock.Add(step.advance)
		out := d.filter("a1", &addonpb.TelemetryBatch{Records: step.records})
		var got []string
		for _, record := range out.GetRecords() {
			got = append(got, describeRecord(t, record))
		}
		if !reflect.DeepEqual(got, step.want) {
			t.Fatalf("step %d: forwarded %v, want %v", i, got, step.want)
		}
	}
	if len(d.scopes) != 0 {
		t.Fatalf("unscoped events must not create scoped state, got %d scopes", len(d.scopes))
	}
}
