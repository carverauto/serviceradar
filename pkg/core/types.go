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
	"github.com/carverauto/serviceradar/proto"
)

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
	snmpManager             snmp.SNMPManager
	rperfManager            rperf.RperfManager
	config                  *models.DBConfig
	authService             *auth.Auth
	metricBuffers           map[string][]*db.TimeseriesMetric
	serviceBuffers          map[string][]*db.ServiceStatus
	sysmonBuffers           map[string][]*models.SysmonMetrics
	bufferMu                sync.RWMutex
	pollerStatusCache       map[string]*models.PollerStatus
	pollerStatusUpdates     map[string]*models.PollerStatus
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
