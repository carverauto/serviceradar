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

	"github.com/shirou/gopsutil/v3/disk"
)

// CollectDisks gathers disk usage metrics for specified paths.
// If paths is empty or contains only "/", all mounted filesystems are collected.
func CollectDisks(ctx context.Context, paths []string) ([]DiskMetric, error) {
	// Get all partitions (fallback to include non-physical mounts in containers)
	partitions, err := disk.PartitionsWithContext(ctx, false)
	if err != nil {
		return nil, err
	}
	if len(partitions) == 0 {
		partitions, err = disk.PartitionsWithContext(ctx, true)
		if err != nil {
			return nil, err
		}
	}

	// Build a set of requested paths for quick lookup
	pathSet := make(map[string]struct{}, len(paths))
	collectAll := len(paths) == 0
	for _, p := range paths {
		pathSet[p] = struct{}{}
	}

	metrics := make([]DiskMetric, 0, len(partitions))

	for _, partition := range partitions {
		mountpoint := partition.Mountpoint

		// Skip if not in requested paths (unless collecting all)
		if !collectAll {
			if _, ok := pathSet[mountpoint]; !ok {
				continue
			}
		}

		// Skip pseudo filesystems
		if isPseudoFilesystem(partition.Fstype) {
			continue
		}

		usage, err := disk.UsageWithContext(ctx, mountpoint)
		if err != nil {
			// Skip inaccessible partitions
			continue
		}

		metrics = append(metrics, DiskMetric{
			MountPoint: mountpoint,
			UsedBytes:  usage.Used,
			TotalBytes: usage.Total,
		})
	}

	return metrics, nil
}

// isPseudoFilesystem returns true for virtual/pseudo filesystems that shouldn't be monitored.
func isPseudoFilesystem(fstype string) bool {
	pseudoTypes := map[string]struct{}{
		"proc":            {},
		"sysfs":           {},
		"devfs":           {},
		"devpts":          {},
		"tmpfs":           {},
		"securityfs":      {},
		"cgroup":          {},
		"cgroup2":         {},
		"pstore":          {},
		"debugfs":         {},
		"hugetlbfs":       {},
		"mqueue":          {},
		"configfs":        {},
		"fusectl":         {},
		"bpf":             {},
		"tracefs":         {},
		"efivarfs":        {},
		"autofs":          {},
		"squashfs":        {},
		"nsfs":            {},
		"devtmpfs":        {},
		"ramfs":           {},
		"rpc_pipefs":      {},
		"nfsd":            {},
		"binfmt_misc":     {},
		"fuse.portal":     {},
		"fuse.gvfsd-fuse": {},
		// Note: overlay is NOT included because it's used as the real
		// root filesystem in containers and stores actual user data.
	}

	_, isPseudo := pseudoTypes[fstype]
	return isPseudo
}
