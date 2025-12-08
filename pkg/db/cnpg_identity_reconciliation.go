package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const upsertNetworkSightingSQL = `
INSERT INTO network_sightings (
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
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10
)
ON CONFLICT (partition, ip) WHERE status = 'active'
DO UPDATE SET
	last_seen = EXCLUDED.last_seen,
	ttl_expires_at = EXCLUDED.ttl_expires_at,
	fingerprint_id = COALESCE(EXCLUDED.fingerprint_id, network_sightings.fingerprint_id),
	metadata = COALESCE(network_sightings.metadata, '{}'::jsonb) || COALESCE(EXCLUDED.metadata, '{}'::jsonb),
	source = EXCLUDED.source;
`

const expireNetworkSightingsSQL = `
UPDATE network_sightings
SET status = 'expired',
    last_seen = GREATEST(last_seen, now())
WHERE status = 'active'
  AND ttl_expires_at IS NOT NULL
  AND ttl_expires_at <= $1
RETURNING sighting_id, partition, ip, ttl_expires_at;
`

var (
	errNetworkSightingNil       = errors.New("sighting is nil")
	errNetworkSightingIPMissing = errors.New("sighting ip missing")
)

// StoreNetworkSightings upserts active sightings for partition+IP, refreshing last_seen/TTL.
func (db *DB) StoreNetworkSightings(ctx context.Context, sightings []*models.NetworkSighting) error {
	if len(sightings) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, s := range sightings {
		args, err := buildNetworkSightingArgs(s)
		if err != nil {
			db.logger.Warn().
				Err(err).
				Str("ip", safeNetworkSightingIP(s)).
				Msg("skipping network sighting for CNPG")
			continue
		}

		batch.Queue(upsertNetworkSightingSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	// Serialize network sighting writes to prevent deadlocks.
	// Uses the same mutex as device updates since sightings may be promoted to devices.
	if db.deviceUpdatesMu != nil {
		db.deviceUpdatesMu.Lock()
		defer db.deviceUpdatesMu.Unlock()
	}

	return db.sendCNPGWithRetry(ctx, batch, "network_sightings")
}

func buildNetworkSightingArgs(s *models.NetworkSighting) ([]interface{}, error) {
	if s == nil {
		return nil, errNetworkSightingNil
	}

	ip := strings.TrimSpace(s.IP)
	if ip == "" {
		return nil, errNetworkSightingIPMissing
	}

	partition := strings.TrimSpace(s.Partition)
	if partition == "" {
		partition = defaultPartitionValue
	}

	status := strings.TrimSpace(string(s.Status))
	if status == "" {
		status = string(models.SightingStatusActive)
	}

	source := strings.TrimSpace(string(s.Source))
	if source == "" {
		source = string(models.DiscoverySourceSweep)
	}

	firstSeen := sanitizeTimestamp(s.FirstSeen)
	lastSeen := sanitizeTimestamp(s.LastSeen)

	var metadata interface{}
	if len(s.Metadata) > 0 {
		bytes, err := json.Marshal(s.Metadata)
		if err != nil {
			return nil, fmt.Errorf("metadata: %w", err)
		}
		metadata = json.RawMessage(bytes)
	}

	return []interface{}{
		partition,
		ip,
		toNullableStringPtr(s.SubnetID),
		source,
		status,
		firstSeen,
		lastSeen,
		toNullableTime(s.TTLExpiresAt),
		toNullableStringPtr(s.FingerprintID),
		metadata,
	}, nil
}

func safeNetworkSightingIP(s *models.NetworkSighting) string {
	if s == nil {
		return ""
	}
	return s.IP
}

func toNullableStringPtr(v *string) interface{} {
	if v == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*v)
	if trimmed == "" {
		return nil
	}
	return trimmed
}

// ExpireNetworkSightings marks active sightings expired when TTL elapses and returns affected rows.
func (db *DB) ExpireNetworkSightings(ctx context.Context, now time.Time) ([]*models.NetworkSighting, error) {
	if !db.useCNPGWrites() {
		return nil, nil
	}

	rows, err := db.pgPool.Query(ctx, expireNetworkSightingsSQL, now.UTC())
	if err != nil {
		return nil, fmt.Errorf("expire sightings: %w", err)
	}
	defer rows.Close()

	var expired []*models.NetworkSighting
	for rows.Next() {
		var rec models.NetworkSighting
		var ttl *time.Time

		if err := rows.Scan(&rec.SightingID, &rec.Partition, &rec.IP, &ttl); err != nil {
			return nil, fmt.Errorf("scan expired sighting: %w", err)
		}
		rec.Status = models.SightingStatusExpired
		rec.TTLExpiresAt = ttl
		expired = append(expired, &rec)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate expired sightings: %w", err)
	}

	return expired, nil
}
