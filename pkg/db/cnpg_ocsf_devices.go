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
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

// ocsf device error sentinels
var (
	errOCSFDeviceNotFound        = errors.New("ocsf device not found")
	errFailedToQueryOCSFDevice   = errors.New("failed to query ocsf device")
	errFailedToScanOCSFDeviceRow = errors.New("failed to scan ocsf device row")
)

// ocsfDevicesSelection is the base SELECT for querying ocsf_devices.
const ocsfDevicesSelection = `
SELECT
	uid,
	type_id,
	type,
	name,
	hostname,
	ip,
	mac,
	uid_alt,
	vendor_name,
	model,
	domain,
	zone,
	subnet_uid,
	vlan_uid,
	region,
	first_seen_time,
	last_seen_time,
	created_time,
	modified_time,
	risk_level_id,
	risk_level,
	risk_score,
	is_managed,
	is_compliant,
	is_trusted,
	os,
	hw_info,
	network_interfaces,
	owner,
	org,
	groups,
	agent_list,
	gateway_id,
	agent_id,
	discovery_sources,
	is_available,
	metadata
FROM ocsf_devices
WHERE 1=1`

// UpsertOCSFDevice inserts or updates an OCSF device
func (db *DB) UpsertOCSFDevice(ctx context.Context, device *models.OCSFDevice) error {
	if device == nil || !db.cnpgConfigured() {
		return nil
	}

	// Serialize JSONB fields
	osJSON, hwInfoJSON, networkInterfacesJSON, ownerJSON, orgJSON, groupsJSON, agentListJSON, metadataJSON, err := device.ToJSONFields()
	if err != nil {
		return fmt.Errorf("failed to serialize OCSF device JSONB fields: %w", err)
	}

	// Set modification time
	now := time.Now().UTC()
	device.ModifiedTime = now

	// If first seen is not set, use created time
	if device.FirstSeenTime == nil {
		device.FirstSeenTime = &now
	}
	if device.LastSeenTime == nil {
		device.LastSeenTime = &now
	}

	const query = `
	INSERT INTO ocsf_devices (
		uid, type_id, type, name, hostname, ip, mac,
		uid_alt, vendor_name, model, domain, zone, subnet_uid, vlan_uid, region,
		first_seen_time, last_seen_time, created_time, modified_time,
		risk_level_id, risk_level, risk_score, is_managed, is_compliant, is_trusted,
		os, hw_info, network_interfaces, owner, org, groups, agent_list,
		gateway_id, agent_id, discovery_sources, is_available, metadata
	) VALUES (
		$1, $2, $3, $4, $5, $6, $7,
		$8, $9, $10, $11, $12, $13, $14, $15,
		$16, $17, $18, $19,
		$20, $21, $22, $23, $24, $25,
		$26::jsonb, $27::jsonb, $28::jsonb, $29::jsonb, $30::jsonb, $31::jsonb, $32::jsonb,
		$33, $34, $35, $36, $37::jsonb
	)
	ON CONFLICT (uid) DO UPDATE SET
		type_id = EXCLUDED.type_id,
		type = COALESCE(EXCLUDED.type, ocsf_devices.type),
		name = COALESCE(EXCLUDED.name, ocsf_devices.name),
		hostname = COALESCE(NULLIF(EXCLUDED.hostname, ''), ocsf_devices.hostname),
		ip = COALESCE(NULLIF(EXCLUDED.ip, ''), ocsf_devices.ip),
		mac = COALESCE(NULLIF(EXCLUDED.mac, ''), ocsf_devices.mac),
		uid_alt = COALESCE(EXCLUDED.uid_alt, ocsf_devices.uid_alt),
		vendor_name = COALESCE(EXCLUDED.vendor_name, ocsf_devices.vendor_name),
		model = COALESCE(EXCLUDED.model, ocsf_devices.model),
		domain = COALESCE(EXCLUDED.domain, ocsf_devices.domain),
		zone = COALESCE(EXCLUDED.zone, ocsf_devices.zone),
		subnet_uid = COALESCE(EXCLUDED.subnet_uid, ocsf_devices.subnet_uid),
		vlan_uid = COALESCE(EXCLUDED.vlan_uid, ocsf_devices.vlan_uid),
		region = COALESCE(EXCLUDED.region, ocsf_devices.region),
		last_seen_time = EXCLUDED.last_seen_time,
		modified_time = EXCLUDED.modified_time,
		risk_level_id = COALESCE(EXCLUDED.risk_level_id, ocsf_devices.risk_level_id),
		risk_level = COALESCE(EXCLUDED.risk_level, ocsf_devices.risk_level),
		risk_score = COALESCE(EXCLUDED.risk_score, ocsf_devices.risk_score),
		is_managed = COALESCE(EXCLUDED.is_managed, ocsf_devices.is_managed),
		is_compliant = COALESCE(EXCLUDED.is_compliant, ocsf_devices.is_compliant),
		is_trusted = COALESCE(EXCLUDED.is_trusted, ocsf_devices.is_trusted),
		os = COALESCE(EXCLUDED.os, ocsf_devices.os),
		hw_info = COALESCE(EXCLUDED.hw_info, ocsf_devices.hw_info),
		network_interfaces = COALESCE(EXCLUDED.network_interfaces, ocsf_devices.network_interfaces),
		owner = COALESCE(EXCLUDED.owner, ocsf_devices.owner),
		org = COALESCE(EXCLUDED.org, ocsf_devices.org),
		groups = COALESCE(EXCLUDED.groups, ocsf_devices.groups),
		agent_list = COALESCE(EXCLUDED.agent_list, ocsf_devices.agent_list),
		gateway_id = COALESCE(NULLIF(EXCLUDED.gateway_id, ''), ocsf_devices.gateway_id),
		agent_id = COALESCE(NULLIF(EXCLUDED.agent_id, ''), ocsf_devices.agent_id),
		discovery_sources = (
			SELECT array_agg(DISTINCT src) FROM unnest(
				array_cat(ocsf_devices.discovery_sources, EXCLUDED.discovery_sources)
			) AS src WHERE src IS NOT NULL
		),
		is_available = EXCLUDED.is_available,
		metadata = ocsf_devices.metadata || EXCLUDED.metadata`

	_, err = db.conn().Exec(ctx, query,
		device.UID,
		device.TypeID,
		nullableString(device.Type),
		nullableString(device.Name),
		nullableString(device.Hostname),
		nullableString(device.IP),
		nullableString(device.MAC),
		nullableString(device.UIDAlt),
		nullableString(device.VendorName),
		nullableString(device.Model),
		nullableString(device.Domain),
		nullableString(device.Zone),
		nullableString(device.SubnetUID),
		nullableString(device.VlanUID),
		nullableString(device.Region),
		device.FirstSeenTime,
		device.LastSeenTime,
		device.CreatedTime,
		device.ModifiedTime,
		device.RiskLevelID,
		nullableString(device.RiskLevel),
		device.RiskScore,
		device.IsManaged,
		device.IsCompliant,
		device.IsTrusted,
		nullableBytes(osJSON),
		nullableBytes(hwInfoJSON),
		nullableBytes(networkInterfacesJSON),
		nullableBytes(ownerJSON),
		nullableBytes(orgJSON),
		nullableBytes(groupsJSON),
		nullableBytes(agentListJSON),
		nullableString(device.GatewayID),
		nullableString(device.AgentID),
		device.DiscoverySources,
		device.IsAvailable,
		nullableBytes(metadataJSON),
	)

	if err != nil {
		return fmt.Errorf("failed to upsert OCSF device: %w", err)
	}

	return nil
}

// UpsertOCSFDeviceBatch inserts or updates multiple OCSF devices in a batch
func (db *DB) UpsertOCSFDeviceBatch(ctx context.Context, devices []*models.OCSFDevice) error {
	if len(devices) == 0 || !db.cnpgConfigured() {
		return nil
	}

	batch := &pgx.Batch{}
	now := time.Now().UTC()

	for _, device := range devices {
		if device == nil {
			continue
		}

		// Serialize JSONB fields
		osJSON, hwInfoJSON, networkInterfacesJSON, ownerJSON, orgJSON, groupsJSON, agentListJSON, metadataJSON, err := device.ToJSONFields()
		if err != nil {
			db.logger.Warn().
				Err(err).
				Str("uid", device.UID).
				Msg("failed to serialize OCSF device JSONB fields; skipping device")
			continue
		}

		device.ModifiedTime = now
		if device.FirstSeenTime == nil {
			device.FirstSeenTime = &now
		}
		if device.LastSeenTime == nil {
			device.LastSeenTime = &now
		}

		batch.Queue(`
			INSERT INTO ocsf_devices (
				uid, type_id, type, name, hostname, ip, mac,
				uid_alt, vendor_name, model, domain, zone, subnet_uid, vlan_uid, region,
				first_seen_time, last_seen_time, created_time, modified_time,
				risk_level_id, risk_level, risk_score, is_managed, is_compliant, is_trusted,
				os, hw_info, network_interfaces, owner, org, groups, agent_list,
				gateway_id, agent_id, discovery_sources, is_available, metadata
			) VALUES (
				$1, $2, $3, $4, $5, $6, $7,
				$8, $9, $10, $11, $12, $13, $14, $15,
				$16, $17, $18, $19,
				$20, $21, $22, $23, $24, $25,
				$26::jsonb, $27::jsonb, $28::jsonb, $29::jsonb, $30::jsonb, $31::jsonb, $32::jsonb,
				$33, $34, $35, $36, $37::jsonb
			)
			ON CONFLICT (uid) DO UPDATE SET
				type_id = EXCLUDED.type_id,
				type = COALESCE(EXCLUDED.type, ocsf_devices.type),
				name = COALESCE(EXCLUDED.name, ocsf_devices.name),
				hostname = COALESCE(NULLIF(EXCLUDED.hostname, ''), ocsf_devices.hostname),
				ip = COALESCE(NULLIF(EXCLUDED.ip, ''), ocsf_devices.ip),
				mac = COALESCE(NULLIF(EXCLUDED.mac, ''), ocsf_devices.mac),
				vendor_name = COALESCE(EXCLUDED.vendor_name, ocsf_devices.vendor_name),
				model = COALESCE(EXCLUDED.model, ocsf_devices.model),
				last_seen_time = EXCLUDED.last_seen_time,
				modified_time = EXCLUDED.modified_time,
				risk_level_id = COALESCE(EXCLUDED.risk_level_id, ocsf_devices.risk_level_id),
				risk_level = COALESCE(EXCLUDED.risk_level, ocsf_devices.risk_level),
				risk_score = COALESCE(EXCLUDED.risk_score, ocsf_devices.risk_score),
				is_managed = COALESCE(EXCLUDED.is_managed, ocsf_devices.is_managed),
				is_compliant = COALESCE(EXCLUDED.is_compliant, ocsf_devices.is_compliant),
				is_trusted = COALESCE(EXCLUDED.is_trusted, ocsf_devices.is_trusted),
				os = COALESCE(EXCLUDED.os, ocsf_devices.os),
				hw_info = COALESCE(EXCLUDED.hw_info, ocsf_devices.hw_info),
				network_interfaces = COALESCE(EXCLUDED.network_interfaces, ocsf_devices.network_interfaces),
				gateway_id = COALESCE(NULLIF(EXCLUDED.gateway_id, ''), ocsf_devices.gateway_id),
				agent_id = COALESCE(NULLIF(EXCLUDED.agent_id, ''), ocsf_devices.agent_id),
				discovery_sources = (
					SELECT array_agg(DISTINCT src) FROM unnest(
						array_cat(ocsf_devices.discovery_sources, EXCLUDED.discovery_sources)
					) AS src WHERE src IS NOT NULL
				),
				is_available = EXCLUDED.is_available,
				metadata = ocsf_devices.metadata || EXCLUDED.metadata`,
			device.UID,
			device.TypeID,
			nullableString(device.Type),
			nullableString(device.Name),
			nullableString(device.Hostname),
			nullableString(device.IP),
			nullableString(device.MAC),
			nullableString(device.UIDAlt),
			nullableString(device.VendorName),
			nullableString(device.Model),
			nullableString(device.Domain),
			nullableString(device.Zone),
			nullableString(device.SubnetUID),
			nullableString(device.VlanUID),
			nullableString(device.Region),
			device.FirstSeenTime,
			device.LastSeenTime,
			device.CreatedTime,
			device.ModifiedTime,
			device.RiskLevelID,
			nullableString(device.RiskLevel),
			device.RiskScore,
			device.IsManaged,
			device.IsCompliant,
			device.IsTrusted,
			nullableBytes(osJSON),
			nullableBytes(hwInfoJSON),
			nullableBytes(networkInterfacesJSON),
			nullableBytes(ownerJSON),
			nullableBytes(orgJSON),
			nullableBytes(groupsJSON),
			nullableBytes(agentListJSON),
			nullableString(device.GatewayID),
			nullableString(device.AgentID),
			device.DiscoverySources,
			device.IsAvailable,
			nullableBytes(metadataJSON),
		)
	}

	// Serialize device updates writes to prevent deadlocks
	if db.deviceUpdatesMu != nil {
		db.deviceUpdatesMu.Lock()
		defer db.deviceUpdatesMu.Unlock()
	}

	return db.sendCNPGWithRetry(ctx, batch, "ocsf_devices")
}

// GetOCSFDevice retrieves an OCSF device by UID
func (db *DB) GetOCSFDevice(ctx context.Context, uid string) (*models.OCSFDevice, error) {
	const query = ocsfDevicesSelection + `
	AND uid = $1
	LIMIT 1`

	row := db.conn().QueryRow(ctx, query, uid)
	device, err := scanOCSFDevice(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("%w: %s", errOCSFDeviceNotFound, uid)
		}
		return nil, err
	}

	return device, nil
}

// GetOCSFDevicesByIP retrieves OCSF devices by IP address
func (db *DB) GetOCSFDevicesByIP(ctx context.Context, ip string) ([]*models.OCSFDevice, error) {
	const query = ocsfDevicesSelection + `
	AND ip = $1
	ORDER BY last_seen_time DESC`

	rows, err := db.conn().Query(ctx, query, ip)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryOCSFDevice, err)
	}
	defer rows.Close()

	return gatherOCSFDevices(rows)
}

// GetOCSFDevicesByIPsOrIDs retrieves OCSF devices by a list of IPs or UIDs
func (db *DB) GetOCSFDevicesByIPsOrIDs(ctx context.Context, ips []string, uids []string) ([]*models.OCSFDevice, error) {
	if !db.cnpgConfigured() || (len(ips) == 0 && len(uids) == 0) {
		return nil, nil
	}

	query := ocsfDevicesSelection

	var args []interface{}
	var conditions []string

	if len(ips) > 0 {
		conditions = append(conditions, fmt.Sprintf("ip = ANY($%d)", len(args)+1))
		args = append(args, ips)
	}

	if len(uids) > 0 {
		conditions = append(conditions, fmt.Sprintf("uid = ANY($%d)", len(args)+1))
		args = append(args, uids)
	}

	if len(conditions) > 0 {
		query += " AND (" + conditions[0]
		for _, cond := range conditions[1:] {
			query += " OR " + cond
		}
		query += ")"
	}

	query += " ORDER BY last_seen_time DESC"

	rows, err := db.conn().Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryOCSFDevice, err)
	}
	defer rows.Close()

	return gatherOCSFDevices(rows)
}

// ListOCSFDevices lists OCSF devices with pagination
func (db *DB) ListOCSFDevices(ctx context.Context, limit, offset int) ([]*models.OCSFDevice, error) {
	query := ocsfDevicesSelection + `
	ORDER BY uid ASC
	LIMIT $1 OFFSET $2`

	rows, err := db.conn().Query(ctx, query, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryOCSFDevice, err)
	}
	defer rows.Close()

	return gatherOCSFDevices(rows)
}

// ListOCSFDevicesByType lists OCSF devices filtered by type_id
func (db *DB) ListOCSFDevicesByType(ctx context.Context, typeID int, limit, offset int) ([]*models.OCSFDevice, error) {
	query := ocsfDevicesSelection + `
	AND type_id = $1
	ORDER BY last_seen_time DESC
	LIMIT $2 OFFSET $3`

	rows, err := db.conn().Query(ctx, query, typeID, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToQueryOCSFDevice, err)
	}
	defer rows.Close()

	return gatherOCSFDevices(rows)
}

// CountOCSFDevices returns the total count of OCSF devices
func (db *DB) CountOCSFDevices(ctx context.Context) (int64, error) {
	const query = `SELECT COUNT(*) FROM ocsf_devices`

	var count int64
	if err := db.conn().QueryRow(ctx, query).Scan(&count); err != nil {
		return 0, fmt.Errorf("%w: %w", errFailedToQueryOCSFDevice, err)
	}

	return count, nil
}

// DeleteOCSFDevices permanently removes the specified devices.
// This is an alias for DeleteDevices which operates on the same ocsf_devices table.
func (db *DB) DeleteOCSFDevices(ctx context.Context, uids []string) error {
	return db.DeleteDevices(ctx, uids)
}

// CleanupStaleOCSFDevices removes devices not seen within the retention period
func (db *DB) CleanupStaleOCSFDevices(ctx context.Context, retention time.Duration) (int64, error) {
	if !db.cnpgConfigured() {
		return 0, nil
	}

	result, err := db.conn().Exec(ctx,
		`DELETE FROM ocsf_devices WHERE last_seen_time < $1`,
		time.Now().UTC().Add(-retention),
	)
	if err != nil {
		return 0, fmt.Errorf("failed to cleanup stale OCSF devices: %w", err)
	}

	return result.RowsAffected(), nil
}

func gatherOCSFDevices(rows pgx.Rows) ([]*models.OCSFDevice, error) {
	var devices []*models.OCSFDevice

	for rows.Next() {
		device, err := scanOCSFDevice(rows)
		if err != nil {
			return nil, err
		}
		if device != nil {
			devices = append(devices, device)
		}
	}

	return devices, rows.Err()
}

// ocsfDeviceScanTargets holds the nullable scan targets for an OCSF device.
type ocsfDeviceScanTargets struct {
	deviceType        sql.NullString
	name              sql.NullString
	hostname          sql.NullString
	ip                sql.NullString
	mac               sql.NullString
	uidAlt            sql.NullString
	vendorName        sql.NullString
	model             sql.NullString
	domain            sql.NullString
	zone              sql.NullString
	subnetUID         sql.NullString
	vlanUID           sql.NullString
	region            sql.NullString
	firstSeenTime     sql.NullTime
	lastSeenTime      sql.NullTime
	riskLevelID       sql.NullInt32
	riskLevel         sql.NullString
	riskScore         sql.NullInt32
	isManaged         sql.NullBool
	isCompliant       sql.NullBool
	isTrusted         sql.NullBool
	gatewayID          sql.NullString
	agentID           sql.NullString
	isAvailable       sql.NullBool
	osJSON            []byte
	hwInfoJSON        []byte
	networkIfacesJSON []byte
	ownerJSON         []byte
	orgJSON           []byte
	groupsJSON        []byte
	agentListJSON     []byte
	metadataJSON      []byte
	discoverySources  []string
}

func scanOCSFDevice(row pgx.Row) (*models.OCSFDevice, error) {
	var d models.OCSFDevice
	var t ocsfDeviceScanTargets

	if err := row.Scan(
		&d.UID,
		&d.TypeID,
		&t.deviceType,
		&t.name,
		&t.hostname,
		&t.ip,
		&t.mac,
		&t.uidAlt,
		&t.vendorName,
		&t.model,
		&t.domain,
		&t.zone,
		&t.subnetUID,
		&t.vlanUID,
		&t.region,
		&t.firstSeenTime,
		&t.lastSeenTime,
		&d.CreatedTime,
		&d.ModifiedTime,
		&t.riskLevelID,
		&t.riskLevel,
		&t.riskScore,
		&t.isManaged,
		&t.isCompliant,
		&t.isTrusted,
		&t.osJSON,
		&t.hwInfoJSON,
		&t.networkIfacesJSON,
		&t.ownerJSON,
		&t.orgJSON,
		&t.groupsJSON,
		&t.agentListJSON,
		&t.gatewayID,
		&t.agentID,
		&t.discoverySources,
		&t.isAvailable,
		&t.metadataJSON,
	); err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToScanOCSFDeviceRow, err)
	}

	mapOCSFDeviceNullableFields(&d, &t)
	unmarshalOCSFDeviceJSONFields(&d, &t)

	return &d, nil
}

// mapOCSFDeviceNullableFields maps nullable scan targets to device fields.
func mapOCSFDeviceNullableFields(d *models.OCSFDevice, t *ocsfDeviceScanTargets) {
	// String fields
	d.Type = nullStringValue(t.deviceType)
	d.Name = nullStringValue(t.name)
	d.Hostname = nullStringValue(t.hostname)
	d.IP = nullStringValue(t.ip)
	d.MAC = nullStringValue(t.mac)
	d.UIDAlt = nullStringValue(t.uidAlt)
	d.VendorName = nullStringValue(t.vendorName)
	d.Model = nullStringValue(t.model)
	d.Domain = nullStringValue(t.domain)
	d.Zone = nullStringValue(t.zone)
	d.SubnetUID = nullStringValue(t.subnetUID)
	d.VlanUID = nullStringValue(t.vlanUID)
	d.Region = nullStringValue(t.region)
	d.RiskLevel = nullStringValue(t.riskLevel)
	d.GatewayID = nullStringValue(t.gatewayID)
	d.AgentID = nullStringValue(t.agentID)

	// Time fields
	d.FirstSeenTime = nullTimePointer(t.firstSeenTime)
	d.LastSeenTime = nullTimePointer(t.lastSeenTime)

	// Integer pointer fields
	d.RiskLevelID = nullInt32Pointer(t.riskLevelID)
	d.RiskScore = nullInt32Pointer(t.riskScore)

	// Boolean pointer fields
	d.IsManaged = nullBoolPointer(t.isManaged)
	d.IsCompliant = nullBoolPointer(t.isCompliant)
	d.IsTrusted = nullBoolPointer(t.isTrusted)
	d.IsAvailable = nullBoolPointer(t.isAvailable)

	// Slice field
	d.DiscoverySources = t.discoverySources
}

// unmarshalOCSFDeviceJSONFields unmarshals JSONB fields into device structs.
func unmarshalOCSFDeviceJSONFields(d *models.OCSFDevice, t *ocsfDeviceScanTargets) {
	if len(t.osJSON) > 0 {
		var os models.OCSFDeviceOS
		if err := json.Unmarshal(t.osJSON, &os); err == nil {
			d.OS = &os
		}
	}
	if len(t.hwInfoJSON) > 0 {
		var hwInfo models.OCSFDeviceHWInfo
		if err := json.Unmarshal(t.hwInfoJSON, &hwInfo); err == nil {
			d.HWInfo = &hwInfo
		}
	}
	if len(t.networkIfacesJSON) > 0 {
		var ifaces []models.OCSFNetworkInterface
		if err := json.Unmarshal(t.networkIfacesJSON, &ifaces); err == nil {
			d.NetworkInterfaces = ifaces
		}
	}
	if len(t.ownerJSON) > 0 {
		var owner models.OCSFUser
		if err := json.Unmarshal(t.ownerJSON, &owner); err == nil {
			d.Owner = &owner
		}
	}
	if len(t.orgJSON) > 0 {
		var org models.OCSFOrganization
		if err := json.Unmarshal(t.orgJSON, &org); err == nil {
			d.Org = &org
		}
	}
	if len(t.groupsJSON) > 0 {
		var groups []models.OCSFGroup
		if err := json.Unmarshal(t.groupsJSON, &groups); err == nil {
			d.Groups = groups
		}
	}
	if len(t.agentListJSON) > 0 {
		var agents []models.OCSFAgent
		if err := json.Unmarshal(t.agentListJSON, &agents); err == nil {
			d.AgentList = agents
		}
	}
	if len(t.metadataJSON) > 0 {
		var metadata map[string]string
		if err := json.Unmarshal(t.metadataJSON, &metadata); err == nil {
			d.Metadata = metadata
		}
	}
}

// nullStringValue returns the string value if valid, empty string otherwise.
func nullStringValue(ns sql.NullString) string {
	if ns.Valid {
		return ns.String
	}
	return ""
}

// nullTimePointer returns a pointer to the time if valid, nil otherwise.
func nullTimePointer(nt sql.NullTime) *time.Time {
	if nt.Valid {
		return &nt.Time
	}
	return nil
}

// nullInt32Pointer returns a pointer to the int value if valid, nil otherwise.
func nullInt32Pointer(ni sql.NullInt32) *int {
	if ni.Valid {
		v := int(ni.Int32)
		return &v
	}
	return nil
}

// nullBoolPointer returns a pointer to the bool value if valid, nil otherwise.
func nullBoolPointer(nb sql.NullBool) *bool {
	if nb.Valid {
		return &nb.Bool
	}
	return nil
}

// Helper functions for nullable values
func nullableString(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

func nullableBytes(b []byte) interface{} {
	if len(b) == 0 {
		return nil
	}
	return b
}
