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

package agent

import (
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
)

// Conversion of normalized sync device updates into SyncPageBatchV1. The
// input update is the JSON form of a normalized update map (the same form
// buildSyncResultsChunks marshals), so the typed page carries precisely
// what the legacy chunk carried. The projector rebuilds each update with
// its sync_meta attached and enqueues it into the same sync ingestion
// pipeline, so the DIRE population guard, conflicting-identity refusal and
// ingestion ledgers downstream are unchanged.

func syncPopulationReport(population *syncsources.PopulationStats) *edgev1.SyncPopulationReportV1 {
	if population == nil {
		return nil
	}
	return &edgev1.SyncPopulationReportV1{
		RawRows:                      int64(population.RawRows),
		ExcludedRows:                 int64(population.ExcludedRows),
		InvalidRows:                  int64(population.InvalidRows),
		ValidOccurrences:             int64(population.ValidOccurrences),
		DistinctSourceIds:            int64(population.DistinctSourceIDs),
		DuplicateOccurrences:         int64(population.DuplicateOccurrences),
		ConflictingDuplicateIds:      int64(len(population.ConflictingDuplicateIDs)),
		DuplicateSourceIdExamples:    boundedPopulationExamples(population.DuplicateSourceIDExamples),
		InvalidRowExamples:           boundedPopulationExamples(population.InvalidRowExamples),
		ConflictingDuplicateExamples: boundedPopulationExamples(population.ConflictingDuplicateIDs),
	}
}

func syncMetaRecord(meta syncChunkMeta, chunkIndex, totalChunks int, isFinal bool) *edgev1.SyncMetaV1 {
	record := &edgev1.SyncMetaV1{
		SyncServiceId: meta.syncServiceID,
		SyncRunId:     meta.runID,
		ChunkIndex:    int32(chunkIndex),
		TotalChunks:   int32(totalChunks),
		TotalDevices:  int32(meta.totalDevices),
		IsFinal:       isFinal,
	}
	if isFinal {
		record.Population = syncPopulationReport(meta.population)
	}
	return record
}

func optionalInt32(update map[string]interface{}, key string) *int32 {
	if _, ok := update[key]; !ok {
		return nil
	}
	value := int32(payloadNumber(update, key))
	return &value
}

func optionalInt64(update map[string]interface{}, key string) *int64 {
	if _, ok := update[key]; !ok {
		return nil
	}
	value := payloadNumber(update, key)
	return &value
}

func optionalBool(update map[string]interface{}, key string) *bool {
	if _, ok := update[key]; !ok {
		return nil
	}
	value := payloadBool(update, key)
	return &value
}

func syncDeviceRecord(update map[string]interface{}) *edgev1.SyncDeviceRecordV1 {
	record := &edgev1.SyncDeviceRecordV1{
		DeviceId:             payloadString(update, "device_id"),
		Uid:                  payloadString(update, "uid"),
		UidAlt:               payloadString(update, "uid_alt"),
		AgentId:              payloadString(update, "agent_id"),
		GatewayId:            payloadString(update, "gateway_id"),
		Partition:            payloadString(update, "partition"),
		Ip:                   payloadString(update, "ip"),
		Mac:                  payloadString(update, "mac"),
		Hostname:             payloadString(update, "hostname"),
		Name:                 payloadString(update, "name"),
		Source:               payloadString(update, "source"),
		SourceInstance:       payloadString(update, "source_instance"),
		DiscoverySources:     payloadStringList(update, "discovery_sources"),
		Type:                 payloadString(update, "type"),
		TypeId:               int32(payloadNumber(update, "type_id")),
		DeviceType:           payloadString(update, "device_type"),
		VendorName:           firstPayloadString(update, "vendor_name", "vendor", "manufacturer"),
		Model:                payloadString(update, "model"),
		Domain:               payloadString(update, "domain"),
		Zone:                 payloadString(update, "zone"),
		SubnetUid:            payloadString(update, "subnet_uid"),
		VlanUid:              payloadString(update, "vlan_uid"),
		Region:               payloadString(update, "region"),
		RiskLevelId:          optionalInt32(update, "risk_level_id"),
		RiskLevel:            payloadString(update, "risk_level"),
		RiskScore:            optionalInt32(update, "risk_score"),
		IsAvailable:          optionalBool(update, "is_available"),
		IsManaged:            optionalBool(update, "is_managed"),
		IsCompliant:          optionalBool(update, "is_compliant"),
		IsTrusted:            optionalBool(update, "is_trusted"),
		TimestampUnixNano:    payloadTimeNano(update, "timestamp"),
		FirstSeenUnixNano:    payloadTimeNano(update, "first_seen_time"),
		LastSeenUnixNano:     payloadTimeNano(update, "last_seen_time"),
		CreatedTimeUnixNano:  payloadTimeNano(update, "created_time"),
		ModifiedTimeUnixNano: payloadTimeNano(update, "modified_time"),
		SwitchPortAttachment: updateStringMap(update["switch_port_attachment"]),
		Metadata:             updateStringMap(update["metadata"]),
		Tags:                 updateStringMap(update["tags"]),
		Facts:                updateStringMap(update["facts"]),
	}
	if osInfo := payloadMap(update, "os"); osInfo != nil {
		record.Os = &edgev1.SyncDeviceOsV1{
			Name:          payloadString(osInfo, "name"),
			Type:          payloadString(osInfo, "type"),
			TypeId:        optionalInt32(osInfo, "type_id"),
			Version:       payloadString(osInfo, "version"),
			Build:         payloadString(osInfo, "build"),
			Edition:       payloadString(osInfo, "edition"),
			KernelRelease: payloadString(osInfo, "kernel_release"),
			CpuBits:       optionalInt32(osInfo, "cpu_bits"),
			SpName:        payloadString(osInfo, "sp_name"),
			SpVer:         payloadString(osInfo, "sp_ver"),
			Lang:          payloadString(osInfo, "lang"),
		}
	}
	if hw := payloadMap(update, "hw_info"); hw != nil {
		record.HwInfo = &edgev1.SyncDeviceHwInfoV1{
			CpuArchitecture:  payloadString(hw, "cpu_architecture"),
			CpuBits:          optionalInt32(hw, "cpu_bits"),
			CpuCores:         optionalInt32(hw, "cpu_cores"),
			CpuCount:         optionalInt32(hw, "cpu_count"),
			CpuSpeedMhz:      firstOptionalInt32(hw, "cpu_speed_mhz", "cpu_speed"),
			CpuType:          payloadString(hw, "cpu_type"),
			RamSize:          optionalInt64(hw, "ram_size"),
			SerialNumber:     payloadString(hw, "serial_number"),
			Chassis:          payloadString(hw, "chassis"),
			BiosManufacturer: payloadString(hw, "bios_manufacturer"),
			BiosVer:          payloadString(hw, "bios_ver"),
			BiosDate:         payloadString(hw, "bios_date"),
			Uuid:             payloadString(hw, "uuid"),
		}
	}
	record.NetworkInterfaces = syncNetworkInterfaces(update)
	if owner := payloadMap(update, "owner"); owner != nil {
		record.Owner = &edgev1.SyncDeviceUserV1{
			Uid:    payloadString(owner, "uid"),
			Name:   payloadString(owner, "name"),
			Email:  firstPayloadString(owner, "email_addr", "email"),
			Type:   payloadString(owner, "type"),
			TypeId: optionalInt32(owner, "type_id"),
		}
	}
	if org := payloadMap(update, "org"); org != nil {
		record.Org = &edgev1.SyncDeviceOrganizationV1{
			Uid:    payloadString(org, "uid"),
			Name:   payloadString(org, "name"),
			OuUid:  payloadString(org, "ou_uid"),
			OuName: payloadString(org, "ou_name"),
		}
	}
	for _, raw := range payloadList(update, "groups") {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		record.Groups = append(record.Groups, &edgev1.SyncDeviceGroupV1{
			Uid:  payloadString(entry, "uid"),
			Name: payloadString(entry, "name"),
			Type: payloadString(entry, "type"),
			Desc: payloadString(entry, "desc"),
		})
	}
	for _, raw := range payloadList(update, "agent_list") {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		record.AgentList = append(record.AgentList, &edgev1.SyncDeviceAgentV1{
			Uid:        payloadString(entry, "uid"),
			Name:       payloadString(entry, "name"),
			Type:       payloadString(entry, "type"),
			TypeId:     optionalInt32(entry, "type_id"),
			Version:    payloadString(entry, "version"),
			VendorName: payloadString(entry, "vendor_name"),
		})
	}
	return record
}

func syncNetworkInterfaces(update map[string]interface{}) []*edgev1.SyncNetworkInterfaceV1 {
	raw := payloadList(update, "network_interfaces")
	if raw == nil {
		raw = payloadList(update, "interfaces")
	}
	var out []*edgev1.SyncNetworkInterfaceV1
	for _, item := range raw {
		entry, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		out = append(out, &edgev1.SyncNetworkInterfaceV1{
			Name:                firstPayloadString(entry, "name", "if_name", "interface_name", "port_name"),
			Description:         firstPayloadString(entry, "description", "if_descr", "desc", "port_descr"),
			Alias:               firstPayloadString(entry, "alias", "if_alias", "label"),
			MacAddress:          firstPayloadString(entry, "mac_address", "mac", "if_phys_address"),
			Ipv4Address:         firstPayloadString(entry, "ipv4_address", "ip_address", "ip"),
			Ipv6Address:         payloadString(entry, "ipv6_address"),
			IpAddresses:         firstStringList(entry, "ip_addresses", "ips"),
			Cidr:                payloadString(entry, "cidr"),
			Subnet:              payloadString(entry, "subnet"),
			Hostname:            payloadString(entry, "hostname"),
			Uid:                 firstPayloadString(entry, "uid", "id", "interface_uid"),
			Type:                payloadString(entry, "type"),
			TypeId:              firstOptionalInt32(entry, "type_id", "if_type"),
			Brand:               payloadString(entry, "brand"),
			BroadcastSsid:       firstPayloadString(entry, "broadcast_ssid", "ssid"),
			HiddenBroadcastSsid: optionalBool(entry, "hidden_broadcast_ssid"),
			LastConnectedSsid:   payloadString(entry, "last_connected_ssid"),
			Channels:            payloadStringList(entry, "channels"),
			Vlan:                optionalInt32(entry, "vlan"),
		})
	}
	return out
}

func firstPayloadString(payload map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		if value := payloadString(payload, key); value != "" {
			return value
		}
	}
	return ""
}

func firstOptionalInt32(payload map[string]interface{}, keys ...string) *int32 {
	for _, key := range keys {
		if value := optionalInt32(payload, key); value != nil {
			return value
		}
	}
	return nil
}

func firstStringList(payload map[string]interface{}, keys ...string) []string {
	for _, key := range keys {
		if value := payloadStringList(payload, key); value != nil {
			return value
		}
	}
	return nil
}
