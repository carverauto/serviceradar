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

package core

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

// DeviceRegistry is a concrete implementation of DeviceRegistryService
type DeviceRegistry struct {
	db db.Service
}

// NewDeviceRegistry creates a new device registry instance
func NewDeviceRegistry(database db.Service) *DeviceRegistry {
	return &DeviceRegistry{
		db: database,
	}
}

// ProcessSweepResult processes a sweep result using materialized view approach
func (r *DeviceRegistry) ProcessSweepResult(ctx context.Context, result *models.SweepResult) error {
	if result == nil {
		return fmt.Errorf("sweep result is nil")
	}

	// Create a copy for enrichment
	enrichedResult := *result

	// Enrich with alternate IPs and discovery sources from existing devices
	if err := r.enrichSweepResult(ctx, &enrichedResult); err != nil {
		log.Printf("Warning: Failed to enrich sweep result for %s: %v", result.IP, err)
		// Continue with original result if enrichment fails
		return r.db.PublishSweepResult(ctx, result)
	}

	log.Printf("Processing sweep result for device %s (IP: %s, Available: %t) using materialized view pipeline",
		enrichedResult.DeviceID, enrichedResult.IP, enrichedResult.Available)

	// Publish enriched result to sweep_results stream
	return r.db.PublishSweepResult(ctx, &enrichedResult)
}

// ProcessBatchSweepResults processes multiple sweep results using materialized view approach
// CRITICAL: This is the single chokepoint where ALL SweepResults pass through before
// being published to the materialized view. This is where we implement the application-side
// enrichment logic to solve the "look-ahead" problem described in the architectural decision record.
func (r *DeviceRegistry) ProcessBatchSweepResults(ctx context.Context, results []*models.SweepResult) error {
	if len(results) == 0 {
		return nil
	}

	log.Printf("Processing batch of %d sweep results using materialized view pipeline", len(results))

	// STEP 1: Enrich each sweep result with known alternate IPs and discovery sources.
	enrichedResults := make([]*models.SweepResult, len(results))
	for i, result := range results {
		enrichedResult := *result // Copy the result

		if err := r.enrichSweepResult(ctx, &enrichedResult); err != nil {
			log.Printf("Warning: Failed to enrich sweep result for %s: %v", result.IP, err)
			// Continue with original result if enrichment fails
			enrichedResults[i] = result
		} else {
			enrichedResults[i] = &enrichedResult
		}
	}

	// STEP 2: Publish enriched results to sweep_results stream
	// The materialized view pipeline can now properly merge devices because each sweep result
	// contains all the historical alternate IP context it needs
	return r.db.PublishBatchSweepResults(ctx, enrichedResults)
}

// UpdateDevice processes a device update using materialized view approach
func (r *DeviceRegistry) UpdateDevice(ctx context.Context, update *models.DeviceUpdate) error {
	if update == nil {
		return fmt.Errorf("device update is nil")
	}

	// Convert device update to sweep result
	result := &models.SweepResult{
		DeviceID:        update.DeviceID,
		IP:              update.IP,
		Available:       update.IsAvailable,
		Timestamp:       update.Timestamp,
		DiscoverySource: string(update.Source),
		AgentID:         update.AgentID,
		PollerID:        update.PollerID,
		Metadata:        update.Metadata,
	}

	if update.Hostname != nil {
		result.Hostname = update.Hostname
	}
	if update.MAC != nil {
		result.MAC = update.MAC
	}

	log.Printf("Processing device update for %s using materialized view pipeline", update.DeviceID)

	// Simply publish to sweep_results - the materialized view handles the rest
	return r.db.PublishSweepResult(ctx, result)
}

// GetDevice retrieves a device by ID
func (r *DeviceRegistry) GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	return r.db.GetUnifiedDevice(ctx, deviceID)
}

// GetDevicesByIP retrieves devices by IP address
func (r *DeviceRegistry) GetDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	return r.db.GetUnifiedDevicesByIP(ctx, ip)
}

// ListDevices lists devices with pagination
func (r *DeviceRegistry) ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	return r.db.ListUnifiedDevices(ctx, limit, offset)
}

// FindCanonicalDevicesByIPs finds canonical devices for a batch of IPs using materialized view approach
// Returns a map of IP -> canonical UnifiedDevice
func (r *DeviceRegistry) FindCanonicalDevicesByIPs(ctx context.Context, ips []string) (map[string]*models.UnifiedDevice, error) {
	if len(ips) == 0 {
		return make(map[string]*models.UnifiedDevice), nil
	}

	// This now becomes a critical method.
	// It queries the DB for all devices that match any of the given IPs.
	existingDevices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, ips, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to lookup devices by IPs: %w", err)
	}

	// Create the IP -> Device map for the caller
	ipToDeviceMap := make(map[string]*models.UnifiedDevice)
	for _, device := range existingDevices {
		// Map the primary IP
		if device.IP != "" {
			ipToDeviceMap[device.IP] = device
		}
		// Map all alternate IPs
		if device.Metadata != nil && device.Metadata.Value != nil {
			for _, altIP := range extractAlternateIPs(device.Metadata.Value) {
				if altIP != "" {
					ipToDeviceMap[altIP] = device
				}
			}
		}
	}

	return ipToDeviceMap, nil
}

// ========================================================================
// Device Unification Enrichment Logic
// ========================================================================
// The following functions implement the "application-side enrichment" described
// in the hybrid device unification architectural decision record.

// extractAlternateIPs extracts alternate IPs from device metadata
func extractAlternateIPs(metadata map[string]string) []string {
	const key = "alternate_ips"

	existing, ok := metadata[key]
	if !ok || existing == "" {
		return nil
	}

	var ips []string

	// Try to parse as JSON array first
	if err := json.Unmarshal([]byte(existing), &ips); err != nil {
		// Fall back to comma-separated format for backward compatibility
		ips = strings.Split(existing, ",")
		for i, ip := range ips {
			ips[i] = strings.TrimSpace(ip)
		}
	}

	return ips
}

// addAlternateIP adds an alternate IP to metadata, following the same pattern as the mapper utils
func addAlternateIP(metadata map[string]string, ip string) map[string]string {
	if ip == "" {
		return metadata
	}

	if metadata == nil {
		metadata = make(map[string]string)
	}

	const key = "alternate_ips"
	ips := extractAlternateIPs(metadata)

	// Check if IP already exists
	for _, existing := range ips {
		if existing == ip {
			return metadata
		}
	}

	ips = append(ips, ip)
	if data, err := json.Marshal(ips); err == nil {
		metadata[key] = string(data)
	}

	return metadata
}

// enrichSweepResult queries existing unified devices and enriches the sweep result
// with a complete set of known alternate IPs and discovery sources. This provides
// the necessary context for the database's materialized view to correctly merge
// device records.
func (r *DeviceRegistry) enrichSweepResult(ctx context.Context, sweep *models.SweepResult) error {
	// Step 1: Collect all IPs to check from the incoming sweep result.
	// This includes its primary IP and any alternate IPs it might already have in its metadata.
	ipsToCheck := make(map[string]struct{})
	if sweep.IP != "" {
		ipsToCheck[sweep.IP] = struct{}{}
	}
	if sweep.Metadata != nil {
		for _, ip := range extractAlternateIPs(sweep.Metadata) {
			if ip != "" {
				ipsToCheck[ip] = struct{}{}
			}
		}
	}

	ipsToCheckSlice := make([]string, 0, len(ipsToCheck))
	for ip := range ipsToCheck {
		ipsToCheckSlice = append(ipsToCheckSlice, ip)
	}

	if len(ipsToCheckSlice) == 0 {
		return nil // Nothing to look up.
	}

	// Step 2: Query for existing devices that match ANY of the collected IPs.
	// This is the critical change from the original implementation.
	existingDevices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, ipsToCheckSlice, nil)
	if err != nil {
		log.Printf("Warning: Failed to query existing devices for enrichment for IPs %v: %v", ipsToCheckSlice, err)
		return nil // Proceed with unenriched data.
	}

	// If no existing device is found, there's nothing to enrich.
	if len(existingDevices) == 0 {
		return nil
	}

	// Step 3: A canonical device was found. Now merge all information from all duplicates.
	// Find the best canonical device (e.g., most recently seen or most sources).
	var canonicalDevice *models.UnifiedDevice
	maxSources := -1
	for _, device := range existingDevices {
		if canonicalDevice == nil {
			canonicalDevice = device
			maxSources = len(device.DiscoverySources)
			continue
		}
		if len(device.DiscoverySources) > maxSources {
			canonicalDevice = device
			maxSources = len(device.DiscoverySources)
		} else if len(device.DiscoverySources) == maxSources && device.LastSeen.After(canonicalDevice.LastSeen) {
			canonicalDevice = device
		}
	}

	// Step 4: Use the canonical device's ID for the incoming sweep. This ensures all updates go to one record.
	sweep.DeviceID = canonicalDevice.DeviceID

	// Step 5: Collect ALL unique discovery sources and IPs from ALL found devices.
	allKnownSources := make(map[string]struct{})
	allKnownIPs := make(map[string]struct{})

	// Add sources/IPs from the incoming sweep result first.
	if sweep.DiscoverySource != "" {
		allKnownSources[sweep.DiscoverySource] = struct{}{}
	}
	for ip := range ipsToCheck {
		allKnownIPs[ip] = struct{}{}
	}

	// Add sources/IPs from all related devices found in the DB.
	for _, device := range existingDevices {
		if device.IP != "" {
			allKnownIPs[device.IP] = struct{}{}
		}
		for _, sourceInfo := range device.DiscoverySources {
			if sourceInfo.Source != "" {
				allKnownSources[string(sourceInfo.Source)] = struct{}{}
			}
		}
		if device.Metadata != nil && device.Metadata.Value != nil {
			for _, ip := range extractAlternateIPs(device.Metadata.Value) {
				if ip != "" {
					allKnownIPs[ip] = struct{}{}
				}
			}
		}
	}

	// Step 6: Enrich the sweep result's metadata with the complete, merged information.
	if sweep.Metadata == nil {
		sweep.Metadata = make(map[string]string)
	}

	// Add all discovered IPs as alternate_ips.
	alternateIPs := make([]string, 0)
	for ip := range allKnownIPs {
		// The primary IP of the sweep should not be in its own alternates list.
		if ip != sweep.IP {
			alternateIPs = append(alternateIPs, ip)
		}
	}
	if len(alternateIPs) > 0 {
		if alternateIPsJSON, err := json.Marshal(alternateIPs); err == nil {
			sweep.Metadata["alternate_ips"] = string(alternateIPsJSON)
		}
	} else {
		// Ensure old data is cleared if there are no longer any alternate IPs.
		delete(sweep.Metadata, "alternate_ips")
	}

	// Add the complete list of discovery sources.
	finalSourceList := make([]string, 0, len(allKnownSources))
	for source := range allKnownSources {
		finalSourceList = append(finalSourceList, source)
	}
	if sourcesJSON, err := json.Marshal(finalSourceList); err == nil {
		sweep.Metadata["all_discovery_sources"] = string(sourcesJSON)
	}

	log.Printf("Enriched sweep result for IP %s with canonical_id %s: %d alternate IPs, sources %v",
		sweep.IP, sweep.DeviceID, len(alternateIPs), finalSourceList)

	return nil
}

// enrichSweepResultWithAlternateIPs queries existing unified devices and enriches the sweep result
// with known alternate IPs. This provides context for the database materialized view and enables
// application-level device unification when devices are queried.
func (r *DeviceRegistry) enrichSweepResultWithAlternateIPs(ctx context.Context, sweep *models.SweepResult) error {
	// Get all IPs to check (primary IP plus any existing alternate IPs)
	ipsToCheck := []string{sweep.IP}
	existingAlternateIPs := extractAlternateIPs(sweep.Metadata)
	ipsToCheck = append(ipsToCheck, existingAlternateIPs...)

	// Query for existing unified devices that match any of these IPs
	existingDevices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, ipsToCheck, nil)
	if err != nil {
		log.Printf("Warning: Failed to query existing devices for enrichment: %v", err)
		return nil // Don't fail the whole operation for enrichment issues
	}

	if len(existingDevices) == 0 {
		return nil // No existing devices found, no enrichment needed
	}

	// Collect all known alternate IPs from existing devices
	var allKnownIPs []string
	seenIPs := make(map[string]bool)

	for _, device := range existingDevices {
		// Add the device's primary IP
		if device.IP != "" && !seenIPs[device.IP] {
			allKnownIPs = append(allKnownIPs, device.IP)
			seenIPs[device.IP] = true
		}

		// Add any alternate IPs from the device's metadata
		if device.Metadata != nil {
			deviceAlternateIPs := extractAlternateIPs(device.Metadata.Value)
			for _, ip := range deviceAlternateIPs {
				if ip != "" && !seenIPs[ip] {
					allKnownIPs = append(allKnownIPs, ip)
					seenIPs[ip] = true
				}
			}
		}
	}

	// Enrich the sweep result's metadata with all known alternate IPs
	if sweep.Metadata == nil {
		sweep.Metadata = make(map[string]string)
	}

	enrichmentCount := 0
	for _, ip := range allKnownIPs {
		if ip != sweep.IP { // Don't add the primary IP as an alternate
			sweep.Metadata = addAlternateIP(sweep.Metadata, ip)
			enrichmentCount++
		}
	}

	if enrichmentCount > 0 {
		log.Printf("Enriched device %s with %d alternate IPs", sweep.IP, enrichmentCount)
	}

	return nil
}
