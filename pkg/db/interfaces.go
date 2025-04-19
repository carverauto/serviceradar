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

// Package db pkg/db/interfaces.go
package db

import (
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

//go:generate mockgen -destination=mock_db.go -package=db github.com/carverauto/serviceradar/pkg/db Row,Result,Rows,Transaction,Service

// TimeseriesMetric represents a generic timeseries datapoint.
type TimeseriesMetric struct {
	Name      string      `json:"name"`
	Value     string      `json:"value"` // Store as string for flexibility
	Type      string      `json:"type"`  // Metric type identifier
	Timestamp time.Time   `json:"timestamp"`
	Metadata  interface{} `json:"metadata"` // Additional type-specific metadata
}

// Row represents a database row.
type Row interface {
	Scan(dest ...interface{}) error
}

// Result represents the result of a database operation.
type Result interface {
	LastInsertId() (int64, error)
	RowsAffected() (int64, error)
}

// Rows represents multiple database rows.
type Rows interface {
	Next() bool
	Scan(dest ...interface{}) error
	Close() error
	Err() error
}

// Transaction represents operations that can be performed within a database transaction.
type Transaction interface {
	Exec(query string, args ...interface{}) (Result, error)
	Query(query string, args ...interface{}) (Rows, error)
	QueryRow(query string, args ...interface{}) Row
	Commit() error
	Rollback() error
}

// Service represents all database operations.
type Service interface {
	// Core database operations.

	Begin() (Transaction, error)
	Close() error
	Exec(query string, args ...interface{}) (Result, error)
	Query(query string, args ...interface{}) (Rows, error)
	QueryRow(query string, args ...interface{}) Row

	// Poller operations.

	UpdatePollerStatus(status *PollerStatus) error
	GetPollerStatus(pollerID string) (*PollerStatus, error)
	GetPollerHistory(pollerID string) ([]PollerStatus, error)
	GetPollerHistoryPoints(pollerID string, limit int) ([]PollerHistoryPoint, error)
	IsPollerOffline(pollerID string, threshold time.Duration) (bool, error)

	// Service operations.

	UpdateServiceStatus(status *ServiceStatus) error
	GetPollerServices(pollerID string) ([]ServiceStatus, error)
	GetServiceHistory(pollerID, serviceName string, limit int) ([]ServiceStatus, error)

	// Maintenance operations.

	CleanOldData(retentionPeriod time.Duration) error

	// Generic timeseries methods

	StoreMetric(pollerID string, metric *TimeseriesMetric) error
	GetMetrics(pollerID, metricName string, start, end time.Time) ([]TimeseriesMetric, error)
	GetMetricsByType(pollerID, metricType string, start, end time.Time) ([]TimeseriesMetric, error)

	// Sysmon metric operations

	StoreSysmonMetrics(pollerID string, metrics *models.SysmonMetrics, timestamp time.Time) error
	GetCPUMetrics(pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error)
	GetDiskMetrics(pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error)
	GetMemoryMetrics(pollerID string, start, end time.Time) ([]models.MemoryMetric, error)
	GetAllDiskMetrics(pollerID string, start, end time.Time) ([]models.DiskMetric, error)
	GetAllMountPoints(pollerID string) ([]string, error)

	// Rperf

	StoreRperfMetrics(pollerID, serviceName string, message string, timestamp time.Time) error

	// Auth

	StoreUser(user *models.User) error
	GetUserByID(id string) (*models.User, error)
}
