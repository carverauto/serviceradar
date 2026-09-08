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
	"encoding/json"
	"strings"
	"time"
)

func attachTopologyObservationV2(link *TopologyLink) {
	if link == nil {
		return
	}
	if link.Metadata == nil {
		link.Metadata = make(map[string]string)
	}

	if link.Observation == nil {
		link.Observation = buildTopologyObservationV2(link)
	}
	if link.Observation == nil {
		return
	}

	link.Metadata["observation_contract_version"] = link.Observation.ContractVersion
	link.Metadata["observation_type"] = link.Observation.ObservationType
	link.Metadata["observation_source_protocol"] = link.Observation.SourceProtocol
	link.Metadata["observation_source_adapter"] = link.Observation.SourceAdapter
	link.Metadata["observation_evidence_class"] = link.Observation.EvidenceClass
	link.Metadata["observation_confidence_tier"] = link.Observation.ConfidenceTier

	raw, err := json.Marshal(link.Observation)
	if err == nil {
		link.Metadata["observation_v2_json"] = string(raw)
	}
}

func buildTopologyObservationV2(link *TopologyLink) *TopologyObservationV2 {
	if link == nil {
		return nil
	}
	sourceProtocol := strings.ToLower(strings.TrimSpace(link.Protocol))
	if sourceProtocol == "" {
		sourceProtocol = "unknown"
	}
	evidenceClass := strings.TrimSpace(link.Metadata["evidence_class"])
	confidenceTier := strings.TrimSpace(link.Metadata["confidence_tier"])
	adapter := strings.TrimSpace(link.Metadata["source_adapter_version"])

	sourceUID := strings.TrimSpace(link.LocalDeviceID)
	if sourceUID == "" {
		sourceUID = strings.TrimSpace(link.LocalDeviceIP)
	}
	targetUID := strings.TrimSpace(link.NeighborChassisID)
	if targetUID == "" {
		targetUID = strings.TrimSpace(link.NeighborMgmtAddr)
	}
	neighborDeviceID := ""
	if link.NeighborIdentity != nil {
		neighborDeviceID = strings.TrimSpace(link.NeighborIdentity.DeviceID)
	}
	if targetUID == "" && neighborDeviceID != "" {
		targetUID = neighborDeviceID
	}

	return &TopologyObservationV2{
		ContractVersion: topologyContractV2,
		ObservationType: "topology_link",
		SourceProtocol:  sourceProtocol,
		SourceAdapter:   adapter,
		EvidenceClass:   evidenceClass,
		ConfidenceTier:  confidenceTier,
		ObservedAtUnix:  time.Now().UTC().Unix(),
		DiscoveryID:     strings.TrimSpace(link.Metadata["discovery_id"]),
		SourceEndpoint: TopologyObservationEndpointV2{
			UID:      sourceUID,
			DeviceID: strings.TrimSpace(link.LocalDeviceID),
			IP:       strings.TrimSpace(link.LocalDeviceIP),
			IfIndex:  link.LocalIfIndex,
			IfName:   strings.TrimSpace(link.LocalIfName),
		},
		TargetEndpoint: TopologyObservationEndpointV2{
			UID:      targetUID,
			DeviceID: neighborDeviceID,
			IP:       strings.TrimSpace(link.NeighborMgmtAddr),
			MAC:      strings.TrimSpace(link.NeighborChassisID),
			PortID:   strings.TrimSpace(link.NeighborPortID),
			SysName:  strings.TrimSpace(link.NeighborSystemName),
		},
		RawAttributes: map[string]string{
			"neighbor_port_descr": strings.TrimSpace(link.NeighborPortDescr),
			"source":              strings.TrimSpace(link.Metadata["source"]),
			"confidence_reason":   strings.TrimSpace(link.Metadata["confidence_reason"]),
		},
	}
}
