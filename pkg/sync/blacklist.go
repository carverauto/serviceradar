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

package sync

import (
	"fmt"
	"net"
	"strings"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// NetworkBlacklist manages a list of CIDR ranges to filter out discovered devices
type NetworkBlacklist struct {
	networks []*net.IPNet
	logger   logger.Logger
}

// NewNetworkBlacklist creates a new NetworkBlacklist from a list of CIDR strings
func NewNetworkBlacklist(cidrs []string, log logger.Logger) (*NetworkBlacklist, error) {
	nb := &NetworkBlacklist{
		networks: make([]*net.IPNet, 0, len(cidrs)),
		logger:   log,
	}

	for _, cidr := range cidrs {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR %s: %w", cidr, err)
		}

		nb.networks = append(nb.networks, network)

		log.Info().Str("cidr", cidr).Msg("Added network to blacklist")
	}

	return nb, nil
}

// IsBlacklisted checks if an IP address falls within any of the blacklisted ranges
func (nb *NetworkBlacklist) IsBlacklisted(ip string) bool {
	parsedIP := net.ParseIP(ip)
	if parsedIP == nil {
		nb.logger.Debug().Str("ip", ip).Msg("Failed to parse IP address")

		return false
	}

	for _, network := range nb.networks {
		if network.Contains(parsedIP) {
			nb.logger.Debug().
				Str("ip", ip).
				Str("network", network.String()).
				Msg("IP is in blacklisted network")

			return true
		}
	}

	return false
}

// FilterDevices filters out devices whose IPs fall within blacklisted ranges
func (nb *NetworkBlacklist) FilterDevices(devices []*models.DeviceUpdate) []*models.DeviceUpdate {
	if len(nb.networks) == 0 {
		return devices
	}

	filtered := make([]*models.DeviceUpdate, 0, len(devices))

	blacklistedCount := 0

	for _, device := range devices {
		if device.IP == "" {
			// Keep devices without IP addresses
			filtered = append(filtered, device)

			continue
		}

		if nb.IsBlacklisted(device.IP) {
			blacklistedCount++

			nb.logger.Debug().
				Str("ip", device.IP).
				Str("source", string(device.Source)).
				Msg("Filtering out blacklisted device")

			continue
		}

		filtered = append(filtered, device)
	}

	if blacklistedCount > 0 {
		nb.logger.Info().
			Int("filtered_count", blacklistedCount).
			Int("original_count", len(devices)).
			Int("remaining_count", len(filtered)).
			Msg("Filtered devices based on network blacklist")
	}

	return filtered
}

// FilterKVData filters out KV entries whose keys contain blacklisted IP addresses
func (nb *NetworkBlacklist) FilterKVData(kvData map[string][]byte, devices []*models.DeviceUpdate) map[string][]byte {
	if len(nb.networks) == 0 || len(kvData) == 0 {
		return kvData
	}

	// Create a set of allowed IPs from the filtered devices
	allowedIPs := make(map[string]bool, len(devices))

	for _, device := range devices {
		if device.IP != "" {
			allowedIPs[device.IP] = true
		}
	}

	filtered := make(map[string][]byte)
	blacklistedCount := 0

	for key, value := range kvData {
		// Check if key contains an IP address pattern (e.g., "agentID/192.168.1.1")
		// Keys can be in format "deviceID" or "agentID/IP"
		parts := strings.Split(key, "/")

		if len(parts) == 2 {
			ip := parts[1]

			if nb.IsBlacklisted(ip) || !allowedIPs[ip] {
				blacklistedCount++

				nb.logger.Debug().
					Str("key", key).
					Str("ip", ip).
					Msg("Filtering out blacklisted KV entry")

				continue
			}
		}

		// Keep entries that don't follow the agentID/IP pattern or are not blacklisted
		filtered[key] = value
	}

	if blacklistedCount > 0 {
		nb.logger.Info().
			Int("filtered_count", blacklistedCount).
			Int("original_count", len(kvData)).
			Int("remaining_count", len(filtered)).
			Msg("Filtered KV data based on network blacklist")
	}

	return filtered
}

// FilterIPAddresses filters out IP addresses that fall within blacklisted ranges
func (nb *NetworkBlacklist) FilterIPAddresses(ips []string) []string {
	if len(nb.networks) == 0 {
		return ips
	}

	filtered := make([]string, 0, len(ips))
	blacklistedCount := 0

	for _, ip := range ips {
		if nb.IsBlacklisted(ip) {
			blacklistedCount++
			nb.logger.Debug().
				Str("ip", ip).
				Msg("Filtering out blacklisted IP address")
			continue
		}
		filtered = append(filtered, ip)
	}

	if blacklistedCount > 0 {
		nb.logger.Info().
			Int("filtered_count", blacklistedCount).
			Int("original_count", len(ips)).
			Int("remaining_count", len(filtered)).
			Msg("Filtered IP addresses based on network blacklist")
	}

	return filtered
}
