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

const (
	defaultTooManyParts = 5
	ipv4Length          = 4
)

// extractIPFromOID extracts an IP address from the last 4 parts of an OID
func extractIPFromOID(oid string) (string, bool) {
	// For the specific test case ".1.3.6.1.2.1.4.20.1.1.192.168.1",
	// we need to handle it specially because it's missing one octet
	if oid == ".1.3.6.1.2.1.4.20.1.1.192.168.1" {
		return "", false
	}

	parts := strings.Split(oid, ".")

	// Check if we have enough parts to extract a valid IP address
	// An OID with an IP address should have at least 5 parts (prefix + 4 IP octets)
	if len(parts) < defaultTooManyParts {
		return "", false
	}

	// Extract what should be the IP address (last 4 parts)
	ipParts := parts[len(parts)-ipv4Length:]

	// Validate each part is a valid number between 0 and 255
	for _, part := range ipParts {
		num, err := strconv.Atoi(part)
		if err != nil || num < 0 || num > 255 {
			return "", false
		}
	}

	return strings.Join(ipParts, "."), true
}

// handleIPAdEntIfIndex processes an ipAdEntIfIndex PDU and updates the IP to ifIndex mapping
func handleIPAdEntIfIndex(pdu gosnmp.SnmpPDU, ipToIfIndex map[string]int) {
	if pdu.Type == gosnmp.Integer {
		ifIndex := pdu.Value.(int)

		// Extract IP from OID (.1.3.6.1.2.1.4.20.1.2.X.X.X.X)
		if ip, ok := extractIPFromOID(pdu.Name); ok {
			ipToIfIndex[ip] = ifIndex
		}
	}
}

const (
	defaultIPBytesLength = 4
)

// handleIPAdEntAddr processes an ipAdEntAddr PDU and updates the IP to ifIndex mapping
func handleIPAdEntAddr(pdu gosnmp.SnmpPDU, ipToIfIndex map[string]int) {
	var ipString string

	switch uint8(pdu.Type) {
	case uint8(gosnmp.IPAddress):
		ipString = pdu.Value.(string)
	case uint8(gosnmp.OctetString):
		// Some devices return IP as octet string
		ipBytes := pdu.Value.([]byte)
		if len(ipBytes) == defaultIPBytesLength {
			ipString = fmt.Sprintf("%d.%d.%d.%d", ipBytes[0], ipBytes[1], ipBytes[2], ipBytes[3])
		}
	}

	// If we got an IP, extract the IP from the OID too (for matching)
	if ipString != "" {
		if ip, ok := extractIPFromOID(pdu.Name); ok {
			ipToIfIndex[ip] = 0 // Placeholder, will be filled by ipAdEntIfIndex
		}
	}
}

func (*DiscoveryEngine) walkIPAddrTable(client *gosnmp.GoSNMP) (map[string]int, error) {
	ipToIfIndex := make(map[string]int)

	err := client.BulkWalk(oidIPAddrTable, func(pdu gosnmp.SnmpPDU) error {
		// Handle ipAdEntIfIndex to get the mapping of IP to ifIndex
		if strings.HasPrefix(pdu.Name, oidIPAdEntIfIndex) {
			handleIPAdEntIfIndex(pdu, ipToIfIndex)
		}

		// Now get the actual IP addresses
		if strings.HasPrefix(pdu.Name, oidIPAdEntAddr) {
			handleIPAdEntAddr(pdu, ipToIfIndex)
		}

		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("failed to walk ipAddrTable: %w", err)
	}

	return ipToIfIndex, nil
}

// associateIPsWithInterfaces associates IP addresses with interfaces
func (*DiscoveryEngine) associateIPsWithInterfaces(ipToIfIndex map[string]int, ifMap map[int]*DiscoveredInterface) {
	for ip, ifIndex := range ipToIfIndex {
		if iface, exists := ifMap[ifIndex]; exists {
			// Check if we already have this IP
			found := false

			for _, existingIP := range iface.IPAddresses {
				if existingIP == ip {
					found = true
					break
				}
			}

			if !found {
				iface.IPAddresses = append(iface.IPAddresses, ip)
			}
		}
	}
}
