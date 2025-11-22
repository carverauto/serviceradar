package db

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

// InsertEvents persists CloudEvents rows into the CNPG-backed events table.
func (db *DB) InsertEvents(ctx context.Context, rows []*models.EventRow) error {
	if len(rows) == 0 {
		return nil
	}

	if !db.cnpgConfigured() {
		return ErrDatabaseNotInitialized
	}

	batch := &pgx.Batch{}

	for _, row := range rows {
		if row == nil {
			continue
		}

		ts := row.EventTimestamp
		if ts.IsZero() {
			ts = time.Now().UTC()
		}

		batch.Queue(
			`INSERT INTO events (
				event_timestamp,
				specversion,
				id,
				source,
				type,
				datacontenttype,
				subject,
				remote_addr,
				host,
				level,
				severity,
				short_message,
				version,
				raw_data
			) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
			ON CONFLICT (id, event_timestamp) DO UPDATE SET
				event_timestamp = EXCLUDED.event_timestamp,
				specversion     = EXCLUDED.specversion,
				source          = EXCLUDED.source,
				type            = EXCLUDED.type,
				datacontenttype = EXCLUDED.datacontenttype,
				subject         = EXCLUDED.subject,
				remote_addr     = EXCLUDED.remote_addr,
				host            = EXCLUDED.host,
				level           = EXCLUDED.level,
				severity        = EXCLUDED.severity,
				short_message   = EXCLUDED.short_message,
				version         = EXCLUDED.version,
				raw_data        = EXCLUDED.raw_data`,
			ts,
			row.SpecVersion,
			row.ID,
			row.Source,
			row.Type,
			row.DataContentType,
			row.Subject,
			row.RemoteAddr,
			row.Host,
			row.Level,
			row.Severity,
			row.ShortMessage,
			row.Version,
			row.RawData,
		)
	}

	br := db.pgPool.SendBatch(ctx, batch)
	if err := br.Close(); err != nil {
		return fmt.Errorf("failed to insert events: %w", err)
	}

	return nil
}
