/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package db

import (
	"context"
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
	errFailedToUpdateUnifiedDevice  = errors.New("failed to update unified device")
	errFailedToInsertUnifiedDevice  = errors.New("failed to insert unified device")
	errInvalidDeviceID              = errors.New("invalid device ID")
	errInvalidDiscoverySource       = errors.New("invalid discovery source")
)

// GetUnifiedDevice retrieves a device from the unified_devices versioned KV store by device ID.
func (db *DB) GetUnifiedDevice(ctx context.Context, deviceID string) (*models.Device, error) {
	if deviceID == "" {
		return nil, fmt.Errorf("%w: device ID cannot be empty", errInvalidDeviceID)
	}

	query := `SELECT
        device_id, agent_id, poller_id, discovery_sources, ip, mac, hostname,
        first_seen, last_seen, is_available, metadata, os_info, version_info,
        device_type, service_type, service_status, last_heartbeat
    FROM table(unified_devices)
    WHERE device_id = ?
    LIMIT 1`

	rows, err := db.Conn.Query(ctx, query, deviceID)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer rows.Close()

	if !rows.Next() {
		return nil, fmt.Errorf("%w: %s", errUnifiedDeviceNotFound, deviceID)
	}

	var d models.Device
	var osInfo, versionInfo, deviceType, serviceType, serviceStatus *string
	var lastHeartbeat *time.Time
	var metadata map[string]string

	err = rows.Scan(
		&d.DeviceID,
		&d.AgentID,
		&d.PollerID,
		&d.DiscoverySources,
		&d.IP,
		&d.MAC,
		&d.Hostname,
		&d.FirstSeen,
		&d.LastSeen,
		&d.IsAvailable,
		&metadata,
		&osInfo,
		&versionInfo,
		&deviceType,
		&serviceType,
		&serviceStatus,
		&lastHeartbeat,
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToScanUnifiedDeviceRow, err)
	}

	// Convert metadata map to interface{} map
	if metadata != nil {
		d.Metadata = make(map[string]interface{})
		for k, v := range metadata {
			d.Metadata[k] = v
		}
	}

	// Add additional metadata fields if they exist
	if osInfo != nil {
		if d.Metadata == nil {
			d.Metadata = make(map[string]interface{})
		}
		d.Metadata["os_info"] = *osInfo
	}
	if versionInfo != nil {
		if d.Metadata == nil {
			d.Metadata = make(map[string]interface{})
		}
		d.Metadata["version_info"] = *versionInfo
	}
	if deviceType != nil {
		if d.Metadata == nil {
			d.Metadata = make(map[string]interface{})
		}
		d.Metadata["device_type"] = *deviceType
	}
	if serviceType != nil {
		if d.Metadata == nil {
			d.Metadata = make(map[string]interface{})
		}
		d.Metadata["service_type"] = *serviceType
	}
	if serviceStatus != nil {
		if d.Metadata == nil {
			d.Metadata = make(map[string]interface{})
		}
		d.Metadata["service_status"] = *serviceStatus
	}
	if lastHeartbeat != nil {
		if d.Metadata == nil {
			d.Metadata = make(map[string]interface{})
		}
		d.Metadata["last_heartbeat"] = lastHeartbeat.Format(time.RFC3339)
	}

	return &d, nil
}

// UpdateUnifiedDevice updates or inserts a device in the unified_devices versioned KV store.
// This method handles the versioned KV store semantics properly by using INSERT operations.
// For versioned KV stores, INSERT with the same primary key creates a new version of the record.
func (db *DB) UpdateUnifiedDevice(ctx context.Context, device *models.Device) error {
	if device == nil {
		return fmt.Errorf("%w: device cannot be nil", errInvalidDeviceID)
	}
	if device.DeviceID == "" {
		return fmt.Errorf("%w: device ID cannot be empty", errInvalidDeviceID)
	}

	log.Printf("Updating unified device: %s", device.DeviceID)

	// For versioned KV stores in Proton/ClickHouse, we use INSERT to create new versions
	// The versioned KV store will automatically handle versioning with _tp_time
	query := `INSERT INTO unified_devices (
        device_id, agent_id, poller_id, discovery_sources, ip, mac, hostname,
        first_seen, last_seen, is_available, metadata, os_info, version_info,
        device_type, service_type, service_status, last_heartbeat
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

	// Convert metadata to map[string]string format expected by the database
	metadata := make(map[string]string)
	var osInfo, versionInfo, deviceType, serviceType, serviceStatus *string
	var lastHeartbeat *time.Time

	if device.Metadata != nil {
		for k, v := range device.Metadata {
			switch k {
			case "os_info":
				if str, ok := v.(string); ok {
					osInfo = &str
				}
			case "version_info":
				if str, ok := v.(string); ok {
					versionInfo = &str
				}
			case "device_type":
				if str, ok := v.(string); ok {
					deviceType = &str
				}
			case "service_type":
				if str, ok := v.(string); ok {
					serviceType = &str
				}
			case "service_status":
				if str, ok := v.(string); ok {
					serviceStatus = &str
				}
			case "last_heartbeat":
				if str, ok := v.(string); ok {
					if t, err := time.Parse(time.RFC3339, str); err == nil {
						lastHeartbeat = &t
					}
				}
			default:
				metadata[k] = fmt.Sprintf("%v", v)
			}
		}
	}

	// Ensure valid timestamps
	firstSeen := device.FirstSeen
	if firstSeen.IsZero() {
		firstSeen = time.Now()
	}
	lastSeen := device.LastSeen
	if lastSeen.IsZero() {
		lastSeen = time.Now()
	}

	// Validate timestamps are within acceptable range
	if !isValidTimestamp(firstSeen) {
		firstSeen = time.Now()
	}
	if !isValidTimestamp(lastSeen) {
		lastSeen = time.Now()
	}

	_, err := db.Conn.Exec(ctx, query,
		device.DeviceID,
		device.AgentID,
		device.PollerID,
		device.DiscoverySources,
		device.IP,
		device.MAC,
		device.Hostname,
		firstSeen,
		lastSeen,
		device.IsAvailable,
		metadata,
		osInfo,
		versionInfo,
		deviceType,
		serviceType,
		serviceStatus,
		lastHeartbeat,
	)
	if err != nil {
		return fmt.Errorf("%w: %w", errFailedToUpdateUnifiedDevice, err)
	}

	log.Printf("Successfully updated unified device: %s", device.DeviceID)
	return nil
}

// AddDiscoverySource adds a discovery source to a device's discovery_sources array if not already present.
// This method handles the versioned KV store semantics by first retrieving the current device,
// updating the discovery sources array, and then inserting the updated record.
func (db *DB) AddDiscoverySource(ctx context.Context, deviceID string, source string) error {
	if deviceID == "" {
		return fmt.Errorf("%w: device ID cannot be empty", errInvalidDeviceID)
	}
	if source == "" {
		return fmt.Errorf("%w: discovery source cannot be empty", errInvalidDiscoverySource)
	}

	log.Printf("Adding discovery source '%s' to device: %s", source, deviceID)

	// First, try to get the existing device
	existingDevice, err := db.GetUnifiedDevice(ctx, deviceID)
	if err != nil {
		if errors.Is(err, errUnifiedDeviceNotFound) {
			// Device doesn't exist, cannot add source to non-existent device
			return fmt.Errorf("%w: cannot add discovery source to non-existent device %s", errUnifiedDeviceNotFound, deviceID)
		}
		return fmt.Errorf("failed to get existing device: %w", err)
	}

	// Check if the source already exists in the discovery_sources array
	for _, existingSource := range existingDevice.DiscoverySources {
		if existingSource == source {
			log.Printf("Discovery source '%s' already exists for device: %s", source, deviceID)
			return nil // Source already exists, nothing to do
		}
	}

	// Add the new source to the array
	existingDevice.DiscoverySources = append(existingDevice.DiscoverySources, source)
	existingDevice.LastSeen = time.Now()

	// Update the device with the new discovery sources
	if err := db.UpdateUnifiedDevice(ctx, existingDevice); err != nil {
		return fmt.Errorf("failed to update device with new discovery source: %w", err)
	}

	log.Printf("Successfully added discovery source '%s' to device: %s", source, deviceID)
	return nil
}

// UpsertUnifiedDevice creates or updates a device in the unified_devices versioned KV store.
// If the device exists, it merges the discovery sources and updates other fields.
// If the device doesn't exist, it creates a new record.
func (db *DB) UpsertUnifiedDevice(ctx context.Context, device *models.Device) error {
	if device == nil {
		return fmt.Errorf("%w: device cannot be nil", errInvalidDeviceID)
	}
	if device.DeviceID == "" {
		return fmt.Errorf("%w: device ID cannot be empty", errInvalidDeviceID)
	}

	log.Printf("Upserting unified device: %s", device.DeviceID)

	// Try to get the existing device
	existingDevice, err := db.GetUnifiedDevice(ctx, device.DeviceID)
	if err != nil && !errors.Is(err, errUnifiedDeviceNotFound) {
		return fmt.Errorf("failed to get existing device: %w", err)
	}

	if existingDevice != nil {
		// Device exists, merge the data
		log.Printf("Device %s exists, merging data", device.DeviceID)

		// Merge discovery sources
		discoverySourcesSet := make(map[string]bool)
		for _, source := range existingDevice.DiscoverySources {
			discoverySourcesSet[source] = true
		}
		for _, source := range device.DiscoverySources {
			discoverySourcesSet[source] = true
		}

		// Convert back to slice
		var mergedSources []string
		for source := range discoverySourcesSet {
			mergedSources = append(mergedSources, source)
		}
		device.DiscoverySources = mergedSources

		// Preserve first_seen from existing device
		if !existingDevice.FirstSeen.IsZero() {
			device.FirstSeen = existingDevice.FirstSeen
		}

		// Use the newer last_seen
		if device.LastSeen.IsZero() || (!existingDevice.LastSeen.IsZero() && existingDevice.LastSeen.After(device.LastSeen)) {
			device.LastSeen = existingDevice.LastSeen
		}

		// Merge metadata
		if existingDevice.Metadata != nil && device.Metadata != nil {
			for k, v := range existingDevice.Metadata {
				if _, exists := device.Metadata[k]; !exists {
					device.Metadata[k] = v
				}
			}
		} else if existingDevice.Metadata != nil && device.Metadata == nil {
			device.Metadata = existingDevice.Metadata
		}

		// Preserve other fields if they're empty in the new device
		if device.AgentID == "" && existingDevice.AgentID != "" {
			device.AgentID = existingDevice.AgentID
		}
		if device.PollerID == "" && existingDevice.PollerID != "" {
			device.PollerID = existingDevice.PollerID
		}
		if device.MAC == "" && existingDevice.MAC != "" {
			device.MAC = existingDevice.MAC
		}
		if device.Hostname == "" && existingDevice.Hostname != "" {
			device.Hostname = existingDevice.Hostname
		}
	} else {
		// Device doesn't exist, set defaults
		log.Printf("Device %s doesn't exist, creating new record", device.DeviceID)
		if device.FirstSeen.IsZero() {
			device.FirstSeen = time.Now()
		}
		if device.LastSeen.IsZero() {
			device.LastSeen = time.Now()
		}
	}

	// Update the device
	if err := db.UpdateUnifiedDevice(ctx, device); err != nil {
		return fmt.Errorf("failed to upsert device: %w", err)
	}

	log.Printf("Successfully upserted unified device: %s", device.DeviceID)
	return nil
}

// DeleteUnifiedDevice deletes a device from the unified_devices versioned KV store.
// For versioned KV stores in Proton/ClickHouse, DELETE operations create a tombstone record.
// This method marks the device as deleted rather than physically removing it.
func (db *DB) DeleteUnifiedDevice(ctx context.Context, deviceID string) error {
	if deviceID == "" {
		return fmt.Errorf("%w: device ID cannot be empty", errInvalidDeviceID)
	}

	log.Printf("Deleting unified device: %s", deviceID)

	// For versioned KV stores, DELETE operations create tombstone records
	query := `DELETE FROM unified_devices WHERE device_id = ?`
	
	_, err := db.Conn.Exec(ctx, query, deviceID)
	if err != nil {
		return fmt.Errorf("failed to delete unified device: %w", err)
	}

	log.Printf("Successfully deleted unified device: %s", deviceID)
	return nil
}

// ListUnifiedDevices retrieves all devices from the unified_devices versioned KV store with optional filtering.
func (db *DB) ListUnifiedDevices(ctx context.Context, pollerID string, limit int) ([]*models.Device, error) {
	var query string
	var args []interface{}

	if pollerID != "" {
		query = `SELECT
            device_id, agent_id, poller_id, discovery_sources, ip, mac, hostname,
            first_seen, last_seen, is_available, metadata, os_info, version_info,
            device_type, service_type, service_status, last_heartbeat
        FROM table(unified_devices)
        WHERE poller_id = ?
        ORDER BY last_seen DESC`
		args = append(args, pollerID)
	} else {
		query = `SELECT
            device_id, agent_id, poller_id, discovery_sources, ip, mac, hostname,
            first_seen, last_seen, is_available, metadata, os_info, version_info,
            device_type, service_type, service_status, last_heartbeat
        FROM table(unified_devices)
        ORDER BY last_seen DESC`
	}

	if limit > 0 {
		query += fmt.Sprintf(" LIMIT %d", limit)
	}

	rows, err := db.Conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer rows.Close()

	var devices []*models.Device

	for rows.Next() {
		var d models.Device
		var osInfo, versionInfo, deviceType, serviceType, serviceStatus *string
		var lastHeartbeat *time.Time
		var metadata map[string]string

		err := rows.Scan(
			&d.DeviceID,
			&d.AgentID,
			&d.PollerID,
			&d.DiscoverySources,
			&d.IP,
			&d.MAC,
			&d.Hostname,
			&d.FirstSeen,
			&d.LastSeen,
			&d.IsAvailable,
			&metadata,
			&osInfo,
			&versionInfo,
			&deviceType,
			&serviceType,
			&serviceStatus,
			&lastHeartbeat,
		)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", errFailedToScanUnifiedDeviceRow, err)
		}

		// Convert metadata map to interface{} map and add additional fields
		if metadata != nil {
			d.Metadata = make(map[string]interface{})
			for k, v := range metadata {
				d.Metadata[k] = v
			}
		}

		// Add additional metadata fields if they exist
		if osInfo != nil {
			if d.Metadata == nil {
				d.Metadata = make(map[string]interface{})
			}
			d.Metadata["os_info"] = *osInfo
		}
		if versionInfo != nil {
			if d.Metadata == nil {
				d.Metadata = make(map[string]interface{})
			}
			d.Metadata["version_info"] = *versionInfo
		}
		if deviceType != nil {
			if d.Metadata == nil {
				d.Metadata = make(map[string]interface{})
			}
			d.Metadata["device_type"] = *deviceType
		}
		if serviceType != nil {
			if d.Metadata == nil {
				d.Metadata = make(map[string]interface{})
			}
			d.Metadata["service_type"] = *serviceType
		}
		if serviceStatus != nil {
			if d.Metadata == nil {
				d.Metadata = make(map[string]interface{})
			}
			d.Metadata["service_status"] = *serviceStatus
		}
		if lastHeartbeat != nil {
			if d.Metadata == nil {
				d.Metadata = make(map[string]interface{})
			}
			d.Metadata["last_heartbeat"] = lastHeartbeat.Format(time.RFC3339)
		}

		devices = append(devices, &d)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: %w", errIterRows, err)
	}

	return devices, nil
}