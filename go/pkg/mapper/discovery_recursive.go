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

func (e *DiscoveryEngine) collectRecursiveSNMPTargets(
	job *DiscoveryJob, knownTargets map[string]bool) map[string]bool {
	if job == nil {
		return map[string]bool{}
	}

	job.mu.RLock()
	defer job.mu.RUnlock()

	targets := make(map[string]bool)
	identityToIP := recursiveNeighborIdentityIndex(job.Results)

	for _, link := range job.Results.TopologyLinks {
		if link == nil {
			continue
		}
		if !recursiveTopologyLinkEligible(link) {
			continue
		}

		neighborCandidates := recursiveNeighborCandidates(link, identityToIP)
		for _, neighborIP := range neighborCandidates {
			if knownTargets[neighborIP] {
				continue
			}

			targets[neighborIP] = true
		}
	}

	return targets
}

func recursiveTopologyLinkEligible(link *TopologyLink) bool {
	if link == nil {
		return false
	}

	if link.Metadata == nil {
		link.Metadata = make(map[string]string)
	}

	applySourceAdapterVersion(link)
	applyTopologyEvidenceClass(link)

	if strings.EqualFold(strings.TrimSpace(link.Metadata["candidate_only"]), "true") {
		return recursiveCandidateOnlyTopologyLinkEligible(link)
	}

	if recursiveWiredNeighborEligible(link) {
		return true
	}

	evidenceClass := normalizeTopologyEvidenceClass(link.Metadata["evidence_class"])

	switch evidenceClass {
	case evidenceClassDirectPhysical, evidenceClassDirectLogical, evidenceClassHostedVirtual:
		return true
	default:
		return false
	}
}

// UniFi (and similar controller) wired clients carry a management IPv4 but
// stay endpoint-attachment in the mapper job — ingest later classifies them
// as direct-physical. Recursion must use the same neighbor IP or a Catalyst
// on a non-seed VLAN is never SNMP'd.
func recursiveWiredNeighborEligible(link *TopologyLink) bool {
	if link == nil || link.Metadata == nil {
		return false
	}

	if !isIPv4(strings.TrimSpace(link.NeighborMgmtAddr)) {
		return false
	}

	source := strings.ToLower(strings.TrimSpace(link.Metadata["source"]))
	return strings.Contains(source, "wired-client")
}

func recursiveCandidateOnlyTopologyLinkEligible(link *TopologyLink) bool {
	if link == nil {
		return false
	}

	if !strings.EqualFold(strings.TrimSpace(link.Protocol), "SNMP-L2") {
		return false
	}

	if !strings.EqualFold(strings.TrimSpace(link.Metadata["source"]), "snmp-arp-only") {
		return false
	}

	if !strings.EqualFold(strings.TrimSpace(link.Metadata["confidence_reason"]), "single_identifier_inference") {
		return false
	}

	return isIPv4(strings.TrimSpace(link.NeighborMgmtAddr))
}

func recursiveNeighborIdentityIndex(results *DiscoveryResults) map[string]string {
	index := make(map[string]string)
	if results == nil {
		return index
	}

	for _, device := range results.Devices {
		if device == nil {
			continue
		}

		ip := strings.TrimSpace(device.IP)
		if ip == "" || !isIPv4(ip) {
			continue
		}

		mac := NormalizeMAC(device.MAC)
		if mac != "" {
			index["mac:"+mac] = ip
		}

		for _, name := range []string{device.Hostname, device.SysName, device.DeviceID} {
			normalized := normalizeRecursiveNeighborName(name)
			if normalized != "" {
				index["name:"+normalized] = ip
			}
		}
	}

	return index
}

func recursiveNeighborCandidates(link *TopologyLink, identityToIP map[string]string) []string {
	candidates := make([]string, 0, 2)
	seen := make(map[string]struct{}, 2)

	add := func(value string) {
		ip := strings.TrimSpace(value)
		if ip == "" || !isIPv4(ip) {
			return
		}
		if _, exists := seen[ip]; exists {
			return
		}
		seen[ip] = struct{}{}
		candidates = append(candidates, ip)
	}

	add(link.NeighborMgmtAddr)

	identity := link.NeighborIdentity
	if identity == nil {
		identity = NormalizeTopologyLinkNeighborIdentity(link)
	}

	if identity == nil {
		return candidates
	}

	add(identity.ManagementIP)

	if ip, ok := identityToIP["mac:"+NormalizeMAC(identity.ChassisID)]; ok {
		add(ip)
	}

	if key := normalizeRecursiveNeighborName(identity.SystemName); key != "" {
		if ip, ok := identityToIP["name:"+key]; ok {
			add(ip)
		}
	}

	if key := normalizeRecursiveNeighborName(identity.DeviceID); key != "" {
		if ip, ok := identityToIP["name:"+key]; ok {
			add(ip)
		}
	}

	return candidates
}

func normalizeRecursiveNeighborName(value string) string {
	normalized := strings.TrimSpace(strings.ToLower(value))
	if normalized == "" {
		return ""
	}

	if idx := strings.Index(normalized, "."); idx > 0 {
		return normalized[:idx]
	}

	return normalized
}

// processDevicesForSNMPTargets processes devices for SNMP targets with MAC-based deduplication
func (e *DiscoveryEngine) processDevicesForSNMPTargets(
	job *DiscoveryJob, devices []*DiscoveredDevice,
	allPotentialSNMPTargets map[string]bool, seenMACs map[string]string) {
	for _, device := range devices {
		if device == nil {
			continue
		}

		e.addOrUpdateDeviceToResults(job, device)

		if strings.EqualFold(strings.TrimSpace(device.Metadata["snmp_target_eligible"]), "false") {
			continue
		}

		if device.IP != "" {
			if device.MAC != "" {
				normalizedMAC := NormalizeMAC(device.MAC)
				if primaryIP, seen := seenMACs[normalizedMAC]; !seen {
					seenMACs[normalizedMAC] = device.IP
					allPotentialSNMPTargets[device.IP] = true

					e.logger.Debug().Str("job_id", job.ID).Str("hostname", device.Hostname).
						Str("mac", device.MAC).Str("ip", device.IP).
						Msg("Adding device to SNMP targets")
				} else {
					e.logger.Debug().Str("job_id", job.ID).Str("hostname", device.Hostname).
						Str("mac", device.MAC).Str("primary_ip", primaryIP).
						Str("skipped_ip", device.IP).
						Msg("Device already in SNMP targets, skipping IP")
				}
			} else {
				allPotentialSNMPTargets[device.IP] = true
			}
		}
	}
}
