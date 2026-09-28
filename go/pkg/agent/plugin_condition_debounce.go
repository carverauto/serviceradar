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
	"bytes"
	"encoding/json"
	"maps"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
)

// Condition events — OCSF events carrying `unmapped.condition_key` and
// `unmapped.level` — are emitted by stateless check plugins every cycle for as
// long as a resource stays in a warning/critical band. Left unchecked, a
// resource that simply stays "critical" (or sawtooths WITHIN the critical band,
// e.g. 91%→92%→…→95%) writes one ocsf_events row per check cycle: on the demo
// this was the #2 ocsf_events driver.
//
// A WASM plugin cannot suppress these itself: it is re-instantiated on every
// invocation and keeps no state across cycles (no host KV/state API, and its
// config is the static assignment params). The agent, by contrast, is the
// plugin's long-lived, per-assignment host, so it is the natural place to
// remember each condition's last level and forward an event only when that level
// TRANSITIONS. Nothing else de-duplicates these: every emitted event gets a
// unique id and lands as a distinct ocsf_events row.
//
// Condition scopes. The unscoped rules above forward the first observation of
// every key, `ok` included, so a plugin that mirrors a vendor's alert list has
// two bad options: emit `ok` for every possible alert on every device each run
// (a flood), or emit only active alerts (the clear never arrives; the key ages
// out of the TTL silently). A condition event may therefore carry
// `unmapped.condition_scope`, and the plugin closes a run's view of that scope
// with one scope-complete marker record (`unmapped.condition_scope_complete`
// plus `unmapped.active_condition_keys`). For scoped keys the agent forwards
// raises and level changes as usual, never forwards an `ok` for a key it never
// saw alerting, and, on the marker, synthesizes an `ok` clear for every key it
// forwarded at a non-ok level that the marker no longer lists. No marker means
// the plugin's view was partial, so nothing is cleared. Events without a scope
// keep the unscoped behavior exactly.

const (
	// conditionRefreshInterval re-forwards an unchanged level at most this often,
	// so a long-running condition still produces a periodic heartbeat rather than
	// going silent forever after its first alert.
	conditionRefreshInterval = 15 * time.Minute
	// conditionTTL evicts state for conditions that have not been observed for a
	// while — the resource recovered and the plugin stopped emitting — bounding
	// memory to the set of currently-alerting resources.
	conditionTTL = time.Hour
	// conditionHysteresisMargin is how far a ratio must fall below a band's enter
	// threshold before the condition leaves that band. It stops a value hovering
	// at a boundary (e.g. flipping 89%/91% around the 90% critical line) from
	// flapping between levels and re-alerting each cycle.
	conditionHysteresisMargin = 0.05
	// conditionTemplateMaxBytes caps the payload remembered per scoped key as the
	// template for its synthesized clear. A larger payload is reduced to the
	// fields a clear needs (see reduceConditionTemplate), so a bulky condition
	// event does not keep its whole payload alive for as long as it is active.
	conditionTemplateMaxBytes = 16 * 1024
	// conditionClearedMessagePrefix prefixes the message of a synthesized clear.
	conditionClearedMessagePrefix = "Condition cleared: "
	// conditionClearedBy marks a synthesized clear in `unmapped` so it can be
	// told apart from an `ok` the plugin emitted itself.
	conditionClearedBy = "condition_scope_complete"
)

// conditionLevel is the discrete band a condition occupies. It mirrors the
// plugin-side pressureLevel but is defined here because the agent and the WASM
// plugin are separate Go modules.
type conditionLevel int

const (
	conditionLevelOK conditionLevel = iota
	conditionLevelWarning
	conditionLevelCritical
)

func parseConditionLevel(value string) conditionLevel {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "critical":
		return conditionLevelCritical
	case "warning":
		return conditionLevelWarning
	default:
		return conditionLevelOK
	}
}

// nextConditionLevel applies hysteresis: entering a higher band happens at its
// enter threshold, but leaving a band requires dropping a full margin below that
// threshold. A value parked at a boundary therefore stays in its current band
// instead of oscillating.
func nextConditionLevel(prev conditionLevel, ratio, warn, crit, margin float64) conditionLevel {
	critEnter, critExit := crit, crit-margin
	warnEnter, warnExit := warn, warn-margin

	switch prev {
	case conditionLevelCritical:
		switch {
		case ratio >= critExit:
			return conditionLevelCritical
		case ratio >= warnExit:
			return conditionLevelWarning
		default:
			return conditionLevelOK
		}
	case conditionLevelWarning:
		switch {
		case ratio >= critEnter:
			return conditionLevelCritical
		case ratio >= warnExit:
			return conditionLevelWarning
		default:
			return conditionLevelOK
		}
	case conditionLevelOK:
		fallthrough
	default: // ok / unknown
		switch {
		case ratio >= critEnter:
			return conditionLevelCritical
		case ratio >= warnEnter:
			return conditionLevelWarning
		default:
			return conditionLevelOK
		}
	}
}

// conditionSample is the de-duplication-relevant slice of a condition event.
type conditionSample struct {
	key        string
	scope      string // empty for an unscoped condition
	level      conditionLevel
	ratio      *float64
	warn, crit *float64
}

// conditionUnmapped decodes the condition fields. The scope field is raw so a
// malformed scope value can never make an otherwise valid condition event fail
// to decode: that would change how pre-existing unscoped events are handled.
type conditionUnmapped struct {
	Unmapped struct {
		ConditionKey   string          `json:"condition_key"`
		Level          string          `json:"level"`
		Ratio          *float64        `json:"ratio"`
		Warn           *float64        `json:"warn"`
		Crit           *float64        `json:"crit"`
		ConditionScope json.RawMessage `json:"condition_scope"`
	} `json:"unmapped"`
}

// rawJSONString returns the trimmed string held by raw, or "" when raw is
// absent, null, or not a JSON string.
func rawJSONString(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return ""
	}
	return strings.TrimSpace(value)
}

// parseConditionSample extracts the condition fields from an OCSF event payload.
// ok is false when the payload is not a condition event (no condition_key/level),
// in which case the record must be forwarded untouched.
func parseConditionSample(payload []byte) (conditionSample, bool) {
	if len(payload) == 0 {
		return conditionSample{}, false
	}
	var env conditionUnmapped
	if err := json.Unmarshal(payload, &env); err != nil {
		return conditionSample{}, false
	}
	key := strings.TrimSpace(env.Unmapped.ConditionKey)
	level := strings.TrimSpace(env.Unmapped.Level)
	if key == "" || level == "" {
		return conditionSample{}, false
	}
	return conditionSample{
		key:   key,
		scope: rawJSONString(env.Unmapped.ConditionScope),
		level: parseConditionLevel(level),
		ratio: env.Unmapped.Ratio,
		warn:  env.Unmapped.Warn,
		crit:  env.Unmapped.Crit,
	}, true
}

// conditionScopeMarker is a plugin's statement that its view of one scope is
// complete for this run and that activeKeys are all of the scope's keys that
// are currently non-ok.
type conditionScopeMarker struct {
	scope      string
	activeKeys map[string]struct{}
}

type conditionScopeMarkerUnmapped struct {
	Unmapped struct {
		ScopeComplete json.RawMessage `json:"condition_scope_complete"`
		ActiveKeys    json.RawMessage `json:"active_condition_keys"`
	} `json:"unmapped"`
}

// conditionScopeMarkerField is checked before decoding so ordinary events do
// not pay for a second JSON decode.
var conditionScopeMarkerField = []byte(`"condition_scope_complete"`)

// parseConditionScopeMarker extracts a scope-complete marker. Both fields are
// required: a marker without a JSON string array of active keys (an empty
// array is fine) is not trusted, because treating it as "nothing is active"
// would clear every alert in the scope.
func parseConditionScopeMarker(payload []byte) (conditionScopeMarker, bool) {
	if !bytes.Contains(payload, conditionScopeMarkerField) {
		return conditionScopeMarker{}, false
	}
	var env conditionScopeMarkerUnmapped
	if err := json.Unmarshal(payload, &env); err != nil {
		return conditionScopeMarker{}, false
	}
	scope := rawJSONString(env.Unmapped.ScopeComplete)
	if scope == "" || len(env.Unmapped.ActiveKeys) == 0 {
		return conditionScopeMarker{}, false
	}
	var keys []string
	if err := json.Unmarshal(env.Unmapped.ActiveKeys, &keys); err != nil || keys == nil {
		return conditionScopeMarker{}, false
	}
	active := make(map[string]struct{}, len(keys))
	for _, key := range keys {
		if key = strings.TrimSpace(key); key != "" {
			active[key] = struct{}{}
		}
	}
	return conditionScopeMarker{scope: scope, activeKeys: active}, true
}

type conditionEntry struct {
	level     conditionLevel
	emittedAt time.Time
	seenAt    time.Time
}

// conditionClearTemplate is the last forwarded non-ok record for a scoped key,
// kept so a clear can be synthesized with the same class, device, keys and
// signal-schema metadata as the alert it closes.
type conditionClearTemplate struct {
	payload  []byte
	metadata map[string]string
}

type scopedConditionEntry struct {
	conditionEntry
	template conditionClearTemplate
}

// pluginConditionDebouncer remembers the last emitted level for each
// (assignment, condition_key) so it can forward a condition event only when the
// level transitions (with hysteresis), collapsing the per-cycle repeats a
// stateless plugin necessarily produces.
type pluginConditionDebouncer struct {
	mu    sync.Mutex
	now   func() time.Time
	newID func() string
	state map[string]conditionEntry
	// scopes holds scoped conditions, keyed by assignment + "\x00" + scope and
	// then by condition_key. Only non-ok keys are remembered: a scoped key that
	// returns to ok is forgotten, which is what keeps a healthy fleet at zero
	// state and zero events.
	scopes map[string]map[string]*scopedConditionEntry
}

func newPluginConditionDebouncer(now func() time.Time) *pluginConditionDebouncer {
	if now == nil {
		now = time.Now
	}
	return &pluginConditionDebouncer{
		now:    now,
		newID:  uuid.NewString,
		state:  make(map[string]conditionEntry),
		scopes: make(map[string]map[string]*scopedConditionEntry),
	}
}

// filter returns the batch with suppressed condition records removed. Records
// that are not condition events pass through untouched. A nil debouncer is a
// no-op so callers need not special-case it.
//
// Clears synthesized for a scope-complete marker are inserted directly after
// that marker, sorted by condition_key. Keeping them next to the snapshot that
// caused them (rather than at the end of the batch) keeps the output order a
// pure function of the input order, including when one batch carries markers
// for several scopes.
func (d *pluginConditionDebouncer) filter(assignmentID string, batch *addonpb.TelemetryBatch) *addonpb.TelemetryBatch {
	if d == nil || batch == nil || len(batch.Records) == 0 {
		return batch
	}

	d.mu.Lock()
	defer d.mu.Unlock()

	now := d.now()
	d.evictLocked(now)

	kept := make([]*addonpb.TelemetryRecord, 0, len(batch.Records))
	for _, record := range batch.Records {
		forward, clears := d.routeLocked(assignmentID, record, now)
		if forward {
			kept = append(kept, record)
		}
		kept = append(kept, clears...)
	}
	batch.Records = kept
	return batch
}

// routeLocked decides whether record is forwarded and returns any clears it
// causes (only a scope-complete marker causes clears).
func (d *pluginConditionDebouncer) routeLocked(assignmentID string, record *addonpb.TelemetryRecord, now time.Time) (bool, []*addonpb.TelemetryRecord) {
	if record == nil {
		return false, nil
	}
	if record.GetPayloadKind() != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT {
		return true, nil
	}

	sample, ok := parseConditionSample(record.GetPayload())
	if !ok {
		// A scope-complete marker is forwarded unchanged (core may reconcile
		// against it) after it has closed the keys it no longer lists.
		if marker, isMarker := parseConditionScopeMarker(record.GetPayload()); isMarker {
			return true, d.completeScopeLocked(assignmentID, marker, now)
		}
		// Not a condition event (e.g. a plain plugin log/event): never suppress.
		return true, nil
	}

	if sample.scope != "" {
		return d.shouldForwardScopedLocked(assignmentID, record, sample, now), nil
	}
	return d.shouldForwardLocked(assignmentID, sample, now), nil
}

// effectiveConditionLevel applies hysteresis when the raw ratio + thresholds are
// present, otherwise falls back to the discrete level the plugin reported
// (health-style conditions have no ratio and simply de-dup on exact level).
func effectiveConditionLevel(sample conditionSample, prevLevel conditionLevel) conditionLevel {
	if sample.ratio != nil && sample.warn != nil && sample.crit != nil {
		return nextConditionLevel(prevLevel, *sample.ratio, *sample.warn, *sample.crit, conditionHysteresisMargin)
	}
	return sample.level
}

// conditionForwardDue reports whether a condition at level effective must be
// forwarded given its previous state: first sighting, level change, or the
// refresh heartbeat falling due.
func conditionForwardDue(prev conditionEntry, exists bool, effective conditionLevel, now time.Time) bool {
	switch {
	case !exists:
		return true
	case effective != prev.level:
		return true
	case now.Sub(prev.emittedAt) >= conditionRefreshInterval:
		return true
	default:
		return false
	}
}

func (d *pluginConditionDebouncer) shouldForwardLocked(assignmentID string, sample conditionSample, now time.Time) bool {
	stateKey := assignmentID + "\x00" + sample.key
	prev, exists := d.state[stateKey]

	prevLevel := conditionLevelOK
	if exists {
		prevLevel = prev.level
	}
	effective := effectiveConditionLevel(sample, prevLevel)
	forward := conditionForwardDue(prev, exists, effective, now)

	entry := conditionEntry{level: effective, seenAt: now, emittedAt: prev.emittedAt}
	if forward {
		entry.emittedAt = now
	}
	d.state[stateKey] = entry
	return forward
}

// shouldForwardScopedLocked applies the scoped rules. Non-ok levels follow the
// unscoped forward rules and remember the forwarded record as the key's clear
// template. An ok level is forwarded only as the transition out of a
// remembered non-ok level, after which the key is forgotten; an ok for a key
// that never alerted is neither forwarded nor remembered, so a healthy key
// produces nothing, not even the periodic refresh.
func (d *pluginConditionDebouncer) shouldForwardScopedLocked(
	assignmentID string,
	record *addonpb.TelemetryRecord,
	sample conditionSample,
	now time.Time,
) bool {
	scopeID := assignmentID + "\x00" + sample.scope
	entries := d.scopes[scopeID]
	prev, exists := entries[sample.key]

	prevEntry := conditionEntry{level: conditionLevelOK}
	if exists {
		prevEntry = prev.conditionEntry
	}
	effective := effectiveConditionLevel(sample, prevEntry.level)

	if effective == conditionLevelOK {
		if !exists {
			return false
		}
		d.forgetScopedLocked(scopeID, sample.key)
		return true
	}

	forward := conditionForwardDue(prevEntry, exists, effective, now)
	entry := &scopedConditionEntry{
		conditionEntry: conditionEntry{level: effective, seenAt: now, emittedAt: prevEntry.emittedAt},
	}
	if exists {
		entry.template = prev.template
	}
	if forward {
		entry.emittedAt = now
		entry.template = newConditionClearTemplate(record, sample)
	}
	if entries == nil {
		entries = make(map[string]*scopedConditionEntry)
		d.scopes[scopeID] = entries
	}
	entries[sample.key] = entry
	return forward
}

// completeScopeLocked synthesizes an ok clear for every remembered non-ok key in
// the marker's scope that the marker no longer lists, and forgets those keys.
// Keys the marker lists but the agent never saw are ignored: the plugin emits
// their events itself. Clears are returned sorted by condition_key.
func (d *pluginConditionDebouncer) completeScopeLocked(
	assignmentID string,
	marker conditionScopeMarker,
	now time.Time,
) []*addonpb.TelemetryRecord {
	scopeID := assignmentID + "\x00" + marker.scope
	entries := d.scopes[scopeID]
	if len(entries) == 0 {
		return nil
	}

	cleared := make([]string, 0, len(entries))
	for key := range entries {
		if _, active := marker.activeKeys[key]; active {
			continue
		}
		cleared = append(cleared, key)
	}
	sort.Strings(cleared)

	clears := make([]*addonpb.TelemetryRecord, 0, len(cleared))
	for _, key := range cleared {
		if record := d.synthesizeClear(entries[key].template, key, marker.scope, now); record != nil {
			clears = append(clears, record)
		}
		d.forgetScopedLocked(scopeID, key)
	}
	return clears
}

func (d *pluginConditionDebouncer) forgetScopedLocked(scopeID, key string) {
	entries := d.scopes[scopeID]
	delete(entries, key)
	if len(entries) == 0 {
		delete(d.scopes, scopeID)
	}
}

// newConditionClearTemplate copies the parts of a forwarded record a clear is
// built from. The copy matters: the record itself is handed downstream and may
// be reused or mutated after this call.
func newConditionClearTemplate(record *addonpb.TelemetryRecord, sample conditionSample) conditionClearTemplate {
	payload := record.GetPayload()
	if len(payload) > conditionTemplateMaxBytes {
		payload = reduceConditionTemplate(payload, sample)
	} else {
		payload = append([]byte(nil), payload...)
	}
	return conditionClearTemplate{
		payload:  payload,
		metadata: maps.Clone(record.GetMetadata()),
	}
}

// conditionTemplateKeptFields are the top-level OCSF fields an oversized
// template is reduced to: what the event writer requires, plus the event's
// provenance. The device is reduced to its identifying fields below.
var conditionTemplateKeptFields = []string{
	"class_uid", "category_uid", "type_uid", "activity_id", "activity_name",
	"log_name", "log_provider", "log_version",
}

// reduceConditionTemplate shrinks an oversized payload to the fields a clear
// needs, bounded by the lengths of the condition key, scope and device uid.
func reduceConditionTemplate(payload []byte, sample conditionSample) []byte {
	var event map[string]json.RawMessage
	if err := json.Unmarshal(payload, &event); err != nil {
		event = nil
	}
	reduced := make(map[string]any, len(conditionTemplateKeptFields)+2)
	for _, field := range conditionTemplateKeptFields {
		if raw, ok := event[field]; ok && len(raw) <= 256 {
			reduced[field] = raw
		}
	}
	var device struct {
		UID      string `json:"uid"`
		Name     string `json:"name"`
		Hostname string `json:"hostname"`
	}
	if raw, ok := event["device"]; ok && json.Unmarshal(raw, &device) == nil {
		kept := map[string]string{}
		for field, value := range map[string]string{"uid": device.UID, "name": device.Name, "hostname": device.Hostname} {
			if value != "" && len(value) <= 1024 {
				kept[field] = value
			}
		}
		if len(kept) > 0 {
			reduced["device"] = kept
		}
	}
	reduced["unmapped"] = map[string]string{
		"condition_key":   sample.key,
		"condition_scope": sample.scope,
	}
	out, err := json.Marshal(reduced)
	if err != nil {
		return nil
	}
	return out
}

// synthesizeClear builds the ok record that closes key. It keeps the template's
// class, device, record metadata (signal schema references) and unmapped
// fields, and replaces everything that describes the moment or the level: a
// fresh event id and time (the event writer de-duplicates on `id`), level ok,
// informational severity and a cleared message. The raise's measurement
// (`ratio`) and raw capture are dropped, since neither describes the clear.
func (d *pluginConditionDebouncer) synthesizeClear(
	template conditionClearTemplate,
	key, scope string,
	now time.Time,
) *addonpb.TelemetryRecord {
	if len(template.payload) == 0 {
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader(template.payload))
	decoder.UseNumber()
	var event map[string]any
	if err := decoder.Decode(&event); err != nil || event == nil {
		return nil
	}

	now = now.UTC()
	id := d.newID()
	event["id"] = id
	event["time"] = conditionEventTime(event["time"], now)
	event["severity_id"] = 1
	event["severity"] = "Informational"
	event["message"] = conditionClearedMessagePrefix + key
	delete(event, "raw_data")

	if metadata, ok := event["metadata"].(map[string]any); ok {
		if _, has := metadata["logged_time"]; has {
			metadata["logged_time"] = now.Format(time.RFC3339Nano)
		}
		if _, has := metadata["uid"]; has {
			metadata["uid"] = id
		}
	}

	unmapped, ok := event["unmapped"].(map[string]any)
	if !ok {
		unmapped = make(map[string]any)
		event["unmapped"] = unmapped
	}
	unmapped["condition_key"] = key
	unmapped["condition_scope"] = scope
	unmapped["level"] = "ok"
	unmapped["condition_cleared_by"] = conditionClearedBy
	delete(unmapped, "ratio")

	payload, err := json.Marshal(event)
	if err != nil {
		return nil
	}
	return &addonpb.TelemetryRecord{
		EventId:              id,
		ObservedTimeUnixNano: now.UnixNano(),
		EventTimeUnixNano:    now.UnixNano(),
		PayloadKind:          addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		Payload:              payload,
		Metadata:             maps.Clone(template.metadata),
	}
}

// conditionEventTime renders now in the representation the template used for
// `time`: epoch milliseconds (OCSF timestamp_t) when it was a number, otherwise
// an RFC 3339 string. The event writer accepts both.
func conditionEventTime(previous any, now time.Time) any {
	if _, isNumber := previous.(json.Number); isNumber {
		return now.UnixMilli()
	}
	return now.Format(time.RFC3339Nano)
}

// evictLocked forgets conditions not observed within conditionTTL. Eviction is
// silent for scoped keys too: it never synthesizes a clear, because an unseen
// key says nothing about whether the condition cleared.
func (d *pluginConditionDebouncer) evictLocked(now time.Time) {
	for key, entry := range d.state {
		if now.Sub(entry.seenAt) > conditionTTL {
			delete(d.state, key)
		}
	}
	for scopeID, entries := range d.scopes {
		for key, entry := range entries {
			if now.Sub(entry.seenAt) > conditionTTL {
				delete(entries, key)
			}
		}
		if len(entries) == 0 {
			delete(d.scopes, scopeID)
		}
	}
}
