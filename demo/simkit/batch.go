package simkit

import "time"

// MaxTelemetryBatch is the agent's per-batch record cap for emit_telemetry.
const MaxTelemetryBatch = 256

// Schedule status metric names read by the presenter strip.
const (
	MetricFaultActive = "demo.fault.active"
	MetricFaultNextAt = "demo.fault.next_at"
)

// Device is an inventory record shaped like the product's device discovery
// contract.
type Device struct {
	AssetID  string            `json:"asset_id"`
	Kind     string            `json:"kind"`
	Name     string            `json:"name"`
	Hostname string            `json:"hostname,omitempty"`
	IP       string            `json:"ip,omitempty"`
	MAC      string            `json:"mac,omitempty"`
	Serial   string            `json:"serial,omitempty"`
	Vendor   string            `json:"vendor,omitempty"`
	Model    string            `json:"model,omitempty"`
	Site     string            `json:"site,omitempty"`
	Lat      *float64          `json:"lat,omitempty"`
	Lon      *float64          `json:"lon,omitempty"`
	Labels   map[string]string `json:"labels,omitempty"`
}

// Metric is one sample shaped like the product's metric batch contract.
type Metric struct {
	Name    string            `json:"name"`
	AssetID string            `json:"asset_id,omitempty"`
	Value   float64           `json:"value"`
	Unit    string            `json:"unit,omitempty"`
	Time    time.Time         `json:"time"`
	Labels  map[string]string `json:"labels,omitempty"`
}

// Event is a fault transition or other occurrence, shaped for an OCSF event.
type Event struct {
	ID       string            `json:"id"`
	AssetID  string            `json:"asset_id"`
	Kind     string            `json:"kind"`
	Title    string            `json:"title"`
	Severity string            `json:"severity"`
	Opening  bool              `json:"opening"`
	FaultID  string            `json:"fault_id,omitempty"`
	Time     time.Time         `json:"time"`
	Labels   map[string]string `json:"labels,omitempty"`
}

// Batch is everything a run emits, before it is mapped onto SDK calls.
type Batch struct {
	Devices []Device `json:"devices,omitempty"`
	Metrics []Metric `json:"metrics,omitempty"`
	Events  []Event  `json:"events,omitempty"`
}

// MetricChunks splits metrics into slices of at most max records.
func (b Batch) MetricChunks(max int) [][]Metric {
	if max <= 0 {
		max = MaxTelemetryBatch
	}
	var out [][]Metric
	for i := 0; i < len(b.Metrics); i += max {
		end := i + max
		if end > len(b.Metrics) {
			end = len(b.Metrics)
		}
		out = append(out, b.Metrics[i:end])
	}
	return out
}

// TransitionEvent converts a fault transition into an event. Opening and
// resolving events of one fault share FaultID; the event id is unique per
// transition and stable across repeats.
func TransitionEvent(tr Transition) Event {
	phase := "resolved"
	if tr.Opening {
		phase = "opened"
	}
	return Event{
		ID:       tr.Fault.ID + "/" + phase,
		AssetID:  tr.Fault.Target,
		Kind:     tr.Fault.Kind,
		Title:    tr.Fault.Title,
		Severity: tr.Fault.Severity,
		Opening:  tr.Opening,
		FaultID:  tr.Fault.ID,
		Time:     tr.At,
	}
}

// StatusMetrics reports the schedule state the presenter strip reads: the
// number of active faults and, when one is scheduled, when the next starts.
func (s *Schedule) StatusMetrics(t time.Time, overrides []Override) []Metric {
	out := []Metric{{Name: MetricFaultActive, Value: float64(len(s.ActiveAt(t, overrides))), Time: t}}
	if next, ok := s.NextStart(t); ok {
		out = append(out, Metric{
			Name:   MetricFaultNextAt,
			Value:  float64(next.Start.Unix()),
			Unit:   "unix_s",
			Time:   t,
			Labels: map[string]string{"kind": next.Kind, "target": next.Target},
		})
	}
	return out
}
