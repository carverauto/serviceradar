/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package metrics

import (
	"container/list"
	"context"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
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
	db          db.Service
}

var _ SysmonMetricsProvider = (*Manager)(nil)

func NewManager(cfg models.MetricsConfig, d db.Service) *Manager {
	if cfg.MaxPollers == 0 {
		cfg.MaxPollers = 10000 // Reasonable default
	}

	return &Manager{
		config:    cfg,
		evictList: list.New(),
		db:        d,
	}
}

func (m *Manager) CleanupStalePollers(staleDuration time.Duration) {
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

func (m *Manager) AddMetric(
	nodeID string, timestamp time.Time, responseTime int64, serviceName, deviceID, partition, agentID string) error {
	if !m.config.Enabled {
		return nil
	}

	// Update LRU tracking first
	m.updateNodeLRU(nodeID)

	// Check if we need to evict
	if m.nodeCount.Load() >= int64(m.config.MaxPollers) {
		if err := m.evictOldest(); err != nil {
			log.Printf("Failed to evict old node: %v", err)
		}
	}

	// Load or create metric store for this node
	store, loaded := m.nodes.LoadOrStore(nodeID, NewBuffer(int(m.config.Retention)))
	if !loaded {
		m.nodeCount.Add(1)
		m.activeNodes.Add(1)
	}

	store.(MetricStore).Add(timestamp, responseTime, serviceName, deviceID, partition, agentID, nodeID)

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

func (m *Manager) GetMetricsByDevice(deviceID string) []models.MetricPoint {
	if !m.config.Enabled {
		return nil
	}

	var allPoints []models.MetricPoint

	// Search across all nodes for metrics with the specified device ID
	m.nodes.Range(func(_, value interface{}) bool {
		store := value.(MetricStore)
		points := store.GetPoints()

		// Filter points by device ID
		for _, point := range points {
			if point.DeviceID == deviceID {
				allPoints = append(allPoints, point)
			}
		}

		return true // Continue iteration
	})

	return allPoints
}

func (m *Manager) GetActiveNodes() int64 {
	return m.activeNodes.Load()
}

func (m *Manager) GetDevicesWithActiveMetrics() []string {
	if !m.config.Enabled {
		return []string{}
	}

	deviceMap := make(map[string]bool)
	
	m.nodes.Range(func(_, value interface{}) bool {
		store := value.(MetricStore)
		points := store.GetPoints()
		
		for _, point := range points {
			if point.DeviceID != "" {
				deviceMap[point.DeviceID] = true
			}
		}
		
		return true
	})
	
	deviceIDs := make([]string, 0, len(deviceMap))
	for deviceID := range deviceMap {
		deviceIDs = append(deviceIDs, deviceID)
	}
	
	return deviceIDs
}

// GetAllMountPoints retrieves all unique mount points for a given poller.
func (m *Manager) GetAllMountPoints(ctx context.Context, pollerID string) ([]string, error) {
	log.Printf("Retrieving all mount points for poller %s", pollerID)

	// Call the database service to get all mount points
	mountPoints, err := m.db.GetAllMountPoints(ctx, pollerID)
	if err != nil {
		log.Printf("Error retrieving mount points for poller %s: %v", pollerID, err)
		return nil, err
	}

	if len(mountPoints) == 0 {
		log.Printf("No mount points found for poller %s", pollerID)
		return []string{}, nil
	}

	return mountPoints, nil
}
