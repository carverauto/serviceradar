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
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

// unifiedDevicesSelection is the base SELECT for querying unified_devices.
// With the DIRE simplification, there are no tombstones or soft deletes to filter out.
// All devices in the table are active.
const unifiedDevicesSelection = `
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
FROM unified_devices
WHERE 1=1`

func (db *DB) cnpgInsertDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error {
	if len(updates) == 0 || !db.cnpgConfigured() {
		return nil
	}

	batch := &pgx.Batch{}

	for _, update := range updates {
		observed := update.Timestamp
		if observed.IsZero() {
			observed = time.Now().UTC()
		}

		if update.Partition == "" {
			update.Partition = defaultPartitionValue
		}

		if update.Metadata == nil {
			update.Metadata = make(map[string]string)
		}

		metaBytes, err := json.Marshal(update.Metadata)
		if err != nil {
			db.logger.Warn().
				Err(err).
				Str("device_id", update.DeviceID).
				Msg("failed to marshal device update metadata for CNPG; defaulting to empty object")
			metaBytes = []byte("{}")
		}

		arbitrarySource := string(update.Source)
		if arbitrarySource == "" {
			arbitrarySource = "unknown"
		}

		// Insert into device_updates log (hypertable for history)
		batch.Queue(
			`INSERT INTO device_updates (
				observed_at,
				agent_id,
				poller_id,
				partition,
				device_id,
				discovery_source,
				ip,
				mac,
				hostname,
				available,
				metadata
			) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb)`,
			observed,
			update.AgentID,
			update.PollerID,
			update.Partition,
			update.DeviceID,
			arbitrarySource,
			update.IP,
			toNullableString(update.MAC),
			toNullableString(update.Hostname),
			update.IsAvailable,
			metaBytes,
		)

		// Upsert into unified_devices (current state table)
		// This maintains the source of truth for device inventory
		discoverySources := []string{arbitrarySource}
		batch.Queue(
			`INSERT INTO unified_devices (
				device_id,
				ip,
				poller_id,
				agent_id,
				hostname,
				mac,
				discovery_sources,
				is_available,
				first_seen,
				last_seen,
				metadata,
				updated_at
			) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$9,$10::jsonb,NOW())
			ON CONFLICT (device_id) DO UPDATE SET
				ip = COALESCE(NULLIF(EXCLUDED.ip, ''), unified_devices.ip),
				poller_id = COALESCE(NULLIF(EXCLUDED.poller_id, ''), unified_devices.poller_id),
				agent_id = COALESCE(NULLIF(EXCLUDED.agent_id, ''), unified_devices.agent_id),
				hostname = COALESCE(EXCLUDED.hostname, unified_devices.hostname),
				mac = COALESCE(EXCLUDED.mac, unified_devices.mac),
				discovery_sources = (
					SELECT array_agg(DISTINCT src) FROM unnest(
						array_cat(unified_devices.discovery_sources, EXCLUDED.discovery_sources)
					) AS src WHERE src IS NOT NULL
				),
				is_available = EXCLUDED.is_available,
				last_seen = EXCLUDED.last_seen,
				metadata = unified_devices.metadata || EXCLUDED.metadata,
				updated_at = NOW()`,
			update.DeviceID,
			update.IP,
			update.PollerID,
			update.AgentID,
			toNullableString(update.Hostname),
			toNullableString(update.MAC),
			discoverySources,
			update.IsAvailable,
			observed,
			metaBytes,
		)
	}

	// Serialize device updates writes to prevent deadlocks.
	// Multiple concurrent callers can build batches in parallel,
	// but only one can execute against the database at a time.
	if db.deviceUpdatesMu != nil {
		db.deviceUpdatesMu.Lock()
		defer db.deviceUpdatesMu.Unlock()
	}

	return db.sendCNPGWithRetry(ctx, batch, "device_updates")
}

func (db *DB) cnpgGetUnifiedDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	const query = unifiedDevicesSelection + `
	AND device_id = $1
	ORDER BY last_seen DESC
	LIMIT 1`

	row := db.conn().QueryRow(ctx, query, deviceID)
	device, err := scanCNPGUnifiedDevice(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("%w: %s", errUnifiedDeviceNotFound, deviceID)
		}
		return nil, err
	}

	return device, nil
}

func (db *DB) cnpgGetUnifiedDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	const query = unifiedDevicesSelection + `
	AND ip = $1
	ORDER BY last_seen DESC`

	rows, err := db.conn().Query(ctx, query, ip)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer rows.Close()

	return gatherCNPGUnifiedDevices(rows)
}

func (db *DB) cnpgListUnifiedDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	query := unifiedDevicesSelection + `
	ORDER BY device_id ASC
	LIMIT $1 OFFSET $2`

	rows, err := db.conn().Query(ctx, query, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}
	defer rows.Close()

	return gatherCNPGUnifiedDevices(rows)
}

func (db *DB) cnpgCountUnifiedDevices(ctx context.Context) (int64, error) {
	// Simple count - no tombstone/deleted filtering needed with DIRE simplification
	const query = `SELECT COUNT(*) FROM unified_devices`

	var count int64
	if err := db.conn().QueryRow(ctx, query).Scan(&count); err != nil {
		return 0, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
	}

	return count, nil
}

func (db *DB) cnpgQueryUnifiedDevicesBatch(ctx context.Context, deviceIDs, ips []string) ([]*models.UnifiedDevice, error) {
	var results []*models.UnifiedDevice

	appendResults := func(rows pgx.Rows) error {
		defer rows.Close()
		batch, err := gatherCNPGUnifiedDevices(rows)
		if err != nil {
			return err
		}
		results = append(results, batch...)
		return nil
	}

	if len(deviceIDs) > 0 {
		rows, err := db.conn().Query(ctx, unifiedDevicesSelection+`
			AND device_id = ANY($1)
			ORDER BY device_id, last_seen DESC`, deviceIDs)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
		}
		if err := appendResults(rows); err != nil {
			return nil, err
		}
	}

	if len(ips) > 0 {
		rows, err := db.conn().Query(ctx, unifiedDevicesSelection+`
			AND ip = ANY($1)
			ORDER BY device_id, last_seen DESC`, ips)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", errFailedToQueryUnifiedDevice, err)
		}
		if err := appendResults(rows); err != nil {
			return nil, err
		}
	}

	return dedupeUnifiedDevices(results), nil
}

func gatherCNPGUnifiedDevices(rows pgx.Rows) ([]*models.UnifiedDevice, error) {
	var devices []*models.UnifiedDevice

	for rows.Next() {
		device, err := scanCNPGUnifiedDevice(rows)
		if err != nil {
			return nil, err
		}
		if device != nil {
			devices = append(devices, device)
		}
	}

	return devices, rows.Err()
}

func scanCNPGUnifiedDevice(row pgx.Row) (*models.UnifiedDevice, error) {
	var (
		d               models.UnifiedDevice
		hostname        sql.NullString
		mac             sql.NullString
		serviceType     sql.NullString
		serviceStatus   sql.NullString
		osInfo          sql.NullString
		versionInfo     sql.NullString
		lastHeartbeat   sql.NullTime
		discoverySource []string
		metadata        []byte
		pollerID        sql.NullString
		agentID         sql.NullString
	)

	if err := row.Scan(
		&d.DeviceID,
		&d.IP,
		&pollerID,
		&hostname,
		&mac,
		&discoverySource,
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
	); err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToScanUnifiedDeviceRow, err)
	}

	if hostname.Valid {
		d.Hostname = &models.DiscoveredField[string]{Value: hostname.String}
	}

	if mac.Valid {
		d.MAC = &models.DiscoveredField[string]{Value: mac.String}
	}

	if serviceType.Valid {
		d.ServiceType = serviceType.String
	}

	if serviceStatus.Valid {
		d.ServiceStatus = serviceStatus.String
	}

	if osInfo.Valid {
		d.OSInfo = osInfo.String
	}

	if versionInfo.Valid {
		d.VersionInfo = versionInfo.String
	}

	if lastHeartbeat.Valid {
		ts := lastHeartbeat.Time
		d.LastHeartbeat = &ts
	}

	if len(discoverySource) > 0 {
		d.DiscoverySources = make([]models.DiscoverySourceInfo, len(discoverySource))
		for i, s := range discoverySource {
			d.DiscoverySources[i] = models.DiscoverySourceInfo{
				Source: models.DiscoverySource(s),
				// Future enhancement: stitch poller/agent identity per source.
			}
		}
	}

	if len(metadata) > 0 {
		var fields map[string]string
		if err := json.Unmarshal(metadata, &fields); err == nil && len(fields) > 0 {
			d.Metadata = &models.DiscoveredField[map[string]string]{Value: fields}
		}
	}

	return &d, nil
}

func dedupeUnifiedDevices(devices []*models.UnifiedDevice) []*models.UnifiedDevice {
	if len(devices) == 0 {
		return devices
	}

	seen := make(map[string]*models.UnifiedDevice, len(devices))
	for _, device := range devices {
		if device == nil {
			continue
		}
		seen[device.DeviceID] = device
	}

	result := make([]*models.UnifiedDevice, 0, len(seen))
	for _, device := range seen {
		result = append(result, device)
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].LastSeen.After(result[j].LastSeen)
	})

	return result
}

func toNullableString(value *string) interface{} {
	if value == nil {
		return nil
	}

	if trimmed := strings.TrimSpace(*value); trimmed == "" {
		return nil
	} else {
		return trimmed
	}
}

// CleanupStaleUnifiedDevices removes devices not seen within the retention period.
// This should be called periodically (e.g., daily) to prevent unbounded table growth.
func (db *DB) CleanupStaleUnifiedDevices(ctx context.Context, retention time.Duration) (int64, error) {
	if !db.cnpgConfigured() {
		return 0, nil
	}

	result, err := db.conn().Exec(ctx,
		`DELETE FROM unified_devices WHERE last_seen < $1`,
		time.Now().UTC().Add(-retention),
	)
	if err != nil {
		return 0, fmt.Errorf("failed to cleanup stale unified devices: %w", err)
	}

	return result.RowsAffected(), nil
}

// GetStaleIPOnlyDevices returns IDs of devices that have no strong identifiers
// and have not been seen for the specified TTL.
func (db *DB) GetStaleIPOnlyDevices(ctx context.Context, ttl time.Duration) ([]string, error) {
	if !db.cnpgConfigured() {
		return nil, nil
	}

	// Query for devices where:
	// 1. No strong identifiers (MAC, Armis ID, Netbox ID)
	// 2. Last seen older than TTL
	const query = `
	SELECT device_id
	FROM unified_devices
	WHERE mac IS NULL
	  AND metadata->>'armis_device_id' IS NULL
	  AND metadata->>'netbox_device_id' IS NULL
	  AND last_seen < $1`

	rows, err := db.conn().Query(ctx, query, time.Now().UTC().Add(-ttl))
	if err != nil {
		return nil, fmt.Errorf("failed to query stale IP-only devices: %w", err)
	}
	defer rows.Close()

	var deviceIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("failed to scan device ID: %w", err)
		}
		deviceIDs = append(deviceIDs, id)
	}

	return deviceIDs, rows.Err()
}

// DeleteDevices permanently removes the specified devices from the database.
// With the DIRE simplification, we use hard deletes instead of soft deletes.
// An audit record is written to device_updates before deletion.
func (db *DB) DeleteDevices(ctx context.Context, deviceIDs []string) error {
	if len(deviceIDs) == 0 || !db.cnpgConfigured() {
		return nil
	}

	// First, log the deletion to device_updates for audit trail
	batch := &pgx.Batch{}
	now := time.Now().UTC()
	for _, deviceID := range deviceIDs {
		batch.Queue(
			`INSERT INTO device_updates (
				observed_at, device_id, discovery_source, metadata
			) VALUES ($1, $2, 'serviceradar', '{"_action": "deleted"}'::jsonb)`,
			now, deviceID,
		)
	}

	// Execute audit log batch
	br := db.conn().SendBatch(ctx, batch)
	if err := br.Close(); err != nil {
		db.logger.Warn().Err(err).Msg("Failed to log device deletions to audit trail")
		// Continue with deletion even if audit fails
	}

	// Hard delete the devices
	const deleteQuery = `DELETE FROM unified_devices WHERE device_id = ANY($1)`
	_, err := db.conn().Exec(ctx, deleteQuery, deviceIDs)
	if err != nil {
		return fmt.Errorf("failed to delete devices: %w", err)
	}

	// Also remove from device_identifiers table
	const deleteIdentifiersQuery = `DELETE FROM device_identifiers WHERE device_id = ANY($1)`
	_, err = db.conn().Exec(ctx, deleteIdentifiersQuery, deviceIDs)
	if err != nil {
		db.logger.Warn().Err(err).Msg("Failed to delete device identifiers")
		// Not a fatal error - the device is already deleted
	}

	return nil
}

// SoftDeleteDevices is deprecated - use DeleteDevices for hard deletes.
// This function now calls DeleteDevices for backwards compatibility.
func (db *DB) SoftDeleteDevices(ctx context.Context, deviceIDs []string) error {
	return db.DeleteDevices(ctx, deviceIDs)
}
