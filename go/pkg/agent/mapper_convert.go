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
	"bytes"
	"encoding/json"
	"strconv"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Conversion of mapper update payloads into the typed mapper batches of
// proto/edge/v1/json_producer_batches.proto. The input is the exact JSON
// array the mapper payload builders produce (host agent/gateway/partition
// stamps and the candidate-only topology filter already applied), decoded
// back into maps. Metadata maps ride verbatim; the promoted typed fields are
// read out of the same metadata for typed consumers, and the projector
// rebuilds the update payload from the verbatim maps.

func decodeUpdateArray(data []byte) []map[string]interface{} {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var updates []map[string]interface{}
	if err := decoder.Decode(&updates); err != nil {
		return nil
	}
	return updates
}

func payloadMap(payload map[string]interface{}, key string) map[string]interface{} {
	if nested, ok := payload[key].(map[string]interface{}); ok {
		return nested
	}
	return nil
}

func payloadTimeNano(payload map[string]interface{}, key string) int64 {
	text := payloadString(payload, key)
	if text == "" {
		return 0
	}
	if parsed, err := time.Parse(time.RFC3339Nano, text); err == nil {
		return parsed.UnixNano()
	}
	if parsed, err := time.Parse(time.RFC3339, text); err == nil {
		return parsed.UnixNano()
	}
	return 0
}

func metadataString(metadata map[string]string, key string) string {
	return metadata[key]
}

func metadataInt32(metadata map[string]string, key string) int32 {
	value, err := strconv.ParseInt(metadata[key], 10, 32)
	if err != nil {
		return 0
	}
	return int32(value)
}

func metadataInt64(metadata map[string]string, key string) int64 {
	value, err := strconv.ParseInt(metadata[key], 10, 64)
	if err != nil {
		return 0
	}
	return value
}

func mapperDeviceRecord(update map[string]interface{}) *edgev1.MapperDeviceRecordV1 {
	metadata := updateStringMap(update["metadata"])
	record := &edgev1.MapperDeviceRecordV1{
		DeviceId:          payloadString(update, "device_id"),
		Ip:                payloadString(update, "ip"),
		Source:            payloadString(update, "source"),
		TimestampUnixNano: payloadTimeNano(update, "timestamp"),
		IsAvailable:       payloadBool(update, "is_available"),
		Hostname:          payloadString(update, "hostname"),
		Mac:               payloadString(update, "mac"),
		AgentId:           payloadString(update, "agent_id"),
		GatewayId:         payloadString(update, "gateway_id"),
		Partition:         payloadString(update, "partition"),
		SnmpFingerprint:   mapperSnmpFingerprint(payloadMap(update, "snmp_fingerprint")),
		SyncServiceId:     metadataString(metadata, "sync_service_id"),
		IdentityMacKind:   metadataString(metadata, "identity_mac_kind"),
		SysDescr:          metadataString(metadata, "sys_descr"),
		SnmpDescription:   metadataString(metadata, "snmp_description"),
		SysObjectId:       metadataString(metadata, "sys_object_id"),
		SysName:           metadataString(metadata, "sys_name"),
		SnmpName:          metadataString(metadata, "snmp_name"),
		SysContact:        metadataString(metadata, "sys_contact"),
		SysOwner:          metadataString(metadata, "sys_owner"),
		SnmpOwner:         metadataString(metadata, "snmp_owner"),
		SysLocation:       metadataString(metadata, "sys_location"),
		SnmpLocation:      metadataString(metadata, "snmp_location"),
		IpForwarding:      metadataInt32(metadata, "ip_forwarding"),
		BridgeBaseMac:     metadataString(metadata, "bridge_base_mac"),
		Uptime:            metadataInt64(metadata, "uptime"),
		FirstSeenUnixNano: payloadTimeNano(update, "first_seen_time"),
		LastSeenUnixNano:  payloadTimeNano(update, "last_seen_time"),
		Metadata:          metadata,
	}
	return record
}

func mapperSnmpFingerprint(fp map[string]interface{}) *edgev1.MapperSnmpFingerprintV1 {
	if fp == nil {
		return nil
	}
	out := &edgev1.MapperSnmpFingerprintV1{
		ExtractionErrors: updateStringMap(fp["extraction_errors"]),
	}
	if system := payloadMap(fp, "system"); system != nil {
		out.System = &edgev1.MapperSnmpSystemFingerprintV1{
			SysName:      payloadString(system, "sys_name"),
			SysDescr:     payloadString(system, "sys_descr"),
			SysObjectId:  payloadString(system, "sys_object_id"),
			SysContact:   payloadString(system, "sys_contact"),
			SysLocation:  payloadString(system, "sys_location"),
			IpForwarding: int32(payloadNumber(system, "ip_forwarding")),
		}
	}
	if bridge := payloadMap(fp, "bridge"); bridge != nil {
		out.Bridge = &edgev1.MapperSnmpBridgeFingerprintV1{
			BridgeBaseMac:          payloadString(bridge, "bridge_base_mac"),
			BridgePortCount:        int32(payloadNumber(bridge, "bridge_port_count")),
			StpForwardingPortCount: int32(payloadNumber(bridge, "stp_forwarding_port_count")),
		}
	}
	if vlan := payloadMap(fp, "vlan"); vlan != nil {
		out.Vlan = mapperSnmpVlan(vlan)
	}
	if summary := payloadMap(fp, "interface_summary"); summary != nil {
		out.InterfaceSummary = mapperSnmpInterfaceSummary(summary)
	}
	return out
}

func mapperSnmpVlan(vlan map[string]interface{}) *edgev1.MapperSnmpVlanFingerprintV1 {
	out := &edgev1.MapperSnmpVlanFingerprintV1{}
	for _, raw := range payloadList(vlan, "vlan_ids_seen") {
		out.VlanIdsSeen = append(out.VlanIdsSeen, int32(numberValue(raw)))
	}
	for _, raw := range payloadList(vlan, "pvid_distribution") {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		out.PvidDistribution = append(out.PvidDistribution, &edgev1.MapperSnmpVlanPvidCountV1{
			Pvid:  int32(payloadNumber(entry, "pvid")),
			Count: int32(payloadNumber(entry, "count")),
		})
	}
	for _, raw := range payloadList(vlan, "port_evidence") {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		out.PortEvidence = append(out.PortEvidence, &edgev1.MapperSnmpVlanPortEvidenceV1{
			VlanId:           int32(payloadNumber(entry, "vlan_id")),
			EgressPortsHex:   payloadString(entry, "egress_ports_hex"),
			UntaggedPortsHex: payloadString(entry, "untagged_ports_hex"),
		})
	}
	return out
}

func mapperSnmpInterfaceSummary(summary map[string]interface{}) *edgev1.MapperSnmpInterfaceSummaryV1 {
	out := &edgev1.MapperSnmpInterfaceSummaryV1{
		InterfaceCount:        int32(payloadNumber(summary, "interface_count")),
		BridgeLikeNameCount:   int32(payloadNumber(summary, "bridge_like_name_count")),
		WirelessLikeNameCount: int32(payloadNumber(summary, "wireless_like_name_count")),
	}
	for _, raw := range payloadList(summary, "if_type_counts") {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		out.IfTypeCounts = append(out.IfTypeCounts, &edgev1.MapperSnmpIfTypeCountV1{
			IfType: int32(payloadNumber(entry, "if_type")),
			Count:  int32(payloadNumber(entry, "count")),
		})
	}
	return out
}

func numberValue(raw interface{}) int64 {
	return payloadNumber(map[string]interface{}{"v": raw}, "v")
}

func mapperInterfaceRecord(update map[string]interface{}) *edgev1.MapperInterfaceRecordV1 {
	record := &edgev1.MapperInterfaceRecordV1{
		DeviceId:          payloadString(update, "device_id"),
		DeviceIp:          payloadString(update, "device_ip"),
		IfIndex:           int32(payloadNumber(update, "if_index")),
		IfName:            payloadString(update, "if_name"),
		IfDescr:           payloadString(update, "if_descr"),
		IfAlias:           payloadString(update, "if_alias"),
		IfSpeed:           uint64(payloadNumber(update, "if_speed")),
		IfPhysAddress:     payloadString(update, "if_phys_address"),
		IpAddresses:       payloadStringList(update, "ip_addresses"),
		IfAdminStatus:     int32(payloadNumber(update, "if_admin_status")),
		IfOperStatus:      int32(payloadNumber(update, "if_oper_status")),
		IfType:            int32(payloadNumber(update, "if_type")),
		Duplex:            payloadString(update, "duplex"),
		Source:            payloadString(update, "source"),
		Metadata:          updateStringMap(update["metadata"]),
		TimestampUnixNano: payloadTimeNano(update, "timestamp"),
		AgentId:           payloadString(update, "agent_id"),
		GatewayId:         payloadString(update, "gateway_id"),
		Partition:         payloadString(update, "partition"),
	}
	if _, ok := update["speed_bps"]; ok {
		speed := uint64(payloadNumber(update, "speed_bps"))
		record.SpeedBps = &speed
	}
	if _, ok := update["mtu"]; ok {
		mtu := int32(payloadNumber(update, "mtu"))
		record.Mtu = &mtu
	}
	for _, raw := range payloadList(update, "available_metrics") {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		record.AvailableMetrics = append(record.AvailableMetrics, &edgev1.MapperInterfaceMetricV1{
			Name:           payloadString(entry, "name"),
			Oid:            payloadString(entry, "oid"),
			DataType:       payloadString(entry, "data_type"),
			Supports_64Bit: payloadBool(entry, "supports_64bit"),
			Oid_64Bit:      payloadString(entry, "oid_64bit"),
			Category:       payloadString(entry, "category"),
			Unit:           payloadString(entry, "unit"),
		})
	}
	return record
}

func mapperTopologyRecord(update map[string]interface{}) *edgev1.MapperTopologyLinkRecordV1 {
	metadata := updateStringMap(update["metadata"])
	record := &edgev1.MapperTopologyLinkRecordV1{
		Protocol:           payloadString(update, "protocol"),
		LocalDeviceIp:      payloadString(update, "local_device_ip"),
		LocalDeviceId:      payloadString(update, "local_device_id"),
		LocalIfIndex:       int32(payloadNumber(update, "local_if_index")),
		LocalIfName:        payloadString(update, "local_if_name"),
		NeighborDeviceId:   payloadString(update, "neighbor_device_id"),
		NeighborChassisId:  payloadString(update, "neighbor_chassis_id"),
		NeighborPortId:     payloadString(update, "neighbor_port_id"),
		NeighborPortDescr:  payloadString(update, "neighbor_port_descr"),
		NeighborSystemName: payloadString(update, "neighbor_system_name"),
		NeighborMgmtAddr:   payloadString(update, "neighbor_mgmt_addr"),
		Metadata:           metadata,
		TimestampUnixNano:  payloadTimeNano(update, "timestamp"),
		AgentId:            payloadString(update, "agent_id"),
		GatewayId:          payloadString(update, "gateway_id"),
		Partition:          payloadString(update, "partition"),
	}
	if identity := payloadMap(update, "neighbor_identity"); identity != nil {
		record.NeighborIdentity = &edgev1.MapperNeighborIdentityV1{
			ManagementIp: payloadString(identity, "management_ip"),
			DeviceId:     payloadString(identity, "device_id"),
			ChassisId:    payloadString(identity, "chassis_id"),
			PortId:       payloadString(identity, "port_id"),
			PortDescr:    payloadString(identity, "port_descr"),
			SystemName:   payloadString(identity, "system_name"),
		}
	}
	if observation := payloadMap(update, "observation"); observation != nil {
		record.Observation = mapperTopologyObservation(observation)
		record.ConfidenceTier = payloadString(observation, "confidence_tier")
	}
	if record.ConfidenceTier == "" {
		record.ConfidenceTier = payloadString(update, "confidence_tier")
	}
	if record.ConfidenceTier == "" {
		record.ConfidenceTier = metadataString(metadata, "confidence_tier")
	}
	record.ConfidenceReason = metadataString(metadata, "confidence_reason")
	return record
}

func mapperTopologyObservation(observation map[string]interface{}) *edgev1.MapperTopologyObservationV2 {
	return &edgev1.MapperTopologyObservationV2{
		ContractVersion: payloadString(observation, "contract_version"),
		ObservationType: payloadString(observation, "observation_type"),
		SourceProtocol:  payloadString(observation, "source_protocol"),
		SourceAdapter:   payloadString(observation, "source_adapter"),
		EvidenceClass:   payloadString(observation, "evidence_class"),
		ConfidenceTier:  payloadString(observation, "confidence_tier"),
		ObservedAtUnix:  payloadNumber(observation, "observed_at_unix"),
		DiscoveryId:     payloadString(observation, "discovery_id"),
		SourceEndpoint:  mapperTopologyEndpoint(payloadMap(observation, "source_endpoint")),
		TargetEndpoint:  mapperTopologyEndpoint(payloadMap(observation, "target_endpoint")),
		RawAttributes:   updateStringMap(observation["raw_attributes"]),
	}
}

func mapperTopologyEndpoint(endpoint map[string]interface{}) *edgev1.MapperTopologyEndpointV1 {
	if endpoint == nil {
		return nil
	}
	return &edgev1.MapperTopologyEndpointV1{
		Uid:      payloadString(endpoint, "uid"),
		DeviceId: payloadString(endpoint, "device_id"),
		Ip:       payloadString(endpoint, "ip"),
		Mac:      payloadString(endpoint, "mac"),
		PortId:   payloadString(endpoint, "port_id"),
		IfName:   payloadString(endpoint, "if_name"),
		IfIndex:  int32(payloadNumber(endpoint, "if_index")),
		SysName:  payloadString(endpoint, "sys_name"),
	}
}
