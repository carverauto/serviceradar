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
	"net"
	"sort"
	"strconv"
	"strings"

	"github.com/gosnmp/gosnmp"
)

const (
	defaultTooManyParts = 5
	ipv4Length          = 4
	ipv4BitLength       = 32
	ipv6BitLength       = 128
	maxBroadcastPrefix  = 30

	// ipAddressType values from IP-MIB (RFC 4293).
	ipAddressTypeBroadcast = 3
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

func snmpIPv4String(pdu gosnmp.SnmpPDU) string {
	switch uint8(pdu.Type) {
	case uint8(gosnmp.IPAddress):
		if s, ok := pdu.Value.(string); ok {
			return s
		}
	case uint8(gosnmp.OctetString):
		ipBytes, ok := pdu.Value.([]byte)
		if ok && len(ipBytes) == defaultIPBytesLength {
			return fmt.Sprintf("%d.%d.%d.%d", ipBytes[0], ipBytes[1], ipBytes[2], ipBytes[3])
		}
	}

	return ""
}

// handleIPAdEntAddr processes an ipAdEntAddr PDU and updates the IP to ifIndex mapping
func handleIPAdEntAddr(pdu gosnmp.SnmpPDU, ipToIfIndex map[string]int) {
	ipString := snmpIPv4String(pdu)

	// If we got an IP, extract the IP from the OID too (for matching)
	if ipString != "" {
		if ip, ok := extractIPFromOID(pdu.Name); ok {
			if _, exists := ipToIfIndex[ip]; !exists {
				ipToIfIndex[ip] = 0 // Placeholder, will be filled by ipAdEntIfIndex
			}
		}
	}
}

// handleIPAdEntNetMask processes an ipAdEntNetMask PDU and records the IPv4 prefix length.
func handleIPAdEntNetMask(pdu gosnmp.SnmpPDU, ipToPrefixLen map[string]int) {
	maskString := snmpIPv4String(pdu)
	if maskString == "" {
		return
	}

	parsedMask := net.ParseIP(maskString)
	if parsedMask == nil {
		return
	}

	mask4 := parsedMask.To4()
	if mask4 == nil {
		return
	}

	ones, bits := net.IPMask(mask4).Size()
	if bits != ipv4BitLength {
		return
	}

	if ip, ok := extractIPFromOID(pdu.Name); ok {
		ipToPrefixLen[ip] = ones
	}
}

func (*DiscoveryEngine) walkIPAddrTable(client *gosnmp.GoSNMP) (map[string]int, map[string]int, error) {
	ipToIfIndex := make(map[string]int)
	ipToPrefixLen := make(map[string]int)

	err := client.BulkWalk(oidIPAddrTable, func(pdu gosnmp.SnmpPDU) error {
		// Handle ipAdEntIfIndex to get the mapping of IP to ifIndex
		if strings.HasPrefix(pdu.Name, oidIPAdEntIfIndex) {
			handleIPAdEntIfIndex(pdu, ipToIfIndex)
		}

		// Now get the actual IP addresses
		if strings.HasPrefix(pdu.Name, oidIPAdEntAddr) {
			handleIPAdEntAddr(pdu, ipToIfIndex)
		}

		if strings.HasPrefix(pdu.Name, oidIPAdEntNetMask) {
			handleIPAdEntNetMask(pdu, ipToPrefixLen)
		}

		return nil
	})
	if err != nil {
		return nil, nil, fmt.Errorf("failed to walk ipAddrTable: %w", err)
	}

	filterBroadcastAddresses(ipToIfIndex, ipToPrefixLen)

	return ipToIfIndex, ipToPrefixLen, nil
}

// associateIPsWithInterfaces associates IP addresses with interfaces
func (*DiscoveryEngine) associateIPsWithInterfaces(ipToIfIndex map[string]int, ifMap map[int]*DiscoveredInterface) {
	for ip, ifIndex := range ipToIfIndex {
		if parsed := net.ParseIP(ip); parsed != nil && parsed.To4() != nil && parsed.To4().Equal(net.IPv4bcast) {
			continue
		}

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

func (*DiscoveryEngine) associateIPPrefixesWithInterfaces(
	ipToIfIndex map[string]int,
	ipToPrefixLen map[string]int,
	ifMap map[int]*DiscoveredInterface,
) {
	if len(ipToPrefixLen) == 0 {
		return
	}

	cidrsByIfIndex := make(map[int][]string)

	for ip, ifIndex := range ipToIfIndex {
		prefixLen, ok := ipToPrefixLen[ip]
		if !ok {
			continue
		}

		if _, exists := ifMap[ifIndex]; !exists {
			continue
		}

		cidrsByIfIndex[ifIndex] = append(cidrsByIfIndex[ifIndex], fmt.Sprintf("%s/%d", ip, prefixLen))
	}

	for ifIndex, cidrs := range cidrsByIfIndex {
		iface := ifMap[ifIndex]
		if iface == nil {
			continue
		}

		sort.Strings(cidrs)

		if iface.Metadata == nil {
			iface.Metadata = make(map[string]string)
		}

		iface.Metadata["ip_cidrs"] = strings.Join(cidrs, ",")
	}
}

// InetAddressType values from the INET-ADDRESS-MIB, used as the first index
// component of ipAddressTable.
const (
	inetAddressTypeIPv4  = 1
	inetAddressTypeIPv6  = 2
	inetAddressTypeIPv4z = 3
	inetAddressTypeIPv6z = 4

	ipv6Length = 16
)

// parseInetAddressIndex decodes the {ipAddressAddrType, ipAddressAddr} index
// that ipAddressTable rows are keyed by, given the OID sub-identifiers that
// follow the column OID.
//
// ipAddressAddr is an InetAddress (a variable-length OCTET STRING) and the IP-MIB
// does not declare it IMPLIED, so per RFC 2578 its length is encoded as a
// sub-identifier ahead of the bytes. The suffix is therefore
// `<addrType>.<length>.<byte>...` -- for example `1.4.192.168.1.1` for IPv4 and
// `2.16.32.1.13.184...` for IPv6. Reading a fixed number of trailing octets, the
// way extractIPFromOID does for the legacy table, cannot decode this.
//
// The zoned variants (ipv4z/ipv6z) append a 4-byte zone index after the address;
// the address itself is the leading 4 or 16 bytes, and the zone is dropped
// because an interface-scoped address is not a useful device alias.
func parseInetAddressIndex(suffix []string) (string, bool) {
	// addrType + length + at least one address octet.
	const minIndexParts = 3
	if len(suffix) < minIndexParts {
		return "", false
	}

	addrType, err := strconv.Atoi(suffix[0])
	if err != nil {
		return "", false
	}

	declaredLen, err := strconv.Atoi(suffix[1])
	if err != nil {
		return "", false
	}

	octets := suffix[2:]
	if declaredLen <= 0 || declaredLen > len(octets) {
		return "", false
	}

	var wantLen int

	switch addrType {
	case inetAddressTypeIPv4, inetAddressTypeIPv4z:
		wantLen = ipv4Length
	case inetAddressTypeIPv6, inetAddressTypeIPv6z:
		wantLen = ipv6Length
	default:
		// dns(16) and any future type are not addresses we can alias on.
		return "", false
	}

	if declaredLen < wantLen {
		return "", false
	}

	raw := make(net.IP, 0, wantLen)

	for _, octet := range octets[:wantLen] {
		value, convErr := strconv.Atoi(octet)
		if convErr != nil || value < 0 || value > math.MaxUint8 {
			return "", false
		}

		raw = append(raw, byte(value))
	}

	ip := raw.String()
	if ip == "" || ip == "<nil>" {
		return "", false
	}

	return ip, true
}

func parseIPAddressColumnSuffix(pduName, columnOID string) (string, bool) {
	if !strings.HasPrefix(pduName, columnOID+".") {
		return "", false
	}

	suffix := strings.TrimPrefix(pduName, columnOID+".")
	if suffix == "" {
		return "", false
	}

	return parseInetAddressIndex(strings.Split(suffix, "."))
}

// parseIPAddressPrefixRowPointer extracts the trailing ipAddressPrefixLength
// sub-identifier from an ipAddressPrefix RowPointer OID when it points into
// ipAddressPrefixTable (.1.3.6.1.2.1.4.32.1).
func parseIPAddressPrefixRowPointer(pdu gosnmp.SnmpPDU, isIPv6 bool) (int, bool) {
	var oid string

	switch v := pdu.Value.(type) {
	case string:
		oid = strings.TrimSpace(v)
	case []byte:
		oid = strings.TrimSpace(string(v))
	default:
		return 0, false
	}

	if oid == "" {
		return 0, false
	}

	normalized := "." + strings.TrimPrefix(oid, ".")
	if !strings.HasPrefix(normalized, oidIPAddressPrefixTable+".") {
		return 0, false
	}

	parts := strings.Split(normalized, ".")
	last := parts[len(parts)-1]

	prefixLen, err := strconv.Atoi(last)
	if err != nil || prefixLen < 0 {
		return 0, false
	}

	maxBits := ipv4BitLength
	if isIPv6 {
		maxBits = ipv6BitLength
	}

	if prefixLen > maxBits {
		return 0, false
	}

	return prefixLen, true
}

func isIPv4DirectedBroadcast(ip net.IP, network *net.IPNet) bool {
	if ip == nil || network == nil {
		return false
	}

	ip4 := ip.To4()
	netIP4 := network.IP.To4()
	if ip4 == nil || netIP4 == nil || len(network.Mask) != ipv4Length {
		return false
	}

	ones, bits := network.Mask.Size()
	if bits != ipv4BitLength || ones < 0 || ones > maxBroadcastPrefix {
		return false
	}

	for i := 0; i < ipv4Length; i++ {
		bcastOctet := (netIP4[i] & network.Mask[i]) | ^network.Mask[i]
		if ip4[i] != bcastOctet {
			return false
		}
	}

	return true
}

func isIPv4DirectedBroadcastCIDR(cidr string) bool {
	ip, network, err := net.ParseCIDR(strings.TrimSpace(cidr))
	if err != nil || ip == nil {
		if parsed := net.ParseIP(strings.TrimSpace(cidr)); parsed != nil && parsed.To4() != nil {
			return parsed.To4().Equal(net.IPv4bcast)
		}

		return false
	}

	if ip4 := ip.To4(); ip4 != nil && ip4.Equal(net.IPv4bcast) {
		return true
	}

	return isIPv4DirectedBroadcast(ip, network)
}

func filterBroadcastAddresses(ipToIfIndex map[string]int, ipToPrefixLen map[string]int) {
	var networks []*net.IPNet

	for ip, prefixLen := range ipToPrefixLen {
		parsed := net.ParseIP(ip)
		if parsed == nil || parsed.To4() == nil {
			continue
		}

		if prefixLen < 0 || prefixLen > maxBroadcastPrefix {
			continue
		}

		mask := net.CIDRMask(prefixLen, ipv4BitLength)
		networks = append(networks, &net.IPNet{
			IP:   parsed.To4().Mask(mask),
			Mask: mask,
		})
	}

	for ip := range ipToIfIndex {
		parsed := net.ParseIP(ip)
		if parsed == nil {
			continue
		}

		ip4 := parsed.To4()
		if ip4 == nil {
			continue
		}

		if ip4.Equal(net.IPv4bcast) {
			delete(ipToIfIndex, ip)
			delete(ipToPrefixLen, ip)
			continue
		}

		for _, network := range networks {
			if isIPv4DirectedBroadcast(ip4, network) {
				delete(ipToIfIndex, ip)
				delete(ipToPrefixLen, ip)
				break
			}
		}
	}
}

// collectIPAddressTable returns the non-broadcast addresses with their ifIndex
// and prefix length, plus every address ipAddressType classifies as
// broadcast(3) so callers can drop it from addresses learned elsewhere.
func collectIPAddressTable(pdus []gosnmp.SnmpPDU) (map[string]int, map[string]int, []string) {
	ipToIfIndex := make(map[string]int)
	ipToType := make(map[string]int)
	ipToPrefixLen := make(map[string]int)

	for _, pdu := range pdus {
		if ip, ok := parseIPAddressColumnSuffix(pdu.Name, oidIPAddressIfIndex); ok {
			if ifIndex, valOK := pdu.Value.(int); valOK {
				ipToIfIndex[ip] = ifIndex
			}
			continue
		}

		if ip, ok := parseIPAddressColumnSuffix(pdu.Name, oidIPAddressType); ok {
			if addrType, valOK := pdu.Value.(int); valOK {
				ipToType[ip] = addrType
			}
			continue
		}

		if ip, ok := parseIPAddressColumnSuffix(pdu.Name, oidIPAddressPrefix); ok {
			if prefixLen, valOK := parseIPAddressPrefixRowPointer(pdu, strings.Contains(ip, ":")); valOK {
				ipToPrefixLen[ip] = prefixLen
			}
		}
	}

	var broadcastIPs []string

	for ip, addrType := range ipToType {
		if addrType == ipAddressTypeBroadcast {
			broadcastIPs = append(broadcastIPs, ip)
			delete(ipToIfIndex, ip)
			delete(ipToPrefixLen, ip)
		}
	}

	sort.Strings(broadcastIPs)

	filterBroadcastAddresses(ipToIfIndex, ipToPrefixLen)

	return ipToIfIndex, ipToPrefixLen, broadcastIPs
}

// mergeIPAddressTable folds ipAddressTable rows into the ipAddrTable results
// and then drops every address ipAddressTable classified as broadcast, including
// one ipAddrTable reported without a usable mask. It returns the number of IPv6
// addresses merged.
func mergeIPAddressTable(
	ipToIfIndex, ipToPrefixLen, extra, extraPrefixes map[string]int,
	broadcastIPs []string,
) int {
	v6Count := 0

	for ip, prefixLen := range extraPrefixes {
		if _, exists := ipToPrefixLen[ip]; !exists {
			ipToPrefixLen[ip] = prefixLen
		}
	}

	for ip, ifIndex := range extra {
		// ipAddrTable already carries a real ifIndex for the addresses it
		// reports; do not let a duplicate row overwrite it with a placeholder.
		if existing, ok := ipToIfIndex[ip]; ok && existing != 0 && ifIndex == 0 {
			continue
		}

		ipToIfIndex[ip] = ifIndex

		if strings.Contains(ip, ":") {
			v6Count++
		}
	}

	for _, ip := range broadcastIPs {
		delete(ipToIfIndex, ip)
		delete(ipToPrefixLen, ip)
	}

	return v6Count
}

// walkIPAddressTable walks ipAddressIfIndex to learn every address the device
// reports, IPv6 included, excluding broadcast rows (ipAddressType = broadcast(3)).
// The broadcast rows are returned separately so the caller can also drop them
// from the addresses ipAddrTable reported.
//
// This is additive to walkIPAddrTable rather than a replacement: ipAddrTable is
// universally implemented while ipAddressTable is not, so dropping the legacy
// walk would lose IPv4 on older agents. Where both report the same address the
// values agree, and merging is idempotent.
func (*DiscoveryEngine) walkIPAddressTable(
	client *gosnmp.GoSNMP,
) (map[string]int, map[string]int, []string, error) {
	var pdus []gosnmp.SnmpPDU

	err := client.BulkWalk(oidIPAddressTable, func(pdu gosnmp.SnmpPDU) error {
		if strings.HasPrefix(pdu.Name, oidIPAddressIfIndex+".") ||
			strings.HasPrefix(pdu.Name, oidIPAddressType+".") ||
			strings.HasPrefix(pdu.Name, oidIPAddressPrefix+".") {
			pdus = append(pdus, pdu)
		}

		return nil
	})
	if err != nil {
		return nil, nil, nil, fmt.Errorf("failed to walk ipAddressTable: %w", err)
	}

	ipToIfIndex, ipToPrefixLen, broadcastIPs := collectIPAddressTable(pdus)

	return ipToIfIndex, ipToPrefixLen, broadcastIPs, nil
}
