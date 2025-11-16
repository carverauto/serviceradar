package core

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var errLogDigestHandlerNil = errors.New("log digest handler cannot be nil")

const (
	criticalLogStreamQuery = `
SELECT
	timestamp,
	severity_text,
	service_name,
	trace_id,
	span_id,
	body,
	created_at
FROM logs
WHERE created_at >= $1
	AND lower(severity_text) IN ('fatal', 'error')
ORDER BY created_at ASC, timestamp ASC, trace_id ASC, span_id ASC
LIMIT $2`

	defaultLogTailerBatchSize    = 200
	defaultLogTailerPollInterval = 5 * time.Second
)

// DBLogTailer streams critical log entries from CNPG via the db.Service abstraction.
type DBLogTailer struct {
	db           db.Service
	logger       logger.Logger
	now          func() time.Time
	pollInterval time.Duration
	batchSize    int
}

// NewDBLogTailer constructs a DB-backed log tailer.
func NewDBLogTailer(database db.Service, log logger.Logger) *DBLogTailer {
	return &DBLogTailer{
		db:           database,
		logger:       log,
		now:          time.Now,
		pollInterval: defaultLogTailerPollInterval,
		batchSize:    defaultLogTailerBatchSize,
	}
}

// Stream starts an unbounded query and forwards matching log summaries to the handler.
func (t *DBLogTailer) Stream(ctx context.Context, handler func(models.LogSummary)) error {
	if handler == nil {
		return errLogDigestHandlerNil
	}

	cursor := t.now().UTC()
	lastKey := ""

	for {
		processed, err := t.consumeBatch(ctx, handler, &cursor, &lastKey)
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return nil
			}
			return err
		}

		if processed > 0 {
			continue
		}

		timer := time.NewTimer(t.pollInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
	}
}

func (t *DBLogTailer) consumeBatch(
	ctx context.Context,
	handler func(models.LogSummary),
	cursor *time.Time,
	lastKey *string,
) (int, error) {
	rows, err := t.db.ExecuteQuery(ctx, criticalLogStreamQuery, cursor.UTC(), t.batchSize)
	if err != nil {
		return 0, fmt.Errorf("query critical logs: %w", err)
	}

	processed := 0
	currentCursor := cursor.UTC()

	for _, row := range rows {
		createdAt, _ := row["created_at"].(time.Time)
		rowKey := buildLogRowKey(createdAt, toString(row["trace_id"]), toString(row["span_id"]))

		if createdAt.Equal(currentCursor) && rowKey <= *lastKey {
			continue
		}

		summary := models.LogSummary{
			Timestamp:   asTime(row["timestamp"]),
			Severity:    strings.ToLower(strings.TrimSpace(toString(row["severity_text"]))),
			ServiceName: strings.TrimSpace(toString(row["service_name"])),
			TraceID:     strings.TrimSpace(toString(row["trace_id"])),
			SpanID:      strings.TrimSpace(toString(row["span_id"])),
			Body:        strings.TrimSpace(toString(row["body"])),
		}

		handler(summary)
		processed++
		*cursor = createdAt.UTC()
		currentCursor = *cursor
		*lastKey = rowKey
	}

	return processed, nil
}

func buildLogRowKey(createdAt time.Time, traceID, spanID string) string {
	return fmt.Sprintf("%d|%s|%s", createdAt.UTC().UnixNano(), traceID, spanID)
}

func asTime(value interface{}) time.Time {
	switch v := value.(type) {
	case time.Time:
		return v.UTC()
	case string:
		if parsed, err := time.Parse(time.RFC3339Nano, v); err == nil {
			return parsed.UTC()
		}
	}
	return time.Time{}
}
