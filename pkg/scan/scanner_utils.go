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

package scan

import (
	"net"

	"github.com/carverauto/serviceradar/pkg/models"
)

// ExpandCIDR expands a CIDR notation into a slice of IP addresses.
// Skips network and broadcast addresses for non-/32 networks.
func ExpandCIDR(cidr string) ([]string, error) {
	baseIP, ipnet, err := net.ParseCIDR(cidr) // Renamed outer "ip" to "baseIP"
	if err != nil {
		return nil, err
	}

	var ips []string

	for currentIP := baseIP.Mask(ipnet.Mask); ipnet.Contains(currentIP); incIP(currentIP) { // Renamed loop "ip" to "currentIP"
		// Skip network and broadcast addresses for IPv4 non-/32
		ones, _ := ipnet.Mask.Size()
		if currentIP.To4() != nil && ones != 32 {
			if currentIP.Equal(ipnet.IP) || isBroadcast(currentIP, ipnet) {
				continue
			}
		}

		ips = append(ips, currentIP.String())
	}

	return ips, nil
}

// incIP increments an IP address in place.
func incIP(ip net.IP) {
	for i := len(ip) - 1; i >= 0; i-- {
		ip[i]++
		if ip[i] != 0 {
			break
		}
	}
}

// isBroadcast checks if an IP is the broadcast address of a network.
func isBroadcast(ip net.IP, ipnet *net.IPNet) bool {
	broadcast := make(net.IP, len(ip))
	for i := range ip {
		broadcast[i] = ipnet.IP[i] | ^ipnet.Mask[i]
	}

	return ip.Equal(broadcast)
}

// TargetFromIP creates a models.Target from an IP string and mode, with optional port.
func TargetFromIP(ip string, mode models.SweepMode, port ...int) models.Target {
	t := models.Target{
		Host: ip,
		Mode: mode,
	}

	if len(port) > 0 {
		t.Port = port[0]
	}

	return t
}
