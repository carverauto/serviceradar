package metrics

import (
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

type MetricsManager struct {
	nodes       sync.Map // Map of nodeID -> *NodeMetrics
	config      models.MetricsConfig
	activeNodes int64 // Atomic counter for active nodes
}

func NewMetricsManager(cfg models.MetricsConfig) *MetricsManager {
	log.Printf("Creating MetricsManager with config: %+v", cfg)

	return &MetricsManager{
		config: cfg,
	}
}

func (m *MetricsManager) AddMetric(nodeID string, timestamp time.Time, responseTime int64, serviceName string) error {
	log.Printf(
		"AddMetric called for nodeID: %s, timestamp: %v, responseTime: %d, serviceName: %s",
		nodeID, timestamp, responseTime, serviceName)

	if !m.config.Enabled {
		log.Printf("Metrics are disabled")
		return nil
	}

	// Load or create the NodeMetrics for this node
	nodeMetrics, loaded := m.nodes.LoadOrStore(nodeID, &NodeMetrics{
		buffer: NewMetricBuffer(m.config.Retention),
	})

	// Increment activeNodes counter if this is a new node
	if !loaded {
		atomic.AddInt64(&m.activeNodes, 1)
	}

	// Cast to NodeMetrics
	nm := nodeMetrics.(*NodeMetrics)

	// Use fine-grained lock for this node
	nm.mu.Lock()
	defer nm.mu.Unlock()

	// Add the metric and return any error
	return nm.buffer.Add(timestamp, responseTime, serviceName)
}

func (m *MetricsManager) GetMetrics(nodeID string) []models.MetricPoint {
	log.Printf("GetMetrics called for nodeID: %s", nodeID)

	// Load the NodeMetrics for this node
	nodeMetrics, ok := m.nodes.Load(nodeID)
	if !ok {
		return nil
	}

	// Cast to NodeMetrics
	nm := nodeMetrics.(*NodeMetrics)

	// Use fine-grained lock for this node
	nm.mu.RLock()
	defer nm.mu.RUnlock()

	return nm.buffer.GetPoints()
}

func (m *MetricsManager) GetActiveNodes() int64 {
	return atomic.LoadInt64(&m.activeNodes)
}
