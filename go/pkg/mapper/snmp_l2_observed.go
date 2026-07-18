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
)

const (
	// maxObservedJoinPortMACs bounds the observed-join fan-out per FDB port:
	// trunk/uplink ports hold many MACs and are not endpoint attachment
	// points. The direct same-device ARP+FDB path is NOT affected by this
	// bound.
	maxObservedJoinPortMACs = 8

	// maxObservedJoinIPsPerMAC bounds the observed-join fan-out per MAC: a
	// MAC mapping to many IPs is a shared/virtual/proxy-ARP MAC, not an
	// endpoint.
	maxObservedJoinIPsPerMAC = 4
)

type arpNeighbor struct {
	ifIndex            int32
	ip                 string
	mac                string
	fdbPortMapped      bool
	fdbMacCount        int
	neighborKnown      bool
	neighborIdentified bool
	crossSubnet        bool  // resolved IP is outside the observing device's own /24s
	observedJoin       bool  // produced by the cross-device shared-map FDB join
	vlanID             int32 // best-effort VLAN association from the FDB walk; 0 = unknown
}

type knownMACNeighbor struct {
	deviceID string
	ip       string
	mac      string
}

// observedNeighborIPState carries per-mapping provenance in the shared per-job
// MAC→IP map. subnetLocal is sticky-true: it records whether ANY observing
// device owned the IP's /24, so consumers can prefer mappings reported by the
// L3 owner of the endpoint's subnet over remote ARP hearsay. observers records
// the set of target IPs whose ARP walks reported the mapping, so the FDB join
// can require genuinely cross-device evidence.
type observedNeighborIPState struct {
	subnetLocal bool
	observers   map[string]struct{}
}

// observedNeighborIPRecord is the sorted snapshot form of one MAC→IP mapping.
type observedNeighborIPRecord struct {
	ip          string
	subnetLocal bool
	observers   []string
}

// observedByOtherDevice reports whether any device other than targetIP
// observed the mapping. The target's own ARP rows already flow through the
// direct ARP+FDB path (and its known-IP veto), so a self-observed-only mapping
// must never resurface as a cross-device join.
func observedByOtherDevice(record observedNeighborIPRecord, targetIP string) bool {
	for _, observer := range record.observers {
		if observer != targetIP {
			return true
		}
	}

	return false
}

func (e *DiscoveryEngine) recordObservedNeighborIPByMAC(job *DiscoveryJob, mac, ip, observerIP string, subnetLocal bool) {
	if job == nil {
		return
	}

	normalizedMAC := NormalizeMAC(mac)
	ip = strings.TrimSpace(ip)
	if normalizedMAC == "" || !isIPv4(ip) {
		return
	}

	job.mu.Lock()
	defer job.mu.Unlock()

	if job.observedNeighborIPsByMAC == nil {
		job.observedNeighborIPsByMAC = make(map[string]map[string]observedNeighborIPState)
	}

	observedIPs := job.observedNeighborIPsByMAC[normalizedMAC]
	if observedIPs == nil {
		observedIPs = make(map[string]observedNeighborIPState)
		job.observedNeighborIPsByMAC[normalizedMAC] = observedIPs
	}

	state := observedIPs[ip]
	state.subnetLocal = state.subnetLocal || subnetLocal
	if observer := strings.TrimSpace(observerIP); observer != "" {
		if state.observers == nil {
			state.observers = make(map[string]struct{})
		}
		state.observers[observer] = struct{}{}
	}
	observedIPs[ip] = state
}

func (e *DiscoveryEngine) observedNeighborIPsByMAC(job *DiscoveryJob) map[string][]observedNeighborIPRecord {
	if job == nil {
		return map[string][]observedNeighborIPRecord{}
	}

	job.mu.RLock()
	defer job.mu.RUnlock()

	if len(job.observedNeighborIPsByMAC) == 0 {
		return map[string][]observedNeighborIPRecord{}
	}

	copied := make(map[string][]observedNeighborIPRecord, len(job.observedNeighborIPsByMAC))
	for mac, observedIPs := range job.observedNeighborIPsByMAC {
		records := make([]observedNeighborIPRecord, 0, len(observedIPs))
		for ip, state := range observedIPs {
			observers := make([]string, 0, len(state.observers))
			for observer := range state.observers {
				observers = append(observers, observer)
			}
			sort.Strings(observers)
			records = append(records, observedNeighborIPRecord{
				ip:          ip,
				subnetLocal: state.subnetLocal,
				observers:   observers,
			})
		}
		sort.Slice(records, func(i, j int) bool { return records[i].ip < records[j].ip })
		copied[mac] = records
	}

	return copied
}

func (e *DiscoveryEngine) observedFDBMappedNeighbors(
	job *DiscoveryJob,
	targetIP string,
	localSubnets map[string]struct{},
	bridgeIfByMAC map[string]int32,
	vlanByMAC map[string]int32,
	fdbMacCountByIf map[int32]int,
	knownNeighborsByMAC map[string]knownMACNeighbor,
	knownNeighborIPs map[string]bool,
) []arpNeighbor {
	observedIPsByMAC := e.observedNeighborIPsByMAC(job)
	if len(observedIPsByMAC) == 0 || len(bridgeIfByMAC) == 0 {
		return nil
	}

	macs := make([]string, 0, len(bridgeIfByMAC))
	for normalizedMAC := range bridgeIfByMAC {
		macs = append(macs, normalizedMAC)
	}
	sort.Strings(macs)

	neighbors := make([]arpNeighbor, 0, len(macs))
	for _, normalizedMAC := range macs {
		if _, exists := knownNeighborsByMAC[normalizedMAC]; exists {
			continue
		}

		ifIndex := bridgeIfByMAC[normalizedMAC]
		if ifIndex <= 0 {
			continue
		}

		// Ports holding many MACs are trunk/uplink ports, not endpoint
		// attachment points; skip the observed join there entirely. The
		// direct same-device ARP+FDB path is not bounded by this.
		if fdbMacCountByIf[ifIndex] > maxObservedJoinPortMACs {
			continue
		}

		observedIPs := observedIPsByMAC[normalizedMAC]

		// Prefer mappings recorded by a device that owned the IP's /24 (the
		// L3 owner of the endpoint's subnet); fall back to non-local mappings
		// only when no subnet-local observation exists. This bounds
		// cross-device ARP mis-joins when observers disagree.
		hasSubnetLocal := false
		for _, observed := range observedIPs {
			if observed.subnetLocal {
				hasSubnetLocal = true
				break
			}
		}

		candidates := make([]observedNeighborIPRecord, 0, len(observedIPs))
		for _, observed := range observedIPs {
			if hasSubnetLocal && !observed.subnetLocal {
				continue
			}

			if observed.ip == targetIP || !isIPv4(observed.ip) {
				continue
			}

			// Only genuinely cross-device mappings may join: the target's
			// own ARP rows already produced direct ARP+FDB neighbors.
			if !observedByOtherDevice(observed, targetIP) {
				continue
			}

			candidates = append(candidates, observed)
		}

		// A MAC that still maps to many IPs after the preference filter is a
		// shared/virtual/proxy-ARP MAC, not an endpoint; skip it entirely.
		if len(candidates) > maxObservedJoinIPsPerMAC {
			continue
		}

		for _, observed := range candidates {
			observedIP := observed.ip
			neighbors = append(neighbors, arpNeighbor{
				ifIndex:            ifIndex,
				ip:                 observedIP,
				mac:                normalizedMAC,
				fdbPortMapped:      true,
				fdbMacCount:        fdbMacCountByIf[ifIndex],
				neighborKnown:      knownNeighborIPs[observedIP],
				neighborIdentified: false,
				crossSubnet:        !inSubnetSet(localSubnets, observedIP),
				observedJoin:       true,
				vlanID:             vlanByMAC[normalizedMAC],
			})
		}
	}

	return neighbors
}

// observedJoinContext caches the per-target inputs of the observed FDB join so
// the end-of-topology-stage reconcile pass can re-run the join against the
// FINAL shared ARP map without any SNMP I/O.
type observedJoinContext struct {
	localDeviceID   string
	localSubnets    map[string]struct{}
	bridgeIfByMAC   map[string]int32
	vlanByMAC       map[string]int32
	fdbMacCountByIf map[int32]int
}

func (e *DiscoveryEngine) recordObservedJoinContext(job *DiscoveryJob, targetIP string, joinCtx *observedJoinContext) {
	if job == nil || targetIP == "" || joinCtx == nil {
		return
	}

	job.mu.Lock()
	defer job.mu.Unlock()

	if job.observedJoinContexts == nil {
		job.observedJoinContexts = make(map[string]*observedJoinContext)
	}
	job.observedJoinContexts[targetIP] = joinCtx
}

// reconcileTopologyLinkKey identifies a link for the reconcile-pass dedupe.
func reconcileTopologyLinkKey(link *TopologyLink) string {
	return fmt.Sprintf("%s|%s|%d|%s|%s",
		link.Protocol,
		link.LocalDeviceID,
		link.LocalIfIndex,
		NormalizeMAC(link.NeighborChassisID),
		link.NeighborMgmtAddr,
	)
}

// reconcileObservedFDBJoins re-runs the cross-device observed FDB join for
// every walked topology target after the LAST topology pass. The per-target
// join runs once at the target's own walk, so an FDB owner walked before the
// ARP owner never saw the mapping; this pass replays the join against the
// final shared map and publishes only links not already present in the job
// results. No SNMP I/O happens here.
func (e *DiscoveryEngine) reconcileObservedFDBJoins(job *DiscoveryJob) {
	if job == nil {
		return
	}

	job.mu.RLock()
	targets := make([]string, 0, len(job.observedJoinContexts))
	for targetIP := range job.observedJoinContexts {
		targets = append(targets, targetIP)
	}
	existing := make(map[string]struct{})
	if job.Results != nil {
		for _, link := range job.Results.TopologyLinks {
			existing[reconcileTopologyLinkKey(link)] = struct{}{}
		}
	}
	job.mu.RUnlock()

	if len(targets) == 0 {
		return
	}
	sort.Strings(targets)

	// The device set no longer changes at this point in the job, so one
	// rebuild reflects the final state for every target.
	knownNeighborIPs := e.knownDeviceIPv4Set(job)
	knownNeighborsByMAC := e.knownDeviceNeighborByMAC(job)

	for _, targetIP := range targets {
		job.mu.RLock()
		joinCtx := job.observedJoinContexts[targetIP]
		job.mu.RUnlock()
		if joinCtx == nil || joinCtx.localDeviceID == "" {
			continue
		}

		neighbors := e.observedFDBMappedNeighbors(
			job,
			targetIP,
			joinCtx.localSubnets,
			joinCtx.bridgeIfByMAC,
			joinCtx.vlanByMAC,
			joinCtx.fdbMacCountByIf,
			knownNeighborsByMAC,
			knownNeighborIPs,
		)
		if len(neighbors) == 0 {
			continue
		}

		links := buildSNMPL2LinksFromNeighbors(joinCtx.localDeviceID, targetIP, job.ID, neighbors)

		newLinks := make([]*TopologyLink, 0, len(links))
		for _, link := range links {
			key := reconcileTopologyLinkKey(link)
			if _, seen := existing[key]; seen {
				continue
			}
			existing[key] = struct{}{}
			newLinks = append(newLinks, link)
		}

		if len(newLinks) > 0 {
			e.publishTopologyLinks(job, newLinks, targetIP, "SNMP-L2")
		}
	}
}
