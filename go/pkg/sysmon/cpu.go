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
	"context"
	"fmt"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"

	"github.com/carverauto/serviceradar/go/pkg/cpufreq"
)

// CPUCollector handles CPU metrics collection with frequency support.
type CPUCollector struct {
	sampleInterval time.Duration
	freqCollector  func(context.Context) (*cpufreq.Snapshot, error)
}

// NewCPUCollector creates a new CPU metrics collector.
func NewCPUCollector(sampleInterval time.Duration) *CPUCollector {
	return &CPUCollector{
		sampleInterval: sampleInterval,
		freqCollector:  cpufreq.NewCollector(sampleInterval),
	}
}

// Collect gathers CPU metrics including usage and frequency.
func (c *CPUCollector) Collect(ctx context.Context) ([]CPUMetric, []CPUClusterMetric, error) {
	// Get frequency snapshot (includes core count and labels)
	freqSnapshot, err := c.freqCollector(ctx)
	if err != nil {
		// Fall back to basic CPU collection without frequency
		return c.collectBasic(ctx)
	}

	// Get per-CPU usage percentages
	usagePercent, err := cpu.PercentWithContext(ctx, c.sampleInterval, true)
	if err != nil {
		// Use frequency data without usage
		return c.buildMetricsFromFreq(freqSnapshot, nil), c.buildClusterMetrics(freqSnapshot), nil
	}

	return c.buildMetricsFromFreq(freqSnapshot, usagePercent), c.buildClusterMetrics(freqSnapshot), nil
}

// collectBasic collects CPU metrics without frequency data.
func (c *CPUCollector) collectBasic(ctx context.Context) ([]CPUMetric, []CPUClusterMetric, error) {
	// Get CPU count
	count, err := cpu.CountsWithContext(ctx, true)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to get CPU count: %w", err)
	}

	// Get per-CPU usage percentages
	usagePercent, err := cpu.PercentWithContext(ctx, c.sampleInterval, true)
	if err != nil {
		// Return empty metrics with core count
		metrics := make([]CPUMetric, count)
		for i := 0; i < count; i++ {
			metrics[i] = CPUMetric{
				CoreID:       int32(i),
				Label:        fmt.Sprintf("CPU%d", i),
				UsagePercent: 0,
			}
		}
		return metrics, nil, nil
	}

	metrics := make([]CPUMetric, 0, len(usagePercent))
	for i, usage := range usagePercent {
		metrics = append(metrics, CPUMetric{
			CoreID:       int32(i),
			Label:        fmt.Sprintf("CPU%d", i),
			UsagePercent: usage,
		})
	}

	return metrics, nil, nil
}

// buildMetricsFromFreq builds CPU metrics from frequency snapshot and usage data.
func (c *CPUCollector) buildMetricsFromFreq(snap *cpufreq.Snapshot, usagePercent []float64) []CPUMetric {
	metrics := make([]CPUMetric, 0, len(snap.Cores))

	for _, core := range snap.Cores {
		usage := 0.0
		if core.CoreID >= 0 && core.CoreID < len(usagePercent) {
			usage = usagePercent[core.CoreID]
		}

		metrics = append(metrics, CPUMetric{
			CoreID:       int32(core.CoreID),
			Label:        core.Label,
			Cluster:      core.Cluster,
			UsagePercent: usage,
			FrequencyHz:  core.FrequencyHz,
		})
	}

	return metrics
}

// buildClusterMetrics builds cluster metrics from frequency snapshot.
func (c *CPUCollector) buildClusterMetrics(snap *cpufreq.Snapshot) []CPUClusterMetric {
	if len(snap.Clusters) == 0 {
		return nil
	}

	metrics := make([]CPUClusterMetric, 0, len(snap.Clusters))
	for _, cluster := range snap.Clusters {
		metrics = append(metrics, CPUClusterMetric{
			Name:        cluster.Name,
			FrequencyHz: cluster.FrequencyHz,
		})
	}

	return metrics
}
