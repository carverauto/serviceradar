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
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errFailedToScanUnifiedDeviceRow = errors.New("failed to scan unified device row")
	errUnifiedDeviceNotFound        = errors.New("unified device not found")
	errFailedToQueryUnifiedDevice   = errors.New("failed to query unified device")
)

const unifiedDeviceBatchLimit = 200

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
    LIMIT 1`, escapeLiteral(deviceID))

	// This function has special handling for the case where no rows are returned,
	// so we can't use the queryUnifiedDevices helper
	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer func() { _ = rows.Close() }()

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
	defer func() { _ = rows.Close() }()

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
    WHERE ip = $1
    ORDER BY _tp_time DESC`

	return db.queryUnifiedDevicesWithArgs(ctx, query, ip)
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
	ips = dedupeStrings(ips)
	deviceIDs = dedupeStrings(deviceIDs)

	if len(ips) == 0 && len(deviceIDs) == 0 {
		return nil, nil
	}

	resultByID := make(map[string]*models.UnifiedDevice)

	collect := func(batch []*models.UnifiedDevice) {
		for _, device := range batch {
			if device == nil {
				continue
			}
			resultByID[device.DeviceID] = device
		}
	}

	queryBatch := func(ids, address []string) error {
		if len(ids) == 0 && len(address) == 0 {
			return nil
		}

		devices, err := db.queryUnifiedDeviceBatch(ctx, ids, address)
		if err != nil {
			return err
		}

		collect(devices)

		return nil
	}

	for _, chunk := range chunkStrings(deviceIDs, unifiedDeviceBatchLimit) {
		if err := queryBatch(chunk, nil); err != nil {
			return nil, err
		}
	}

	for _, chunk := range chunkStrings(ips, unifiedDeviceBatchLimit) {
		if err := queryBatch(nil, chunk); err != nil {
			return nil, err
		}
	}

	if len(resultByID) == 0 {
		return nil, nil
	}

	results := make([]*models.UnifiedDevice, 0, len(resultByID))
	for _, device := range resultByID {
		results = append(results, device)
	}

	sort.Slice(results, func(i, j int) bool {
		return results[i].LastSeen.After(results[j].LastSeen)
	})

	return results, nil
}

func (db *DB) queryUnifiedDeviceBatch(ctx context.Context, deviceIDs, ips []string) ([]*models.UnifiedDevice, error) {
	var conditions []string
	var withClauses []string

	if len(deviceIDs) > 0 {
		withClauses = append(withClauses, fmt.Sprintf(`device_candidates AS (
        SELECT device_id
        FROM VALUES('device_id string', %s)
    )`, joinValueTuples(deviceIDs)))
		conditions = append(conditions, "device_id IN (SELECT device_id FROM device_candidates)")
	}

	if len(ips) > 0 {
		withClauses = append(withClauses, fmt.Sprintf(`ip_candidates AS (
        SELECT ip
        FROM VALUES('ip string', %s)
    )`, joinValueTuples(ips)))
		conditions = append(conditions, "ip IN (SELECT ip FROM ip_candidates)")
	}

	query := fmt.Sprintf(`%sSELECT
        device_id, ip, poller_id, hostname, mac, discovery_sources,
        is_available, first_seen, last_seen, metadata, agent_id, device_type, 
        service_type, service_status, last_heartbeat, os_info, version_info
    FROM table(unified_devices)
    WHERE %s
    ORDER BY _tp_time DESC`, buildWithClause(withClauses), strings.Join(conditions, " OR "))

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to batch query unified devices: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var devices []*models.UnifiedDevice

	for rows.Next() {
		device, err := db.scanUnifiedDeviceSimple(rows)
		if err != nil {
			db.logger.Warn().Err(err).Msg("Failed to scan unified device in batch fetch")
			continue
		}

		devices = append(devices, device)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: %w", errIterRows, err)
	}

	return devices, nil
}

func chunkStrings(values []string, limit int) [][]string {
	if len(values) == 0 || limit <= 0 {
		return nil
	}

	var chunks [][]string
	for start := 0; start < len(values); start += limit {
		end := start + limit
		if end > len(values) {
			end = len(values)
		}
		chunk := values[start:end]
		if len(chunk) > 0 {
			chunks = append(chunks, chunk)
		}
	}

	return chunks
}

func dedupeStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}

	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}

	return result
}

func buildWithClause(clauses []string) string {
	if len(clauses) == 0 {
		return ""
	}

	return fmt.Sprintf("WITH %s ", strings.Join(clauses, ", "))
}

func joinValueTuples(values []string) string {
	if len(values) == 0 {
		return "('')"
	}

	literals := make([]string, 0, len(values))
	for _, v := range values {
		if v == "" {
			continue
		}
		literals = append(literals, fmt.Sprintf("('%s')", escapeLiteral(v)))
	}

	if len(literals) == 0 {
		return "('')"
	}

	return strings.Join(literals, ", ")
}

func escapeLiteral(value string) string {
	return strings.ReplaceAll(value, "'", "''")
}
