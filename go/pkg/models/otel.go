package models

import "time"

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
}

// OTELTraceRow stores a single OTEL trace span row.
type OTELTraceRow struct {
	Timestamp          time.Time
	TraceID            string
	SpanID             string
	ParentSpanID       string
	Name               string
	Kind               int32
	StartTimeUnixNano  int64
	EndTimeUnixNano    int64
	ServiceName        string
	ServiceVersion     string
	ServiceInstance    string
	ScopeName          string
	ScopeVersion       string
	StatusCode         int32
	StatusMessage      string
	Attributes         string
	ResourceAttributes string
	Events             string
	Links              string
}
