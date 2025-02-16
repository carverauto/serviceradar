package db

import "time"

// NodeHistoryPoint represents a single point in a node's history.
type NodeHistoryPoint struct {
	Timestamp time.Time `json:"timestamp"`
	IsHealthy bool      `json:"is_healthy"`
}

// NodeStatus represents a node's current status.
type NodeStatus struct {
	NodeID    string    `json:"node_id"`
	IsHealthy bool      `json:"is_healthy"`
	FirstSeen time.Time `json:"first_seen"`
	LastSeen  time.Time `json:"last_seen"`
}

// ServiceStatus represents a service's status.
type ServiceStatus struct {
	NodeID      string    `json:"node_id"`
	ServiceName string    `json:"service_name"`
	ServiceType string    `json:"service_type"`
	Available   bool      `json:"available"`
	Details     string    `json:"details"`
	Timestamp   time.Time `json:"timestamp"`
}

type SNMPMetric struct {
	OIDName   string      `json:"oid_name"`
	Value     interface{} `json:"value"`
	ValueType string      `json:"value_type"`
	Timestamp time.Time   `json:"timestamp"`
	Scale     float64     `json:"scale"`
	IsDelta   bool        `json:"is_delta"`
}
