package models

import (
	"encoding/json"
	"time"
)

// OCSFEventRow represents a row in the ocsf_events table.
type OCSFEventRow struct {
	ID           string
	Time         time.Time
	ClassUID     int32
	CategoryUID  int32
	TypeUID      int32
	ActivityID   int32
	ActivityName string
	SeverityID   int32
	Severity     string
	Message      string
	StatusID     *int32
	Status       string
	StatusCode   string
	StatusDetail string
	Metadata     json.RawMessage
	Observables  json.RawMessage
	TraceID      string
	SpanID       string
	Actor        json.RawMessage
	Device       json.RawMessage
	SrcEndpoint  json.RawMessage
	DstEndpoint  json.RawMessage
	LogName      string
	LogProvider  string
	LogLevel     string
	LogVersion   string
	Unmapped     json.RawMessage
	RawData      string
	TenantID     string
	CreatedAt    time.Time
}
