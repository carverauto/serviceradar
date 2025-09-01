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

package api

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/gorilla/mux"

	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/metricstore"
	"github.com/carverauto/serviceradar/pkg/models"
	srqlmodels "github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser"
)

type ServiceStatus struct {
	AgentID   string          `json:"agent_id"`
	PollerID  string          `json:"poller_id"`
	Name      string          `json:"name"`
	Available bool            `json:"available"`
	Message   []byte          `json:"message"`
	Type      string          `json:"type"`    // e.g., "process", "port", "blockchain", etc.
	Details   json.RawMessage `json:"details"` // Flexible field for service-specific data
}

type PollerStatus struct {
	PollerID   string               `json:"poller_id"`
	IsHealthy  bool                 `json:"is_healthy"`
	LastUpdate time.Time            `json:"last_update"`
	Services   []ServiceStatus      `json:"services"`
	UpTime     string               `json:"uptime"`
	FirstSeen  time.Time            `json:"first_seen"`
	Metrics    []models.MetricPoint `json:"metrics,omitempty"`
}

type SystemStatus struct {
	TotalPollers   int       `json:"total_pollers"`
	HealthyPollers int       `json:"healthy_pollers"`
	LastUpdate     time.Time `json:"last_update"`
}

type PollerHistory struct {
	PollerID  string
	Timestamp time.Time
	IsHealthy bool
	Services  []ServiceStatus
}

type PollerHistoryPoint struct {
	Timestamp time.Time `json:"timestamp"`
	IsHealthy bool      `json:"is_healthy"`
}

type DeviceMetricsStatusResponse struct {
	DeviceIDs []string `json:"device_ids"`
}

type APIServer struct {
	mu                   sync.RWMutex
	pollers              map[string]*PollerStatus
	router               *mux.Router
	protectedRouter      *mux.Router
	pollerHistoryHandler func(pollerID string) ([]PollerHistoryPoint, error)
	metricsManager       metrics.MetricCollector
	snmpManager          metricstore.SNMPManager
	rperfManager         metricstore.RperfManager
	queryExecutor        db.QueryExecutor
	dbService            db.Service
	deviceRegistry       DeviceRegistryService
	knownPollers         []string
	authService          auth.AuthService
	corsConfig           models.CORSConfig
	dbType               parser.DatabaseType
	entityTableMap       map[srqlmodels.EntityType]string
    logger               logger.Logger
    // KV client settings for admin config writes
    kvAddress            string
    kvSecurity           *models.SecurityConfig
    kvPutFn              func(ctx context.Context, key string, value []byte, ttl int64) error
}

// DeviceRegistryService interface for accessing the device registry
type DeviceRegistryService interface {
	GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error)
	GetDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error)
	ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error)
	GetMergedDevice(ctx context.Context, deviceIDOrIP string) (*models.UnifiedDevice, error)
	FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.UnifiedDevice, error)
}
