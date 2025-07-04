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
	"time"

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

	log.Printf("Processing sweep result for device %s (IP: %s, Available: %t) using materialized view pipeline",
		result.DeviceID, result.IP, result.Available)

	// Create a copy for enrichment
	enrichedResult := *result
	
	// Enrich with alternate IPs from existing devices
	if err := r.enrichSweepResultWithAlternateIPs(ctx, &enrichedResult); err != nil {
		log.Printf("Warning: Failed to enrich sweep result for %s: %v", result.IP, err)
		// Continue with original result if enrichment fails
		return r.db.PublishSweepResult(ctx, result)
	}

	// Force canonical device ID to prevent database duplicates
	canonicalDeviceID, err := r.findCanonicalDeviceID(ctx, &enrichedResult)
	if err != nil {
		log.Printf("Warning: Failed to find canonical device ID for %s: %v", result.IP, err)
	} else {
		originalDeviceID := enrichedResult.DeviceID
		enrichedResult.DeviceID = canonicalDeviceID
		log.Printf("CANONICAL MAPPING: %s -> %s (IP: %s)", originalDeviceID, canonicalDeviceID, enrichedResult.IP)
	}

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

	// STEP 1: Enrich and canonicalize device IDs to prevent duplicates
	enrichedResults := make([]*models.SweepResult, len(results))
	for i, result := range results {
		enrichedResult := *result // Copy the result
		
		// Log the incoming sweep result for debugging
		log.Printf("Processing sweep result: IP=%s, DeviceID=%s, Partition=%s, Source=%s, Existing alternates=%v", 
			result.IP, result.DeviceID, result.Partition, result.DiscoverySource, extractAlternateIPs(result.Metadata))
		
		// Enrich with alternate IPs from existing devices
		if err := r.enrichSweepResultWithAlternateIPs(ctx, &enrichedResult); err != nil {
			log.Printf("Warning: Failed to enrich sweep result for %s: %v", result.IP, err)
			// Continue with original result if enrichment fails
			enrichedResults[i] = result
		} else {
			// CRITICAL: Force canonical device ID to prevent database duplicates
			canonicalDeviceID, err := r.findCanonicalDeviceID(ctx, &enrichedResult)
			if err != nil {
				log.Printf("Warning: Failed to find canonical device ID for %s: %v", result.IP, err)
				enrichedResults[i] = &enrichedResult
			} else {
				// Override the device ID to force database consolidation
				originalDeviceID := enrichedResult.DeviceID
				enrichedResult.DeviceID = canonicalDeviceID
				
				log.Printf("CANONICAL MAPPING: %s -> %s (IP: %s, Alternates: %v)", 
					originalDeviceID, canonicalDeviceID, enrichedResult.IP, extractAlternateIPs(enrichedResult.Metadata))
				
				enrichedResults[i] = &enrichedResult
			}
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

	// With materialized view approach, we simply query the current device state
	result := make(map[string]*models.UnifiedDevice)
	
	for _, ip := range ips {
		devices, err := r.db.GetUnifiedDevicesByIP(ctx, ip)
		if err != nil || len(devices) == 0 {
			continue // No device found for this IP, skip without warning
		}
		
		// Take the first device (should be unique due to materialized view)
		result[ip] = devices[0]
	}
	
	return result, nil
}

// FindRelatedDevices finds all devices that are related through alternate IPs
// This performs a transitive closure to find all devices that share any IPs
func (r *DeviceRegistry) FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.UnifiedDevice, error) {
	// Start with the initial device
	device, err := r.db.GetUnifiedDevice(ctx, deviceID)
	if err != nil {
		return nil, fmt.Errorf("failed to get initial device: %w", err)
	}
	
	// Track all IPs we need to check (primary + alternates)
	ipsToCheck := []string{device.IP}
	if device.Metadata != nil {
		alternateIPs := extractAlternateIPs(device.Metadata.Value)
		ipsToCheck = append(ipsToCheck, alternateIPs...)
	}
	
	// Track devices we've already seen to avoid infinite loops
	seenDeviceIDs := make(map[string]bool)
	seenDeviceIDs[device.DeviceID] = true
	
	relatedDevices := []*models.UnifiedDevice{device}
	
	// Keep searching until we find no new devices
	for len(ipsToCheck) > 0 {
		// Query for all devices that match any of our IPs
		newDevices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, ipsToCheck, nil)
		if err != nil {
			log.Printf("Warning: Failed to query related devices: %v", err)
			break
		}
		
		// Reset IPs to check for the next iteration
		ipsToCheck = nil
		
		// Process newly found devices
		for _, newDevice := range newDevices {
			if seenDeviceIDs[newDevice.DeviceID] {
				continue // Already processed this device
			}
			
			seenDeviceIDs[newDevice.DeviceID] = true
			relatedDevices = append(relatedDevices, newDevice)
			
			// Add this device's IPs to check in the next iteration
			ipsToCheck = append(ipsToCheck, newDevice.IP)
			if newDevice.Metadata != nil {
				alternateIPs := extractAlternateIPs(newDevice.Metadata.Value)
				ipsToCheck = append(ipsToCheck, alternateIPs...)
			}
		}
		
		// If we found no new devices, we're done
		if len(ipsToCheck) == 0 {
			break
		}
	}
	
	log.Printf("Found %d related devices for device %s", len(relatedDevices), deviceID)
	return relatedDevices, nil
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

// enrichSweepResultWithAlternateIPs queries existing unified devices and enriches the sweep result
// with known alternate IPs. This provides context for the database materialized view and enables
// application-level device unification when devices are queried.
func (r *DeviceRegistry) enrichSweepResultWithAlternateIPs(ctx context.Context, sweep *models.SweepResult) error {
	// Get all IPs to check (primary IP plus any existing alternate IPs)
	ipsToCheck := []string{sweep.IP}
	existingAlternateIPs := extractAlternateIPs(sweep.Metadata)
	ipsToCheck = append(ipsToCheck, existingAlternateIPs...)
	
	log.Printf("Enrichment: Checking IPs %v for device %s", ipsToCheck, sweep.DeviceID)
	
	// Query for existing unified devices that match any of these IPs
	// This will find devices where:
	// 1. The device's primary IP matches any of our IPs
	// 2. Any of our IPs appear in the device's alternate_ips metadata
	existingDevices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, ipsToCheck, nil)
	if err != nil {
		log.Printf("Warning: Failed to query existing devices for enrichment: %v", err)
		return nil // Don't fail the whole operation for enrichment issues
	}
	
	log.Printf("Enrichment: Found %d existing devices that match IPs %v", len(existingDevices), ipsToCheck)
	
	// Collect all known alternate IPs from existing devices and recent sweeps
	var allKnownIPs []string
	seenIPs := make(map[string]bool)
	
	if len(existingDevices) == 0 {
		log.Printf("Enrichment: No existing devices found for IPs %v", ipsToCheck)
		return nil // No existing devices found, no enrichment needed
	}
	
	for _, device := range existingDevices {
		log.Printf("Enrichment: Processing existing device %s (IP: %s)", device.DeviceID, device.IP)
		
		// Add the device's primary IP
		if device.IP != "" && !seenIPs[device.IP] {
			allKnownIPs = append(allKnownIPs, device.IP)
			seenIPs[device.IP] = true
		}
		
		// Add any alternate IPs from the device's metadata
		if device.Metadata != nil {
			deviceAlternateIPs := extractAlternateIPs(device.Metadata.Value)
			log.Printf("Enrichment: Device %s has alternate IPs: %v", device.DeviceID, deviceAlternateIPs)
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
		log.Printf("Enrichment: Successfully enriched device %s (IP: %s) with %d alternate IPs: %v", 
			sweep.DeviceID, sweep.IP, enrichmentCount, extractAlternateIPs(sweep.Metadata))
	} else {
		log.Printf("Enrichment: No new alternate IPs added for device %s (IP: %s)", sweep.DeviceID, sweep.IP)
	}
	
	return nil
}

// findCanonicalDeviceID determines the canonical device ID for a sweep result
// This ensures all related devices use the same device ID in the database
func (r *DeviceRegistry) findCanonicalDeviceID(ctx context.Context, sweep *models.SweepResult) (string, error) {
	// Collect all IPs that this device is associated with
	allIPs := []string{sweep.IP}
	alternateIPs := extractAlternateIPs(sweep.Metadata)
	allIPs = append(allIPs, alternateIPs...)
	
	// Query for any existing devices that match these IPs
	existingDevices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, allIPs, nil)
	if err != nil {
		log.Printf("Warning: Failed to query existing devices for canonical ID: %v", err)
		// Fallback to original device ID
		return sweep.DeviceID, nil
	}
	
	if len(existingDevices) == 0 {
		// No existing devices found, use the current device ID as canonical
		return sweep.DeviceID, nil
	}
	
	// Find the canonical device ID by choosing the lexicographically smallest one
	// This ensures deterministic behavior across multiple discovery sources
	canonicalID := sweep.DeviceID
	
	for _, device := range existingDevices {
		if device.DeviceID < canonicalID {
			canonicalID = device.DeviceID
		}
	}
	
	log.Printf("Canonical ID selection: Current=%s, Found %d existing devices, Canonical=%s", 
		sweep.DeviceID, len(existingDevices), canonicalID)
	
	return canonicalID, nil
}

// CleanupDuplicateDevices removes duplicate devices from the database by forcing them to use canonical device IDs
// This is needed to clean up existing duplicates that were created before the canonical ID logic was implemented
func (r *DeviceRegistry) CleanupDuplicateDevices(ctx context.Context) error {
	log.Printf("Starting cleanup of duplicate devices...")
	
	// Get all devices from the database
	allDevices, err := r.db.ListUnifiedDevices(ctx, 10000, 0) // Large limit to get all devices
	if err != nil {
		return fmt.Errorf("failed to list devices for cleanup: %w", err)
	}
	
	log.Printf("Found %d total devices, analyzing for duplicates...", len(allDevices))
	
	// Track which devices we've already processed
	processedDevices := make(map[string]bool)
	cleanupCount := 0
	
	for _, device := range allDevices {
		if processedDevices[device.DeviceID] {
			continue // Already processed this device
		}
		
		// Find all related devices (sharing IPs)
		relatedDevices, err := r.FindRelatedDevices(ctx, device.DeviceID)
		if err != nil {
			log.Printf("Warning: Failed to find related devices for %s: %v", device.DeviceID, err)
			continue
		}
		
		if len(relatedDevices) <= 1 {
			// No duplicates for this device
			processedDevices[device.DeviceID] = true
			continue
		}
		
		// Found duplicates! Determine canonical device ID
		canonicalDeviceID := relatedDevices[0].DeviceID
		for _, related := range relatedDevices {
			if related.DeviceID < canonicalDeviceID {
				canonicalDeviceID = related.DeviceID
			}
		}
		
		log.Printf("CLEANUP: Found %d related devices for %s, canonical ID: %s", 
			len(relatedDevices), device.DeviceID, canonicalDeviceID)
		
		// Create a unified sweep result that will consolidate all data
		mergedDevice, err := r.GetMergedDevice(ctx, device.DeviceID)
		if err != nil {
			log.Printf("Warning: Failed to get merged device for %s: %v", device.DeviceID, err)
			continue
		}
		
		// Create a sweep result from the merged device with canonical ID
		sweepResult := &models.SweepResult{
			DeviceID:        canonicalDeviceID,
			IP:              mergedDevice.IP,
			Available:       mergedDevice.IsAvailable,
			Timestamp:       mergedDevice.LastSeen,
			DiscoverySource: "cleanup",
			AgentID:         "system",
			PollerID:        "cleanup",
			Metadata:        make(map[string]string),
		}
		
		// Add all known IPs as alternate IPs
		if mergedDevice.Metadata != nil && mergedDevice.Metadata.Value != nil {
			for k, v := range mergedDevice.Metadata.Value {
				sweepResult.Metadata[k] = v
			}
		}
		
		// Set hostname and MAC if available
		if mergedDevice.Hostname != nil {
			sweepResult.Hostname = &mergedDevice.Hostname.Value
		}
		if mergedDevice.MAC != nil {
			sweepResult.MAC = &mergedDevice.MAC.Value
		}
		
		// Publish the consolidated sweep result
		log.Printf("CLEANUP: Publishing consolidated device %s", canonicalDeviceID)
		if err := r.db.PublishSweepResult(ctx, sweepResult); err != nil {
			log.Printf("Warning: Failed to publish cleanup sweep result for %s: %v", canonicalDeviceID, err)
		} else {
			cleanupCount++
		}
		
		// Mark all related devices as processed
		for _, related := range relatedDevices {
			processedDevices[related.DeviceID] = true
		}
	}
	
	log.Printf("Cleanup completed: %d duplicate device groups processed", cleanupCount)
	return nil
}

// GetMergedDevice returns a unified view of a device by finding and merging all related devices
// This provides the application-level device unification that solves the alternate IP problem
func (r *DeviceRegistry) GetMergedDevice(ctx context.Context, deviceIDOrIP string) (*models.UnifiedDevice, error) {
	// First, try to find the device by ID
	var initialDevice *models.UnifiedDevice
	device, err := r.db.GetUnifiedDevice(ctx, deviceIDOrIP)
	if err == nil {
		initialDevice = device
	} else {
		// If not found by ID, try by IP
		devices, err := r.db.GetUnifiedDevicesByIP(ctx, deviceIDOrIP)
		if err != nil || len(devices) == 0 {
			return nil, fmt.Errorf("device not found: %s", deviceIDOrIP)
		}
		initialDevice = devices[0]
	}
	
	// Find all related devices
	relatedDevices, err := r.FindRelatedDevices(ctx, initialDevice.DeviceID)
	if err != nil {
		return nil, fmt.Errorf("failed to find related devices: %w", err)
	}
	
	// If there's only one device, return it as-is
	if len(relatedDevices) == 1 {
		return relatedDevices[0], nil
	}
	
	// Merge all related devices into a single unified view
	merged := &models.UnifiedDevice{
		DeviceID:    initialDevice.DeviceID, // Keep the initial device's ID
		IP:          initialDevice.IP,        // Keep the initial device's primary IP
		IsAvailable: false,                   // Will be true if ANY device is available
	}
	
	// Collect all unique IPs, discovery sources, and find the best values for each field
	allIPs := make(map[string]bool)
	allDiscoverySources := make(map[string]models.DiscoverySourceInfo)
	var latestSeen time.Time
	var earliestSeen time.Time
	
	for _, device := range relatedDevices {
		// Collect primary IP
		allIPs[device.IP] = true
		
		// Collect alternate IPs
		if device.Metadata != nil {
			alternateIPs := extractAlternateIPs(device.Metadata.Value)
			for _, ip := range alternateIPs {
				allIPs[ip] = true
			}
		}
		
		// Track availability (true if ANY device is available)
		if device.IsAvailable {
			merged.IsAvailable = true
		}
		
		// Track time ranges
		if earliestSeen.IsZero() || device.FirstSeen.Before(earliestSeen) {
			earliestSeen = device.FirstSeen
		}
		if device.LastSeen.After(latestSeen) {
			latestSeen = device.LastSeen
			// Use values from the most recently seen device
			merged.Hostname = device.Hostname
			merged.MAC = device.MAC
			merged.Metadata = device.Metadata
			merged.DeviceType = device.DeviceType
			merged.ServiceType = device.ServiceType
			merged.ServiceStatus = device.ServiceStatus
			merged.LastHeartbeat = device.LastHeartbeat
			merged.OSInfo = device.OSInfo
			merged.VersionInfo = device.VersionInfo
		}
		
		// Collect discovery sources
		for _, source := range device.DiscoverySources {
			allDiscoverySources[string(source.Source)] = source
		}
	}
	
	// Set time ranges
	merged.FirstSeen = earliestSeen
	merged.LastSeen = latestSeen
	
	// Convert discovery sources map to slice
	for _, source := range allDiscoverySources {
		merged.DiscoverySources = append(merged.DiscoverySources, source)
	}
	
	// Update metadata with all known alternate IPs
	if merged.Metadata == nil {
		merged.Metadata = &models.DiscoveredField[map[string]string]{
			Value: make(map[string]string),
		}
	}
	
	// Remove the primary IP from the alternate IPs set
	delete(allIPs, merged.IP)
	
	// Convert remaining IPs to alternate IPs
	var alternateIPsList []string
	for ip := range allIPs {
		alternateIPsList = append(alternateIPsList, ip)
	}
	
	if len(alternateIPsList) > 0 {
		alternateIPsJSON, _ := json.Marshal(alternateIPsList)
		merged.Metadata.Value["alternate_ips"] = string(alternateIPsJSON)
	}
	
	log.Printf("Merged %d devices into unified device %s with %d total IPs", 
		len(relatedDevices), merged.DeviceID, len(allIPs)+1)
	
	return merged, nil
}
