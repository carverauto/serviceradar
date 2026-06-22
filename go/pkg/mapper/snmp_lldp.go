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
	defaultLLDPPartsCount = 11
)

// processLLDPRemoteTableEntry processes a single LLDP remote table entry
func (e *DiscoveryEngine) processLLDPRemoteTableEntry(
	pdu gosnmp.SnmpPDU, linkMap map[string]*TopologyLink, targetIP string, job *DiscoveryJob) error {
	parts := strings.Split(pdu.Name, ".")
	if len(parts) < defaultLLDPPartsCount {
		return nil
	}

	// Extract timeMark.localPort.index from OID
	// Format: .1.0.8802.1.1.2.1.4.1.1.X.timeMark.localPort.index
	timeMark := parts[len(parts)-3]
	localPort := parts[len(parts)-2]
	index := parts[len(parts)-1]

	key := fmt.Sprintf("%s.%s.%s", timeMark, localPort, index)

	// Get the actual device ID from the discovered device
	job.mu.RLock()

	var localDeviceID string

	for _, device := range job.Results.Devices {
		if device.IP == targetIP {
			localDeviceID = device.DeviceID
			break
		}
	}

	job.mu.RUnlock()

	// Create topology link if not exists
	if _, exists := linkMap[key]; !exists {
		localPortIdx, _ := strconv.Atoi(localPort)
		linkMap[key] = &TopologyLink{
			Protocol:      "LLDP",
			LocalDeviceIP: targetIP,
			LocalDeviceID: localDeviceID,
			LocalIfIndex:  safeInt32(localPortIdx),
			Metadata:      make(map[string]string),
		}
	}

	link := linkMap[key]

	// Extract OID suffix for comparison
	oidSuffix := parts[len(parts)-4]

	// Process the PDU based on OID suffix
	e.processLLDPOIDSuffix(oidSuffix, pdu, link)

	return nil
}

// processLLDPOIDSuffix processes a PDU based on its OID suffix
func (*DiscoveryEngine) processLLDPOIDSuffix(oidSuffix string, pdu gosnmp.SnmpPDU, link *TopologyLink) {
	// Parse based on the OID suffix
	switch oidSuffix {
	case "5": // oidLldpRemChassisId
		if pdu.Type == gosnmp.OctetString {
			link.NeighborChassisID = formatLLDPID(pdu.Value.([]byte))
		}
	case "7": // oidLldpRemPortId
		if pdu.Type == gosnmp.OctetString {
			link.NeighborPortID = formatLLDPID(pdu.Value.([]byte))
		}
	case "8": // oidLldpRemPortDesc
		if pdu.Type == gosnmp.OctetString {
			link.NeighborPortDescr = string(pdu.Value.([]byte))
		}
	case "9": // oidLldpRemSysName
		if pdu.Type == gosnmp.OctetString {
			link.NeighborSystemName = string(pdu.Value.([]byte))
		}
	}
}

const (
	// 5
	defaultByteLengthCheck = 5
)

// processLLDPManagementAddress processes LLDP management address entries
func (*DiscoveryEngine) processLLDPManagementAddress(pdu gosnmp.SnmpPDU, linkMap map[string]*TopologyLink) error {
	if pdu.Type != gosnmp.OctetString {
		return nil
	}

	key := lldpManagementAddressLinkKey(pdu.Name)
	if key == "" {
		key = lldpManagementAddressLinkKey(strings.TrimPrefix(pdu.Name, "."))
	}

	// Try to extract IP address from management address
	bytes := pdu.Value.([]byte)
	if len(bytes) >= defaultByteLengthCheck {
		// First byte is usually the address type (1=IPv4)
		if bytes[0] == 1 && len(bytes) >= 5 {
			ip := net.IPv4(bytes[1], bytes[2], bytes[3], bytes[4])

			if link, ok := linkMap[key]; ok && link.NeighborMgmtAddr == "" {
				link.NeighborMgmtAddr = ip.String()
				return nil
			}

			// Fallback for incomplete OIDs: assign to first unresolved link.
			for _, link := range linkMap {
				if link.NeighborMgmtAddr == "" {
					link.NeighborMgmtAddr = ip.String()
					return nil
				}
			}
		}
	}

	return nil
}

func lldpManagementAddressLinkKey(oid string) string {
	base := strings.TrimPrefix(oidLLDPRemManAddr, ".")
	trimmed := strings.TrimPrefix(oid, ".")
	prefix := base + "."
	if !strings.HasPrefix(trimmed, prefix) {
		return ""
	}

	suffix := strings.TrimPrefix(trimmed, prefix)
	parts := strings.Split(suffix, ".")
	if len(parts) < 3 {
		return ""
	}

	return fmt.Sprintf("%s.%s.%s", parts[0], parts[1], parts[2])
}

// isValidLLDPLink checks if a link has at least one neighbor identifier
func (*DiscoveryEngine) isValidLLDPLink(link *TopologyLink) bool {
	return link.NeighborChassisID != "" || link.NeighborSystemName != "" || link.NeighborPortID != ""
}

// addLLDPMetadata adds metadata to a link
func (*DiscoveryEngine) addLLDPMetadata(link *TopologyLink, jobID string) {
	link.Metadata["discovery_id"] = jobID
	link.Metadata["discovery_time"] = time.Now().Format(time.RFC3339)
	link.Metadata["protocol"] = "LLDP"
	link.Metadata["source"] = "lldp"
}

// finalizeLLDPLinks validates and finalizes LLDP links
func (e *DiscoveryEngine) finalizeLLDPLinks(
	linkMap map[string]*TopologyLink, job *DiscoveryJob) ([]*TopologyLink, error) {
	links := make([]*TopologyLink, 0, len(linkMap))

	for _, link := range linkMap {
		// Skip invalid links
		if !e.isValidLLDPLink(link) {
			continue
		}

		e.addLLDPMetadata(link, job.ID)
		links = append(links, link)
	}

	if len(links) == 0 {
		return nil, ErrNoLLDPNeighborsFound
	}

	return links, nil
}

// queryLLDP queries LLDP topology information
func (e *DiscoveryEngine) queryLLDP(client *gosnmp.GoSNMP, targetIP string, job *DiscoveryJob) ([]*TopologyLink, error) {
	linkMap := make(map[string]*TopologyLink) // Key is "timeMark.localPort.index"

	// Walk LLDP remote table
	err := client.BulkWalk(oidLLDPRemTable, func(pdu gosnmp.SnmpPDU) error {
		return e.processLLDPRemoteTableEntry(pdu, linkMap, targetIP, job)
	})
	if err != nil {
		return nil, fmt.Errorf("failed to walk LLDP table: %w", err)
	}

	// Walk LLDP management address table for neighbor IPs
	err = client.BulkWalk(oidLLDPRemManAddr, func(pdu gosnmp.SnmpPDU) error {
		return e.processLLDPManagementAddress(pdu, linkMap)
	})
	if err != nil {
		return nil, err
	}

	return e.finalizeLLDPLinks(linkMap, job)
}
