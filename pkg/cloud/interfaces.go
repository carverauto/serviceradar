/*-
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

// Package cloud pkg/cloud/interfaces.go

//go:generate mockgen -destination=mock_server.go -package=cloud github.com/carverauto/serviceradar/pkg/cloud NodeService,CloudService

package cloud

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/cloud/api"
	"github.com/carverauto/serviceradar/pkg/metrics"
)

// NodeService represents node-related operations.
type NodeService interface {
	GetNodeStatus(nodeID string) (*api.NodeStatus, error)
	UpdateNodeStatus(nodeID string, status *api.NodeStatus) error
	GetNodeHistory(nodeID string, limit int) ([]api.NodeHistoryPoint, error)
	CheckNodeHealth(nodeID string) (bool, error)
}

// CloudService represents the main cloud service functionality.
type CloudService interface {
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	ReportStatus(ctx context.Context, nodeID string, status *api.NodeStatus) error
	GetMetricsManager() metrics.MetricCollector
}
