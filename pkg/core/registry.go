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

	// STEP 1: Enrich each sweep result with known alternate IPs
	// This is the "application-side enrichment" that enables the materialized view pipeline to work
	enrichedResults := make([]*models.SweepResult, len(results))
	for i, result := range results {
		enrichedResult := *result // Copy the result
		
		// Enrich with alternate IPs from existing devices
		if err := r.enrichSweepResultWithAlternateIPs(ctx, &enrichedResult); err != nil {
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
