package dbeventwriter

// Real OTLP metric data points (refactor-otel-signal-correlation, 8.2).
//
// Decodes ExportMetricsServiceRequest payloads from `otel.metrics.raw` into
// rows for the `otel_metric_points` hypertable, mirroring
// ServiceRadar.EventWriter.Processors.OtelMetrics so that both writers
// produce identical primary keys (timestamp, metric_name, service_name,
// attributes_hash) for identical input and double-ingest dedupes via
// ON CONFLICT DO NOTHING:
//
//   - attributes are serialized as sorted-key JSON (every nesting level),
//     matching Jason's encoding of a key-sorted ordered object;
//   - attributes_hash is the lowercase-hex md5 of that exact JSON text;
//   - timestamps truncate time_unix_nano to microseconds, matching
//     DateTime.from_unix!(div(ns, 1000), :microsecond);
//   - service_name defaults to "" (resource "service.name" then
//     "service_name"), matching the Elixir processor and the column default;
//   - temporality serializes as "delta"/"cumulative"/"unspecified".
//
// Exponential histogram and summary points are not decoded yet (spec'd
// follow-up); they are counted in the metrics rejected counter instead of
// being silently dropped.

import (
	"bytes"
	"context"
	"crypto/md5" //nolint:gosec // non-cryptographic content hash, must match Elixir :crypto.hash(:md5, _)
	"encoding/hex"
	"encoding/json"
	"math"
	"sort"
	"strconv"
	"time"

	"github.com/nats-io/nats.go/jetstream"
	commonv1 "go.opentelemetry.io/proto/otlp/common/v1"
	metricspbv1 "go.opentelemetry.io/proto/otlp/metrics/v1"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

// Metric point type/temporality strings shared with the Elixir writer.
const (
	metricTypeSum       = "sum"
	metricTypeGauge     = "gauge"
	metricTypeHistogram = "histogram"

	temporalityDelta       = "delta"
	temporalityCumulative  = "cumulative"
	temporalityUnspecified = "unspecified"
)

// processMetricPointsTable handles otel_metric_points batch processing.
func (p *Processor) processMetricPointsTable(ctx context.Context, table string, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	return processOTELTable(
		ctx,
		p.logger,
		table,
		msgs,
		p.parseOTELMetricPoints,
		p.db.InsertOTELMetricPoints,
		"Skipping malformed OTEL metric points message",
		"Inserted OTEL metric points into CNPG",
		&metricCounters,
	)
}

// parseOTELMetricPoints decodes an ExportMetricsServiceRequest into
// otel_metric_points rows.
func (p *Processor) parseOTELMetricPoints(msg jetstream.Msg) ([]models.OTELMetricPointRow, bool) {
	req, err := p.parseMetricsRequest(msg.Data())
	if err != nil {
		p.logger.Debug().
			Err(err).
			Str("subject", msg.Subject()).
			Msg("Failed to parse OTLP metrics protobuf for metric points")

		return nil, false
	}

	var rows []models.OTELMetricPointRow

	for _, resourceMetric := range req.ResourceMetrics {
		rows = append(rows, p.metricPointRowsForResource(resourceMetric)...)
	}

	metricCounters.received.Add(int64(len(rows)))

	return rows, true
}

// metricPointRowsForResource walks one ResourceMetrics subtree. A nil
// resource is processed with empty attributes and service_name "" instead of
// being skipped, matching the Elixir processor.
func (p *Processor) metricPointRowsForResource(resourceMetric *metricspbv1.ResourceMetrics) []models.OTELMetricPointRow {
	if resourceMetric == nil {
		return nil
	}

	resourceAttrs := map[string]interface{}{}
	if resourceMetric.Resource != nil {
		resourceAttrs = attrsToMap(resourceMetric.Resource.Attributes)
	}

	serviceName := stringAttr(resourceAttrs, "service.name", "service_name")

	var rows []models.OTELMetricPointRow

	for _, scopeMetric := range resourceMetric.ScopeMetrics {
		if scopeMetric == nil {
			continue
		}

		for _, metric := range scopeMetric.Metrics {
			rows = append(rows, p.metricPointRows(metric, serviceName)...)
		}
	}

	return rows
}

// metricPointRows converts one metric into data-point rows. Exponential
// histogram and summary points are counted as rejected (decode is a spec'd
// follow-up) instead of silently dropped.
func (p *Processor) metricPointRows(metric *metricspbv1.Metric, serviceName string) []models.OTELMetricPointRow {
	if metric == nil {
		return nil
	}

	unit := optionalString(metric.Unit)

	switch data := metric.Data.(type) {
	case *metricspbv1.Metric_Sum:
		if data.Sum == nil {
			return nil
		}

		temporality := temporalityString(data.Sum.AggregationTemporality)
		isMonotonic := data.Sum.IsMonotonic
		rows := make([]models.OTELMetricPointRow, 0, len(data.Sum.DataPoints))

		for _, point := range data.Sum.DataPoints {
			if point == nil {
				continue
			}

			row := numberPointRow(point, metric.Name, metricTypeSum, unit, serviceName)
			row.Temporality = &temporality
			row.IsMonotonic = &isMonotonic
			rows = append(rows, row)
		}

		return rows
	case *metricspbv1.Metric_Gauge:
		if data.Gauge == nil {
			return nil
		}

		rows := make([]models.OTELMetricPointRow, 0, len(data.Gauge.DataPoints))

		for _, point := range data.Gauge.DataPoints {
			if point == nil {
				continue
			}

			rows = append(rows, numberPointRow(point, metric.Name, metricTypeGauge, unit, serviceName))
		}

		return rows
	case *metricspbv1.Metric_Histogram:
		if data.Histogram == nil {
			return nil
		}

		temporality := temporalityString(data.Histogram.AggregationTemporality)
		rows := make([]models.OTELMetricPointRow, 0, len(data.Histogram.DataPoints))

		for _, point := range data.Histogram.DataPoints {
			if point == nil {
				continue
			}

			row := histogramPointRow(point, metric.Name, unit, serviceName)
			row.Temporality = &temporality
			rows = append(rows, row)
		}

		return rows
	case *metricspbv1.Metric_ExponentialHistogram:
		points := 0
		if data.ExponentialHistogram != nil {
			points = len(data.ExponentialHistogram.DataPoints)
		}

		p.countUnsupportedMetricPoints(metric.Name, "exponential_histogram", points)

		return nil
	case *metricspbv1.Metric_Summary:
		points := 0
		if data.Summary != nil {
			points = len(data.Summary.DataPoints)
		}

		p.countUnsupportedMetricPoints(metric.Name, "summary", points)

		return nil
	default:
		return nil
	}
}

// countUnsupportedMetricPoints records data points of metric types that are
// not decoded yet so they show up in pipeline accounting instead of
// disappearing silently.
func (p *Processor) countUnsupportedMetricPoints(metricName, metricType string, points int) {
	if points == 0 {
		points = 1 // a typeless metric still represents one dropped signal
	}

	metricCounters.rejected.Add(int64(points))

	p.logger.Debug().
		Str("metric_name", metricName).
		Str("metric_type", metricType).
		Int("data_points", points).
		Msg("Dropping OTLP metric data points of unsupported type (decode is a spec'd follow-up)")
}

func numberPointRow(
	point *metricspbv1.NumberDataPoint,
	metricName, metricType string,
	unit *string,
	serviceName string,
) models.OTELMetricPointRow {
	row := baseMetricPointRow(metricName, metricType, unit, serviceName, point.Attributes, point.TimeUnixNano)

	switch value := point.Value.(type) {
	case *metricspbv1.NumberDataPoint_AsDouble:
		v := value.AsDouble
		row.Value = &v
	case *metricspbv1.NumberDataPoint_AsInt:
		v := float64(value.AsInt)
		row.Value = &v
	}

	return row
}

func histogramPointRow(
	point *metricspbv1.HistogramDataPoint,
	metricName string,
	unit *string,
	serviceName string,
) models.OTELMetricPointRow {
	row := baseMetricPointRow(metricName, metricTypeHistogram, unit, serviceName, point.Attributes, point.TimeUnixNano)

	count := safeUint64ToInt64(point.Count)
	row.Count = &count
	row.Sum = point.Sum

	bucketCounts := encodeJSONUints(point.BucketCounts)
	row.BucketCounts = &bucketCounts

	explicitBounds := encodeJSONFloats(point.ExplicitBounds)
	row.ExplicitBounds = &explicitBounds

	return row
}

func baseMetricPointRow(
	metricName, metricType string,
	unit *string,
	serviceName string,
	attrs []*commonv1.KeyValue,
	timeUnixNano uint64,
) models.OTELMetricPointRow {
	attributesJSON := canonicalAttributesJSON(attrs)

	return models.OTELMetricPointRow{
		Timestamp:      metricPointTimestamp(timeUnixNano),
		MetricName:     metricName,
		MetricType:     metricType,
		Unit:           unit,
		ServiceName:    serviceName,
		Attributes:     attributesJSON,
		AttributesHash: md5Hex(attributesJSON),
	}
}

// metricPointTimestamp truncates time_unix_nano to microsecond precision,
// matching DateTime.from_unix!(div(ns, 1000), :microsecond) in the Elixir
// writer so identical points hash to identical primary keys.
func metricPointTimestamp(timeUnixNano uint64) time.Time {
	if timeUnixNano == 0 {
		return time.Now().UTC()
	}

	return time.UnixMicro(int64(timeUnixNano / 1000)).UTC() //nolint:gosec // division keeps the value within int64 range
}

func temporalityString(temporality metricspbv1.AggregationTemporality) string {
	switch temporality {
	case metricspbv1.AggregationTemporality_AGGREGATION_TEMPORALITY_DELTA:
		return temporalityDelta
	case metricspbv1.AggregationTemporality_AGGREGATION_TEMPORALITY_CUMULATIVE:
		return temporalityCumulative
	default:
		return temporalityUnspecified
	}
}

func optionalString(value string) *string {
	if value == "" {
		return nil
	}

	return &value
}

func md5Hex(text string) string {
	digest := md5.Sum([]byte(text)) //nolint:gosec // content hash for dedupe, mirrors Elixir md5_hex/1
	return hex.EncodeToString(digest[:])
}

// canonicalAttributesJSON renders OTLP attributes as deterministic JSON with
// keys sorted at every nesting level, byte-compatible with the Elixir
// writer's encode_point_attributes/1 (Jason over a key-sorted ordered
// object) for the value types OTLP produces. Strings are encoded without
// HTML escaping (Jason does not escape <, >, &); floats always carry a
// fractional digit ("42.0", not "42") like Erlang's shortest float
// formatting. Extreme float magnitudes that Jason renders in exponent
// notation may still differ textually; metric labels are overwhelmingly
// strings, ints, and bools, where the encodings are identical.
func canonicalAttributesJSON(attrs []*commonv1.KeyValue) string {
	var buf bytes.Buffer

	writeCanonicalJSON(&buf, attrsToMap(attrs))

	return buf.String()
}

func writeCanonicalJSON(buf *bytes.Buffer, value interface{}) {
	switch typed := value.(type) {
	case nil:
		buf.WriteString("null")
	case bool:
		buf.WriteString(strconv.FormatBool(typed))
	case string:
		writeCanonicalJSONString(buf, typed)
	case int64:
		buf.WriteString(strconv.FormatInt(typed, 10))
	case float64:
		buf.WriteString(canonicalJSONFloat(typed))
	case []interface{}:
		buf.WriteByte('[')

		for i, item := range typed {
			if i > 0 {
				buf.WriteByte(',')
			}

			writeCanonicalJSON(buf, item)
		}

		buf.WriteByte(']')
	case map[string]interface{}:
		keys := make([]string, 0, len(typed))
		for key := range typed {
			keys = append(keys, key)
		}

		sort.Strings(keys)

		buf.WriteByte('{')

		for i, key := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}

			writeCanonicalJSONString(buf, key)
			buf.WriteByte(':')
			writeCanonicalJSON(buf, typed[key])
		}

		buf.WriteByte('}')
	default:
		// attrsToMap only produces the types above; degrade to null rather
		// than emit invalid JSON.
		buf.WriteString("null")
	}
}

// writeCanonicalJSONString encodes a JSON string without HTML escaping so
// "<", ">", and "&" stay literal, matching Jason's default escaping.
func writeCanonicalJSONString(buf *bytes.Buffer, value string) {
	encoder := json.NewEncoder(buf)
	encoder.SetEscapeHTML(false)

	if err := encoder.Encode(value); err != nil {
		buf.WriteString(`""`)
		return
	}

	// json.Encoder.Encode appends a trailing newline; drop it.
	buf.Truncate(buf.Len() - 1)
}

// canonicalJSONFloat formats a float the way Jason/Erlang shortest-float
// formatting does for the common range: integral values keep one fractional
// digit ("42.0"), everything else uses the shortest round-trip form.
// Non-finite values (invalid JSON; Jason raises) degrade to null.
func canonicalJSONFloat(value float64) string {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return "null"
	}

	if value == math.Trunc(value) && math.Abs(value) < 1e15 {
		return strconv.FormatFloat(value, 'f', 1, 64)
	}

	return strconv.FormatFloat(value, 'g', -1, 64)
}

// encodeJSONUints renders bucket counts as a JSON array ("[]" when empty),
// matching Jason.encode!(bucket_counts || []).
func encodeJSONUints(values []uint64) string {
	var buf bytes.Buffer

	buf.WriteByte('[')

	for i, value := range values {
		if i > 0 {
			buf.WriteByte(',')
		}

		buf.WriteString(strconv.FormatUint(value, 10))
	}

	buf.WriteByte(']')

	return buf.String()
}

// encodeJSONFloats renders explicit bounds as a JSON array ("[]" when
// empty) using the same float formatting as attribute values, matching
// Jason.encode!(explicit_bounds || []) ("[10.0,100.0]").
func encodeJSONFloats(values []float64) string {
	var buf bytes.Buffer

	buf.WriteByte('[')

	for i, value := range values {
		if i > 0 {
			buf.WriteByte(',')
		}

		buf.WriteString(canonicalJSONFloat(value))
	}

	buf.WriteByte(']')

	return buf.String()
}
