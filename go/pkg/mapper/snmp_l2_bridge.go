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

	"strconv"

	"strings"

	"github.com/gosnmp/gosnmp"
)

func (e *DiscoveryEngine) bridgeIfIndexByMAC(client *gosnmp.GoSNMP) (map[string]int32, map[int32]int) {
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

	fdbPDUs := make([]gosnmp.SnmpPDU, 0)
	_ = client.BulkWalk(oidDot1dTpFdbPort, func(pdu gosnmp.SnmpPDU) error {
		fdbPDUs = append(fdbPDUs, pdu)
		return nil
	})

	return e.bridgeIfIndexByMACFromFDBPDUs(bridgePortToIfIndex, fdbPDUs)
}

func (e *DiscoveryEngine) bridgeIfIndexByMACFromFDBPDUs(
	bridgePortToIfIndex map[int32]int32,
	fdbPDUs []gosnmp.SnmpPDU,
) (map[string]int32, map[int32]int) {
	hasExplicitBridgePortMap := len(bridgePortToIfIndex) > 0
	result := make(map[string]int32)
	ambiguousMACs := make(map[string]struct{})
	fdbMacCountByIf := make(map[int32]int)
	seenByIfMAC := make(map[string]struct{})

	for _, pdu := range fdbPDUs {
		bridgePort, ok := e.getInt32FromPDU(pdu, "dot1dTpFdbPort")
		if !ok || bridgePort <= 0 {
			continue
		}

		ifIndex, exists := bridgePortToIfIndex[bridgePort]
		if !exists || ifIndex <= 0 {
			// Some switches expose dot1dTpFdbPort but not dot1dBasePortIfIndex.
			// On those agents, bridge port IDs are typically aligned with ifIndex.
			// Use that as a fallback so FDB evidence can still drive topology attribution.
			if hasExplicitBridgePortMap {
				continue
			}
			ifIndex = bridgePort
		}

		mac, ok := macFromFDBOID(pdu.Name)
		if !ok || mac == "" {
			continue
		}

		normalized := NormalizeMAC(mac)
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
			ambiguousMACs[normalized] = struct{}{}
			continue
		}

		result[normalized] = ifIndex
	}

	return result, fdbMacCountByIf
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
