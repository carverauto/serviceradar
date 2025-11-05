package models

import "time"

// CollectorCapability describes the collectors currently responsible for a device.
// Capabilities are explicit strings such as "icmp", "snmp", or "sysmon".
type CollectorCapability struct {
	DeviceID     string    `json:"device_id"`
	Capabilities []string  `json:"capabilities"`
	AgentID      string    `json:"agent_id,omitempty"`
	PollerID     string    `json:"poller_id,omitempty"`
	LastSeen     time.Time `json:"last_seen"`
	ServiceName  string    `json:"service_name,omitempty"`
}
