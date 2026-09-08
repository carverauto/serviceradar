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
	"strings"
)

func applyTopologyEvidenceClass(link *TopologyLink) {
	if link == nil {
		return
	}

	if link.Metadata == nil {
		link.Metadata = make(map[string]string)
	}

	if cls := strings.TrimSpace(link.Metadata["evidence_class"]); cls != "" {
		link.Metadata["evidence_class"] = normalizeTopologyEvidenceClass(cls)
		applyTopologyRelationFamily(link)
		if strings.TrimSpace(link.Metadata["confidence_tier"]) != "" {
			return
		}

		switch link.Metadata["evidence_class"] {
		case evidenceClassDirectPhysical, evidenceClassDirectLogical, evidenceClassHostedVirtual, evidenceClassEndpointAttachment:
			link.Metadata["confidence_tier"] = confidenceTierHigh
		case evidenceClassInferredSegment:
			link.Metadata["confidence_tier"] = confidenceTierMedium
		default:
			link.Metadata["confidence_tier"] = confidenceTierLow
		}
		return
	}

	protocol := strings.ToLower(strings.TrimSpace(link.Protocol))
	source := strings.ToLower(strings.TrimSpace(link.Metadata["source"]))

	switch {
	case protocol == "lldp" || protocol == "cdp":
		link.Metadata["evidence_class"] = evidenceClassDirectPhysical
	case protocol == "wireguard-derived":
		link.Metadata["evidence_class"] = evidenceClassDirectLogical
	case protocol == "unifi-api" && strings.Contains(source, "port-table"):
		link.Metadata["evidence_class"] = evidenceClassInferredSegment
	case protocol == "unifi-api" || protocol == "mikrotik-api":
		link.Metadata["evidence_class"] = evidenceClassDirectPhysical
	case protocol == "proxmox-api" || protocol == "proxmox" || protocol == "vmware" || protocol == "esxi":
		link.Metadata["evidence_class"] = evidenceClassHostedVirtual
	case protocol == protocolSNMPL2 || source == sourceSNMPARPFDB:
		link.Metadata["evidence_class"] = evidenceClassInferredSegment
	default:
		link.Metadata["evidence_class"] = evidenceClassInferredSegment
	}

	applyTopologyRelationFamily(link)

	if strings.TrimSpace(link.Metadata["confidence_tier"]) != "" {
		return
	}

	switch link.Metadata["evidence_class"] {
	case evidenceClassDirectPhysical, evidenceClassDirectLogical, evidenceClassHostedVirtual, evidenceClassEndpointAttachment:
		link.Metadata["confidence_tier"] = confidenceTierHigh
	case evidenceClassInferredSegment:
		link.Metadata["confidence_tier"] = confidenceTierMedium
	default:
		link.Metadata["confidence_tier"] = confidenceTierLow
	}
}

func normalizeTopologyEvidenceClass(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "direct":
		return evidenceClassDirectPhysical
	case "inferred":
		return evidenceClassInferredSegment
	case evidenceClassEndpointAttachment:
		return evidenceClassEndpointAttachment
	default:
		return strings.ToLower(strings.TrimSpace(value))
	}
}

func applyTopologyRelationFamily(link *TopologyLink) {
	if link == nil {
		return
	}
	if link.Metadata == nil {
		link.Metadata = make(map[string]string)
	}
	if family := strings.TrimSpace(link.Metadata["relation_family"]); family != "" {
		link.Metadata["relation_family"] = strings.ToUpper(family)
		return
	}

	protocol := strings.ToLower(strings.TrimSpace(link.Protocol))
	source := strings.ToLower(strings.TrimSpace(link.Metadata["source"]))
	evidenceClass := normalizeTopologyEvidenceClass(link.Metadata["evidence_class"])
	confidenceReason := strings.ToLower(strings.TrimSpace(link.Metadata["confidence_reason"]))

	switch {
	case evidenceClass == evidenceClassDirectPhysical:
		link.Metadata["relation_family"] = "CONNECTS_TO"
	case evidenceClass == evidenceClassDirectLogical:
		link.Metadata["relation_family"] = "LOGICAL_PEER"
	case evidenceClass == evidenceClassHostedVirtual:
		link.Metadata["relation_family"] = "HOSTED_ON"
	case evidenceClass == evidenceClassEndpointAttachment:
		link.Metadata["relation_family"] = "ATTACHED_TO"
	case evidenceClass == evidenceClassObservedOnly:
		link.Metadata["relation_family"] = relationObservedTo
	case evidenceClass == evidenceClassInferredSegment &&
		confidenceReason == "single_identifier_inference" &&
		(protocol == protocolSNMPL2 || source == sourceSNMPARPFDB):
		link.Metadata["relation_family"] = relationObservedTo
	case evidenceClass == evidenceClassInferredSegment &&
		(protocol == protocolSNMPL2 || source == sourceSNMPARPFDB || strings.Contains(source, "port-table")):
		link.Metadata["relation_family"] = "ATTACHED_TO"
	case evidenceClass == evidenceClassInferredSegment:
		link.Metadata["relation_family"] = "INFERRED_TO"
	default:
		link.Metadata["relation_family"] = relationObservedTo
	}
}
