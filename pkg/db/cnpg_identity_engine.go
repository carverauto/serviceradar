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
	"strings"
)

// DeviceIdentifier represents a device identifier for the IdentityEngine.
// This is used for inserting/updating device identifiers in the device_identifiers table.
type DeviceIdentifier struct {
	DeviceID        string
	IdentifierType  string
	IdentifierValue string
	Partition       string
}

const (
	// SQL for looking up a device ID by a single identifier
	getDeviceIDByIdentifierSQL = `
SELECT device_id
FROM device_identifiers
WHERE identifier_type = $1
  AND identifier_value = $2
  AND partition = $3
LIMIT 1`

	// SQL for batch lookup of device IDs by identifier type and values
	batchGetDeviceIDsByIdentifierSQL = `
SELECT identifier_value, device_id
FROM device_identifiers
WHERE identifier_type = $1
  AND identifier_value = ANY($2)`

	// SQL for upserting device identifiers (new schema with partition)
	upsertDeviceIdentifierNewSQL = `
INSERT INTO device_identifiers (device_id, identifier_type, identifier_value, partition, first_seen, last_seen)
VALUES ($1, $2, $3, $4, NOW(), NOW())
ON CONFLICT (identifier_type, identifier_value, partition)
DO UPDATE SET
    device_id = EXCLUDED.device_id,
    last_seen = NOW()
WHERE device_identifiers.device_id = EXCLUDED.device_id`
)

// GetDeviceIDByIdentifier looks up a device ID by identifier type, value, and partition.
// Returns empty string if not found.
func (db *DB) GetDeviceIDByIdentifier(ctx context.Context, identifierType, identifierValue, partition string) (string, error) {
	if !db.useCNPGWrites() || identifierType == "" || identifierValue == "" {
		return "", nil
	}

	if partition == "" {
		partition = "default"
	}

	rows, err := db.conn().Query(ctx, getDeviceIDByIdentifierSQL, identifierType, identifierValue, partition)
	if err != nil {
		return "", err
	}
	defer rows.Close()

	if rows.Next() {
		var deviceID string
		if err := rows.Scan(&deviceID); err != nil {
			return "", err
		}
		return strings.TrimSpace(deviceID), nil
	}

	return "", nil
}

// BatchGetDeviceIDsByIdentifier looks up device IDs for multiple identifier values of the same type.
// Returns a map of identifier_value -> device_id.
func (db *DB) BatchGetDeviceIDsByIdentifier(ctx context.Context, identifierType string, identifierValues []string) (map[string]string, error) {
	result := make(map[string]string)

	if !db.useCNPGWrites() || identifierType == "" || len(identifierValues) == 0 {
		return result, nil
	}

	rows, err := db.conn().Query(ctx, batchGetDeviceIDsByIdentifierSQL, identifierType, identifierValues)
	if err != nil {
		return result, err
	}
	defer rows.Close()

	for rows.Next() {
		var idValue, deviceID string
		if err := rows.Scan(&idValue, &deviceID); err != nil {
			continue
		}
		idValue = strings.TrimSpace(idValue)
		deviceID = strings.TrimSpace(deviceID)
		if idValue != "" && deviceID != "" {
			result[idValue] = deviceID
		}
	}

	return result, rows.Err()
}

// UpsertDeviceIdentifiersNew inserts or updates device identifiers using the new schema.
// The new schema has a unique constraint on (identifier_type, identifier_value, partition).
func (db *DB) UpsertDeviceIdentifiersNew(ctx context.Context, identifiers []DeviceIdentifier) error {
	if !db.useCNPGWrites() || len(identifiers) == 0 {
		return nil
	}

	for _, id := range identifiers {
		if id.DeviceID == "" || id.IdentifierType == "" || id.IdentifierValue == "" {
			continue
		}

		partition := id.Partition
		if partition == "" {
			partition = "default"
		}

		_, err := db.conn().Exec(ctx, upsertDeviceIdentifierNewSQL,
			id.DeviceID,
			id.IdentifierType,
			id.IdentifierValue,
			partition,
		)
		if err != nil {
			db.logger.Debug().
				Err(err).
				Str("device_id", id.DeviceID).
				Str("identifier_type", id.IdentifierType).
				Str("identifier_value", id.IdentifierValue).
				Msg("Failed to upsert device identifier")
			// Continue with other identifiers
		}
	}

	return nil
}
