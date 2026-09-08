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
	"strings"
	"sync"
	"time"

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
	level      conditionLevel
	ratio      *float64
	warn, crit *float64
}

type conditionUnmapped struct {
	Unmapped struct {
		ConditionKey string   `json:"condition_key"`
		Level        string   `json:"level"`
		Ratio        *float64 `json:"ratio"`
		Warn         *float64 `json:"warn"`
		Crit         *float64 `json:"crit"`
	} `json:"unmapped"`
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
		level: parseConditionLevel(level),
		ratio: env.Unmapped.Ratio,
		warn:  env.Unmapped.Warn,
		crit:  env.Unmapped.Crit,
	}, true
}

type conditionEntry struct {
	level     conditionLevel
	emittedAt time.Time
	seenAt    time.Time
}

// pluginConditionDebouncer remembers the last emitted level for each
// (assignment, condition_key) so it can forward a condition event only when the
// level transitions (with hysteresis), collapsing the per-cycle repeats a
// stateless plugin necessarily produces.
type pluginConditionDebouncer struct {
	mu    sync.Mutex
	now   func() time.Time
	state map[string]conditionEntry
}

func newPluginConditionDebouncer(now func() time.Time) *pluginConditionDebouncer {
	if now == nil {
		now = time.Now
	}
	return &pluginConditionDebouncer{
		now:   now,
		state: make(map[string]conditionEntry),
	}
}

// filter returns the batch with suppressed condition records removed. Records
// that are not condition events pass through untouched. A nil debouncer is a
// no-op so callers need not special-case it.
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
		if d.shouldForwardLocked(assignmentID, record, now) {
			kept = append(kept, record)
		}
	}
	batch.Records = kept
	return batch
}

func (d *pluginConditionDebouncer) shouldForwardLocked(assignmentID string, record *addonpb.TelemetryRecord, now time.Time) bool {
	if record == nil {
		return false
	}
	if record.GetPayloadKind() != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT {
		return true
	}

	sample, ok := parseConditionSample(record.GetPayload())
	if !ok {
		// Not a condition event (e.g. a plain plugin log/event): never suppress.
		return true
	}

	stateKey := assignmentID + "\x00" + sample.key
	prev, exists := d.state[stateKey]

	// Effective level: apply hysteresis when the raw ratio + thresholds are
	// present, otherwise fall back to the discrete level the plugin reported
	// (health-style conditions have no ratio and simply de-dup on exact level).
	effective := sample.level
	if sample.ratio != nil && sample.warn != nil && sample.crit != nil {
		prevLevel := conditionLevelOK
		if exists {
			prevLevel = prev.level
		}
		effective = nextConditionLevel(prevLevel, *sample.ratio, *sample.warn, *sample.crit, conditionHysteresisMargin)
	}

	forward := false
	switch {
	case !exists:
		forward = true
	case effective != prev.level:
		forward = true
	case now.Sub(prev.emittedAt) >= conditionRefreshInterval:
		forward = true
	}

	entry := conditionEntry{level: effective, seenAt: now, emittedAt: prev.emittedAt}
	if forward {
		entry.emittedAt = now
	}
	d.state[stateKey] = entry
	return forward
}

func (d *pluginConditionDebouncer) evictLocked(now time.Time) {
	for key, entry := range d.state {
		if now.Sub(entry.seenAt) > conditionTTL {
			delete(d.state, key)
		}
	}
}
