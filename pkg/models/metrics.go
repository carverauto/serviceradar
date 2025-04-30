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

// Package models pkg/models/metrics.go
package models

import "time"

// MetricPoint represents a single performance metric measurement.
// @Description A single point of performance metric data with timestamp information.
type MetricPoint struct {
	// The time when this metric was collected
	Timestamp time.Time `json:"timestamp" example:"2025-04-24T14:15:22Z"`
	// The response time in milliseconds
	ResponseTime int64 `json:"response_time" example:"42"`
	// The name of the service this metric is for
	ServiceName string `json:"service_name" example:"postgres"`
}

// MetricsConfig contains configuration for metrics collection.
// @Description Configuration settings for metrics collection and storage.
type MetricsConfig struct {
	// Whether metrics collection is enabled
	Enabled bool `json:"metrics_enabled" example:"true"`
	// How long metrics are kept before being purged (in days)
	Retention int `json:"metrics_retention" example:"30"`
	// Maximum number of pollers to track metrics for
	MaxPollers int32 `json:"max_pollers" example:"1000"`
}

const MetricPointSize = 32 // 8 bytes timestamp + 8 bytes response + 16 bytes name

// SysmonMetrics represents system monitoring metrics.
// @Description System monitoring metrics including CPU, disk, and memory usage.
type SysmonMetrics struct {
	// CPU usage metrics for individual cores
	CPUs []CPUMetric `json:"cpus"`
	// Disk usage metrics for various mount points
	Disks []DiskMetric `json:"disks"`
	// Memory usage metrics
	Memory MemoryMetric `json:"memory"`
}

// CPUMetric represents CPU utilization for a single core.
// @Description CPU usage metrics for an individual processor core.
type CPUMetric struct {
	// ID number of the CPU core
	CoreID int32 `json:"core_id" example:"0"`
	// Usage percentage (0-100)
	UsagePercent float64 `json:"usage_percent" example:"45.2"`
	// When this metric was collected
	Timestamp time.Time `json:"timestamp" example:"2025-04-24T14:15:22Z"`
}

// DiskMetric represents disk usage for a single mount point.
// @Description Storage usage metrics for a disk partition.
type DiskMetric struct {
	// Mount point path
	MountPoint string `json:"mount_point" example:"/var"`
	// Bytes currently in use
	UsedBytes uint64 `json:"used_bytes" example:"10737418240"`
	// Total capacity in bytes
	TotalBytes uint64 `json:"total_bytes" example:"107374182400"`
	// When this metric was collected
	Timestamp time.Time `json:"timestamp" example:"2025-04-24T14:15:22Z"`
}

// MemoryMetric represents system memory usage.
// @Description System memory utilization metrics.
type MemoryMetric struct {
	// Bytes currently in use
	UsedBytes uint64 `json:"used_bytes" example:"4294967296"`
	// Total memory capacity in bytes
	TotalBytes uint64 `json:"total_bytes" example:"17179869184"`
	// When this metric was collected
	Timestamp time.Time `json:"timestamp" example:"2025-04-24T14:15:22Z"`
}

// SysmonMetricData represents the raw data received from the sysmon service.
// @Description Raw system monitoring data received from the monitoring agent.
type SysmonMetricData struct {
	// ISO8601 timestamp when data was collected
	Timestamp string `json:"timestamp" example:"2025-04-24T14:15:22Z"`
	// Unique identifier for the host
	HostID string `json:"host_id" example:"server-east-1"`
	// CPU metrics for each core
	CPUs []struct {
		// ID number of the CPU core
		CoreID int32 `json:"core_id" example:"0"`
		// Usage percentage (0-100)
		UsagePercent float32 `json:"usage_percent" example:"45.2"`
	} `json:"cpus"`
	// Disk usage metrics for each mount point
	Disks []struct {
		// Mount point path
		MountPoint string `json:"mount_point" example:"/var"`
		// Bytes currently in use
		UsedBytes uint64 `json:"used_bytes" example:"10737418240"`
		// Total capacity in bytes
		TotalBytes uint64 `json:"total_bytes" example:"107374182400"`
	} `json:"disks"`
	// Memory usage metrics
	Memory struct {
		// Bytes currently in use
		UsedBytes uint64 `json:"used_bytes" example:"4294967296"`
		// Total memory capacity in bytes
		TotalBytes uint64 `json:"total_bytes" example:"17179869184"`
	} `json:"memory"`
}

// SNMPMetric represents an SNMP metric.
// @Description A metric collected via SNMP, including its value, type, and timestamp.
type SNMPMetric struct {
	// The name of the OID (Object Identifier)
	// @example "sysUpTime"
	OIDName string `json:"oid_name"`

	// The value of the metric
	// @example 12345
	Value interface{} `json:"value"`

	// The type of the value (e.g., integer, string)
	// @example "integer"
	ValueType string `json:"value_type"`

	// The time when the metric was collected
	// @example "2025-04-24T14:15:22Z"
	Timestamp time.Time `json:"timestamp"`

	// The scale factor applied to the value
	// @example 1.0
	Scale float64 `json:"scale"`

	// Whether the metric represents a delta value
	// @example false
	IsDelta bool `json:"is_delta"`
}
