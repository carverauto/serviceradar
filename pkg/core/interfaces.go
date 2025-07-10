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

// Package core pkg/core/interfaces.go
//go:generate mockgen -destination=mock_server.go -package=core github.com/carverauto/serviceradar/pkg/core NodeService,CoreService,DiscoveryService

package core

import (
	"context"
	"encoding/json"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/proto"
)

// NodeService represents node-related operations.
type NodeService interface {
	GetNodeStatus(nodeID string) (*api.PollerStatus, error)
	UpdateNodeStatus(nodeID string, status *api.PollerStatus) error
	GetNodeHistory(nodeID string, limit int) ([]api.PollerHistoryPoint, error)
	CheckNodeHealth(nodeID string) (bool, error)
}

// CoreService represents the main core service functionality.
type CoreService interface {
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	ReportStatus(ctx context.Context, nodeID string, status *api.PollerStatus) error
	GetMetricsManager() metrics.MetricCollector
}

// DiscoveryService handles network discovery operations.
type DiscoveryService interface {
	ProcessSyncResults(
		ctx context.Context,
		reportingPollerID, partition string,
		svc *proto.ServiceStatus,
		details json.RawMessage,
		timestamp time.Time) error
	ProcessSNMPDiscoveryResults(
		ctx context.Context,
		reportingPollerID, partition string,
		svc *proto.ServiceStatus,
		details json.RawMessage,
		timestamp time.Time) error
}
