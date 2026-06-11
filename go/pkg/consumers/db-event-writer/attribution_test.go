package dbeventwriter

import (
	"testing"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/require"
	logsv1 "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	metricsv1 "go.opentelemetry.io/proto/otlp/collector/metrics/v1"
	tracev1 "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	logspbv1 "go.opentelemetry.io/proto/otlp/logs/v1"
	metricspbv1 "go.opentelemetry.io/proto/otlp/metrics/v1"
	tracepbv1 "go.opentelemetry.io/proto/otlp/trace/v1"
	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// attributionMsg is a minimal jetstream.Msg fake for header->column mapping
// tests. Only Subject, Data, and Headers are implemented; the embedded nil
// interface panics on anything else, which would flag an unexpected call.
type attributionMsg struct {
	jetstream.Msg

	subject string
	data    []byte
	header  nats.Header
}

func (m *attributionMsg) Subject() string      { return m.subject }
func (m *attributionMsg) Data() []byte         { return m.data }
func (m *attributionMsg) Headers() nats.Header { return m.header }

func attributedHeader() nats.Header {
	header := nats.Header{}
	header.Set(headerIngestIdentity, "spiffe://serviceradar/agent/edge-01")
	header.Set(headerIngestAgentID, "edge-01")
	header.Set(headerIngestPartition, "site-a")

	return header
}

func requireAttributed(t *testing.T, identity, agentID, partition string) {
	t.Helper()

	require.Equal(t, "spiffe://serviceradar/agent/edge-01", identity)
	require.Equal(t, "edge-01", agentID)
	require.Equal(t, "site-a", partition)
}

func TestIngestAttributionFromMsg(t *testing.T) {
	t.Run("headers present", func(t *testing.T) {
		attribution := ingestAttributionFromMsg(&attributionMsg{header: attributedHeader()})

		requireAttributed(t, attribution.identity, attribution.agentID, attribution.partition)
	})

	t.Run("nil header map", func(t *testing.T) {
		attribution := ingestAttributionFromMsg(&attributionMsg{})

		require.Equal(t, ingestAttribution{}, attribution)
	})

	t.Run("absent keys map to empty strings", func(t *testing.T) {
		header := nats.Header{}
		header.Set("Unrelated-Header", "x")

		attribution := ingestAttributionFromMsg(&attributionMsg{header: header})

		require.Equal(t, ingestAttribution{}, attribution)
	})
}

func tracesPayload(t *testing.T) []byte {
	t.Helper()

	payload, err := proto.Marshal(&tracev1.ExportTraceServiceRequest{
		ResourceSpans: []*tracepbv1.ResourceSpans{
			{
				ScopeSpans: []*tracepbv1.ScopeSpans{
					{
						Spans: []*tracepbv1.Span{
							{
								TraceId: []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
								SpanId:  []byte{1, 2, 3, 4, 5, 6, 7, 8},
								Name:    "edge-span",
							},
						},
					},
				},
			},
		},
	})
	require.NoError(t, err)

	return payload
}

func logsPayload(t *testing.T) []byte {
	t.Helper()

	payload, err := proto.Marshal(&logsv1.ExportLogsServiceRequest{
		ResourceLogs: []*logspbv1.ResourceLogs{
			{
				ScopeLogs: []*logspbv1.ScopeLogs{
					{
						LogRecords: []*logspbv1.LogRecord{
							{SeverityText: "INFO"},
						},
					},
				},
			},
		},
	})
	require.NoError(t, err)

	return payload
}

func metricsPayload(t *testing.T) []byte {
	t.Helper()

	payload, err := proto.Marshal(&metricsv1.ExportMetricsServiceRequest{
		ResourceMetrics: []*metricspbv1.ResourceMetrics{
			{
				ScopeMetrics: []*metricspbv1.ScopeMetrics{
					{
						Metrics: []*metricspbv1.Metric{
							{
								Name: "edge_metric",
								Data: &metricspbv1.Metric_Gauge{
									Gauge: &metricspbv1.Gauge{
										DataPoints: []*metricspbv1.NumberDataPoint{
											{
												TimeUnixNano: pointTimeUnixNano,
												Value:        &metricspbv1.NumberDataPoint_AsDouble{AsDouble: 1.5},
											},
										},
									},
								},
							},
						},
					},
				},
			},
		},
	})
	require.NoError(t, err)

	return payload
}

func TestParseOTELTracesStampsIngestAttribution(t *testing.T) {
	p := &Processor{logger: logger.NewTestLogger()}

	rows, ok := p.parseOTELTraces(&attributionMsg{
		subject: "otel.traces",
		data:    tracesPayload(t),
		header:  attributedHeader(),
	})
	require.True(t, ok)
	require.Len(t, rows, 1)

	requireAttributed(t, rows[0].IngestIdentity, rows[0].IngestAgentID, rows[0].IngestPartition)
}

func TestParseOTELTracesAbsentHeadersStayEmpty(t *testing.T) {
	p := &Processor{logger: logger.NewTestLogger()}

	rows, ok := p.parseOTELTraces(&attributionMsg{subject: "otel.traces", data: tracesPayload(t)})
	require.True(t, ok)
	require.Len(t, rows, 1)

	require.Empty(t, rows[0].IngestIdentity)
	require.Empty(t, rows[0].IngestAgentID)
	require.Empty(t, rows[0].IngestPartition)
}

func TestParseOTELMessageStampsIngestAttributionProtobuf(t *testing.T) {
	p := &Processor{logger: logger.NewTestLogger()}

	rows, ok := p.parseOTELMessage(&attributionMsg{
		subject: "otel.logs",
		data:    logsPayload(t),
		header:  attributedHeader(),
	})
	require.True(t, ok)
	require.Len(t, rows, 1)

	requireAttributed(t, rows[0].IngestIdentity, rows[0].IngestAgentID, rows[0].IngestPartition)
}

func TestParseOTELMessageStampsIngestAttributionJSON(t *testing.T) {
	p := &Processor{logger: logger.NewTestLogger()}

	rows, ok := p.parseOTELMessage(&attributionMsg{
		subject: "events.syslog",
		data:    []byte(`{"timestamp":"2026-06-10T12:00:00Z","body":"edge log line","severity_text":"INFO"}`),
		header:  attributedHeader(),
	})
	require.True(t, ok)
	require.Len(t, rows, 1)

	requireAttributed(t, rows[0].IngestIdentity, rows[0].IngestAgentID, rows[0].IngestPartition)
}

func TestParseOTELMetricsStampsIngestAttribution(t *testing.T) {
	p := &Processor{logger: logger.NewTestLogger()}

	rows, ok := p.parseOTELMetrics(&attributionMsg{
		subject: "otel.metrics",
		data:    metricsPayload(t),
		header:  attributedHeader(),
	})
	require.True(t, ok)
	require.Len(t, rows, 1)

	requireAttributed(t, rows[0].IngestIdentity, rows[0].IngestAgentID, rows[0].IngestPartition)
}

func TestParsePerformanceMessageStampsIngestAttribution(t *testing.T) {
	p := &Processor{logger: logger.NewTestLogger()}

	rows, ok := p.parsePerformanceMessage(&attributionMsg{
		subject: "metrics.performance",
		data: []byte(`[{"timestamp":"2026-06-10T12:00:00Z","trace_id":"t","span_id":"s",` +
			`"service_name":"svc","span_name":"op","span_kind":"server","duration_ms":1.0,` +
			`"duration_seconds":0.001,"metric_type":"performance","is_slow":false,` +
			`"component":"c","level":"info"}]`),
		header: attributedHeader(),
	})
	require.True(t, ok)
	require.Len(t, rows, 1)

	requireAttributed(t, rows[0].IngestIdentity, rows[0].IngestAgentID, rows[0].IngestPartition)
}

func TestParseOTELMetricPointsStampsIngestAttribution(t *testing.T) {
	p := &Processor{logger: logger.NewTestLogger()}

	rows, ok := p.parseOTELMetricPoints(&attributionMsg{
		subject: "otel.metrics.raw",
		data:    metricsPayload(t),
		header:  attributedHeader(),
	})
	require.True(t, ok)
	require.Len(t, rows, 1)

	requireAttributed(t, rows[0].IngestIdentity, rows[0].IngestAgentID, rows[0].IngestPartition)
}

// TestAttributionIsPerMessageNotPerBatch parses two messages with different
// headers through the same processor and asserts each message's rows carry
// its own attribution (headers must never leak across a batch).
func TestAttributionIsPerMessageNotPerBatch(t *testing.T) {
	p := &Processor{logger: logger.NewTestLogger()}

	first, ok := p.parseOTELTraces(&attributionMsg{
		subject: "otel.traces",
		data:    tracesPayload(t),
		header:  attributedHeader(),
	})
	require.True(t, ok)
	require.Len(t, first, 1)

	second, ok := p.parseOTELTraces(&attributionMsg{subject: "otel.traces", data: tracesPayload(t)})
	require.True(t, ok)
	require.Len(t, second, 1)

	requireAttributed(t, first[0].IngestIdentity, first[0].IngestAgentID, first[0].IngestPartition)
	require.Empty(t, second[0].IngestIdentity)
	require.Empty(t, second[0].IngestAgentID)
	require.Empty(t, second[0].IngestPartition)
}
