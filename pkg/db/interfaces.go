/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package db

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

//go:generate mockgen -destination=mock_db.go -package=db github.com/carverauto/serviceradar/pkg/db Service

// TimeseriesMetric represents a generic timeseries datapoint.
type TimeseriesMetric struct {
	Name      string      `json:"name"`
	Value     string      `json:"value"` // Store as string for flexibility
	Type      string      `json:"type"`  // Metric type identifier
	Timestamp time.Time   `json:"timestamp"`
	Metadata  interface{} `json:"metadata"` // Additional type-specific metadata
}

// Service represents all database operations for Timeplus Proton.
type Service interface {
	Close() error

	// Poller operations.

	UpdatePollerStatus(ctx context.Context, status *PollerStatus) error
	GetPollerStatus(ctx context.Context, pollerID string) (*PollerStatus, error)
	GetPollerHistory(ctx context.Context, pollerID string) ([]PollerStatus, error)
	GetPollerHistoryPoints(ctx context.Context, pollerID string, limit int) ([]PollerHistoryPoint, error)
	IsPollerOffline(ctx context.Context, pollerID string, threshold time.Duration) (bool, error)
	ListPollers(ctx context.Context) ([]string, error)
	DeletePoller(ctx context.Context, pollerID string) error
	ListPollerStatuses(ctx context.Context, patterns []string) ([]PollerStatus, error)
	ListNeverReportedPollers(ctx context.Context, patterns []string) ([]string, error)

	// Service operations.

	UpdateServiceStatus(ctx context.Context, status *ServiceStatus) error
	UpdateServiceStatuses(ctx context.Context, statuses []*ServiceStatus) error
	GetPollerServices(ctx context.Context, pollerID string) ([]ServiceStatus, error)
	GetServiceHistory(ctx context.Context, pollerID, serviceName string, limit int) ([]ServiceStatus, error)

	// Maintenance operations.

	CleanOldData(ctx context.Context, retentionPeriod time.Duration) error

	// Generic timeseries methods.

	StoreMetric(ctx context.Context, pollerID string, metric *TimeseriesMetric) error
	StoreMetrics(ctx context.Context, pollerID string, metrics []*TimeseriesMetric) error
	GetMetrics(ctx context.Context, pollerID, metricName string, start, end time.Time) ([]TimeseriesMetric, error)
	GetMetricsByType(ctx context.Context, pollerID, metricType string, start, end time.Time) ([]TimeseriesMetric, error)

	// Sysmon metric operations.

	StoreSysmonMetrics(ctx context.Context, pollerID string, metrics *models.SysmonMetrics, timestamp time.Time) error
	GetCPUMetrics(ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error)
	GetDiskMetrics(ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error)
	GetMemoryMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error)
	GetAllDiskMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error)
	GetAllMountPoints(ctx context.Context, pollerID string) ([]string, error)
	GetAllCPUMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonCPUResponse, error)
	GetAllDiskMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonDiskResponse, error)
	GetMemoryMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonMemoryResponse, error)

	// Rperf.

	StoreRperfMetrics(ctx context.Context, pollerID, serviceName string, message string, timestamp time.Time) error

	// Auth.

	StoreUser(ctx context.Context, user *models.User) error
	GetUserByID(ctx context.Context, id string) (*models.User, error)
}

// SysmonMetricsProvider interface defines operations for system monitoring metrics.
type SysmonMetricsProvider interface {
	GetAllCPUMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonCPUResponse, error)
	GetCPUMetrics(ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error)
	GetAllDiskMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonDiskResponse, error)
	GetDiskMetrics(ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error)
	GetAllDiskMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error)
	GetAllMountPoints(ctx context.Context, pollerID string) ([]string, error)
	GetMemoryMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonMemoryResponse, error)
	GetMemoryMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error)
}
