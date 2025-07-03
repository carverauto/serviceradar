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
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errFailedToScanUnifiedDeviceRow = errors.New("failed to scan unified device row")
	errUnifiedDeviceNotFound        = errors.New("unified device not found")
	errFailedToQueryUnifiedDevice   = errors.New("failed to query unified device")
)

// StoreUnifiedDevice is deprecated with materialized view approach
// Use PublishSweepResult instead - the materialized view handles device creation/updates
func (db *DB) StoreUnifiedDevice(ctx context.Context, device *models.UnifiedDevice) error {
	log.Printf("WARNING: StoreUnifiedDevice is deprecated with materialized view approach. Use PublishSweepResult instead.")
	return fmt.Errorf("StoreUnifiedDevice is deprecated - use PublishSweepResult instead")
}

// StoreBatchUnifiedDevices is deprecated with materialized view approach  
// Use PublishBatchSweepResults instead - the materialized view handles device creation/updates
func (db *DB) StoreBatchUnifiedDevices(ctx context.Context, devices []*models.UnifiedDevice) error {
	log.Printf("WARNING: StoreBatchUnifiedDevices is deprecated with materialized view approach. Use PublishBatchSweepResults instead.")
	return fmt.Errorf("StoreBatchUnifiedDevices is deprecated - use PublishBatchSweepResults instead")
}

// GetUnifiedDevice retrieves a unified device by its ID (latest version)
// Uses materialized view approach - reads from unified_devices stream
func (db *DB) GetUnifiedDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	query := fmt.Sprintf(`SELECT
        device_id, ip, poller_id, hostname, mac, discovery_sources,
        is_available, first_seen, last_seen, metadata, agent_id, device_type, 
        service_type, service_status, last_heartbeat, os_info, version_info
    FROM table(unified_devices)
    WHERE device_id = '%s'
    ORDER BY _tp_time DESC
    LIMIT 1`, deviceID)

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer rows.Close()

	if !rows.Next() {
		return nil, fmt.Errorf("%w: %s", errUnifiedDeviceNotFound, deviceID)
	}

	device, err := db.scanUnifiedDeviceSimple(rows)
	if err != nil {
		return nil, err
	}

	return device, nil
}

// GetUnifiedDevicesByIP retrieves unified devices with a specific IP address
// Searches both primary IP field and alternate IPs in metadata using materialized view approach
func (db *DB) GetUnifiedDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	query := fmt.Sprintf(`SELECT
        device_id, ip, poller_id, hostname, mac, discovery_sources,
        is_available, first_seen, last_seen, metadata, agent_id, device_type, 
        service_type, service_status, last_heartbeat, os_info, version_info
    FROM table(unified_devices)
    WHERE ip = '%s' OR has(map_keys(metadata), 'alternate_ips') AND position(metadata['alternate_ips'], '%s') > 0
    ORDER BY _tp_time DESC`, ip, ip)

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer rows.Close()

	var devices []*models.UnifiedDevice
	for rows.Next() {
		device, err := db.scanUnifiedDeviceSimple(rows)
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

// ListUnifiedDevices returns a list of unified devices with pagination using materialized view approach
func (db *DB) ListUnifiedDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	query := fmt.Sprintf(`SELECT
        device_id, ip, poller_id, hostname, mac, discovery_sources,
        is_available, first_seen, last_seen, metadata, agent_id, device_type, 
        service_type, service_status, last_heartbeat, os_info, version_info
    FROM table(unified_devices)
    WHERE NOT has(map_keys(metadata), '_merged_into')
    ORDER BY last_seen DESC
    LIMIT %d OFFSET %d`, limit, offset)

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer rows.Close()

	var devices []*models.UnifiedDevice
	for rows.Next() {
		device, err := db.scanUnifiedDeviceSimple(rows)
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

// scanUnifiedDeviceSimple scans a database row from the new unified_devices stream into a UnifiedDevice struct
// This works with the materialized view approach using simpler data types
func (db *DB) scanUnifiedDeviceSimple(rows Rows) (*models.UnifiedDevice, error) {
	var d models.UnifiedDevice
	var hostname, mac, serviceType, serviceStatus, osInfo, versionInfo *string
	var lastHeartbeat *time.Time
	var discoverySources []string
	var metadata map[string]string
	var pollerID, agentID string

	err := rows.Scan(
		&d.DeviceID,
		&d.IP,
		&pollerID,
		&hostname,
		&mac,
		&discoverySources,
		&d.IsAvailable,
		&d.FirstSeen,
		&d.LastSeen,
		&metadata,
		&agentID,
		&d.DeviceType,
		&serviceType,
		&serviceStatus,
		&lastHeartbeat,
		&osInfo,
		&versionInfo,
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToScanUnifiedDeviceRow, err)
	}

	// Set optional string fields
	if serviceType != nil {
		d.ServiceType = *serviceType
	}
	if serviceStatus != nil {
		d.ServiceStatus = *serviceStatus
	}
	if osInfo != nil {
		d.OSInfo = *osInfo
	}
	if versionInfo != nil {
		d.VersionInfo = *versionInfo
	}
	d.LastHeartbeat = lastHeartbeat

	// Convert simple hostname to DiscoveredField if needed
	if hostname != nil && *hostname != "" {
		d.Hostname = &models.DiscoveredField[string]{
			Value: *hostname,
		}
	}

	// Convert simple MAC to DiscoveredField if needed
	if mac != nil && *mac != "" {
		d.MAC = &models.DiscoveredField[string]{
			Value: *mac,
		}
	}

	// Convert simple metadata map to DiscoveredField if needed
	if metadata != nil && len(metadata) > 0 {
		d.Metadata = &models.DiscoveredField[map[string]string]{
			Value: metadata,
		}
	}

	// Parse discovery sources - ClickHouse returns array(string) as []string directly
	if len(discoverySources) > 0 {
		// Convert simple strings to DiscoverySourceInfo structs
		d.DiscoverySources = make([]models.DiscoverySourceInfo, len(discoverySources))
		for i, source := range discoverySources {
			d.DiscoverySources[i] = models.DiscoverySourceInfo{
				Source: models.DiscoverySource(source),
			}
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

// MarkDeviceAsMerged is deprecated with materialized view approach
// Device merging is handled automatically by the materialized view
func (db *DB) MarkDeviceAsMerged(ctx context.Context, deviceID, mergedIntoDeviceID string) error {
	log.Printf("WARNING: MarkDeviceAsMerged is deprecated with materialized view approach. Device merging is automatic.")
	return nil // Don't fail, just ignore since merging is automatic
}

// GetUnifiedDevicesByIPsOrIDs fetches all potential candidate devices for a batch of IPs and Device IDs.
// Uses materialized view approach for efficient batch lookups
func (db *DB) GetUnifiedDevicesByIPsOrIDs(ctx context.Context, ips []string, deviceIDs []string) ([]*models.UnifiedDevice, error) {
	if len(ips) == 0 && len(deviceIDs) == 0 {
		return nil, nil
	}

	// Build the WHERE clause dynamically
	var conditions []string
	
	// Add device ID conditions
	if len(deviceIDs) > 0 {
		deviceIDList := make([]string, len(deviceIDs))
		for i, id := range deviceIDs {
			deviceIDList[i] = fmt.Sprintf("'%s'", id)
		}
		conditions = append(conditions, fmt.Sprintf("device_id IN (%s)", strings.Join(deviceIDList, ",")))
	}
	
	// Add IP conditions (both primary IP and alternate IPs)
	if len(ips) > 0 {
		ipList := make([]string, len(ips))
		for i, ip := range ips {
			ipList[i] = fmt.Sprintf("'%s'", ip)
		}
		conditions = append(conditions, fmt.Sprintf("ip IN (%s)", strings.Join(ipList, ",")))
		
		// Also check if any of the incoming IPs exist in the 'alternate_ips' metadata
		for _, ip := range ips {
			conditions = append(conditions, fmt.Sprintf("has(map_keys(metadata), 'alternate_ips') AND position(metadata['alternate_ips'], '%s') > 0", ip))
		}
	}

	query := fmt.Sprintf(`SELECT
        device_id, ip, poller_id, hostname, mac, discovery_sources,
        is_available, first_seen, last_seen, metadata, agent_id, device_type, 
        service_type, service_status, last_heartbeat, os_info, version_info
    FROM table(unified_devices)
    WHERE %s
    ORDER BY _tp_time DESC`, strings.Join(conditions, " OR "))

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to batch query unified devices: %w", err)
	}
	defer rows.Close()

	var devices []*models.UnifiedDevice
	for rows.Next() {
		device, err := db.scanUnifiedDeviceSimple(rows)
		if err != nil {
			log.Printf("Warning: failed to scan unified device in batch fetch: %v", err)
			continue
		}
		devices = append(devices, device)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: %w", errIterRows, err)
	}

	return devices, nil
}