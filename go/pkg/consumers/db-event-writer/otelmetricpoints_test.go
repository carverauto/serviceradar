package dbeventwriter

import (
	"bytes"
	"testing"
	"time"

	commonv1 "go.opentelemetry.io/proto/otlp/common/v1"
	metricspbv1 "go.opentelemetry.io/proto/otlp/metrics/v1"
	resourcev1 "go.opentelemetry.io/proto/otlp/resource/v1"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
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
//
//nolint:gocyclo // Field parity is clearer as one table-shaped assertion block.
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
		// The fixture has no service.instance.id, no scope name, and no
		// point start time: identity columns default to "" and
		// start_time_unix_nano stays NULL.
		if row.ServiceInstanceID != "" {
			t.Fatalf("row %d: expected empty service instance id, got %q", i, row.ServiceInstanceID)
		}
		if row.ScopeName != "" {
			t.Fatalf("row %d: expected empty scope name, got %q", i, row.ScopeName)
		}
		if row.StartTimeUnixNano != nil {
			t.Fatalf("row %d: expected nil start_time_unix_nano, got %d", i, *row.StartTimeUnixNano)
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
	// Hash recipe v2: md5 of `{"destination":"slack"}` + "\n" + "" (instance)
	// + "\n" + "" (scope) — must equal the Elixir writer's hash for the same
	// input. (Recipe v1 over the bare JSON was 45bc1fb6631438bd09e8a9da86ef28f9.)
	if sumRow.AttributesHash != "0a400c7afa11f7cb8f6b057bfc2ced04" {
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
	// Hash recipe v2: md5 of "{}" + "\n" + "" + "\n" + "".
	// (Recipe v1 over bare "{}" was 99914b932bd37a50b983c5e7c90ae93b.)
	if gaugeRow.AttributesHash != "5ad5cc4d26869082efd29c436b57384a" {
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
	// Same empty attributes + empty identity as the gauge point.
	if histogramRow.AttributesHash != "5ad5cc4d26869082efd29c436b57384a" {
		t.Fatalf("unexpected histogram attributes hash: %s", histogramRow.AttributesHash)
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

	identity := metricPointIdentity{serviceName: "svc"}

	rowsA := p.metricPointRows(point([]*commonv1.KeyValue{
		stringKeyValue("a", "1"),
		stringKeyValue("b", "2"),
	}), identity)
	rowsB := p.metricPointRows(point([]*commonv1.KeyValue{
		stringKeyValue("b", "2"),
		stringKeyValue("a", "1"),
	}), identity)

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

	// Hash recipe v2: md5 of `{"a":"1","b":"2"}` + "\n" + "" + "\n" + "".
	// (Recipe v1 over the bare JSON was 8018d630c38e45a64531824279891103.)
	if rowsA[0].AttributesHash != "08d15b1d3dba45bfb72b5ba30c440f5c" {
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

	identity := metricPointIdentity{serviceName: "svc"}

	if rows := p.metricPointRows(expoMetric, identity); len(rows) != 0 {
		t.Fatalf("expected no rows for exponential histogram, got %d", len(rows))
	}
	if rows := p.metricPointRows(summaryMetric, identity); len(rows) != 0 {
		t.Fatalf("expected no rows for summary, got %d", len(rows))
	}

	rejected := metricCounters.rejected.Load() - before
	if rejected != 3 {
		t.Fatalf("expected 3 rejected data points (2 expo + 1 summary), got %d", rejected)
	}
}

// gaugeMetricWithAttrs builds a single-point gauge metric carrying the given
// point attributes, the smallest input that exercises the hash recipe.
func gaugeMetricWithAttrs(attrs ...*commonv1.KeyValue) *metricspbv1.Metric {
	return &metricspbv1.Metric{
		Name: "hash_probe",
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

// singleMetricPointRow converts one metric through the processor and asserts
// exactly one row came out.
func singleMetricPointRow(
	t *testing.T,
	p *Processor,
	metric *metricspbv1.Metric,
	identity metricPointIdentity,
) models.OTELMetricPointRow {
	t.Helper()

	rows := p.metricPointRows(metric, identity)
	if len(rows) != 1 {
		t.Fatalf("expected exactly one row, got %d", len(rows))
	}

	return rows[0]
}

func intKeyValue(key string, value int64) *commonv1.KeyValue {
	return &commonv1.KeyValue{
		Key:   key,
		Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_IntValue{IntValue: value}},
	}
}

func doubleKeyValue(key string, value float64) *commonv1.KeyValue {
	return &commonv1.KeyValue{
		Key:   key,
		Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_DoubleValue{DoubleValue: value}},
	}
}

func bytesKeyValue(key string, value []byte) *commonv1.KeyValue {
	return &commonv1.KeyValue{
		Key:   key,
		Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_BytesValue{BytesValue: value}},
	}
}

func kvlistKeyValue(key string, values ...*commonv1.KeyValue) *commonv1.KeyValue {
	return &commonv1.KeyValue{
		Key: key,
		Value: &commonv1.AnyValue{
			Value: &commonv1.AnyValue_KvlistValue{
				KvlistValue: &commonv1.KeyValueList{Values: values},
			},
		},
	}
}

// TestMetricPointHashSortsNestedMaps asserts recipe-v2 canonical bytes sort
// map keys at every nesting level, so reordering nested kvlist entries does
// not change the hash: canonical input
// `{"outer":{"a":"1","b":"2"},"z":"last"}` + "\n" + "" + "\n" + "".
func TestMetricPointHashSortsNestedMaps(t *testing.T) {
	t.Parallel()

	p := metricPointsProcessor()
	identity := metricPointIdentity{serviceName: "svc"}

	rowA := singleMetricPointRow(t, p, gaugeMetricWithAttrs(
		stringKeyValue("z", "last"),
		kvlistKeyValue("outer",
			stringKeyValue("b", "2"),
			stringKeyValue("a", "1"),
		),
	), identity)
	rowB := singleMetricPointRow(t, p, gaugeMetricWithAttrs(
		kvlistKeyValue("outer",
			stringKeyValue("a", "1"),
			stringKeyValue("b", "2"),
		),
		stringKeyValue("z", "last"),
	), identity)

	wantJSON := `{"outer":{"a":"1","b":"2"},"z":"last"}`
	if rowA.Attributes != wantJSON || rowB.Attributes != wantJSON {
		t.Fatalf("expected display JSON sorted at every level, got %s and %s",
			rowA.Attributes, rowB.Attributes)
	}

	if rowA.AttributesHash != rowB.AttributesHash {
		t.Fatalf("nested ordering changed the hash: %s vs %s", rowA.AttributesHash, rowB.AttributesHash)
	}

	// md5 of `{"outer":{"a":"1","b":"2"},"z":"last"}` + "\n\n".
	if rowA.AttributesHash != "f821d4197b5dc05ea9fa366ea480f027" {
		t.Fatalf("unexpected nested-map attributes hash: %s", rowA.AttributesHash)
	}
}

// TestMetricPointHashDistinguishesIntFromIntegralDouble asserts the recipe-v2
// type split: protobuf int 42 encodes as base-10 "42" while double 42.0
// encodes as "f4045000000000000" (big-endian Float64bits hex), so the two
// hash differently even though the display JSON renders both numerically.
func TestMetricPointHashDistinguishesIntFromIntegralDouble(t *testing.T) {
	t.Parallel()

	p := metricPointsProcessor()
	identity := metricPointIdentity{serviceName: "svc"}

	intRow := singleMetricPointRow(t, p, gaugeMetricWithAttrs(intKeyValue("answer", 42)), identity)
	doubleRow := singleMetricPointRow(t, p, gaugeMetricWithAttrs(doubleKeyValue("answer", 42.0)), identity)

	if intRow.Attributes != `{"answer":42}` {
		t.Fatalf("unexpected int display JSON: %s", intRow.Attributes)
	}
	if doubleRow.Attributes != `{"answer":42.0}` {
		t.Fatalf("unexpected double display JSON: %s", doubleRow.Attributes)
	}

	// md5 of `{"answer":42}` + "\n\n".
	if intRow.AttributesHash != "bd3a40e04fa406b8d985c73e85e536b5" {
		t.Fatalf("unexpected int attributes hash: %s", intRow.AttributesHash)
	}

	// md5 of `{"answer":f4045000000000000}` + "\n\n".
	if doubleRow.AttributesHash != "c7c4a09614b3e28324a32a8ca9d5a726" {
		t.Fatalf("unexpected double attributes hash: %s", doubleRow.AttributesHash)
	}

	if intRow.AttributesHash == doubleRow.AttributesHash {
		t.Fatal("int 42 and double 42.0 must hash differently under recipe v2")
	}
}

// TestMetricPointHashEncodesBytesDistinctFromString asserts bytes attributes
// hash as "b" + std base64 ("bAQL+"), distinct from a string attribute whose
// value is the same base64 text, even though both display as "AQL+".
func TestMetricPointHashEncodesBytesDistinctFromString(t *testing.T) {
	t.Parallel()

	p := metricPointsProcessor()
	identity := metricPointIdentity{serviceName: "svc"}

	bytesRow := singleMetricPointRow(t, p,
		gaugeMetricWithAttrs(bytesKeyValue("blob", []byte{0x01, 0x02, 0xFE})), identity)
	stringRow := singleMetricPointRow(t, p,
		gaugeMetricWithAttrs(stringKeyValue("blob", "AQL+")), identity)

	// Display JSON renders bytes as their base64 text, identical to the
	// string attribute — only the hash distinguishes them.
	if bytesRow.Attributes != `{"blob":"AQL+"}` || stringRow.Attributes != `{"blob":"AQL+"}` {
		t.Fatalf("unexpected display JSON: %s and %s", bytesRow.Attributes, stringRow.Attributes)
	}

	// md5 of `{"blob":bAQL+}` + "\n\n".
	if bytesRow.AttributesHash != "919d5b66db28fb4d165cc2237b4ba2ea" {
		t.Fatalf("unexpected bytes attributes hash: %s", bytesRow.AttributesHash)
	}

	// md5 of `{"blob":"AQL+"}` + "\n\n".
	if stringRow.AttributesHash != "d36ca93e4a2e8b1eed4c0d86b05afaa7" {
		t.Fatalf("unexpected string attributes hash: %s", stringRow.AttributesHash)
	}

	if bytesRow.AttributesHash == stringRow.AttributesHash {
		t.Fatal("bytes and string attributes must hash differently under recipe v2")
	}
}

// TestMetricPointIdentityFeedsHashAndColumns asserts service.instance.id and
// the instrumentation scope name populate their columns AND feed the hash:
// identical point attributes produce four distinct hashes across the four
// identity combinations.
func TestMetricPointIdentityFeedsHashAndColumns(t *testing.T) {
	t.Parallel()

	p := metricPointsProcessor()

	build := func(instanceID, scopeName string) models.OTELMetricPointRow {
		t.Helper()

		resourceAttrs := []*commonv1.KeyValue{stringKeyValue("service.name", "metrics-service")}
		if instanceID != "" {
			resourceAttrs = append(resourceAttrs, stringKeyValue("service.instance.id", instanceID))
		}

		rows := p.metricPointRowsForResource(&metricspbv1.ResourceMetrics{
			Resource: &resourcev1.Resource{Attributes: resourceAttrs},
			ScopeMetrics: []*metricspbv1.ScopeMetrics{
				{
					Scope:   &commonv1.InstrumentationScope{Name: scopeName},
					Metrics: []*metricspbv1.Metric{gaugeMetricWithAttrs(stringKeyValue("destination", "slack"))},
				},
			},
		})
		if len(rows) != 1 {
			t.Fatalf("expected exactly one row, got %d", len(rows))
		}

		return rows[0]
	}

	both := build("instance-1", "scope-a")
	if both.ServiceInstanceID != "instance-1" || both.ScopeName != "scope-a" {
		t.Fatalf("identity columns not populated: %+v", both)
	}

	// md5 of `{"destination":"slack"}` + "\n" + "instance-1" + "\n" + "scope-a".
	if both.AttributesHash != "26821101abf833b1c4f0704c27412203" {
		t.Fatalf("unexpected instance+scope hash: %s", both.AttributesHash)
	}

	// md5 of `{"destination":"slack"}` + "\n" + "instance-1" + "\n".
	instanceOnly := build("instance-1", "")
	if instanceOnly.AttributesHash != "12fabac8ad8a527d447a7fe53fd5438b" {
		t.Fatalf("unexpected instance-only hash: %s", instanceOnly.AttributesHash)
	}

	// md5 of `{"destination":"slack"}` + "\n\n" + "scope-a".
	scopeOnly := build("", "scope-a")
	if scopeOnly.AttributesHash != "152a33a6f1df3a16108b8d8d73f24c10" {
		t.Fatalf("unexpected scope-only hash: %s", scopeOnly.AttributesHash)
	}

	// md5 of `{"destination":"slack"}` + "\n\n" — same as the parity fixture.
	neither := build("", "")
	if neither.AttributesHash != "0a400c7afa11f7cb8f6b057bfc2ced04" {
		t.Fatalf("unexpected empty-identity hash: %s", neither.AttributesHash)
	}
}

// TestMetricPointStartTimeStored asserts start_time_unix_nano is carried for
// number and histogram points and stays NULL (nil) when the point reports 0.
func TestMetricPointStartTimeStored(t *testing.T) {
	t.Parallel()

	p := metricPointsProcessor()
	identity := metricPointIdentity{serviceName: "svc"}

	const startTimeUnixNano = uint64(1_705_315_000_000_000_000)

	gaugeMetric := gaugeMetricWithAttrs()
	gaugeMetric.GetGauge().DataPoints[0].StartTimeUnixNano = startTimeUnixNano

	gaugeRow := singleMetricPointRow(t, p, gaugeMetric, identity)
	if gaugeRow.StartTimeUnixNano == nil || *gaugeRow.StartTimeUnixNano != int64(startTimeUnixNano) {
		t.Fatalf("expected gauge start_time_unix_nano %d, got %v", startTimeUnixNano, gaugeRow.StartTimeUnixNano)
	}

	histogramSum := 1.0
	histogramRow := singleMetricPointRow(t, p, &metricspbv1.Metric{
		Name: "hist_with_start",
		Data: &metricspbv1.Metric_Histogram{
			Histogram: &metricspbv1.Histogram{
				DataPoints: []*metricspbv1.HistogramDataPoint{
					{
						TimeUnixNano:      pointTimeUnixNano,
						StartTimeUnixNano: startTimeUnixNano,
						Count:             1,
						Sum:               &histogramSum,
					},
				},
			},
		},
	}, identity)
	if histogramRow.StartTimeUnixNano == nil || *histogramRow.StartTimeUnixNano != int64(startTimeUnixNano) {
		t.Fatalf("expected histogram start_time_unix_nano %d, got %v",
			startTimeUnixNano, histogramRow.StartTimeUnixNano)
	}

	zeroRow := singleMetricPointRow(t, p, gaugeMetricWithAttrs(), identity)
	if zeroRow.StartTimeUnixNano != nil {
		t.Fatalf("expected nil start_time_unix_nano for zero start time, got %d", *zeroRow.StartTimeUnixNano)
	}
}

// TestMetricPointHashRichCrossLanguageFixture locks the full recipe-v2
// surface (arrays, kvlists, bytes, floats, null, escapes, identity) against
// the literal the Elixir EventWriter test suite asserts for the same input.
func TestMetricPointHashRichCrossLanguageFixture(t *testing.T) {
	attrs := []*commonv1.KeyValue{
		{Key: "str", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_StringValue{StringValue: `va"l\ue`}}},
		{Key: "none", Value: &commonv1.AnyValue{}},
		{Key: "nested", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_KvlistValue{KvlistValue: &commonv1.KeyValueList{Values: []*commonv1.KeyValue{
			{Key: "z", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_StringValue{StringValue: "last"}}},
			{Key: "a", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_KvlistValue{KvlistValue: &commonv1.KeyValueList{Values: []*commonv1.KeyValue{
				{Key: "deep", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_ArrayValue{ArrayValue: &commonv1.ArrayValue{Values: []*commonv1.AnyValue{
					{Value: &commonv1.AnyValue_IntValue{IntValue: 1}},
					{Value: &commonv1.AnyValue_IntValue{IntValue: 2}},
				}}}}},
			}}}}},
		}}}}},
		{Key: "neg", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_DoubleValue{DoubleValue: -1.5}}},
		{Key: "int", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_IntValue{IntValue: 42}}},
		{Key: "float", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_DoubleValue{DoubleValue: 0.5}}},
		{Key: "bytes", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_BytesValue{BytesValue: []byte{0xFF, 0x00, 0x01}}}},
		{Key: "bool", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_BoolValue{BoolValue: true}}},
		{Key: "arr", Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_ArrayValue{ArrayValue: &commonv1.ArrayValue{Values: []*commonv1.AnyValue{
			{Value: &commonv1.AnyValue_StringValue{StringValue: "x"}},
			{Value: &commonv1.AnyValue_IntValue{IntValue: 1}},
			{Value: &commonv1.AnyValue_DoubleValue{DoubleValue: 2.5}},
			{Value: &commonv1.AnyValue_BoolValue{BoolValue: false}},
		}}}}},
	}

	var buf bytes.Buffer
	writeCanonicalHashValue(&buf, attrsToCanonicalMap(attrs))

	wantCanonical := `{"arr":["x",1,f4004000000000000,false],"bool":true,"bytes":b/wAB,` +
		`"float":f3fe0000000000000,"int":42,"neg":fbff8000000000000,` +
		`"nested":{"a":{"deep":[1,2]},"z":"last"},"none":null,"str":"va\"l\\ue"}`
	if got := buf.String(); got != wantCanonical {
		t.Fatalf("canonical bytes mismatch:\n got: %s\nwant: %s", got, wantCanonical)
	}

	identity := metricPointIdentity{serviceInstanceID: "instance-7", scopeName: "sr.scope"}
	if got := metricPointAttributesHash(attrs, identity); got != "94d9dd949b532a243809a41937972918" {
		t.Fatalf("cross-language hash mismatch: got %s, want 94d9dd949b532a243809a41937972918", got)
	}
}
