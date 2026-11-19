package sdk

import (
	"encoding/json"
	"fmt"
	"sync/atomic"
	"time"
)

// Status represents a plugin execution status.
type Status string

const (
	StatusOK       Status = "OK"
	StatusWarning  Status = "WARNING"
	StatusCritical Status = "CRITICAL"
	StatusUnknown  Status = "UNKNOWN"
)

// Severity represents event severity.
type Severity string

const (
	SeverityInfo     Severity = "INFO"
	SeverityWarning  Severity = "WARNING"
	SeverityCritical Severity = "CRITICAL"
	SeverityError    Severity = "ERROR"
)

// Result is the serviceradar.plugin_result.v1 payload.
type Result struct {
	Status             Status              `json:"status"`
	Summary            string              `json:"summary"`
	Details            string              `json:"details,omitempty"`
	Perfdata           string              `json:"perfdata,omitempty"`
	Labels             map[string]string   `json:"labels,omitempty"`
	ObservedAt         string              `json:"observed_at,omitempty"`
	SchemaVersion      int                 `json:"schema_version,omitempty"`
	Display            []DisplayWidget     `json:"display,omitempty"`
	Events             []OCSFEvent         `json:"events,omitempty"`
	DeviceDiscovery    []DeviceDiscovery   `json:"device_discovery,omitempty"`
	AdvisoryFeeds      []AdvisoryFeedBatch `json:"advisory_feeds,omitempty"`
	AlertHint          bool                `json:"alert_hint,omitempty"`
	ConditionID        string              `json:"condition_id,omitempty"`
	CheckInstanceID    string              `json:"check_instance_id,omitempty"`
	MonitoredServiceID string              `json:"monitored_service_id,omitempty"`
	DeviceUID          string              `json:"device_uid,omitempty"`
}

// ThresholdSpec defines warning/critical thresholds and bounds.
type ThresholdSpec struct {
	Warn *float64
	Crit *float64
	Min  *float64
	Max  *float64
}

// Thresholds returns a ThresholdSpec pointer with warn/crit set when > 0.
func Thresholds(warn, crit float64) *ThresholdSpec {
	t := &ThresholdSpec{}
	if warn > 0 {
		t.Warn = &warn
	}
	if crit > 0 {
		t.Crit = &crit
	}
	return t
}

// DisplayWidget describes UI rendering hints.
type DisplayWidget struct {
	Widget string         `json:"widget"`
	Label  string         `json:"label,omitempty"`
	Value  string         `json:"value,omitempty"`
	Tone   string         `json:"tone,omitempty"`
	Layout string         `json:"layout,omitempty"`
	Data   map[string]any `json:"data,omitempty"`
}

// OCSFEvent represents an OCSF Event Log Activity payload.
type OCSFEvent struct {
	ID           string           `json:"id"`
	Time         time.Time        `json:"time"`
	ClassUID     int              `json:"class_uid"`
	CategoryUID  int              `json:"category_uid"`
	TypeUID      int              `json:"type_uid"`
	ActivityID   int              `json:"activity_id"`
	ActivityName string           `json:"activity_name,omitempty"`
	SeverityID   int              `json:"severity_id"`
	Severity     string           `json:"severity,omitempty"`
	Message      string           `json:"message,omitempty"`
	StatusID     *int             `json:"status_id,omitempty"`
	Status       string           `json:"status,omitempty"`
	StatusCode   string           `json:"status_code,omitempty"`
	StatusDetail string           `json:"status_detail,omitempty"`
	Metadata     map[string]any   `json:"metadata,omitempty"`
	Observables  []map[string]any `json:"observables,omitempty"`
	TraceID      string           `json:"trace_id,omitempty"`
	SpanID       string           `json:"span_id,omitempty"`
	Actor        map[string]any   `json:"actor,omitempty"`
	Device       map[string]any   `json:"device,omitempty"`
	SrcEndpoint  map[string]any   `json:"src_endpoint,omitempty"`
	DstEndpoint  map[string]any   `json:"dst_endpoint,omitempty"`
	LogName      string           `json:"log_name,omitempty"`
	LogProvider  string           `json:"log_provider,omitempty"`
	LogLevel     string           `json:"log_level,omitempty"`
	LogVersion   string           `json:"log_version,omitempty"`
	Unmapped     map[string]any   `json:"unmapped,omitempty"`
	RawData      string           `json:"raw_data,omitempty"`
}

const (
	ocsfClassEventLogActivity  = 1008
	ocsfCategorySystemActivity = 1
	ocsfActivityLogCreate      = 1
	ocsfVersion                = "1.7.0"
)

//nolint:gochecknoglobals
var eventCounter uint64

// NewResult returns a result with defaults.
func NewResult() *Result {
	return &Result{SchemaVersion: 1, Status: StatusUnknown}
}

// Ok returns an OK result with the provided summary.
func Ok(summary string) *Result {
	res := NewResult()
	res.Status = StatusOK
	res.Summary = summary

	return res
}

// Warning returns a WARNING result with the provided summary.
func Warning(summary string) *Result {
	res := NewResult()
	res.Status = StatusWarning
	res.Summary = summary

	return res
}

// Critical returns a CRITICAL result with the provided summary.
func Critical(summary string) *Result {
	res := NewResult()
	res.Status = StatusCritical
	res.Summary = summary

	return res
}

// Unknown returns an UNKNOWN result with the provided summary.
func Unknown(summary string) *Result {
	res := NewResult()
	res.Status = StatusUnknown
	res.Summary = summary

	return res
}

// TargetResult returns a result scoped to a descriptor-aware target context.
func TargetResult(ctx TargetContext, status Status, summary string) *Result {
	return NewResult().ForTarget(ctx).WithStatus(status).WithSummary(summary)
}

func (r *Result) SetStatus(status Status)      { r.Status = status }
func (r *Result) SetSummary(summary string)    { r.Summary = summary }
func (r *Result) SetDetails(details string)    { r.Details = details }
func (r *Result) SetPerfdata(perfdata string)  { r.Perfdata = perfdata }
func (r *Result) SetSchemaVersion(version int) { r.SchemaVersion = version }

func (r *Result) WithStatus(status Status) *Result {
	r.SetStatus(status)
	return r
}

func (r *Result) WithSummary(summary string) *Result {
	r.SetSummary(summary)
	return r
}

func (r *Result) WithDetails(details string) *Result {
	r.SetDetails(details)
	return r
}

func (r *Result) WithPerfdata(perfdata string) *Result {
	r.SetPerfdata(perfdata)
	return r
}

func (r *Result) WithSchemaVersion(version int) *Result {
	r.SetSchemaVersion(version)
	return r
}

func (r *Result) ForTarget(ctx TargetContext) *Result {
	if r == nil {
		return r
	}

	r.CheckInstanceID = ctx.CheckInstanceID
	r.MonitoredServiceID = ctx.MonitoredServiceID()
	r.DeviceUID = ctx.DeviceUID()
	r.AddLabel("check_instance_id", ctx.CheckInstanceID)

	if ctx.DescriptorID != "" {
		r.AddLabel("descriptor_id", ctx.DescriptorID)
	}
	if ctx.UID != "" {
		r.AddLabel("target_uid", ctx.UID)
	}

	return r
}

func (r *Result) SetObservedAt(t time.Time) {
	r.ObservedAt = t.UTC().Format(time.RFC3339Nano)
}

func (r *Result) WithObservedAt(t time.Time) *Result {
	r.SetObservedAt(t)
	return r
}

func (r *Result) AddLabel(key, value string) {
	if key == "" {
		return
	}

	if r.Labels == nil {
		r.Labels = make(map[string]string)
	}

	r.Labels[key] = value
}

func (r *Result) WithLabel(key, value string) *Result {
	r.AddLabel(key, value)
	return r
}

func (r *Result) AddStatCard(label, value, tone string) {
	r.Display = append(r.Display, DisplayWidget{
		Widget: "stat_card",
		Label:  label,
		Value:  value,
		Tone:   tone,
	})
}

func (r *Result) WithStatCard(label, value, tone string) *Result {
	r.AddStatCard(label, value, tone)
	return r
}

func (r *Result) AddTable(data map[string]string, layout string) {
	if data == nil {
		return
	}

	mapped := make(map[string]any, len(data))
	for key, value := range data {
		mapped[key] = value
	}

	r.Display = append(r.Display, DisplayWidget{
		Widget: "table",
		Layout: layout,
		Data:   mapped,
	})
}

func (r *Result) WithTable(data map[string]string, layout string) *Result {
	r.AddTable(data, layout)
	return r
}

func (r *Result) AddSparkline(label string, points []float64, tone string) {
	if len(points) == 0 {
		return
	}

	r.Display = append(r.Display, DisplayWidget{
		Widget: "sparkline",
		Label:  label,
		Tone:   tone,
		Data: map[string]any{
			"values": points,
		},
	})
}

func (r *Result) WithSparkline(label string, points []float64, tone string) *Result {
	r.AddSparkline(label, points, tone)
	return r
}

func (r *Result) AddMarkdown(markdown string) {
	if markdown == "" {
		return
	}

	r.Display = append(r.Display, DisplayWidget{
		Widget: "markdown",
		Data: map[string]any{
			"markdown": markdown,
		},
	})
}

func (r *Result) WithMarkdown(markdown string) *Result {
	r.AddMarkdown(markdown)
	return r
}

func (r *Result) EmitEvent(severity Severity, summary, key string) {
	if summary == "" {
		return
	}

	event := NewOCSFEventLogActivity(summary, severity)
	if key != "" {
		if event.Unmapped == nil {
			event.Unmapped = make(map[string]any)
		}

		event.Unmapped["condition_key"] = key
	}

	r.Events = append(r.Events, event)
}

func (r *Result) WithEvent(severity Severity, summary, key string) *Result {
	r.EmitEvent(severity, summary, key)
	return r
}

// AddOCSFEvent appends a pre-built OCSF event to the result payload.
func (r *Result) AddOCSFEvent(event OCSFEvent) {
	if event.ID == "" {
		event.ID = generateEventID()
	}

	if event.Time.IsZero() {
		event.Time = time.Now().UTC()
	}

	r.Events = append(r.Events, event)
}

func (r *Result) WithOCSFEvent(event OCSFEvent) *Result {
	r.AddOCSFEvent(event)
	return r
}

// NewOCSFEventLogActivity creates a minimal OCSF Event Log Activity entry.
func NewOCSFEventLogActivity(message string, severity Severity) OCSFEvent {
	severityID, severityName := severityToOCSF(severity)
	now := time.Now().UTC()

	return OCSFEvent{
		ID:           generateEventID(),
		Time:         now,
		ClassUID:     ocsfClassEventLogActivity,
		CategoryUID:  ocsfCategorySystemActivity,
		TypeUID:      ocsfClassEventLogActivity*100 + ocsfActivityLogCreate,
		ActivityID:   ocsfActivityLogCreate,
		ActivityName: "Create",
		SeverityID:   severityID,
		Severity:     severityName,
		Message:      message,
		Metadata:     defaultOCSFMetadata(now),
		LogName:      "events.ocsf.processed",
		LogProvider:  "serviceradar-plugin",
	}
}

func defaultOCSFMetadata(now time.Time) map[string]any {
	return map[string]any{
		"version": ocsfVersion,
		"product": map[string]any{
			"vendor_name": "ServiceRadar",
			"name":        "plugin",
		},
		"logged_time": now.Format(time.RFC3339Nano),
	}
}

func severityToOCSF(severity Severity) (int, string) {
	switch severity {
	case SeverityCritical:
		return 5, "Critical"
	case SeverityError:
		return 6, "High"
	case SeverityWarning:
		return 3, "Medium"
	case SeverityInfo:
		fallthrough
	default:
		return 1, "Informational"
	}
}

func generateEventID() string {
	counter := atomic.AddUint64(&eventCounter, 1)
	return fmt.Sprintf("plugin-%d-%d", time.Now().UTC().UnixNano(), counter)
}

func (r *Result) RequestImmediateAlert(conditionID string) {
	r.AlertHint = true
	r.ConditionID = conditionID
}

func (r *Result) AddAdvisoryFeed(batch AdvisoryFeedBatch) {
	r.AdvisoryFeeds = append(r.AdvisoryFeeds, batch)
}

func (r *Result) WithAdvisoryFeed(batch AdvisoryFeedBatch) *Result {
	r.AddAdvisoryFeed(batch)
	return r
}

func (r *Result) WithImmediateAlert(conditionID string) *Result {
	r.RequestImmediateAlert(conditionID)
	return r
}

// ApplyThresholds compares a value against warning/critical thresholds and updates status.
func (r *Result) ApplyThresholds(value float64, warn, crit *float64) {
	switch {
	case crit != nil && value >= *crit:
		r.Status = StatusCritical
	case warn != nil && value >= *warn:
		r.Status = StatusWarning
	case r.Status == "" || r.Status == StatusUnknown:
		r.Status = StatusOK
	}
}

func (r *Result) WithThresholds(value float64, warn, crit *float64) *Result {
	r.ApplyThresholds(value, warn, crit)
	return r
}

func applyResultDefaults(r *Result, now time.Time) {
	if r.SchemaVersion == 0 {
		r.SchemaVersion = 1
	}

	if r.Status == "" {
		r.Status = StatusUnknown
	}

	if r.Summary == "" {
		r.Summary = string(r.Status)
	}

	if r.ObservedAt == "" {
		r.SetObservedAt(now)
	}
}

func (r *Result) finalize() {
	applyResultDefaults(r, time.Now().UTC())
}

// Serialize returns the JSON payload for the result.
func (r *Result) Serialize() ([]byte, error) {
	now := time.Now().UTC()

	payload := Result{}
	if r != nil {
		payload = *r
	}

	applyResultDefaults(&payload, now)

	return json.Marshal(payload)
}
