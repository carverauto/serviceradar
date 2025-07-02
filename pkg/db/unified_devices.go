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

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errFailedToScanUnifiedDeviceRow = errors.New("failed to scan unified device row")
	errUnifiedDeviceNotFound        = errors.New("unified device not found")
	errFailedToQueryUnifiedDevice   = errors.New("failed to query unified device")
)

// StoreUnifiedDevice stores a unified device into the unified_devices_registry stream
func (db *DB) StoreUnifiedDevice(ctx context.Context, device *models.UnifiedDevice) error {
	if device.DeviceID == "" {
		return fmt.Errorf("device ID is required")
	}

	log.Printf("Storing unified device %s", device.DeviceID)

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
func (db *DB) GetUnifiedDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	query := fmt.Sprintf(`SELECT
        device_id, ip, hostname_field, mac_field, metadata_field, discovery_sources,
        first_seen, last_seen, is_available, device_type, service_type, service_status,
        last_heartbeat, os_info, version_info
    FROM table(unified_devices_registry)
    WHERE ip = '%s'`, ip)

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