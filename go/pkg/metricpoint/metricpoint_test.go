package metricpoint_test

import (
	"encoding/json"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/metricpoint"
)

func TestGaugeShape(t *testing.T) {
	m := metricpoint.Gauge("cpu.usage", 42.5, 1000, metricpoint.WithUnit("%"), metricpoint.WithMetricType("cpu"))

	if m.Schema != metricpoint.Schema || m.SchemaVersion != metricpoint.SchemaVersion {
		t.Fatalf("schema/version = %s/%d", m.Schema, m.SchemaVersion)
	}
	if m.Kind != metricpoint.KindGauge || m.IsMonotonic != nil {
		t.Fatalf("gauge kind/monotonic = %s/%v (monotonic must be absent for a gauge)", m.Kind, m.IsMonotonic)
	}
	if m.Unit != "%" || m.MetricType != "cpu" {
		t.Fatalf("unit/type = %s/%s", m.Unit, m.MetricType)
	}
	if len(m.Points) != 1 || m.Points[0].Value != 42.5 || m.Points[0].TimeUnixNano != 1000 {
		t.Fatalf("points = %+v", m.Points)
	}
}

func TestCounterIsCumulativeMonotonicSum(t *testing.T) {
	m := metricpoint.Counter("net.bytes", 4_000_000_000, 2000, 1000, metricpoint.WithUnit("By"))

	if m.Kind != metricpoint.KindSum || m.IsMonotonic == nil || !*m.IsMonotonic ||
		m.Temporality != metricpoint.TemporalityCumulative {
		t.Fatalf("counter shape = %s/%v/%s", m.Kind, m.IsMonotonic, m.Temporality)
	}
	if m.Points[0].StartTimeUnixNano != 1000 {
		t.Fatalf("reset anchor = %d", m.Points[0].StartTimeUnixNano)
	}
}

// A non-monotonic sum (UpDownCounter) must serialize is_monotonic:false rather
// than omitting it — otherwise it is indistinguishable from a kind where
// monotonicity is irrelevant. Regression test for fj #3788 review (REC7a).
func TestNonMonotonicSumSerializesFalse(t *testing.T) {
	m := metricpoint.Multi("queue.depth", metricpoint.KindSum, false, metricpoint.TemporalityCumulative,
		[]metricpoint.DataPoint{metricpoint.Point(5, 1000, nil)})

	if m.IsMonotonic == nil || *m.IsMonotonic {
		t.Fatalf("non-monotonic sum monotonic = %v, want non-nil false", m.IsMonotonic)
	}

	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(b, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if v, ok := decoded["is_monotonic"]; !ok || v != false {
		t.Errorf("is_monotonic = %v (ok=%v), want present false in %s", v, ok, b)
	}
}

func TestMultiPointDimensions(t *testing.T) {
	m := metricpoint.Multi("cpu.usage", metricpoint.KindGauge, false, "", []metricpoint.DataPoint{
		metricpoint.Point(10, 1000, map[string]string{"core_id": "0"}),
		metricpoint.Point(20, 1000, map[string]string{"core_id": "1"}),
	}, metricpoint.WithUnit("%"))

	if len(m.Points) != 2 {
		t.Fatalf("want 2 points, got %d", len(m.Points))
	}
	if m.Points[0].Attributes["core_id"] != "0" || m.Points[1].Attributes["core_id"] != "1" {
		t.Fatalf("per-point attributes lost: %+v", m.Points)
	}
}

func TestMarshalsCanonicalFields(t *testing.T) {
	m := metricpoint.Counter("io.rbytes", 100, 2000, 1000,
		metricpoint.WithUnit("By"),
		metricpoint.WithResource(metricpoint.Resource{ServiceName: "sysmon", Attributes: map[string]string{"host_id": "h1"}}),
	)

	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(b, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	for _, key := range []string{"schema", "schema_version", "metric_name", "kind", "temporality", "is_monotonic", "points", "resource"} {
		if _, ok := decoded[key]; !ok {
			t.Errorf("missing canonical field %q in %s", key, b)
		}
	}
	if decoded["schema"] != metricpoint.Schema {
		t.Errorf("schema = %v", decoded["schema"])
	}
}
