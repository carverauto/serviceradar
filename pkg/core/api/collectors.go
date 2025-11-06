package api

import (
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// CollectorCapabilityResponse surfaces explicit collector capability details for a device.
type CollectorCapabilityResponse struct {
	HasCollector   bool       `json:"has_collector"`
	SupportsICMP   bool       `json:"supports_icmp"`
	SupportsSNMP   bool       `json:"supports_snmp"`
	SupportsSysmon bool       `json:"supports_sysmon"`
	Capabilities   []string   `json:"capabilities,omitempty"`
	AgentID        string     `json:"agent_id,omitempty"`
	PollerID       string     `json:"poller_id,omitempty"`
	ServiceName    string     `json:"service_name,omitempty"`
	LastSeen       *time.Time `json:"last_seen,omitempty"`
}

func toCollectorCapabilityResponse(record *models.CollectorCapability) *CollectorCapabilityResponse {
	if record == nil || len(record.Capabilities) == 0 {
		return nil
	}

	resp := &CollectorCapabilityResponse{
		HasCollector: true,
		Capabilities: append([]string(nil), record.Capabilities...),
		AgentID:      record.AgentID,
		PollerID:     record.PollerID,
		ServiceName:  record.ServiceName,
	}

	if !record.LastSeen.IsZero() {
		ts := record.LastSeen.UTC()
		resp.LastSeen = &ts
	}

	for _, capability := range record.Capabilities {
		switch strings.ToLower(strings.TrimSpace(capability)) {
		case "icmp":
			resp.SupportsICMP = true
		case "snmp":
			resp.SupportsSNMP = true
		case "sysmon":
			resp.SupportsSysmon = true
		}
	}

	return resp
}

// CapabilitySnapshotResponse surfaces per-capability state tracked in the capability matrix.
type CapabilitySnapshotResponse struct {
	Capability    string         `json:"capability"`
	ServiceID     string         `json:"service_id,omitempty"`
	ServiceType   string         `json:"service_type,omitempty"`
	State         string         `json:"state,omitempty"`
	Enabled       bool           `json:"enabled"`
	LastChecked   string         `json:"last_checked,omitempty"`
	LastSuccess   string         `json:"last_success,omitempty"`
	LastFailure   string         `json:"last_failure,omitempty"`
	FailureReason string         `json:"failure_reason,omitempty"`
	Metadata      map[string]any `json:"metadata,omitempty"`
	RecordedBy    string         `json:"recorded_by,omitempty"`
}

func toCapabilitySnapshotResponse(snapshot *models.DeviceCapabilitySnapshot) *CapabilitySnapshotResponse {
	if snapshot == nil || snapshot.Capability == "" {
		return nil
	}

	resp := &CapabilitySnapshotResponse{
		Capability:    snapshot.Capability,
		ServiceID:     snapshot.ServiceID,
		ServiceType:   snapshot.ServiceType,
		State:         snapshot.State,
		Enabled:       snapshot.Enabled,
		FailureReason: snapshot.FailureReason,
		Metadata:      snapshot.Metadata,
		RecordedBy:    snapshot.RecordedBy,
	}

	if !snapshot.LastChecked.IsZero() {
		resp.LastChecked = snapshot.LastChecked.UTC().Format(time.RFC3339Nano)
	}
	if snapshot.LastSuccess != nil && !snapshot.LastSuccess.IsZero() {
		resp.LastSuccess = snapshot.LastSuccess.UTC().Format(time.RFC3339Nano)
	}
	if snapshot.LastFailure != nil && !snapshot.LastFailure.IsZero() {
		resp.LastFailure = snapshot.LastFailure.UTC().Format(time.RFC3339Nano)
	}

	return resp
}

func toCapabilitySnapshotResponses(snapshots []*models.DeviceCapabilitySnapshot) []*CapabilitySnapshotResponse {
	if len(snapshots) == 0 {
		return nil
	}

	results := make([]*CapabilitySnapshotResponse, 0, len(snapshots))
	for _, snapshot := range snapshots {
		if resp := toCapabilitySnapshotResponse(snapshot); resp != nil {
			results = append(results, resp)
		}
	}
	if len(results) == 0 {
		return nil
	}
	return results
}
