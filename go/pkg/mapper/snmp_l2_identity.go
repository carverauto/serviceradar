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

	"strconv"

	"strings"
)

func (e *DiscoveryEngine) lookupLocalDeviceID(job *DiscoveryJob, targetIP string) string {
	if job == nil {
		return ""
	}

	// Support reconciled identities where the polled target IP is stored as an
	// alternate/alias IP instead of the device primary IP.
	deviceID, _ := e.resolveExistingDeviceIdentityByIP(job, targetIP)
	return strings.TrimSpace(deviceID)
}

func (e *DiscoveryEngine) lookupKnownDeviceName(job *DiscoveryJob, targetIP string) string {
	if job == nil || job.Results == nil {
		return ""
	}

	job.mu.RLock()
	defer job.mu.RUnlock()

	targetIP = strings.TrimSpace(targetIP)
	if targetIP == "" {
		return ""
	}

	for _, device := range job.Results.Devices {
		if device == nil {
			continue
		}

		if strings.TrimSpace(device.IP) == targetIP ||
			deviceHasAlternateIP(device, targetIP) {
			return firstNonEmpty(device.Hostname, device.SysName)
		}
	}

	return ""
}

func deviceHasAlternateIP(device *DiscoveredDevice, ip string) bool {
	if device == nil || device.Metadata == nil || ip == "" {
		return false
	}

	if _, ok := device.Metadata["alt_ip:"+ip]; ok {
		return true
	}
	_, ok := device.Metadata["ip_alias:"+ip]
	return ok
}

func describeSNMPTarget(ip, hostname string) string {
	ip = strings.TrimSpace(ip)
	hostname = strings.TrimSpace(hostname)
	if hostname == "" || hostname == ip {
		return ip
	}

	return fmt.Sprintf("%s (%s)", ip, hostname)
}

func (e *DiscoveryEngine) localIPv4Subnets(job *DiscoveryJob, targetIP string) map[string]struct{} {
	subnets := make(map[string]struct{})
	addIfIPv4Subnet(subnets, targetIP)

	if job == nil || job.Results == nil {
		return subnets
	}

	job.mu.RLock()
	defer job.mu.RUnlock()

	for _, iface := range job.Results.Interfaces {
		if iface.DeviceIP != targetIP {
			continue
		}
		for _, ip := range iface.IPAddresses {
			addIfIPv4Subnet(subnets, ip)
		}
	}

	return subnets
}

func addIfIPv4Subnet(subnets map[string]struct{}, ip string) {
	parsed := net.ParseIP(strings.TrimSpace(ip))
	if parsed == nil || parsed.To4() == nil {
		return
	}

	v4 := parsed.To4()
	key := fmt.Sprintf("%d.%d.%d", v4[0], v4[1], v4[2])
	subnets[key] = struct{}{}
}

func inSubnetSet(subnets map[string]struct{}, ip string) bool {
	if len(subnets) == 0 {
		return true
	}

	parsed := net.ParseIP(strings.TrimSpace(ip))
	if parsed == nil || parsed.To4() == nil {
		return false
	}

	v4 := parsed.To4()
	key := fmt.Sprintf("%d.%d.%d", v4[0], v4[1], v4[2])
	_, exists := subnets[key]
	return exists
}

func isIPv4(ip string) bool {
	parsed := net.ParseIP(strings.TrimSpace(ip))
	return parsed != nil && parsed.To4() != nil
}

func parseIPToMediaSuffix(oidName string) (int32, string, bool) {
	parts := strings.Split(strings.TrimPrefix(oidName, "."), ".")
	baseParts := strings.Split(strings.TrimPrefix(oidIPToMediaPhys, "."), ".")
	if len(parts) < len(baseParts)+5 {
		return 0, "", false
	}

	idxOffset := len(baseParts)
	ifIndexVal, err := strconv.Atoi(parts[idxOffset])
	if err != nil || ifIndexVal <= 0 || ifIndexVal > math.MaxInt32 {
		return 0, "", false
	}

	octets := make([]string, 4)
	for i := 0; i < 4; i++ {
		octet, convErr := strconv.Atoi(parts[idxOffset+1+i])
		if convErr != nil || octet < 0 || octet > 255 {
			return 0, "", false
		}
		octets[i] = strconv.Itoa(octet)
	}

	return int32(ifIndexVal), strings.Join(octets, "."), true //nolint:gosec // G115: bounds checked above
}

func parseIPToPhysicalSuffix(oidName string) (int32, string, bool) {
	parts := strings.Split(strings.TrimPrefix(oidName, "."), ".")
	baseParts := strings.Split(strings.TrimPrefix(oidIPToPhysicalPhys, "."), ".")
	if len(parts) < len(baseParts)+3 {
		return 0, "", false
	}

	idxOffset := len(baseParts)
	ifIndexVal, err := strconv.Atoi(parts[idxOffset])
	if err != nil || ifIndexVal <= 0 || ifIndexVal > math.MaxInt32 {
		return 0, "", false
	}

	addrType, err := strconv.Atoi(parts[idxOffset+1])
	if err != nil || addrType != 1 {
		// Only support IPv4 inetAddressType.
		return 0, "", false
	}

	rest := parts[idxOffset+2:]
	switch {
	case len(rest) == 4:
		// Some agents encode IPv4 directly as 4 trailing octets.
	case len(rest) >= 5:
		// Common encoding: addrLen, then octets.
		addrLen, lenErr := strconv.Atoi(rest[0])
		if lenErr != nil || addrLen != 4 || len(rest) < 5 {
			return 0, "", false
		}
		rest = rest[1:5]
	default:
		return 0, "", false
	}

	octets := make([]string, 4)
	for i := 0; i < 4; i++ {
		octet, convErr := strconv.Atoi(rest[i])
		if convErr != nil || octet < 0 || octet > 255 {
			return 0, "", false
		}
		octets[i] = strconv.Itoa(octet)
	}

	return int32(ifIndexVal), strings.Join(octets, "."), true //nolint:gosec // G115: bounds checked above
}
