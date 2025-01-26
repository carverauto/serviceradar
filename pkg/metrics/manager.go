package metrics

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

type Manager struct {
	nodes       sync.Map // Map of nodeID -> MetricStore
	config      models.MetricsConfig
	activeNodes int64
}

func NewManager(cfg models.MetricsConfig) MetricCollector {
	return &Manager{
		config: cfg,
	}
}

func (m *Manager) AddMetric(nodeID string, timestamp time.Time, responseTime int64, serviceName string) error {
	if !m.config.Enabled {
		return nil
	}

	// Load or create metric store for this node
	store, loaded := m.nodes.LoadOrStore(nodeID, NewBuffer(m.config.Retention))
	if !loaded {
		atomic.AddInt64(&m.activeNodes, 1)
	}

	store.(MetricStore).Add(timestamp, responseTime, serviceName)
	return nil
}

func (m *Manager) GetMetrics(nodeID string) []models.MetricPoint {
	store, ok := m.nodes.Load(nodeID)
	if !ok {
		return nil
	}
	return store.(MetricStore).GetPoints()
}

func (m *Manager) GetActiveNodes() int64 {
	return atomic.LoadInt64(&m.activeNodes)
}
