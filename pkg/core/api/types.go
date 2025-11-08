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
	"github.com/carverauto/serviceradar/pkg/natsutil"
	"github.com/carverauto/serviceradar/pkg/search"
	"github.com/carverauto/serviceradar/pkg/spireadmin"
)

type ServiceStatus struct {
	AgentID   string          `json:"agent_id"`
	PollerID  string          `json:"poller_id"`
	Name      string          `json:"name"`
	Available bool            `json:"available"`
	Message   []byte          `json:"message"`
	Type      string          `json:"type"`                  // e.g., "process", "port", "blockchain", etc.
	Details   json.RawMessage `json:"details"`               // Flexible field for service-specific data
	KvStoreID string          `json:"kv_store_id,omitempty"` // KV store identifier used by this service
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

// EdgeOnboardingService provides read access to onboarding packages.
type EdgeOnboardingService interface {
	ListPackages(ctx context.Context, filter *models.EdgeOnboardingListFilter) ([]*models.EdgeOnboardingPackage, error)
	GetPackage(ctx context.Context, packageID string) (*models.EdgeOnboardingPackage, error)
	ListEvents(ctx context.Context, packageID string, limit int) ([]*models.EdgeOnboardingEvent, error)
	CreatePackage(ctx context.Context, req *models.EdgeOnboardingCreateRequest) (*models.EdgeOnboardingCreateResult, error)
	DeliverPackage(ctx context.Context, req *models.EdgeOnboardingDeliverRequest) (*models.EdgeOnboardingDeliverResult, error)
	RevokePackage(ctx context.Context, req *models.EdgeOnboardingRevokeRequest) (*models.EdgeOnboardingRevokeResult, error)
	DeletePackage(ctx context.Context, packageID string) error
	DefaultSelectors() []string
	MetadataDefaults() map[models.EdgeOnboardingComponentType]map[string]string
	SetAllowedPollerCallback(cb func([]string))
	SetDeviceRegistryCallback(cb func(context.Context, []*models.DeviceUpdate) error)
}

type APIServer struct {
	mu                    sync.RWMutex
	pollers               map[string]*PollerStatus
	router                *mux.Router
	protectedRouter       *mux.Router
	pollerHistoryHandler  func(pollerID string) ([]PollerHistoryPoint, error)
	metricsManager        metrics.MetricCollector
	snmpManager           metricstore.SNMPManager
	rperfManager          metricstore.RperfManager
	queryExecutor         db.QueryExecutor
	dbService             db.Service
	deviceRegistry        DeviceRegistryService
	serviceRegistry       ServiceRegistryService // Service registry for pollers/agents/checkers
	knownPollers          []string
	knownPollerSet        map[string]struct{}
	dynamicPollers        map[string]struct{}
	authService           auth.AuthService
	corsConfig            models.CORSConfig
	logger                logger.Logger
	kvAddress             string
	kvSecurity            *models.SecurityConfig
	kvPutFn               func(ctx context.Context, key string, value []byte, ttl int64) error
	kvGetFn               func(ctx context.Context, key string) ([]byte, bool, uint64, error)
	kvEndpoints           map[string]*KVEndpoint
	rbacConfig            *models.RBACConfig
	spireAdminClient      spireadmin.Client
	spireAdminConfig      *models.SpireAdminConfig
	edgeOnboarding        EdgeOnboardingService
	eventPublisher        *natsutil.EventPublisher
	logDigest             LogDigestService
	statsService          StatsService
	searchPlanner         *search.Planner
	requireDeviceRegistry bool
}

// KVEndpoint describes a reachable KV gRPC endpoint that fronts a specific JetStream domain.
type KVEndpoint struct {
	ID       string                 `json:"id"`
	Name     string                 `json:"name"`
	Address  string                 `json:"address"` // gRPC address for proto.KVService
	Domain   string                 `json:"domain"`  // NATS JetStream domain behind this KV
	Type     string                 `json:"type"`    // hub | leaf | other
	Security *models.SecurityConfig `json:"security,omitempty"`
}

// DeviceRegistryService interface for accessing the device registry
type DeviceRegistryService interface {
	GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error)
	GetDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error)
	ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error)
	GetMergedDevice(ctx context.Context, deviceIDOrIP string) (*models.UnifiedDevice, error)
	FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.UnifiedDevice, error)
	GetCollectorCapabilities(ctx context.Context, deviceID string) (*models.CollectorCapability, bool)
	ListDeviceCapabilitySnapshots(ctx context.Context, deviceID string) []*models.DeviceCapabilitySnapshot
}

// LogDigestService exposes cached critical log data for the API layer.
type LogDigestService interface {
	Latest(limit int) []models.LogSummary
	Counters() *models.LogCounters
}

// StatsService exposes cached device statistics.
type StatsService interface {
	Snapshot() *models.DeviceStatsSnapshot
	Meta() models.DeviceStatsMeta
}
