package db

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const selectPromotableSightingsSQL = `
SELECT
	sighting_id,
	partition,
	ip,
	subnet_id,
	source,
	status,
	first_seen,
	last_seen,
	ttl_expires_at,
	fingerprint_id,
	metadata
FROM network_sightings
WHERE status = 'active'
  AND first_seen <= $1
`

const markSightingsPromotedSQL = `
UPDATE network_sightings
SET status = 'promoted',
    last_seen = now()
WHERE sighting_id = ANY($1)
`

const listActiveSightingsSQL = `
SELECT
	sighting_id,
	partition,
	ip,
	subnet_id,
	source,
	status,
	first_seen,
	last_seen,
	ttl_expires_at,
	fingerprint_id,
	metadata
FROM network_sightings
WHERE status = 'active'
  AND ($1 = '' OR partition = $1)
ORDER BY last_seen DESC
LIMIT $2
OFFSET $3
`

const getSightingByIDSQL = `
SELECT
	sighting_id,
	partition,
	ip,
	subnet_id,
	source,
	status,
	first_seen,
	last_seen,
	ttl_expires_at,
	fingerprint_id,
	metadata
FROM network_sightings
WHERE sighting_id = $1
`

const updateSightingStatusSQL = `
UPDATE network_sightings
SET status = $2,
    last_seen = GREATEST(last_seen, now())
WHERE sighting_id = $1
RETURNING sighting_id
`

const listSightingEventsSQL = `
SELECT
	event_id,
	sighting_id,
	device_id,
	event_type,
	actor,
	details,
	created_at
FROM sighting_events
WHERE sighting_id = $1
ORDER BY created_at DESC
LIMIT $2
`

const countActiveSightingsSQL = `
SELECT
	COUNT(*)
FROM network_sightings
WHERE status = 'active'
  AND ($1 = '' OR partition = $1)
`

const listSubnetPoliciesSQL = `
SELECT
	subnet_id,
	cidr::text,
	classification,
	promotion_rules,
	reaper_profile,
	allow_ip_as_id,
	created_at,
	updated_at
FROM subnet_policies
ORDER BY created_at DESC
LIMIT $1
`

const listMergeAuditSQL = `
SELECT
	event_id,
	from_device_id,
	to_device_id,
	reason,
	confidence_score,
	source,
	details,
	created_at
FROM merge_audit
ORDER BY created_at DESC
LIMIT $1
`

const listMergeAuditByDeviceSQL = `
SELECT
	event_id,
	from_device_id,
	to_device_id,
	reason,
	confidence_score,
	source,
	details,
	created_at
FROM merge_audit
WHERE from_device_id = $1 OR to_device_id = $1
ORDER BY created_at DESC
LIMIT $2
`

// ListPromotableSightings returns active sightings that have persisted beyond the provided cutoff.
func (db *DB) ListPromotableSightings(ctx context.Context, cutoff time.Time) ([]*models.NetworkSighting, error) {
	if !db.UseCNPGReads() {
		return nil, fmt.Errorf("cnpg reads not available")
	}

	rows, err := db.pgPool.Query(ctx, selectPromotableSightingsSQL, cutoff.UTC())
	if err != nil {
		return nil, fmt.Errorf("list promotable sightings: %w", err)
	}
	defer rows.Close()

	var result []*models.NetworkSighting

	for rows.Next() {
		var (
			rec             models.NetworkSighting
			subnetID        *string
			fingerprintID   *string
			ttlExpiresAtRaw *time.Time
			metadataRaw     map[string]string
		)

		if err := rows.Scan(
			&rec.SightingID,
			&rec.Partition,
			&rec.IP,
			&subnetID,
			&rec.Source,
			&rec.Status,
			&rec.FirstSeen,
			&rec.LastSeen,
			&ttlExpiresAtRaw,
			&fingerprintID,
			&metadataRaw,
		); err != nil {
			return nil, fmt.Errorf("scan promotable sighting: %w", err)
		}

		rec.SubnetID = subnetID
		rec.FingerprintID = fingerprintID
		rec.TTLExpiresAt = ttlExpiresAtRaw
		rec.Metadata = metadataRaw
		result = append(result, &rec)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate promotable sightings: %w", err)
	}

	return result, nil
}

// MarkSightingsPromoted updates sightings to promoted status.
func (db *DB) MarkSightingsPromoted(ctx context.Context, ids []string) (int64, error) {
	if len(ids) == 0 || !db.useCNPGWrites() {
		return 0, nil
	}

	tag, err := db.pgPool.Exec(ctx, markSightingsPromotedSQL, ids)
	if err != nil {
		return 0, fmt.Errorf("mark sightings promoted: %w", err)
	}

	return tag.RowsAffected(), nil
}

// ListActiveSightings returns active sightings optionally filtered by partition.
func (db *DB) ListActiveSightings(ctx context.Context, partition string, limit, offset int) ([]*models.NetworkSighting, error) {
	if !db.UseCNPGReads() {
		return nil, fmt.Errorf("cnpg reads not available")
	}
	if limit <= 0 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}

	rows, err := db.pgPool.Query(ctx, listActiveSightingsSQL, partition, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("list active sightings: %w", err)
	}
	defer rows.Close()

	var result []*models.NetworkSighting

	for rows.Next() {
		var (
			rec             models.NetworkSighting
			subnetID        *string
			fingerprintID   *string
			ttlExpiresAtRaw *time.Time
			metadataRaw     map[string]string
		)

		if err := rows.Scan(
			&rec.SightingID,
			&rec.Partition,
			&rec.IP,
			&subnetID,
			&rec.Source,
			&rec.Status,
			&rec.FirstSeen,
			&rec.LastSeen,
			&ttlExpiresAtRaw,
			&fingerprintID,
			&metadataRaw,
		); err != nil {
			return nil, fmt.Errorf("scan active sighting: %w", err)
		}

		rec.SubnetID = subnetID
		rec.FingerprintID = fingerprintID
		rec.TTLExpiresAt = ttlExpiresAtRaw
		rec.Metadata = metadataRaw
		result = append(result, &rec)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate active sightings: %w", err)
	}

	return result, nil
}

// CountActiveSightings returns the total number of active sightings for the optional partition filter.
func (db *DB) CountActiveSightings(ctx context.Context, partition string) (int64, error) {
	if !db.UseCNPGReads() {
		return 0, fmt.Errorf("cnpg reads not available")
	}

	var count int64
	if err := db.pgPool.QueryRow(ctx, countActiveSightingsSQL, partition).Scan(&count); err != nil {
		return 0, fmt.Errorf("count active sightings: %w", err)
	}
	return count, nil
}

// GetNetworkSighting returns a single sighting by ID.
func (db *DB) GetNetworkSighting(ctx context.Context, sightingID string) (*models.NetworkSighting, error) {
	if !db.UseCNPGReads() {
		return nil, fmt.Errorf("cnpg reads not available")
	}

	id := strings.TrimSpace(sightingID)
	if id == "" {
		return nil, fmt.Errorf("sighting_id is required")
	}

	row := db.pgPool.QueryRow(ctx, getSightingByIDSQL, id)

	var (
		rec             models.NetworkSighting
		subnetID        *string
		fingerprintID   *string
		ttlExpiresAtRaw *time.Time
		metadataRaw     map[string]string
	)

	if err := row.Scan(
		&rec.SightingID,
		&rec.Partition,
		&rec.IP,
		&subnetID,
		&rec.Source,
		&rec.Status,
		&rec.FirstSeen,
		&rec.LastSeen,
		&ttlExpiresAtRaw,
		&fingerprintID,
		&metadataRaw,
	); err != nil {
		return nil, fmt.Errorf("get sighting: %w", err)
	}

	rec.SubnetID = subnetID
	rec.FingerprintID = fingerprintID
	rec.TTLExpiresAt = ttlExpiresAtRaw
	rec.Metadata = metadataRaw
	return &rec, nil
}

// UpdateSightingStatus updates a sighting's status and returns affected rows.
func (db *DB) UpdateSightingStatus(ctx context.Context, sightingID string, status models.NetworkSightingStatus) (int64, error) {
	if !db.useCNPGWrites() {
		return 0, nil
	}
	id := strings.TrimSpace(sightingID)
	if id == "" {
		return 0, fmt.Errorf("sighting_id is required")
	}

	statusValue := strings.TrimSpace(string(status))
	if statusValue == "" {
		return 0, fmt.Errorf("status is required")
	}

	tag, err := db.pgPool.Exec(ctx, updateSightingStatusSQL, id, statusValue)
	if err != nil {
		return 0, fmt.Errorf("update sighting status: %w", err)
	}

	return tag.RowsAffected(), nil
}

// ListSightingEvents returns audit events for a sighting ordered newest first.
func (db *DB) ListSightingEvents(ctx context.Context, sightingID string, limit int) ([]*models.SightingEvent, error) {
	if !db.UseCNPGReads() {
		return nil, fmt.Errorf("cnpg reads not available")
	}
	id := strings.TrimSpace(sightingID)
	if id == "" {
		return nil, fmt.Errorf("sighting_id is required")
	}
	if limit <= 0 {
		limit = 50
	}

	rows, err := db.pgPool.Query(ctx, listSightingEventsSQL, id, limit)
	if err != nil {
		return nil, fmt.Errorf("list sighting events: %w", err)
	}
	defer rows.Close()

	var events []*models.SightingEvent

	for rows.Next() {
		var ev models.SightingEvent
		var details map[string]string
		if err := rows.Scan(
			&ev.EventID,
			&ev.SightingID,
			&ev.DeviceID,
			&ev.EventType,
			&ev.Actor,
			&details,
			&ev.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan sighting event: %w", err)
		}
		ev.Details = details
		events = append(events, &ev)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate sighting events: %w", err)
	}

	return events, nil
}

// ListSubnetPolicies returns configured subnet policies ordered by creation time.
func (db *DB) ListSubnetPolicies(ctx context.Context, limit int) ([]*models.SubnetPolicy, error) {
	if !db.UseCNPGReads() {
		return nil, fmt.Errorf("cnpg reads not available")
	}
	if limit <= 0 {
		limit = 100
	}

	rows, err := db.pgPool.Query(ctx, listSubnetPoliciesSQL, limit)
	if err != nil {
		return nil, fmt.Errorf("list subnet policies: %w", err)
	}
	defer rows.Close()

	var policies []*models.SubnetPolicy

	for rows.Next() {
		var (
			policy         models.SubnetPolicy
			promotionRules json.RawMessage
		)

		if err := rows.Scan(
			&policy.SubnetID,
			&policy.CIDR,
			&policy.Classification,
			&promotionRules,
			&policy.ReaperProfile,
			&policy.AllowIPAsID,
			&policy.CreatedAt,
			&policy.UpdatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan subnet policy: %w", err)
		}

		if len(promotionRules) > 0 {
			if err := json.Unmarshal(promotionRules, &policy.PromotionRules); err != nil {
				return nil, fmt.Errorf("parse promotion_rules: %w", err)
			}
		}

		policies = append(policies, &policy)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate subnet policies: %w", err)
	}

	return policies, nil
}

// ListMergeAuditEvents returns merge audit events optionally filtered by device involvement.
func (db *DB) ListMergeAuditEvents(ctx context.Context, deviceID string, limit int) ([]*models.MergeAuditEvent, error) {
	if !db.UseCNPGReads() {
		return nil, fmt.Errorf("cnpg reads not available")
	}

	if limit <= 0 {
		limit = 100
	}

	deviceID = strings.TrimSpace(deviceID)

	var (
		rows pgx.Rows
		err  error
	)

	if deviceID != "" {
		rows, err = db.pgPool.Query(ctx, listMergeAuditByDeviceSQL, deviceID, limit)
	} else {
		rows, err = db.pgPool.Query(ctx, listMergeAuditSQL, limit)
	}
	if err != nil {
		return nil, fmt.Errorf("list merge audit: %w", err)
	}
	defer rows.Close()

	var events []*models.MergeAuditEvent

	for rows.Next() {
		var (
			ev          models.MergeAuditEvent
			confidence  *float64
			detailsJSON json.RawMessage
		)

		if err := rows.Scan(
			&ev.EventID,
			&ev.FromDeviceID,
			&ev.ToDeviceID,
			&ev.Reason,
			&confidence,
			&ev.Source,
			&detailsJSON,
			&ev.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan merge audit: %w", err)
		}

		ev.ConfidenceScore = confidence

		if len(detailsJSON) > 0 {
			var details map[string]string
			if err := json.Unmarshal(detailsJSON, &details); err == nil {
				ev.Details = details
			}
		}

		events = append(events, &ev)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate merge audit: %w", err)
	}

	return events, nil
}
