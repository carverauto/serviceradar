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

	"github.com/carverauto/serviceradar/pkg/config"
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
	GatewayID  string          `json:"gateway_id"`
	Name      string          `json:"name"`
	Available bool            `json:"available"`
	Message   []byte          `json:"message"`
	Type      string          `json:"type"`                  // e.g., "process", "port", "blockchain", etc.
	Details   json.RawMessage `json:"details"`               // Flexible field for service-specific data
	KvStoreID string          `json:"kv_store_id,omitempty"` // KV store identifier used by this service
}

type GatewayStatus struct {
	GatewayID   string               `json:"gateway_id"`
	IsHealthy  bool                 `json:"is_healthy"`
	LastUpdate time.Time            `json:"last_update"`
	Services   []ServiceStatus      `json:"services"`
	UpTime     string               `json:"uptime"`
	FirstSeen  time.Time            `json:"first_seen"`
	Metrics    []models.MetricPoint `json:"metrics,omitempty"`
}

type SystemStatus struct {
	TotalGateways   int       `json:"total_gateways"`
	HealthyGateways int       `json:"healthy_gateways"`
	LastUpdate     time.Time `json:"last_update"`
}

type GatewayHistory struct {
	GatewayID  string
	Timestamp time.Time
	IsHealthy bool
	Services  []ServiceStatus
}

type GatewayHistoryPoint struct {
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
	SetAllowedGatewayCallback(cb func([]string))
	SetDeviceRegistryCallback(cb func(context.Context, []*models.DeviceUpdate) error)
	ListComponentTemplates(ctx context.Context, componentType models.EdgeOnboardingComponentType, securityMode string) ([]models.EdgeTemplate, error)
}

type APIServer struct {
	mu                    sync.RWMutex
	gateways               map[string]*GatewayStatus
	router                *mux.Router
	protectedRouter       *mux.Router
	gatewayHistoryHandler  func(gatewayID string) ([]GatewayHistoryPoint, error)
	metricsManager        metrics.MetricCollector
	snmpManager           metricstore.SNMPManager
	rperfManager          metricstore.RperfManager
	queryExecutor         db.QueryExecutor
	dbService             db.Service
	deviceRegistry        DeviceRegistryService
	serviceRegistry       ServiceRegistryService // Service registry for gateways/agents/checkers
	knownGateways          []string
	knownGatewaySet        map[string]struct{}
	dynamicGateways        map[string]struct{}
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
	templateRegistry      TemplateRegistry
	identityConfig        *models.IdentityReconciliationConfig
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
	GetDevice(ctx context.Context, deviceID string) (*models.OCSFDevice, error)
	GetDeviceByIDStrict(ctx context.Context, deviceID string) (*models.OCSFDevice, error)
	GetDevicesByIP(ctx context.Context, ip string) ([]*models.OCSFDevice, error)
	ListDevices(ctx context.Context, limit, offset int) ([]*models.OCSFDevice, error)
	FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.OCSFDevice, error)
	GetCollectorCapabilities(ctx context.Context, deviceID string) (*models.CollectorCapability, bool)
	ListDeviceCapabilitySnapshots(ctx context.Context, deviceID string) []*models.DeviceCapabilitySnapshot
	ReconcileSightings(ctx context.Context) error
	ListSightings(ctx context.Context, partition string, limit, offset int) ([]*models.NetworkSighting, error)
	CountSightings(ctx context.Context, partition string) (int64, error)
	PromoteSighting(ctx context.Context, sightingID, actor string) (*models.DeviceUpdate, error)
	DismissSighting(ctx context.Context, sightingID, actor, reason string) error
	ListSightingEvents(ctx context.Context, sightingID string, limit int) ([]*models.SightingEvent, error)
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

// TemplateRegistry provides access to service configuration templates.
type TemplateRegistry interface {
	Get(serviceName string) ([]byte, config.ConfigFormat, error)
}
