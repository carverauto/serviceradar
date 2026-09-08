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
	"fmt"
	"net"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
)

type targetRouteSummary struct {
	ipv4Targets                   int
	ipv6Targets                   int
	ipv6TCPConnectFallbackTargets int
}

func summarizeTargetRoutes(targets []models.Target) targetRouteSummary {
	var summary targetRouteSummary

	for _, target := range targets {
		if target.Metadata == nil {
			continue
		}

		switch target.Metadata[metadataAddressFamily] {
		case addressFamilyIPv4:
			summary.ipv4Targets++
		case addressFamilyIPv6:
			summary.ipv6Targets++
		}

		if fallback, ok := target.Metadata[metadataIPv6RawSYNFallback].(bool); ok && fallback {
			summary.ipv6TCPConnectFallbackTargets++
		}
	}

	return summary
}

func scannerCapabilities(scanner scan.Scanner) scan.ScannerCapabilities {
	if provider, ok := scanner.(scan.CapabilityProvider); ok {
		return provider.Capabilities()
	}

	return scan.ScannerCapabilities{}
}

func scannerStatsAddressFamily(scanner scan.Scanner) string {
	caps := scannerCapabilities(scanner)

	if caps.RawSYNIPv4 || caps.RawSYNIPv6 {
		switch {
		case caps.RawSYNIPv4 && caps.RawSYNIPv6:
			return addressFamilyDualStack
		case caps.RawSYNIPv6:
			return addressFamilyIPv6
		default:
			return addressFamilyIPv4
		}
	}

	if caps.TCPConnectIPv4 || caps.TCPConnectIPv6 {
		switch {
		case caps.TCPConnectIPv4 && caps.TCPConnectIPv6:
			return addressFamilyDualStack
		case caps.TCPConnectIPv6:
			return addressFamilyIPv6
		default:
			return addressFamilyIPv4
		}
	}

	return addressFamilyUnknown
}

func scannerStatsPath(scanner scan.Scanner) string {
	caps := scannerCapabilities(scanner)
	if caps.RawSYNIPv4 || caps.RawSYNIPv6 {
		return scannerPathRawSYN
	}
	if caps.TCPConnectIPv4 || caps.TCPConnectIPv6 {
		return scannerPathTCPConnect
	}

	return addressFamilyUnknown
}

func (s *NetworkSweeper) rawSYNIPv6Available() bool {
	return scannerCapabilities(s.tcpScanner).RawSYNIPv6
}

func (s *NetworkSweeper) effectiveSweepModesForCIDR(cidr string, sweepModes []models.SweepMode) ([]models.SweepMode, bool, error) {
	baseIP, _, err := net.ParseCIDR(cidr)
	if err != nil {
		return nil, false, err
	}

	modes := effectiveSweepModes(baseIP.To4() == nil, sweepModes, s.rawSYNIPv6Available())

	return modes, len(modes) > 0, nil
}

func effectiveSweepModesForIPWithRawSYN(ip string, sweepModes []models.SweepMode, rawSYNIPv6Available bool) []models.SweepMode {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return sweepModes
	}

	return effectiveSweepModes(parsed.To4() == nil, sweepModes, rawSYNIPv6Available)
}

func effectiveSweepModes(ipv6 bool, sweepModes []models.SweepMode, rawSYNIPv6Available bool) []models.SweepMode {
	if !ipv6 {
		return sweepModes
	}

	modes := make([]models.SweepMode, 0, len(sweepModes))
	if containsMode(sweepModes, models.ModeICMP) {
		modes = append(modes, models.ModeICMP)
	}

	if rawSYNIPv6Available && containsMode(sweepModes, models.ModeTCP) {
		modes = append(modes, models.ModeTCP)
	}

	if containsMode(sweepModes, models.ModeTCPConnect) || (!rawSYNIPv6Available && containsMode(sweepModes, models.ModeTCP)) {
		modes = append(modes, models.ModeTCPConnect)
	}

	return modes
}

func validateCIDRExpansion(cidr string, hostCount int) error {
	baseIP, _, err := net.ParseCIDR(cidr)
	if err != nil {
		return err
	}

	if baseIP.To4() == nil && hostCount > defaultTargetBatch {
		return fmt.Errorf("%w: %s expands to %d hosts, above limit %d", errIPv6CIDRTooLarge, cidr, hostCount, defaultTargetBatch)
	}

	return nil
}

// generateTargets creates scan targets from the configuration.
func (s *NetworkSweeper) generateTargets() ([]models.Target, error) {
	var targets []models.Target

	totalHostCount := 0

	// Process legacy networks with global sweep modes (for backward compatibility)
	for _, network := range s.config.Networks {
		networkTargets, hostCount, err := s.generateTargetsForNetwork(network)
		if err != nil {
			return nil, err
		}

		targets = append(targets, networkTargets...)
		totalHostCount += hostCount
	}

	// Process device targets with per-device sweep modes (from sync service)
	for _, deviceTarget := range s.config.DeviceTargets {
		deviceTargets, hostCount := s.generateTargetsForDeviceTarget(&deviceTarget)

		targets = append(targets, deviceTargets...)
		totalHostCount += hostCount
	}

	s.logger.Info().
		Int("targetsGenerated", len(targets)).
		Int("networkCount", len(s.config.Networks)).
		Int("deviceTargetCount", len(s.config.DeviceTargets)).
		Int("totalHosts", totalHostCount).
		Ints("configuredPorts", s.config.Ports).
		Strs("globalSweepModes", func() []string {
			modes := make([]string, 0, len(s.config.SweepModes))
			for _, m := range s.config.SweepModes {
				modes = append(modes, string(m))
			}
			return modes
		}()).
		Msg("Generated targets from networks and device targets")

	return targets, nil
}

// containsMode checks if a mode is in a slice of modes.
func containsMode(modes []models.SweepMode, mode models.SweepMode) bool {
	for _, m := range modes {
		if m == mode {
			return true
		}
	}

	return false
}
