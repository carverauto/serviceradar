package models

import (
	"time"
)

// Device represents a network device.
type Device struct {
	DeviceID        string                 `json:"device_id"`
	PollerID        string                 `json:"poller_id"`
	DiscoverySource string                 `json:"discovery_source"`
	IP              string                 `json:"ip"`
	MAC             string                 `json:"mac,omitempty"`
	Hostname        string                 `json:"hostname,omitempty"`
	FirstSeen       time.Time              `json:"first_seen"`
	LastSeen        time.Time              `json:"last_seen"`
	IsAvailable     bool                   `json:"is_available"`
	Metadata        map[string]interface{} `json:"metadata,omitempty"`
}
