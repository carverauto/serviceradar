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

	"github.com/carverauto/serviceradar/go/pkg/hostinventory"
	"github.com/shirou/gopsutil/v3/net"
)

// CollectNetwork gathers network interface statistics.
func CollectNetwork(ctx context.Context) ([]NetworkMetric, error) {
	counters, err := net.IOCountersWithContext(ctx, true) // per-interface
	if err != nil {
		return nil, err
	}

	return filterNetworkCounters(counters, hostinventory.Collect(), hostinventory.ClassifyName), nil
}

func filterNetworkCounters(
	counters []net.IOCountersStat,
	inventory []hostinventory.Interface,
	classifyByName func(string) hostinventory.Interface,
) []NetworkMetric {
	byName := make(map[string]hostinventory.Interface, len(inventory))
	for _, iface := range inventory {
		byName[iface.Name] = iface
	}

	metrics := make([]NetworkMetric, 0, len(counters))

	for _, counter := range counters {
		iface, ok := byName[counter.Name]
		if !ok && classifyByName != nil {
			iface = classifyByName(counter.Name)
		} else if !ok {
			iface.Name = counter.Name
		}
		if iface.IsHostInternal() {
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

	return metrics
}
