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
	"strings"

	"github.com/shirou/gopsutil/v3/net"
)

// CollectNetwork gathers network interface statistics.
func CollectNetwork(ctx context.Context) ([]NetworkMetric, error) {
	counters, err := net.IOCountersWithContext(ctx, true) // per-interface
	if err != nil {
		return nil, err
	}

	metrics := make([]NetworkMetric, 0, len(counters))

	for _, counter := range counters {
		// Skip loopback and virtual interfaces
		if shouldSkipInterface(counter.Name) {
			continue
		}

		metrics = append(metrics, NetworkMetric{
			Interface:   counter.Name,
			BytesSent:   counter.BytesSent,
			BytesRecv:   counter.BytesRecv,
			PacketsSent: counter.PacketsSent,
			PacketsRecv: counter.PacketsRecv,
			ErrorsIn:    counter.Errin,
			ErrorsOut:   counter.Errout,
			DropsIn:     counter.Dropin,
			DropsOut:    counter.Dropout,
		})
	}

	return metrics, nil
}

// shouldSkipInterface returns true for interfaces that should be excluded from monitoring.
func shouldSkipInterface(name string) bool {
	name = strings.ToLower(name)

	// Skip loopback
	if name == "lo" || name == "lo0" {
		return true
	}

	// Skip Docker virtual interfaces
	skipPrefixes := []string{
		"docker",
		"br-",
		"veth",
		"virbr",
		"vnet",
		"tun",
		"tap",
		"bridge",
	}

	for _, prefix := range skipPrefixes {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}

	return false
}
