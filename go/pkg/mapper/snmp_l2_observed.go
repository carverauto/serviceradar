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
	"sort"

	"strings"
)

type arpNeighbor struct {
	ifIndex            int32
	ip                 string
	mac                string
	fdbPortMapped      bool
	fdbMacCount        int
	neighborKnown      bool
	neighborIdentified bool
}

type knownMACNeighbor struct {
	deviceID string
	ip       string
	mac      string
}

func (e *DiscoveryEngine) recordObservedNeighborIPByMAC(job *DiscoveryJob, mac, ip string) {
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
		job.observedNeighborIPsByMAC = make(map[string]map[string]struct{})
	}

	observedIPs := job.observedNeighborIPsByMAC[normalizedMAC]
	if observedIPs == nil {
		observedIPs = make(map[string]struct{})
		job.observedNeighborIPsByMAC[normalizedMAC] = observedIPs
	}

	observedIPs[ip] = struct{}{}
}

func (e *DiscoveryEngine) observedNeighborIPsByMAC(job *DiscoveryJob) map[string][]string {
	if job == nil {
		return map[string][]string{}
	}

	job.mu.RLock()
	defer job.mu.RUnlock()

	if len(job.observedNeighborIPsByMAC) == 0 {
		return map[string][]string{}
	}

	copied := make(map[string][]string, len(job.observedNeighborIPsByMAC))
	for mac, observedIPs := range job.observedNeighborIPsByMAC {
		ips := make([]string, 0, len(observedIPs))
		for ip := range observedIPs {
			ips = append(ips, ip)
		}
		sort.Strings(ips)
		copied[mac] = ips
	}

	return copied
}

func (e *DiscoveryEngine) observedFDBMappedNeighbors(
	job *DiscoveryJob,
	targetIP string,
	localSubnets map[string]struct{},
	bridgeIfByMAC map[string]int32,
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

		for _, observedIP := range observedIPsByMAC[normalizedMAC] {
			if observedIP == targetIP || !isIPv4(observedIP) || !inSubnetSet(localSubnets, observedIP) {
				continue
			}

			neighbors = append(neighbors, arpNeighbor{
				ifIndex:            ifIndex,
				ip:                 observedIP,
				mac:                normalizedMAC,
				fdbPortMapped:      true,
				fdbMacCount:        fdbMacCountByIf[ifIndex],
				neighborKnown:      knownNeighborIPs[observedIP],
				neighborIdentified: false,
			})
		}
	}

	return neighbors
}
