package dbeventwriter

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/nats-io/nats.go/jetstream"
	"github.com/timeplus-io/proton-go-driver/v2"
	v1 "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	metricsv1 "go.opentelemetry.io/proto/otlp/collector/metrics/v1"
	tracev1 "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	commonv1 "go.opentelemetry.io/proto/otlp/common/v1"
	logsv1 "go.opentelemetry.io/proto/otlp/logs/v1"
	metricspbv1 "go.opentelemetry.io/proto/otlp/metrics/v1"
	resourcev1 "go.opentelemetry.io/proto/otlp/resource/v1"
	tracepbv1 "go.opentelemetry.io/proto/otlp/trace/v1"
	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	maxInt64      = 9223372036854775807
	unknownString = "unknown"

	// GELF log levels (RFC 3164)
	gelfLevelError  = 3 // Error
	gelfLevelNotice = 5 // Notice
	gelfLevelInfo   = 6 // Info
)

var (
	// ErrFailedToParseCloudEvent indicates that data could not be parsed as a CloudEvent wrapper.
	ErrFailedToParseCloudEvent = errors.New("failed to parse as CloudEvent wrapper")
)

// safeUint64ToInt64 safely converts uint64 to int64, capping at maxInt64 if needed
func safeUint64ToInt64(u uint64) int64 {
	if u > uint64(maxInt64) {
		return maxInt64
	}

	return int64(u)
}

// Processor writes JetStream messages to Proton tables.
type Processor struct {
	conn    proton.Conn
	table   string         // Legacy single table
	streams []StreamConfig // Multi-stream configuration
	logger  logger.Logger
}

// LogRow represents a row in the logs table
type LogRow struct {
	Timestamp          time.Time `db:"timestamp"`
	TraceID            string    `db:"trace_id"`
	SpanID             string    `db:"span_id"`
	SeverityText       string    `db:"severity_text"`
	SeverityNumber     int32     `db:"severity_number"`
	Body               string    `db:"body"`
	ServiceName        string    `db:"service_name"`
	ServiceVersion     string    `db:"service_version"`
	ServiceInstance    string    `db:"service_instance"`
	ScopeName          string    `db:"scope_name"`
	ScopeVersion       string    `db:"scope_version"`
	Attributes         string    `db:"attributes"`
	ResourceAttributes string    `db:"resource_attributes"`
	// RawData removed to save storage space
}

// MetricsRow represents a row in the metrics table
type MetricsRow struct {
	Timestamp       time.Time `db:"timestamp"`
	TraceID         string    `db:"trace_id"`
	SpanID          string    `db:"span_id"`
	ServiceName     string    `db:"service_name"`
	SpanName        string    `db:"span_name"`
	SpanKind        string    `db:"span_kind"`
	DurationMs      float64   `db:"duration_ms"`
	DurationSeconds float64   `db:"duration_seconds"`
	MetricType      string    `db:"metric_type"`
	HTTPMethod      string    `db:"http_method"`
	HTTPRoute       string    `db:"http_route"`
	HTTPStatusCode  string    `db:"http_status_code"`
	GRPCService     string    `db:"grpc_service"`
	GRPCMethod      string    `db:"grpc_method"`
	GRPCStatusCode  string    `db:"grpc_status_code"`
	IsSlow          bool      `db:"is_slow"`
	Component       string    `db:"component"`
	Level           string    `db:"level"`
	// RawData removed to save storage space
}

// TracesRow represents a row in the traces table
type TracesRow struct {
	Timestamp          time.Time `db:"timestamp"`
	TraceID            string    `db:"trace_id"`
	SpanID             string    `db:"span_id"`
	ParentSpanID       string    `db:"parent_span_id"`
	Name               string    `db:"name"`
	Kind               int32     `db:"kind"`
	StartTimeUnixNano  uint64    `db:"start_time_unix_nano"`
	EndTimeUnixNano    uint64    `db:"end_time_unix_nano"`
	ServiceName        string    `db:"service_name"`
	ServiceVersion     string    `db:"service_version"`
	ServiceInstance    string    `db:"service_instance"`
	ScopeName          string    `db:"scope_name"`
	ScopeVersion       string    `db:"scope_version"`
	StatusCode         int32     `db:"status_code"`
	StatusMessage      string    `db:"status_message"`
	Attributes         string    `db:"attributes"`
	ResourceAttributes string    `db:"resource_attributes"`
	Events             string    `db:"events"`
	Links              string    `db:"links"`
	// RawData removed to save storage space
}

// parseCloudEvent attempts to extract the `data` field from a CloudEvent.
// It returns the data as a JSON string and true on success. If the message is
// not a valid CloudEvent or does not contain a `data` field, ok will be false.
func parseCloudEvent(b []byte) (string, bool) {
	var tmp struct {
		Data json.RawMessage `json:"data"`
	}

	if err := json.Unmarshal(b, &tmp); err != nil {
		return "", false
	}

	if len(tmp.Data) == 0 {
		return "", false
	}

	return string(tmp.Data), true
}

// extractAttributeValue extracts a string value from an attribute based on its type
func extractAttributeValue(attr *commonv1.KeyValue) string {
	switch {
	case attr.Value.GetStringValue() != "":
		return attr.Value.GetStringValue()
	case attr.Value.GetBoolValue():
		return "true"
	case attr.Value.GetIntValue() != 0:
		return fmt.Sprintf("%d", attr.Value.GetIntValue())
	case attr.Value.GetDoubleValue() != 0:
		return fmt.Sprintf("%f", attr.Value.GetDoubleValue())
	default:
		return ""
	}
}

// processResourceAttributes processes resource attributes and extracts service information
func processResourceAttributes(
	resource *resourcev1.Resource) (serviceName, serviceVersion, serviceInstance string, resourceAttribs []string) {
	if resource == nil {
		return "", "", "", nil
	}

	resourceAttribs = make([]string, 0, len(resource.Attributes))

	for _, attr := range resource.Attributes {
		value := extractAttributeValue(attr)
		if value == "" {
			continue
		}

		// Extract service information
		switch attr.Key {
		case "service.name":
			serviceName = value
		case "service.version":
			serviceVersion = value
		case "service.instance.id":
			serviceInstance = value
		}

		// Add to resource attributes
		resourceAttribs = append(resourceAttribs, fmt.Sprintf("%s=%s", attr.Key, value))
	}

	return serviceName, serviceVersion, serviceInstance, resourceAttribs
}

// processLogAttributes processes log record attributes
func processLogAttributes(attributes []*commonv1.KeyValue) []string {
	logAttribs := make([]string, 0, len(attributes))

	for _, attr := range attributes {
		value := extractAttributeValue(attr)
		if value == "" {
			continue
		}

		logAttribs = append(logAttribs, fmt.Sprintf("%s=%s", attr.Key, value))
	}

	return logAttribs
}

// createLogRow creates a LogRow from a log record and its context
func createLogRow(
	logRecord *logsv1.LogRecord,
	serviceName, serviceVersion, serviceInstance string,
	scopeName, scopeVersion string,
	resourceAttribs []string,
	logAttribs []string,
) LogRow {
	// Extract body text
	body := ""
	if logRecord.Body != nil && logRecord.Body.GetStringValue() != "" {
		body = logRecord.Body.GetStringValue()
	}

	// Convert timestamp safely to prevent uint64 -> int64 overflow
	var timestamp time.Time

	if logRecord.TimeUnixNano <= uint64(maxInt64) {
		timestamp = time.Unix(0, int64(logRecord.TimeUnixNano))
	} else {
		// Handle overflow case - split into seconds and remaining nanoseconds
		// For extremely large values, use a safe approach that avoids overflow
		seconds := logRecord.TimeUnixNano / 1000000000
		nanos := logRecord.TimeUnixNano % 1000000000

		// Ensure seconds is within int64 range
		var secInt64 int64

		if seconds > uint64(maxInt64) {
			// If seconds would overflow int64, use max int64 value
			// This is an extreme edge case (timestamp far in the future)
			secInt64 = maxInt64
		} else {
			secInt64 = int64(seconds)
		}

		// Explicitly check that nanos is within int64 range
		// This check is redundant since nanos is always < 1000000000 after modulo operation,
		// but it satisfies the linter
		var nanosInt64 int64

		if nanos > uint64(maxInt64) {
			// This condition should never be true after modulo 1000000000
			nanosInt64 = 0
		} else {
			nanosInt64 = int64(nanos)
		}

		timestamp = time.Unix(secInt64, nanosInt64)
	}

	// Note: Removed raw_data JSON generation to save storage space
	// The raw protobuf data was consuming massive storage with no benefit

	return LogRow{
		Timestamp:          timestamp,
		TraceID:            fmt.Sprintf("%x", logRecord.TraceId),
		SpanID:             fmt.Sprintf("%x", logRecord.SpanId),
		SeverityText:       logRecord.SeverityText,
		SeverityNumber:     int32(logRecord.SeverityNumber),
		Body:               body,
		ServiceName:        serviceName,
		ServiceVersion:     serviceVersion,
		ServiceInstance:    serviceInstance,
		ScopeName:          scopeName,
		ScopeVersion:       scopeVersion,
		Attributes:         strings.Join(logAttribs, ","),
		ResourceAttributes: strings.Join(resourceAttribs, ","),
		// RawData field removed to save storage space
	}
}

// getScopeInfo extracts scope name and version
func getScopeInfo(scope *commonv1.InstrumentationScope) (name, version string) {
	if scope == nil {
		return "", ""
	}

	return scope.Name, scope.Version
}

// parseOTELLogs parses OTEL protobuf logs data and returns LogRow entries
func parseOTELLogs(b []byte, _ string) ([]LogRow, error) {
	// Unmarshal the protobuf data
	var req v1.ExportLogsServiceRequest

	if err := proto.Unmarshal(b, &req); err != nil {
		return nil, fmt.Errorf("failed to unmarshal OTEL logs: %w", err)
	}

	// Pre-allocate result slice
	var rows []LogRow

	// Process all logs in a single loop
	for _, resourceLog := range req.ResourceLogs {
		// Skip invalid resource logs
		if resourceLog.Resource == nil {
			continue
		}

		// Get service info once per resource
		serviceName, serviceVersion, serviceInstance, resourceAttribs :=
			processResourceAttributes(resourceLog.Resource)

		// Process all scope logs for this resource
		for _, scopeLog := range resourceLog.ScopeLogs {
			// Get scope info once per scope
			scopeName, scopeVersion := getScopeInfo(scopeLog.Scope)

			// Process all log records for this scope
			for _, logRecord := range scopeLog.LogRecords {
				// Get log attributes
				logAttribs := processLogAttributes(logRecord.Attributes)

				// Build and add the log row
				row := createLogRow(
					logRecord,
					serviceName, serviceVersion, serviceInstance,
					scopeName, scopeVersion,
					resourceAttribs,
					logAttribs,
				)

				rows = append(rows, row)
			}
		}
	}

	return rows, nil
}

// processEventData handles the parsing of CloudEvent data into an EventRow
func processEventData(row *models.EventRow, ce *models.CloudEvent) {
	dataBytes, err := json.Marshal(ce.Data)
	if err != nil {
		return
	}

	// Try to handle as poller health event first
	if tryPollerHealthEvent(row, ce, dataBytes) {
		return
	}

	// Fall back to GELF format (for syslog and other events)
	tryGELFFormat(row, dataBytes)
}

// tryPollerHealthEvent attempts to parse data as a poller health event
func tryPollerHealthEvent(row *models.EventRow, ce *models.CloudEvent, dataBytes []byte) bool {
	if ce.Type != "com.carverauto.serviceradar.poller.health" &&
		ce.Subject != "events.poller.health" {
		return false
	}

	var pollerData models.PollerHealthEventData

	if err := json.Unmarshal(dataBytes, &pollerData); err != nil {
		return false
	}

	row.Host = pollerData.Host
	row.RemoteAddr = pollerData.RemoteAddr
	row.ShortMessage = fmt.Sprintf("Poller %s state changed from %s to %s",
		pollerData.PollerID, pollerData.PreviousState, pollerData.CurrentState)
	row.Level = getLogLevelForState(pollerData.CurrentState)
	row.Severity = getSeverityForState(pollerData.CurrentState)
	row.EventTimestamp = pollerData.Timestamp
	row.Version = "1.1"

	return true
}

// tryGELFFormat attempts to parse data as GELF format
func tryGELFFormat(row *models.EventRow, dataBytes []byte) {
	var gelfPayload struct {
		RemoteAddr   string  `json:"_remote_addr"`
		Host         string  `json:"host"`
		Level        int32   `json:"level"`
		Severity     string  `json:"severity"`
		ShortMessage string  `json:"short_message"`
		Timestamp    float64 `json:"timestamp"`
		Version      string  `json:"version"`
	}

	if err := json.Unmarshal(dataBytes, &gelfPayload); err != nil {
		return
	}

	row.RemoteAddr = gelfPayload.RemoteAddr
	row.Host = gelfPayload.Host
	row.Level = gelfPayload.Level
	row.Severity = gelfPayload.Severity
	row.ShortMessage = gelfPayload.ShortMessage
	row.Version = gelfPayload.Version

	// Handle GELF timestamp if present and valid
	if gelfPayload.Timestamp > 0 {
		processGELFTimestamp(row, gelfPayload.Timestamp)
	}
}

// processGELFTimestamp handles GELF timestamp conversion and validation
func processGELFTimestamp(row *models.EventRow, timestamp float64) {
	sec := int64(timestamp)
	nsec := int64((timestamp - float64(sec)) * float64(time.Second))
	ts := time.Unix(sec, nsec)

	// Validate timestamp is within ClickHouse DateTime64 range
	minTimestamp := time.Date(1925, 1, 1, 0, 0, 0, 0, time.UTC)
	maxTimestamp := time.Date(2283, 11, 11, 0, 0, 0, 0, time.UTC)

	if !ts.Before(minTimestamp) && !ts.After(maxTimestamp) {
		row.EventTimestamp = ts
	}
}

// buildEventRow parses a CloudEvent payload and returns a models.EventRow.
// Handles both GELF format (syslog) and PollerHealthEventData format (poller events).
// If parsing fails, the returned row will contain only the raw data and subject.
func buildEventRow(b []byte, subject string) models.EventRow {
	var ce models.CloudEvent

	if err := json.Unmarshal(b, &ce); err != nil {
		return models.EventRow{RawData: string(b), Subject: subject}
	}

	if ce.Subject == "" {
		ce.Subject = subject
	}

	// Create base event row from CloudEvent fields
	row := models.EventRow{
		SpecVersion:     ce.SpecVersion,
		ID:              ce.ID,
		Source:          ce.Source,
		Type:            ce.Type,
		DataContentType: ce.DataContentType,
		Subject:         ce.Subject,
		RawData:         string(b),
	}

	// Extract timestamp from CloudEvent time field if available
	if ce.Time != nil {
		row.EventTimestamp = *ce.Time
	}

	// Handle different data payload formats based on event type or subject
	if ce.Data != nil {
		processEventData(&row, &ce)
	}

	// Use current time as fallback if no valid timestamp was found
	if row.EventTimestamp.IsZero() {
		row.EventTimestamp = time.Now()
	}

	return row
}

// getLogLevelForState maps poller states to GELF log levels
func getLogLevelForState(state string) int32 {
	switch state {
	case "unhealthy":
		return gelfLevelError // Error
	case "healthy":
		return gelfLevelInfo // Info
	case unknownString:
		return gelfLevelNotice // Notice
	default:
		return gelfLevelInfo // Info
	}
}

// getSeverityForState maps poller states to severity strings
func getSeverityForState(state string) string {
	switch state {
	case "unhealthy":
		return "error"
	case "healthy":
		return "info"
	case unknownString:
		return "notice"
	default:
		return "info"
	}
}

// NewProcessor creates a Processor using the provided db.Service.
func NewProcessor(dbService db.Service, table string, log logger.Logger) (*Processor, error) {
	dbImpl, ok := dbService.(*db.DB)
	if !ok {
		return nil, errDBServiceNotDB
	}

	return &Processor{conn: dbImpl.Conn, table: table, logger: log}, nil
}

// NewProcessorWithStreams creates a Processor with multi-stream configuration.
func NewProcessorWithStreams(dbService db.Service, streams []StreamConfig, log logger.Logger) (*Processor, error) {
	dbImpl, ok := dbService.(*db.DB)
	if !ok {
		return nil, errDBServiceNotDB
	}

	return &Processor{conn: dbImpl.Conn, streams: streams, logger: log}, nil
}

// getTableForSubject returns the table name for a given subject
func (p *Processor) getTableForSubject(subject string) string {
	if len(p.streams) > 0 {
		for _, stream := range p.streams {
			if stream.Subject == subject || strings.HasPrefix(subject, stream.Subject) {
				return stream.Table
			}
		}
	}

	return p.table // fallback to legacy table
}

// ProcessBatch writes a batch of messages to appropriate tables and returns the processed messages.
func (p *Processor) ProcessBatch(ctx context.Context, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	p.logger.Info().Int("message_count", len(msgs)).Msg("ProcessBatch called")

	if len(msgs) == 0 {
		p.logger.Debug().Msg("No messages to process")
		return nil, nil
	}

	// Group messages by table
	messagesByTable := make(map[string][]jetstream.Msg)

	for _, msg := range msgs {
		table := p.getTableForSubject(msg.Subject())
		p.logger.Debug().Str("subject", msg.Subject()).Str("table", table).Msg("Message routing")
		messagesByTable[table] = append(messagesByTable[table], msg)
	}

	processed := make([]jetstream.Msg, 0, len(msgs))

	// Process each table separately
	for table, tableMsgs := range messagesByTable {
		p.logger.Info().Str("table", table).Int("message_count", len(tableMsgs)).Msg("Processing table")

		processedMsgs, err := p.processTableMessages(ctx, table, tableMsgs)
		if err != nil {
			return processed, err
		}

		processed = append(processed, processedMsgs...)
	}

	return processed, nil
}

// processTableMessages routes messages to the appropriate table processor based on table name
func (p *Processor) processTableMessages(ctx context.Context, table string, tableMsgs []jetstream.Msg) ([]jetstream.Msg, error) {
	switch {
	case strings.Contains(table, "logs"):
		p.logger.Debug().Str("table", table).Msg("Processing as logs table")
		return p.processLogsTable(ctx, table, tableMsgs)
	case strings.Contains(table, "traces"):
		p.logger.Debug().Str("table", table).Msg("Processing as traces table")
		return p.processTracesTable(ctx, table, tableMsgs)
	case strings.Contains(table, "metrics"):
		p.logger.Debug().Str("table", table).Msg("Processing as metrics table")
		return p.processMetricsTable(ctx, table, tableMsgs)
	default:
		p.logger.Debug().Str("table", table).Msg("Processing as events table")
		return p.processEventsTable(ctx, table, tableMsgs)
	}
}

// processEventsTable handles events table batch processing
func (p *Processor) processEventsTable(ctx context.Context, table string, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	query := fmt.Sprintf("INSERT INTO %s (specversion, id, source, type, datacontenttype, "+
		"subject, remote_addr, host, level, severity, short_message, event_timestamp, version, raw_data) "+
		"VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", table)

	batch, err := p.conn.PrepareBatch(ctx, query)
	if err != nil {
		return nil, err
	}

	processed := make([]jetstream.Msg, 0, len(msgs))

	for _, msg := range msgs {
		row := buildEventRow(msg.Data(), msg.Subject())

		if err := batch.Append(
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
			row.EventTimestamp,
			row.Version,
			row.RawData,
		); err != nil {
			return processed, err
		}

		processed = append(processed, msg)
	}

	if err := batch.Send(); err != nil {
		return processed, err
	}

	return processed, nil
}

// processLogsTable handles logs table batch processing
func (p *Processor) processLogsTable(ctx context.Context, table string, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	query := fmt.Sprintf("INSERT INTO %s (timestamp, trace_id, span_id, severity_text, severity_number, "+
		"body, service_name, service_version, service_instance, scope_name, scope_version, "+
		"attributes, resource_attributes) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", table)

	batch, err := p.conn.PrepareBatch(ctx, query)
	if err != nil {
		return nil, err
	}

	processed := make([]jetstream.Msg, 0, len(msgs))

	for _, msg := range msgs {
		// Handle OTEL logs
		if strings.Contains(msg.Subject(), "otel") {
			logRows, ok := p.parseOTELMessage(msg)
			if ok {
				for i := range logRows {
					if err := batch.Append(
						logRows[i].Timestamp,
						logRows[i].TraceID,
						logRows[i].SpanID,
						logRows[i].SeverityText,
						logRows[i].SeverityNumber,
						logRows[i].Body,
						logRows[i].ServiceName,
						logRows[i].ServiceVersion,
						logRows[i].ServiceInstance,
						logRows[i].ScopeName,
						logRows[i].ScopeVersion,
						logRows[i].Attributes,
						logRows[i].ResourceAttributes,
					); err != nil {
						return processed, err
					}
				}
			} else {
				p.logger.Warn().Msg("Skipping malformed OTEL message")
			}
		}

		processed = append(processed, msg)
	}

	if err := batch.Send(); err != nil {
		return processed, err
	}

	return processed, nil
}

// processMetricsTable handles performance metrics table batch processing
func (p *Processor) processMetricsTable(ctx context.Context, table string, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	p.logger.Info().Str("table", table).Int("message_count", len(msgs)).Msg("Starting metrics table processing")

	query := fmt.Sprintf("INSERT INTO %s (timestamp, trace_id, span_id, service_name, span_name, span_kind, "+
		"duration_ms, duration_seconds, metric_type, http_method, http_route, http_status_code, "+
		"grpc_service, grpc_method, grpc_status_code, is_slow, component, level) "+
		"VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", table)

	batch, err := p.conn.PrepareBatch(ctx, query)
	if err != nil {
		p.logger.Error().Err(err).Str("query", query).Msg("Failed to prepare batch for metrics table")
		return nil, err
	}

	p.logger.Debug().Str("table", table).Msg("Prepared batch for metrics table")

	processed := make([]jetstream.Msg, 0, len(msgs))
	rowsProcessed := 0

	for _, msg := range msgs {
		// Handle OTEL metrics messages
		if strings.Contains(msg.Subject(), "otel") && strings.Contains(msg.Subject(), "metrics") {
			p.logger.Debug().Str("subject", msg.Subject()).Msg("Processing OTEL metrics message")

			metricsRows, ok := p.parseOTELMetrics(msg)
			if ok {
				p.logger.Debug().Int("metrics_rows_count", len(metricsRows)).Msg("Parsed OTEL metrics rows")

				for i := range metricsRows {
					if err = batch.Append(
						metricsRows[i].Timestamp,
						metricsRows[i].TraceID,
						metricsRows[i].SpanID,
						metricsRows[i].ServiceName,
						metricsRows[i].SpanName,
						metricsRows[i].SpanKind,
						metricsRows[i].DurationMs,
						metricsRows[i].DurationSeconds,
						metricsRows[i].MetricType,
						metricsRows[i].HTTPMethod,
						metricsRows[i].HTTPRoute,
						metricsRows[i].HTTPStatusCode,
						metricsRows[i].GRPCService,
						metricsRows[i].GRPCMethod,
						metricsRows[i].GRPCStatusCode,
						metricsRows[i].IsSlow,
						metricsRows[i].Component,
						metricsRows[i].Level,
					); err != nil {
						p.logger.Error().Err(err).Msg("Failed to append metrics row to batch")
						return processed, err
					}

					rowsProcessed++
				}
			} else {
				p.logger.Warn().Msg("Skipping malformed OTEL metrics message")
			}
		}

		processed = append(processed, msg)
	}

	p.logger.Info().Int("rows_processed", rowsProcessed).Str("table", table).Msg("Sending batch to database")

	err = batch.Send()
	if err != nil {
		p.logger.Error().Err(err).Str("table", table).Int("rows_processed", rowsProcessed).Msg("Failed to send batch to database")
		return processed, err
	}

	p.logger.Info().Int("rows_processed", rowsProcessed).Str("table", table).Msg("Successfully sent batch to database")

	return processed, nil
}

// processOTELTracesMessage processes a single OTEL traces message
func (p *Processor) processOTELTracesMessage(msg jetstream.Msg, batch interface{}) (tracesCount int, err error) {
	traceRows, ok := p.parseOTELTraces(msg)
	if !ok {
		p.logger.Warn().Msg("Skipping malformed OTEL trace message")
		return 0, nil
	}

	p.logger.Debug().
		Int("traces_rows_count", len(traceRows)).
		Msg("Parsed OTEL traces rows")

	rowsProcessed := 0

	// Append traces rows
	for i := range traceRows {
		if err := batch.(interface {
			Append(...interface{}) error
		}).Append(
			traceRows[i].Timestamp,
			traceRows[i].TraceID,
			traceRows[i].SpanID,
			traceRows[i].ParentSpanID,
			traceRows[i].Name,
			traceRows[i].Kind,
			traceRows[i].StartTimeUnixNano,
			traceRows[i].EndTimeUnixNano,
			traceRows[i].ServiceName,
			traceRows[i].ServiceVersion,
			traceRows[i].ServiceInstance,
			traceRows[i].ScopeName,
			traceRows[i].ScopeVersion,
			traceRows[i].StatusCode,
			traceRows[i].StatusMessage,
			traceRows[i].Attributes,
			traceRows[i].ResourceAttributes,
			traceRows[i].Events,
			traceRows[i].Links,
		); err != nil {
			p.logger.Error().Err(err).Msg("Failed to append traces row to batch")
			return rowsProcessed, err
		}

		rowsProcessed++
	}

	return rowsProcessed, nil
}

// processTracesTable handles traces table batch processing
func (p *Processor) processTracesTable(ctx context.Context, table string, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	p.logger.Info().Str("table", table).Int("message_count", len(msgs)).Msg("Starting traces table processing")

	// Prepare traces batch
	query := fmt.Sprintf("INSERT INTO %s (timestamp, trace_id, span_id, parent_span_id, name, kind, "+
		"start_time_unix_nano, end_time_unix_nano, service_name, service_version, service_instance, "+
		"scope_name, scope_version, status_code, status_message, attributes, resource_attributes, "+
		"events, links) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", table)

	batch, err := p.conn.PrepareBatch(ctx, query)
	if err != nil {
		p.logger.Error().Err(err).Str("query", query).Msg("Failed to prepare batch for traces table")
		return nil, err
	}

	p.logger.Debug().Str("table", table).Msg("Prepared batch for traces table")

	processed := make([]jetstream.Msg, 0, len(msgs))
	rowsProcessed := 0

	for _, msg := range msgs {
		if strings.Contains(msg.Subject(), "otel") {
			p.logger.Debug().Str("subject", msg.Subject()).Msg("Processing OTEL traces message")

			tracesCount, processErr := p.processOTELTracesMessage(msg, batch)
			if processErr != nil {
				return processed, processErr
			}

			rowsProcessed += tracesCount
		}

		processed = append(processed, msg)
	}

	p.logger.Info().
		Int("traces_rows_processed", rowsProcessed).
		Str("table", table).
		Msg("Sending batch to database")

	// Send traces batch
	if err = batch.(interface{ Send() error }).Send(); err != nil {
		p.logger.Error().Err(err).Str("table", table).Int("rows_processed", rowsProcessed).Msg("Failed to send traces batch to database")
		return processed, err
	}

	p.logger.Info().
		Int("traces_rows_processed", rowsProcessed).
		Str("table", table).
		Msg("Successfully sent traces batch to database")

	return processed, nil
}

// parseOTELMessage attempts to parse an OTEL message and returns log rows
// It returns the parsed log rows and a boolean indicating success
func (p *Processor) parseOTELMessage(msg jetstream.Msg) ([]LogRow, bool) {
	p.logger.Debug().
		Str("subject", msg.Subject()).
		Int("data_length", len(msg.Data())).
		Msg("Processing OTEL message")

	// First try to parse as direct protobuf
	logRows, err := parseOTELLogs(msg.Data(), msg.Subject())
	if err == nil {
		p.logger.Debug().
			Int("log_rows", len(logRows)).
			Msg("Successfully parsed log rows from OTEL message")

		return logRows, true
	}

	p.logger.Debug().Err(err).Msg("Failed to parse as direct protobuf")

	// Try to parse as CloudEvent wrapper
	data, ok := parseCloudEvent(msg.Data())
	if !ok {
		p.logger.Debug().Msg("Failed to parse as CloudEvent wrapper")
		return nil, false
	}

	p.logger.Debug().
		Int("data_length", len(data)).
		Msg("Trying to parse as CloudEvent wrapper")

	logRows, err = parseOTELLogs([]byte(data), msg.Subject())
	if err != nil {
		p.logger.Debug().Err(err).Msg("Failed to parse OTEL logs completely")
		return nil, false
	}

	p.logger.Debug().
		Int("log_rows", len(logRows)).
		Msg("Successfully parsed log rows from OTEL message")

	return logRows, true
}

// parsePerformanceMessage attempts to parse a performance analytics JSON message and returns metrics rows
// It returns the parsed metrics rows and a boolean indicating success
func (p *Processor) parsePerformanceMessage(msg jetstream.Msg) ([]MetricsRow, bool) {
	p.logger.Debug().
		Str("subject", msg.Subject()).
		Int("data_length", len(msg.Data())).
		Msg("Processing performance message")

	// Parse JSON array of performance metrics
	var performanceMetrics []struct {
		Timestamp       string  `json:"timestamp"`
		TraceID         string  `json:"trace_id"`
		SpanID          string  `json:"span_id"`
		ServiceName     string  `json:"service_name"`
		SpanName        string  `json:"span_name"`
		SpanKind        string  `json:"span_kind"`
		DurationMs      float64 `json:"duration_ms"`
		DurationSeconds float64 `json:"duration_seconds"`
		MetricType      string  `json:"metric_type"`
		HTTPMethod      *string `json:"http_method"`
		HTTPRoute       *string `json:"http_route"`
		HTTPStatusCode  *string `json:"http_status_code"`
		GRPCService     *string `json:"grpc_service"`
		GRPCMethod      *string `json:"grpc_method"`
		GRPCStatusCode  *string `json:"grpc_status_code"`
		IsSlow          bool    `json:"is_slow"`
		Component       string  `json:"component"`
		Level           string  `json:"level"`
	}

	if err := json.Unmarshal(msg.Data(), &performanceMetrics); err != nil {
		p.logger.Debug().Err(err).Msg("Failed to parse performance metrics JSON")
		return nil, false
	}

	// Convert to MetricsRow structs
	metricsRows := make([]MetricsRow, 0, len(performanceMetrics))

	for i := range performanceMetrics {
		metric := &performanceMetrics[i]
		// Parse timestamp
		timestamp, err := time.Parse(time.RFC3339, metric.Timestamp)
		if err != nil {
			p.logger.Warn().Err(err).Str("timestamp", metric.Timestamp).Msg("Failed to parse timestamp, using current time")

			timestamp = time.Now()
		}

		// Helper function to convert optional string pointers to strings
		getStringValue := func(s *string) string {
			if s == nil {
				return ""
			}

			return *s
		}

		// Note: Removed raw_data JSON generation to save storage space

		row := MetricsRow{
			Timestamp:       timestamp,
			TraceID:         metric.TraceID,
			SpanID:          metric.SpanID,
			ServiceName:     metric.ServiceName,
			SpanName:        metric.SpanName,
			SpanKind:        metric.SpanKind,
			DurationMs:      metric.DurationMs,
			DurationSeconds: metric.DurationSeconds,
			MetricType:      metric.MetricType,
			HTTPMethod:      getStringValue(metric.HTTPMethod),
			HTTPRoute:       getStringValue(metric.HTTPRoute),
			HTTPStatusCode:  getStringValue(metric.HTTPStatusCode),
			GRPCService:     getStringValue(metric.GRPCService),
			GRPCMethod:      getStringValue(metric.GRPCMethod),
			GRPCStatusCode:  getStringValue(metric.GRPCStatusCode),
			IsSlow:          metric.IsSlow,
			Component:       metric.Component,
			Level:           metric.Level,
			// RawData field removed to save storage space
		}

		metricsRows = append(metricsRows, row)
	}

	p.logger.Debug().
		Int("metrics_rows", len(metricsRows)).
		Msg("Successfully parsed performance metrics")

	return metricsRows, true
}

// isJSONFormat checks if the data starts with '[' indicating JSON array format
func (p *Processor) isJSONFormat(data []byte) bool {
	if len(data) > 0 {
		firstByte := data[0]
		p.logger.Debug().
			Uint8("first_byte", firstByte).
			Str("first_byte_char", string(firstByte)).
			Bool("is_json_array", firstByte == '[').
			Str("data_preview", string(data[:min(50, len(data))])).
			Msg("Checking data format")

		return firstByte == '['
	}

	return false
}

// parseOTELRequest is a generic function to parse OTEL protobuf requests
func (p *Processor) parseOTELRequest(msgData []byte, req proto.Message, requestType string) error {
	// First try to parse as direct protobuf
	err := proto.Unmarshal(msgData, req)
	if err == nil {
		return nil
	}

	p.logger.Debug().Err(err).Msg("Failed to parse as direct protobuf, trying CloudEvent wrapper")

	// Try to parse as CloudEvent wrapper
	data, ok := parseCloudEvent(msgData)
	if !ok {
		return ErrFailedToParseCloudEvent
	}

	// Try to unmarshal the extracted data
	if err := proto.Unmarshal([]byte(data), req); err != nil {
		return fmt.Errorf("failed to unmarshal OTEL %s from CloudEvent: %w", requestType, err)
	}

	return nil
}

// parseMetricsRequest attempts to unmarshal metrics request from message data
func (p *Processor) parseMetricsRequest(msgData []byte) (*metricsv1.ExportMetricsServiceRequest, error) {
	var req metricsv1.ExportMetricsServiceRequest

	err := p.parseOTELRequest(msgData, &req, "metrics")
	if err != nil {
		return nil, err
	}

	return &req, nil
}

// processResourceMetrics processes all metrics for a single resource
func (p *Processor) processResourceMetrics(resourceMetric *metricspbv1.ResourceMetrics) []MetricsRow {
	var rows []MetricsRow

	// Skip invalid resource metrics
	if resourceMetric.Resource == nil {
		return rows
	}

	// Get service info once per resource
	serviceName, serviceVersion, serviceInstance, resourceAttribs := processResourceAttributes(resourceMetric.Resource)
	// Note: serviceVersion, serviceInstance, resourceAttribs are extracted but not used in metrics processing
	_ = serviceVersion
	_ = serviceInstance
	_ = resourceAttribs

	// Process all scope metrics for this resource
	for _, scopeMetric := range resourceMetric.ScopeMetrics {
		// Process all metrics for this scope
		for _, metric := range scopeMetric.Metrics {
			// Create a base metrics row
			metricType := getMetricType(metric)
			p.logger.Debug().
				Str("metric_name", metric.Name).
				Str("metric_type", metricType).
				Msg("Processing metric")

			baseRow := MetricsRow{
				ServiceName: serviceName,
				SpanName:    metric.Name,
				MetricType:  metricType,
			}

			// Process all data points for this metric
			metricRows := processMetricDataPoints(metric, &baseRow)
			rows = append(rows, metricRows...)
		}
	}

	return rows
}

// processMetricDataPoints processes data points based on metric type
func processMetricDataPoints(metric *metricspbv1.Metric, baseRow *MetricsRow) []MetricsRow {
	var rows []MetricsRow

	// Helper function to process number data points
	processNumberDataPoint := func(point *metricspbv1.NumberDataPoint, _ string) MetricsRow {
		row := *baseRow
		row.Timestamp = time.Unix(0, safeUint64ToInt64(point.TimeUnixNano))
		row.DurationMs = getNumberValue(point)
		row.DurationSeconds = row.DurationMs / 1000.0

		// Extract attributes
		extractMetricAttributes(&row, point.Attributes)

		// Note: Removed raw_data JSON generation to save storage space

		return row
	}

	// Process based on metric type
	switch data := metric.Data.(type) {
	case *metricspbv1.Metric_Gauge:
		for _, point := range data.Gauge.DataPoints {
			row := processNumberDataPoint(point, "gauge")
			rows = append(rows, row)
		}
	case *metricspbv1.Metric_Sum:
		for _, point := range data.Sum.DataPoints {
			row := processNumberDataPoint(point, "sum")
			rows = append(rows, row)
		}
	case *metricspbv1.Metric_Histogram:
		for _, point := range data.Histogram.DataPoints {
			row := *baseRow
			row.Timestamp = time.Unix(0, safeUint64ToInt64(point.TimeUnixNano))

			if point.Sum != nil {
				row.DurationMs = *point.Sum
			}

			row.DurationSeconds = row.DurationMs / 1000.0

			// Extract attributes
			extractMetricAttributes(&row, point.Attributes)

			// Note: Removed raw_data JSON generation to save storage space

			rows = append(rows, row)
		}
	}

	return rows
}

// parseOTELMetrics attempts to parse an OTEL metrics message and returns metrics rows
// It returns the parsed metrics rows and a boolean indicating success
func (p *Processor) parseOTELMetrics(msg jetstream.Msg) ([]MetricsRow, bool) {
	msgData := msg.Data()
	p.logger.Debug().
		Str("subject", msg.Subject()).
		Int("data_length", len(msgData)).
		Msg("Processing OTEL metrics message")

	// Check if it's JSON format
	if p.isJSONFormat(msgData) {
		p.logger.Info().Msg("Detected JSON format, using parsePerformanceMessage")
		return p.parsePerformanceMessage(msg)
	}

	// Parse the metrics request
	req, err := p.parseMetricsRequest(msgData)
	if err != nil {
		p.logger.Warn().
			Err(err).
			Str("subject", msg.Subject()).
			Int("data_length", len(msgData)).
			Str("data_preview", string(msgData[:min(100, len(msgData))])).
			Msg("Failed to parse OTEL metrics message")

		return nil, false
	}

	// Pre-allocate result slice
	var rows []MetricsRow

	p.logger.Debug().
		Int("resource_metrics_count", len(req.ResourceMetrics)).
		Msg("Successfully parsed OTEL metrics request")

	// Process all metrics
	for _, resourceMetric := range req.ResourceMetrics {
		resourceRows := p.processResourceMetrics(resourceMetric)
		rows = append(rows, resourceRows...)
	}

	p.logger.Debug().
		Int("metrics_rows", len(rows)).
		Msg("Successfully parsed metrics rows from OTEL message")

	return rows, true
}

// getMetricType returns the type of metric as a string
func getMetricType(metric *metricspbv1.Metric) string {
	switch metric.Data.(type) {
	case *metricspbv1.Metric_Gauge:
		return "gauge"
	case *metricspbv1.Metric_Sum:
		return "sum"
	case *metricspbv1.Metric_Histogram:
		return "histogram"
	case *metricspbv1.Metric_ExponentialHistogram:
		return "exponential_histogram"
	case *metricspbv1.Metric_Summary:
		return "summary"
	default:
		return unknownString
	}
}

// getNumberValue extracts the numeric value from a data point
func getNumberValue(point *metricspbv1.NumberDataPoint) float64 {
	switch v := point.Value.(type) {
	case *metricspbv1.NumberDataPoint_AsDouble:
		return v.AsDouble
	case *metricspbv1.NumberDataPoint_AsInt:
		return float64(v.AsInt)
	default:
		return 0
	}
}

// extractMetricAttributes extracts relevant attributes from metric data points
func extractMetricAttributes(row *MetricsRow, attributes []*commonv1.KeyValue) {
	for _, attr := range attributes {
		value := extractAttributeValue(attr)

		switch attr.Key {
		case "http.method":
			row.HTTPMethod = value
		case "http.route":
			row.HTTPRoute = value
		case "http.status_code":
			row.HTTPStatusCode = value
		case "rpc.service", "grpc.service":
			row.GRPCService = value
		case "rpc.method", "grpc.method":
			row.GRPCMethod = value
		case "rpc.grpc.status_code", "grpc.status_code":
			row.GRPCStatusCode = value
		case "component":
			row.Component = value
		case "level":
			row.Level = value
		case "span.kind":
			row.SpanKind = value
		}
	}
}

// parseTracesRequest attempts to unmarshal traces request from message data
func (p *Processor) parseTracesRequest(msgData []byte) (*tracev1.ExportTraceServiceRequest, error) {
	var req tracev1.ExportTraceServiceRequest

	err := p.parseOTELRequest(msgData, &req, "traces")
	if err != nil {
		return nil, err
	}

	return &req, nil
}

// convertSpanTimestamp safely converts span timestamp to time.Time
func convertSpanTimestamp(startTimeUnixNano uint64) time.Time {
	if startTimeUnixNano <= uint64(maxInt64) {
		return time.Unix(0, int64(startTimeUnixNano))
	}

	// Handle overflow case
	seconds := startTimeUnixNano / 1000000000
	nanos := startTimeUnixNano % 1000000000

	var secInt64 int64
	if seconds > uint64(maxInt64) {
		secInt64 = maxInt64
	} else {
		secInt64 = int64(seconds)
	}

	return time.Unix(secInt64, safeUint64ToInt64(nanos))
}

// processSpanEvents converts span events to JSON string
func processSpanEvents(events []*tracepbv1.Span_Event) string {
	if len(events) == 0 {
		return "[]"
	}

	eventMaps := make([]map[string]interface{}, 0, len(events))

	for _, event := range events {
		eventMap := map[string]interface{}{
			"time_unix_nano": event.TimeUnixNano,
			"name":           event.Name,
			"attributes":     processLogAttributes(event.Attributes),
		}
		eventMaps = append(eventMaps, eventMap)
	}

	if eventBytes, err := json.Marshal(eventMaps); err == nil {
		return string(eventBytes)
	}

	return "[]"
}

// processSpanLinks converts span links to JSON string
func processSpanLinks(links []*tracepbv1.Span_Link) string {
	if len(links) == 0 {
		return "[]"
	}

	linkMaps := make([]map[string]interface{}, 0, len(links))

	for _, link := range links {
		linkMap := map[string]interface{}{
			"trace_id":   fmt.Sprintf("%x", link.TraceId),
			"span_id":    fmt.Sprintf("%x", link.SpanId),
			"attributes": processLogAttributes(link.Attributes),
		}
		linkMaps = append(linkMaps, linkMap)
	}

	if linkBytes, err := json.Marshal(linkMaps); err == nil {
		return string(linkBytes)
	}

	return "[]"
}

// processSpanSimple converts a single span to a TracesRow
func processSpanSimple(span *tracepbv1.Span, serviceName, serviceVersion, serviceInstance string,
	resourceAttribs []string, scopeName, scopeVersion string) TracesRow {
	// Convert timestamp
	timestamp := convertSpanTimestamp(span.StartTimeUnixNano)

	// Process span attributes
	spanAttribs := processLogAttributes(span.Attributes)

	// Process events and links
	eventsJSON := processSpanEvents(span.Events)
	linksJSON := processSpanLinks(span.Links)

	// Note: Removed raw_data JSON generation to save storage space
	// The raw protobuf data was consuming massive storage (65-160GB) with no benefit

	// Get status info
	statusCode := int32(0)
	statusMessage := ""

	if span.Status != nil {
		statusCode = int32(span.Status.Code)
		statusMessage = span.Status.Message
	}

	// Convert attributes to comma-separated strings
	spanAttribsStr := strings.Join(spanAttribs, ",")
	resourceAttribsStr := strings.Join(resourceAttribs, ",")

	// Create the trace row
	traceRow := TracesRow{
		Timestamp:          timestamp,
		TraceID:            fmt.Sprintf("%x", span.TraceId),
		SpanID:             fmt.Sprintf("%x", span.SpanId),
		ParentSpanID:       fmt.Sprintf("%x", span.ParentSpanId),
		Name:               span.Name,
		Kind:               int32(span.Kind),
		StartTimeUnixNano:  span.StartTimeUnixNano,
		EndTimeUnixNano:    span.EndTimeUnixNano,
		ServiceName:        serviceName,
		ServiceVersion:     serviceVersion,
		ServiceInstance:    serviceInstance,
		ScopeName:          scopeName,
		ScopeVersion:       scopeVersion,
		StatusCode:         statusCode,
		StatusMessage:      statusMessage,
		Attributes:         spanAttribsStr,
		ResourceAttributes: resourceAttribsStr,
		Events:             eventsJSON,
		Links:              linksJSON,
		// RawData field removed to save storage space
	}

	return traceRow
}

// processResourceSpans processes all spans for a single resource
func processResourceSpans(resourceSpan *tracepbv1.ResourceSpans) []TracesRow {
	var traceRows []TracesRow

	// Skip invalid resource spans
	if resourceSpan.Resource == nil {
		return traceRows
	}

	// Get service info once per resource
	serviceName, serviceVersion, serviceInstance, resourceAttribs :=
		processResourceAttributes(resourceSpan.Resource)

	// Process all scope spans for this resource
	for _, scopeSpan := range resourceSpan.ScopeSpans {
		// Get scope info once per scope
		scopeName, scopeVersion := getScopeInfo(scopeSpan.Scope)

		// Process all spans for this scope
		for _, span := range scopeSpan.Spans {
			traceRow := processSpanSimple(span, serviceName, serviceVersion, serviceInstance,
				resourceAttribs, scopeName, scopeVersion)
			traceRows = append(traceRows, traceRow)
		}
	}

	return traceRows
}

// parseOTELTraces attempts to parse an OTEL traces message and returns trace rows
// It returns the parsed trace rows and a boolean indicating success
func (p *Processor) parseOTELTraces(msg jetstream.Msg) ([]TracesRow, bool) {
	p.logger.Debug().
		Str("subject", msg.Subject()).
		Int("data_length", len(msg.Data())).
		Msg("Processing OTEL traces message")

	// Parse the traces request
	req, err := p.parseTracesRequest(msg.Data())
	if err != nil {
		p.logger.Debug().Err(err).Msg("Failed to parse OTEL traces message")
		return nil, false
	}

	// Pre-allocate result slice
	var traceRows []TracesRow

	// Process all traces
	for _, resourceSpan := range req.ResourceSpans {
		resourceTraceRows := processResourceSpans(resourceSpan)
		traceRows = append(traceRows, resourceTraceRows...)
	}

	p.logger.Debug().
		Int("trace_rows", len(traceRows)).
		Msg("Successfully parsed trace rows from OTEL message")

	return traceRows, true
}
