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
	"sort"
	"time"

	"github.com/shirou/gopsutil/v3/process"
)

const unknownStatus = "unknown"

// processInfo holds collected process information for sorting.
type processInfo struct {
	pid         int32
	name        string
	cpuPercent  float64
	memoryBytes uint64
	status      string
	createTime  int64
}

// CollectProcesses gathers metrics for running processes.
// Results are sorted by CPU usage (descending), then memory (descending), and
// bounded by limit to avoid retaining or streaming unbounded process payloads.
func CollectProcesses(ctx context.Context, limit int) ([]ProcessMetric, error) {
	metrics, _, err := CollectProcessSnapshot(ctx, limit)
	return metrics, err
}

// CollectProcessSnapshot gathers top process metrics plus the total process
// count observed before the detail list is capped.
func CollectProcessSnapshot(ctx context.Context, limit int) ([]ProcessMetric, int, error) {
	procs, err := process.ProcessesWithContext(ctx)
	if err != nil {
		return nil, 0, err
	}
	processCount := len(procs)

	// Collect info for all processes
	infos := make([]processInfo, 0, len(procs))
	for _, p := range procs {
		info, err := collectProcessInfo(ctx, p)
		if err != nil {
			// Skip processes we can't access
			continue
		}
		infos = append(infos, info)
	}

	// Sort by CPU usage (descending), then by memory (descending)
	// This provides a useful default ordering; backend can re-sort as needed
	sort.Slice(infos, func(i, j int) bool {
		if infos[i].cpuPercent != infos[j].cpuPercent {
			return infos[i].cpuPercent > infos[j].cpuPercent
		}
		return infos[i].memoryBytes > infos[j].memoryBytes
	})

	infos = limitProcessInfos(infos, limit)

	// Convert to metrics.
	metrics := make([]ProcessMetric, 0, len(infos))
	for _, info := range infos {
		startTime := unknownStatus
		if info.createTime > 0 {
			startTime = time.Unix(info.createTime/1000, 0).UTC().Format(time.RFC3339)
		}

		metrics = append(metrics, ProcessMetric{
			PID:         uint32(info.pid),
			Name:        info.name,
			CPUUsage:    float32(info.cpuPercent),
			MemoryUsage: info.memoryBytes,
			Status:      info.status,
			StartTime:   startTime,
		})
	}

	return metrics, processCount, nil
}

func limitProcessInfos(infos []processInfo, limit int) []processInfo {
	if limit <= 0 || len(infos) <= limit {
		return infos
	}

	return infos[:limit]
}

// collectProcessInfo gathers information about a single process.
func collectProcessInfo(ctx context.Context, p *process.Process) (processInfo, error) {
	info := processInfo{
		pid: p.Pid,
	}

	// Get name
	name, err := p.NameWithContext(ctx)
	if err != nil {
		return info, err
	}
	info.name = name

	// Get CPU percent
	cpuPercent, err := p.CPUPercentWithContext(ctx)
	if err == nil {
		info.cpuPercent = cpuPercent
	}

	// Get memory info
	memInfo, err := p.MemoryInfoWithContext(ctx)
	if err == nil && memInfo != nil {
		info.memoryBytes = memInfo.RSS
	}

	// Get status
	statusSlice, err := p.StatusWithContext(ctx)
	if err == nil && len(statusSlice) > 0 {
		info.status = statusSlice[0]
	} else {
		info.status = unknownStatus
	}

	// Get create time
	createTime, err := p.CreateTimeWithContext(ctx)
	if err == nil {
		info.createTime = createTime
	}

	return info, nil
}
