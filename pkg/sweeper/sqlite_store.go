package sweeper

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"time"
)

var (
	errGetResults   = errors.New("error getting results")
	errPruneResults = errors.New("error pruning results")
)

type SQLiteStore struct {
	db *sql.DB
}

// queryBuilder helps construct SQL queries with parameters.
type queryBuilder struct {
	query string
	args  []interface{}
}

func (s *SQLiteStore) SaveResult(ctx context.Context, result *Result) error {
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

// newQueryBuilder initializes a queryBuilder with base query.
func newQueryBuilder() *queryBuilder {
	return &queryBuilder{
		query: `
            SELECT host, port, available, first_seen, last_seen, response_time, error
            FROM sweep_results
            WHERE 1=1
        `,
		args: make([]interface{}, 0),
	}
}

// addHostFilter adds host filter if specified.
func (qb *queryBuilder) addHostFilter(host string) {
	if host != "" {
		qb.query += " AND host = ?"
		qb.args = append(qb.args, host)
	}
}

// addPortFilter adds port filter if specified.
func (qb *queryBuilder) addPortFilter(port int) {
	if port != 0 {
		qb.query += " AND port = ?"
		qb.args = append(qb.args, port)
	}
}

// addTimeRangeFilter adds time range filters if specified.
func (qb *queryBuilder) addTimeRangeFilter(startTime, endTime time.Time) {
	if !startTime.IsZero() {
		qb.query += " AND last_seen >= ?"
		qb.args = append(qb.args, startTime)
	}

	if !endTime.IsZero() {
		qb.query += " AND last_seen <= ?"
		qb.args = append(qb.args, endTime)
	}
}

// addAvailabilityFilter adds availability filter if specified.
func (qb *queryBuilder) addAvailabilityFilter(available *bool) {
	if available != nil {
		qb.query += " AND available = ?"
		qb.args = append(qb.args, *available)
	}
}

// finalize adds ordering and returns the complete query and args.
func (qb *queryBuilder) finalize() (queryString string, queryArgs []interface{}) {
	qb.query += " ORDER BY last_seen DESC"
	return qb.query, qb.args
}

// scanRow scans a single row into a Result struct.
func scanRow(rows *sql.Rows) (*Result, error) {
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
		r.Error = fmt.Errorf("%w: %s", errGetResults, errStr.String)
	}

	return &r, nil
}

func (s *SQLiteStore) GetResults(ctx context.Context, filter *ResultFilter) ([]Result, error) {
	// Build query
	qb := newQueryBuilder()
	qb.addHostFilter(filter.Host)
	qb.addPortFilter(filter.Port)
	qb.addTimeRangeFilter(filter.StartTime, filter.EndTime)
	qb.addAvailabilityFilter(filter.Available)
	query, args := qb.finalize()

	// Execute query
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("failed to query results: %w", err)
	}
	defer func(rows *sql.Rows) {
		err := rows.Close()
		if err != nil {
			log.Print("Error closing rows: ", err)
		}
	}(rows)

	// Process results
	var results []Result

	for rows.Next() {
		result, err := scanRow(rows)
		if err != nil {
			return nil, err
		}

		results = append(results, *result)
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
		return fmt.Errorf("%w %w", errPruneResults, err)
	}

	return nil
}
