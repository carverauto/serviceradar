package models

import "time"

// LogSummary provides a compact view of high-severity log entries that are surfaced on dashboards.
type LogSummary struct {
	Timestamp   time.Time `json:"timestamp"`
	Severity    string    `json:"severity"`
	ServiceName string    `json:"service_name,omitempty"`
	Body        string    `json:"body,omitempty"`
	TraceID     string    `json:"trace_id,omitempty"`
	SpanID      string    `json:"span_id,omitempty"`
}

// SeverityWindowCounts captures per-severity totals for a specific rolling window.
type SeverityWindowCounts struct {
	Total   int `json:"total"`
	Fatal   int `json:"fatal"`
	Error   int `json:"error"`
	Warning int `json:"warning"`
	Info    int `json:"info"`
	Debug   int `json:"debug"`
	Other   int `json:"other"`
}

// LogCounters tracks rolling window statistics for recent high-severity logs.
type LogCounters struct {
	UpdatedAt time.Time            `json:"updated_at"`
	Window1H  SeverityWindowCounts `json:"window_1h"`
	Window24H SeverityWindowCounts `json:"window_24h"`
}

// LogDigestSnapshot represents a pre-computed digest of critical logs and counters.
type LogDigestSnapshot struct {
	Entries  []LogSummary `json:"entries"`
	Counters LogCounters  `json:"counters"`
}
