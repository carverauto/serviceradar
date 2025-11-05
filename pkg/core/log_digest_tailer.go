package core

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	proton "github.com/timeplus-io/proton-go-driver/v2"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	criticalLogStreamQuery = `
SELECT
    timestamp,
    severity_text,
    service_name,
    trace_id,
    span_id,
    body
FROM logs
WHERE lower(severity_text) IN ('fatal', 'error')`
)

// DBLogTailer streams critical log entries from Proton via the db.Service abstraction.
type DBLogTailer struct {
	db     db.Service
	logger logger.Logger
}

// NewDBLogTailer constructs a DB-backed log tailer.
func NewDBLogTailer(database db.Service, log logger.Logger) *DBLogTailer {
	return &DBLogTailer{
		db:     database,
		logger: log,
	}
}

// Stream starts an unbounded query and forwards matching log summaries to the handler.
func (t *DBLogTailer) Stream(ctx context.Context, handler func(models.LogSummary)) error {
	if handler == nil {
		return errors.New("log digest handler cannot be nil")
	}

	conn, closeFn, err := t.openStreamingConn()
	if err != nil {
		return err
	}
	defer closeFn()

	rows, err := conn.Query(ctx, criticalLogStreamQuery)
	if err != nil {
		return fmt.Errorf("stream critical logs: %w", err)
	}
	defer func() { _ = rows.Close() }()

	for rows.Next() {
		var (
			ts       time.Time
			severity string
			service  string
			traceID  string
			spanID   string
			body     string
		)

		if scanErr := rows.Scan(&ts, &severity, &service, &traceID, &spanID, &body); scanErr != nil {
			return fmt.Errorf("scan critical log row: %w", scanErr)
		}

		handler(models.LogSummary{
			Timestamp:   ts.UTC(),
			Severity:    strings.ToLower(strings.TrimSpace(severity)),
			ServiceName: strings.TrimSpace(service),
			TraceID:     strings.TrimSpace(traceID),
			SpanID:      strings.TrimSpace(spanID),
			Body:        strings.TrimSpace(body),
		})
	}

	if err := rows.Err(); err != nil {
		if errors.Is(err, context.Canceled) {
			return nil
		}
		return fmt.Errorf("critical log stream error: %w", err)
	}

	return nil
}

func (t *DBLogTailer) openStreamingConn() (proton.Conn, func(), error) {
	if dbImpl, ok := t.db.(*db.DB); ok {
		streamConn, err := dbImpl.NewStreamingConn()
		if err != nil {
			return nil, nil, fmt.Errorf("open streaming connection: %w", err)
		}
		return streamConn, func() { _ = streamConn.Close() }, nil
	}

	connRaw, err := t.db.GetStreamingConnection()
	if err != nil {
		return nil, nil, fmt.Errorf("get streaming connection: %w", err)
	}

	conn, ok := connRaw.(proton.Conn)
	if !ok {
		return nil, nil, ErrDatabaseTypeAssertion
	}

	return conn, func() {}, nil
}
