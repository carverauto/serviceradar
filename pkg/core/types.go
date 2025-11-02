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

// Package core pkg/core/types.go
package core

import (
	"sync"
	"time"

	"github.com/nats-io/nats.go"
	"go.opentelemetry.io/otel/trace"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/metricstore"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/natsutil"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
)

// sysmonMetricBuffer holds sysmon metrics with their associated partition
type sysmonMetricBuffer struct {
	Metrics   *models.SysmonMetrics
	Partition string
}

// Server represents the core ServiceRadar server instance with all its dependencies and configuration.
type Server struct {
	proto.UnimplementedPollerServiceServer
	proto.UnimplementedCoreServiceServer
	mu                  sync.RWMutex
	DB                  db.Service
	alertThreshold      time.Duration
	webhooks            []alerts.AlertService
	apiServer           api.Service
	ShutdownChan        chan struct{}
	pollerPatterns      []string
	grpcServer          *grpc.Server
	metrics             *metrics.Manager
	snmpManager         metricstore.SNMPManager
	rperfManager        metricstore.RperfManager
	config              *models.CoreServiceConfig
	authService         *auth.Auth
	DeviceRegistry      registry.Manager
	ServiceRegistry     registry.ServiceManager
	identityKVClient    identityKVClient
	identityKVCloser    func() error
	eventPublisher      *natsutil.EventPublisher
	natsConn            *nats.Conn
	discoveryService    DiscoveryService
	natsReconnectMu     sync.Mutex
	natsReconnectActive bool
	edgeOnboarding      *edgeOnboardingService
	// MCP removed from Go server; SRQL tooling moved out of process
	metricBuffers           map[string][]*models.TimeseriesMetric
	serviceBuffers          map[string][]*models.ServiceStatus
	serviceListBuffers      map[string][]*models.Service
	sysmonBuffers           map[string][]*sysmonMetricBuffer
	metricBufferMu          sync.RWMutex
	serviceBufferMu         sync.RWMutex
	serviceListBufferMu     sync.RWMutex
	sysmonBufferMu          sync.RWMutex
	pollerStatusCache       map[string]*models.PollerStatus
	pollerStatusUpdates     map[string]*models.PollerStatus
	pollerStatusUpdateMutex sync.Mutex
	cacheLastUpdated        time.Time
	cacheMutex              sync.RWMutex
	logger                  logger.Logger
	tracer                  trace.Tracer
	canonicalCache          *canonicalCache
}

// OIDStatusData represents the structure of OID status data.
type OIDStatusData struct {
	LastValue  interface{} `json:"last_value"`
	LastUpdate string      `json:"last_update"`
	ErrorCount int         `json:"error_count"`
	LastError  string      `json:"last_error,omitempty"`
}

// ServiceStatus represents the status of a monitored service.
type ServiceStatus struct {
	PollerID    string
	ServiceName string
	ServiceType string
	Available   bool
	Details     string
	Timestamp   time.Time
}
