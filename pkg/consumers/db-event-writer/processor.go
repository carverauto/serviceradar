package dbeventwriter

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/nats-io/nats.go/jetstream"
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
)

// safeUint64ToInt64 safely converts uint64 to int64, capping at maxInt64 if needed
func safeUint64ToInt64(u uint64) int64 {
	if u > uint64(maxInt64) {
		return maxInt64
	}

	return int64(u)
}

// Processor writes JetStream messages to CNPG observability tables.
type Processor struct {
	db      *db.DB
	table   string         // Legacy single table
	streams []StreamConfig // Multi-stream configuration
	logger  logger.Logger
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
	scopeName, scopeVersion, scopeAttributes string,
	resourceAttribs []string,
	logAttribs []string,
) models.OTELLogRow {
	// Extract body text
	body := ""
	if logRecord.Body != nil && logRecord.Body.GetStringValue() != "" {
		body = logRecord.Body.GetStringValue()
	}

	timestamp := safeTimeFromUnixNano(logRecord.TimeUnixNano)
	observedTimestamp := safeTimeFromUnixNanoPtr(logRecord.ObservedTimeUnixNano)
	traceFlags := traceFlagsFromRecord(logRecord.Flags)

	// Note: Removed raw_data JSON generation to save storage space
	// The raw protobuf data was consuming massive storage with no benefit

	return models.OTELLogRow{
		Timestamp:          timestamp,
		ObservedTimestamp:  observedTimestamp,
		TraceID:            fmt.Sprintf("%x", logRecord.TraceId),
		SpanID:             fmt.Sprintf("%x", logRecord.SpanId),
		TraceFlags:         traceFlags,
		SeverityText:       logRecord.SeverityText,
		SeverityNumber:     int32(logRecord.SeverityNumber),
		Body:               body,
		EventName:          logRecord.EventName,
		ServiceName:        serviceName,
		ServiceVersion:     serviceVersion,
		ServiceInstance:    serviceInstance,
		ScopeName:          scopeName,
		ScopeVersion:       scopeVersion,
		ScopeAttributes:    scopeAttributes,
		Attributes:         strings.Join(logAttribs, ","),
		ResourceAttributes: strings.Join(resourceAttribs, ","),
		// RawData field removed to save storage space
	}
}

// getScopeInfo extracts scope name and version
func getScopeInfo(scope *commonv1.InstrumentationScope) (name, version, attributes string) {
	if scope == nil {
		return "", "", ""
	}

	scopeAttributes := processLogAttributes(scope.Attributes)

	return scope.Name, scope.Version, strings.Join(scopeAttributes, ",")
}

func safeTimeFromUnixNano(value uint64) time.Time {
	if value == 0 {
		return time.Now().UTC()
	}

	if value <= uint64(maxInt64) {
		return time.Unix(0, int64(value))
	}

	seconds := value / 1000000000
	nanos := value % 1000000000

	var secInt64 int64
	if seconds > uint64(maxInt64) {
		secInt64 = maxInt64
	} else {
		secInt64 = int64(seconds)
	}

	return time.Unix(secInt64, int64(nanos))
}

func safeTimeFromUnixNanoPtr(value uint64) *time.Time {
	if value == 0 {
		return nil
	}

	parsed := safeTimeFromUnixNano(value)
	return &parsed
}

func traceFlagsFromRecord(flags uint32) *int32 {
	if flags == 0 {
		return nil
	}

	// Mask to W3C trace flags (lowest 8 bits).
	traceFlags := int32(flags & 0xFF)
	return &traceFlags
}

// parseOTELLogs parses OTEL protobuf logs data and returns LogRow entries
func parseOTELLogs(b []byte, _ string) ([]models.OTELLogRow, error) {
	// Unmarshal the protobuf data
	var req v1.ExportLogsServiceRequest

	if err := proto.Unmarshal(b, &req); err != nil {
		return nil, fmt.Errorf("failed to unmarshal OTEL logs: %w", err)
	}

	// Pre-allocate result slice
	var rows []models.OTELLogRow

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
			scopeName, scopeVersion, scopeAttributes := getScopeInfo(scopeLog.Scope)

			// Process all log records for this scope
			for _, logRecord := range scopeLog.LogRecords {
				// Get log attributes
				logAttribs := processLogAttributes(logRecord.Attributes)

				// Build and add the log row
				row := createLogRow(
					logRecord,
					serviceName, serviceVersion, serviceInstance,
					scopeName, scopeVersion, scopeAttributes,
					resourceAttribs,
					logAttribs,
				)

				rows = append(rows, row)
			}
		}
	}

	return rows, nil
}

// NewProcessor creates a Processor using the provided db.Service.
func NewProcessor(dbService db.Service, table string, log logger.Logger) (*Processor, error) {
	dbImpl, ok := dbService.(*db.DB)
	if !ok {
		return nil, errDBServiceNotDB
	}

	return &Processor{db: dbImpl, table: table, logger: log}, nil
}

// NewProcessorWithStreams creates a Processor with multi-stream configuration.
func NewProcessorWithStreams(dbService db.Service, streams []StreamConfig, log logger.Logger) (*Processor, error) {
	dbImpl, ok := dbService.(*db.DB)
	if !ok {
		return nil, errDBServiceNotDB
	}

	return &Processor{db: dbImpl, streams: streams, logger: log}, nil
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
	case strings.Contains(table, "ocsf_events"):
		p.logger.Debug().Str("table", table).Msg("Processing as OCSF events table")
		return p.processOCSFEventsTable(ctx, table, tableMsgs)
	case table == "ocsf_network_activity" || strings.Contains(table, "ocsf_network_activity"):
		p.logger.Debug().Str("table", table).Msg("Processing as OCSF network activity table")
		return p.processOCSFNetworkActivityTable(ctx, tableMsgs)
	default:
		return nil, fmt.Errorf("%w: %s", errUnsupportedTable, table)
	}
}

// processOCSFEventsTable handles OCSF events table batch processing.
func (p *Processor) processOCSFEventsTable(ctx context.Context, table string, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	if len(msgs) == 0 {
		return nil, nil
	}

	if p.db == nil {
		return nil, errCNPGEventsNotConfigured
	}

	processed := make([]jetstream.Msg, 0, len(msgs))
	eventRows := make([]models.OCSFEventRow, 0, len(msgs))

	for _, msg := range msgs {
		processed = append(processed, msg)
		row, err := parseOCSFEvent(msg.Data())
		if err != nil {
			p.logger.Warn().
				Err(err).
				Str("subject", msg.Subject()).
				Msg("Skipping malformed OCSF event payload")
			continue
		}

		eventRows = append(eventRows, *row)
	}

	if len(eventRows) == 0 {
		return processed, nil
	}

	if err := p.db.InsertOCSFEvents(ctx, table, eventRows); err != nil {
		return processed, err
	}

	p.logger.Info().
		Int("rows_processed", len(eventRows)).
		Str("table", table).
		Msg("Inserted OCSF events into CNPG")

	return processed, nil
}

func processOTELTable[T any](
	ctx context.Context,
	log logger.Logger,
	table string,
	msgs []jetstream.Msg,
	parse func(jetstream.Msg) ([]T, bool),
	insert func(context.Context, string, []T) error,
	warnMsg, successMsg string,
) ([]jetstream.Msg, error) {
	if len(msgs) == 0 {
		return nil, nil
	}

	processed := make([]jetstream.Msg, 0, len(msgs))
	rows := make([]T, 0, len(msgs))

	for _, msg := range msgs {
		processed = append(processed, msg)

		if !strings.Contains(msg.Subject(), "otel") {
			continue
		}

		parsedRows, ok := parse(msg)
		if !ok {
			log.Warn().Msg(warnMsg)
			continue
		}

		rows = append(rows, parsedRows...)
	}

	if len(rows) == 0 {
		return processed, nil
	}

	if err := insert(ctx, table, rows); err != nil {
		return processed, err
	}

	log.Info().
		Int("rows_processed", len(rows)).
		Str("table", table).
		Msg(successMsg)

	return processed, nil
}

// processLogsTable handles logs table batch processing
func (p *Processor) processLogsTable(ctx context.Context, table string, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	return processOTELTable(
		ctx,
		p.logger,
		table,
		msgs,
		p.parseOTELMessage,
		p.db.InsertOTELLogs,
		"Skipping malformed OTEL log message",
		"Inserted OTEL logs into CNPG",
	)
}

// processMetricsTable handles performance metrics table batch processing
func (p *Processor) processMetricsTable(ctx context.Context, table string, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	if len(msgs) == 0 {
		return nil, nil
	}

	processed := make([]jetstream.Msg, 0, len(msgs))
	metricRows := make([]models.OTELMetricRow, 0, len(msgs))

	for _, msg := range msgs {
		processed = append(processed, msg)

		var (
			rows []models.OTELMetricRow
			ok   bool
		)

		switch {
		case strings.Contains(msg.Subject(), "otel") && strings.Contains(msg.Subject(), "metrics"):
			rows, ok = p.parseOTELMetrics(msg)
			if !ok {
				p.logger.Warn().Msg("Skipping malformed OTEL metrics message")
				continue
			}
		case p.isJSONFormat(msg.Data()):
			rows, ok = p.parsePerformanceMessage(msg)
			if !ok {
				p.logger.Warn().Msg("Skipping malformed performance metrics JSON message")
				continue
			}
		default:
			continue
		}

		metricRows = append(metricRows, rows...)
	}

	if len(metricRows) == 0 {
		return processed, nil
	}

	if err := p.db.InsertOTELMetrics(ctx, table, metricRows); err != nil {
		return processed, err
	}

	p.logger.Info().
		Int("rows_processed", len(metricRows)).
		Str("table", table).
		Msg("Inserted OTEL metrics into CNPG")

	return processed, nil
}

// processTracesTable handles traces table batch processing
func (p *Processor) processTracesTable(ctx context.Context, table string, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	return processOTELTable(
		ctx,
		p.logger,
		table,
		msgs,
		p.parseOTELTraces,
		p.db.InsertOTELTraces,
		"Skipping malformed OTEL trace message",
		"Inserted OTEL traces into CNPG",
	)
}

// parseOTELMessage attempts to parse an OTEL message and returns log rows
// It returns the parsed log rows and a boolean indicating success
func (p *Processor) parseOTELMessage(msg jetstream.Msg) ([]models.OTELLogRow, bool) {
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

	logRows, ok := parseJSONLogs(msg.Data(), msg.Subject())
	if !ok {
		p.logger.Debug().Msg("Failed to parse as JSON log payload")
		return nil, false
	}

	p.logger.Debug().
		Int("log_rows", len(logRows)).
		Msg("Successfully parsed log rows from JSON payload")

	return logRows, true
}

// parsePerformanceMessage attempts to parse a performance analytics JSON message and returns metrics rows
// It returns the parsed metrics rows and a boolean indicating success
func (p *Processor) parsePerformanceMessage(msg jetstream.Msg) ([]models.OTELMetricRow, bool) {
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

	// Convert to OTELMetricRow structs
	metricsRows := make([]models.OTELMetricRow, 0, len(performanceMetrics))

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

		row := models.OTELMetricRow{
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
	if err := proto.Unmarshal(msgData, req); err != nil {
		return fmt.Errorf("failed to unmarshal OTEL %s: %w", requestType, err)
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
func (p *Processor) processResourceMetrics(resourceMetric *metricspbv1.ResourceMetrics) []models.OTELMetricRow {
	var rows []models.OTELMetricRow

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

			baseRow := models.OTELMetricRow{
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
func processMetricDataPoints(metric *metricspbv1.Metric, baseRow *models.OTELMetricRow) []models.OTELMetricRow {
	var rows []models.OTELMetricRow

	// Helper function to process number data points
	processNumberDataPoint := func(point *metricspbv1.NumberDataPoint, _ string) models.OTELMetricRow {
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
func (p *Processor) parseOTELMetrics(msg jetstream.Msg) ([]models.OTELMetricRow, bool) {
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
	var rows []models.OTELMetricRow

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
func extractMetricAttributes(row *models.OTELMetricRow, attributes []*commonv1.KeyValue) {
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

// processSpanSimple converts a single span to an OTELTraceRow
func processSpanSimple(span *tracepbv1.Span, serviceName, serviceVersion, serviceInstance string,
	resourceAttribs []string, scopeName, scopeVersion string) models.OTELTraceRow {
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
	traceRow := models.OTELTraceRow{
		Timestamp:          timestamp,
		TraceID:            fmt.Sprintf("%x", span.TraceId),
		SpanID:             fmt.Sprintf("%x", span.SpanId),
		ParentSpanID:       fmt.Sprintf("%x", span.ParentSpanId),
		Name:               span.Name,
		Kind:               int32(span.Kind),
		StartTimeUnixNano:  safeUint64ToInt64(span.StartTimeUnixNano),
		EndTimeUnixNano:    safeUint64ToInt64(span.EndTimeUnixNano),
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
func processResourceSpans(resourceSpan *tracepbv1.ResourceSpans) []models.OTELTraceRow {
	var traceRows []models.OTELTraceRow

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
		scopeName, scopeVersion, _ := getScopeInfo(scopeSpan.Scope)

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
func (p *Processor) parseOTELTraces(msg jetstream.Msg) ([]models.OTELTraceRow, bool) {
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
	var traceRows []models.OTELTraceRow

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
// processOCSFNetworkActivityTable processes OCSF network_activity events
func (p *Processor) processOCSFNetworkActivityTable(ctx context.Context, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	if len(msgs) == 0 {
		return nil, nil
	}

	if p.db == nil {
		return nil, errCNPGOCSFNotConfigured
	}

	var rows []models.OCSFNetworkActivity
	var processed []jetstream.Msg

	for _, msg := range msgs {
		data := msg.Data()

		// Try to extract data from CloudEvents envelope using json.RawMessage
		// to avoid an unnecessary marshal/unmarshal round-trip.
		eventData := data
		if extracted, ok := parseCloudEvent(data); ok {
			eventData = []byte(extracted)
		}

		// Parse OCSF JSON
		var ocsfEvent map[string]interface{}
		if err := json.Unmarshal(eventData, &ocsfEvent); err != nil {
			p.logger.Error().Err(err).Msg("Failed to parse OCSF JSON")
			continue
		}

		// Extract timestamp (milliseconds since epoch)
		timeMs, ok := ocsfEvent["time"].(float64)
		if !ok {
			p.logger.Error().Msg("Missing or invalid 'time' field in OCSF event")
			continue
		}
		timestamp := time.Unix(0, int64(timeMs)*1000000)

		// Build row
		row := models.OCSFNetworkActivity{
			Time:         timestamp,
			ClassUID:     int(getFloat64(ocsfEvent, "class_uid", 4001)),
			CategoryUID:  int(getFloat64(ocsfEvent, "category_uid", 4)),
			ActivityID:   int(getFloat64(ocsfEvent, "activity_id", 6)),
			TypeUID:      int(getFloat64(ocsfEvent, "type_uid", 400106)),
			SeverityID:   int(getFloat64(ocsfEvent, "severity_id", 1)),
			OCSFPayload:  eventData,
			Partition:    "default",
			CreatedAt:    time.Now(),
		}

		// Extract timestamps
		if startTime := getFloat64(ocsfEvent, "start_time", 0); startTime > 0 {
			t := time.Unix(0, int64(startTime)*1000000)
			row.StartTime = &t
		}
		if endTime := getFloat64(ocsfEvent, "end_time", 0); endTime > 0 {
			t := time.Unix(0, int64(endTime)*1000000)
			row.EndTime = &t
		}

		// Extract src_endpoint
		if srcEndpoint, ok := ocsfEvent["src_endpoint"].(map[string]interface{}); ok {
			if ip, ok := srcEndpoint["ip"].(string); ok {
				row.SrcEndpointIP = ip
			}
			if port, ok := srcEndpoint["port"].(float64); ok {
				p := int(port)
				row.SrcEndpointPort = &p
			}
			if as, ok := extractNestedFloat64(srcEndpoint, "autonomous_system", "number"); ok {
				asNum := int(as)
				row.SrcASNumber = &asNum
			}
		}

		// Extract dst_endpoint
		if dstEndpoint, ok := ocsfEvent["dst_endpoint"].(map[string]interface{}); ok {
			if ip, ok := dstEndpoint["ip"].(string); ok {
				row.DstEndpointIP = ip
			}
			if port, ok := dstEndpoint["port"].(float64); ok {
				p := int(port)
				row.DstEndpointPort = &p
			}
			if as, ok := extractNestedFloat64(dstEndpoint, "autonomous_system", "number"); ok {
				asNum := int(as)
				row.DstASNumber = &asNum
			}
		}

		// Extract connection_info
		if connInfo, ok := ocsfEvent["connection_info"].(map[string]interface{}); ok {
			if protoNum, ok := connInfo["protocol_num"].(float64); ok {
				p := int(protoNum)
				row.ProtocolNum = &p
			}
			if protoName, ok := connInfo["protocol_name"].(string); ok {
				row.ProtocolName = protoName
			}
			if tcpFlags, ok := connInfo["tcp_flags"].(float64); ok {
				f := int(tcpFlags)
				row.TCPFlags = &f
			}
		}

		// Extract traffic
		if traffic, ok := ocsfEvent["traffic"].(map[string]interface{}); ok {
			row.BytesTotal = int64(getFloat64(traffic, "bytes", 0))
			row.PacketsTotal = int64(getFloat64(traffic, "packets", 0))
			row.BytesIn = int64(getFloat64(traffic, "bytes_in", 0))
			row.BytesOut = int64(getFloat64(traffic, "bytes_out", 0))
		}

		// Extract sampler address from observables
		if observables, ok := ocsfEvent["observables"].([]interface{}); ok && len(observables) > 0 {
			if obs, ok := observables[0].(map[string]interface{}); ok {
				if value, ok := obs["value"].(string); ok {
					row.SamplerAddress = value
				}
			}
		}

		rows = append(rows, row)
		processed = append(processed, msg)
	}

	if len(rows) == 0 {
		return nil, nil
	}

	// Batch insert
	if err := p.insertOCSFNetworkActivityBatch(ctx, rows); err != nil {
		return nil, fmt.Errorf("failed to insert OCSF network activity batch: %w", err)
	}

	p.logger.Info().Int("count", len(rows)).Msg("Inserted OCSF network activity events")
	return processed, nil
}

// insertOCSFNetworkActivityBatch performs batch insert of OCSF network activity rows
func (p *Processor) insertOCSFNetworkActivityBatch(ctx context.Context, rows []models.OCSFNetworkActivity) error {
	if len(rows) == 0 {
		return nil
	}

	batch := &pgx.Batch{}
	query := `
		INSERT INTO ocsf_network_activity (
			time, class_uid, category_uid, activity_id, type_uid, severity_id,
			start_time, end_time,
			src_endpoint_ip, src_endpoint_port, src_as_number,
			dst_endpoint_ip, dst_endpoint_port, dst_as_number,
			protocol_num, protocol_name, tcp_flags,
			bytes_total, packets_total, bytes_in, bytes_out,
			sampler_address, ocsf_payload, partition, created_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25
		)
	`

	for _, row := range rows {
		batch.Queue(query,
			row.Time, row.ClassUID, row.CategoryUID, row.ActivityID, row.TypeUID, row.SeverityID,
			row.StartTime, row.EndTime,
			row.SrcEndpointIP, row.SrcEndpointPort, row.SrcASNumber,
			row.DstEndpointIP, row.DstEndpointPort, row.DstASNumber,
			row.ProtocolNum, row.ProtocolName, row.TCPFlags,
			row.BytesTotal, row.PacketsTotal, row.BytesIn, row.BytesOut,
			row.SamplerAddress, row.OCSFPayload, row.Partition, row.CreatedAt,
		)
	}

	br := p.db.SendBatch(ctx, batch)
	defer br.Close()

	for i := 0; i < batch.Len(); i++ {
		if _, err := br.Exec(); err != nil {
			return fmt.Errorf("failed to execute batch item %d: %w", i, err)
		}
	}

	return nil
}

// Helper functions for OCSF event parsing
func getFloat64(m map[string]interface{}, key string, defaultVal float64) float64 {
	if v, ok := m[key].(float64); ok {
		return v
	}
	return defaultVal
}

func extractNestedFloat64(m map[string]interface{}, key1, key2 string) (float64, bool) {
	if nested, ok := m[key1].(map[string]interface{}); ok {
		if val, ok := nested[key2].(float64); ok {
			return val, true
		}
	}
	return 0, false
}
