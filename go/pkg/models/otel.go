package models

import "time"

// Ingest attribution columns (refactor-otel-signal-correlation, 10.6).
//
// Every OTEL signal row carries the edge ingest attribution stamped upstream
// as NATS message headers: Sr-Ingest-Identity -> IngestIdentity,
// Sr-Agent-Id -> IngestAgentID, Sr-Partition -> IngestPartition. The columns
// are TEXT NOT NULL DEFAULT '' and an absent header stays "", so edge- and
// centrally-ingested signals are indistinguishable except for these fields.

// OTELLogRow represents a normalized log entry emitted by OTEL collectors.
type OTELLogRow struct {
	Timestamp          time.Time
	ObservedTimestamp  *time.Time
	TraceID            string
	SpanID             string
	TraceFlags         *int32
	SeverityText       string
	SeverityNumber     int32
	Body               string
	EventName          string
	Source             string
	ServiceName        string
	ServiceVersion     string
	ServiceInstance    string
	ScopeName          string
	ScopeVersion       string
	ScopeAttributes    string
	Attributes         string
	ResourceAttributes string
	IngestIdentity     string
	IngestAgentID      string
	IngestPartition    string
}

// OTELMetricRow captures a single OTEL performance metric sample.
type OTELMetricRow struct {
	Timestamp       time.Time
	TraceID         string
	SpanID          string
	ServiceName     string
	SpanName        string
	SpanKind        string
	DurationMs      float64
	DurationSeconds float64
	MetricType      string
	HTTPMethod      string
	HTTPRoute       string
	HTTPStatusCode  string
	GRPCService     string
	GRPCMethod      string
	GRPCStatusCode  string
	IsSlow          bool
	Component       string
	Level           string
	Unit            string // Unit of measurement (e.g., "ms", "s", "bytes", "1" for counts)
	IngestIdentity  string
	IngestAgentID   string
	IngestPartition string
}

// OTELMetricPointRow captures a real OTLP metric data point (sum, gauge, or
// histogram) destined for the otel_metric_points hypertable. Mirrors
// ServiceRadar.EventWriter.Processors.OtelMetrics metric-point rows: the
// primary key is (timestamp, metric_name, service_name, attributes_hash), so
// AttributesHash must follow hash recipe v2 — the lowercase-hex md5 of
// canonicalBytes(pointAttributes) + "\n" + serviceInstanceID + "\n" +
// scopeName — for cross-writer dedupe to work. Attributes remains the
// display JSON (keys sorted at every nesting level) and is no longer the
// hash input. StartTimeUnixNano is nil when the point carried no start time
// (NULL column); ScopeName and ServiceInstanceID default to "", matching
// the column defaults.
type OTELMetricPointRow struct {
	Timestamp         time.Time
	MetricName        string
	MetricType        string
	Unit              *string
	Temporality       *string
	IsMonotonic       *bool
	ServiceName       string
	ServiceInstanceID string
	ScopeName         string
	StartTimeUnixNano *int64
	Attributes        string
	AttributesHash    string
	Value             *float64
	Count             *int64
	Sum               *float64
	BucketCounts      *string
	ExplicitBounds    *string
	IngestIdentity    string
	IngestAgentID     string
	IngestPartition   string
}

// OTELTraceRow stores a single OTEL trace span row.
//
// TraceState and ScopeAttributes keep Go's "" zero value in the struct, but
// the CNPG INSERT stores "" as NULL (NULLIF): trace_state is NULL when the
// span carries no W3C tracestate, scope_attributes is NULL when the
// instrumentation scope has no attributes. ScopeAttributes is sorted-key JSON
// object text, the same encoding the Elixir writer uses for attribute
// columns. ServiceNamespace and DeploymentEnvironment default to "" matching
// their NOT NULL empty-string-default columns; the dropped counts default
// to 0.
type OTELTraceRow struct {
	Timestamp              time.Time
	TraceID                string
	SpanID                 string
	ParentSpanID           string
	Name                   string
	Kind                   int32
	StartTimeUnixNano      int64
	EndTimeUnixNano        int64
	ServiceName            string
	ServiceVersion         string
	ServiceInstance        string
	ServiceNamespace       string
	DeploymentEnvironment  string
	ScopeName              string
	ScopeVersion           string
	ScopeAttributes        string
	StatusCode             int32
	StatusMessage          string
	TraceState             string
	Attributes             string
	ResourceAttributes     string
	Events                 string
	Links                  string
	DroppedAttributesCount int32
	DroppedEventsCount     int32
	DroppedLinksCount      int32
	IngestIdentity         string
	IngestAgentID          string
	IngestPartition        string
}
