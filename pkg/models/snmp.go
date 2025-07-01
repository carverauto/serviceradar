package models

import (
	"encoding/json"
	"time"

	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
)

type Duration time.Duration

// SNMPConfig represents SNMP checker configuration.
type SNMPConfig struct {
	NodeAddress string          `json:"node_address"`
	Timeout     Duration        `json:"timeout"`
	ListenAddr  string          `json:"listen_addr"`
	Security    *SecurityConfig `json:"security"`
	Targets     []Target        `json:"targets"`
}
type SNMPDiscoveryDataPayload struct {
	Devices    []*discoverypb.DiscoveredDevice    `json:"devices"`
	Interfaces []*discoverypb.DiscoveredInterface `json:"interfaces"`
	Topology   []*discoverypb.TopologyLink        `json:"topology"`
	AgentID    string                             `json:"agent_id"`  // Agent that ran the discovery engine
	PollerID   string                             `json:"poller_id"` // Poller that initiated the discovery
}

// ServiceMetricsPayload is the enhanced payload structure for ALL service metrics reports.
// It includes metadata about the collector infrastructure along with the service-specific data.
type ServiceMetricsPayload struct {
	PollerID    string          `json:"poller_id"`    // Poller that collected the metrics
	AgentID     string          `json:"agent_id"`     // Agent that the poller belongs to
	Partition   string          `json:"partition"`    // Partition for the collection
	ServiceType string          `json:"service_type"` // Type of service (snmp, sysmon, icmp, etc.)
	ServiceName string          `json:"service_name"` // Name of the service instance
	Data        json.RawMessage `json:"data"`         // Service-specific data payload
}

// SNMPMetricsPayload is the enhanced payload structure for SNMP metrics reports.
// It includes metadata about the collector infrastructure along with the target data.
// Deprecated: Use ServiceMetricsPayload instead
type SNMPMetricsPayload struct {
	PollerID  string          `json:"poller_id"` // Poller that collected the metrics
	AgentID   string          `json:"agent_id"`  // Agent that the poller belongs to
	Partition string          `json:"partition"` // Partition from SNMP checker config
	Targets   json.RawMessage `json:"targets"`   // Target statuses and metrics (map[string]snmp.TargetStatus)
}
