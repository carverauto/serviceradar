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

package sysmon

import (
	"time"
)

// MetricSample represents a complete snapshot of system metrics at a point in time.
// This structure is compatible with the existing Rust sysmon output format.
type MetricSample struct {
	// Timestamp is when this sample was collected (RFC3339 format).
	Timestamp string `json:"timestamp"`

	// HostID is the hostname or unique identifier for this host.
	HostID string `json:"host_id"`

	// HostIP is the primary IP address of this host.
	HostIP string `json:"host_ip"`

	// Partition is the optional partition/segment identifier.
	Partition *string `json:"partition,omitempty"`

	// AgentID is the ServiceRadar agent identifier.
	AgentID string `json:"agent_id,omitempty"`

	// CPUs contains per-core CPU metrics.
	CPUs []CPUMetric `json:"cpus"`

	// Clusters contains aggregate CPU cluster metrics (e.g., big.LITTLE).
	Clusters []CPUClusterMetric `json:"clusters,omitempty"`

	// Disks contains per-mount-point disk metrics.
	Disks []DiskMetric `json:"disks"`

	// Memory contains system memory metrics.
	Memory MemoryMetric `json:"memory"`

	// Network contains per-interface network metrics.
	Network []NetworkMetric `json:"network,omitempty"`

	// Processes contains top process metrics.
	Processes []ProcessMetric `json:"processes"`
}

// CPUMetric represents CPU utilization for a single core.
type CPUMetric struct {
	// CoreID is the zero-based logical core ID.
	CoreID int32 `json:"core_id"`

	// Label is a platform-specific identifier (e.g., ECPU0, PCPU3).
	Label string `json:"label,omitempty"`

	// Cluster is the logical cluster this core belongs to (e.g., ECPU, PCPU).
	Cluster string `json:"cluster,omitempty"`

	// UsagePercent is the CPU usage percentage (0-100).
	UsagePercent float64 `json:"usage_percent"`

	// FrequencyHz is the instantaneous frequency in Hz, if available.
	FrequencyHz float64 `json:"frequency_hz,omitempty"`
}

// CPUClusterMetric represents aggregated CPU cluster telemetry.
type CPUClusterMetric struct {
	// Name is the cluster identifier (e.g., ECPU, PCPU).
	Name string `json:"name"`

	// FrequencyHz is the instantaneous frequency in Hz, if available.
	FrequencyHz float64 `json:"frequency_hz"`
}

// DiskMetric represents disk usage for a single mount point.
type DiskMetric struct {
	// MountPoint is the filesystem mount path.
	MountPoint string `json:"mount_point"`

	// UsedBytes is the number of bytes currently in use.
	UsedBytes uint64 `json:"used_bytes"`

	// TotalBytes is the total capacity in bytes.
	TotalBytes uint64 `json:"total_bytes"`
}

// MemoryMetric represents system memory usage.
type MemoryMetric struct {
	// UsedBytes is the number of bytes currently in use.
	UsedBytes uint64 `json:"used_bytes"`

	// TotalBytes is the total memory capacity in bytes.
	TotalBytes uint64 `json:"total_bytes"`

	// SwapUsedBytes is the swap space currently in use.
	SwapUsedBytes uint64 `json:"swap_used_bytes,omitempty"`

	// SwapTotalBytes is the total swap capacity.
	SwapTotalBytes uint64 `json:"swap_total_bytes,omitempty"`
}

// NetworkMetric represents network interface statistics.
type NetworkMetric struct {
	// Interface is the network interface name.
	Interface string `json:"interface"`

	// BytesSent is the total bytes transmitted.
	BytesSent uint64 `json:"bytes_sent"`

	// BytesRecv is the total bytes received.
	BytesRecv uint64 `json:"bytes_recv"`

	// PacketsSent is the total packets transmitted.
	PacketsSent uint64 `json:"packets_sent"`

	// PacketsRecv is the total packets received.
	PacketsRecv uint64 `json:"packets_recv"`

	// ErrorsIn is the count of receive errors.
	ErrorsIn uint64 `json:"errors_in"`

	// ErrorsOut is the count of transmit errors.
	ErrorsOut uint64 `json:"errors_out"`

	// DropsIn is the count of dropped incoming packets.
	DropsIn uint64 `json:"drops_in"`

	// DropsOut is the count of dropped outgoing packets.
	DropsOut uint64 `json:"drops_out"`
}

// ProcessMetric represents metrics for a single process.
type ProcessMetric struct {
	// PID is the process ID.
	PID uint32 `json:"pid"`

	// Name is the process name.
	Name string `json:"name"`

	// CPUUsage is the CPU usage percentage.
	CPUUsage float32 `json:"cpu_usage"`

	// MemoryUsage is the memory usage in bytes.
	MemoryUsage uint64 `json:"memory_usage"`

	// Status is the process status (e.g., Running, Sleeping).
	Status string `json:"status"`

	// StartTime is when the process started (RFC3339 format).
	StartTime string `json:"start_time"`
}

// NewMetricSample creates a new MetricSample with the current timestamp.
func NewMetricSample(hostID, hostIP, agentID string, partition *string) *MetricSample {
	return &MetricSample{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		HostID:    hostID,
		HostIP:    hostIP,
		AgentID:   agentID,
		Partition: partition,
		CPUs:      []CPUMetric{},
		Clusters:  []CPUClusterMetric{},
		Disks:     []DiskMetric{},
		Memory:    MemoryMetric{},
		Network:   []NetworkMetric{},
		Processes: []ProcessMetric{},
	}
}
