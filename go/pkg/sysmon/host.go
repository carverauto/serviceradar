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

package sysmon

import (
	"context"
	"net"
	"os"
	"strings"
	"time"
)

// getHostID returns a unique identifier for this host.
func getHostID() string {
	if hostname, err := os.Hostname(); err == nil && hostname != "" {
		return hostname
	}
	return "unknown-host"
}

// getLocalIP determines the primary local IP address.
func getLocalIP(ctx context.Context) string {
	// First try to find a stable, non-docker, non-loopback IPv4
	if ip := firstUsableIPv4(); ip != "" {
		return ip
	}

	// Fall back to dial trick to determine which interface would be used
	dialer := &net.Dialer{
		Timeout: time.Second,
	}

	conn, err := dialer.DialContext(ctx, "udp", "8.8.8.8:80")
	if err != nil {
		return "unknown"
	}
	defer func() {
		_ = conn.Close()
	}()

	localAddr, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return "unknown"
	}

	return localAddr.IP.String()
}

// firstUsableIPv4 finds the first non-loopback, non-docker IPv4 address.
func firstUsableIPv4() string {
	// Docker network CIDRs to skip
	dockerCIDRs := []net.IPNet{
		{IP: net.IPv4(172, 17, 0, 0), Mask: net.CIDRMask(16, 32)},
		{IP: net.IPv4(172, 18, 0, 0), Mask: net.CIDRMask(16, 32)},
		{IP: net.IPv4(172, 19, 0, 0), Mask: net.CIDRMask(16, 32)},
	}

	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}

	for _, iface := range ifaces {
		// Skip down and loopback interfaces
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		// Skip docker/virtual interfaces by name
		name := strings.ToLower(iface.Name)
		if strings.HasPrefix(name, "docker") ||
			strings.HasPrefix(name, "br-") ||
			strings.HasPrefix(name, "veth") ||
			strings.HasPrefix(name, "virbr") {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || ipNet == nil {
				continue
			}

			ip := ipNet.IP.To4()
			if ip == nil || !ip.IsGlobalUnicast() {
				continue
			}

			// Skip docker CIDRs
			skip := false
			for _, cidr := range dockerCIDRs {
				if cidr.Contains(ip) {
					skip = true
					break
				}
			}
			if skip {
				continue
			}

			return ip.String()
		}
	}

	return ""
}
