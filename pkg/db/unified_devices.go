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

	// This function has special handling for the case where no rows are returned,
	// so we can't use the queryUnifiedDevices helper
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

// queryUnifiedDevicesWithArgs executes a parameterized query and returns a slice of UnifiedDevice objects
func (db *DB) queryUnifiedDevicesWithArgs(ctx context.Context, query string, args ...interface{}) ([]*models.UnifiedDevice, error) {
	rows, err := db.Conn.Query(ctx, query, args...)
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

// GetUnifiedDevicesByIP retrieves unified devices with a specific IP address
// Searches both primary IP field and alternate IPs in metadata using materialized view approach
func (db *DB) GetUnifiedDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	query := `SELECT
        device_id, ip, poller_id, hostname, mac, discovery_sources,
        is_available, first_seen, last_seen, metadata, agent_id, device_type, 
        service_type, service_status, last_heartbeat, os_info, version_info
    FROM table(unified_devices)
    WHERE ip = $1 OR has(map_keys(metadata), 'alternate_ips') AND position(metadata['alternate_ips'], $2) > 0
    ORDER BY _tp_time DESC`

	return db.queryUnifiedDevicesWithArgs(ctx, query, ip, ip)
}

// ListUnifiedDevices returns a list of unified devices with pagination using materialized view approach
func (db *DB) ListUnifiedDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	query := `SELECT
        device_id, ip, poller_id, hostname, mac, discovery_sources,
        is_available, first_seen, last_seen, metadata, agent_id, device_type, 
        service_type, service_status, last_heartbeat, os_info, version_info
    FROM table(unified_devices)
    WHERE NOT has(map_keys(metadata), '_merged_into')
    ORDER BY last_seen DESC
    LIMIT $1 OFFSET $2`

	return db.queryUnifiedDevicesWithArgs(ctx, query, limit, offset)
}

// scanUnifiedDeviceSimple scans a database row from the new unified_devices stream into a UnifiedDevice struct
// This works with the materialized view approach using simpler data types
func (*DB) scanUnifiedDeviceSimple(rows Rows) (*models.UnifiedDevice, error) {
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
	if len(metadata) > 0 {
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

// GetUnifiedDevicesByIPsOrIDs fetches all potential candidate devices for a batch of IPs and Device IDs.
// Uses materialized view approach for efficient batch lookups
func (db *DB) GetUnifiedDevicesByIPsOrIDs(ctx context.Context, ips, deviceIDs []string) ([]*models.UnifiedDevice, error) {
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
			conditions = append(conditions,
				fmt.Sprintf("has(map_keys(metadata), 'alternate_ips') "+
					"AND position(metadata['alternate_ips'], '%s') > 0", ip))
		}
	}

	query := fmt.Sprintf(`SELECT
        device_id, ip, poller_id, hostname, mac, discovery_sources,
        is_available, first_seen, last_seen, metadata, agent_id, device_type, 
        service_type, service_status, last_heartbeat, os_info, version_info
    FROM table(unified_devices)
    WHERE %s
    ORDER BY _tp_time DESC`, strings.Join(conditions, " OR "))

	// Special handling for batch queries - we want to log warnings but continue if a single row fails
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
