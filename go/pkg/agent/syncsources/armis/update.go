/*
 * Copyright 2026 Carver Automation Corporation.
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

package armis

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
)

// buildUpdate maps a raw Armis device record onto a ServiceRadar device
// update. MAC fields are passed through raw; the runtime's generic
// normalization step validates and cleans them for every source.
func buildUpdate(run syncsources.RunContext, item device, queryLabel string) map[string]interface{} {
	ipAddress := item.primaryIP()
	if ipAddress == "" {
		return nil
	}

	metadata := buildMetadata(item, queryLabel, metadataFieldsForSource(run.Source), run.Source.SyncServiceID)
	update := map[string]interface{}{
		"agent_id":   run.AgentID,
		"gateway_id": run.GatewayID,
		"partition":  run.Partition,
		"device_id":  fmt.Sprintf("%s:%s", run.Partition, ipAddress),
		"ip":         ipAddress,
		"source":     SourceType,
		"timestamp":  formatSecondTimestamp(time.Now()),
		"metadata":   metadata,
	}

	addTopLevelFields(update, item)

	return update
}

func formatSecondTimestamp(t time.Time) string {
	return t.UTC().Truncate(time.Second).Format(time.RFC3339)
}

func buildMetadata(item device, queryLabel string, rawMetadataFields []string, scope string) map[string]string {
	metadata := map[string]string{
		"integration_type": SourceType,
	}
	if item.ID > 0 {
		armisID := strconv.Itoa(item.ID)
		// Native provider key. Retained for northbound write-back, drift
		// audit, and resolution of identifier rows minted before scoped
		// integration IDs existed.
		metadata["armis_device_id"] = armisID
		if scoped := syncsources.ScopedIntegrationID(SourceType, scope, "device", armisID); scoped != "" {
			metadata["integration_id"] = scoped
		} else {
			// No stable source scope; keep the legacy bare value. Core
			// rejects it as unscoped rather than merging on it.
			metadata["integration_id"] = armisID
		}
	}
	if id := item.effectiveID(); id > 0 {
		metadata["source_device_id"] = strconv.Itoa(id)
	}

	if item.Type != "" {
		metadata["type"] = item.Type
		metadata["device_type"] = item.Type
	}
	if item.Category != "" {
		metadata["category"] = item.Category
	}
	if brand := firstNonEmpty(item.Brand, item.Manufacturer); brand != "" {
		metadata["brand"] = brand
		metadata["manufacturer"] = brand
	}
	if item.Model != "" {
		metadata["model"] = item.Model
	}
	if osName := firstNonEmpty(item.OSName, item.OperatingSystem); osName != "" {
		metadata["os_name"] = osName
		metadata["operating_system"] = osName
	}
	if item.OSVersion != "" {
		metadata["os_version"] = item.OSVersion
	}
	if encoded := compactJSONValue(item.Boundaries); encoded != "" {
		metadata["boundaries"] = encoded
	}
	if names := boundaryNames(item.Boundaries); len(names) > 0 {
		metadata["boundary_names"] = strings.Join(names, ",")
	}
	if riskLevel := item.effectiveRiskLevel(); riskLevel > 0 {
		metadata["risk_score"] = strconv.Itoa(riskLevel)
	}
	if queryLabel != "" {
		metadata["query_label"] = queryLabel
	}
	if len(item.Tags) > 0 {
		metadata["source_tags"] = strings.Join(item.Tags, ",")
	}
	if len(item.IPv4Addresses) > 0 {
		metadata["ipv4_addresses"] = strings.Join(item.IPv4Addresses, ",")
	}
	if len(item.IPv6Addresses) > 0 {
		metadata["ipv6_addresses"] = strings.Join(item.IPv6Addresses, ",")
	}
	if raw := item.rawMACValues(); raw != "" {
		// Raw comma-joined MAC values; the runtime normalization step
		// validates, normalizes, and deduplicates (or removes) them.
		metadata["mac_addresses"] = raw
	}
	if len(item.SerialNumbers) > 0 {
		metadata["serial_number"] = item.SerialNumbers[0]
		metadata["serial_numbers"] = strings.Join(item.SerialNumbers, ",")
	}
	if item.PurdueLevel != nil {
		purdueLevel := strconv.FormatFloat(*item.PurdueLevel, 'f', -1, 64)
		metadata["purdue_level"] = purdueLevel
	}
	if item.Visibility != "" {
		metadata["visibility"] = item.Visibility
	}
	if encoded := compactJSONValue(item.Site); encoded != "" {
		metadata["site"] = encoded
	}
	if encoded := compactJSONValue(item.NetworkInterfaces); encoded != "" {
		metadata["network_interfaces"] = encoded
	}
	addArmisRawMetadata(metadata, item, rawMetadataFields)

	return metadata
}

func addTopLevelFields(update map[string]interface{}, item device) {
	if raw := item.rawMACValues(); raw != "" {
		// Raw MAC field; the runtime normalization step reduces it to the
		// first valid MAC address (or removes the key).
		update["mac"] = raw
	}
	if hostname := item.primaryName(); hostname != "" {
		update["hostname"] = hostname
	}
	if item.Type != "" {
		update["type"] = item.Type
	}
	if brand := firstNonEmpty(item.Brand, item.Manufacturer); brand != "" {
		update["vendor_name"] = brand
	}
	if item.Model != "" {
		update["model"] = item.Model
	}
	if osName := firstNonEmpty(item.OSName, item.OperatingSystem); osName != "" {
		update["os"] = map[string]interface{}{
			"name":    osName,
			"version": item.OSVersion,
		}
	}
	if len(item.NetworkInterfaces) > 0 {
		update["network_interfaces"] = item.NetworkInterfaces
	}
	if firstSeen := item.effectiveFirstSeen(); !firstSeen.IsZero() {
		update["first_seen_time"] = formatSecondTimestamp(firstSeen)
	}
	if lastSeen := item.effectiveLastSeen(); !lastSeen.IsZero() {
		update["last_seen_time"] = formatSecondTimestamp(lastSeen)
	}
	if riskLevel := item.effectiveRiskLevel(); riskLevel > 0 {
		update["risk_score"] = riskLevel
	}
}
