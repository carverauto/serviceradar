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

package metrics

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

//go:generate mockgen -destination=mock_buffer.go -package=metrics github.com/carverauto/serviceradar/pkg/metrics MetricStore,MetricCollector,StructuredMetricCollector,SysmonMetricsProvider

type MetricStore interface {
	Add(timestamp time.Time, responseTime int64, serviceName string)
	GetPoints() []models.MetricPoint
	GetLastPoint() *models.MetricPoint // New method
}

type MetricCollector interface {
	AddMetric(nodeID string, timestamp time.Time, responseTime int64, serviceName string) error
	GetMetrics(nodeID string) []models.MetricPoint
	CleanupStalePollers(staleDuration time.Duration)
}

type StructuredMetricCollector interface {
	StoreSysmonMetrics(ctx context.Context, pollerID string, metrics *models.SysmonMetrics, timestamp time.Time) error
	GetCPUMetrics(ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error)
	GetDiskMetrics(ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error)
	GetMemoryMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error)
	GetAllDiskMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error)

	// Rperf methods

	StoreRperfMetrics(ctx context.Context, pollerID string, metrics *models.RperfMetrics, timestamp time.Time) error
	GetRperfMetrics(ctx context.Context, pollerID string, target string, start, end time.Time) ([]models.RperfMetric, error)
}

// SysmonMetricsProvider interface extension.
type SysmonMetricsProvider interface {
	GetAllCPUMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]db.SysmonCPUResponse, error)
	GetCPUMetrics(ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error)
	GetAllDiskMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]db.SysmonDiskResponse, error)
	GetDiskMetrics(ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error)
	GetMemoryMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]db.SysmonMemoryResponse, error)
}
