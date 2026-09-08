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

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
)

func (s *NetworkSweeper) generateTargetsForNetwork(network string) ([]models.Target, int, error) {
	_, supported, err := s.effectiveSweepModesForCIDR(network, s.config.SweepModes)
	if err != nil {
		return nil, 0, err
	}
	if !supported {
		return nil, 0, nil
	}

	hostCount, err := countCIDRHosts(network)
	if err != nil {
		return nil, 0, err
	}
	if err := validateCIDRExpansion(network, hostCount); err != nil {
		return nil, 0, err
	}

	ips, err := scan.ExpandCIDR(network)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to expand CIDR %s: %w", network, err)
	}

	var targets []models.Target

	metadata := map[string]interface{}{
		"network":     network,
		"total_hosts": len(ips),
		"source":      "legacy_networks",
	}

	for _, ip := range ips {
		targets = append(targets, s.createTargetsForIP(ip, s.config.SweepModes, metadata)...)
	}

	return targets, len(ips), nil
}

// generateTargetsForDeviceTarget creates targets for a device target configuration
func (s *NetworkSweeper) generateTargetsForDeviceTarget(deviceTarget *models.DeviceTarget) (targets []models.Target, hostCount int) {
	// Use device-specific sweep modes if available, otherwise fall back to global
	sweepModes := deviceTarget.SweepModes
	if len(sweepModes) == 0 {
		s.logger.Debug().
			Str("device", deviceTarget.Network).
			Msg("Device target has no sweep modes, using global config")

		sweepModes = s.config.SweepModes
	}

	effectiveModes, supported, err := s.effectiveSweepModesForCIDR(deviceTarget.Network, sweepModes)
	if err != nil {
		s.logger.Warn().
			Err(err).
			Str("network", deviceTarget.Network).
			Str("query_label", deviceTarget.QueryLabel).
			Msg("Failed to classify device target IP family, skipping")

		return targets, hostCount
	}
	if !supported {
		return targets, hostCount
	}

	estimatedHostCount, err := countCIDRHosts(deviceTarget.Network)
	if err != nil {
		s.logger.Warn().
			Err(err).
			Str("network", deviceTarget.Network).
			Str("query_label", deviceTarget.QueryLabel).
			Msg("Failed to count device target CIDR, skipping")

		return targets, hostCount
	}
	if err := validateCIDRExpansion(deviceTarget.Network, estimatedHostCount); err != nil {
		s.logger.Warn().
			Err(err).
			Str("network", deviceTarget.Network).
			Str("query_label", deviceTarget.QueryLabel).
			Msg("Device target CIDR is too broad for sweep expansion, skipping")

		return targets, hostCount
	}

	// Always expand and use the primary network (e.g., a single /32).
	// We intentionally ignore any additional IP lists in metadata (e.g., "all_ips").
	ips, err := scan.ExpandCIDR(deviceTarget.Network)
	if err != nil {
		s.logger.Warn().
			Err(err).
			Str("network", deviceTarget.Network).
			Str("query_label", deviceTarget.QueryLabel).
			Msg("Failed to expand device target CIDR, skipping")

		return targets, hostCount
	}

	targetIPs := ips

	metadata := map[string]interface{}{
		"network":     deviceTarget.Network,
		"total_hosts": len(targetIPs),
		"source":      deviceTarget.Source,
		"query_label": deviceTarget.QueryLabel,
	}

	// Add device target metadata to the scan metadata (for tracking only)
	for k, v := range deviceTarget.Metadata {
		metadata[k] = v
	}

	s.logger.Debug().
		Str("device", deviceTarget.Network).
		Strs("sweep_modes", func() []string {
			modes := make([]string, 0, len(effectiveModes))
			for _, m := range effectiveModes {
				modes = append(modes, string(m))
			}
			return modes
		}()).
		Int("ip_count", len(targetIPs)).
		Int("port_count", len(s.config.Ports)).
		Msg("Generating targets for device")

	for _, ip := range targetIPs {
		targets = append(targets, s.createTargetsForIP(ip, sweepModes, metadata)...)
	}

	hostCount = len(targetIPs)

	return targets, hostCount
}

func (s *NetworkSweeper) generateTargetsBatched(consume func(models.Target) error) error {
	totalHostCount := 0

	for _, network := range s.config.Networks {
		_, supported, err := s.effectiveSweepModesForCIDR(network, s.config.SweepModes)
		if err != nil {
			return fmt.Errorf("failed to parse CIDR %s: %w", network, err)
		}
		if !supported {
			continue
		}

		hostCount, err := countCIDRHosts(network)
		if err != nil {
			return fmt.Errorf("failed to parse CIDR %s: %w", network, err)
		}
		if err := validateCIDRExpansion(network, hostCount); err != nil {
			return err
		}

		metadata := map[string]interface{}{
			"network":     network,
			"total_hosts": hostCount,
			"source":      "legacy_networks",
		}

		visited, err := forEachCIDRHost(network, func(ip string) error {
			return s.emitTargetsForIP(ip, s.config.SweepModes, metadata, consume)
		})
		if err != nil {
			return fmt.Errorf("failed to generate targets for CIDR %s: %w", network, err)
		}

		totalHostCount += visited
	}

	for _, deviceTarget := range s.config.DeviceTargets {
		hostCount, err := countCIDRHosts(deviceTarget.Network)
		if err != nil {
			s.logger.Warn().
				Err(err).
				Str("network", deviceTarget.Network).
				Str("query_label", deviceTarget.QueryLabel).
				Msg("Failed to parse device target CIDR, skipping")

			continue
		}

		metadata := map[string]interface{}{
			"network":     deviceTarget.Network,
			"total_hosts": hostCount,
			"source":      deviceTarget.Source,
			"query_label": deviceTarget.QueryLabel,
		}

		for k, v := range deviceTarget.Metadata {
			metadata[k] = v
		}

		sweepModes := deviceTarget.SweepModes
		if len(sweepModes) == 0 {
			s.logger.Debug().
				Str("device", deviceTarget.Network).
				Msg("Device target has no sweep modes, using global config")

			sweepModes = s.config.SweepModes
		}

		_, supported, err := s.effectiveSweepModesForCIDR(deviceTarget.Network, sweepModes)
		if err != nil {
			return fmt.Errorf("failed to parse device CIDR %s: %w", deviceTarget.Network, err)
		}
		if !supported {
			continue
		}
		if err := validateCIDRExpansion(deviceTarget.Network, hostCount); err != nil {
			return err
		}

		visited, err := forEachCIDRHost(deviceTarget.Network, func(ip string) error {
			return s.emitTargetsForIP(ip, sweepModes, metadata, consume)
		})
		if err != nil {
			return fmt.Errorf("failed to generate targets for device CIDR %s: %w", deviceTarget.Network, err)
		}

		totalHostCount += visited
	}

	s.logger.Info().
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
		Msg("Generated batched targets from networks and device targets")

	return nil
}
