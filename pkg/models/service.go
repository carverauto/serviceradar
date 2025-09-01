package models

import "time"

// Service represents a monitored service associated with a poller.
type Service struct {
    PollerID    string            `json:"poller_id"`
    ServiceName string            `json:"service_name"`
    ServiceType string            `json:"service_type"`
    AgentID     string            `json:"agent_id"`
    DeviceID    string            `json:"device_id,omitempty"`
    Partition   string            `json:"partition,omitempty"`
    Timestamp   time.Time         `json:"timestamp"`
    // Config holds merged, JSON-capable configuration for the service:
    // - top-level kv_* metadata (kv_store_id, kv_enabled, kv_configured)
    // - service's own config fields from getStatus payloads
    // This is marshaled to a JSON string for storage in the services stream.
    Config      map[string]interface{} `json:"config,omitempty"`
}
