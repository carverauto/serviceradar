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

package agent

import (
	"net"
)

// IPSorter is a type for sorting IP addresses.
type IPSorter []string

func (s IPSorter) Len() int { return len(s) }

func (s IPSorter) Swap(i, j int) { s[i], s[j] = s[j], s[i] }

// Less implements sort.Interface.
func (s IPSorter) Less(i, j int) bool {
	return compareIPs(s[i], s[j])
}

// compareIPs compares two IP address strings.
// Returns true if ip1 should sort before ip2.
func compareIPs(ip1Str, ip2Str string) bool {
	ip1 := net.ParseIP(ip1Str)
	ip2 := net.ParseIP(ip2Str)

	// Handle case where either IP is invalid
	if valid := handleInvalidIPs(ip1, ip2, ip1Str, ip2Str); valid != nil {
		return *valid
	}

	// Convert and compare as IPv4
	return compareIPv4(ip1, ip2, ip1Str, ip2Str)
}

// handleInvalidIPs handles cases where one or both IPs are invalid.
// Returns nil if both IPs are valid.
func handleInvalidIPs(ip1, ip2 net.IP, ip1Str, ip2Str string) *bool {
	if ip1 == nil || ip2 == nil {
		result := false
		if ip1 == nil && ip2 == nil {
			// Both invalid, sort alphabetically
			result = ip1Str < ip2Str
		} else {
			// Invalid IPs come first
			result = ip1 == nil
		}

		return &result
	}

	return nil
}

// compareIPv4 compares two valid IPs as IPv4 addresses.
func compareIPv4(ip1, ip2 net.IP, ip1Str, ip2Str string) bool {
	ip1v4 := ip1.To4()
	ip2v4 := ip2.To4()

	// Handle non-IPv4 addresses
	if ip1v4 == nil || ip2v4 == nil {
		if ip1v4 == nil && ip2v4 == nil {
			return ip1Str < ip2Str
		}

		return ip1v4 == nil
	}

	// Compare IPv4 addresses byte by byte
	return compareBytes(ip1v4, ip2v4)
}

// compareBytes compares two IPv4 addresses byte by byte.
func compareBytes(ip1, ip2 net.IP) bool {
	for i := 0; i < 4; i++ {
		if ip1[i] != ip2[i] {
			return ip1[i] < ip2[i]
		}
	}

	return false
}
