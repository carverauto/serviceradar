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

package sweeper

import (
	"net"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
)

func forEachCIDRHost(cidr string, fn func(string) error) (int, error) {
	baseIP, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return 0, err
	}

	ones, _ := ipNet.Mask.Size()
	currentIP := append(net.IP(nil), baseIP.Mask(ipNet.Mask)...)
	count := 0

	for ; ipNet.Contains(currentIP); incCIDRIP(currentIP) {
		if currentIP.To4() != nil && ones != 32 {
			if currentIP.Equal(ipNet.IP) || isCIDRBroadcast(currentIP, ipNet) {
				continue
			}
		}

		if err := fn(currentIP.String()); err != nil {
			return count, err
		}

		count++
	}

	return count, nil
}

func incCIDRIP(ip net.IP) {
	for i := len(ip) - 1; i >= 0; i-- {
		ip[i]++
		if ip[i] != 0 {
			break
		}
	}
}

func isCIDRBroadcast(ip net.IP, ipNet *net.IPNet) bool {
	broadcast := make(net.IP, len(ip))
	for i := range ip {
		broadcast[i] = ipNet.IP[i] | ^ipNet.Mask[i]
	}

	return ip.Equal(broadcast)
}

// createTargetsForIP creates targets for a specific IP using the given sweep modes
func (s *NetworkSweeper) createTargetsForIP(ip string, sweepModes []models.SweepMode, metadata map[string]interface{}) []models.Target {
	var targets []models.Target

	_ = s.emitTargetsForIP(ip, sweepModes, metadata, func(target models.Target) error {
		targets = append(targets, target)
		return nil
	})

	return targets
}

func (s *NetworkSweeper) emitTargetsForIP(
	ip string,
	sweepModes []models.SweepMode,
	metadata map[string]interface{},
	emit func(models.Target) error,
) error {
	requestedModes := sweepModes
	rawSYNIPv6Available := s.rawSYNIPv6Available()
	effectiveModes := effectiveSweepModesForIPWithRawSYN(ip, requestedModes, rawSYNIPv6Available)

	if containsMode(effectiveModes, models.ModeICMP) {
		target := scan.TargetFromIP(ip, models.ModeICMP)
		target.Metadata = metadataForTarget(metadata, ip, requestedModes, models.ModeICMP, rawSYNIPv6Available)
		if err := emit(target); err != nil {
			return err
		}
	}

	if containsMode(effectiveModes, models.ModeTCP) {
		for _, port := range s.config.Ports {
			target := scan.TargetFromIP(ip, models.ModeTCP, port)
			target.Metadata = metadataForTarget(metadata, ip, requestedModes, models.ModeTCP, rawSYNIPv6Available)
			if err := emit(target); err != nil {
				return err
			}
		}
	}

	if containsMode(effectiveModes, models.ModeTCPConnect) {
		for _, port := range s.config.Ports {
			target := scan.TargetFromIP(ip, models.ModeTCPConnect, port)
			target.Metadata = metadataForTarget(metadata, ip, requestedModes, models.ModeTCPConnect, rawSYNIPv6Available)
			if err := emit(target); err != nil {
				return err
			}
		}
	}

	return nil
}

func metadataForTarget(
	base map[string]interface{},
	ip string,
	requestedModes []models.SweepMode,
	effectiveMode models.SweepMode,
	rawSYNIPv6Available bool,
) map[string]interface{} {
	metadata := make(map[string]interface{}, len(base)+6)
	for key, value := range base {
		metadata[key] = value
	}

	addressFamily := addressFamilyIPv4
	if isIPv6String(ip) {
		addressFamily = addressFamilyIPv6
	}

	requestedMode := effectiveMode
	ipv6TCPFallback := false

	if addressFamily == addressFamilyIPv6 &&
		effectiveMode == models.ModeTCPConnect &&
		containsMode(requestedModes, models.ModeTCP) &&
		(!rawSYNIPv6Available || !containsMode(requestedModes, models.ModeTCPConnect)) {
		requestedMode = models.ModeTCP
		ipv6TCPFallback = true
	}

	scannerPath := string(effectiveMode)
	if ipv6TCPFallback {
		scannerPath = scannerPathTCPConnectIPv6SYN
	}

	metadata[metadataAddressFamily] = addressFamily
	metadata["requested_sweep_modes"] = sweepModeStrings(requestedModes)
	metadata["requested_sweep_mode"] = string(requestedMode)
	metadata["effective_sweep_mode"] = string(effectiveMode)
	metadata["scanner_path"] = scannerPath
	metadata[metadataIPv6RawSYNFallback] = ipv6TCPFallback

	return metadata
}

func sweepModeStrings(modes []models.SweepMode) []string {
	strings := make([]string, 0, len(modes))
	for _, mode := range modes {
		strings = append(strings, string(mode))
	}

	return strings
}

func isIPv6String(ip string) bool {
	parsed := net.ParseIP(ip)
	return parsed != nil && parsed.To4() == nil
}
