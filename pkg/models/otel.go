package models

import "time"

// OTELLogRow represents a normalized log entry emitted by OTEL collectors.
type OTELLogRow struct {
	Timestamp          time.Time
	TraceID            string
	SpanID             string
	SeverityText       string
	SeverityNumber     int32
	Body               string
	ServiceName        string
	ServiceVersion     string
	ServiceInstance    string
	ScopeName          string
	ScopeVersion       string
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
