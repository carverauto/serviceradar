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

const upsertDeviceIdentifiersSQL = `
INSERT INTO device_identifiers (
	device_id,
	id_type,
	id_value,
	confidence,
	source,
	first_seen,
	last_seen,
	verified,
	metadata
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9
)
ON CONFLICT (id_type, id_value) DO UPDATE SET
	device_id = EXCLUDED.device_id,
	confidence = EXCLUDED.confidence,
	source = EXCLUDED.source,
	first_seen = LEAST(device_identifiers.first_seen, EXCLUDED.first_seen),
	last_seen = GREATEST(device_identifiers.last_seen, EXCLUDED.last_seen),
	verified = device_identifiers.verified OR EXCLUDED.verified,
	metadata = COALESCE(device_identifiers.metadata, '{}'::jsonb) || COALESCE(EXCLUDED.metadata, '{}'::jsonb);
`

const insertSightingEventsSQL = `
INSERT INTO sighting_events (
	sighting_id,
	device_id,
	event_type,
	actor,
	details,
	created_at
) VALUES ($1,$2,$3,$4,$5,$6)
`

var (
	errIdentifierNil     = errors.New("identifier is nil")
	errDeviceIDMissing   = errors.New("device_id missing")
	errIDTypeMissing     = errors.New("id_type missing")
	errIDValueMissing    = errors.New("id_value missing")
	errSightingEventNil  = errors.New("event is nil")
	errSightingIDMissing = errors.New("sighting_id missing")
	errEventTypeMissing  = errors.New("event_type missing")
)

// UpsertDeviceIdentifiers writes identifier rows for devices.
func (db *DB) UpsertDeviceIdentifiers(ctx context.Context, identifiers []*models.DeviceIdentifier) error {
	if len(identifiers) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, id := range identifiers {
		args, err := buildDeviceIdentifierArgs(id)
		if err != nil {
			db.logger.Warn().
				Err(err).
				Str("id_type", safeIDType(id)).
				Str("id_value", safeIDValue(id)).
				Msg("skipping device identifier")
			continue
		}
		batch.Queue(upsertDeviceIdentifiersSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "device identifiers")
}

func buildDeviceIdentifierArgs(id *models.DeviceIdentifier) ([]interface{}, error) {
	if id == nil {
		return nil, errIdentifierNil
	}

	devID := strings.TrimSpace(id.DeviceID)
	if devID == "" {
		return nil, errDeviceIDMissing
	}

	idType := strings.TrimSpace(id.IDType)
	if idType == "" {
		return nil, errIDTypeMissing
	}

	idValue := strings.TrimSpace(id.IDValue)
	if idValue == "" {
		return nil, errIDValueMissing
	}

	confidence := strings.TrimSpace(id.Confidence)
	if confidence == "" {
		confidence = "weak"
	}

	source := strings.TrimSpace(id.Source)

	firstSeen := sanitizeTimestamp(id.FirstSeen)
	lastSeen := sanitizeTimestamp(id.LastSeen)

	var metadata interface{}
	if len(id.Metadata) > 0 {
		bytes, err := json.Marshal(id.Metadata)
		if err != nil {
			return nil, fmt.Errorf("metadata: %w", err)
		}
		metadata = json.RawMessage(bytes)
	} else {
		// Database has NOT NULL constraint with DEFAULT '{}', but explicit NULL bypasses default
		metadata = json.RawMessage("{}")
	}

	return []interface{}{
		devID,
		idType,
		idValue,
		confidence,
		source,
		firstSeen,
		lastSeen,
		id.Verified,
		metadata,
	}, nil
}

// InsertSightingEvents records audit events for sightings.
func (db *DB) InsertSightingEvents(ctx context.Context, events []*models.SightingEvent) error {
	if len(events) == 0 || !db.useCNPGWrites() {
		return nil
	}

	batch := &pgx.Batch{}
	queued := 0

	for _, ev := range events {
		args, err := buildSightingEventArgs(ev)
		if err != nil {
			db.logger.Warn().
				Err(err).
				Str("sighting_id", safeSightingID(ev)).
				Msg("skipping sighting event")
			continue
		}
		batch.Queue(insertSightingEventsSQL, args...)
		queued++
	}

	if queued == 0 {
		return nil
	}

	return db.sendCNPG(ctx, batch, "sighting events")
}

func buildSightingEventArgs(ev *models.SightingEvent) ([]interface{}, error) {
	if ev == nil {
		return nil, errSightingEventNil
	}

	sightingID := strings.TrimSpace(ev.SightingID)
	if sightingID == "" {
		return nil, errSightingIDMissing
	}

	eventType := strings.TrimSpace(ev.EventType)
	if eventType == "" {
		return nil, errEventTypeMissing
	}

	actor := strings.TrimSpace(ev.Actor)
	if actor == "" {
		actor = systemActor
	}

	createdAt := ev.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Now()
	}

	var details interface{}
	if len(ev.Details) > 0 {
		bytes, err := json.Marshal(ev.Details)
		if err != nil {
			return nil, fmt.Errorf("details: %w", err)
		}
		details = json.RawMessage(bytes)
	}

	return []interface{}{
		sightingID,
		toNullableString(stringPtr(ev.DeviceID)),
		eventType,
		actor,
		details,
		sanitizeTimestamp(createdAt),
	}, nil
}

func safeIDType(id *models.DeviceIdentifier) string {
	if id == nil {
		return ""
	}
	return id.IDType
}

func safeIDValue(id *models.DeviceIdentifier) string {
	if id == nil {
		return ""
	}
	return id.IDValue
}

func stringPtr(v string) *string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	return &v
}

func safeSightingID(ev *models.SightingEvent) string {
	if ev == nil {
		return ""
	}
	return ev.SightingID
}
