// Package metricpoint builds serviceradar.metric.v1 envelopes for agent
// producers (sysmon, snmp, icmp, mtr, sweep, rperf) so they emit one unified,
// OTLP-grade metric shape instead of a per-producer schema smuggled inside a
// status payload (fj #3788, REC7).
//
// A Metric is one metric stream (a name + kind + unit) carrying one or many
// DataPoints. Multiple points let a producer dimension cores/mounts/interfaces
// without splitting envelopes. The reader/gateway treats the result as the
// canonical serviceradar.metric.v1 contract.
package metricpoint

// Schema and schema version of the canonical metric envelope.
const (
	Schema        = "serviceradar.metric.v1"
	SchemaVersion = 2
)

// Metric kinds (OTel data-shape).
const (
	KindGauge     = "gauge"
	KindSum       = "sum"
	KindHistogram = "histogram"
)

// Aggregation temporality for cumulative/delta sums.
const (
	TemporalityDelta      = "delta"
	TemporalityCumulative = "cumulative"
)

// Resource identifies the producer of a metric, carried once per envelope.
type Resource struct {
	ServiceName       string            `json:"service_name"`
	ServiceInstanceID string            `json:"service_instance_id,omitempty"`
	ScopeName         string            `json:"scope_name,omitempty"`
	Attributes        map[string]string `json:"attributes,omitempty"`
}

// DataPoint is a single sample within a Metric. Attributes carry the per-point
// dimensions (core_id, mount_point, if_index, ...) that distinguish series.
type DataPoint struct {
	TimeUnixNano      int64             `json:"time_unix_nano"`
	StartTimeUnixNano int64             `json:"start_time_unix_nano,omitempty"`
	Value             float64           `json:"value"`
	Attributes        map[string]string `json:"attributes,omitempty"`
}

// Metric is a serviceradar.metric.v1 envelope: one metric stream, >=1 points.
type Metric struct {
	Schema        string `json:"schema"`
	SchemaVersion int    `json:"schema_version"`
	Name          string `json:"metric_name"`
	MetricType    string `json:"metric_type,omitempty"`
	Kind          string `json:"kind"`
	Temporality   string `json:"temporality,omitempty"`
	// IsMonotonic is a pointer so an explicitly non-monotonic sum
	// (is_monotonic:false, e.g. an UpDownCounter) stays distinguishable from a
	// kind where monotonicity is irrelevant (gauge/histogram) — the latter omits
	// the field entirely. Only kind=sum sets it.
	IsMonotonic *bool             `json:"is_monotonic,omitempty"`
	Unit        string            `json:"unit,omitempty"`
	Resource    *Resource         `json:"resource,omitempty"`
	Points      []DataPoint       `json:"points"`
	Tags        map[string]string `json:"tags,omitempty"`
}

// Option configures a Metric.
type Option func(*Metric)

// WithUnit sets the UCUM unit (%, By, 1, ms, Hz).
func WithUnit(unit string) Option { return func(m *Metric) { m.Unit = unit } }

// WithMetricType sets the routing/domain token (cpu, memory, interface, ...).
func WithMetricType(metricType string) Option {
	return func(m *Metric) { m.MetricType = metricType }
}

// WithResource attaches the producer resource identity.
func WithResource(r Resource) Option { return func(m *Metric) { m.Resource = &r } }

// WithTags attaches envelope-level tags.
func WithTags(tags map[string]string) Option { return func(m *Metric) { m.Tags = tags } }

// WithTemporality overrides the aggregation temporality (defaults: gauge has
// none, counter is cumulative).
func WithTemporality(temporality string) Option {
	return func(m *Metric) { m.Temporality = temporality }
}

// Point builds a DataPoint at the given time with optional dimensions.
func Point(value float64, timeUnixNano int64, attrs map[string]string) DataPoint {
	return DataPoint{TimeUnixNano: timeUnixNano, Value: value, Attributes: attrs}
}

// Gauge builds a single-point gauge (a spot value meaningful on its own).
func Gauge(name string, value float64, timeUnixNano int64, opts ...Option) Metric {
	return build(name, KindGauge, false, "",
		[]DataPoint{{TimeUnixNano: timeUnixNano, Value: value}}, opts)
}

// Counter builds a single-point cumulative monotonic sum (a running total whose
// rate is the meaningful quantity). startUnixNano is the reset anchor.
func Counter(name string, value float64, timeUnixNano, startUnixNano int64, opts ...Option) Metric {
	return build(name, KindSum, true, TemporalityCumulative,
		[]DataPoint{{TimeUnixNano: timeUnixNano, StartTimeUnixNano: startUnixNano, Value: value}}, opts)
}

// Multi builds a multi-point metric (e.g. per-core CPU, per-interface octets).
func Multi(name, kind string, monotonic bool, temporality string, points []DataPoint, opts ...Option) Metric {
	return build(name, kind, monotonic, temporality, points, opts)
}

func build(name, kind string, monotonic bool, temporality string, points []DataPoint, opts []Option) Metric {
	m := Metric{
		Schema:        Schema,
		SchemaVersion: SchemaVersion,
		Name:          name,
		Kind:          kind,
		Temporality:   temporality,
		Points:        points,
	}

	// is_monotonic only has meaning for sums; carry it (true OR false) there and
	// leave it absent for gauges/histograms.
	if kind == KindSum {
		m.IsMonotonic = &monotonic
	}

	for _, opt := range opts {
		opt(&m)
	}

	return m
}
