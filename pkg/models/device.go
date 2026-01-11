package models

import (
	"time"
)

// Device represents a network device.
type Device struct {
	DeviceID         string                 `json:"device_id"`
	AgentID          string                 `json:"agent_id"`
	GatewayID         string                 `json:"gateway_id"`
	DiscoverySources []string               `json:"discovery_sources"`
	IP               string                 `json:"ip"`
	MAC              string                 `json:"mac,omitempty"`
	Hostname         string                 `json:"hostname,omitempty"`
	FirstSeen        time.Time              `json:"first_seen"`
	LastSeen         time.Time              `json:"last_seen"`
	IsAvailable      bool                   `json:"is_available"`
	ServiceType      string                 `json:"service_type,omitempty"`
	ServiceStatus    string                 `json:"service_status,omitempty"`
	LastHeartbeat    *time.Time             `json:"last_heartbeat,omitempty"`
	DeviceType       string                 `json:"device_type,omitempty"`
	OSInfo           string                 `json:"os_info,omitempty"`
	VersionInfo      string                 `json:"version_info,omitempty"`
	Metadata         map[string]interface{} `json:"metadata,omitempty"`
}
