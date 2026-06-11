package dbeventwriter

import (
	"testing"
	"time"

	commonv1 "go.opentelemetry.io/proto/otlp/common/v1"
	metricspbv1 "go.opentelemetry.io/proto/otlp/metrics/v1"
	resourcev1 "go.opentelemetry.io/proto/otlp/resource/v1"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// pointTimeUnixNano mirrors @point_time in the Elixir OtelMetrics test so the
// cross-writer parity assertions cover the same input.
const pointTimeUnixNano = uint64(1_705_315_800_123_456_789)

func metricPointsProcessor() *Processor {
	return &Processor{logger: logger.NewTestLogger()}
}

// buildMetricPointsResource mirrors build_metrics_request/0 in
// elixir .../processors/otel_metrics_test.exs.
func buildMetricPointsResource() *metricspbv1.ResourceMetrics {
	sumMetric := &metricspbv1.Metric{
		Name: "falcosecurity_falcosidekick_outputs",
		Unit: "1",
		Data: &metricspbv1.Metric_Sum{
			Sum: &metricspbv1.Sum{
				AggregationTemporality: metricspbv1.AggregationTemporality_AGGREGATION_TEMPORALITY_CUMULATIVE,
				IsMonotonic:            true,
				DataPoints: []*metricspbv1.NumberDataPoint{
					{
						TimeUnixNano: pointTimeUnixNano,
						Value:        &metricspbv1.NumberDataPoint_AsInt{AsInt: 42},
						Attributes: []*commonv1.KeyValue{
							stringKeyValue("destination", "slack"),
						},
					},
				},
			},
		},
	}

	gaugeMetric := &metricspbv1.Metric{
		Name: "process_cpu_usage",
		Data: &metricspbv1.Metric_Gauge{
			Gauge: &metricspbv1.Gauge{
				DataPoints: []*metricspbv1.NumberDataPoint{
					{
						TimeUnixNano: pointTimeUnixNano,
						Value:        &metricspbv1.NumberDataPoint_AsDouble{AsDouble: 0.5},
					},
				},
			},
		},
	}

	histogramSum := 123.5
	histogramMetric := &metricspbv1.Metric{
		Name: "http_request_duration",
		Unit: "ms",
		Data: &metricspbv1.Metric_Histogram{
			Histogram: &metricspbv1.Histogram{
				AggregationTemporality: metricspbv1.AggregationTemporality_AGGREGATION_TEMPORALITY_DELTA,
				DataPoints: []*metricspbv1.HistogramDataPoint{
					{
						TimeUnixNano:   pointTimeUnixNano,
						Count:          10,
						Sum:            &histogramSum,
						BucketCounts:   []uint64{1, 2, 7},
						ExplicitBounds: []float64{10.0, 100.0},
					},
				},
			},
		},
	}

	return &metricspbv1.ResourceMetrics{
		Resource: &resourcev1.Resource{
			Attributes: []*commonv1.KeyValue{
				stringKeyValue("service.name", "metrics-service"),
			},
		},
		ScopeMetrics: []*metricspbv1.ScopeMetrics{
			{Metrics: []*metricspbv1.Metric{sumMetric, gaugeMetric, histogramMetric}},
		},
	}
}

// TestMetricPointRowsElixirParity asserts the Go writer produces the same
// otel_metric_points column values as the Elixir EventWriter for the same
// protobuf input — most importantly the primary-key fields (timestamp,
// metric_name, service_name, attributes_hash) so double-ingest dedupes via
// ON CONFLICT DO NOTHING.
func TestMetricPointRowsElixirParity(t *testing.T) {
	t.Parallel()

	p := metricPointsProcessor()
	rows := p.metricPointRowsForResource(buildMetricPointsResource())

	if len(rows) != 3 {
		t.Fatalf("expected 3 rows, got %d", len(rows))
	}

	sumRow, gaugeRow, histogramRow := rows[0], rows[1], rows[2]

	// Timestamps truncate to microseconds, matching
	// DateTime.from_unix!(div(ns, 1000), :microsecond).
	wantTimestamp := time.UnixMicro(1_705_315_800_123_456).UTC()
	for i, row := range rows {
		if !row.Timestamp.Equal(wantTimestamp) {
			t.Fatalf("row %d: expected timestamp %v, got %v", i, wantTimestamp, row.Timestamp)
		}
		if row.ServiceName != "metrics-service" {
			t.Fatalf("row %d: unexpected service name %q", i, row.ServiceName)
		}
	}

	// Sum point.
	if sumRow.MetricName != "falcosecurity_falcosidekick_outputs" || sumRow.MetricType != "sum" {
		t.Fatalf("unexpected sum row identity: %+v", sumRow)
	}
	if sumRow.Unit == nil || *sumRow.Unit != "1" {
		t.Fatalf("expected sum unit \"1\", got %v", sumRow.Unit)
	}
	if sumRow.Temporality == nil || *sumRow.Temporality != "cumulative" {
		t.Fatalf("expected cumulative temporality, got %v", sumRow.Temporality)
	}
	if sumRow.IsMonotonic == nil || !*sumRow.IsMonotonic {
		t.Fatalf("expected monotonic sum, got %v", sumRow.IsMonotonic)
	}
	if sumRow.Value == nil || *sumRow.Value != 42.0 {
		t.Fatalf("expected sum value 42.0, got %v", sumRow.Value)
	}
	if sumRow.Count != nil {
		t.Fatalf("expected nil count on sum row, got %v", *sumRow.Count)
	}
	if sumRow.Attributes != `{"destination":"slack"}` {
		t.Fatalf("unexpected sum attributes JSON: %s", sumRow.Attributes)
	}
	// md5("{\"destination\":\"slack\"}") — must equal the Elixir writer's
	// md5_hex of the identical sorted-key JSON text.
	if sumRow.AttributesHash != "45bc1fb6631438bd09e8a9da86ef28f9" {
		t.Fatalf("unexpected sum attributes hash: %s", sumRow.AttributesHash)
	}

	// Gauge point.
	if gaugeRow.MetricName != "process_cpu_usage" || gaugeRow.MetricType != "gauge" {
		t.Fatalf("unexpected gauge row identity: %+v", gaugeRow)
	}
	if gaugeRow.Unit != nil || gaugeRow.Temporality != nil || gaugeRow.IsMonotonic != nil {
		t.Fatalf("expected nil unit/temporality/monotonic on gauge row: %+v", gaugeRow)
	}
	if gaugeRow.Value == nil || *gaugeRow.Value != 0.5 {
		t.Fatalf("expected gauge value 0.5, got %v", gaugeRow.Value)
	}
	if gaugeRow.Attributes != "{}" {
		t.Fatalf("expected empty attributes object, got %s", gaugeRow.Attributes)
	}
	// md5("{}")
	if gaugeRow.AttributesHash != "99914b932bd37a50b983c5e7c90ae93b" {
		t.Fatalf("unexpected gauge attributes hash: %s", gaugeRow.AttributesHash)
	}

	// Histogram point.
	if histogramRow.MetricName != "http_request_duration" || histogramRow.MetricType != "histogram" {
		t.Fatalf("unexpected histogram row identity: %+v", histogramRow)
	}
	if histogramRow.Unit == nil || *histogramRow.Unit != "ms" {
		t.Fatalf("expected histogram unit \"ms\", got %v", histogramRow.Unit)
	}
	if histogramRow.Temporality == nil || *histogramRow.Temporality != "delta" {
		t.Fatalf("expected delta temporality, got %v", histogramRow.Temporality)
	}
	if histogramRow.Value != nil {
		t.Fatalf("expected nil value on histogram row, got %v", *histogramRow.Value)
	}
	if histogramRow.Count == nil || *histogramRow.Count != 10 {
		t.Fatalf("expected histogram count 10, got %v", histogramRow.Count)
	}
	if histogramRow.Sum == nil || *histogramRow.Sum != 123.5 {
		t.Fatalf("expected histogram sum 123.5, got %v", histogramRow.Sum)
	}
	if histogramRow.BucketCounts == nil || *histogramRow.BucketCounts != "[1,2,7]" {
		t.Fatalf("unexpected bucket counts: %v", histogramRow.BucketCounts)
	}
	// Jason renders floats with a fractional digit: [10.0,100.0].
	if histogramRow.ExplicitBounds == nil || *histogramRow.ExplicitBounds != "[10.0,100.0]" {
		t.Fatalf("unexpected explicit bounds: %v", histogramRow.ExplicitBounds)
	}
}

func TestMetricPointAttributesHashStableAcrossOrdering(t *testing.T) {
	t.Parallel()

	p := metricPointsProcessor()

	point := func(attrs []*commonv1.KeyValue) *metricspbv1.Metric {
		return &metricspbv1.Metric{
			Name: "ordered",
			Data: &metricspbv1.Metric_Gauge{
				Gauge: &metricspbv1.Gauge{
					DataPoints: []*metricspbv1.NumberDataPoint{
						{
							TimeUnixNano: pointTimeUnixNano,
							Value:        &metricspbv1.NumberDataPoint_AsDouble{AsDouble: 1.0},
							Attributes:   attrs,
						},
					},
				},
			},
		}
	}

	rowsA := p.metricPointRows(point([]*commonv1.KeyValue{
		stringKeyValue("a", "1"),
		stringKeyValue("b", "2"),
	}), "svc")
	rowsB := p.metricPointRows(point([]*commonv1.KeyValue{
		stringKeyValue("b", "2"),
		stringKeyValue("a", "1"),
	}), "svc")

	if len(rowsA) != 1 || len(rowsB) != 1 {
		t.Fatalf("expected one row per request, got %d and %d", len(rowsA), len(rowsB))
	}

	if rowsA[0].Attributes != `{"a":"1","b":"2"}` {
		t.Fatalf("expected sorted-key attributes JSON, got %s", rowsA[0].Attributes)
	}

	if rowsA[0].AttributesHash != rowsB[0].AttributesHash {
		t.Fatalf("attributes hash not stable across ordering: %s vs %s",
			rowsA[0].AttributesHash, rowsB[0].AttributesHash)
	}

	// md5("{\"a\":\"1\",\"b\":\"2\"}")
	if rowsA[0].AttributesHash != "8018d630c38e45a64531824279891103" {
		t.Fatalf("unexpected attributes hash: %s", rowsA[0].AttributesHash)
	}
}

func TestMetricPointRowsNilResourceUsesEmptyServiceName(t *testing.T) {
	t.Parallel()

	p := metricPointsProcessor()
	resourceMetric := buildMetricPointsResource()
	resourceMetric.Resource = nil

	rows := p.metricPointRowsForResource(resourceMetric)
	if len(rows) != 3 {
		t.Fatalf("expected nil-resource metrics to still produce 3 rows, got %d", len(rows))
	}

	for i, row := range rows {
		// Matches the Elixir writer and the column default: service_name ''.
		if row.ServiceName != "" {
			t.Fatalf("row %d: expected empty service name, got %q", i, row.ServiceName)
		}
	}
}

// Not parallel: asserts a delta on the package-global metricCounters.
func TestMetricPointRowsCountsUnsupportedTypesAsRejected(t *testing.T) {
	p := metricPointsProcessor()

	expoMetric := &metricspbv1.Metric{
		Name: "latency_expo",
		Data: &metricspbv1.Metric_ExponentialHistogram{
			ExponentialHistogram: &metricspbv1.ExponentialHistogram{
				DataPoints: []*metricspbv1.ExponentialHistogramDataPoint{
					{TimeUnixNano: pointTimeUnixNano},
					{TimeUnixNano: pointTimeUnixNano},
				},
			},
		},
	}

	summaryMetric := &metricspbv1.Metric{
		Name: "latency_summary",
		Data: &metricspbv1.Metric_Summary{
			Summary: &metricspbv1.Summary{
				DataPoints: []*metricspbv1.SummaryDataPoint{
					{TimeUnixNano: pointTimeUnixNano},
				},
			},
		},
	}

	before := metricCounters.rejected.Load()

	if rows := p.metricPointRows(expoMetric, "svc"); len(rows) != 0 {
		t.Fatalf("expected no rows for exponential histogram, got %d", len(rows))
	}
	if rows := p.metricPointRows(summaryMetric, "svc"); len(rows) != 0 {
		t.Fatalf("expected no rows for summary, got %d", len(rows))
	}

	rejected := metricCounters.rejected.Load() - before
	if rejected != 3 {
		t.Fatalf("expected 3 rejected data points (2 expo + 1 summary), got %d", rejected)
	}
}
