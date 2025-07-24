package dbeventwriter

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/timeplus-io/proton-go-driver/v2"
	v1 "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	commonv1 "go.opentelemetry.io/proto/otlp/common/v1"
	logsv1 "go.opentelemetry.io/proto/otlp/logs/v1"
	resourcev1 "go.opentelemetry.io/proto/otlp/resource/v1"
	"google.golang.org/protobuf/proto"
)

// Processor writes JetStream messages to Proton tables.
type Processor struct {
	conn    proton.Conn
	table   string              // Legacy single table
	streams []StreamConfig      // Multi-stream configuration
}


// LogRow represents a row in the logs table
type LogRow struct {
	Timestamp         time.Time `db:"timestamp"`
	TraceID           string    `db:"trace_id"`
	SpanID            string    `db:"span_id"`
	SeverityText      string    `db:"severity_text"`
	SeverityNumber    int32     `db:"severity_number"`
	Body              string    `db:"body"`
	ServiceName       string    `db:"service_name"`
	ServiceVersion    string    `db:"service_version"`
	ServiceInstance   string    `db:"service_instance"`
	ScopeName         string    `db:"scope_name"`
	ScopeVersion      string    `db:"scope_version"`
	Attributes        string    `db:"attributes"`
	ResourceAttributes string   `db:"resource_attributes"`
	RawData           string    `db:"raw_data"`
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
	if attr.Value.GetStringValue() != "" {
		return attr.Value.GetStringValue()
	} else if attr.Value.GetBoolValue() {
		return "true"
	} else if attr.Value.GetIntValue() != 0 {
		return fmt.Sprintf("%d", attr.Value.GetIntValue())
	} else if attr.Value.GetDoubleValue() != 0 {
		return fmt.Sprintf("%f", attr.Value.GetDoubleValue())
	}
	return ""
}

// processResourceAttributes processes resource attributes and extracts service information
func processResourceAttributes(resource *resourcev1.Resource) (string, string, string, []string) {
	var serviceName, serviceVersion, serviceInstance string
	var resourceAttribs []string
	
	if resource == nil {
		return "", "", "", nil
	}
	
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
	var logAttribs []string
	
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
	
	// Convert timestamp
	timestamp := time.Unix(0, int64(logRecord.TimeUnixNano))
	
	// Create raw data JSON
	rawDataMap := map[string]interface{}{
		"resource_logs": map[string]interface{}{
			"resource_attributes": resourceAttribs,
			"scope_logs": map[string]interface{}{
				"scope": map[string]interface{}{
					"name":    scopeName,
					"version": scopeVersion,
				},
				"log_record": map[string]interface{}{
					"timestamp":       logRecord.TimeUnixNano,
					"severity_text":   logRecord.SeverityText,
					"severity_number": logRecord.SeverityNumber,
					"body":            body,
					"attributes":      logAttribs,
					"trace_id":        fmt.Sprintf("%x", logRecord.TraceId),
					"span_id":         fmt.Sprintf("%x", logRecord.SpanId),
				},
			},
		},
	}
	
	// Marshal to JSON
	rawDataJson, _ := json.Marshal(rawDataMap)
	
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
		RawData:            string(rawDataJson),
	}
}

// getScopeInfo extracts scope name and version
func getScopeInfo(scope *commonv1.InstrumentationScope) (string, string) {
	if scope == nil {
		return "", ""
	}
	return scope.Name, scope.Version
}

// parseOTELLogs parses OTEL protobuf logs data and returns LogRow entries
func parseOTELLogs(b []byte, subject string) ([]LogRow, error) {
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
		dataBytes, err := json.Marshal(ce.Data)
		if err != nil {
			return row
		}

		// Try to handle as poller health event first
		if ce.Type == "com.carverauto.serviceradar.poller.health" || 
		   ce.Subject == "events.poller.health" {
			var pollerData models.PollerHealthEventData
			if err := json.Unmarshal(dataBytes, &pollerData); err == nil {
				row.Host = pollerData.Host
				row.RemoteAddr = pollerData.RemoteAddr
				row.ShortMessage = fmt.Sprintf("Poller %s state changed from %s to %s", 
					pollerData.PollerID, pollerData.PreviousState, pollerData.CurrentState)
				row.Level = getLogLevelForState(pollerData.CurrentState)
				row.Severity = getSeverityForState(pollerData.CurrentState)
				row.EventTimestamp = pollerData.Timestamp
				row.Version = "1.1"
				return row
			}
		}

		// Fall back to GELF format (for syslog and other events)
		var gelfPayload struct {
			RemoteAddr   string  `json:"_remote_addr"`
			Host         string  `json:"host"`
			Level        int32   `json:"level"`
			Severity     string  `json:"severity"`
			ShortMessage string  `json:"short_message"`
			Timestamp    float64 `json:"timestamp"`
			Version      string  `json:"version"`
		}

		if err := json.Unmarshal(dataBytes, &gelfPayload); err == nil {
			row.RemoteAddr = gelfPayload.RemoteAddr
			row.Host = gelfPayload.Host
			row.Level = gelfPayload.Level
			row.Severity = gelfPayload.Severity
			row.ShortMessage = gelfPayload.ShortMessage
			row.Version = gelfPayload.Version

			// Handle GELF timestamp if present and valid
			if gelfPayload.Timestamp > 0 {
				sec := int64(gelfPayload.Timestamp)
				nsec := int64((gelfPayload.Timestamp - float64(sec)) * float64(time.Second))
				ts := time.Unix(sec, nsec)

				// Validate timestamp is within ClickHouse DateTime64 range
				minTimestamp := time.Date(1925, 1, 1, 0, 0, 0, 0, time.UTC)
				maxTimestamp := time.Date(2283, 11, 11, 0, 0, 0, 0, time.UTC)

				if !ts.Before(minTimestamp) && !ts.After(maxTimestamp) {
					row.EventTimestamp = ts
				}
			}
		}
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
		return 3 // Error
	case "healthy":
		return 6 // Info
	case "unknown":
		return 5 // Notice
	default:
		return 6 // Info
	}
}

// getSeverityForState maps poller states to severity strings
func getSeverityForState(state string) string {
	switch state {
	case "unhealthy":
		return "error"
	case "healthy":
		return "info"
	case "unknown":
		return "notice"
	default:
		return "info"
	}
}

// NewProcessor creates a Processor using the provided db.Service.
func NewProcessor(dbService db.Service, table string) (*Processor, error) {
	dbImpl, ok := dbService.(*db.DB)
	if !ok {
		return nil, errDBServiceNotDB
	}

	return &Processor{conn: dbImpl.Conn, table: table}, nil
}

// NewProcessorWithStreams creates a Processor with multi-stream configuration.
func NewProcessorWithStreams(dbService db.Service, streams []StreamConfig) (*Processor, error) {
	dbImpl, ok := dbService.(*db.DB)
	if !ok {
		return nil, errDBServiceNotDB
	}

	return &Processor{conn: dbImpl.Conn, streams: streams}, nil
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
	if len(msgs) == 0 {
		return nil, nil
	}

	// Group messages by table
	messagesByTable := make(map[string][]jetstream.Msg)
	for _, msg := range msgs {
		table := p.getTableForSubject(msg.Subject())
		messagesByTable[table] = append(messagesByTable[table], msg)
	}

	processed := make([]jetstream.Msg, 0, len(msgs))

	// Process each table separately
	for table, tableMsgs := range messagesByTable {
		if strings.Contains(table, "logs") {
			// Handle OTEL logs table
			processedMsgs, err := p.processLogsTable(ctx, table, tableMsgs)
			if err != nil {
				return processed, err
			}
			processed = append(processed, processedMsgs...)
		} else {
			// Handle events table
			processedMsgs, err := p.processEventsTable(ctx, table, tableMsgs)
			if err != nil {
				return processed, err
			}
			processed = append(processed, processedMsgs...)
		}
	}

	return processed, nil
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
		"attributes, resource_attributes, raw_data) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", table)

	batch, err := p.conn.PrepareBatch(ctx, query)
	if err != nil {
		return nil, err
	}

	processed := make([]jetstream.Msg, 0, len(msgs))

	for _, msg := range msgs {
		// Handle OTEL logs
		if strings.Contains(msg.Subject(), "otel") {
			if logRows, ok := parseOTELMessage(msg); ok {
				for _, row := range logRows {
					if err := batch.Append(
						row.Timestamp,
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
						row.RawData,
					); err != nil {
						return processed, err
					}
				}
			} else {
				log.Printf("Skipping malformed OTEL message")
			}
		}

		processed = append(processed, msg)
	}

	if err := batch.Send(); err != nil {
		return processed, err
	}

	return processed, nil
}

// parseOTELMessage attempts to parse an OTEL message and returns log rows
// It returns the parsed log rows and a boolean indicating success
func parseOTELMessage(msg jetstream.Msg) ([]LogRow, bool) {
	log.Printf("Processing OTEL message from subject: %s, data length: %d", msg.Subject(), len(msg.Data()))
	
	// First try to parse as direct protobuf
	logRows, err := parseOTELLogs(msg.Data(), msg.Subject())
	if err == nil {
		log.Printf("Successfully parsed %d log rows from OTEL message", len(logRows))
		return logRows, true
	}
	
	log.Printf("Failed to parse as direct protobuf: %v", err)
	
	// Try to parse as CloudEvent wrapper
	data, ok := parseCloudEvent(msg.Data())
	if !ok {
		log.Printf("Failed to parse as CloudEvent wrapper")
		return nil, false
	}
	
	log.Printf("Trying to parse as CloudEvent wrapper, data length: %d", len(data))
	logRows, err = parseOTELLogs([]byte(data), msg.Subject())
	if err != nil {
		log.Printf("Failed to parse OTEL logs completely: %v", err)
		return nil, false
	}
	
	log.Printf("Successfully parsed %d log rows from OTEL message", len(logRows))
	return logRows, true
}