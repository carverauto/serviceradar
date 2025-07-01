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

import (
	"time"
)

// MetricPoint represents a single performance metric measurement.
// @Description A single point of performance metric data with timestamp information.
type MetricPoint struct {
	// The time when this metric was collected
	Timestamp time.Time `json:"timestamp" example:"2025-04-24T14:15:22Z"`
	// The response time in milliseconds
	ResponseTime int64 `json:"response_time" example:"42"`
	// The name of the service this metric is for
	ServiceName string `json:"service_name" example:"postgres"`
	// The device ID this metric is associated with (partition:ip)
	DeviceID string `json:"device_id,omitempty" example:"default:192.168.1.100"`
	// The partition this metric belongs to
	Partition string `json:"partition,omitempty" example:"default"`
	// The agent ID that collected this metric
	AgentID string `json:"agent_id,omitempty" example:"agent-1234"`
	// The poller ID that requested this metric
	PollerID string `json:"poller_id,omitempty" example:"demo-staging"`
}

// MetricsConfig contains configuration for metrics collection.
// @Description Configuration settings for metrics collection and storage.
type MetricsConfig struct {
	// Whether metrics collection is enabled
	Enabled bool `json:"metrics_enabled" example:"true"`
	// How long metrics are kept before being purged (in days)
	Retention int32 `json:"metrics_retention" example:"30"`
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
	Memory *MemoryMetric `json:"memory"`
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
	// Host identifier for the agent that collected this metric
	HostID string `json:"host_id,omitempty" example:"server-east-1"`
	// Host IP address for the agent that collected this metric
	HostIP string `json:"host_ip,omitempty" example:"192.168.1.100"`
	// ServiceRadar agent identifier
	AgentID string `json:"agent_id,omitempty" example:"agent-1234"`
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
	// Host identifier for the agent that collected this metric
	HostID string `json:"host_id,omitempty" example:"server-east-1"`
	// Host IP address for the agent that collected this metric
	HostIP string `json:"host_ip,omitempty" example:"192.168.1.100"`
	// ServiceRadar agent identifier
	AgentID string `json:"agent_id,omitempty" example:"agent-1234"`
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
	// Host identifier for the agent that collected this metric
	HostID string `json:"host_id,omitempty" example:"server-east-1"`
	// Host IP address for the agent that collected this metric
	HostIP string `json:"host_ip,omitempty" example:"192.168.1.100"`
	// ServiceRadar agent identifier
	AgentID string `json:"agent_id,omitempty" example:"agent-1234"`
}

// SysmonMetricData represents the raw data received from the sysmon service.
// @Description Raw system monitoring data received from the monitoring agent.
type SysmonMetricData struct {
	// ISO8601 timestamp when data was collected
	Timestamp string `json:"timestamp" example:"2025-04-24T14:15:22Z"`
	// Unique identifier for the host
	HostID string `json:"host_id" example:"server-east-1"`
	// IP address of the host
	HostIP string `json:"host_ip" example:"192.168.1.100"`
	// Partition identifier for device-centric model (optional)
	Partition *string `json:"partition,omitempty" example:"demo-staging"`
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

// TimeseriesMetric represents a generic timeseries datapoint.
type TimeseriesMetric struct {
	PollerID       string    `json:"poller_id"` // Unique identifier for the poller that collected this metric
	Name           string    `json:"name"`
	TargetDeviceIP string    `json:"target_device_ip"` // IP address of the device this metric is for
	DeviceID       string    `json:"device_id"`        // Device identifier in format "partition:ip"
	Partition      string    `json:"partition"`        // Partition identifier for this device
	IfIndex        int32     `json:"if_index"`
	Value          string    `json:"value"` // Store as string for flexibility
	Type           string    `json:"type"`  // Metric type identifier
	Timestamp      time.Time `json:"timestamp"`
	Metadata       string    `json:"metadata"`
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

// SweepResult represents a single sweep result to be stored.
type SweepResult struct {
	AgentID         string            `json:"agent_id"`
	PollerID        string            `json:"poller_id"`
	Partition       string            `json:"partition"`
	DiscoverySource string            `json:"discovery_source"`
	IP              string            `json:"ip"`
	MAC             *string           `json:"mac,omitempty"`
	Hostname        *string           `json:"hostname,omitempty"`
	Timestamp       time.Time         `json:"timestamp"`
	Available       bool              `json:"available"`
	Metadata        map[string]string `json:"metadata,omitempty"`
}

// SysmonDiskResponse represents a disk metrics response grouped by timestamp.
type SysmonDiskResponse struct {
	Disks     []DiskMetric `json:"disks"`
	Timestamp time.Time    `json:"timestamp"`
}

// SysmonMemoryResponse represents a memory metrics response.
type SysmonMemoryResponse struct {
	Memory    MemoryMetric `json:"memory"`
	Timestamp time.Time    `json:"timestamp"`
}

// SysmonCPUResponse represents a CPU metrics response grouped by timestamp.
type SysmonCPUResponse struct {
	Cpus      []CPUMetric `json:"cpus"`
	Timestamp time.Time   `json:"timestamp"`
}
