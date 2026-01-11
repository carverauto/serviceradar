package models

import "time"

// Service represents a monitored service associated with a gateway.
type Service struct {
	GatewayID    string            `json:"gateway_id"`
	ServiceName string            `json:"service_name"`
	ServiceType string            `json:"service_type"`
	AgentID     string            `json:"agent_id"`
	DeviceID    string            `json:"device_id,omitempty"`
	Partition   string            `json:"partition,omitempty"`
	Timestamp   time.Time         `json:"timestamp"`
	Config      map[string]string `json:"config,omitempty"` // Service configuration including KV store info
}
