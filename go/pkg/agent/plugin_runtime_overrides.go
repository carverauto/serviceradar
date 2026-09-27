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
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// Run overrides are time-bounded state that a plugin action leaves for later
// scheduled runs of the same assignment (a demo fault, a maintenance window).
// Plugin runs are stateless, so the host keeps them and merges the deliverable
// set into each scheduled run's config under runOverridesConfigKey.
//
// Two sources feed the set:
//   - the control plane, through PluginAssignmentConfig.run_overrides_json.
//     This copy is authoritative: core clamps each override to its action
//     descriptor's maximum duration and forgets it once acknowledged.
//   - the action result the agent just captured. Applying it locally lets the
//     very next run see a new fault without waiting for a config poll. A local
//     entry lives only until the config names the same id, or for
//     runOverrideLocalTTL, so an override core rejected cannot outlive a poll.
//
// An override is delivered active until expires_at, then marked expired until
// a run that received it submits a result. The agent then reports the id in the
// result's host-authored run_overrides_acknowledged list and stops delivering it.
const (
	runOverridesConfigKey    = "_serviceradar_run_overrides"
	runOverridesSchema       = "serviceradar.plugin_run_overrides.v1"
	runOverridesAckKey       = "run_overrides_acknowledged"
	runOverrideLocalTTL      = 2 * time.Minute
	runOverrideMaxPerSet     = 64
	runOverrideMaxIDLength   = 128
	runOverrideOperationSet  = "set"
	runOverrideOperationEnd  = "end"
	runOverrideActionOpsKey  = "run_overrides"
	runOverrideDefaultExpiry = 10 * time.Minute
)

var errRunOverridesSchema = errors.New("unexpected run overrides schema")

// pluginRunOverride is one override as the host delivers it to a plugin.
type pluginRunOverride struct {
	ID        string          `json:"id"`
	Kind      string          `json:"kind"`
	Target    string          `json:"target,omitempty"`
	Params    json.RawMessage `json:"params,omitempty"`
	StartsAt  time.Time       `json:"starts_at"`
	ExpiresAt time.Time       `json:"expires_at"`
	Expired   bool            `json:"expired"`
}

type runOverrideEnvelope struct {
	Schema    string              `json:"schema"`
	Overrides []pluginRunOverride `json:"overrides"`
}

type localRunOverride struct {
	override   pluginRunOverride
	recordedAt time.Time
}

type assignmentRunOverrides struct {
	config []pluginRunOverride
	local  map[string]localRunOverride
	ended  map[string]time.Time
	acked  map[string]struct{}
}

// runOverrideStore holds the per-assignment override state of one agent.
type runOverrideStore struct {
	mu          sync.Mutex
	assignments map[string]*assignmentRunOverrides
}

func newRunOverrideStore() *runOverrideStore {
	return &runOverrideStore{assignments: make(map[string]*assignmentRunOverrides)}
}

func (s *runOverrideStore) entry(assignmentID string) *assignmentRunOverrides {
	state, ok := s.assignments[assignmentID]
	if !ok {
		state = &assignmentRunOverrides{
			local: make(map[string]localRunOverride),
			ended: make(map[string]time.Time),
			acked: make(map[string]struct{}),
		}
		s.assignments[assignmentID] = state
	}
	return state
}

// parseRunOverridesConfig decodes PluginAssignmentConfig.run_overrides_json.
func parseRunOverridesConfig(raw []byte) ([]pluginRunOverride, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil, nil
	}

	var envelope runOverrideEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, fmt.Errorf("decode run overrides: %w", err)
	}
	if envelope.Schema != runOverridesSchema {
		return nil, fmt.Errorf("%w: %q", errRunOverridesSchema, envelope.Schema)
	}

	overrides := make([]pluginRunOverride, 0, len(envelope.Overrides))
	for _, override := range envelope.Overrides {
		if !validRunOverride(override) {
			continue
		}
		override.Expired = false
		overrides = append(overrides, override)
		if len(overrides) >= runOverrideMaxPerSet {
			break
		}
	}
	return overrides, nil
}

func validRunOverride(override pluginRunOverride) bool {
	id := strings.TrimSpace(override.ID)
	return id != "" && len(id) <= runOverrideMaxIDLength &&
		strings.TrimSpace(override.Kind) != "" &&
		!override.ExpiresAt.IsZero() && override.ExpiresAt.After(override.StartsAt)
}

// applyConfig replaces the authoritative overrides of the given assignments and
// forgets state for assignments that no longer exist.
func (s *runOverrideStore) applyConfig(assignments []*pluginAssignment, now time.Time) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	present := make(map[string]struct{}, len(assignments))
	for _, assignment := range assignments {
		if assignment == nil {
			continue
		}
		present[assignment.AssignmentID] = struct{}{}
		state := s.entry(assignment.AssignmentID)
		state.config = append([]pluginRunOverride(nil), assignment.runOverrides...)

		inConfig := make(map[string]struct{}, len(state.config))
		for _, override := range state.config {
			inConfig[override.ID] = struct{}{}
			delete(state.local, override.ID)
		}
		// An acknowledged id core has dropped needs no more suppression.
		for id := range state.acked {
			if _, ok := inConfig[id]; !ok {
				delete(state.acked, id)
			}
		}
		pruneRunOverrideLocalState(state, now)
	}

	for id := range s.assignments {
		if _, ok := present[id]; !ok {
			delete(s.assignments, id)
		}
	}
}

func pruneRunOverrideLocalState(state *assignmentRunOverrides, now time.Time) {
	for id, local := range state.local {
		if now.Sub(local.recordedAt) > runOverrideLocalTTL {
			delete(state.local, id)
		}
	}
	for id, endedAt := range state.ended {
		if now.Sub(endedAt) > runOverrideLocalTTL {
			delete(state.ended, id)
		}
	}
}

// recordActionResult applies the run_overrides operations of an action result
// the agent just captured, as a short-lived local overlay.
func (s *runOverrideStore) recordActionResult(assignmentID string, result []byte, now time.Time) {
	if s == nil || strings.TrimSpace(assignmentID) == "" || len(result) == 0 {
		return
	}

	var payload struct {
		Status     string `json:"status"`
		Operations []struct {
			Op              string          `json:"op"`
			ID              string          `json:"id"`
			Kind            string          `json:"kind"`
			Target          string          `json:"target"`
			Params          json.RawMessage `json:"params"`
			StartsAt        *time.Time      `json:"starts_at"`
			ExpiresAt       *time.Time      `json:"expires_at"`
			DurationSeconds int64           `json:"duration_seconds"`
		} `json:"run_overrides"`
	}
	if err := json.Unmarshal(result, &payload); err != nil || len(payload.Operations) == 0 {
		return
	}
	// Mirror core: only a succeeded action may change later runs.
	switch strings.ToLower(strings.TrimSpace(payload.Status)) {
	case "succeeded", "success", "completed":
	default:
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	state := s.entry(assignmentID)

	for i, op := range payload.Operations {
		if i >= runOverrideMaxPerSet {
			break
		}
		id := strings.TrimSpace(op.ID)
		if id == "" || len(id) > runOverrideMaxIDLength {
			continue
		}

		switch op.Op {
		case runOverrideOperationEnd:
			delete(state.local, id)
			state.ended[id] = now
		case runOverrideOperationSet:
			override := pluginRunOverride{
				ID:       id,
				Kind:     strings.TrimSpace(op.Kind),
				Target:   op.Target,
				Params:   op.Params,
				StartsAt: now,
			}
			if op.StartsAt != nil {
				override.StartsAt = *op.StartsAt
			}
			switch {
			case op.ExpiresAt != nil:
				override.ExpiresAt = *op.ExpiresAt
			case op.DurationSeconds > 0:
				override.ExpiresAt = override.StartsAt.Add(time.Duration(op.DurationSeconds) * time.Second)
			default:
				override.ExpiresAt = override.StartsAt.Add(runOverrideDefaultExpiry)
			}
			if !validRunOverride(override) {
				continue
			}
			delete(state.ended, id)
			delete(state.acked, id)
			state.local[id] = localRunOverride{override: override, recordedAt: now}
		}
	}
}

// deliver returns the overrides a scheduled run of the assignment receives now,
// and the ids among them delivered marked expired.
func (s *runOverrideStore) deliver(assignmentID string, now time.Time) ([]pluginRunOverride, []string) {
	if s == nil {
		return nil, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	state, ok := s.assignments[assignmentID]
	if !ok {
		return nil, nil
	}
	pruneRunOverrideLocalState(state, now)

	byID := make(map[string]pluginRunOverride, len(state.config)+len(state.local))
	for _, override := range state.config {
		byID[override.ID] = override
	}
	for id, local := range state.local {
		if _, ok := byID[id]; !ok {
			byID[id] = local.override
		}
	}

	delivered := make([]pluginRunOverride, 0, len(byID))
	var expired []string
	for id, override := range byID {
		if _, ended := state.ended[id]; ended {
			continue
		}
		if _, acked := state.acked[id]; acked {
			continue
		}
		if now.Before(override.StartsAt) {
			continue
		}
		override.Expired = !now.Before(override.ExpiresAt)
		if override.Expired {
			expired = append(expired, id)
		}
		delivered = append(delivered, override)
	}

	sort.Slice(delivered, func(i, j int) bool { return delivered[i].ID < delivered[j].ID })
	sort.Strings(expired)
	return delivered, expired
}

// acknowledge records that a run which received the given expired overrides
// submitted its result; they are no longer delivered.
func (s *runOverrideStore) acknowledge(assignmentID string, ids []string) {
	if s == nil || len(ids) == 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.entry(assignmentID)
	for _, id := range ids {
		state.acked[id] = struct{}{}
		delete(state.local, id)
	}
}

// mergeRunOverridesIntoConfig returns params with runOverridesConfigKey set to
// the delivered overrides. The key is always host-owned: a value an operator or
// plugin placed there is removed even when nothing is delivered. Non-object
// params are returned unchanged.
func mergeRunOverridesIntoConfig(params []byte, overrides []pluginRunOverride) ([]byte, error) {
	trimmed := bytes.TrimSpace(params)
	config := map[string]json.RawMessage{}
	if len(trimmed) > 0 {
		if trimmed[0] != '{' {
			return params, nil
		}
		if err := json.Unmarshal(trimmed, &config); err != nil {
			return params, nil
		}
	}

	_, hadKey := config[runOverridesConfigKey]
	if len(overrides) == 0 {
		if !hadKey {
			return params, nil
		}
		delete(config, runOverridesConfigKey)
		return json.Marshal(config)
	}

	envelope, err := json.Marshal(runOverrideEnvelope{Schema: runOverridesSchema, Overrides: overrides})
	if err != nil {
		return nil, fmt.Errorf("encode run overrides: %w", err)
	}
	config[runOverridesConfigKey] = envelope
	return json.Marshal(config)
}

// applyRunOverrides merges the deliverable run overrides into a scheduled run's
// config and remembers which were delivered expired.
func (e *pluginExecution) applyRunOverrides(now time.Time) {
	if e == nil || e.manager == nil || e.assignment == nil || e.mode != pluginExecutionModeScheduled {
		return
	}

	overrides, expired := e.manager.runOverrides.deliver(e.assignment.AssignmentID, now)
	config, err := mergeRunOverridesIntoConfig(e.configJSON, overrides)
	if err != nil {
		e.manager.logger.Warn().
			Err(err).
			Str("assignment_id", e.assignment.AssignmentID).
			Msg("Running plugin without run overrides")
		return
	}
	e.configJSON = config
	e.expiredRunOverrides = expired
}
