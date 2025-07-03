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

// Package db pkg/db/interfaces.go
package db

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

//go:generate mockgen -destination=mock_db.go -package=db github.com/carverauto/serviceradar/pkg/db Service,SysmonMetricsProvider,Rows,QueryExecutor

// QueryExecutor defines a generic interface for executing database queries
type QueryExecutor interface {
	ExecuteQuery(ctx context.Context, query string, params ...interface{}) ([]map[string]interface{}, error)
}

// Service represents all database operations for Timeplus Proton.
type Service interface {
	Close() error

	// Poller operations.

	UpdatePollerStatus(ctx context.Context, status *models.PollerStatus) error
	GetPollerStatus(ctx context.Context, pollerID string) (*models.PollerStatus, error)
	GetPollerHistory(ctx context.Context, pollerID string) ([]models.PollerStatus, error)
	GetPollerHistoryPoints(ctx context.Context, pollerID string, limit int) ([]models.PollerHistoryPoint, error)
	IsPollerOffline(ctx context.Context, pollerID string, threshold time.Duration) (bool, error)
	ListPollers(ctx context.Context) ([]string, error)
	DeletePoller(ctx context.Context, pollerID string) error
	ListPollerStatuses(ctx context.Context, patterns []string) ([]models.PollerStatus, error)
	ListNeverReportedPollers(ctx context.Context, patterns []string) ([]string, error)

	// Service operations.

	UpdateServiceStatus(ctx context.Context, status *models.ServiceStatus) error
	UpdateServiceStatuses(ctx context.Context, statuses []*models.ServiceStatus) error
	GetPollerServices(ctx context.Context, pollerID string) ([]models.ServiceStatus, error)
	GetServiceHistory(ctx context.Context, pollerID, serviceName string, limit int) ([]models.ServiceStatus, error)
	// StoreServices stores a batch of service records in the services stream.
	StoreServices(ctx context.Context, services []*models.Service) error

	// Maintenance operations.

	// Generic timeseries methods.

	StoreMetric(ctx context.Context, pollerID string, metric *models.TimeseriesMetric) error
	StoreMetrics(ctx context.Context, pollerID string, metrics []*models.TimeseriesMetric) error
	GetMetrics(ctx context.Context, pollerID, metricName string, start, end time.Time) ([]models.TimeseriesMetric, error)
	GetMetricsByType(ctx context.Context, pollerID, metricType string, start, end time.Time) ([]models.TimeseriesMetric, error)

	// Query (SRQL) operations.

	QueryExecutor // Embed QueryExecutor interface

	// Sysmon metric operations.

	StoreSysmonMetrics(
		ctx context.Context,
		pollerID, agentID, hostID, partition, hostIP string,
		metrics *models.SysmonMetrics,
		timestamp time.Time) error
	GetCPUMetrics(ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error)
	GetDiskMetrics(ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error)
	GetMemoryMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error)
	GetAllDiskMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error)
	GetAllMountPoints(ctx context.Context, pollerID string) ([]string, error)
	GetAllCPUMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonCPUResponse, error)
	GetAllDiskMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonDiskResponse, error)
	GetMemoryMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonMemoryResponse, error)

	// Rperf.

	StoreRperfMetrics(ctx context.Context, pollerID, serviceName string, message string, timestamp time.Time) error

	// NetFlow operations.

	StoreNetflowMetrics(ctx context.Context, metrics []*models.NetflowMetric) error

	// Auth.

	StoreUser(ctx context.Context, user *models.User) error
	GetUserByID(ctx context.Context, id string) (*models.User, error)

	// Sweep operations.

	StoreSweepResults(ctx context.Context, results []*models.SweepResult) error
	StoreSweepHostStates(ctx context.Context, states []*models.SweepHostState) error
	GetSweepHostStates(ctx context.Context, pollerID string, limit int) ([]*models.SweepHostState, error)

	// Discovery operations.

	PublishDiscoveredInterface(ctx context.Context, iface *models.DiscoveredInterface) error
	PublishTopologyDiscoveryEvent(ctx context.Context, event *models.TopologyDiscoveryEvent) error
	PublishBatchDiscoveredInterfaces(ctx context.Context, interfaces []*models.DiscoveredInterface) error
	PublishBatchTopologyDiscoveryEvents(ctx context.Context, events []*models.TopologyDiscoveryEvent) error

	// Device operations.
	StoreDevices(ctx context.Context, devices []*models.Device) error
	GetDeviceByID(ctx context.Context, deviceID string) (*models.Device, error)
	GetDevicesByIP(ctx context.Context, ip string) ([]*models.Device, error)

	// Unified Device operations.
	StoreUnifiedDevice(ctx context.Context, device *models.UnifiedDevice) error
	GetUnifiedDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error)
	GetUnifiedDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error)
	ListUnifiedDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error)

	// Device-centric metric operations.
	GetMetricsForDevice(ctx context.Context, deviceID string, start, end time.Time) ([]models.TimeseriesMetric, error)
	GetMetricsForDeviceByType(ctx context.Context, deviceID, metricType string, start, end time.Time) ([]models.TimeseriesMetric, error)
	GetMetricsForPartition(ctx context.Context, partition string, start, end time.Time) ([]models.TimeseriesMetric, error)
}

// SysmonMetricsProvider interface defines operations for system monitoring metrics.
type SysmonMetricsProvider interface {
	GetAllCPUMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonCPUResponse, error)
	GetCPUMetrics(ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error)
	GetAllDiskMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonDiskResponse, error)
	GetDiskMetrics(ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error)
	GetAllDiskMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error)
	GetAllMountPoints(ctx context.Context, pollerID string) ([]string, error)
	GetMemoryMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonMemoryResponse, error)
	GetMemoryMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error)
}

// Rows represents multiple database rows.
type Rows interface {
	Next() bool
	Scan(dest ...interface{}) error
	Close() error
	Err() error
}
