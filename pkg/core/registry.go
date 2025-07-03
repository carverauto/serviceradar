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
	"fmt"
	"log"

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
	}

	// Apply the device update
	return r.UpdateDevice(ctx, deviceUpdate)
}

// UpdateDevice updates an existing device or creates a new one
func (r *DeviceRegistry) UpdateDevice(ctx context.Context, update *models.DeviceUpdate) error {
	if update == nil {
		return fmt.Errorf("device update is nil")
	}

	// Get existing device or create new one
	device, err := r.db.GetUnifiedDevice(ctx, update.DeviceID)
	if err != nil {
		// Create new device if not found
		device = &models.UnifiedDevice{
			DeviceID:         update.DeviceID,
			IP:               update.IP,
			IsAvailable:      update.IsAvailable,
			FirstSeen:        update.Timestamp,
			LastSeen:         update.Timestamp,
			DiscoverySources: []models.DiscoverySourceInfo{},
		}
	}

	// Update availability status
	device.IsAvailable = update.IsAvailable
	device.LastSeen = update.Timestamp

	// Find existing discovery source or create new one
	sourceFound := false
	for i, source := range device.DiscoverySources {
		if source.Source == update.Source && source.AgentID == update.AgentID && source.PollerID == update.PollerID {
			device.DiscoverySources[i].LastSeen = update.Timestamp
			device.DiscoverySources[i].Confidence = update.Confidence
			sourceFound = true
			break
		}
	}

	if !sourceFound {
		newSource := models.DiscoverySourceInfo{
			Source:     update.Source,
			AgentID:    update.AgentID,
			PollerID:   update.PollerID,
			FirstSeen:  update.Timestamp,
			LastSeen:   update.Timestamp,
			Confidence: update.Confidence,
		}
		device.DiscoverySources = append(device.DiscoverySources, newSource)
	}

	// Update metadata field by merging instead of overwriting
	if update.Metadata != nil && len(update.Metadata) > 0 {
		// If there's no existing metadata, the new update becomes the metadata.
		if device.Metadata == nil {
			device.Metadata = &models.DiscoveredField[map[string]string]{
				Value:       update.Metadata,
				Source:      update.Source,
				LastUpdated: update.Timestamp,
				Confidence:  update.Confidence,
				AgentID:     update.AgentID,
				PollerID:    update.PollerID,
			}
		} else {
			// There is existing metadata, so we need to merge.
			// First, merge the key-value pairs. New values from the update overwrite old ones.
			if device.Metadata.Value == nil {
				device.Metadata.Value = make(map[string]string)
			}
			for k, v := range update.Metadata {
				device.Metadata.Value[k] = v
			}

			// Now, decide whether to update the attribution of the entire metadata block.
			// Higher confidence source wins. If confidence is equal, the newer timestamp wins.
			if update.Confidence > device.Metadata.Confidence ||
				(update.Confidence == device.Metadata.Confidence && update.Timestamp.After(device.Metadata.LastUpdated)) {
				device.Metadata.Source = update.Source
				device.Metadata.LastUpdated = update.Timestamp
				device.Metadata.Confidence = update.Confidence
				device.Metadata.AgentID = update.AgentID
				device.Metadata.PollerID = update.PollerID
			}
		}
	}

	// Store the updated device
	return r.db.StoreUnifiedDevice(ctx, device)
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
