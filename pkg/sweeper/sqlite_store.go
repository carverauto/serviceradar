package sweeper

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

const schema = `
CREATE TABLE IF NOT EXISTS sweep_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    host TEXT NOT NULL,
    port INTEGER NOT NULL,
    available BOOLEAN NOT NULL,
    first_seen TIMESTAMP NOT NULL,
    last_seen TIMESTAMP NOT NULL,
    response_time INTEGER NOT NULL,
    error TEXT,
    UNIQUE(host, port)
);

CREATE INDEX IF NOT EXISTS idx_sweep_results_host_port ON sweep_results(host, port);
CREATE INDEX IF NOT EXISTS idx_sweep_results_last_seen ON sweep_results(last_seen);
`

type SQLiteStore struct {
	db *sql.DB
}

func NewSQLiteStore(db *sql.DB) (*SQLiteStore, error) {
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("failed to create schema: %w", err)
	}

	return &SQLiteStore{db: db}, nil
}

func (s *SQLiteStore) SaveResult(ctx context.Context, result Result) error {
	// Use upsert to handle both new and existing results
	const query = `
        INSERT INTO sweep_results (
            host, port, available, first_seen, last_seen, response_time, error
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(host, port) DO UPDATE SET
            available = ?,
            last_seen = ?,
            response_time = ?,
            error = ?
        WHERE host = ? AND port = ?
    `
	errStr := ""
	if result.Error != nil {
		errStr = result.Error.Error()
	}

	respTimeNanos := result.RespTime.Nanoseconds()

	_, err := s.db.ExecContext(ctx, query,
		result.Target.Host, result.Target.Port,
		result.Available, result.FirstSeen, result.LastSeen,
		respTimeNanos, errStr,
		// For the UPDATE part
		result.Available, result.LastSeen,
		respTimeNanos, errStr,
		result.Target.Host, result.Target.Port,
	)

	if err != nil {
		return fmt.Errorf("failed to save result: %w", err)
	}

	return nil
}

func (s *SQLiteStore) GetResults(ctx context.Context, filter ResultFilter) ([]Result, error) {
	query := `
        SELECT host, port, available, first_seen, last_seen, response_time, error
        FROM sweep_results
        WHERE 1=1
    `
	var args []interface{}

	if filter.Host != "" {
		query += " AND host = ?"
		args = append(args, filter.Host)
	}
	if filter.Port != 0 {
		query += " AND port = ?"
		args = append(args, filter.Port)
	}
	if !filter.StartTime.IsZero() {
		query += " AND last_seen >= ?"
		args = append(args, filter.StartTime)
	}
	if !filter.EndTime.IsZero() {
		query += " AND last_seen <= ?"
		args = append(args, filter.EndTime)
	}
	if filter.Available != nil {
		query += " AND available = ?"
		args = append(args, *filter.Available)
	}

	query += " ORDER BY last_seen DESC"

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("failed to query results: %w", err)
	}
	defer rows.Close()

	var results []Result
	for rows.Next() {
		var r Result
		var errStr sql.NullString
		var respTimeNanos int64

		err := rows.Scan(
			&r.Target.Host,
			&r.Target.Port,
			&r.Available,
			&r.FirstSeen,
			&r.LastSeen,
			&respTimeNanos,
			&errStr,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan row: %w", err)
		}

		r.RespTime = time.Duration(respTimeNanos)
		if errStr.Valid {
			r.Error = fmt.Errorf(errStr.String)
		}

		results = append(results, r)
	}

	return results, nil
}

func (s *SQLiteStore) PruneResults(ctx context.Context, age time.Duration) error {
	cutoff := time.Now().Add(-age)

	_, err := s.db.ExecContext(ctx,
		"DELETE FROM sweep_results WHERE last_seen < ?",
		cutoff,
	)
	if err != nil {
		return fmt.Errorf("failed to prune results: %w", err)
	}

	return nil
}
