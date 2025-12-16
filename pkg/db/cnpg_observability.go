package db

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultLogsTable    = "logs"
	defaultMetricsTable = "otel_metrics"
	defaultTracesTable  = "otel_traces"
)

const (
	otelLogsInsertSQL = `INSERT INTO %s (
		timestamp,
		trace_id,
		span_id,
		severity_text,
		severity_number,
		body,
		service_name,
		service_version,
		service_instance,
		scope_name,
		scope_version,
		attributes,
		resource_attributes
	) VALUES (
		$1,$2,$3,$4,$5,
		$6,$7,$8,$9,$10,
		$11,$12,$13
	) ON CONFLICT DO NOTHING`

	otelMetricsInsertSQL = `INSERT INTO %s (
		timestamp,
		trace_id,
		span_id,
		service_name,
		span_name,
		span_kind,
		duration_ms,
		duration_seconds,
		metric_type,
		http_method,
		http_route,
		http_status_code,
		grpc_service,
		grpc_method,
		grpc_status_code,
		is_slow,
		component,
		level,
		unit
	) VALUES (
		$1,$2,$3,$4,$5,
		$6,$7,$8,$9,$10,
		$11,$12,$13,$14,$15,
		$16,$17,$18,$19
	) ON CONFLICT DO NOTHING`

	otelTracesInsertSQL = `INSERT INTO %s (
		timestamp,
		trace_id,
		span_id,
		parent_span_id,
		name,
		kind,
		start_time_unix_nano,
		end_time_unix_nano,
		service_name,
		service_version,
		service_instance,
		scope_name,
		scope_version,
		status_code,
		status_message,
		attributes,
		resource_attributes,
		events,
		links
	) VALUES (
		$1,$2,$3,$4,$5,
		$6,$7,$8,$9,$10,
		$11,$12,$13,$14,$15,
		$16,$17,$18,$19
	) ON CONFLICT DO NOTHING`
)

type otelRowInserter interface {
	RowCount() int
	TimestampAt(rowIndex int) time.Time
	QueueRow(batch *pgx.Batch, query string, rowIndex int, timestamp time.Time)
}

type otelLogInserter struct {
	rows []models.OTELLogRow
}

func (inserter otelLogInserter) RowCount() int { return len(inserter.rows) }

func (inserter otelLogInserter) TimestampAt(rowIndex int) time.Time {
	return inserter.rows[rowIndex].Timestamp
}

func (inserter otelLogInserter) QueueRow(batch *pgx.Batch, query string, rowIndex int, timestamp time.Time) {
	row := inserter.rows[rowIndex]
	batch.Queue(query,
		timestamp,
		row.TraceID,
		row.SpanID,
		row.SeverityText,
		row.SeverityNumber,
		row.Body,
		row.ServiceName,
		row.ServiceVersion,
		row.ServiceInstance,
		row.ScopeName,
		row.ScopeVersion,
		row.Attributes,
		row.ResourceAttributes,
	)
}

type otelMetricInserter struct {
	rows []models.OTELMetricRow
}

func (inserter otelMetricInserter) RowCount() int { return len(inserter.rows) }

func (inserter otelMetricInserter) TimestampAt(rowIndex int) time.Time {
	return inserter.rows[rowIndex].Timestamp
}

func (inserter otelMetricInserter) QueueRow(batch *pgx.Batch, query string, rowIndex int, timestamp time.Time) {
	row := inserter.rows[rowIndex]
	batch.Queue(query,
		timestamp,
		row.TraceID,
		row.SpanID,
		row.ServiceName,
		row.SpanName,
		row.SpanKind,
		row.DurationMs,
		row.DurationSeconds,
		row.MetricType,
		row.HTTPMethod,
		row.HTTPRoute,
		row.HTTPStatusCode,
		row.GRPCService,
		row.GRPCMethod,
		row.GRPCStatusCode,
		row.IsSlow,
		row.Component,
		row.Level,
		row.Unit,
	)
}

type otelTraceInserter struct {
	rows []models.OTELTraceRow
}

func (inserter otelTraceInserter) RowCount() int { return len(inserter.rows) }

func (inserter otelTraceInserter) TimestampAt(rowIndex int) time.Time {
	return inserter.rows[rowIndex].Timestamp
}

func (inserter otelTraceInserter) QueueRow(batch *pgx.Batch, query string, rowIndex int, timestamp time.Time) {
	row := inserter.rows[rowIndex]
	batch.Queue(query,
		timestamp,
		row.TraceID,
		row.SpanID,
		row.ParentSpanID,
		row.Name,
		row.Kind,
		row.StartTimeUnixNano,
		row.EndTimeUnixNano,
		row.ServiceName,
		row.ServiceVersion,
		row.ServiceInstance,
		row.ScopeName,
		row.ScopeVersion,
		row.StatusCode,
		row.StatusMessage,
		row.Attributes,
		row.ResourceAttributes,
		row.Events,
		row.Links,
	)
}

func buildOTELLogsInsertQuery(sanitizedTable string) string {
	return fmt.Sprintf(otelLogsInsertSQL, sanitizedTable)
}

func buildOTELMetricsInsertQuery(sanitizedTable string) string {
	return fmt.Sprintf(otelMetricsInsertSQL, sanitizedTable)
}

func buildOTELTracesInsertQuery(sanitizedTable string) string {
	return fmt.Sprintf(otelTracesInsertSQL, sanitizedTable)
}

func (db *DB) insertOTELRows(
	ctx context.Context,
	table string,
	defaultTable string,
	kind string,
	rowCount int,
	buildQuery func(sanitizedTable string) string,
	timestampAt func(rowIndex int) time.Time,
	queueRow func(batch *pgx.Batch, query string, rowIndex int, timestamp time.Time),
) error {
	if rowCount == 0 {
		return nil
	}

	if !db.cnpgConfigured() {
		return ErrCNPGUnavailable
	}

	sanitizedTable, canonicalTable := sanitizeObservabilityTable(table, defaultTable)
	query := buildQuery(sanitizedTable)

	batch := &pgx.Batch{}
	now := time.Now().UTC()

	for rowIndex := 0; rowIndex < rowCount; rowIndex++ {
		ts := timestampAt(rowIndex)
		if ts.IsZero() {
			ts = now
		}

		queueRow(batch, query, rowIndex, ts.UTC())
	}

	return db.sendCNPG(ctx, batch, fmt.Sprintf("%s %s", canonicalTable, kind))
}

func (db *DB) insertOTEL(
	ctx context.Context,
	table string,
	defaultTable string,
	kind string,
	buildQuery func(sanitizedTable string) string,
	inserter otelRowInserter,
) error {
	return db.insertOTELRows(
		ctx,
		table,
		defaultTable,
		kind,
		inserter.RowCount(),
		buildQuery,
		inserter.TimestampAt,
		inserter.QueueRow,
	)
}

// InsertOTELLogs persists OTEL log rows into the configured CNPG table.
func (db *DB) InsertOTELLogs(ctx context.Context, table string, rows []models.OTELLogRow) error {
	return db.insertOTEL(ctx, table, defaultLogsTable, "logs", buildOTELLogsInsertQuery, otelLogInserter{rows: rows})
}

// InsertOTELMetrics persists OTEL metric rows into the configured CNPG table.
func (db *DB) InsertOTELMetrics(ctx context.Context, table string, rows []models.OTELMetricRow) error {
	return db.insertOTEL(ctx, table, defaultMetricsTable, "metrics", buildOTELMetricsInsertQuery, otelMetricInserter{rows: rows})
}

// InsertOTELTraces persists OTEL trace rows into the configured CNPG table.
func (db *DB) InsertOTELTraces(ctx context.Context, table string, rows []models.OTELTraceRow) error {
	return db.insertOTEL(ctx, table, defaultTracesTable, "traces", buildOTELTracesInsertQuery, otelTraceInserter{rows: rows})
}

func sanitizeObservabilityTable(tableName, defaultName string) (string, string) {
	raw := strings.TrimSpace(tableName)
	if raw == "" {
		raw = defaultName
	}

	parts := strings.Split(raw, ".")
	identifiers := make([]string, 0, len(parts))

	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}

		identifiers = append(identifiers, part)
	}

	if len(identifiers) == 0 {
		identifiers = []string{defaultName}
	}

	canonical := strings.Join(identifiers, ".")
	return pgx.Identifier(identifiers).Sanitize(), canonical
}
