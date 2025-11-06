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
	errNoDeviceFilters              = errors.New("no deviceIDs or ips provided")
)

const unifiedDeviceBatchLimit = 200

// GetUnifiedDevice retrieves a unified device by its ID (latest version)
// Uses materialized view approach - reads from unified_devices stream
func (db *DB) GetUnifiedDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	query := `SELECT
        device_id, ip, poller_id, hostname, mac, discovery_sources,
        is_available, first_seen, last_seen, metadata, agent_id, device_type, 
        service_type, service_status, last_heartbeat, os_info, version_info
    FROM table(unified_devices)
    WHERE device_id = $1
    ORDER BY _tp_time DESC NULLS LAST
    LIMIT 1`

	// This function has special handling for the case where no rows are returned,
	// so we can't use the queryUnifiedDevices helper
	rows, err := db.Conn.Query(ctx, query, deviceID)
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
    WHERE ip = $1`

	return db.queryUnifiedDevicesWithArgs(ctx, query, ip)
}

// ListUnifiedDevices returns a list of unified devices with pagination using materialized view approach
func (db *DB) ListUnifiedDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	query := `SELECT
        device_id, ip, poller_id, hostname, mac, discovery_sources,
        is_available, first_seen, last_seen, metadata, agent_id, device_type, 
        service_type, service_status, last_heartbeat, os_info, version_info
    FROM table(unified_devices)
    WHERE metadata['_merged_into'] IS NULL
       OR metadata['_merged_into'] = ''
       OR metadata['_merged_into'] = device_id
    ORDER BY device_id ASC
    LIMIT $1 OFFSET $2`

	return db.queryUnifiedDevicesWithArgs(ctx, query, limit, offset)
}

// CountUnifiedDevices returns the total number of unified devices materialized in Proton.
func (db *DB) CountUnifiedDevices(ctx context.Context) (int64, error) {
	const query = `SELECT count() AS total FROM table(unified_devices)`

	row := db.Conn.QueryRow(ctx, query)

	var total int64
	if err := row.Scan(&total); err != nil {
		return 0, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}

	return total, nil
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
	if len(deviceIDs) == 0 && len(ips) == 0 {
		return nil, errNoDeviceFilters
	}

	buildQuery := func(column string, values []string) string {
		placeholders := make([]string, len(values))
		for i, value := range values {
			placeholders[i] = fmt.Sprintf("'%s'", escapeLiteral(value))
		}

		// Use CTE to filter first, then aggregate to avoid "aggregate in WHERE" error
		// Using literal strings instead of parameterized queries to work around Proton limitations
		query := fmt.Sprintf(`
WITH filtered AS (
    SELECT
        device_id,
        ip,
        poller_id,
        hostname,
        mac,
        discovery_sources,
        is_available,
        first_seen,
        last_seen,
        metadata,
        agent_id,
        device_type,
        service_type,
        service_status,
        last_heartbeat,
        os_info,
        version_info,
        _tp_time
    FROM table(unified_devices)
    WHERE %s IN (%s)
)
SELECT
    device_id,
    ip,
    poller_id,
    hostname,
    mac,
    discovery_sources,
    is_available,
    first_seen,
    last_seen,
    metadata,
    agent_id,
    device_type,
    service_type,
    service_status,
    last_heartbeat,
    os_info,
    version_info
FROM filtered
ORDER BY device_id, _tp_time DESC
LIMIT 1 BY device_id`, column, strings.Join(placeholders, ","))

		return query
	}

	var devices []*models.UnifiedDevice

	execute := func(column string, values []string) error {
		if len(values) == 0 {
			return nil
		}

		query := buildQuery(column, values)

		rows, err := db.Conn.Query(ctx, query)
		if err != nil {
			return fmt.Errorf("failed to query unified devices by %s: %w", column, err)
		}
		defer func() { _ = rows.Close() }()

		for rows.Next() {
			device, err := db.scanUnifiedDeviceSimple(rows)
			if err != nil {
				db.logger.Warn().Err(err).Msg("Failed to scan unified device in batch fetch")
				continue
			}
			devices = append(devices, device)
		}

		if err := rows.Err(); err != nil {
			return fmt.Errorf("%w: %w", errIterRows, err)
		}

		return nil
	}

	if err := execute("device_id", deviceIDs); err != nil {
		return nil, err
	}

	if err := execute("ip", ips); err != nil {
		return nil, err
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

func joinValueTuples(values []string) string {
	literals := make([]string, 0, len(values))
	for _, v := range values {
		if v = strings.TrimSpace(v); v == "" {
			continue
		}
		literals = append(literals, fmt.Sprintf("('%s')", escapeLiteral(v)))
	}

	return strings.Join(literals, ", ")
}

func escapeLiteral(value string) string {
	return strings.ReplaceAll(value, "'", "''")
}
