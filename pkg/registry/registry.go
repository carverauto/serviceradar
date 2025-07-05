package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
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
		if err != nil {
			log.Printf("Error finding canonical device for IP %s: %v. Processing as-is.", sighting.IP, err)
		} else if canonicalDeviceID != "" && canonicalDeviceID != sighting.DeviceID {
			log.Printf("REGISTRY: Mapping device %s (IP: %s, hostname: %s) to canonical device %s", 
				sighting.DeviceID, sighting.IP, 
				func() string { if sighting.Hostname != nil { return *sighting.Hostname } else { return "<nil>" } }(), 
				canonicalDeviceID)
			sighting.DeviceID = canonicalDeviceID
		} else {
			log.Printf("REGISTRY: No mapping needed for device %s (IP: %s, hostname: %s)", 
				sighting.DeviceID, sighting.IP, 
				func() string { if sighting.Hostname != nil { return *sighting.Hostname } else { return "<nil>" } }())
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
func (r *DeviceRegistry) normalizeSighting(sighting *models.SweepResult) error {
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

// findRelatedDevices queries the DB to find all devices related to the sighting by any IP address.
// It returns the chosen canonical device, any other related devices, and an error.
func (r *DeviceRegistry) findRelatedDevices(ctx context.Context, sighting *models.SweepResult) (canonical *models.UnifiedDevice, duplicates []*models.UnifiedDevice, err error) {
	// Collect all IPs from the incoming sighting to check against the database.
	ipsToCheck := make(map[string]struct{})
	ipsToCheck[sighting.IP] = struct{}{}
	for _, ip := range extractAlternateIPs(sighting.Metadata) {
		ipsToCheck[ip] = struct{}{}
	}

	ipSlice := make([]string, 0, len(ipsToCheck))
	for ip := range ipsToCheck {
		ipSlice = append(ipSlice, ip)
	}

	// Query the DB for devices matching any of the IPs or the DeviceID.
	existingDevices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, ipSlice, []string{sighting.DeviceID})
	if err != nil {
		return nil, nil, fmt.Errorf("failed to query devices by IPs/ID: %w", err)
	}

	if len(existingDevices) == 0 {
		return nil, nil, nil // No existing device, this is a new one.
	}

	// Determine the canonical device. Rule: oldest device wins. This is stable.
	canonical = existingDevices[0]
	for _, device := range existingDevices[1:] {
		if device.FirstSeen.Before(canonical.FirstSeen) {
			canonical = device
		}
	}

	// All other devices are duplicates that will be merged.
	for _, device := range existingDevices {
		if device.DeviceID != canonical.DeviceID {
			duplicates = append(duplicates, device)
		}
	}

	return canonical, duplicates, nil
}

// enrichSighting merges data from the sighting and all related devices into one authoritative record.
func (r *DeviceRegistry) enrichSighting(sighting *models.SweepResult, canonical *models.UnifiedDevice, duplicates []*models.UnifiedDevice) *models.SweepResult {
	// If no existing device was found, the sighting is already what we need.
	if canonical == nil {
		return sighting
	}

	log.Printf("Merging sighting for IP %s into canonical device %s", sighting.IP, canonical.DeviceID)

	// The sighting's DeviceID MUST be set to the canonical ID. This is the key to the merge.
	sighting.DeviceID = canonical.DeviceID

	// Create a comprehensive set of all data points.
	allIPs := make(map[string]struct{})
	allSources := make(map[string]struct{})
	mergedMeta := make(map[string]string)

	// Helper to merge metadata, giving preference to newer (sighting) values.
	merge := func(meta map[string]string) {
		for k, v := range meta {
			if _, exists := mergedMeta[k]; !exists {
				mergedMeta[k] = v
			}
		}
	}

	// 1. Add data from the canonical device.
	allIPs[canonical.IP] = struct{}{}
	for _, sourceInfo := range canonical.DiscoverySources {
		allSources[string(sourceInfo.Source)] = struct{}{}
	}
	if canonical.Metadata != nil && canonical.Metadata.Value != nil {
		merge(canonical.Metadata.Value)
	}

	// 2. Add data from all duplicate devices.
	for _, dupe := range duplicates {
		allIPs[dupe.IP] = struct{}{}
		for _, sourceInfo := range dupe.DiscoverySources {
			allSources[string(sourceInfo.Source)] = struct{}{}
		}
		if dupe.Metadata != nil && dupe.Metadata.Value != nil {
			merge(dupe.Metadata.Value)
		}
	}

	// 3. Add data from the new sighting (overwrites older metadata).
	allIPs[sighting.IP] = struct{}{}
	allSources[sighting.DiscoverySource] = struct{}{}
	if sighting.Metadata != nil {
		for k, v := range sighting.Metadata {
			mergedMeta[k] = v
		}
	}

	// Re-add IPs from sighting's original metadata, in case they weren't in the DB yet
	for _, ip := range extractAlternateIPs(sighting.Metadata) {
		allIPs[ip] = struct{}{}
	}

	// 4. Construct the final metadata for the enriched sighting.
	// The primary IP of the sighting remains what it was, but all others go into alternates.
	alternateIPs := make([]string, 0, len(allIPs)-1)
	for ip := range allIPs {
		if ip != sighting.IP {
			alternateIPs = append(alternateIPs, ip)
		}
	}

	if len(alternateIPs) > 0 {
		altIPsJSON, err := json.Marshal(alternateIPs)
		if err == nil {
			mergedMeta["alternate_ips"] = string(altIPsJSON)
		}
	} else {
		delete(mergedMeta, "alternate_ips")
	}

	// Also add a list of all sources for context.
	sourceList := make([]string, 0, len(allSources))
	for src := range allSources {
		sourceList = append(sourceList, src)
	}
	allSourcesJSON, err := json.Marshal(sourceList)
	if err == nil {
		mergedMeta["all_discovery_sources"] = string(allSourcesJSON)
	}

	sighting.Metadata = mergedMeta

	return sighting
}

// findCanonicalDeviceID looks for an existing device that this sighting should be merged with
func (r *DeviceRegistry) findCanonicalDeviceID(ctx context.Context, sighting *models.SweepResult) (string, error) {
	// Strategy 1: Try to find existing devices with this IP (including alternate IPs)
	devices, err := r.db.GetUnifiedDevicesByIP(ctx, sighting.IP)
	if err != nil {
		// If the method doesn't exist or fails, try the simpler approach
		return r.findCanonicalDeviceIDSimple(ctx, sighting)
	}

	// If we found devices, determine which should be canonical
	if len(devices) > 0 {
		for _, device := range devices {
			// If this device has the sighting IP as its primary IP, check if it should remain canonical
			if device.IP == sighting.IP {
				log.Printf("Found existing device %s with primary IP %s", device.DeviceID, sighting.IP)
				return device.DeviceID, nil
			}
			
			// If this device has the sighting IP as an alternate IP, this device should be canonical
			if device.Metadata != nil && device.Metadata.Value != nil {
				alternateIPsJSON, exists := device.Metadata.Value["alternate_ips"]
				if exists {
					var alternateIPs []string
					if err := json.Unmarshal([]byte(alternateIPsJSON), &alternateIPs); err == nil {
						for _, altIP := range alternateIPs {
							if altIP == sighting.IP {
								log.Printf("Found canonical device %s for IP %s via alternate IPs", device.DeviceID, sighting.IP)
								return device.DeviceID, nil
							}
						}
					}
				}
			}
		}
	}
	
	// Also check if any of the sighting's alternate IPs match existing devices
	// Only enable this for trusted discovery sources and with hostname matching
	sightingAlternateIPs := extractAlternateIPs(sighting.Metadata)
	if len(sightingAlternateIPs) > 0 && sighting.Hostname != nil && *sighting.Hostname != "" {
		// Only enable alternate IP correlation for trusted sources
		isTrustedSource := sighting.DiscoverySource == "mapper" || sighting.DiscoverySource == "unifi-api"
		if !isTrustedSource {
			log.Printf("Skipping alternate IP correlation for untrusted source: %s", sighting.DiscoverySource)
		} else {
			// Query for devices that have any of the sighting's alternate IPs as primary
			for _, altIP := range sightingAlternateIPs {
				// Skip common gateway/router IPs that could cause false correlations
				if isCommonGatewayIP(altIP) {
					log.Printf("Skipping common gateway IP %s for correlation", altIP)
					continue
				}
				
				altDevices, err := r.db.GetUnifiedDevicesByIP(ctx, altIP)
				if err == nil && len(altDevices) > 0 {
					canonicalDevice := altDevices[0]
					
					// Additional safety check: only correlate if hostnames match
					if canonicalDevice.Hostname != nil && canonicalDevice.Hostname.Value == *sighting.Hostname {
						log.Printf("Found existing device %s for sighting %s via alternate IP %s (hostname match: %s)", 
							canonicalDevice.DeviceID, sighting.DeviceID, altIP, *sighting.Hostname)
						return canonicalDevice.DeviceID, nil
					} else {
						log.Printf("Skipping correlation between %s and %s via IP %s - hostname mismatch (%s vs %s)", 
							sighting.DeviceID, canonicalDevice.DeviceID, altIP,
							func() string { if sighting.Hostname != nil { return *sighting.Hostname } else { return "<nil>" } }(),
							func() string { if canonicalDevice.Hostname != nil { return canonicalDevice.Hostname.Value } else { return "<nil>" } }())
					}
				}
			}
		}
	}

	// If no existing devices were found, use the simple approach as fallback
	return r.findCanonicalDeviceIDSimple(ctx, sighting)
}

// findCanonicalDeviceIDSimple provides a fallback method when the advanced DB methods aren't available
func (r *DeviceRegistry) findCanonicalDeviceIDSimple(ctx context.Context, sighting *models.SweepResult) (string, error) {
	// Only enable simple correlation for trusted discovery sources to avoid false correlations
	isTrustedSource := sighting.DiscoverySource == "mapper" || sighting.DiscoverySource == "unifi-api"
	if !isTrustedSource {
		log.Printf("Skipping simple correlation for untrusted source: %s", sighting.DiscoverySource)
		return "", nil
	}
	
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
	return strings.HasPrefix(ip, "192.168.") || 
		   strings.HasPrefix(ip, "10.") || 
		   strings.HasPrefix(ip, "172.16.") ||
		   strings.HasPrefix(ip, "172.17.") ||
		   strings.HasPrefix(ip, "172.18.") ||
		   strings.HasPrefix(ip, "172.19.") ||
		   strings.HasPrefix(ip, "172.20.") ||
		   strings.HasPrefix(ip, "172.21.") ||
		   strings.HasPrefix(ip, "172.22.") ||
		   strings.HasPrefix(ip, "172.23.") ||
		   strings.HasPrefix(ip, "172.24.") ||
		   strings.HasPrefix(ip, "172.25.") ||
		   strings.HasPrefix(ip, "172.26.") ||
		   strings.HasPrefix(ip, "172.27.") ||
		   strings.HasPrefix(ip, "172.28.") ||
		   strings.HasPrefix(ip, "172.29.") ||
		   strings.HasPrefix(ip, "172.30.") ||
		   strings.HasPrefix(ip, "172.31.")
}

// isCommonGatewayIP checks if an IP is a common gateway/router IP that could cause false correlations
func isCommonGatewayIP(ip string) bool {
	// Only filter the most common default gateway patterns - be conservative
	// Don't filter 192.168.2.1 since that's your actual farm01 device
	commonGateways := []string{
		"192.168.1.1", "192.168.0.1", 
		"10.0.0.1", "10.0.1.1", "10.1.1.1",
		"172.16.0.1", "172.16.1.1",
	}
	
	for _, gateway := range commonGateways {
		if ip == gateway {
			return true
		}
	}
	return false
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
	if device.Metadata != nil && device.Metadata.Value != nil {
		if alternateIPsJSON, ok := device.Metadata.Value["alternate_ips"]; ok {
			var alternateIPs []string
			if err := json.Unmarshal([]byte(alternateIPsJSON), &alternateIPs); err == nil {
				for _, ip := range alternateIPs {
					devices, err := r.GetDevicesByIP(ctx, ip)
					if err != nil {
						log.Printf("Warning: failed to get devices by alternate IP %s: %v", ip, err)
						continue
					}
					for _, d := range devices {
						if d.DeviceID != deviceID {
							relatedDevicesMap[d.DeviceID] = d
						}
					}
				}
			}
		}
	}

	// Convert map to slice
	relatedDevices := make([]*models.UnifiedDevice, 0, len(relatedDevicesMap))
	for _, device := range relatedDevicesMap {
		relatedDevices = append(relatedDevices, device)
	}

	return relatedDevices, nil
}

// CleanupDuplicateDevices identifies and merges duplicate device records
func (r *DeviceRegistry) CleanupDuplicateDevices(ctx context.Context) error {
	// This is a placeholder implementation - in the new architecture,
	// duplicate prevention happens at ingestion time rather than cleanup time
	log.Printf("CleanupDuplicateDevices called - in the new architecture, deduplication happens during ProcessSighting")
	return nil
}
