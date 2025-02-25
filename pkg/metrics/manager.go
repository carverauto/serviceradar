package metrics

import (
	"container/list"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

type Manager struct {
	nodes       sync.Map // map of nodeID -> MetricStore
	config      models.MetricsConfig
	activeNodes atomic.Int64
	nodeCount   atomic.Int64 // Track total nodes for enforcing limits
	evictList   *list.List   // LRU tracking
	evictMap    sync.Map     // map[string]*list.Element for O(1) lookups
	mu          sync.RWMutex // Protects eviction logic
}

func NewManager(cfg models.MetricsConfig) MetricCollector {
	if cfg.MaxNodes == 0 {
		cfg.MaxNodes = 10000 // Reasonable default
	}

	return &Manager{
		config:    cfg,
		evictList: list.New(),
	}
}

func (m *Manager) CleanupStaleNodes(staleDuration time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()

	now := time.Now()
	staleThreshold := now.Add(-staleDuration)

	// Iterate through nodes and remove stale ones
	m.nodes.Range(func(key, value interface{}) bool {
		nodeID := key.(string)
		store := value.(MetricStore)

		lastPoint := store.GetLastPoint()
		if lastPoint != nil && lastPoint.Timestamp.Before(staleThreshold) {
			if _, ok := m.nodes.LoadAndDelete(nodeID); ok {
				m.nodeCount.Add(-1)
				m.activeNodes.Add(-1)

				// Also remove from LRU tracking
				if element, ok := m.evictMap.Load(nodeID); ok {
					m.evictList.Remove(element.(*list.Element))
					m.evictMap.Delete(nodeID)
				}
			}
		}

		return true
	})
}

func (m *Manager) AddMetric(nodeID string, timestamp time.Time, responseTime int64, serviceName string) error {
	if !m.config.Enabled {
		return nil
	}

	// Update LRU tracking first
	m.updateNodeLRU(nodeID)

	// Check if we need to evict
	if m.nodeCount.Load() >= int64(m.config.MaxNodes) {
		if err := m.evictOldest(); err != nil {
			log.Printf("Failed to evict old node: %v", err)
		}
	}

	// Load or create metric store for this node
	store, loaded := m.nodes.LoadOrStore(nodeID, NewBuffer(m.config.Retention))
	if !loaded {
		m.nodeCount.Add(1)
		m.activeNodes.Add(1)
	}

	store.(MetricStore).Add(timestamp, responseTime, serviceName)

	return nil
}

func (m *Manager) updateNodeLRU(nodeID string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// If node exists in LRU, move it to front
	if element, ok := m.evictMap.Load(nodeID); ok {
		m.evictList.MoveToFront(element.(*list.Element))
		return
	}

	// Add new node to LRU
	element := m.evictList.PushFront(nodeID)
	m.evictMap.Store(nodeID, element)
}

func (m *Manager) evictOldest() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	element := m.evictList.Back()
	if element == nil {
		return nil
	}

	nodeID := element.Value.(string)
	m.evictList.Remove(element)
	m.evictMap.Delete(nodeID)

	// Remove from nodes map
	if _, ok := m.nodes.LoadAndDelete(nodeID); ok {
		m.nodeCount.Add(-1)
		m.activeNodes.Add(-1)
	}

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
	return m.activeNodes.Load()
}
