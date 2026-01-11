package db

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const defaultOCSFEventsTable = "ocsf_events"

func buildOCSFEventsInsertQuery(table string) string {
	return fmt.Sprintf(`INSERT INTO %s (
		id,
		time,
		class_uid,
		category_uid,
		type_uid,
		activity_id,
		activity_name,
		severity_id,
		severity,
		message,
		status_id,
		status,
		status_code,
		status_detail,
		metadata,
		observables,
		trace_id,
		span_id,
		actor,
		device,
		src_endpoint,
		dst_endpoint,
		log_name,
		log_provider,
		log_level,
		log_version,
		unmapped,
		raw_data,
		tenant_id,
		created_at
	) VALUES (
		$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,
		$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,
		$21,$22,$23,$24,$25,$26,$27,$28,$29,$30
	) ON CONFLICT (id, time) DO NOTHING`, table)
}

// InsertOCSFEvents persists OCSF event rows into the configured CNPG table.
func (db *DB) InsertOCSFEvents(ctx context.Context, table string, rows []models.OCSFEventRow) error {
	if len(rows) == 0 {
		return nil
	}

	if !db.cnpgConfigured() {
		return ErrDatabaseNotInitialized
	}

	sanitizedTable, canonicalTable := sanitizeObservabilityTable(table, defaultOCSFEventsTable)
	query := buildOCSFEventsInsertQuery(sanitizedTable)

	batch := &pgx.Batch{}
	now := time.Now().UTC()

	for i := range rows {
		row := rows[i]
		if row.ID == "" {
			continue
		}

		ts := row.Time
		if ts.IsZero() {
			ts = now
		}

		createdAt := row.CreatedAt
		if createdAt.IsZero() {
			createdAt = now
		}

		severityID := row.SeverityID
		if severityID == 0 {
			severityID = 1
		}

		batch.Queue(
			query,
			row.ID,
			ts,
			row.ClassUID,
			row.CategoryUID,
			row.TypeUID,
			row.ActivityID,
			row.ActivityName,
			severityID,
			row.Severity,
			row.Message,
			row.StatusID,
			row.Status,
			row.StatusCode,
			row.StatusDetail,
			row.Metadata,
			row.Observables,
			row.TraceID,
			row.SpanID,
			row.Actor,
			row.Device,
			row.SrcEndpoint,
			row.DstEndpoint,
			row.LogName,
			row.LogProvider,
			row.LogLevel,
			row.LogVersion,
			row.Unmapped,
			row.RawData,
			row.TenantID,
			createdAt,
		)
	}

	if err := sendBatchExecAll(ctx, batch, db.conn().SendBatch, canonicalTable); err != nil {
		return fmt.Errorf("failed to insert ocsf events: %w", err)
	}

	return nil
}
