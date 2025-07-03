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

package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errFailedToScanUnifiedDeviceRow = errors.New("failed to scan unified device row")
	errUnifiedDeviceNotFound        = errors.New("unified device not found")
	errFailedToQueryUnifiedDevice   = errors.New("failed to query unified device")
)

// StoreUnifiedDevice stores a unified device into the unified_devices_registry stream
// This method now handles merging with existing devices to preserve discovery sources
func (db *DB) StoreUnifiedDevice(ctx context.Context, device *models.UnifiedDevice) error {
	if device.DeviceID == "" {
		return fmt.Errorf("device ID is required")
	}

	log.Printf("Storing unified device %s", device.DeviceID)

	// Try to get existing device for merging
	existing, err := db.GetUnifiedDevice(ctx, device.DeviceID)
	if err == nil && existing != nil {
		// Merge discovery sources from both devices
		device = db.mergeUnifiedDevices(existing, device)
		log.Printf("Merged discovery sources for device %s", device.DeviceID)
	} else {
		log.Printf("Creating new unified device %s", device.DeviceID)
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO unified_devices_registry (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	// Convert discovery sources to JSON
	discoverySourcesJSON, err := json.Marshal(device.DiscoverySources)
	if err != nil {
		return fmt.Errorf("failed to marshal discovery sources: %w", err)
	}

	// Convert discovered fields to JSON
	hostnameJSON := "{}"
	if device.Hostname != nil {
		if data, err := json.Marshal(device.Hostname); err == nil {
			hostnameJSON = string(data)
		}
	}

	macJSON := "{}"
	if device.MAC != nil {
		if data, err := json.Marshal(device.MAC); err == nil {
			macJSON = string(data)
		}
	}

	metadataJSON := "{}"
	if device.Metadata != nil {
		if data, err := json.Marshal(device.Metadata); err == nil {
			metadataJSON = string(data)
		}
	}

	var lastHeartbeat interface{}
	if device.LastHeartbeat != nil {
		lastHeartbeat = *device.LastHeartbeat
	}

	if err := batch.Append(
		device.DeviceID,
		device.IP,
		hostnameJSON,
		macJSON,
		metadataJSON,
		string(discoverySourcesJSON),
		device.FirstSeen,
		device.LastSeen,
		device.IsAvailable,
		device.DeviceType,
		device.ServiceType,
		device.ServiceStatus,
		lastHeartbeat,
		device.OSInfo,
		device.VersionInfo,
	); err != nil {
		if batchErr := batch.Abort(); batchErr != nil {
			return batchErr
		}
		return fmt.Errorf("failed to append unified device %s: %w", device.DeviceID, err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to send batch: %w", err)
	}

	return nil
}

// StoreBatchUnifiedDevices stores multiple unified devices in a single batch operation
// Each device is merged with any existing device data before storage
func (db *DB) StoreBatchUnifiedDevices(ctx context.Context, devices []*models.UnifiedDevice) error {
	if len(devices) == 0 {
		return nil
	}

	log.Printf("Storing batch of %d unified devices with database-level merging", len(devices))

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO unified_devices_registry (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, device := range devices {
		if device.DeviceID == "" {
			log.Printf("Skipping device with empty ID in batch")
			continue
		}

		// Merge with existing device data, same as StoreUnifiedDevice does
		finalDevice := device
		if existing, err := db.GetUnifiedDevice(ctx, device.DeviceID); err == nil && existing != nil {
			// Merge discovery sources from both devices
			finalDevice = db.mergeUnifiedDevices(existing, device)
			log.Printf("Merged discovery sources for batch device %s", device.DeviceID)
		} else {
			log.Printf("Creating new unified device in batch %s", device.DeviceID)
		}

		// Convert discovery sources to JSON
		discoverySourcesJSON, err := json.Marshal(finalDevice.DiscoverySources)
		if err != nil {
			log.Printf("Failed to marshal discovery sources for device %s: %v", finalDevice.DeviceID, err)
			continue
		}

		// Convert discovered fields to JSON
		hostnameJSON := "{}"
		if finalDevice.Hostname != nil {
			if data, err := json.Marshal(finalDevice.Hostname); err == nil {
				hostnameJSON = string(data)
			}
		}

		macJSON := "{}"
		if finalDevice.MAC != nil {
			if data, err := json.Marshal(finalDevice.MAC); err == nil {
				macJSON = string(data)
			}
		}

		metadataJSON := "{}"
		if finalDevice.Metadata != nil {
			if data, err := json.Marshal(finalDevice.Metadata); err == nil {
				metadataJSON = string(data)
			}
		}

		var lastHeartbeat interface{}
		if finalDevice.LastHeartbeat != nil {
			lastHeartbeat = *finalDevice.LastHeartbeat
		}

		if err := batch.Append(
			finalDevice.DeviceID,
			finalDevice.IP,
			hostnameJSON,
			macJSON,
			metadataJSON,
			string(discoverySourcesJSON),
			finalDevice.FirstSeen,
			finalDevice.LastSeen,
			finalDevice.IsAvailable,
			finalDevice.DeviceType,
			finalDevice.ServiceType,
			finalDevice.ServiceStatus,
			lastHeartbeat,
			finalDevice.OSInfo,
			finalDevice.VersionInfo,
		); err != nil {
			log.Printf("Failed to append device %s to batch: %v", finalDevice.DeviceID, err)
			continue
		}
	}

	if err := batch.Send(); err != nil {
		if batchErr := batch.Abort(); batchErr != nil {
			return fmt.Errorf("failed to abort batch after send error: %w", batchErr)
		}
		return fmt.Errorf("failed to send batch: %w", err)
	}

	log.Printf("Successfully stored batch of %d unified devices", len(devices))
	return nil
}

// GetUnifiedDevice retrieves a unified device by its ID
func (db *DB) GetUnifiedDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	query := fmt.Sprintf(`SELECT
        device_id, ip, hostname_field, mac_field, metadata_field, discovery_sources,
        first_seen, last_seen, is_available, device_type, service_type, service_status,
        last_heartbeat, os_info, version_info
    FROM table(unified_devices_registry)
    WHERE device_id = '%s'
    LIMIT 1`, deviceID)

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer rows.Close()

	if !rows.Next() {
		return nil, fmt.Errorf("%w: %s", errUnifiedDeviceNotFound, deviceID)
	}

	device, err := db.scanUnifiedDevice(rows)
	if err != nil {
		return nil, err
	}

	return device, nil
}

// GetUnifiedDevicesByIP retrieves unified devices with a specific IP address
// This function searches both the primary IP field and alternate IPs in metadata
func (db *DB) GetUnifiedDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	query := fmt.Sprintf(`SELECT
        device_id, ip, hostname_field, mac_field, metadata_field, discovery_sources,
        first_seen, last_seen, is_available, device_type, service_type, service_status,
        last_heartbeat, os_info, version_info
    FROM table(unified_devices_registry)
    WHERE ip = '%s' 
       OR JSON_EXTRACT_STRING(metadata_field, '$.Value.alternate_ips') LIKE '%%"%s"%%'`, ip, ip)

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer rows.Close()

	var devices []*models.UnifiedDevice
	for rows.Next() {
		device, err := db.scanUnifiedDevice(rows)
		if err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: %w", errIterRows, err)
	}

	return devices, nil
}

// ListUnifiedDevices returns a list of unified devices with pagination
func (db *DB) ListUnifiedDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	query := fmt.Sprintf(`SELECT
        device_id, ip, hostname_field, mac_field, metadata_field, discovery_sources,
        first_seen, last_seen, is_available, device_type, service_type, service_status,
        last_heartbeat, os_info, version_info
    FROM table(unified_devices_registry)
    ORDER BY last_seen DESC
    LIMIT %d OFFSET %d`, limit, offset)

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer rows.Close()

	var devices []*models.UnifiedDevice
	for rows.Next() {
		device, err := db.scanUnifiedDevice(rows)
		if err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: %w", errIterRows, err)
	}

	return devices, nil
}

// scanUnifiedDevice scans a database row into a UnifiedDevice struct
func (db *DB) scanUnifiedDevice(rows Rows) (*models.UnifiedDevice, error) {
	var d models.UnifiedDevice
	var hostnameJSON, macJSON, metadataJSON, discoverySourcesJSON string
	var lastHeartbeat interface{}

	err := rows.Scan(
		&d.DeviceID,
		&d.IP,
		&hostnameJSON,
		&macJSON,
		&metadataJSON,
		&discoverySourcesJSON,
		&d.FirstSeen,
		&d.LastSeen,
		&d.IsAvailable,
		&d.DeviceType,
		&d.ServiceType,
		&d.ServiceStatus,
		&lastHeartbeat,
		&d.OSInfo,
		&d.VersionInfo,
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToScanUnifiedDeviceRow, err)
	}

	// Parse JSON fields
	if hostnameJSON != "" && hostnameJSON != "{}" {
		if err := json.Unmarshal([]byte(hostnameJSON), &d.Hostname); err != nil {
			log.Printf("Warning: failed to unmarshal hostname field for device %s: %v", d.DeviceID, err)
		}
	}

	if macJSON != "" && macJSON != "{}" {
		if err := json.Unmarshal([]byte(macJSON), &d.MAC); err != nil {
			log.Printf("Warning: failed to unmarshal MAC field for device %s: %v", d.DeviceID, err)
		}
	}

	if metadataJSON != "" && metadataJSON != "{}" {
		if err := json.Unmarshal([]byte(metadataJSON), &d.Metadata); err != nil {
			log.Printf("Warning: failed to unmarshal metadata field for device %s: %v", d.DeviceID, err)
		}
	}

	if discoverySourcesJSON != "" {
		if err := json.Unmarshal([]byte(discoverySourcesJSON), &d.DiscoverySources); err != nil {
			log.Printf("Warning: failed to unmarshal discovery sources for device %s: %v", d.DeviceID, err)
		}
	}

	// Handle last heartbeat
	if lastHeartbeat != nil {
		if ts, ok := lastHeartbeat.(string); ok {
			// Handle different timestamp formats if needed
			log.Printf("LastHeartbeat timestamp: %s for device %s", ts, d.DeviceID)
		}
	}

	return &d, nil
}

// mergeUnifiedDevices merges two unified devices, preserving discovery sources and updating fields
func (db *DB) mergeUnifiedDevices(existing, new *models.UnifiedDevice) *models.UnifiedDevice {
	// Start with the new device as base
	merged := &models.UnifiedDevice{
		DeviceID:       new.DeviceID,
		IP:             new.IP,
		FirstSeen:      existing.FirstSeen, // Keep original first seen
		LastSeen:       new.LastSeen,       // Update to latest
		IsAvailable:    new.IsAvailable,    // Update availability
		DeviceType:     new.DeviceType,
		ServiceType:    new.ServiceType,
		ServiceStatus:  new.ServiceStatus,
		LastHeartbeat:  new.LastHeartbeat,
		OSInfo:         new.OSInfo,
		VersionInfo:    new.VersionInfo,
	}

	// Merge discovery sources - create a map to avoid duplicates
	sourceMap := make(map[string]models.DiscoverySourceInfo)
	
	// Add existing sources
	for _, source := range existing.DiscoverySources {
		key := fmt.Sprintf("%s-%s-%s", source.Source, source.AgentID, source.PollerID)
		sourceMap[key] = source
	}
	
	// Add new sources, updating last seen if they already exist
	for _, source := range new.DiscoverySources {
		key := fmt.Sprintf("%s-%s-%s", source.Source, source.AgentID, source.PollerID)
		if existingSource, exists := sourceMap[key]; exists {
			// Update existing source with latest timestamp
			existingSource.LastSeen = source.LastSeen
			sourceMap[key] = existingSource
		} else {
			// Add new source
			sourceMap[key] = source
		}
	}
	
	// Convert map back to slice
	merged.DiscoverySources = make([]models.DiscoverySourceInfo, 0, len(sourceMap))
	for _, source := range sourceMap {
		merged.DiscoverySources = append(merged.DiscoverySources, source)
	}

	// Merge hostname - prefer higher confidence or newer data
	if new.Hostname != nil {
		if existing.Hostname == nil || db.shouldUpdateDiscoveredField(existing.Hostname, new.Hostname) {
			merged.Hostname = new.Hostname
		} else {
			merged.Hostname = existing.Hostname
		}
	} else {
		merged.Hostname = existing.Hostname
	}

	// Merge MAC - prefer higher confidence or newer data
	if new.MAC != nil {
		if existing.MAC == nil || db.shouldUpdateDiscoveredField(existing.MAC, new.MAC) {
			merged.MAC = new.MAC
		} else {
			merged.MAC = existing.MAC
		}
	} else {
		merged.MAC = existing.MAC
	}

	// Merge metadata - combine both, with new values taking precedence
	if new.Metadata != nil || existing.Metadata != nil {
		mergedMetadata := make(map[string]string)
		
		// Start with existing metadata
		if existing.Metadata != nil {
			for k, v := range existing.Metadata.Value {
				mergedMetadata[k] = v
			}
		}
		
		// Overlay new metadata
		if new.Metadata != nil {
			for k, v := range new.Metadata.Value {
				mergedMetadata[k] = v
			}
			
			// Use new metadata field properties but with merged values
			merged.Metadata = &models.DiscoveredField[map[string]string]{
				Value:       mergedMetadata,
				Source:      new.Metadata.Source,
				LastUpdated: new.Metadata.LastUpdated,
				Confidence:  new.Metadata.Confidence,
				AgentID:     new.Metadata.AgentID,
				PollerID:    new.Metadata.PollerID,
			}
		} else if existing.Metadata != nil {
			merged.Metadata = existing.Metadata
		}
	}

	log.Printf("Merged device %s: %d discovery sources", merged.DeviceID, len(merged.DiscoverySources))
	return merged
}

// shouldUpdateDiscoveredField determines if a discovered field should be updated based on confidence
func (db *DB) shouldUpdateDiscoveredField(existing, new *models.DiscoveredField[string]) bool {
	if existing == nil {
		return true // Always update if no existing field
	}
	if new == nil {
		return false // Don't update if new field is nil
	}
	
	// Update if new confidence is higher
	if new.Confidence > existing.Confidence {
		return true
	}
	
	// Update if same confidence but newer timestamp
	if new.Confidence == existing.Confidence && new.LastUpdated.After(existing.LastUpdated) {
		return true
	}
	
	return false
}

// MarkDeviceAsMerged adds metadata to indicate a device has been merged into another device
func (db *DB) MarkDeviceAsMerged(ctx context.Context, deviceID, mergedIntoDeviceID string) error {
	if deviceID == "" || mergedIntoDeviceID == "" {
		return fmt.Errorf("both device IDs are required")
	}

	log.Printf("Marking device %s as merged into %s", deviceID, mergedIntoDeviceID)

	// Get the existing device first
	device, err := db.GetUnifiedDevice(ctx, deviceID)
	if err != nil {
		return fmt.Errorf("failed to get device to mark as merged: %w", err)
	}

	// Add merge metadata
	if device.Metadata == nil {
		device.Metadata = &models.DiscoveredField[map[string]string]{
			Value: make(map[string]string),
		}
	}
	
	device.Metadata.Value["_merged_into"] = mergedIntoDeviceID
	device.Metadata.Value["_merged_at"] = time.Now().Format(time.RFC3339)

	// Store the updated device
	return db.StoreUnifiedDevice(ctx, device)
}