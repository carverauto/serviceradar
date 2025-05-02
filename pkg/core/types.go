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

package core

import (
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/rperf"
	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/models/core"
	"github.com/carverauto/serviceradar/proto"
)

type Server struct {
	proto.UnimplementedPollerServiceServer
	mu                      sync.RWMutex
	Db                      db.Service
	AlertThreshold          time.Duration
	Webhooks                []alerts.AlertService
	apiServer               api.Service
	ShutdownChan            chan struct{}
	PollerPatterns          []string
	grpcServer              *grpc.Server
	Metrics                 *metrics.Manager
	SnmpManager             snmp.SNMPManager
	RperfManager            rperf.RperfManager
	Config                  *core.Config
	AuthService             *auth.Auth
	MetricBuffers           map[string][]*db.TimeseriesMetric
	ServiceBuffers          map[string][]*db.ServiceStatus
	SysmonBuffers           map[string][]*models.SysmonMetrics
	BufferMu                sync.RWMutex
	PollerStatusCache       map[string]*models.PollerStatus
	PollerStatusUpdates     map[string]*models.PollerStatus
	pollerStatusUpdateMutex sync.Mutex
	cacheLastUpdated        time.Time
	cacheMutex              sync.RWMutex
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
