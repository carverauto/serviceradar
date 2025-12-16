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

// InsertOTELLogs persists OTEL log rows into the configured CNPG table.
func (db *DB) InsertOTELLogs(ctx context.Context, table string, rows []models.OTELLogRow) error {
	if len(rows) == 0 {
		return nil
	}

	if !db.cnpgConfigured() {
		return ErrCNPGUnavailable
	}

	sanitized, canonical := sanitizeObservabilityTable(table, defaultLogsTable)

	query := fmt.Sprintf(`INSERT INTO %s (
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
	) ON CONFLICT DO NOTHING`, sanitized)

	batch := &pgx.Batch{}
	now := time.Now().UTC()

	for i := range rows {
		ts := rows[i].Timestamp
		if ts.IsZero() {
			ts = now
		}

		batch.Queue(query,
			ts.UTC(),
			rows[i].TraceID,
			rows[i].SpanID,
			rows[i].SeverityText,
			rows[i].SeverityNumber,
			rows[i].Body,
			rows[i].ServiceName,
			rows[i].ServiceVersion,
			rows[i].ServiceInstance,
			rows[i].ScopeName,
			rows[i].ScopeVersion,
			rows[i].Attributes,
			rows[i].ResourceAttributes,
		)
	}

	return db.sendCNPG(ctx, batch, fmt.Sprintf("%s logs", canonical))
}

// InsertOTELMetrics persists OTEL metric rows into the configured CNPG table.
func (db *DB) InsertOTELMetrics(ctx context.Context, table string, rows []models.OTELMetricRow) error {
	if len(rows) == 0 {
		return nil
	}

	if !db.cnpgConfigured() {
		return ErrCNPGUnavailable
	}

	sanitized, canonical := sanitizeObservabilityTable(table, defaultMetricsTable)

	query := fmt.Sprintf(`INSERT INTO %s (
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
	) ON CONFLICT DO NOTHING`, sanitized)

	batch := &pgx.Batch{}
	now := time.Now().UTC()

	for i := range rows {
		ts := rows[i].Timestamp
		if ts.IsZero() {
			ts = now
		}

		batch.Queue(query,
			ts.UTC(),
			rows[i].TraceID,
			rows[i].SpanID,
			rows[i].ServiceName,
			rows[i].SpanName,
			rows[i].SpanKind,
			rows[i].DurationMs,
			rows[i].DurationSeconds,
			rows[i].MetricType,
			rows[i].HTTPMethod,
			rows[i].HTTPRoute,
			rows[i].HTTPStatusCode,
			rows[i].GRPCService,
			rows[i].GRPCMethod,
			rows[i].GRPCStatusCode,
			rows[i].IsSlow,
			rows[i].Component,
			rows[i].Level,
			rows[i].Unit,
		)
	}

	return db.sendCNPG(ctx, batch, fmt.Sprintf("%s metrics", canonical))
}

// InsertOTELTraces persists OTEL trace rows into the configured CNPG table.
func (db *DB) InsertOTELTraces(ctx context.Context, table string, rows []models.OTELTraceRow) error {
	if len(rows) == 0 {
		return nil
	}

	if !db.cnpgConfigured() {
		return ErrCNPGUnavailable
	}

	sanitized, canonical := sanitizeObservabilityTable(table, defaultTracesTable)

	query := fmt.Sprintf(`INSERT INTO %s (
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
	) ON CONFLICT DO NOTHING`, sanitized)

	batch := &pgx.Batch{}
	now := time.Now().UTC()

	for i := range rows {
		ts := rows[i].Timestamp
		if ts.IsZero() {
			ts = now
		}

		batch.Queue(query,
			ts.UTC(),
			rows[i].TraceID,
			rows[i].SpanID,
			rows[i].ParentSpanID,
			rows[i].Name,
			rows[i].Kind,
			rows[i].StartTimeUnixNano,
			rows[i].EndTimeUnixNano,
			rows[i].ServiceName,
			rows[i].ServiceVersion,
			rows[i].ServiceInstance,
			rows[i].ScopeName,
			rows[i].ScopeVersion,
			rows[i].StatusCode,
			rows[i].StatusMessage,
			rows[i].Attributes,
			rows[i].ResourceAttributes,
			rows[i].Events,
			rows[i].Links,
		)
	}

	return db.sendCNPG(ctx, batch, fmt.Sprintf("%s traces", canonical))
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
