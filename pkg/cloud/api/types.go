package api

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/gorilla/mux"
)

type ServiceStatus struct {
	Name      string          `json:"name"`
	Available bool            `json:"available"`
	Message   string          `json:"message"`
	Type      string          `json:"type"`    // e.g., "process", "port", "blockchain", etc.
	Details   json.RawMessage `json:"details"` // Flexible field for service-specific data
}

type NodeStatus struct {
	NodeID     string               `json:"node_id"`
	IsHealthy  bool                 `json:"is_healthy"`
	LastUpdate time.Time            `json:"last_update"`
	Services   []ServiceStatus      `json:"services"`
	UpTime     string               `json:"uptime"`
	FirstSeen  time.Time            `json:"first_seen"`
	Metrics    []models.MetricPoint `json:"metrics,omitempty"`
}

type SystemStatus struct {
	TotalNodes   int       `json:"total_nodes"`
	HealthyNodes int       `json:"healthy_nodes"`
	LastUpdate   time.Time `json:"last_update"`
}

type NodeHistory struct {
	NodeID    string
	Timestamp time.Time
	IsHealthy bool
	Services  []ServiceStatus
}

type NodeHistoryPoint struct {
	Timestamp time.Time `json:"timestamp"`
	IsHealthy bool      `json:"is_healthy"`
}

type APIServer struct {
	mu                 sync.RWMutex
	nodes              map[string]*NodeStatus
	router             *mux.Router
	nodeHistoryHandler func(nodeID string) ([]NodeHistoryPoint, error)
	metricsManager     metrics.MetricCollector
	snmpManager        snmp.SNMPManager
	db                 db.Service
	knownPollers       []string
}
