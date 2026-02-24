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
	"context"
	"fmt"
	"strings"
)

func (e *DiscoveryEngine) upsertInterface(job *DiscoveryJob, iface *DiscoveredInterface) {
	if job == nil || iface == nil {
		return
	}

	key := interfaceDedupKey(iface)

	job.mu.Lock()
	defer job.mu.Unlock()

	if job.interfaceMap == nil {
		job.interfaceMap = make(map[string]*DiscoveredInterface)
	}

	if key == "" {
		job.Results.Interfaces = append(job.Results.Interfaces, iface)
		return
	}

	if existing, ok := job.interfaceMap[key]; ok {
		mergeInterface(existing, iface)
		return
	}

	job.interfaceMap[key] = iface
	job.Results.Interfaces = append(job.Results.Interfaces, iface)
}

func (e *DiscoveryEngine) publishInterfaces(
	ctx context.Context,
	jobID string,
	interfaces []*DiscoveredInterface,
) {
	if e.publisher == nil || len(interfaces) == 0 {
		return
	}

	for _, iface := range interfaces {
		if iface == nil {
			continue
		}

		if err := e.publisher.PublishInterface(ctx, iface); err != nil {
			e.logger.Error().Str("job_id", jobID).
				Str("device_ip", iface.DeviceIP).
				Int32("if_index", iface.IfIndex).
				Err(err).
				Msg("Failed to publish interface")
		}
	}
}

func interfaceDedupKey(iface *DiscoveredInterface) string {
	deviceKey := strings.TrimSpace(iface.DeviceID)
	if deviceKey == "" {
		deviceKey = strings.TrimSpace(iface.DeviceIP)
	}
	if deviceKey == "" {
		return ""
	}

	identifier := interfaceIdentifier(iface)
	if identifier == "" {
		return ""
	}

	return deviceKey + "|" + identifier
}

func (e *DiscoveryEngine) deduplicateInterfaces(job *DiscoveryJob) {
	if job == nil || job.Results == nil {
		return
	}

	dedupedMap := make(map[string]*DiscoveredInterface, len(job.Results.Interfaces))
	deduped := make([]*DiscoveredInterface, 0, len(job.Results.Interfaces))

	for _, iface := range job.Results.Interfaces {
		if iface == nil {
			continue
		}

		key := interfaceDedupKey(iface)
		if key == "" {
			deduped = append(deduped, iface)
			continue
		}

		if existing, ok := dedupedMap[key]; ok {
			mergeInterface(existing, iface)
			continue
		}

		dedupedMap[key] = iface
		deduped = append(deduped, iface)
	}

	job.Results.Interfaces = deduped
	job.interfaceMap = dedupedMap
}

func interfaceIdentifier(iface *DiscoveredInterface) string {
	if iface.IfIndex != 0 {
		return fmt.Sprintf("ifindex:%d", iface.IfIndex)
	}

	ifName := strings.TrimSpace(iface.IfName)
	if ifName != "" {
		return "ifname:" + ifName
	}

	ifDescr := strings.TrimSpace(iface.IfDescr)
	if ifDescr != "" {
		return "ifdescr:" + ifDescr
	}

	return ""
}

func mergeInterface(dst, src *DiscoveredInterface) {
	if dst == nil || src == nil {
		return
	}

	if src.DeviceIP != "" {
		dst.DeviceIP = src.DeviceIP
	}
	if src.DeviceID != "" {
		dst.DeviceID = src.DeviceID
	}
	if src.IfIndex != 0 {
		dst.IfIndex = src.IfIndex
	}
	if src.IfName != "" {
		dst.IfName = src.IfName
	}
	if src.IfDescr != "" {
		dst.IfDescr = src.IfDescr
	}
	if src.IfAlias != "" {
		dst.IfAlias = src.IfAlias
	}
	if src.IfSpeed != 0 {
		dst.IfSpeed = src.IfSpeed
	}
	if src.IfPhysAddress != "" {
		dst.IfPhysAddress = src.IfPhysAddress
	}
	if len(src.IPAddresses) > 0 {
		dst.IPAddresses = mergeStringSlice(dst.IPAddresses, src.IPAddresses)
	}
	if src.IfAdminStatus != 0 {
		dst.IfAdminStatus = src.IfAdminStatus
	}
	if src.IfOperStatus != 0 {
		dst.IfOperStatus = src.IfOperStatus
	}
	if src.IfType != 0 {
		dst.IfType = src.IfType
	}
	if src.Metadata != nil {
		dst.Metadata = mergeStringMap(dst.Metadata, src.Metadata)
	}
	if len(src.AvailableMetrics) > 0 {
		dst.AvailableMetrics = mergeInterfaceMetrics(dst.AvailableMetrics, src.AvailableMetrics)
	}
}

func mergeStringMap(dst, src map[string]string) map[string]string {
	if dst == nil {
		dst = make(map[string]string)
	}

	for key, value := range src {
		dst[key] = value
	}

	return dst
}

func mergeStringSlice(dst, src []string) []string {
	if len(src) == 0 {
		return dst
	}

	seen := make(map[string]struct{}, len(dst))
	out := append([]string(nil), dst...)

	for _, value := range dst {
		if value == "" {
			continue
		}
		seen[value] = struct{}{}
	}

	for _, value := range src {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}

	return out
}

func mergeInterfaceMetrics(dst, src []InterfaceMetric) []InterfaceMetric {
	if len(src) == 0 {
		return dst
	}

	if len(dst) == 0 {
		return append([]InterfaceMetric(nil), src...)
	}

	index := make(map[string]int, len(dst))
	out := dst

	for i, metric := range dst {
		key := interfaceMetricKey(metric)
		if key == "" {
			continue
		}
		index[key] = i
	}

	for _, metric := range src {
		key := interfaceMetricKey(metric)
		if key == "" {
			out = append(out, metric)
			continue
		}
		if idx, ok := index[key]; ok {
			out[idx] = metric
			continue
		}
		index[key] = len(out)
		out = append(out, metric)
	}

	return out
}

func interfaceMetricKey(metric InterfaceMetric) string {
	if metric.Name != "" {
		return "name:" + metric.Name
	}
	if metric.OID != "" {
		return "oid:" + metric.OID
	}
	return ""
}
