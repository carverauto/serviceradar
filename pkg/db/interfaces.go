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

// Service represents all CNPG-backed database operations.
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
	ListAgentsWithPollers(ctx context.Context) ([]AgentInfo, error)
	ListAgentsByPoller(ctx context.Context, pollerID string) ([]AgentInfo, error)

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
		pollerID, agentID, hostID, partition, hostIP, deviceID string,
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
	GetAllProcessMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.ProcessMetric, error)
	GetAllProcessMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonProcessResponse, error)

	// SNMP metric operations.

	GetDevicesWithRecentSNMPMetrics(ctx context.Context, deviceIDs []string) (map[string]bool, error)

	// Rperf.

	StoreRperfMetrics(ctx context.Context, pollerID, serviceName string, message string, timestamp time.Time) error

	// NetFlow operations.

	StoreNetflowMetrics(ctx context.Context, metrics []*models.NetflowMetric) error

	// Auth.

	StoreUser(ctx context.Context, user *models.User) error
	GetUserByID(ctx context.Context, id string) (*models.User, error)

	// Sweep operations.

	StoreSweepHostStates(ctx context.Context, states []*models.SweepHostState) error
	GetSweepHostStates(ctx context.Context, pollerID string, limit int) ([]*models.SweepHostState, error)

	// Discovery operations.

	PublishDiscoveredInterface(ctx context.Context, iface *models.DiscoveredInterface) error
	PublishTopologyDiscoveryEvent(ctx context.Context, event *models.TopologyDiscoveryEvent) error
	PublishBatchDiscoveredInterfaces(ctx context.Context, interfaces []*models.DiscoveredInterface) error
	PublishBatchTopologyDiscoveryEvents(ctx context.Context, events []*models.TopologyDiscoveryEvent) error

	// Device operations (legacy - for backward compatibility).

	GetDeviceByID(ctx context.Context, deviceID string) (*models.Device, error)
	GetDevicesByIP(ctx context.Context, ip string) ([]*models.Device, error)
	GetStaleIPOnlyDevices(ctx context.Context, ttl time.Duration) ([]string, error)
	SoftDeleteDevices(ctx context.Context, deviceIDs []string) error

	// OCSF Device operations (OCSF v1.7.0 aligned).

	GetOCSFDevice(ctx context.Context, uid string) (*models.OCSFDevice, error)
	GetOCSFDevicesByIP(ctx context.Context, ip string) ([]*models.OCSFDevice, error)
	GetOCSFDevicesByIPsOrIDs(ctx context.Context, ips []string, uids []string) ([]*models.OCSFDevice, error)
	ListOCSFDevices(ctx context.Context, limit, offset int) ([]*models.OCSFDevice, error)
	ListOCSFDevicesByType(ctx context.Context, typeID int, limit, offset int) ([]*models.OCSFDevice, error)
	CountOCSFDevices(ctx context.Context) (int64, error)
	CleanupStaleOCSFDevices(ctx context.Context, retention time.Duration) (int64, error)
	UpsertOCSFDevice(ctx context.Context, device *models.OCSFDevice) error
	UpsertOCSFDeviceBatch(ctx context.Context, devices []*models.OCSFDevice) error
	DeleteOCSFDevices(ctx context.Context, uids []string) error
	LockOCSFDevices(ctx context.Context, ips []string) error

	// OCSF Agent operations (ocsf_agents table)
	GetOCSFAgent(ctx context.Context, uid string) (*models.OCSFAgentRecord, error)
	ListOCSFAgents(ctx context.Context, limit, offset int) ([]*models.OCSFAgentRecord, error)
	ListOCSFAgentsByPoller(ctx context.Context, pollerID string) ([]*models.OCSFAgentRecord, error)
	CountOCSFAgents(ctx context.Context) (int64, error)
	UpsertOCSFAgent(ctx context.Context, agent *models.OCSFAgentRecord) error

	// Transaction support
	WithTx(ctx context.Context, fn func(tx Service) error) error

	// DeviceUpdate operations (modern materialized view approach).

	PublishDeviceUpdate(ctx context.Context, update *models.DeviceUpdate) error
	PublishBatchDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error

	// Edge onboarding operations.

	UpsertEdgeOnboardingPackage(ctx context.Context, pkg *models.EdgeOnboardingPackage) error
	GetEdgeOnboardingPackage(ctx context.Context, packageID string) (*models.EdgeOnboardingPackage, error)
	ListEdgeOnboardingPackages(ctx context.Context, filter *models.EdgeOnboardingListFilter) ([]*models.EdgeOnboardingPackage, error)
	ListEdgeOnboardingPollerIDs(ctx context.Context, statuses ...models.EdgeOnboardingStatus) ([]string, error)
	InsertEdgeOnboardingEvent(ctx context.Context, event *models.EdgeOnboardingEvent) error
	ListEdgeOnboardingEvents(ctx context.Context, packageID string, limit int) ([]*models.EdgeOnboardingEvent, error)
	DeleteEdgeOnboardingPackage(ctx context.Context, pkg *models.EdgeOnboardingPackage) error

	// Device-centric metric operations.

	GetMetricsForDevice(ctx context.Context, deviceID string, start, end time.Time) ([]models.TimeseriesMetric, error)
	GetMetricsForDeviceByType(ctx context.Context, deviceID, metricType string, start, end time.Time) ([]models.TimeseriesMetric, error)
	GetICMPMetricsForDevice(ctx context.Context, deviceID, deviceIP string, start, end time.Time) ([]models.TimeseriesMetric, error)
	GetMetricsForPartition(ctx context.Context, partition string, start, end time.Time) ([]models.TimeseriesMetric, error)
	GetDeviceMetricTypes(ctx context.Context, deviceIDs []string, since time.Time) (map[string][]string, error)

	// Identity reconciliation operations.
	ExpireNetworkSightings(ctx context.Context, now time.Time) ([]*models.NetworkSighting, error)
	ListPromotableSightings(ctx context.Context, cutoff time.Time) ([]*models.NetworkSighting, error)
	MarkSightingsPromoted(ctx context.Context, ids []string) (int64, error)
	GetNetworkSighting(ctx context.Context, sightingID string) (*models.NetworkSighting, error)
	UpdateSightingStatus(ctx context.Context, sightingID string, status models.NetworkSightingStatus) (int64, error)
	UpsertDeviceIdentifiers(ctx context.Context, identifiers []*models.DeviceIdentifier) error
	InsertSightingEvents(ctx context.Context, events []*models.SightingEvent) error
	ListActiveSightings(ctx context.Context, partition string, limit, offset int) ([]*models.NetworkSighting, error)
	CountActiveSightings(ctx context.Context, partition string) (int64, error)
	ListSightingEvents(ctx context.Context, sightingID string, limit int) ([]*models.SightingEvent, error)
	ListSubnetPolicies(ctx context.Context, limit int) ([]*models.SubnetPolicy, error)
	ListMergeAuditEvents(ctx context.Context, deviceID string, limit int) ([]*models.MergeAuditEvent, error)

	// Device identifier lookup operations (for IdentityEngine).
	GetDeviceIDByIdentifier(ctx context.Context, identifierType, identifierValue, partition string) (string, error)
	BatchGetDeviceIDsByIdentifier(ctx context.Context, identifierType string, identifierValues []string, partition string) (map[string]string, error)
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
	GetAllProcessMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonProcessResponse, error)
	GetAllProcessMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.ProcessMetric, error)
}

// Rows represents multiple database rows.
type Rows interface {
	Next() bool
	Scan(dest ...interface{}) error
	Close() error
	Err() error
}
