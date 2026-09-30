package sdk

import (
	"encoding/json"
	"fmt"
	"time"
)

// Run overrides are time-bounded state a plugin action leaves for later
// scheduled runs of the same assignment, such as an injected demo fault or a
// maintenance window. Plugin runs are stateless, so the action returns the
// override in its ActionResult and the ServiceRadar host delivers it to every
// later run until it expires.
//
// The action's descriptor must declare MaxOverrideDurationSeconds; ServiceRadar
// clamps every override to it and ignores overrides from actions without it.
//
// After expiry a run receives the override once more with Expired set, so the
// plugin can emit its resolving event; the host keeps delivering it expired
// until a run that received it submits a result.

const (
	// RunOverridesConfigKey is the host-owned config key carrying overrides.
	RunOverridesConfigKey = "_serviceradar_run_overrides"
	// RunOverridesSchemaV1 identifies the delivered override envelope.
	RunOverridesSchemaV1 = "serviceradar.plugin_run_overrides.v1"

	// RunOverrideOpSet sets or refreshes an override.
	RunOverrideOpSet = "set"
	// RunOverrideOpEnd ends an override early.
	RunOverrideOpEnd = "end"
)

// RunOverride is one override as a scheduled run receives it.
type RunOverride struct {
	ID        string         `json:"id"`
	Kind      string         `json:"kind"`
	Target    string         `json:"target,omitempty"`
	Params    map[string]any `json:"params,omitempty"`
	StartsAt  time.Time      `json:"starts_at"`
	ExpiresAt time.Time      `json:"expires_at"`
	// Expired is set on the delivery after ExpiresAt; emit the resolving event.
	Expired bool `json:"expired"`
}

// RunOverrideOperation is one change an action result makes to the overrides
// of its assignment.
type RunOverrideOperation struct {
	Op              string         `json:"op"`
	ID              string         `json:"id"`
	Kind            string         `json:"kind,omitempty"`
	Target          string         `json:"target,omitempty"`
	Params          map[string]any `json:"params,omitempty"`
	StartsAt        string         `json:"starts_at,omitempty"`
	ExpiresAt       string         `json:"expires_at,omitempty"`
	DurationSeconds int            `json:"duration_seconds,omitempty"`
}

type runOverrideEnvelope struct {
	Schema    string        `json:"schema"`
	Overrides []RunOverride `json:"overrides"`
}

// RunOverrides returns the overrides delivered to the current scheduled run.
func RunOverrides() ([]RunOverride, error) {
	data, err := getConfigBytes()
	if err != nil {
		return nil, err
	}
	return ParseRunOverrides(data)
}

// ParseRunOverrides extracts the delivered overrides from a run config
// document. A config without overrides yields an empty list.
func ParseRunOverrides(configJSON []byte) ([]RunOverride, error) {
	if len(configJSON) == 0 {
		return nil, nil
	}

	var config map[string]json.RawMessage
	if err := json.Unmarshal(configJSON, &config); err != nil {
		return nil, fmt.Errorf("decode run config: %w", err)
	}
	raw, ok := config[RunOverridesConfigKey]
	if !ok {
		return nil, nil
	}

	var envelope runOverrideEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, fmt.Errorf("decode run overrides: %w", err)
	}
	if envelope.Schema != RunOverridesSchemaV1 {
		return nil, fmt.Errorf("unsupported run overrides schema %q", envelope.Schema)
	}
	return envelope.Overrides, nil
}

// ActiveAt reports whether the override applies at t (started and not expired).
func (o RunOverride) ActiveAt(t time.Time) bool {
	return !t.Before(o.StartsAt) && t.Before(o.ExpiresAt)
}

// SetRunOverride asks the host to deliver an override to later runs for the
// given duration (clamped to the descriptor's maximum).
func (r *ActionResult) SetRunOverride(id, kind, target string, duration time.Duration, params map[string]any) *ActionResult {
	r.RunOverrides = append(r.RunOverrides, RunOverrideOperation{
		Op:              RunOverrideOpSet,
		ID:              id,
		Kind:            kind,
		Target:          target,
		Params:          params,
		DurationSeconds: int(duration / time.Second),
	})
	return r
}

// EndRunOverride asks the host to stop delivering an override now.
func (r *ActionResult) EndRunOverride(id string) *ActionResult {
	r.RunOverrides = append(r.RunOverrides, RunOverrideOperation{Op: RunOverrideOpEnd, ID: id})
	return r
}

// WithMaxOverrideDuration declares how long overrides returned by this action
// may last. Actions without it cannot set run overrides.
func (d *ActionDescriptor) WithMaxOverrideDuration(seconds int) *ActionDescriptor {
	d.MaxOverrideDurationSeconds = seconds
	return d
}

// EmitOCSFEvent emits one OCSF event through the host telemetry path. It works
// from both scheduled runs and action entrypoints (for example the opening
// event of a fault an action injects), and requires the emit_telemetry
// capability.
func EmitOCSFEvent(event OCSFEvent) error {
	return EmitTelemetry(TelemetryBatch{Records: []TelemetryRecord{NewOCSFTelemetryRecord(event)}})
}
