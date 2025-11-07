package db

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/carverauto/serviceradar/pkg/models"
)

// InsertDeviceCapabilityEvent records a capability check outcome in the
// device_capabilities audit stream. The versioned registry is maintained by a
// ClickHouse materialized view; callers only need to insert into the audit
// stream.
func (db *DB) InsertDeviceCapabilityEvent(ctx context.Context, event *models.DeviceCapabilityEvent) error {
	if event == nil {
		return fmt.Errorf("%w: device capability event is nil", ErrFailedToInsert)
	}

	if event.EventID == "" {
		event.EventID = uuid.NewString()
	}
	if event.RecordedBy == "" {
		event.RecordedBy = "system"
	}
	if event.LastChecked.IsZero() {
		event.LastChecked = time.Now().UTC()
	}
	if event.State == "" {
		event.State = "unknown"
	}

	metadataJSON := "{}"
	if len(event.Metadata) > 0 {
		if raw, err := json.Marshal(event.Metadata); err != nil {
			db.logger.Warn().
				Err(err).
				Str("device_id", event.DeviceID).
				Str("capability", event.Capability).
				Msg("failed to marshal capability metadata; storing empty object")
		} else {
			metadataJSON = string(raw)
		}
	}

	const query = `
INSERT INTO device_capabilities (
    event_id,
    device_id,
    service_id,
    service_type,
    capability,
    state,
    enabled,
    last_checked,
    last_success,
    last_failure,
    failure_reason,
    metadata,
    recorded_by
) VALUES (
    $1, $2, $3, $4, $5,
    $6, $7, $8, $9, $10,
    $11, $12, $13
	)`

	if err := db.Conn.Exec(
		ctx,
		query,
		event.EventID,
		event.DeviceID,
		event.ServiceID,
		event.ServiceType,
		event.Capability,
		event.State,
		event.Enabled,
		event.LastChecked,
		event.LastSuccess,
		event.LastFailure,
		event.FailureReason,
		metadataJSON,
		event.RecordedBy,
	); err != nil {
		return fmt.Errorf("%w: device capability event insert failed: %w", ErrFailedToInsert, err)
	}

	const registryQuery = `
INSERT INTO device_capability_registry (
    device_id,
    capability,
    service_id,
    service_type,
    state,
    enabled,
    last_checked,
    last_success,
    last_failure,
    failure_reason,
    metadata,
    recorded_by
) VALUES (
    $1, $2, $3, $4, $5,
    $6, $7, $8, $9, $10,
    $11, $12
)`

	if err := db.Conn.Exec(
		ctx,
		registryQuery,
		event.DeviceID,
		event.Capability,
		event.ServiceID,
		event.ServiceType,
		event.State,
		event.Enabled,
		event.LastChecked,
		event.LastSuccess,
		event.LastFailure,
		event.FailureReason,
		metadataJSON,
		event.RecordedBy,
	); err != nil {
		return fmt.Errorf("%w: device capability registry upsert failed: %w", ErrFailedToInsert, err)
	}

	return nil
}
