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
	"strings"
	"time"
)

// publishTopologyLinks adds topology links to results and publishes them
func (e *DiscoveryEngine) publishTopologyLinks(job *DiscoveryJob, links []*TopologyLink, target, protocol string) {
	if len(links) == 0 {
		return
	}

	job.mu.Lock()
	job.Results.TopologyLinks = append(job.Results.TopologyLinks, links...)
	job.mu.Unlock()

	// Publish links
	if e.publisher != nil {
		for _, link := range links {
			if link.Metadata == nil {
				link.Metadata = make(map[string]string)
			}
			applySourceAdapterVersion(link)
			applyTopologyEvidenceClass(link)
			resolveLocalInterfaceName(job, link)
			attachTopologyObservationV2(link)
			NormalizeTopologyLinkNeighborIdentity(link)
			link.Metadata["discovery_id"] = job.ID
			link.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
			applyJobOptionsMetadata(job, link.Metadata)
			if strings.EqualFold(strings.TrimSpace(link.Metadata["candidate_only"]), "true") {
				continue
			}
			if err := e.publisher.PublishTopologyLink(job.ctx, link); err != nil {
				e.logger.Error().Str("job_id", job.ID).Str("protocol", protocol).
					Str("target", target).Int32("if_index", link.LocalIfIndex).
					Err(err).Msg("Failed to publish link")
			}
		}
	}
}

// resolveLocalInterfaceName fills link.LocalIfName from the discovered interface
// table (matched by ifindex) when the topology source — LLDP/CDP — only provided
// a local ifindex and no name. Without this, core's interface_id/3 falls back to
// keying the local endpoint as "<device_id>/ifindex:N", which duplicates the
// named "<device_id>/<port-name>" Interface vertex that the SNMP interface scan
// creates for the same physical port. Resolving the name at the source keeps one
// vertex per port. No-op when a name is already present, the ifindex is unknown
// (<= 0), or no matching interface was discovered.
func resolveLocalInterfaceName(job *DiscoveryJob, link *TopologyLink) {
	if job == nil || link == nil {
		return
	}

	if strings.TrimSpace(link.LocalIfName) != "" || link.LocalIfIndex <= 0 {
		return
	}

	job.mu.RLock()
	defer job.mu.RUnlock()

	for _, iface := range job.Results.Interfaces {
		if iface == nil || iface.IfIndex != link.LocalIfIndex {
			continue
		}

		// Mirror discovery_snmp.go's interface naming precedence EXACTLY
		// (IfName -> IfDescr -> "Interface-<ifindex>", never IfAlias) so the
		// resolved link name equals the id the interface-table scan keys the
		// vertex by. Diverging here (e.g. falling back to IfAlias) would resolve
		// to a different label than the scan's vertex and re-introduce a phantom.
		name := strings.TrimSpace(iface.IfName)
		if name == "" {
			name = strings.TrimSpace(iface.IfDescr)
		}

		if name == "" {
			name = fmt.Sprintf("Interface-%d", iface.IfIndex)
		}

		link.LocalIfName = name

		return
	}
}

func applySourceAdapterVersion(link *TopologyLink) {
	if link == nil {
		return
	}
	if link.Metadata == nil {
		link.Metadata = make(map[string]string)
	}
	if strings.TrimSpace(link.Metadata["source_adapter_version"]) != "" {
		return
	}

	source := strings.ToLower(strings.TrimSpace(link.Metadata["source"]))
	protocol := strings.ToLower(strings.TrimSpace(link.Protocol))

	switch {
	case strings.HasPrefix(source, "unifi-api"):
		link.Metadata["source_adapter_version"] = sourceAdapterUniFiV1
		link.Metadata["source_adapter_family"] = "unifi"
	case strings.HasPrefix(source, "mikrotik-api"):
		link.Metadata["source_adapter_version"] = sourceAdapterMikroTikV1
		link.Metadata["source_adapter_family"] = "mikrotik"
	case protocol == protocolLLDP:
		link.Metadata["source_adapter_version"] = sourceAdapterLLDPV1
		link.Metadata["source_adapter_family"] = protocolLLDP
	case protocol == protocolCDP:
		link.Metadata["source_adapter_version"] = sourceAdapterCDPV1
		link.Metadata["source_adapter_family"] = protocolCDP
	case protocol == protocolSNMPL2 || strings.HasPrefix(source, "snmp-"):
		link.Metadata["source_adapter_version"] = sourceAdapterSNMPV1
		link.Metadata["source_adapter_family"] = discoveryModeSNMP
	default:
		link.Metadata["source_adapter_version"] = "unknown.v1"
		link.Metadata["source_adapter_family"] = "unknown"
	}
}

func applyJobOptionsMetadata(job *DiscoveryJob, metadata map[string]string) {
	if job == nil || job.Params == nil || metadata == nil {
		return
	}

	for key, value := range job.Params.Options {
		if value == "" {
			continue
		}
		if jobOptionShouldStayOperational(key) {
			continue
		}
		metadata[key] = value
	}
}

func jobOptionShouldStayOperational(key string) bool {
	switch strings.TrimSpace(strings.ToLower(key)) {
	case proxmoxCandidateProbeOption:
		return true
	default:
		return false
	}
}
