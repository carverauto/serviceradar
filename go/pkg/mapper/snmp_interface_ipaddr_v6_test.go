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
	"strings"
	"testing"

	"github.com/gosnmp/gosnmp"
)

// The OID suffixes below were captured verbatim from a production router with
// `snmpwalk -On -v2c <community> <router> .1.3.6.1.2.1.4.34.1.3`, so this test
// pins the real ipAddressTable index encoding rather than an assumed one.
func TestParseInetAddressIndexDecodesRealRouterOIDs(t *testing.T) {
	tests := []struct {
		name   string
		suffix string
		want   string
		ok     bool
	}{
		{"ipv4 wan", "1.4.152.117.116.178", "152.117.116.178", true},
		{"ipv4 lan gateway", "1.4.192.168.1.1", "192.168.1.1", true},
		{"ipv4 loopback is decoded, filtered downstream", "1.4.127.0.0.1", "127.0.0.1", true},
		{
			"ipv6 global unicast",
			"2.16.32.1.4.112.192.181.0.1.0.0.0.0.0.0.0.1",
			"2001:470:c0b5:1::1",
			true,
		},
		{
			"ipv6 unique local",
			"2.16.253.47.66.10.36.177.0.1.246.146.191.255.254.117.199.42",
			"fd2f:420a:24b1:1:f692:bfff:fe75:c72a",
			true,
		},
		{
			"ipv6 loopback is decoded, filtered downstream",
			"2.16.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.1",
			"::1",
			true,
		},
		// Malformed / unsupported forms must be rejected, never guessed at.
		{"declared length exceeds octets present", "2.16.32.1.4", "", false},
		{"ipv4 type with a truncated address", "1.4.192.168.1", "", false},
		{"dns type is not an address", "16.3.97.98.99", "", false},
		{"empty suffix", "", "", false},
		{"octet out of range", "1.4.192.168.1.999", "", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var parts []string
			if tt.suffix != "" {
				parts = strings.Split(tt.suffix, ".")
			}

			got, ok := parseInetAddressIndex(parts)
			if ok != tt.ok {
				t.Fatalf("parseInetAddressIndex(%q) ok = %v, want %v (got %q)", tt.suffix, ok, tt.ok, got)
			}

			if got != tt.want {
				t.Fatalf("parseInetAddressIndex(%q) = %q, want %q", tt.suffix, got, tt.want)
			}
		})
	}
}

// The legacy helper reads a fixed four trailing octets, which silently produces
// a wrong IPv4 address from an IPv6 row. This is why the new table needs its own
// parser rather than reusing extractIPFromOID.
func TestExtractIPFromOIDCannotDecodeIPv6Rows(t *testing.T) {
	const ipv6Row = ".1.3.6.1.2.1.4.34.1.3.2.16.32.1.4.112.192.181.0.1.0.0.0.0.0.0.0.1"

	legacy, ok := extractIPFromOID(ipv6Row)
	if ok && legacy == "2001:470:c0b5:1::1" {
		t.Fatal("extractIPFromOID unexpectedly decoded an IPv6 row; the dedicated parser would be redundant")
	}

	parsed, parsedOK := parseInetAddressIndex(strings.Split(
		strings.TrimPrefix(strings.TrimPrefix(ipv6Row, oidIPAddressIfIndex), "."), "."))
	if !parsedOK || parsed != "2001:470:c0b5:1::1" {
		t.Fatalf("parseInetAddressIndex failed on the row the legacy helper cannot read: %q ok=%v", parsed, parsedOK)
	}
}

func TestCollectIPAddressTableSkipsBroadcastRowsAndExtractsPrefixes(t *testing.T) {
	pdus := []gosnmp.SnmpPDU{
		{Name: oidIPAddressIfIndex + ".1.4.192.0.2.10", Type: gosnmp.Integer, Value: 2},
		{Name: oidIPAddressIfIndex + ".1.4.192.0.2.255", Type: gosnmp.Integer, Value: 2},
		{Name: oidIPAddressIfIndex + ".2.16.32.1.13.184.0.1.0.0.0.0.0.0.0.0.0.1", Type: gosnmp.Integer, Value: 2},
		{Name: oidIPAddressType + ".1.4.192.0.2.10", Type: gosnmp.Integer, Value: 1},
		{Name: oidIPAddressType + ".1.4.192.0.2.255", Type: gosnmp.Integer, Value: ipAddressTypeBroadcast},
		{Name: oidIPAddressType + ".2.16.32.1.13.184.0.1.0.0.0.0.0.0.0.0.0.1", Type: gosnmp.Integer, Value: 1},
		{
			Name:  oidIPAddressPrefix + ".1.4.192.0.2.10",
			Type:  gosnmp.ObjectIdentifier,
			Value: oidIPAddressPrefixTable + ".1.2.1.4.192.0.2.0.24",
		},
	}

	ipToIfIndex, ipToPrefixLen, broadcastIPs := collectIPAddressTable(pdus)

	if _, exists := ipToIfIndex["192.0.2.255"]; exists {
		t.Fatalf("collectIPAddressTable retained broadcast row 192.0.2.255: %#v", ipToIfIndex)
	}

	if got := strings.Join(broadcastIPs, ","); got != "192.0.2.255" {
		t.Fatalf("broadcastIPs = %q, want 192.0.2.255", got)
	}

	if got := ipToIfIndex["192.0.2.10"]; got != 2 {
		t.Fatalf("ipToIfIndex[192.0.2.10] = %d, want 2", got)
	}

	if got := ipToIfIndex["2001:db8:1::1"]; got != 2 {
		t.Fatalf("ipToIfIndex[2001:db8:1::1] = %d, want 2", got)
	}

	if got := ipToPrefixLen["192.0.2.10"]; got != 24 {
		t.Fatalf("ipToPrefixLen[192.0.2.10] = %d, want 24", got)
	}
}

// ipAddrTable reports 192.0.2.127 without a usable mask, so nothing on the
// legacy side marks it as the /25 broadcast; ipAddressTable classifies the same
// address as broadcast(3) without a prefix. The merged result must not keep it.
func TestMergeIPAddressTableDropsBroadcastClassifiedLegacyRows(t *testing.T) {
	ipToIfIndex := map[string]int{"192.0.2.1": 2, "192.0.2.127": 2}
	ipToPrefixLen := map[string]int{}

	pdus := []gosnmp.SnmpPDU{
		{Name: oidIPAddressIfIndex + ".1.4.192.0.2.1", Type: gosnmp.Integer, Value: 2},
		{Name: oidIPAddressIfIndex + ".1.4.192.0.2.127", Type: gosnmp.Integer, Value: 2},
		{Name: oidIPAddressIfIndex + ".2.16.32.1.13.184.0.1.0.0.0.0.0.0.0.0.0.1", Type: gosnmp.Integer, Value: 2},
		{Name: oidIPAddressType + ".1.4.192.0.2.1", Type: gosnmp.Integer, Value: 1},
		{Name: oidIPAddressType + ".1.4.192.0.2.127", Type: gosnmp.Integer, Value: ipAddressTypeBroadcast},
	}

	extra, extraPrefixes, broadcastIPs := collectIPAddressTable(pdus)
	v6Count := mergeIPAddressTable(ipToIfIndex, ipToPrefixLen, extra, extraPrefixes, broadcastIPs)
	filterBroadcastAddresses(ipToIfIndex, ipToPrefixLen)

	if _, exists := ipToIfIndex["192.0.2.127"]; exists {
		t.Fatalf("merged result retained broadcast-classified 192.0.2.127: %#v", ipToIfIndex)
	}

	if got := ipToIfIndex["192.0.2.1"]; got != 2 {
		t.Fatalf("ipToIfIndex[192.0.2.1] = %d, want 2", got)
	}

	if v6Count != 1 {
		t.Fatalf("v6Count = %d, want 1", v6Count)
	}
}

// A 0.0.0.0 mask and a /0 ipAddressPrefix are a valid zero-length prefix, so the
// interface still reports an explicit CIDR for its .255 host.
func TestZeroLengthPrefixIsPropagated(t *testing.T) {
	ipToPrefixLen := map[string]int{}
	handleIPAdEntNetMask(gosnmp.SnmpPDU{
		Name:  oidIPAdEntNetMask + ".198.51.100.255",
		Type:  gosnmp.IPAddress,
		Value: "0.0.0.0",
	}, ipToPrefixLen)

	if got, ok := ipToPrefixLen["198.51.100.255"]; !ok || got != 0 {
		t.Fatalf("ipToPrefixLen[198.51.100.255] = %d (present=%v), want 0", got, ok)
	}

	prefixLen, ok := parseIPAddressPrefixRowPointer(gosnmp.SnmpPDU{
		Type:  gosnmp.ObjectIdentifier,
		Value: oidIPAddressPrefixTable + ".1.2.1.4.0.0.0.0.0",
	}, false)
	if !ok || prefixLen != 0 {
		t.Fatalf("parseIPAddressPrefixRowPointer = %d (ok=%v), want 0", prefixLen, ok)
	}

	ipToIfIndex := map[string]int{"198.51.100.255": 2}
	filterBroadcastAddresses(ipToIfIndex, ipToPrefixLen)

	ifMap := map[int]*DiscoveredInterface{2: {IfIndex: 2}}
	engine := &DiscoveryEngine{}
	engine.associateIPsWithInterfaces(ipToIfIndex, ifMap)
	engine.associateIPPrefixesWithInterfaces(ipToIfIndex, ipToPrefixLen, ifMap)

	if got := ifMap[2].Metadata["ip_cidrs"]; got != "198.51.100.255/0" {
		t.Fatalf("ifMap[2].Metadata[ip_cidrs] = %q, want 198.51.100.255/0", got)
	}
}

func TestFilterBroadcastAddressesAndPrefixMetadata(t *testing.T) {
	ipToIfIndex := map[string]int{
		"192.0.2.1":       2,
		"192.0.2.255":     2, // directed broadcast for 192.0.2.1/24 on same interface
		"198.51.101.255":  3, // directed broadcast for /23
		"203.0.113.1":     4, // valid /16 host where .255 on same interface is NOT broadcast
		"203.0.113.255":   4, // valid host inside 203.0.0.0/16
		"192.0.2.3":       5, // valid /31 endpoint
		"198.51.100.255":  6, // valid /32 loopback/host route
		"255.255.255.255": 2, // limited broadcast
	}

	ipToPrefixLen := map[string]int{
		"192.0.2.1":      24,
		"198.51.101.255": 23,
		"203.0.113.1":    16,
		"203.0.113.255":  16,
		"192.0.2.3":      31,
		"198.51.100.255": 32,
	}

	filterBroadcastAddresses(ipToIfIndex, ipToPrefixLen)

	for _, forbidden := range []string{"192.0.2.255", "198.51.101.255", "255.255.255.255"} {
		if _, exists := ipToIfIndex[forbidden]; exists {
			t.Fatalf("filterBroadcastAddresses did not remove broadcast IP %s", forbidden)
		}
	}

	for _, allowed := range []string{"192.0.2.1", "203.0.113.1", "203.0.113.255", "192.0.2.3", "198.51.100.255"} {
		if _, exists := ipToIfIndex[allowed]; !exists {
			t.Fatalf("filterBroadcastAddresses removed valid host IP %s", allowed)
		}
	}

	ifMap := map[int]*DiscoveredInterface{
		2: {IfIndex: 2},
		4: {IfIndex: 4},
	}

	engine := &DiscoveryEngine{}
	engine.associateIPsWithInterfaces(ipToIfIndex, ifMap)
	engine.associateIPPrefixesWithInterfaces(ipToIfIndex, ipToPrefixLen, ifMap)

	if got := ifMap[2].Metadata["ip_cidrs"]; got != "192.0.2.1/24" {
		t.Fatalf("ifMap[2].Metadata[ip_cidrs] = %q, want %q", got, "192.0.2.1/24")
	}

	if got := ifMap[4].Metadata["ip_cidrs"]; got != "203.0.113.1/16,203.0.113.255/16" {
		t.Fatalf("ifMap[4].Metadata[ip_cidrs] = %q, want %q", got, "203.0.113.1/16,203.0.113.255/16")
	}
}

func TestMapMikroTikInterfaceIPsSkipsDirectedBroadcastCIDRs(t *testing.T) {
	rawAddresses := []map[string]any{
		{"interface": "bridge1", "address": "192.0.2.1/24"},
		{"interface": "bridge1", "address": "192.0.2.255/24"},
		{"interface": "wan1", "address": "203.0.113.255/16"},
		{"interface": "lo0", "address": "198.51.100.255/32"},
	}

	ips := mapMikroTikInterfaceIPs(rawAddresses)
	cidrs := mapMikroTikInterfaceCIDRs(rawAddresses)

	if got := strings.Join(ips["bridge1"], ","); got != "192.0.2.1" {
		t.Fatalf("ips[bridge1] = %q, want 192.0.2.1", got)
	}
	if got := strings.Join(cidrs["bridge1"], ","); got != "192.0.2.1/24" {
		t.Fatalf("cidrs[bridge1] = %q, want 192.0.2.1/24", got)
	}
	if got := strings.Join(ips["wan1"], ","); got != "203.0.113.255" {
		t.Fatalf("ips[wan1] = %q, want 203.0.113.255", got)
	}
	if got := strings.Join(ips["lo0"], ","); got != "198.51.100.255" {
		t.Fatalf("ips[lo0] = %q, want 198.51.100.255", got)
	}
}
