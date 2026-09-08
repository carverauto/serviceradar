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
	"github.com/gosnmp/gosnmp"
)

// handleInterfaceDiscoverySNMP queries and publishes interface information
func (e *DiscoveryEngine) handleInterfaceDiscoverySNMP(
	job *DiscoveryJob, client *gosnmp.GoSNMP, target string,
) {
	interfaces, err := e.queryInterfaces(job, client, target, job.ID)
	if err != nil {
		e.logger.Error().Str("job_id", job.ID).Str("target", target).Err(err).
			Msg("Failed to query interfaces")

		return
	}

	if len(interfaces) == 0 {
		return
	}

	job.mu.RLock()
	var deviceID string
	for _, device := range job.Results.Devices {
		if device.IP == target {
			deviceID = device.DeviceID
			break
		}
	}
	job.mu.RUnlock()

	job.mu.Lock()
	if deviceEntry, exists := job.deviceMap[deviceID]; exists {
		for _, iface := range interfaces {
			deviceEntry.IPs[iface.DeviceIP] = struct{}{}
			if iface.IfPhysAddress != "" {
				deviceEntry.MACs[iface.IfPhysAddress] = struct{}{}
			}
		}
	}
	job.mu.Unlock()

	for _, iface := range interfaces {
		if iface.DeviceID == "" && deviceID != "" {
			iface.DeviceID = deviceID
		}
		if iface.DeviceIP == "" {
			iface.DeviceIP = target
		}
		e.upsertInterface(job, iface)
	}
}

// handleTopologyDiscoverySNMP queries and publishes topology information (LLDP or CDP)
func (e *DiscoveryEngine) handleTopologyDiscoverySNMP(
	job *DiscoveryJob, client *gosnmp.GoSNMP, targetIP string) {
	// Try LLDP first
	lldpLinks, lldpErr := e.queryLLDP(client, targetIP, job)
	// Try CDP as additional evidence (some neighbors only advertise CDP).
	cdpLinks, cdpErr := e.queryCDP(client, targetIP, job)
	// Also run ARP+FDB enrichment even when LLDP/CDP succeeds.
	// This captures neighbors that do not expose LLDP/CDP (e.g. some AP/uplink edges).
	l2Links, l2Err := e.querySNMPL2Neighbors(client, targetIP, job)
	e.publishTopologyEvidence(job, targetIP, lldpLinks, lldpErr, cdpLinks, cdpErr, l2Links, l2Err)
}

func (e *DiscoveryEngine) publishTopologyEvidence(
	job *DiscoveryJob,
	targetIP string,
	lldpLinks []*TopologyLink,
	lldpErr error,
	cdpLinks []*TopologyLink,
	cdpErr error,
	l2Links []*TopologyLink,
	l2Err error,
) {
	publishedAny := false

	if lldpErr == nil && len(lldpLinks) > 0 {
		e.publishTopologyLinks(job, lldpLinks, targetIP, "LLDP")
		publishedAny = true
	} else {
		e.logger.Debug().Str("job_id", job.ID).Str("target_ip", targetIP).Err(lldpErr).
			Msg("LLDP not supported or no neighbors")
	}

	if cdpErr == nil && len(cdpLinks) > 0 {
		e.publishTopologyLinks(job, cdpLinks, targetIP, "CDP")
		publishedAny = true
	} else {
		e.logger.Debug().Str("job_id", job.ID).Str("target_ip", targetIP).Err(cdpErr).
			Msg("CDP not supported or no neighbors")
	}

	if l2Err == nil && len(l2Links) > 0 {
		e.publishTopologyLinks(job, l2Links, targetIP, "SNMP-L2")
		publishedAny = true
	} else {
		e.logger.Debug().Str("job_id", job.ID).Str("target_ip", targetIP).Err(l2Err).
			Msg("SNMP L2 enrichment returned no neighbors")
	}

	if !publishedAny {
		e.logger.Debug().Str("job_id", job.ID).Str("target_ip", targetIP).
			Msg("No topology neighbors discovered via LLDP/CDP/SNMP-L2")
	}
}
