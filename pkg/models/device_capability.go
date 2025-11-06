package models

import "time"

// DeviceCapabilityEvent captures a single capability check result emitted by a
// poller/agent for audit purposes. Events land in the ClickHouse Stream
// `device_capabilities`.
type DeviceCapabilityEvent struct {
	EventID       string         `json:"event_id"`
	DeviceID      string         `json:"device_id"`
	ServiceID     string         `json:"service_id,omitempty"`
	ServiceType   string         `json:"service_type,omitempty"`
	Capability    string         `json:"capability"`
	State         string         `json:"state,omitempty"`
	Enabled       bool           `json:"enabled"`
	LastChecked   time.Time      `json:"last_checked"`
	LastSuccess   *time.Time     `json:"last_success,omitempty"`
	LastFailure   *time.Time     `json:"last_failure,omitempty"`
	FailureReason string         `json:"failure_reason,omitempty"`
	Metadata      map[string]any `json:"metadata,omitempty"`
	RecordedBy    string         `json:"recorded_by,omitempty"`
}

// DeviceCapabilitySnapshot reflects the most recent state for a capability in
// the versioned_kv registry (`device_capability_registry`).
type DeviceCapabilitySnapshot struct {
	DeviceID      string         `json:"device_id"`
	ServiceID     string         `json:"service_id,omitempty"`
	ServiceType   string         `json:"service_type,omitempty"`
	Capability    string         `json:"capability"`
	State         string         `json:"state,omitempty"`
	Enabled       bool           `json:"enabled"`
	LastChecked   time.Time      `json:"last_checked"`
	LastSuccess   *time.Time     `json:"last_success,omitempty"`
	LastFailure   *time.Time     `json:"last_failure,omitempty"`
	FailureReason string         `json:"failure_reason,omitempty"`
	Metadata      map[string]any `json:"metadata,omitempty"`
	RecordedBy    string         `json:"recorded_by,omitempty"`
}
