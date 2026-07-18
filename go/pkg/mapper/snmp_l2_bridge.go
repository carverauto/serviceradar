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

	"math"

	"sort"

	"strconv"

	"strings"

	"time"

	"github.com/gosnmp/gosnmp"
)

// fdbEntry is one parsed forwarding-database row, normalized across the
// dot1d, dot1q, and per-VLAN community walks.
type fdbEntry struct {
	mac        string
	bridgePort int32
	vlanID     int32 // best-effort VLAN association; 0 = unknown
	ifIndex    int32 // pre-resolved ifIndex (>0) from a VLAN-context base-port map; 0 = resolve via the shared map
}

const (
	// maxVLANCommunityWalks bounds the per-VLAN community sweep so it fits the
	// discovery handler timeout budget.
	maxVLANCommunityWalks = 24

	// vlanCommunityWalkTimeout keeps each VLAN context short. Never inherit
	// the parent client's timeout: at its 30s default a handful of dead VLAN
	// contexts would blow the 30s discovery handler cap on their own.
	vlanCommunityWalkTimeout = 2 * time.Second

	// maxVLANCommunitySweepDuration bounds the aggregate sweep across all
	// VLAN contexts, independent of how slow each context is.
	maxVLANCommunitySweepDuration = 10 * time.Second
)

func (e *DiscoveryEngine) bridgeIfIndexByMAC(
	client *gosnmp.GoSNMP, targetIP string, job *DiscoveryJob,
) (map[string]int32, map[int32]int, map[string]int32) {
	bridgePortToIfIndex := e.collectBridgePortIfIndexMap(client)

	entries := e.dot1dFDBEntriesFromPDUs(collectFDBPDUs(client, oidDot1dTpFdbPort))
	entries = append(entries, e.dot1qFDBEntriesFromPDUs(collectFDBPDUs(client, oidDot1qTpFdbPort))...)

	if creds := effectiveSNMPCredentialsForTarget(job, targetIP); vlanCommunityWalkEnabled(creds) {
		entries = append(entries, e.perVLANCommunityFDBEntries(client, targetIP, creds)...)
	}

	return e.bridgeIfIndexByMACFromFDBEntries(bridgePortToIfIndex, entries)
}

func (e *DiscoveryEngine) collectBridgePortIfIndexMap(client *gosnmp.GoSNMP) map[int32]int32 {
	bridgePortToIfIndex := make(map[int32]int32)
	_ = client.BulkWalk(oidDot1dBasePortIfIndex, func(pdu gosnmp.SnmpPDU) error {
		baseParts := strings.Split(strings.TrimPrefix(oidDot1dBasePortIfIndex, "."), ".")
		parts := strings.Split(strings.TrimPrefix(pdu.Name, "."), ".")
		if len(parts) < len(baseParts)+1 {
			return nil
		}

		bridgePort, convErr := strconv.Atoi(parts[len(baseParts)])
		if convErr != nil || bridgePort < 0 || bridgePort > math.MaxInt32 {
			return nil
		}

		val, ok := e.getInt32FromPDU(pdu, "dot1dBasePortIfIndex")
		if ok && val > 0 {
			bridgePortToIfIndex[int32(bridgePort)] = val //nolint:gosec // G115: bounds checked above
		}
		return nil
	})

	return bridgePortToIfIndex
}

func collectFDBPDUs(client *gosnmp.GoSNMP, rootOID string) []gosnmp.SnmpPDU {
	pdus := make([]gosnmp.SnmpPDU, 0)
	_ = client.BulkWalk(rootOID, func(pdu gosnmp.SnmpPDU) error {
		pdus = append(pdus, pdu)
		return nil
	})

	return pdus
}

func (e *DiscoveryEngine) dot1dFDBEntriesFromPDUs(fdbPDUs []gosnmp.SnmpPDU) []fdbEntry {
	entries := make([]fdbEntry, 0, len(fdbPDUs))
	for _, pdu := range fdbPDUs {
		bridgePort, ok := e.getInt32FromPDU(pdu, "dot1dTpFdbPort")
		if !ok || bridgePort <= 0 {
			continue
		}

		mac, ok := macFromFDBOID(pdu.Name)
		if !ok || mac == "" {
			continue
		}

		entries = append(entries, fdbEntry{mac: mac, bridgePort: bridgePort})
	}

	return entries
}

func (e *DiscoveryEngine) dot1qFDBEntriesFromPDUs(fdbPDUs []gosnmp.SnmpPDU) []fdbEntry {
	entries := make([]fdbEntry, 0, len(fdbPDUs))
	for _, pdu := range fdbPDUs {
		bridgePort, ok := e.getInt32FromPDU(pdu, "dot1qTpFdbPort")
		if !ok || bridgePort <= 0 {
			continue
		}

		mac, fdbID, ok := macFromDot1qFDBOID(pdu.Name)
		if !ok || mac == "" {
			continue
		}

		entries = append(entries, fdbEntry{mac: mac, bridgePort: bridgePort, vlanID: fdbID})
	}

	return entries
}

// bridgeIfIndexByMACFromFDBPDUs is the legacy dot1d-only adapter over the
// merged entry reducer.
func (e *DiscoveryEngine) bridgeIfIndexByMACFromFDBPDUs(
	bridgePortToIfIndex map[int32]int32,
	fdbPDUs []gosnmp.SnmpPDU,
) (map[string]int32, map[int32]int) {
	result, fdbMacCountByIf, _ := e.bridgeIfIndexByMACFromFDBEntries(
		bridgePortToIfIndex, e.dot1dFDBEntriesFromPDUs(fdbPDUs))
	return result, fdbMacCountByIf
}

func (e *DiscoveryEngine) bridgeIfIndexByMACFromFDBEntries(
	bridgePortToIfIndex map[int32]int32,
	entries []fdbEntry,
) (map[string]int32, map[int32]int, map[string]int32) {
	hasExplicitBridgePortMap := len(bridgePortToIfIndex) > 0
	result := make(map[string]int32)
	vlanByMAC := make(map[string]int32)
	ambiguousMACs := make(map[string]struct{})
	fdbMacCountByIf := make(map[int32]int)
	seenByIfMAC := make(map[string]struct{})

	for _, entry := range entries {
		ifIndex := entry.ifIndex
		if ifIndex <= 0 {
			if entry.bridgePort <= 0 {
				continue
			}

			mapped, exists := bridgePortToIfIndex[entry.bridgePort]
			if !exists || mapped <= 0 {
				// Some switches expose FDB ports but not dot1dBasePortIfIndex.
				// On those agents, bridge port IDs are typically aligned with ifIndex.
				// Use that as a fallback so FDB evidence can still drive topology attribution.
				if hasExplicitBridgePortMap {
					continue
				}
				mapped = entry.bridgePort
			}
			ifIndex = mapped
		}

		normalized := NormalizeMAC(entry.mac)
		if normalized == "" {
			continue
		}

		seenKey := fmt.Sprintf("%d|%s", ifIndex, normalized)
		if _, exists := seenByIfMAC[seenKey]; !exists {
			seenByIfMAC[seenKey] = struct{}{}
			fdbMacCountByIf[ifIndex]++
		}

		if _, ambiguous := ambiguousMACs[normalized]; ambiguous {
			continue
		}

		if previousIfIndex, exists := result[normalized]; exists && previousIfIndex != ifIndex {
			delete(result, normalized)
			delete(vlanByMAC, normalized)
			ambiguousMACs[normalized] = struct{}{}
			continue
		}

		result[normalized] = ifIndex
		if entry.vlanID > 0 {
			if _, exists := vlanByMAC[normalized]; !exists {
				vlanByMAC[normalized] = entry.vlanID
			}
		}
	}

	return result, fdbMacCountByIf, vlanByMAC
}

// effectiveSNMPCredentialsForTarget resolves the job credential set the same
// way createSNMPClient does: a TargetSpecific entry fully replaces the base.
func effectiveSNMPCredentialsForTarget(job *DiscoveryJob, targetIP string) *SNMPCredentials {
	if job == nil || job.Params == nil || job.Params.Credentials == nil {
		return nil
	}

	creds := job.Params.Credentials
	if targetCreds, ok := creds.TargetSpecific[targetIP]; ok && targetCreds != nil {
		return targetCreds
	}

	return creds
}

// vlanCommunityWalkEnabled gates the per-VLAN community sweep: it only makes
// sense for v1/v2c community credentials that explicitly opted in.
func vlanCommunityWalkEnabled(creds *SNMPCredentials) bool {
	if creds == nil || !creds.VLANCommunityIndexing {
		return false
	}
	if creds.Version != SNMPVersion1 && creds.Version != SNMPVersion2c {
		return false
	}

	return strings.TrimSpace(creds.Community) != ""
}

func (e *DiscoveryEngine) enumerateBridgeVLANIDs(client *gosnmp.GoSNMP) []int32 {
	vlanIDSet := make(map[int32]struct{})

	_ = client.BulkWalk(oidDot1qPvid, func(pdu gosnmp.SnmpPDU) error {
		if pvid, ok := e.getInt32FromPDU(pdu, "dot1qPvid"); ok && pvid > 0 {
			vlanIDSet[pvid] = struct{}{}
		}
		return nil
	})
	_ = client.BulkWalk(oidDot1qVlanStaticEgress, func(pdu gosnmp.SnmpPDU) error {
		if vlanID, ok := parseVLANIDFromOID(pdu.Name); ok && vlanID > 0 {
			vlanIDSet[vlanID] = struct{}{}
		}
		return nil
	})

	vlanIDs := make([]int32, 0, len(vlanIDSet))
	for vlanID := range vlanIDSet {
		vlanIDs = append(vlanIDs, vlanID)
	}
	sort.Slice(vlanIDs, func(i, j int) bool { return vlanIDs[i] < vlanIDs[j] })

	if len(vlanIDs) > maxVLANCommunityWalks {
		e.logger.Debug().Int("vlan_count", len(vlanIDs)).Int("cap", maxVLANCommunityWalks).
			Msg("Capping per-VLAN community FDB walks")
		vlanIDs = vlanIDs[:maxVLANCommunityWalks]
	}

	return vlanIDs
}

// perVLANCommunityFDBEntries walks the dot1d bridge tables once per VLAN using
// indexed communities (community@vlan). Per-VLAN failures are skipped at debug
// level so a missing VLAN context never fails the whole FDB walk.
func (e *DiscoveryEngine) perVLANCommunityFDBEntries(
	client *gosnmp.GoSNMP, targetIP string, creds *SNMPCredentials,
) []fdbEntry {
	vlanIDs := e.enumerateBridgeVLANIDs(client)
	if len(vlanIDs) == 0 {
		return nil
	}

	return e.sweepVLANCommunityFDBEntries(targetIP, creds, vlanIDs, e.walkVLANCommunityFDBContext, time.Now)
}

// sweepVLANCommunityFDBEntries runs the per-VLAN walks under an aggregate time
// budget: once maxVLANCommunitySweepDuration has elapsed the remaining VLAN
// contexts are skipped so the sweep can never blow the discovery handler cap.
func (e *DiscoveryEngine) sweepVLANCommunityFDBEntries(
	targetIP string,
	creds *SNMPCredentials,
	vlanIDs []int32,
	walkVLAN func(targetIP string, creds *SNMPCredentials, vlanID int32) []fdbEntry,
	now func() time.Time,
) []fdbEntry {
	entries := make([]fdbEntry, 0)
	sweepStart := now()

	for i, vlanID := range vlanIDs {
		if elapsed := now().Sub(sweepStart); elapsed > maxVLANCommunitySweepDuration {
			e.logger.Debug().Str("target_ip", targetIP).
				Int("vlans_skipped", len(vlanIDs)-i).Dur("elapsed", elapsed).
				Msg("Stopping per-VLAN community FDB sweep: aggregate budget exceeded")
			break
		}

		entries = append(entries, walkVLAN(targetIP, creds, vlanID)...)
	}

	return entries
}

func (e *DiscoveryEngine) walkVLANCommunityFDBContext(
	targetIP string, creds *SNMPCredentials, vlanID int32,
) []fdbEntry {
	credsCopy := *creds
	credsCopy.Community = fmt.Sprintf("%s@%d", creds.Community, vlanID)
	credsCopy.TargetSpecific = nil

	vlanClient, err := e.createSNMPClient(targetIP, &credsCopy)
	if err != nil {
		e.logger.Debug().Str("target_ip", targetIP).Int("vlan_id", int(vlanID)).Err(err).
			Msg("Skipping per-VLAN community FDB walk: client setup failed")
		return nil
	}

	// Keep each VLAN context short so the full sweep fits the discovery
	// handler timeout budget.
	vlanClient.Timeout = vlanCommunityWalkTimeout
	vlanClient.Retries = 0

	if connErr := vlanClient.Connect(); connErr != nil {
		e.logger.Debug().Str("target_ip", targetIP).Int("vlan_id", int(vlanID)).Err(connErr).
			Msg("Skipping per-VLAN community FDB walk: connect failed")
		return nil
	}

	vlanBridgePorts := e.collectBridgePortIfIndexMap(vlanClient)
	vlanPDUs := collectFDBPDUs(vlanClient, oidDot1dTpFdbPort)
	if vlanClient.Conn != nil {
		_ = vlanClient.Conn.Close()
	}

	return resolveVLANContextFDBEntries(e.dot1dFDBEntriesFromPDUs(vlanPDUs), vlanBridgePorts, vlanID)
}

// resolveVLANContextFDBEntries resolves per-VLAN FDB entries strictly against
// that VLAN context's own base-port map. Entries whose bridge port is absent
// from the context-local map (or when the context yielded no map at all) are
// DROPPED rather than left for the reducer's global-map fallback:
// context-local bridge-port numbering differs from the global context on the
// platforms this walk targets, so a global-map resolution would attach MACs to
// the wrong port and poison the ambiguity blacklist.
func resolveVLANContextFDBEntries(entries []fdbEntry, vlanBridgePorts map[int32]int32, vlanID int32) []fdbEntry {
	resolved := make([]fdbEntry, 0, len(entries))
	for _, entry := range entries {
		ifIndex, ok := vlanBridgePorts[entry.bridgePort]
		if !ok || ifIndex <= 0 {
			continue
		}

		entry.vlanID = vlanID
		entry.ifIndex = ifIndex
		resolved = append(resolved, entry)
	}

	return resolved
}

func (e *DiscoveryEngine) knownDeviceIPv4Set(job *DiscoveryJob) map[string]bool {
	known := make(map[string]bool)
	if job == nil || job.Results == nil {
		return known
	}

	job.mu.RLock()
	defer job.mu.RUnlock()

	for _, device := range job.Results.Devices {
		if device == nil {
			continue
		}

		if ip := strings.TrimSpace(device.IP); isIPv4(ip) {
			known[ip] = true
		}

		for k := range device.Metadata {
			if strings.HasPrefix(k, "alt_ip:") {
				ip := strings.TrimPrefix(k, "alt_ip:")
				if isIPv4(ip) {
					known[ip] = true
				}
			}
			if strings.HasPrefix(k, "ip_alias:") {
				ip := strings.TrimPrefix(k, "ip_alias:")
				if isIPv4(ip) {
					known[ip] = true
				}
			}
		}
	}

	for _, ip := range job.scanQueue {
		if isIPv4(ip) {
			known[ip] = true
		}
	}

	return known
}

func (e *DiscoveryEngine) knownDeviceNeighborByMAC(job *DiscoveryJob) map[string]knownMACNeighbor {
	known := make(map[string]knownMACNeighbor)
	if job == nil || job.Results == nil {
		return known
	}

	job.mu.RLock()
	defer job.mu.RUnlock()

	for _, device := range job.Results.Devices {
		if device == nil {
			continue
		}

		deviceID := strings.TrimSpace(device.DeviceID)
		ip := strings.TrimSpace(device.IP)
		if deviceID == "" || !isIPv4(ip) {
			continue
		}

		register := func(rawMAC string) {
			norm := NormalizeMAC(rawMAC)
			if norm == "" {
				return
			}
			if _, exists := known[norm]; exists {
				return
			}
			known[norm] = knownMACNeighbor{
				deviceID: deviceID,
				ip:       ip,
				mac:      strings.TrimSpace(rawMAC),
			}
		}

		register(device.MAC)
		register(device.BridgeBaseMAC)
		for key := range device.Metadata {
			if strings.HasPrefix(key, "alt_mac:") {
				register(strings.TrimPrefix(key, "alt_mac:"))
			}
		}
	}

	return known
}

func macFromFDBOID(oidName string) (string, bool) {
	parts := strings.Split(strings.TrimPrefix(oidName, "."), ".")
	baseParts := strings.Split(strings.TrimPrefix(oidDot1dTpFdbPort, "."), ".")
	if len(parts) < len(baseParts)+6 {
		return "", false
	}

	macBytes := make([]byte, 6)
	for i := 0; i < 6; i++ {
		val, err := strconv.Atoi(parts[len(baseParts)+i])
		if err != nil || val < 0 || val > 255 {
			return "", false
		}
		macBytes[i] = byte(val)
	}

	return formatMACAddress(macBytes), true
}

// macFromDot1qFDBOID extracts the MAC and dot1qFdbId from a dot1qTpFdbPort
// OID. The dot1q index is <dot1qFdbId>.<6 MAC octets>, so the MAC is the LAST
// six components — macFromFDBOID reads the FIRST six after the base and would
// misparse the fdbId as a MAC octet. The fdbId doubles as a best-effort VLAN id.
func macFromDot1qFDBOID(oidName string) (string, int32, bool) {
	parts := strings.Split(strings.TrimPrefix(oidName, "."), ".")
	baseParts := strings.Split(strings.TrimPrefix(oidDot1qTpFdbPort, "."), ".")
	if len(parts) < len(baseParts)+7 {
		return "", 0, false
	}

	macBytes := make([]byte, 6)
	for i := 0; i < 6; i++ {
		val, err := strconv.Atoi(parts[len(parts)-6+i])
		if err != nil || val < 0 || val > 255 {
			return "", 0, false
		}
		macBytes[i] = byte(val)
	}

	fdbID, err := strconv.Atoi(parts[len(parts)-7])
	if err != nil || fdbID < 0 || fdbID > math.MaxInt32 {
		return "", 0, false
	}

	return formatMACAddress(macBytes), int32(fdbID), true //nolint:gosec // G115: bounds checked above
}
