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
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"log"
	"sort"
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

// ProcessSweepResult processes a sweep result and updates device availability
func (r *DeviceRegistry) ProcessSweepResult(ctx context.Context, result *models.SweepResult) error {
	if result == nil {
		return fmt.Errorf("sweep result is nil")
	}

	log.Printf("Processing sweep result for device %s (IP: %s, Available: %t, AgentID: %s, PollerID: %s)",
		result.DeviceID, result.IP, result.Available, result.AgentID, result.PollerID)

	// Convert sweep result to device update
	deviceUpdate := &models.DeviceUpdate{
		DeviceID:    result.DeviceID,
		IP:          result.IP,
		IsAvailable: result.Available,
		Timestamp:   result.Timestamp,
		Source:      models.DiscoverySource(result.DiscoverySource),
		AgentID:     result.AgentID,
		PollerID:    result.PollerID,
		Confidence:  models.GetSourceConfidence(models.DiscoverySource(result.DiscoverySource)),
		Metadata:    result.Metadata,
		Hostname:    result.Hostname,
	}

	// Apply the device update
	return r.UpdateDevice(ctx, deviceUpdate)
}

// ProcessBatchSweepResults processes multiple sweep results efficiently by batching database operations
// Performs bidirectional reconciliation including alternate IP lookups to find merge candidates
func (r *DeviceRegistry) ProcessBatchSweepResults(ctx context.Context, results []*models.SweepResult) error {
	if len(results) == 0 {
		return nil
	}

	log.Printf("Processing batch of %d sweep results with full bidirectional reconciliation", len(results))

	// Track canonical devices and their updates
	canonicalDevices := make(map[string]*models.UnifiedDevice)
	
	for _, result := range results {
		if result == nil {
			continue
		}

		// Convert sweep result to device update for reconciliation
		deviceUpdate := &models.DeviceUpdate{
			DeviceID:    result.DeviceID,
			IP:          result.IP,
			IsAvailable: result.Available,
			Timestamp:   result.Timestamp,
			Source:      models.DiscoverySource(result.DiscoverySource),
			AgentID:     result.AgentID,
			PollerID:    result.PollerID,
			Confidence:  models.GetSourceConfidence(models.DiscoverySource(result.DiscoverySource)),
			Metadata:    result.Metadata,
			Hostname:    result.Hostname,
			MAC:         result.MAC,
		}

		// Perform bidirectional reconciliation to find canonical device
		canonicalDevice, err := r.findOrCreateCanonicalDevice(ctx, deviceUpdate, canonicalDevices)
		if err != nil {
			log.Printf("Error finding canonical device for %s: %v", result.IP, err)
			continue
		}

		// Merge the update into the canonical device
		r.mergeDeviceUpdate(canonicalDevice, deviceUpdate)
		
		// Store the canonical device (will overwrite if already exists, which is correct)
		canonicalDevices[canonicalDevice.DeviceID] = canonicalDevice
	}

	// Store all canonical devices in a single batch operation
	if len(canonicalDevices) > 0 {
		devices := make([]*models.UnifiedDevice, 0, len(canonicalDevices))
		for _, device := range canonicalDevices {
			devices = append(devices, device)
		}
		
		if err := r.db.StoreBatchUnifiedDevices(ctx, devices); err != nil {
			return fmt.Errorf("failed to store batch unified devices: %w", err)
		}
		log.Printf("Successfully stored batch of %d canonical unified devices", len(devices))
	}

	return nil
}

// findOrCreateCanonicalDevice performs bidirectional reconciliation to find the canonical device
// for a device update, checking both the batch cache and the database
func (r *DeviceRegistry) findOrCreateCanonicalDevice(ctx context.Context, update *models.DeviceUpdate, batchCache map[string]*models.UnifiedDevice) (*models.UnifiedDevice, error) {
	// Collect all potential candidate devices
	candidates := make(map[string]*models.UnifiedDevice)
	
	// 1. Check if we already have this device in our batch cache
	if cached, exists := batchCache[update.DeviceID]; exists {
		candidates[cached.DeviceID] = cached
	}
	
	// 2. Look up by the update's primary DeviceID in database
	if device, err := r.db.GetUnifiedDevice(ctx, update.DeviceID); err == nil {
		candidates[device.DeviceID] = device
	}

	// 3. Look up by the update's primary IP address in database
	if devices, err := r.db.GetUnifiedDevicesByIP(ctx, update.IP); err == nil {
		for _, device := range devices {
			candidates[device.DeviceID] = device
		}
	}

	// 4. Look up by the update's alternate IPs in database
	if alternateIPsStr, ok := update.Metadata["alternate_ips"]; ok && alternateIPsStr != "" {
		var alternateIPs []string
		if err := json.Unmarshal([]byte(alternateIPsStr), &alternateIPs); err == nil {
			for _, altIP := range alternateIPs {
				if devices, err := r.db.GetUnifiedDevicesByIP(ctx, altIP); err == nil {
					for _, device := range devices {
						candidates[device.DeviceID] = device
					}
				}
			}
		}
	}

	// 5. Check batch cache for devices that have this IP in their alternate IPs
	for _, cachedDevice := range batchCache {
		if cachedDevice.Metadata != nil && cachedDevice.Metadata.Value != nil {
			if alternateIPsStr, ok := cachedDevice.Metadata.Value["alternate_ips"]; ok && alternateIPsStr != "" {
				var alternateIPs []string
				if err := json.Unmarshal([]byte(alternateIPsStr), &alternateIPs); err == nil {
					for _, altIP := range alternateIPs {
						if altIP == update.IP {
							candidates[cachedDevice.DeviceID] = cachedDevice
							break
						}
					}
				}
			}
		}
	}

	// If no candidates found, create a new device
	if len(candidates) == 0 {
		return &models.UnifiedDevice{
			DeviceID:         update.DeviceID,
			IP:               update.IP,
			FirstSeen:        update.Timestamp,
			LastSeen:         update.Timestamp,
			IsAvailable:      update.IsAvailable,
			DiscoverySources: []models.DiscoverySourceInfo{},
		}, nil
	}

	// Filter out merged devices and find the canonical one
	activeCandidates := make([]*models.UnifiedDevice, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.Metadata != nil && candidate.Metadata.Value != nil {
			if mergedInto, isMerged := candidate.Metadata.Value["_merged_into"]; isMerged {
				// This device was merged into another device, try to get the canonical one
				if canonicalCandidate, err := r.db.GetUnifiedDevice(ctx, mergedInto); err == nil {
					log.Printf("Device %s was merged into %s, using canonical device", candidate.DeviceID, mergedInto)
					candidates[canonicalCandidate.DeviceID] = canonicalCandidate
					continue // Skip the merged device
				}
			}
		}
		activeCandidates = append(activeCandidates, candidate)
	}

	if len(activeCandidates) == 0 {
		// All candidates were merged, create a new device
		return &models.UnifiedDevice{
			DeviceID:         update.DeviceID,
			IP:               update.IP,
			FirstSeen:        update.Timestamp,
			LastSeen:         update.Timestamp,
			IsAvailable:      update.IsAvailable,
			DiscoverySources: []models.DiscoverySourceInfo{},
		}, nil
	}

	// Pick the most recently seen active device as canonical
	sort.Slice(activeCandidates, func(i, j int) bool {
		return activeCandidates[i].LastSeen.After(activeCandidates[j].LastSeen)
	})
	canonicalDevice := activeCandidates[0]

	log.Printf("Found canonical device %s for update IP %s (from %d candidates)", canonicalDevice.DeviceID, update.IP, len(candidates))
	
	return canonicalDevice, nil
}

// mergeDeviceUpdate merges a device update into a unified device
func (r *DeviceRegistry) mergeDeviceUpdate(device *models.UnifiedDevice, update *models.DeviceUpdate) {
	// Update timestamps and availability
	if update.Timestamp.After(device.LastSeen) {
		device.LastSeen = update.Timestamp
		// Only update availability if the source provides meaningful availability data
		if update.Source == models.DiscoverySourceSweep ||
			update.Source == models.DiscoverySourceSNMP ||
			update.Source == models.DiscoverySourceSelfReported ||
			update.Source == models.DiscoverySourceIntegration {
			device.IsAvailable = update.IsAvailable
		}
	}
	if update.Timestamp.Before(device.FirstSeen) {
		device.FirstSeen = update.Timestamp
	}

	// Merge hostname if the new one has higher confidence
	if update.Hostname != nil && *update.Hostname != "" {
		newHostnameField := &models.DiscoveredField[string]{
			Value:       *update.Hostname,
			Source:      update.Source,
			LastUpdated: update.Timestamp,
			Confidence:  update.Confidence,
			AgentID:     update.AgentID,
			PollerID:    update.PollerID,
		}
		if shouldUpdateDiscoveredField(device.Hostname, newHostnameField) {
			device.Hostname = newHostnameField
		}
	}

	// Merge MAC if the new one has higher confidence
	if update.MAC != nil && *update.MAC != "" {
		newMACField := &models.DiscoveredField[string]{
			Value:       *update.MAC,
			Source:      update.Source,
			LastUpdated: update.Timestamp,
			Confidence:  update.Confidence,
			AgentID:     update.AgentID,
			PollerID:    update.PollerID,
		}
		if shouldUpdateDiscoveredField(device.MAC, newMACField) {
			device.MAC = newMACField
		}
	}

	// Merge metadata if the new one has higher confidence
	if update.Metadata != nil && len(update.Metadata) > 0 {
		newMetadataField := &models.DiscoveredField[map[string]string]{
			Value:       update.Metadata,
			Source:      update.Source,
			LastUpdated: update.Timestamp,
			Confidence:  update.Confidence,
			AgentID:     update.AgentID,
			PollerID:    update.PollerID,
		}
		if shouldUpdateDiscoveredField(device.Metadata, newMetadataField) {
			device.Metadata = newMetadataField
		}
	}

	// Merge discovery source
	sourceFound := false
	for i, source := range device.DiscoverySources {
		if source.Source == update.Source && source.AgentID == update.AgentID && source.PollerID == update.PollerID {
			device.DiscoverySources[i].LastSeen = update.Timestamp
			device.DiscoverySources[i].Confidence = update.Confidence
			if update.Timestamp.Before(device.DiscoverySources[i].FirstSeen) {
				device.DiscoverySources[i].FirstSeen = update.Timestamp
			}
			sourceFound = true
			break
		}
	}
	if !sourceFound {
		device.DiscoverySources = append(device.DiscoverySources, models.DiscoverySourceInfo{
			Source:     update.Source,
			AgentID:    update.AgentID,
			PollerID:   update.PollerID,
			FirstSeen:  update.Timestamp,
			LastSeen:   update.Timestamp,
			Confidence: update.Confidence,
		})
	}
}

// sweepResultToUnifiedDevice converts a sweep result to a unified device
func (r *DeviceRegistry) sweepResultToUnifiedDevice(result *models.SweepResult) *models.UnifiedDevice {
	confidence := models.GetSourceConfidence(models.DiscoverySource(result.DiscoverySource))

	// Create DiscoveredField wrappers if needed
	var hostname *models.DiscoveredField[string]
	if result.Hostname != nil && *result.Hostname != "" {
		hostname = &models.DiscoveredField[string]{
			Value:       *result.Hostname,
			Source:      models.DiscoverySource(result.DiscoverySource),
			LastUpdated: result.Timestamp,
			Confidence:  confidence,
			AgentID:     result.AgentID,
			PollerID:    result.PollerID,
		}
	}

	var mac *models.DiscoveredField[string]
	if result.MAC != nil && *result.MAC != "" {
		mac = &models.DiscoveredField[string]{
			Value:       *result.MAC,
			Source:      models.DiscoverySource(result.DiscoverySource),
			LastUpdated: result.Timestamp,
			Confidence:  confidence,
			AgentID:     result.AgentID,
			PollerID:    result.PollerID,
		}
	}

	var metadata *models.DiscoveredField[map[string]string]
	if result.Metadata != nil && len(result.Metadata) > 0 {
		metadata = &models.DiscoveredField[map[string]string]{
			Value:       result.Metadata,
			Source:      models.DiscoverySource(result.DiscoverySource),
			LastUpdated: result.Timestamp,
			Confidence:  confidence,
			AgentID:     result.AgentID,
			PollerID:    result.PollerID,
		}
	}

	// Create discovery source info
	discoverySourceInfo := models.DiscoverySourceInfo{
		Source:     models.DiscoverySource(result.DiscoverySource),
		AgentID:    result.AgentID,
		PollerID:   result.PollerID,
		FirstSeen:  result.Timestamp,
		LastSeen:   result.Timestamp,
		Confidence: confidence,
	}

	return &models.UnifiedDevice{
		DeviceID:         result.DeviceID,
		IP:               result.IP,
		Hostname:         hostname,
		MAC:              mac,
		Metadata:         metadata,
		DiscoverySources: []models.DiscoverySourceInfo{discoverySourceInfo},
		FirstSeen:        result.Timestamp,
		LastSeen:         result.Timestamp,
		IsAvailable:      result.Available,
	}
}

// mergeUnifiedDevicesInMemory merges two unified devices in memory (for batch deduplication)
func (r *DeviceRegistry) mergeUnifiedDevicesInMemory(existing, new *models.UnifiedDevice) *models.UnifiedDevice {
	// Start with the existing device
	merged := *existing

	// Update timestamps and availability
	if new.LastSeen.After(merged.LastSeen) {
		merged.LastSeen = new.LastSeen
		merged.IsAvailable = new.IsAvailable
	}
	if new.FirstSeen.Before(merged.FirstSeen) {
		merged.FirstSeen = new.FirstSeen
	}

	// Merge hostname if the new one has higher confidence
	if shouldUpdateDiscoveredField(merged.Hostname, new.Hostname) {
		merged.Hostname = new.Hostname
	}

	// Merge MAC if the new one has higher confidence
	if shouldUpdateDiscoveredField(merged.MAC, new.MAC) {
		merged.MAC = new.MAC
	}

	// Merge metadata if the new one has higher confidence
	if shouldUpdateDiscoveredField(merged.Metadata, new.Metadata) {
		merged.Metadata = new.Metadata
	}

	// Merge discovery sources
	merged.DiscoverySources = r.mergeDiscoverySources(merged.DiscoverySources, new.DiscoverySources)

	return &merged
}

// mergeDiscoverySources merges discovery source arrays, updating existing ones or adding new ones
func (r *DeviceRegistry) mergeDiscoverySources(existing, new []models.DiscoverySourceInfo) []models.DiscoverySourceInfo {
	result := make([]models.DiscoverySourceInfo, len(existing))
	copy(result, existing)

	for _, newSource := range new {
		found := false
		for i, existingSource := range result {
			if existingSource.Source == newSource.Source && 
			   existingSource.AgentID == newSource.AgentID && 
			   existingSource.PollerID == newSource.PollerID {
				// Update existing source
				result[i].LastSeen = newSource.LastSeen
				result[i].Confidence = newSource.Confidence
				if newSource.FirstSeen.Before(result[i].FirstSeen) {
					result[i].FirstSeen = newSource.FirstSeen
				}
				found = true
				break
			}
		}
		if !found {
			// Add new source
			result = append(result, newSource)
		}
	}

	return result
}

// UpdateDevice updates an existing device or creates a new one, now with robust, bidirectional reconciliation.
func (r *DeviceRegistry) UpdateDevice(ctx context.Context, update *models.DeviceUpdate) error {
	if update == nil {
		return fmt.Errorf("device update is nil")
	}

	// =================================================================
	// == START: Bidirectional Reconciliation Logic
	// =================================================================

	// 1. Gather all potential existing devices (candidates) for this update.
	// We use a map to automatically handle duplicates.
	candidates := make(map[string]*models.UnifiedDevice)

	// a. Look up by the update's primary DeviceID.
	if device, err := r.db.GetUnifiedDevice(ctx, update.DeviceID); err == nil {
		candidates[device.DeviceID] = device
	}

	// b. Look up by the update's primary IP address.
	if devices, err := r.db.GetUnifiedDevicesByIP(ctx, update.IP); err == nil {
		for _, device := range devices {
			candidates[device.DeviceID] = device
		}
	}

	// c. Look up by the update's alternate IPs.
	if alternateIPsStr, ok := update.Metadata["alternate_ips"]; ok && alternateIPsStr != "" {
		var alternateIPs []string
		if err := json.Unmarshal([]byte(alternateIPsStr), &alternateIPs); err == nil {
			for _, altIP := range alternateIPs {
				if devices, err := r.db.GetUnifiedDevicesByIP(ctx, altIP); err == nil {
					for _, device := range devices {
						candidates[device.DeviceID] = device
					}
				}
			}
		}
	}

	var canonicalDevice *models.UnifiedDevice
	var otherCandidates []*models.UnifiedDevice

	if len(candidates) == 0 {
		// This is a completely new device. Create a new record for it.
		canonicalDevice = &models.UnifiedDevice{
			DeviceID:         update.DeviceID,
			IP:               update.IP,
			FirstSeen:        update.Timestamp,
			DiscoverySources: []models.DiscoverySourceInfo{},
		}
	} else {
		// We have one or more existing devices. Filter out merged devices and redirect to canonical ones.
		activeCandidates := make([]*models.UnifiedDevice, 0, len(candidates))
		for _, c := range candidates {
			if c.Metadata != nil && c.Metadata.Value != nil {
				if mergedInto, isMerged := c.Metadata.Value["_merged_into"]; isMerged {
					// This device was merged into another device, try to get the canonical one
					if canonicalCandidate, err := r.db.GetUnifiedDevice(ctx, mergedInto); err == nil {
						log.Printf("Device %s was merged into %s, using canonical device", c.DeviceID, mergedInto)
						candidates[canonicalCandidate.DeviceID] = canonicalCandidate
						continue // Skip the merged device
					}
				}
			}
			activeCandidates = append(activeCandidates, c)
		}

		if len(activeCandidates) == 0 {
			// All candidates were merged, create a new device
			canonicalDevice = &models.UnifiedDevice{
				DeviceID:         update.DeviceID,
				IP:               update.IP,
				FirstSeen:        update.Timestamp,
				DiscoverySources: []models.DiscoverySourceInfo{},
			}
		} else {
			// Pick the most recently seen active device
			sort.Slice(activeCandidates, func(i, j int) bool {
				return activeCandidates[i].LastSeen.After(activeCandidates[j].LastSeen)
			})
			canonicalDevice = activeCandidates[0]
			if len(activeCandidates) > 1 {
				otherCandidates = activeCandidates[1:]
			}
		}
	}

	log.Printf("Reconciling update for IP %s. Canonical DeviceID chosen: %s. Found %d candidates.", update.IP, canonicalDevice.DeviceID, len(candidates))

	// =================================================================
	// == END: Bidirectional Reconciliation Logic
	// =================================================================

	// 2. Now, merge the incoming update AND all other found candidates into the chosen canonical device.
	allIPs := make(map[string]struct{})
	allIPs[canonicalDevice.IP] = struct{}{}
	allIPs[update.IP] = struct{}{}

	// Merge properties from other candidates into the canonical one
	for _, other := range otherCandidates {
		allIPs[other.IP] = struct{}{}
		if shouldUpdateDiscoveredField(canonicalDevice.Hostname, other.Hostname) {
			canonicalDevice.Hostname = other.Hostname
		}
		// NOTE: In a complete solution, we would also merge MAC, other metadata, etc.
		// and then delete/deactivate the 'other' record.
		// For now, we focus on IP consolidation which is key to future merges.
	}

	// Only update availability if the source provides meaningful availability data
	if update.Source == models.DiscoverySourceSweep ||
		update.Source == models.DiscoverySourceSNMP ||
		update.Source == models.DiscoverySourceSelfReported {
		canonicalDevice.IsAvailable = update.IsAvailable
	}
	canonicalDevice.LastSeen = update.Timestamp

	// Merge hostname from the current update
	if update.Hostname != nil && *update.Hostname != "" {
		newHostnameField := &models.DiscoveredField[string]{
			Value:       *update.Hostname,
			Source:      update.Source,
			LastUpdated: update.Timestamp,
			Confidence:  update.Confidence,
			AgentID:     update.AgentID,
			PollerID:    update.PollerID,
		}
		if shouldUpdateDiscoveredField(canonicalDevice.Hostname, newHostnameField) {
			canonicalDevice.Hostname = newHostnameField
		}
	}

	// Merge discovery source
	sourceFound := false
	for i, source := range canonicalDevice.DiscoverySources {
		if source.Source == update.Source && source.AgentID == update.AgentID && source.PollerID == update.PollerID {
			canonicalDevice.DiscoverySources[i].LastSeen = update.Timestamp
			canonicalDevice.DiscoverySources[i].Confidence = update.Confidence
			sourceFound = true
			break
		}
	}
	if !sourceFound {
		canonicalDevice.DiscoverySources = append(canonicalDevice.DiscoverySources, models.DiscoverySourceInfo{
			Source:     update.Source,
			AgentID:    update.AgentID,
			PollerID:   update.PollerID,
			FirstSeen:  update.Timestamp,
			LastSeen:   update.Timestamp,
			Confidence: update.Confidence,
		})
	}

	// Merge metadata
	if canonicalDevice.Metadata == nil {
		canonicalDevice.Metadata = &models.DiscoveredField[map[string]string]{
			Value:      make(map[string]string),
			Confidence: -1, // Ensure the first real update wins
		}
	}
	if update.Metadata != nil {
		for k, v := range update.Metadata {
			if k == "alternate_ips" {
				var newIPs []string
				if err := json.Unmarshal([]byte(v), &newIPs); err == nil {
					for _, ip := range newIPs {
						allIPs[ip] = struct{}{}
					}
				}
			} else {
				canonicalDevice.Metadata.Value[k] = v
			}
		}
	}

	// Consolidate all collected IPs into the 'alternate_ips' metadata field
	delete(allIPs, canonicalDevice.IP) // The primary IP should not be in the alternate list
	alternateIPsSlice := make([]string, 0, len(allIPs))
	for ip := range allIPs {
		alternateIPsSlice = append(alternateIPsSlice, ip)
	}
	sort.Strings(alternateIPsSlice)
	alternateIPsJSON, _ := json.Marshal(alternateIPsSlice)
	canonicalDevice.Metadata.Value["alternate_ips"] = string(alternateIPsJSON)

	// Update metadata source info if confidence is higher or equal
	if update.Confidence >= canonicalDevice.Metadata.Confidence {
		canonicalDevice.Metadata.Source = update.Source
		canonicalDevice.Metadata.LastUpdated = update.Timestamp
		canonicalDevice.Metadata.Confidence = update.Confidence
		canonicalDevice.Metadata.AgentID = update.AgentID
		canonicalDevice.Metadata.PollerID = update.PollerID
	}

	// 3. Store the final, merged canonical device.
	if err := r.db.StoreUnifiedDevice(ctx, canonicalDevice); err != nil {
		return fmt.Errorf("failed to store canonical device: %w", err)
	}

	// 4. Mark duplicate devices as merged
	for _, other := range otherCandidates {
		if other.DeviceID != canonicalDevice.DeviceID {
			log.Printf("Marking duplicate device %s as merged into %s", other.DeviceID, canonicalDevice.DeviceID)
			if err := r.db.MarkDeviceAsMerged(ctx, other.DeviceID, canonicalDevice.DeviceID); err != nil {
				log.Printf("Warning: failed to mark device %s as merged: %v", other.DeviceID, err)
				// Don't fail the entire operation if marking fails
			}
		}
	}

	return nil
}

// shouldUpdateDiscoveredField determines if a discovered field should be updated.
// It prioritizes higher confidence, then newer timestamps for equal confidence.
func shouldUpdateDiscoveredField[T any](existing, new *models.DiscoveredField[T]) bool {
	if existing == nil {
		return true // Always update if there's no existing value.
	}
	if new == nil {
		return false // Don't update if the new value is nil.
	}

	// Update if new source has higher confidence.
	if new.Confidence > existing.Confidence {
		return true
	}

	// If confidence is the same, update if the new data is more recent.
	if new.Confidence == existing.Confidence && new.LastUpdated.After(existing.LastUpdated) {
		return true
	}

	return false
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
