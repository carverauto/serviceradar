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

// unifiedDevicesSelection is the base SELECT for querying ocsf_devices with backward-compatible field mapping.
// Maps OCSF fields to legacy UnifiedDevice structure for compatibility with existing code.
const unifiedDevicesSelection = `
SELECT
	uid AS device_id,
	ip,
	poller_id,
	hostname,
	mac,
	discovery_sources,
	is_available,
	first_seen_time AS first_seen,
	last_seen_time AS last_seen,
	metadata,
	agent_id,
	type AS device_type,
	NULL::text AS service_type,
	NULL::text AS service_status,
	NULL::timestamptz AS last_heartbeat,
	os->>'name' AS os_info,
	NULL::text AS version_info
FROM ocsf_devices
WHERE 1=1`

func (db *DB) cnpgInsertDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error {
	if len(updates) == 0 || !db.cnpgConfigured() {
		return nil
	}

	batch := &pgx.Batch{}
	now := time.Now().UTC()

	for _, update := range updates {
		observed := update.Timestamp
		if observed.IsZero() {
			observed = now
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

		// Upsert into ocsf_devices (OCSF-aligned device inventory)
		discoverySources := []string{arbitrarySource}

		// Infer OCSF type from metadata
		typeID, typeName := inferOCSFTypeFromMetadata(update.Metadata)

		// Extract vendor and model from metadata
		vendorName := coalesceMetadata(update.Metadata, "vendor", "manufacturer", "armis_manufacturer")
		model := coalesceMetadata(update.Metadata, "model", "armis_model")

		// Extract risk information if present
		var riskScore *int
		var riskLevelID *int
		var riskLevel string
		if rs := update.Metadata["risk_score"]; rs != "" {
			if score, err := parseMetadataInt(rs); err == nil {
				riskScore = &score
				levelID, levelName := models.RiskLevelFromScore(score)
				riskLevelID = &levelID
				riskLevel = levelName
			}
		}

		// Build OS JSONB from metadata
		osJSON := buildOSJSONFromMetadata(update.Metadata)

		// Build hw_info JSONB from metadata
		hwInfoJSON := buildHWInfoJSONFromMetadata(update.Metadata)

		batch.Queue(
			`INSERT INTO ocsf_devices (
				uid, type_id, type, hostname, ip, mac,
				vendor_name, model,
				first_seen_time, last_seen_time, created_time, modified_time,
				risk_level_id, risk_level, risk_score,
				os, hw_info,
				poller_id, agent_id, discovery_sources, is_available, metadata
			) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$9,$10,$10,$11,$12,$13,$14::jsonb,$15::jsonb,$16,$17,$18,$19,$20::jsonb)
			ON CONFLICT (uid) DO UPDATE SET
				type_id = CASE WHEN ocsf_devices.type_id = 0 THEN EXCLUDED.type_id ELSE ocsf_devices.type_id END,
				type = CASE WHEN ocsf_devices.type_id = 0 THEN EXCLUDED.type ELSE ocsf_devices.type END,
				hostname = COALESCE(NULLIF(EXCLUDED.hostname, ''), ocsf_devices.hostname),
				ip = COALESCE(NULLIF(EXCLUDED.ip, ''), ocsf_devices.ip),
				mac = COALESCE(NULLIF(EXCLUDED.mac, ''), ocsf_devices.mac),
				vendor_name = COALESCE(NULLIF(EXCLUDED.vendor_name, ''), ocsf_devices.vendor_name),
				model = COALESCE(NULLIF(EXCLUDED.model, ''), ocsf_devices.model),
				last_seen_time = EXCLUDED.last_seen_time,
				modified_time = EXCLUDED.modified_time,
				risk_level_id = COALESCE(EXCLUDED.risk_level_id, ocsf_devices.risk_level_id),
				risk_level = COALESCE(NULLIF(EXCLUDED.risk_level, ''), ocsf_devices.risk_level),
				risk_score = COALESCE(EXCLUDED.risk_score, ocsf_devices.risk_score),
				os = COALESCE(EXCLUDED.os, ocsf_devices.os),
				hw_info = COALESCE(EXCLUDED.hw_info, ocsf_devices.hw_info),
				poller_id = COALESCE(NULLIF(EXCLUDED.poller_id, ''), ocsf_devices.poller_id),
				agent_id = COALESCE(NULLIF(EXCLUDED.agent_id, ''), ocsf_devices.agent_id),
				discovery_sources = (
					SELECT array_agg(DISTINCT src) FROM unnest(
						array_cat(ocsf_devices.discovery_sources, EXCLUDED.discovery_sources)
					) AS src WHERE src IS NOT NULL
				),
				is_available = EXCLUDED.is_available,
				metadata = ocsf_devices.metadata || EXCLUDED.metadata`,
			update.DeviceID,
			typeID,
			nullableString(typeName),
			toNullableString(update.Hostname),
			update.IP,
			toNullableString(update.MAC),
			nullableString(vendorName),
			nullableString(model),
			observed,
			now,
			riskLevelID,
			nullableString(riskLevel),
			riskScore,
			nullableBytes(osJSON),
			nullableBytes(hwInfoJSON),
			update.PollerID,
			update.AgentID,
			discoverySources,
			update.IsAvailable,
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

// inferOCSFTypeFromMetadata infers OCSF device type from metadata
func inferOCSFTypeFromMetadata(metadata map[string]string) (int, string) {
	if metadata == nil {
		return models.OCSFDeviceTypeUnknown, "Unknown"
	}

	// Check for explicit type from Armis
	if armisCategory := metadata["armis_category"]; armisCategory != "" {
		if typeID, typeName := inferTypeFromArmisCategory(armisCategory); typeID != models.OCSFDeviceTypeUnknown {
			return typeID, typeName
		}
	}

	// Check for device type from source system
	if deviceType := metadata["device_type"]; deviceType != "" {
		if typeID, typeName := inferTypeFromDeviceType(deviceType); typeID != models.OCSFDeviceTypeUnknown {
			return typeID, typeName
		}
	}

	// Check SNMP sysDescr for network device hints
	if sysDescr := metadata["snmp_sys_descr"]; sysDescr != "" {
		if typeID, typeName := inferTypeFromSNMPSysDescr(sysDescr); typeID != models.OCSFDeviceTypeUnknown {
			return typeID, typeName
		}
	}

	return models.OCSFDeviceTypeUnknown, "Unknown"
}

func inferTypeFromArmisCategory(category string) (int, string) {
	categoryLower := strings.ToLower(category)
	switch {
	case strings.Contains(categoryLower, "firewall"):
		return models.OCSFDeviceTypeFirewall, models.DeviceTypeNameFirewall
	case strings.Contains(categoryLower, "router"):
		return models.OCSFDeviceTypeRouter, models.DeviceTypeNameRouter
	case strings.Contains(categoryLower, "switch"):
		return models.OCSFDeviceTypeSwitch, models.DeviceTypeNameSwitch
	case strings.Contains(categoryLower, "server"):
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	case strings.Contains(categoryLower, "desktop"):
		return models.OCSFDeviceTypeDesktop, models.DeviceTypeNameDesktop
	case strings.Contains(categoryLower, "laptop"):
		return models.OCSFDeviceTypeLaptop, "Laptop"
	case strings.Contains(categoryLower, "iot"), strings.Contains(categoryLower, "sensor"),
		strings.Contains(categoryLower, "camera"):
		return models.OCSFDeviceTypeIOT, "IOT"
	case strings.Contains(categoryLower, "mobile"), strings.Contains(categoryLower, "phone"):
		return models.OCSFDeviceTypeMobile, models.DeviceTypeNameMobile
	}
	return models.OCSFDeviceTypeUnknown, ""
}

func inferTypeFromDeviceType(deviceType string) (int, string) {
	typeLower := strings.ToLower(deviceType)
	switch typeLower {
	case "server":
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	case "desktop", "workstation":
		return models.OCSFDeviceTypeDesktop, models.DeviceTypeNameDesktop
	case "laptop", "notebook":
		return models.OCSFDeviceTypeLaptop, "Laptop"
	case "router":
		return models.OCSFDeviceTypeRouter, models.DeviceTypeNameRouter
	case "switch":
		return models.OCSFDeviceTypeSwitch, models.DeviceTypeNameSwitch
	case "firewall":
		return models.OCSFDeviceTypeFirewall, models.DeviceTypeNameFirewall
	case "iot", "sensor":
		return models.OCSFDeviceTypeIOT, "IOT"
	}
	return models.OCSFDeviceTypeUnknown, ""
}

func inferTypeFromSNMPSysDescr(sysDescr string) (int, string) {
	sysDescrLower := strings.ToLower(sysDescr)
	switch {
	case strings.Contains(sysDescrLower, "router") || (strings.Contains(sysDescrLower, "cisco") && strings.Contains(sysDescrLower, "ios")):
		return models.OCSFDeviceTypeRouter, models.DeviceTypeNameRouter
	case strings.Contains(sysDescrLower, "switch") || strings.Contains(sysDescrLower, "catalyst"):
		return models.OCSFDeviceTypeSwitch, models.DeviceTypeNameSwitch
	case strings.Contains(sysDescrLower, "asa") || strings.Contains(sysDescrLower, "firewall"):
		return models.OCSFDeviceTypeFirewall, models.DeviceTypeNameFirewall
	case strings.Contains(sysDescrLower, "linux"):
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	case strings.Contains(sysDescrLower, "windows"):
		return models.OCSFDeviceTypeServer, models.DeviceTypeNameServer
	}
	return models.OCSFDeviceTypeUnknown, ""
}

func coalesceMetadata(metadata map[string]string, keys ...string) string {
	for _, key := range keys {
		if v := metadata[key]; v != "" {
			return v
		}
	}
	return ""
}

func parseMetadataInt(s string) (int, error) {
	var v int
	_, err := fmt.Sscanf(s, "%d", &v)
	return v, err
}

func buildOSJSONFromMetadata(metadata map[string]string) []byte {
	os := map[string]interface{}{}
	hasData := false

	if v := metadata["os_name"]; v != "" {
		os["name"] = v
		hasData = true
	}
	if v := metadata["os_type"]; v != "" {
		os["type"] = v
		hasData = true
	}
	if v := metadata["os_version"]; v != "" {
		os["version"] = v
		hasData = true
	}
	if v := metadata["kernel_release"]; v != "" {
		os["kernel_release"] = v
		hasData = true
	}

	if !hasData {
		return nil
	}

	b, _ := json.Marshal(os)
	return b
}

func buildHWInfoJSONFromMetadata(metadata map[string]string) []byte {
	hw := map[string]interface{}{}
	hasData := false

	if v := metadata["cpu_architecture"]; v != "" {
		hw["cpu_architecture"] = v
		hasData = true
	}
	if v := metadata["cpu_type"]; v != "" {
		hw["cpu_type"] = v
		hasData = true
	}
	if v := metadata["serial_number"]; v != "" {
		hw["serial_number"] = v
		hasData = true
	}
	if v := metadata["hw_uuid"]; v != "" {
		hw["uuid"] = v
		hasData = true
	}

	if !hasData {
		return nil
	}

	b, _ := json.Marshal(hw)
	return b
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
	// Count from ocsf_devices (OCSF-aligned device inventory)
	const query = `SELECT COUNT(*) FROM ocsf_devices`

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
		`DELETE FROM ocsf_devices WHERE last_seen_time < $1`,
		time.Now().UTC().Add(-retention),
	)
	if err != nil {
		return 0, fmt.Errorf("failed to cleanup stale ocsf devices: %w", err)
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
	SELECT uid
	FROM ocsf_devices
	WHERE (mac IS NULL OR mac = '')
	  AND metadata->>'armis_device_id' IS NULL
	  AND metadata->>'netbox_device_id' IS NULL
	  AND last_seen_time < $1`

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
	if err := sendBatchExecAll(ctx, batch, db.conn().SendBatch, "device deletion audit"); err != nil {
		db.logger.Warn().Err(err).Msg("Failed to log device deletions to audit trail")
		// Continue with deletion even if audit fails
	}

	// Hard delete the devices from ocsf_devices
	const deleteQuery = `DELETE FROM ocsf_devices WHERE uid = ANY($1)`
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
