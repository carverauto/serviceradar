package models

import (
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
	"time"
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
