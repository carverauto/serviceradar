package core

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultSnapshotLimit = 200
	logSeverityError     = "error"
	logSeverityErrAlias  = "err"
)

// DBLogDigestSource hydrates log digests from Proton via the db.Service abstraction.
type DBLogDigestSource struct {
	db     db.Service
	logger logger.Logger
	now    func() time.Time
}

// NewDBLogDigestSource constructs a DB-backed log digest source.
func NewDBLogDigestSource(database db.Service, log logger.Logger) *DBLogDigestSource {
	return &DBLogDigestSource{
		db:     database,
		logger: log,
		now:    time.Now,
	}
}

// Fetch loads the latest fatal/error logs and rolling counters.
func (s *DBLogDigestSource) Fetch(ctx context.Context, limit int) (*models.LogDigestSnapshot, error) {
	if limit <= 0 {
		limit = defaultSnapshotLimit
	}

	entries, err := s.fetchRecentEntries(ctx, limit)
	if err != nil {
		return nil, err
	}

	window1h, err := s.fetchWindowCounts(ctx, 1*time.Hour)
	if err != nil {
		return nil, err
	}

	window24h, err := s.fetchWindowCounts(ctx, 24*time.Hour)
	if err != nil {
		return nil, err
	}

	snapshot := &models.LogDigestSnapshot{
		Entries: entries,
		Counters: models.LogCounters{
			UpdatedAt: s.now().UTC(),
			Window1H:  convertWindowCounts(window1h),
			Window24H: convertWindowCounts(window24h),
		},
	}

	return snapshot, nil
}

func (s *DBLogDigestSource) fetchRecentEntries(ctx context.Context, limit int) ([]models.LogSummary, error) {
	query := fmt.Sprintf(`
        SELECT
            timestamp,
            severity_text,
            service_name,
            trace_id,
            span_id,
            body
        FROM table(logs)
        WHERE timestamp >= now() - INTERVAL 24 HOUR
          AND lower(severity_text) IN ('fatal', 'error')
        ORDER BY timestamp DESC
        LIMIT %d`, limit)

	rows, err := s.db.ExecuteQuery(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("fetch recent critical logs: %w", err)
	}

	results := make([]models.LogSummary, 0, len(rows))
	for _, row := range rows {
		ts, _ := row["timestamp"].(time.Time)
		entry := models.LogSummary{
			Timestamp:   ts.UTC(),
			Severity:    toString(row["severity_text"]),
			ServiceName: toString(row["service_name"]),
			Body:        toString(row["body"]),
			TraceID:     toString(row["trace_id"]),
			SpanID:      toString(row["span_id"]),
		}
		results = append(results, entry)
	}

	return results, nil
}

func (s *DBLogDigestSource) fetchWindowCounts(ctx context.Context, window time.Duration) (map[string]int, error) {
	hours := int(window.Hours())
	query := fmt.Sprintf(`
        SELECT
            severity_text,
            count() AS total
        FROM table(logs)
        WHERE timestamp >= now() - INTERVAL %d HOUR
        GROUP BY severity_text`, hours)

	rows, err := s.db.ExecuteQuery(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("fetch log counters for window %s: %w", window, err)
	}

	counts := make(map[string]int, len(rows))
	for _, row := range rows {
		severity := strings.ToLower(toString(row["severity_text"]))
		if severity == "" {
			severity = statusUnknown
		}
		counts[severity] += toInt(row["total"])
	}

	return counts, nil
}

func convertWindowCounts(raw map[string]int) models.SeverityWindowCounts {
	var window models.SeverityWindowCounts

	for severity, count := range raw {
		switch severity {
		case "fatal", "critical":
			window.Fatal += count
		case logSeverityError, logSeverityErrAlias:
			window.Error += count
		case "warn", "warning":
			window.Warning += count
		case "info", "information":
			window.Info += count
		case "debug", "trace":
			window.Debug += count
		default:
			window.Other += count
		}

		window.Total += count
	}

	return window
}

func toString(value interface{}) string {
	switch v := value.(type) {
	case string:
		return v
	case []byte:
		return string(v)
	case fmt.Stringer:
		return v.String()
	case nil:
		return ""
	default:
		return fmt.Sprintf("%v", v)
	}
}

func toInt(value interface{}) int {
	switch v := value.(type) {
	case int:
		return v
	case int32:
		return int(v)
	case int64:
		return int(v)
	case uint32:
		return int(v)
	case uint64:
		return int(v)
	case float64:
		return int(v)
	case float32:
		return int(v)
	default:
		return 0
	}
}
