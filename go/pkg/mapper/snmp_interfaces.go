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

package mapper

import (
	"fmt"

	"sort"

	"strings"
	"time"

	"github.com/gosnmp/gosnmp"
)

func (e *DiscoveryEngine) queryInterfaces(
	job *DiscoveryJob, client *gosnmp.GoSNMP, target, jobID string) ([]*DiscoveredInterface, error) {
	// Map to store interfaces by index
	ifMap := make(map[int]*DiscoveredInterface)

	// Get the device ID for this target
	var deviceID string

	job.mu.RLock()

	for _, device := range job.Results.Devices {
		if device.IP == target {
			deviceID = device.DeviceID
			break
		}
	}

	job.mu.RUnlock()

	// Walk ifTable to get basic interface information
	if err := e.walkIfTable(client, target, ifMap, deviceID); err != nil {
		return nil, err
	}

	// Try to get additional interface info from ifXTable (if available)
	if err := e.walkIfXTable(client, ifMap); err != nil {
		e.logger.Debug().Str("target", target).Err(err).
			Msg("Failed to walk ifXTable (normal for some devices)")
	}

	// Specifically try to get ifHighSpeed for interfaces that need it
	e.walkIfHighSpeed(client, ifMap)

	// Get IP addresses from ipAddrTable (legacy, IPv4-only)
	ipToIfIndex, err := e.walkIPAddrTable(client)
	if err != nil {
		e.logger.Debug().Str("target", target).Err(err).Msg("Failed to walk ipAddrTable")
	}

	if ipToIfIndex == nil {
		ipToIfIndex = make(map[string]int)
	}

	// Then ipAddressTable (IP-MIB), which is address-family aware and is the only
	// standard source of IPv6 addresses. Not every agent implements it, so a
	// failure here is expected and must not discard the IPv4 results above.
	v6Count := 0

	if extra, addrErr := e.walkIPAddressTable(client); addrErr != nil {
		e.logger.Debug().Str("target", target).Err(addrErr).
			Msg("Failed to walk ipAddressTable (normal for some devices)")
	} else {
		for ip, ifIndex := range extra {
			// ipAddrTable already carries a real ifIndex for the addresses it
			// reports; do not let a duplicate row overwrite it with a placeholder.
			if existing, ok := ipToIfIndex[ip]; ok && existing != 0 && ifIndex == 0 {
				continue
			}

			ipToIfIndex[ip] = ifIndex

			if strings.Contains(ip, ":") {
				v6Count++
			}
		}
	}

	if v6Count > 0 {
		e.logger.Debug().Str("target", target).Int("ipv6_addresses", v6Count).
			Msg("Discovered IPv6 addresses from ipAddressTable")
	}

	// Associate IPs with interfaces
	e.associateIPsWithInterfaces(ipToIfIndex, ifMap)

	// Convert map to slice and finalize interfaces
	interfaces := e.finalizeInterfaces(job, ifMap, jobID)

	// Log summary
	speedCount := 0
	zeroSpeedCount := 0
	maxSpeedCount := 0

	for _, iface := range interfaces {
		switch {
		case iface.IfSpeed == maxUint32Value:
			maxSpeedCount++
		case iface.IfSpeed > 0:
			speedCount++
		default:
			zeroSpeedCount++
		}
	}

	e.logger.Debug().Str("target", target).Int("total", len(interfaces)).
		Int("speed_count", speedCount).Int("zero_speed_count", zeroSpeedCount).
		Int("max_speed_count", maxSpeedCount).Msg("Interface discovery summary")

	// Probe available metrics with a tight budget so interface discovery is not
	// blocked behind thousands of per-interface GET requests on large devices.
	e.probeInterfaceMetrics(client, interfaces, target)

	return interfaces, nil
}

// probeInterfaceMetrics probes each interface for available SNMP metrics.
// This is best-effort only; discovered interface rows are more important than
// complete metric capability metadata.
func (e *DiscoveryEngine) probeInterfaceMetrics(
	client *gosnmp.GoSNMP,
	interfaces []*DiscoveredInterface,
	target string,
) {
	if len(interfaces) == 0 {
		return
	}

	sort.Slice(interfaces, func(i, j int) bool {
		return interfaces[i].IfIndex < interfaces[j].IfIndex
	})

	maxProbe := interfaceMetricProbeMax
	if len(interfaces) > maxProbe {
		e.logger.Warn().
			Str("target", target).
			Int("total_interfaces", len(interfaces)).
			Int("probing", maxProbe).
			Msg("Limiting interface metric probing")
		interfaces = interfaces[:maxProbe]
	}

	deadline := time.Now().Add(interfaceMetricProbeBudget)

	for idx, iface := range interfaces {
		if time.Now().After(deadline) {
			e.logger.Warn().
				Str("target", target).
				Int("probed_interfaces", idx).
				Int("remaining_interfaces", len(interfaces)-idx).
				Msg("Stopping interface metric probing to preserve discovery latency")
			return
		}

		iface.AvailableMetrics = e.probeMetricsForInterface(client, iface.IfIndex)
	}
}

// probeMetricsForInterface probes available metrics for a single interface
func (e *DiscoveryEngine) probeMetricsForInterface(client *gosnmp.GoSNMP, ifIndex int32) []InterfaceMetric {
	var metrics []InterfaceMetric

	for _, metricDef := range getStandardInterfaceMetrics() {
		metric := e.probeMetric(client, metricDef, ifIndex)
		if metric != nil {
			metrics = append(metrics, *metric)
		}
	}

	return metrics
}

// probeMetric probes a single metric OID for availability
func (e *DiscoveryEngine) probeMetric(client *gosnmp.GoSNMP, def interfaceMetricDef, ifIndex int32) *InterfaceMetric {
	// Build the full OID with ifIndex suffix
	oid32 := fmt.Sprintf("%s.%d", def.OID32, ifIndex)

	// Try the 32-bit OID first
	result, err := client.Get([]string{oid32})
	if err != nil || len(result.Variables) == 0 {
		return nil
	}

	// Check if we got a valid response (not NoSuchObject or NoSuchInstance)
	pdu := result.Variables[0]
	if pdu.Type == gosnmp.NoSuchObject || pdu.Type == gosnmp.NoSuchInstance || pdu.Type == gosnmp.Null {
		return nil
	}

	metric := &InterfaceMetric{
		Name:          def.Name,
		OID:           def.OID32,
		DataType:      def.DataType,
		Supports64Bit: false,
		OID64Bit:      "",
		Category:      def.Category,
		Unit:          def.Unit,
	}

	// If there's a 64-bit variant, probe it
	if def.OID64 != "" {
		oid64 := fmt.Sprintf("%s.%d", def.OID64, ifIndex)
		result64, err := client.Get([]string{oid64})
		if err == nil && len(result64.Variables) > 0 {
			pdu64 := result64.Variables[0]
			if pdu64.Type != gosnmp.NoSuchObject && pdu64.Type != gosnmp.NoSuchInstance && pdu64.Type != gosnmp.Null {
				metric.Supports64Bit = true
				metric.OID64Bit = def.OID64
			}
		}
	}

	return metric
}
