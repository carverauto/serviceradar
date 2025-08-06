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
	"context"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/mcp"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/metricstore"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/natsutil"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
	"github.com/nats-io/nats.go"
	"go.opentelemetry.io/otel/trace"
)

// sysmonMetricBuffer holds sysmon metrics with their associated partition
type sysmonMetricBuffer struct {
	Metrics   *models.SysmonMetrics
	Partition string
}

type Server struct {
	proto.UnimplementedPollerServiceServer
	mu                      sync.RWMutex
	DB                      db.Service
	alertThreshold          time.Duration
	webhooks                []alerts.AlertService
	apiServer               api.Service
	ShutdownChan            chan struct{}
	pollerPatterns          []string
	grpcServer              *grpc.Server
	metrics                 *metrics.Manager
	snmpManager             metricstore.SNMPManager
	rperfManager            metricstore.RperfManager
	config                  *models.CoreServiceConfig
	authService             *auth.Auth
	DeviceRegistry          registry.Manager
	eventPublisher          *natsutil.EventPublisher
	natsConn                *nats.Conn
	discoveryService        DiscoveryService
	mcpServer               api.MCPRouteRegistrar
	mcpConfig               *mcp.MCPConfig // Temporary storage for MCP config until API server is available
	mcpLogger               logger.Logger  // Temporary storage for MCP logger until API server is available
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
