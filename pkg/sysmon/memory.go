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

	"github.com/shirou/gopsutil/v3/mem"
)

// CollectMemory gathers system memory metrics.
func CollectMemory(ctx context.Context) (*MemoryMetric, error) {
	vmStats, err := mem.VirtualMemoryWithContext(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get virtual memory stats: %w", err)
	}

	metric := &MemoryMetric{
		UsedBytes:  vmStats.Used,
		TotalBytes: vmStats.Total,
	}

	// Get swap statistics
	swapStats, err := mem.SwapMemoryWithContext(ctx)
	if err == nil {
		metric.SwapUsedBytes = swapStats.Used
		metric.SwapTotalBytes = swapStats.Total
	}
	// Swap errors are non-fatal; some systems don't have swap

	return metric, nil
}
