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

	"strconv"

	"strings"

	"github.com/gosnmp/gosnmp"
)

func (e *DiscoveryEngine) querySNMPL2Neighbors(
	client *gosnmp.GoSNMP, targetIP string, job *DiscoveryJob) ([]*TopologyLink, error) {
	localDeviceID := e.lookupLocalDeviceID(job, targetIP)
	if localDeviceID == "" {
		return nil, ErrNoSNMPDataReturned
	}

	localSubnets := e.localIPv4Subnets(job, targetIP)
	knownNeighborIPs := e.knownDeviceIPv4Set(job)
	knownNeighborsByMAC := e.knownDeviceNeighborByMAC(job)
	bridgeIfByMAC, fdbMacCountByIf, vlanByMAC := e.bridgeIfIndexByMAC(client, targetIP, job)

	// Cache the join inputs so the end-of-topology-stage reconcile pass can
	// replay the cross-device join against the final shared ARP map.
	e.recordObservedJoinContext(job, targetIP, &observedJoinContext{
		localDeviceID:   localDeviceID,
		localSubnets:    localSubnets,
		bridgeIfByMAC:   bridgeIfByMAC,
		vlanByMAC:       vlanByMAC,
		fdbMacCountByIf: fdbMacCountByIf,
	})

	neighbors := make([]arpNeighbor, 0, 32)

	appendNeighborEvidence := func(ip, mac string) {
		if ip == "" || ip == targetIP || !isIPv4(ip) {
			return
		}
		if mac == "" || mac == "00:00:00:00:00:00" {
			return
		}

		norm := NormalizeMAC(mac)
		if norm == "" {
			return
		}

		// Record every valid ARP row into the per-job shared map, including
		// out-of-/24 rows: another walked device's FDB may own the bridge
		// port for this MAC.
		subnetLocal := inSubnetSet(localSubnets, ip)
		e.recordObservedNeighborIPByMAC(job, norm, ip, targetIP, subnetLocal)
		crossSubnet := !subnetLocal
		_, neighborIdentified := knownNeighborsByMAC[norm]
		if bridgeIf, exists := bridgeIfByMAC[norm]; exists && bridgeIf > 0 {
			fdbMacCount := fdbMacCountByIf[bridgeIf]
			neighborKnown := knownNeighborIPs[ip]
			neighbors = append(neighbors, arpNeighbor{
				ifIndex:            bridgeIf,
				ip:                 ip,
				mac:                mac,
				fdbPortMapped:      true,
				fdbMacCount:        fdbMacCount,
				neighborKnown:      neighborKnown,
				neighborIdentified: neighborIdentified,
				crossSubnet:        crossSubnet,
				vlanID:             vlanByMAC[norm],
			})
			return
		}

		neighbors = append(neighbors, arpNeighbor{
			ifIndex:            0,
			ip:                 ip,
			mac:                mac,
			fdbPortMapped:      false,
			fdbMacCount:        0,
			neighborKnown:      knownNeighborIPs[ip],
			neighborIdentified: neighborIdentified,
			crossSubnet:        crossSubnet,
		})
	}

	ipToMediaErr := client.BulkWalk(oidIPToMediaPhys, func(pdu gosnmp.SnmpPDU) error {
		_, ip, ok := parseIPToMediaSuffix(pdu.Name)
		if !ok || ip == "" {
			return nil
		}

		raw, ok := pdu.Value.([]byte)
		if !ok || len(raw) == 0 {
			return nil
		}

		mac := formatMACAddress(raw)
		appendNeighborEvidence(ip, mac)
		return nil
	})

	ipToPhysicalErr := client.BulkWalk(oidIPToPhysicalPhys, func(pdu gosnmp.SnmpPDU) error {
		_, ip, ok := parseIPToPhysicalSuffix(pdu.Name)
		if !ok || ip == "" {
			return nil
		}

		raw, ok := pdu.Value.([]byte)
		if !ok || len(raw) == 0 {
			return nil
		}

		mac := formatMACAddress(raw)
		appendNeighborEvidence(ip, mac)
		return nil
	})

	// Some devices only implement one of these ARP tables.
	// Continue when one walk fails and use whatever evidence is available.
	if ipToMediaErr != nil && ipToPhysicalErr != nil {
		return nil, fmt.Errorf(
			"failed SNMP L2 walks (%s: %w, %s: %w)",
			oidIPToMediaPhys,
			ipToMediaErr,
			oidIPToPhysicalPhys,
			ipToPhysicalErr,
		)
	}

	neighbors = e.selectDensePortNeighbors(neighbors)

	// Bridge-only fallback: correlate known device MACs to bridge FDB entries.
	// This covers L2 switches that lack useful ARP tables for directly connected
	// infrastructure peers (e.g., router/SFP uplinks).
	for normalizedMAC, ifIndex := range bridgeIfByMAC {
		if ifIndex <= 0 {
			continue
		}

		neighbor, ok := knownNeighborsByMAC[normalizedMAC]
		if !ok {
			continue
		}
		if neighbor.deviceID == "" || neighbor.deviceID == localDeviceID {
			continue
		}
		if !isIPv4(neighbor.ip) {
			continue
		}

		mac := strings.TrimSpace(neighbor.mac)
		if mac == "" {
			mac = normalizedMAC
		}

		neighbors = append(neighbors, arpNeighbor{
			ifIndex:            ifIndex,
			ip:                 neighbor.ip,
			mac:                mac,
			fdbPortMapped:      true,
			fdbMacCount:        fdbMacCountByIf[ifIndex],
			neighborKnown:      true,
			neighborIdentified: true,
			crossSubnet:        !inSubnetSet(localSubnets, neighbor.ip),
			vlanID:             vlanByMAC[normalizedMAC],
		})
	}

	neighbors = append(
		neighbors,
		e.observedFDBMappedNeighbors(
			job,
			targetIP,
			localSubnets,
			bridgeIfByMAC,
			vlanByMAC,
			fdbMacCountByIf,
			knownNeighborsByMAC,
			knownNeighborIPs,
		)...,
	)

	links := buildSNMPL2LinksFromNeighbors(localDeviceID, targetIP, job.ID, neighbors)

	if len(links) == 0 {
		return nil, ErrNoLLDPNeighborsFound
	}

	return links, nil
}

const maxSNMPARPCandidateNeighbors = 64

// selectDensePortNeighbors preserves FDB-backed neighbors for publication.
//
// The renderer now clusters endpoint attachments downstream, so clipping dense
// ports here destroys real endpoint evidence before it reaches storage.
func (e *DiscoveryEngine) selectDensePortNeighbors(neighbors []arpNeighbor) []arpNeighbor {
	return neighbors
}

func buildSNMPL2LinksFromNeighbors(
	localDeviceID, targetIP, discoveryID string, neighbors []arpNeighbor) []*TopologyLink {
	links := make([]*TopologyLink, 0, len(neighbors))
	seen := make(map[string]struct{}, len(neighbors))
	arpCandidateCount := 0

	// Fill the ARP-only candidate cap with same-subnet neighbors first so
	// cross-subnet rows never displace the pre-change candidate population
	// (recursion seeds from these candidates). Relative order within each
	// partition is preserved; FDB-mapped neighbors are unaffected by the cap.
	ordered := neighbors
	for _, n := range neighbors {
		if !n.fdbPortMapped && n.crossSubnet {
			ordered = make([]arpNeighbor, 0, len(neighbors))
			deferred := make([]arpNeighbor, 0)
			for _, candidate := range neighbors {
				if !candidate.fdbPortMapped && candidate.crossSubnet {
					deferred = append(deferred, candidate)
					continue
				}
				ordered = append(ordered, candidate)
			}
			ordered = append(ordered, deferred...)
			break
		}
	}

	for _, n := range ordered {
		if n.ip == "" {
			continue
		}

		// Do not convert an IP-only match for an already-known device into a
		// topology edge. Managed peers need stronger identity than "we saw this
		// IP in ARP and a MAC on some bridge port", otherwise a single host can
		// appear attached to multiple unrelated devices. Cross-device
		// ARP-observed joins are exempt: their IPs enter the recursive scan
		// queue (making them "known") without ever gaining a registered
		// identity, so the veto would wrongly drop every recursively-reached
		// switch's endpoints.
		if n.fdbPortMapped && n.neighborKnown && !n.neighborIdentified && !n.observedJoin {
			continue
		}

		key := fmt.Sprintf("%s|%d|%s|%t", n.ip, n.ifIndex, NormalizeMAC(n.mac), n.fdbPortMapped)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}

		if !n.fdbPortMapped {
			if arpCandidateCount >= maxSNMPARPCandidateNeighbors {
				continue
			}

			arpCandidateCount++
			links = append(links, &TopologyLink{
				Protocol:          "SNMP-L2",
				LocalDeviceIP:     targetIP,
				LocalDeviceID:     localDeviceID,
				LocalIfIndex:      0,
				NeighborChassisID: n.mac,
				NeighborMgmtAddr:  n.ip,
				Metadata: map[string]string{
					"protocol":          "SNMP-L2",
					"discovery_id":      discoveryID,
					"source":            "snmp-arp-only",
					"evidence":          "ipNetToMedia",
					"fdb_port_mapped":   "false",
					"evidence_class":    evidenceClassObservedOnly,
					"relation_family":   "OBSERVED_TO",
					"confidence_tier":   confidenceTierLow,
					"confidence_reason": "single_identifier_inference",
					// Keep ARP-only observations marked for recursive target expansion.
					// candidate_only links stay in the in-memory job results to seed
					// the recursive pass but are dropped before publish/export.
					"candidate_only": "true",
				},
			})
			continue
		}

		if n.ifIndex <= 0 {
			continue
		}

		confidenceReason := "arp_fdb_port_mapping"
		switch {
		case n.observedJoin:
			confidenceReason = "cross_device_arp_fdb_join"
		case n.crossSubnet:
			confidenceReason = "cross_subnet_arp_fdb_port_mapping"
		}

		metadata := map[string]string{
			"protocol":          "SNMP-L2",
			"discovery_id":      discoveryID,
			"source":            "snmp-arp-fdb",
			"evidence":          "ipNetToMedia+dot1dTpFdb",
			"fdb_port_mapped":   "true",
			"evidence_class":    evidenceClassInferredSegment,
			"relation_family":   "ATTACHED_TO",
			"confidence_tier":   confidenceTierMedium,
			"confidence_reason": confidenceReason,
		}
		if n.vlanID > 0 {
			metadata["vlan_id"] = strconv.Itoa(int(n.vlanID))
		}

		links = append(links, &TopologyLink{
			Protocol:          "SNMP-L2",
			LocalDeviceIP:     targetIP,
			LocalDeviceID:     localDeviceID,
			LocalIfIndex:      n.ifIndex,
			NeighborChassisID: n.mac,
			NeighborMgmtAddr:  n.ip,
			Metadata:          metadata,
		})
	}

	return links
}
