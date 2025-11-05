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
