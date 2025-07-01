package models

import "time"

// Service represents a monitored service associated with a poller.
type Service struct {
	PollerID    string    `json:"poller_id"`
	ServiceName string    `json:"service_name"`
	ServiceType string    `json:"service_type"`
	AgentID     string    `json:"agent_id"`
	DeviceID    string    `json:"device_id,omitempty"`
	Partition   string    `json:"partition,omitempty"`
	Timestamp   time.Time `json:"timestamp"`
}
