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
