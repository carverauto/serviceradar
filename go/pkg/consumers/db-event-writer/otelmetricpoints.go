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
//   - attributes are serialized as sorted-key JSON (every nesting level)
//     for display, matching Jason's encoding of a key-sorted ordered object;
//   - attributes_hash follows hash recipe v2: lowercase-hex md5 of
//     canonicalBytes(pointAttributes) + "\n" + serviceInstanceID + "\n" +
//     scopeName, where canonicalBytes is the deterministic, type-preserving
//     encoding implemented by writeCanonicalHashValue (NOT the display JSON:
//     floats encode as "f" + big-endian float bits hex, bytes as "b" +
//     base64, so 42 and 42.0 hash differently);
//   - timestamps truncate time_unix_nano to microseconds, matching
//     DateTime.from_unix!(div(ns, 1000), :microsecond);
//   - service_name defaults to "" (resource "service.name" then
//     "service_name"), service_instance_id to "" (resource
//     "service.instance.id"), and scope_name to "" (instrumentation scope
//     name), matching the Elixir processor and the column defaults;
//   - start_time_unix_nano is NULL when the point carries no start time;
//   - temporality serializes as "delta"/"cumulative"/"unspecified".
//
// Exponential histogram and summary points are not decoded yet (spec'd
// follow-up); they are counted in the metrics rejected counter instead of
// being silently dropped.

import (
	"bytes"
	"context"
	"crypto/md5" //nolint:gosec // non-cryptographic content hash, must match Elixir :crypto.hash(:md5, _)
	"encoding/base64"
	"encoding/binary"
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

	// Per-message attribution: headers ride the JetStream message, not the batch.
	stampMetricPointRows(rows, ingestAttributionFromMsg(msg))

	return rows, true
}

// metricPointIdentity carries the resource/scope identity fields that feed
// both the row columns and the recipe-v2 attributes hash. All fields default
// to "", matching the Elixir processor and the column defaults.
type metricPointIdentity struct {
	serviceName       string
	serviceInstanceID string
	scopeName         string
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

	identity := metricPointIdentity{
		serviceName:       stringAttr(resourceAttrs, "service.name", "service_name"),
		serviceInstanceID: stringAttr(resourceAttrs, "service.instance.id"),
	}

	var rows []models.OTELMetricPointRow

	for _, scopeMetric := range resourceMetric.ScopeMetrics {
		if scopeMetric == nil {
			continue
		}

		scopeIdentity := identity

		scopeIdentity.scopeName = ""
		if scopeMetric.Scope != nil {
			scopeIdentity.scopeName = scopeMetric.Scope.Name
		}

		for _, metric := range scopeMetric.Metrics {
			rows = append(rows, p.metricPointRows(metric, scopeIdentity)...)
		}
	}

	return rows
}

// metricPointRows converts one metric into data-point rows. Exponential
// histogram and summary points are counted as rejected (decode is a spec'd
// follow-up) instead of silently dropped.
func (p *Processor) metricPointRows(metric *metricspbv1.Metric, identity metricPointIdentity) []models.OTELMetricPointRow {
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

			row := numberPointRow(point, metric.Name, metricTypeSum, unit, identity)
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

			rows = append(rows, numberPointRow(point, metric.Name, metricTypeGauge, unit, identity))
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

			row := histogramPointRow(point, metric.Name, unit, identity)
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
	identity metricPointIdentity,
) models.OTELMetricPointRow {
	row := baseMetricPointRow(metricName, metricType, unit, identity, point.Attributes, point.TimeUnixNano, point.StartTimeUnixNano)

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
	identity metricPointIdentity,
) models.OTELMetricPointRow {
	row := baseMetricPointRow(
		metricName, metricTypeHistogram, unit, identity, point.Attributes, point.TimeUnixNano, point.StartTimeUnixNano)

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
	identity metricPointIdentity,
	attrs []*commonv1.KeyValue,
	timeUnixNano, startTimeUnixNano uint64,
) models.OTELMetricPointRow {
	row := models.OTELMetricPointRow{
		Timestamp:         metricPointTimestamp(timeUnixNano),
		MetricName:        metricName,
		MetricType:        metricType,
		Unit:              unit,
		ServiceName:       identity.serviceName,
		ServiceInstanceID: identity.serviceInstanceID,
		ScopeName:         identity.scopeName,
		Attributes:        canonicalAttributesJSON(attrs),
		AttributesHash:    metricPointAttributesHash(attrs, identity),
	}

	// NULL when the point carried no start time (0 in OTLP).
	if startTimeUnixNano != 0 {
		startTime := safeUint64ToInt64(startTimeUnixNano)
		row.StartTimeUnixNano = &startTime
	}

	return row
}

// metricPointAttributesHash implements hash recipe v2 shared with the Elixir
// EventWriter: lowercase-hex md5 of canonicalBytes(pointAttributes) + "\n" +
// serviceInstanceID + "\n" + scopeName.
func metricPointAttributesHash(attrs []*commonv1.KeyValue, identity metricPointIdentity) string {
	var buf bytes.Buffer

	writeCanonicalHashValue(&buf, attrsToCanonicalMap(attrs))
	buf.WriteByte('\n')
	buf.WriteString(identity.serviceInstanceID)
	buf.WriteByte('\n')
	buf.WriteString(identity.scopeName)

	return md5Hex(buf.String())
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

// attrsToCanonicalMap converts OTLP KeyValue pairs into the type-preserving
// value tree that feeds the recipe-v2 canonical encoding. Unlike attrsToMap
// (display JSON), bytes values stay []byte so they encode as "b" + base64
// instead of a plain JSON string. Empty keys are skipped and duplicate keys
// last-win, identical to attrsToMap, so the hash and the display JSON always
// describe the same attribute set.
func attrsToCanonicalMap(attrs []*commonv1.KeyValue) map[string]interface{} {
	result := make(map[string]interface{}, len(attrs))

	for _, attr := range attrs {
		if attr == nil || attr.Key == "" {
			continue
		}

		result[attr.Key] = anyValueToCanonical(attr.Value)
	}

	return result
}

// anyValueToCanonical converts an OTLP AnyValue into a canonical-encoding
// value: string, bool, int64, float64, []byte, []interface{}, or
// map[string]interface{}. Unset values become nil. Int-valued attributes
// stay int64 and double-valued stay float64 so 42 and 42.0 hash differently
// by design.
func anyValueToCanonical(value *commonv1.AnyValue) interface{} {
	if value == nil {
		return nil
	}

	switch v := value.Value.(type) {
	case *commonv1.AnyValue_StringValue:
		return v.StringValue
	case *commonv1.AnyValue_BoolValue:
		return v.BoolValue
	case *commonv1.AnyValue_IntValue:
		return v.IntValue
	case *commonv1.AnyValue_DoubleValue:
		return v.DoubleValue
	case *commonv1.AnyValue_BytesValue:
		return v.BytesValue
	case *commonv1.AnyValue_ArrayValue:
		if v.ArrayValue == nil {
			return []interface{}{}
		}

		items := make([]interface{}, 0, len(v.ArrayValue.Values))
		for _, item := range v.ArrayValue.Values {
			items = append(items, anyValueToCanonical(item))
		}

		return items
	case *commonv1.AnyValue_KvlistValue:
		if v.KvlistValue == nil {
			return map[string]interface{}{}
		}

		return attrsToCanonicalMap(v.KvlistValue.Values)
	default:
		return nil
	}
}

// writeCanonicalHashValue renders a canonical value tree as the recipe-v2
// canonical bytes shared with the Elixir EventWriter. Rules (applied
// recursively at every nesting level):
//
//	map    → "{" + entries sorted by key bytes, enc(key)+":"+enc(value)
//	         joined by "," + "}"
//	string → '"' + value escaping ONLY backslash and double-quote + '"'
//	bool   → true/false; nil → null; int64 → base-10
//	float  → "f" + 16-char lowercase hex of big-endian Float64bits
//	         (no decimal text, so formatting differences cannot diverge)
//	bytes  → "b" + std base64
//	array  → "[" + items joined by "," + "]"
func writeCanonicalHashValue(buf *bytes.Buffer, value interface{}) {
	switch typed := value.(type) {
	case nil:
		buf.WriteString("null")
	case bool:
		buf.WriteString(strconv.FormatBool(typed))
	case string:
		writeCanonicalHashString(buf, typed)
	case int64:
		buf.WriteString(strconv.FormatInt(typed, 10))
	case float64:
		var bits [8]byte

		binary.BigEndian.PutUint64(bits[:], math.Float64bits(typed))
		buf.WriteByte('f')
		buf.WriteString(hex.EncodeToString(bits[:]))
	case []byte:
		buf.WriteByte('b')
		buf.WriteString(base64.StdEncoding.EncodeToString(typed))
	case []interface{}:
		buf.WriteByte('[')

		for i, item := range typed {
			if i > 0 {
				buf.WriteByte(',')
			}

			writeCanonicalHashValue(buf, item)
		}

		buf.WriteByte(']')
	case map[string]interface{}:
		keys := make([]string, 0, len(typed))
		for key := range typed {
			keys = append(keys, key)
		}

		// sort.Strings compares bytewise, satisfying "sorted by key bytes".
		sort.Strings(keys)

		buf.WriteByte('{')

		for i, key := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}

			writeCanonicalHashString(buf, key)
			buf.WriteByte(':')
			writeCanonicalHashValue(buf, typed[key])
		}

		buf.WriteByte('}')
	default:
		// anyValueToCanonical only produces the types above; degrade to null
		// rather than silently skip input.
		buf.WriteString("null")
	}
}

// writeCanonicalHashString writes the recipe-v2 string form: double-quoted,
// escaping ONLY backslash and double-quote (control characters and non-ASCII
// bytes pass through verbatim, unlike JSON).
func writeCanonicalHashString(buf *bytes.Buffer, value string) {
	buf.WriteByte('"')

	for i := 0; i < len(value); i++ {
		char := value[i]
		if char == '\\' || char == '"' {
			buf.WriteByte('\\')
		}

		buf.WriteByte(char)
	}

	buf.WriteByte('"')
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
