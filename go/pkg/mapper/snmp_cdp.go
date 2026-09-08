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

	"net"

	"strconv"

	"strings"

	"time"

	"github.com/gosnmp/gosnmp"
)

const (
	defaultPartsCount = 12
)

// processCDPPDU processes a single CDP PDU and updates the link map
func (e *DiscoveryEngine) processCDPPDU(
	pdu gosnmp.SnmpPDU, linkMap map[string]*TopologyLink, targetIP string, job *DiscoveryJob) error {
	parts := strings.Split(pdu.Name, ".")

	if len(parts) < defaultPartsCount {
		return nil
	}

	// Extract ifIndex.index from OID
	// Format: .1.3.6.1.4.1.9.9.23.1.2.1.1.X.ifIndex.index
	ifIndex := parts[len(parts)-2]
	index := parts[len(parts)-1]
	key := fmt.Sprintf("%s.%s", ifIndex, index)

	// Create topology link if not exists
	e.ensureCDPLinkExists(linkMap, key, ifIndex, targetIP, job)

	link := linkMap[key]

	// Extract OID suffix for comparison
	oidSuffix := parts[len(parts)-3]

	// Update link based on OID suffix
	e.updateCDPLinkFromPDU(link, oidSuffix, pdu)

	return nil
}

// ensureCDPLinkExists creates a new topology link if it doesn't exist in the map
func (*DiscoveryEngine) ensureCDPLinkExists(
	linkMap map[string]*TopologyLink, key, ifIndex, targetIP string, job *DiscoveryJob) {
	if _, exists := linkMap[key]; !exists {
		// Get the actual device ID
		var localDeviceID string

		job.mu.RLock()

		for _, device := range job.Results.Devices {
			if device.IP == targetIP {
				localDeviceID = device.DeviceID
				break
			}
		}

		job.mu.RUnlock()

		ifIdx, _ := strconv.Atoi(ifIndex)

		linkMap[key] = &TopologyLink{
			Protocol:      "CDP",
			LocalDeviceIP: targetIP,
			LocalDeviceID: localDeviceID,
			LocalIfIndex:  safeInt32(ifIdx),
			Metadata:      make(map[string]string),
		}
	}
}

// updateCDPLinkFromPDU updates a topology link based on the OID suffix and PDU value
func (e *DiscoveryEngine) updateCDPLinkFromPDU(link *TopologyLink, oidSuffix string, pdu gosnmp.SnmpPDU) {
	switch oidSuffix {
	case "6": // oidCdpCacheDeviceId
		e.updateCDPDeviceID(link, pdu)
	case "7": // oidCdpCacheDevicePort
		e.updateCDPDevicePort(link, pdu)
	case "4": // oidCdpCacheAddress
		e.updateCDPDeviceAddress(link, pdu)
	}
}

// updateCDPDeviceID updates the neighbor system name and chassis ID
func (*DiscoveryEngine) updateCDPDeviceID(link *TopologyLink, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.OctetString {
		link.NeighborSystemName = string(pdu.Value.([]byte))
		// Use as chassis ID if not set
		if link.NeighborChassisID == "" {
			link.NeighborChassisID = link.NeighborSystemName
		}
	}
}

// updateCDPDevicePort updates the neighbor port ID and description
func (*DiscoveryEngine) updateCDPDevicePort(link *TopologyLink, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.OctetString {
		port := string(pdu.Value.([]byte))
		link.NeighborPortID = port
		link.NeighborPortDescr = port
	}
}

// updateCDPDeviceAddress updates the neighbor management address
func (e *DiscoveryEngine) updateCDPDeviceAddress(link *TopologyLink, pdu gosnmp.SnmpPDU) {
	if pdu.Type == gosnmp.OctetString {
		bytes := pdu.Value.([]byte)
		link.NeighborMgmtAddr = e.extractCDPIPAddress(bytes)
	}
}

// extractCDPIPAddress extracts an IP address from CDP address bytes
func (*DiscoveryEngine) extractCDPIPAddress(bytes []byte) string {
	// CDP address format varies, try to extract IP
	if len(bytes) >= defaultByteLength { // CDP often has header bytes before the actual IP
		// Try to extract IPv4 address
		// Typical format: type(1) + len(4) + addr(4)
		if bytes[0] == 1 && len(bytes) >= defaultByteLength { // Type 1 = IP
			ip := net.IPv4(bytes[len(bytes)-4], bytes[len(bytes)-3],
				bytes[len(bytes)-2], bytes[len(bytes)-1])

			return ip.String()
		}
	}

	return ""
}

// finalizeCDPLinks converts the link map to a slice and adds metadata
func (*DiscoveryEngine) finalizeCDPLinks(linkMap map[string]*TopologyLink, job *DiscoveryJob) ([]*TopologyLink, error) {
	links := make([]*TopologyLink, 0, len(linkMap))

	for _, link := range linkMap {
		// Basic validation - need at least one neighbor identifier
		if link.NeighborSystemName == "" && link.NeighborPortID == "" {
			continue
		}

		// Add metadata
		link.Metadata["discovery_id"] = job.ID
		link.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
		link.Metadata["protocol"] = "CDP"
		link.Metadata["source"] = "cdp"

		links = append(links, link)
	}

	if len(links) == 0 {
		return nil, ErrNoCDPNeighborsFound
	}

	return links, nil
}

// queryCDP queries CDP (Cisco Discovery Protocol) topology information
func (e *DiscoveryEngine) queryCDP(client *gosnmp.GoSNMP, targetIP string, job *DiscoveryJob) ([]*TopologyLink, error) {
	linkMap := make(map[string]*TopologyLink) // Key is "ifIndex.index"

	// Walk CDP cache table
	err := client.BulkWalk(oidCDPCacheTable, func(pdu gosnmp.SnmpPDU) error {
		return e.processCDPPDU(pdu, linkMap, targetIP, job)
	})
	if err != nil {
		return nil, fmt.Errorf("failed to walk CDP table: %w", err)
	}

	return e.finalizeCDPLinks(linkMap, job)
}

// formatMACAddress formats a byte array as a MAC address string
