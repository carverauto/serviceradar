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

package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

// DeviceRegistry is the concrete implementation of the registry.Manager.
type DeviceRegistry struct {
	db db.Service
}

// NewDeviceRegistry creates a new, authoritative device registry.
func NewDeviceRegistry(database db.Service) *DeviceRegistry {
	return &DeviceRegistry{
		db: database,
	}
}

// ProcessSighting is the single entry point for a new device discovery event.
func (r *DeviceRegistry) ProcessSighting(ctx context.Context, sighting *models.SweepResult) error {
	return r.ProcessBatchSightings(ctx, []*models.SweepResult{sighting})
}

const (
	defaultNilHostname = "<nil>"
)

// formatHostname returns a string representation of the hostname, or "<nil>" if it's nil
func formatHostname(hostname *string) string {
	if hostname != nil {
		return *hostname
	}

	return defaultNilHostname
}

// ProcessBatchSightings processes a batch of discovery events.
func (r *DeviceRegistry) ProcessBatchSightings(ctx context.Context, sightings []*models.SweepResult) error {
	if len(sightings) == 0 {
		return nil
	}

	enrichedSightings := make([]*models.SweepResult, 0, len(sightings))

	for _, sighting := range sightings {
		// 1. Validate and normalize the incoming sighting.
		if err := r.normalizeSighting(sighting); err != nil {
			log.Printf("Skipping invalid sighting: %v", err)
			continue
		}

		// 2. Check if this IP should be mapped to an existing device
		canonicalDeviceID, err := r.findCanonicalDeviceID(ctx, sighting)

		// Handle error case
		if err != nil {
			log.Printf("Error finding canonical device for IP %s: %v. Processing as-is.", sighting.IP, err)
			enrichedSightings = append(enrichedSightings, sighting)

			continue
		}

		// Handle mapping case
		if canonicalDeviceID != "" && canonicalDeviceID != sighting.DeviceID {
			log.Printf("REGISTRY: Mapping device %s (IP: %s, hostname: %s) to canonical device %s",
				sighting.DeviceID, sighting.IP, formatHostname(sighting.Hostname), canonicalDeviceID)

			sighting.DeviceID = canonicalDeviceID
		} else {
			// No mapping needed
			log.Printf("REGISTRY: No mapping needed for device %s (IP: %s, hostname: %s)",
				sighting.DeviceID, sighting.IP, formatHostname(sighting.Hostname))
		}

		enrichedSightings = append(enrichedSightings, sighting)
	}

	// 4. Publish the enriched, authoritative results to the database.
	// The materialized view in the DB will handle the final state construction.
	if err := r.db.PublishBatchSweepResults(ctx, enrichedSightings); err != nil {
		return fmt.Errorf("failed to publish enriched sightings: %w", err)
	}

	log.Printf("Successfully processed and published %d enriched device sightings.", len(enrichedSightings))

	return nil
}

// normalizeSighting ensures a sighting has the minimum required information.
func (*DeviceRegistry) normalizeSighting(sighting *models.SweepResult) error {
	if sighting.IP == "" {
		return fmt.Errorf("sighting must have an IP address")
	}

	if sighting.Partition == "" {
		sighting.Partition = "default"
		log.Printf("Warning: sighting for IP %s has no partition, using 'default'", sighting.IP)
	}

	if sighting.DeviceID == "" {
		sighting.DeviceID = fmt.Sprintf("%s:%s", sighting.Partition, sighting.IP)
	}

	if sighting.DiscoverySource == "" {
		sighting.DiscoverySource = "unknown"
	}

	return nil
}

// findCanonicalDeviceID looks for an existing device that this sighting should be merged with
func (r *DeviceRegistry) findCanonicalDeviceID(ctx context.Context, sighting *models.SweepResult) (string, error) {
	// Strategy 1: Try to find existing devices with this IP (including alternate IPs)
	devices, err := r.db.GetUnifiedDevicesByIP(ctx, sighting.IP)
	if err != nil {
		// If the method doesn't exist or fails, try the simpler approach
		return r.findCanonicalDeviceIDSimple(ctx, sighting)
	}

	// Check if we can find a match among devices with the same IP
	deviceID, found := r.findDeviceWithMatchingIP(devices, sighting.IP)
	if found {
		return deviceID, nil
	}

	// Check if any of the sighting's alternate IPs match existing devices
	deviceID, found = r.findDeviceByAlternateIPs(ctx, sighting)
	if found {
		return deviceID, nil
	}

	// If no existing devices were found, use the simple approach as fallback
	return r.findCanonicalDeviceIDSimple(ctx, sighting)
}

// findDeviceWithMatchingIP checks if any of the provided devices has the given IP
// either as primary IP or as an alternate IP
func (*DeviceRegistry) findDeviceWithMatchingIP(devices []*models.UnifiedDevice, ip string) (string, bool) {
	if len(devices) == 0 {
		return "", false
	}

	for _, device := range devices {
		// If this device has the IP as its primary IP
		if device.IP == ip {
			log.Printf("Found existing device %s with primary IP %s", device.DeviceID, ip)
			return device.DeviceID, true
		}

		// If this device has the IP as an alternate IP
		if device.Metadata != nil && device.Metadata.Value != nil {
			alternateIPsJSON, exists := device.Metadata.Value["alternate_ips"]
			if !exists {
				continue
			}

			var alternateIPs []string

			if err := json.Unmarshal([]byte(alternateIPsJSON), &alternateIPs); err != nil {
				continue
			}

			for _, altIP := range alternateIPs {
				if altIP == ip {
					log.Printf("Found canonical device %s for IP %s via alternate IPs", device.DeviceID, ip)
					return device.DeviceID, true
				}
			}
		}
	}

	return "", false
}

// findDeviceByAlternateIPs checks if any of the sighting's alternate IPs match existing devices
func (r *DeviceRegistry) findDeviceByAlternateIPs(ctx context.Context, sighting *models.SweepResult) (string, bool) {
	sightingAlternateIPs := extractAlternateIPs(sighting.Metadata)

	// Only proceed if we have alternate IPs and a hostname
	if len(sightingAlternateIPs) == 0 || sighting.Hostname == nil || *sighting.Hostname == "" {
		return "", false
	}

	// Only enable alternate IP correlation for trusted sources
	isTrustedSource := sighting.DiscoverySource == "mapper" || sighting.DiscoverySource == "unifi-api"
	if !isTrustedSource {
		log.Printf("Skipping alternate IP correlation for untrusted source: %s", sighting.DiscoverySource)
		return "", false
	}

	// Query for devices that have any of the sighting's alternate IPs as primary
	for _, altIP := range sightingAlternateIPs {
		altDevices, err := r.db.GetUnifiedDevicesByIP(ctx, altIP)
		if err != nil || len(altDevices) == 0 {
			continue
		}

		canonicalDevice := altDevices[0]

		// Additional safety check: only correlate if hostnames match
		if canonicalDevice.Hostname == nil || canonicalDevice.Hostname.Value != *sighting.Hostname {
			log.Printf("Skipping correlation between %s and %s via IP %s - hostname mismatch (%s vs %s)",
				sighting.DeviceID, canonicalDevice.DeviceID, altIP,
				func() string {
					if sighting.Hostname != nil {
						return *sighting.Hostname
					}
					return defaultNilHostname
				}(),
				func() string {
					if canonicalDevice.Hostname != nil {
						return canonicalDevice.Hostname.Value
					}
					return defaultNilHostname
				}())

			continue
		}

		log.Printf("Found existing device %s for sighting %s via alternate IP %s (hostname match: %s)",
			canonicalDevice.DeviceID, sighting.DeviceID, altIP, *sighting.Hostname)

		return canonicalDevice.DeviceID, true
	}

	return "", false
}

// findCanonicalDeviceIDSimple provides a fallback method when the advanced DB methods aren't available
func (*DeviceRegistry) findCanonicalDeviceIDSimple(_ context.Context, sighting *models.SweepResult) (string, error) {
	// Use a deterministic approach: prefer the lowest IP address (lexicographically)
	// from all known IPs (primary + alternates) to form the canonical device ID.
	// This avoids the problematic public/private bias that can cause incorrect merges.
	// Collect all IPs for this device
	allIPs := make([]string, 0)
	allIPs = append(allIPs, sighting.IP)

	// Add alternate IPs from metadata
	alternateIPs := extractAlternateIPs(sighting.Metadata)
	allIPs = append(allIPs, alternateIPs...)

	// Find the lowest IP address to use as canonical
	if len(allIPs) > 0 {
		lowestIP := allIPs[0]

		for _, ip := range allIPs[1:] {
			if ip < lowestIP {
				lowestIP = ip
			}
		}

		// If the lowest IP is different from the sighting's IP, suggest remapping
		if lowestIP != sighting.IP {
			candidateDeviceID := fmt.Sprintf("%s:%s", sighting.Partition, lowestIP)
			hostname := "<no hostname>"

			if sighting.Hostname != nil {
				hostname = *sighting.Hostname
			}

			log.Printf("Found potential canonical device %s for %s (hostname: %s) - using lowest IP %s",
				candidateDeviceID, sighting.DeviceID, hostname, lowestIP)

			return candidateDeviceID, nil
		}
	}

	return "", nil
}

// isPrivateIP checks if an IP address is in a private range
func isPrivateIP(ip string) bool {
	// Check for 192.168.x.x
	if strings.HasPrefix(ip, "192.168.") {
		return true
	}

	// Check for 10.x.x.x
	if strings.HasPrefix(ip, "10.") {
		return true
	}

	// Check for 172.16.x.x through 172.31.x.x
	if strings.HasPrefix(ip, "172.") {
		return isPrivate172Range(ip)
	}

	return false
}

// isPrivate172Range checks if an IP starting with "172." is in the private range (172.16.x.x through 172.31.x.x)
func isPrivate172Range(ip string) bool {
	parts := strings.Split(ip, ".")
	if len(parts) <= 1 {
		return false
	}

	secondOctet, err := strconv.Atoi(parts[1])
	if err != nil {
		return false
	}

	// Check if it's in the private IP range (16-31)
	return secondOctet >= 16 && secondOctet <= 31
}

// extractAlternateIPs is a helper to parse alternate IPs from metadata.
func extractAlternateIPs(metadata map[string]string) []string {
	if metadata == nil {
		return nil
	}

	const key = "alternate_ips"
	existing, ok := metadata[key]

	if !ok || existing == "" {
		return nil
	}

	var ips []string

	if err := json.Unmarshal([]byte(existing), &ips); err == nil {
		return ips
	}

	// Fallback for non-JSON format
	return strings.Split(existing, ",")
}

// Legacy compatibility methods for transition period

// ProcessSweepResult is an alias for ProcessSighting for backward compatibility
func (r *DeviceRegistry) ProcessSweepResult(ctx context.Context, result *models.SweepResult) error {
	return r.ProcessSighting(ctx, result)
}

// ProcessBatchSweepResults is an alias for ProcessBatchSightings for backward compatibility
func (r *DeviceRegistry) ProcessBatchSweepResults(ctx context.Context, results []*models.SweepResult) error {
	return r.ProcessBatchSightings(ctx, results)
}

// UpdateDevice processes a device update by converting it to a SweepResult
func (r *DeviceRegistry) UpdateDevice(ctx context.Context, update *models.DeviceUpdate) error {
	// Convert DeviceUpdate to SweepResult format
	sweepResult := &models.SweepResult{
		DeviceID:        update.DeviceID,
		IP:              update.IP,
		Partition:       extractPartitionFromDeviceID(update.DeviceID),
		DiscoverySource: string(update.Source),
		AgentID:         update.AgentID,
		PollerID:        update.PollerID,
		Timestamp:       update.Timestamp,
		Available:       update.IsAvailable,
		Metadata:        update.Metadata,
	}

	if update.Hostname != nil {
		if sweepResult.Metadata == nil {
			sweepResult.Metadata = make(map[string]string)
		}

		sweepResult.Metadata["hostname"] = *update.Hostname
	}

	if update.MAC != nil {
		if sweepResult.Metadata == nil {
			sweepResult.Metadata = make(map[string]string)
		}

		sweepResult.Metadata["mac"] = *update.MAC
	}

	return r.ProcessSighting(ctx, sweepResult)
}

// GetDevice retrieves a unified device by its device ID
func (r *DeviceRegistry) GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, nil, []string{deviceID})
	if err != nil {
		return nil, fmt.Errorf("failed to get device %s: %w", deviceID, err)
	}

	if len(devices) == 0 {
		return nil, fmt.Errorf("device %s not found", deviceID)
	}

	return devices[0], nil
}

// GetDevicesByIP retrieves all unified devices that have the given IP
func (r *DeviceRegistry) GetDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, []string{ip}, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to get devices by IP %s: %w", ip, err)
	}

	return devices, nil
}

// ListDevices retrieves a paginated list of unified devices
func (r *DeviceRegistry) ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	// For now, implement a basic version that queries the database
	// This will need to be enhanced with proper pagination support in the db layer
	devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, nil, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to list devices: %w", err)
	}

	// Apply pagination
	start := offset
	if start >= len(devices) {
		return []*models.UnifiedDevice{}, nil
	}

	end := start + limit
	if end > len(devices) {
		end = len(devices)
	}

	return devices[start:end], nil
}

// extractPartitionFromDeviceID extracts the partition from a device ID formatted as "partition:ip"
func extractPartitionFromDeviceID(deviceID string) string {
	parts := strings.Split(deviceID, ":")
	if len(parts) >= 2 {
		return parts[0]
	}

	return "default"
}

// addRelatedDevicesByAlternateIPs adds devices related by alternate IPs to the relatedDevicesMap
func (r *DeviceRegistry) addRelatedDevicesByAlternateIPs(
	ctx context.Context,
	device *models.UnifiedDevice,
	deviceID string,
	relatedDevicesMap map[string]*models.UnifiedDevice) {
	alternateIPs := r.getAlternateIPsFromMetadata(device)
	for _, ip := range alternateIPs {
		r.addDevicesWithIPToMap(ctx, ip, deviceID, relatedDevicesMap)
	}
}

// getAlternateIPsFromMetadata extracts alternate IPs from device metadata
func (*DeviceRegistry) getAlternateIPsFromMetadata(device *models.UnifiedDevice) []string {
	if device.Metadata == nil || device.Metadata.Value == nil {
		return nil
	}

	alternateIPsJSON, ok := device.Metadata.Value["alternate_ips"]
	if !ok {
		return nil
	}

	var alternateIPs []string
	if err := json.Unmarshal([]byte(alternateIPsJSON), &alternateIPs); err != nil {
		log.Printf("Warning: failed to unmarshal alternate IPs: %v", err)
		return nil
	}

	return alternateIPs
}

// addDevicesWithIPToMap adds devices with the given IP to the relatedDevicesMap
func (r *DeviceRegistry) addDevicesWithIPToMap(
	ctx context.Context, ip, excludeDeviceID string, relatedDevicesMap map[string]*models.UnifiedDevice) {
	devices, err := r.GetDevicesByIP(ctx, ip)
	if err != nil {
		log.Printf("Warning: failed to get devices by alternate IP %s: %v", ip, err)
		return
	}

	for _, d := range devices {
		if d.DeviceID != excludeDeviceID {
			relatedDevicesMap[d.DeviceID] = d
		}
	}
}

// GetMergedDevice retrieves a device by device ID or IP, returning the merged/unified view
func (r *DeviceRegistry) GetMergedDevice(ctx context.Context, deviceIDOrIP string) (*models.UnifiedDevice, error) {
	// First try as device ID
	device, err := r.GetDevice(ctx, deviceIDOrIP)
	if err == nil {
		return device, nil
	}

	// If that fails, try as IP address
	devices, err := r.GetDevicesByIP(ctx, deviceIDOrIP)
	if err != nil {
		return nil, fmt.Errorf("failed to get device by ID or IP %s: %w", deviceIDOrIP, err)
	}

	if len(devices) == 0 {
		return nil, fmt.Errorf("device %s not found", deviceIDOrIP)
	}

	// Return the first device (if multiple found, they should be duplicates that need merging)
	return devices[0], nil
}

// FindRelatedDevices finds all devices that are related to the given device ID
func (r *DeviceRegistry) FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.UnifiedDevice, error) {
	// Get the primary device
	device, err := r.GetDevice(ctx, deviceID)
	if err != nil {
		return nil, fmt.Errorf("failed to get primary device %s: %w", deviceID, err)
	}

	// Get all devices with any of the same IPs
	relatedDevicesMap := make(map[string]*models.UnifiedDevice)

	// Check primary IP
	devices, err := r.GetDevicesByIP(ctx, device.IP)
	if err != nil {
		return nil, fmt.Errorf("failed to get devices by primary IP %s: %w", device.IP, err)
	}

	for _, d := range devices {
		if d.DeviceID != deviceID {
			relatedDevicesMap[d.DeviceID] = d
		}
	}

	// Check alternate IPs if available in metadata
	r.addRelatedDevicesByAlternateIPs(ctx, device, deviceID, relatedDevicesMap)

	// Convert map to slice
	relatedDevices := make([]*models.UnifiedDevice, 0, len(relatedDevicesMap))
	for _, device := range relatedDevicesMap {
		relatedDevices = append(relatedDevices, device)
	}

	return relatedDevices, nil
}
