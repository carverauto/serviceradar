package agent

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	srproto "github.com/carverauto/serviceradar/proto"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/proto"
)

func TestMarshalSysmonMetricEnvelope(t *testing.T) {
	t.Parallel()

	partition := defaultPartition
	payload, err := marshalSysmonMetricEnvelope(&sysmon.MetricSample{
		Timestamp: "2026-06-12T00:00:00Z",
		HostID:    "host-1",
		HostIP:    "10.0.0.10",
		Partition: &partition,
		AgentID:   "agent-1",
		CPUs: []sysmon.CPUMetric{
			{CoreID: 0, UsagePercent: 12.5},
		},
		Memory: sysmon.MemoryMetric{UsedBytes: 50, TotalBytes: 100},
		Network: []sysmon.NetworkMetric{
			{Interface: "eth0", BytesSent: 1000, BytesRecv: 2000, PacketsSent: 10, PacketsRecv: 20},
		},
		ProcessCount: 42,
		Processes: []sysmon.ProcessMetric{
			{
				PID:         1234,
				Name:        "nginx",
				CPUUsage:    2.5,
				MemoryUsage: 104857600,
				Status:      "Running",
				StartTime:   "2026-06-11T23:00:00Z",
			},
		},
	}, metricEnvelopeContext{AgentID: "agent-fallback", GatewayID: "gateway-1", Partition: "fallback"})
	require.NoError(t, err)

	batch := decodeMetricBatch(t, payload)
	require.Equal(t, metricEnvelopeSchemaVersion, batch.SchemaVersion)
	require.Equal(t, "agent-1", batch.Resource.AgentId)
	require.Equal(t, "gateway-1", batch.Resource.GatewayId)
	require.Equal(t, "sysmon-metrics", batch.IngestIdentity.Source)

	metrics := metricsByName(batch)
	require.Equal(t, metricpb.MetricKind_METRIC_KIND_GAUGE, metrics["memory.used_percent"].Kind)
	require.InDelta(t, 50.0, metrics["memory.used_percent"].Points[0].Value, 1e-9)
	require.Equal(t, metricpb.MetricKind_METRIC_KIND_SUM, metrics["network.bytes_sent"].Kind)
	require.Equal(t, metricpb.MetricTemporality_METRIC_TEMPORALITY_CUMULATIVE, metrics["network.bytes_sent"].Temporality)
	require.True(t, metrics["network.bytes_sent"].IsMonotonic)
	require.Equal(t, uint32(64), metrics["network.bytes_sent"].CounterWidth)
	require.InDelta(t, 42.0, metrics["process.count"].Points[0].Value, 1e-9)

	processCPU := metrics["process.cpu_usage"]
	require.NotNil(t, processCPU)
	require.Equal(t, "sysmon.process", processCPU.MetricType)
	require.InDelta(t, 2.5, processCPU.Points[0].Value, 1e-9)
	require.Equal(t, "1234", entry(processCPU.Points[0].Attributes, "pid"))
	require.Equal(t, "nginx", entry(processCPU.Points[0].Attributes, "name"))
	require.Equal(t, "Running", entry(processCPU.Points[0].Attributes, "status"))

	processMemory := metrics["process.memory_usage"]
	require.NotNil(t, processMemory)
	require.Equal(t, metricpb.MetricValueType_METRIC_VALUE_TYPE_UINT64, processMemory.Points[0].RawValueType)
	require.Equal(t, "104857600", processMemory.Points[0].RawValue)
}

func TestMarshalSysmonMetricEnvelopeFallsBackToProcessListLength(t *testing.T) {
	t.Parallel()

	payload, err := marshalSysmonMetricEnvelope(&sysmon.MetricSample{
		Timestamp: "2026-06-12T00:00:00Z",
		HostID:    "host-1",
		HostIP:    "10.0.0.10",
		Processes: []sysmon.ProcessMetric{
			{PID: 1, Name: "init"},
			{PID: 2, Name: "agent"},
		},
	}, metricEnvelopeContext{AgentID: "agent-1", GatewayID: "gateway-1", Partition: "default"})
	require.NoError(t, err)

	metrics := metricsByName(decodeMetricBatch(t, payload))
	require.InDelta(t, 2.0, metrics["process.count"].Points[0].Value, 1e-9)
}

func TestMarshalSysmonMetricEnvelopeBatchIncludesMultipleSamples(t *testing.T) {
	t.Parallel()

	partition := defaultPartition
	payload, err := marshalSysmonMetricEnvelopeBatch([]*sysmon.MetricSample{
		{
			Timestamp: "2026-06-12T00:00:00Z",
			HostID:    "host-1",
			HostIP:    "10.0.0.10",
			Partition: &partition,
			AgentID:   "agent-1",
			CPUs: []sysmon.CPUMetric{
				{CoreID: 0, UsagePercent: 12.5},
			},
		},
		{
			Timestamp: "2026-06-12T00:00:01Z",
			HostID:    "host-1",
			HostIP:    "10.0.0.10",
			Partition: &partition,
			AgentID:   "agent-1",
			CPUs: []sysmon.CPUMetric{
				{CoreID: 0, UsagePercent: 20.0},
			},
		},
	}, metricEnvelopeContext{AgentID: "agent-fallback", GatewayID: "gateway-1", Partition: "fallback"})
	require.NoError(t, err)

	batch := decodeMetricBatch(t, payload)
	require.Equal(t, metricEnvelopeSchemaVersion, batch.SchemaVersion)
	require.Equal(t, "sysmon-metrics", batch.IngestIdentity.Source)
	require.Len(t, batch.Metrics, 4)

	cpuMetrics := metricsByNameAndObservedAt(batch, "cpu.usage_percent")
	require.Len(t, cpuMetrics, 2)

	firstObservedAt := uint64(time.Date(2026, 6, 12, 0, 0, 0, 0, time.UTC).UnixNano())
	secondObservedAt := uint64(time.Date(2026, 6, 12, 0, 0, 1, 0, time.UTC).UnixNano())
	require.InDelta(t, 12.5, cpuMetrics[firstObservedAt].Points[0].Value, 1e-9)
	require.InDelta(t, 20.0, cpuMetrics[secondObservedAt].Points[0].Value, 1e-9)
}

func TestMarshalSNMPMetricEnvelopePreservesCounterSemantics(t *testing.T) {
	t.Parallel()

	ifIndex := 7
	payload, err := marshalSNMPMetricEnvelope([]snmpMetricResult{
		{
			Target:       "router-a",
			Host:         "10.0.0.20",
			Metric:       "ifHCInOctets",
			OID:          ".1.3.6.1.2.1.31.1.1.1.6.7",
			Value:        uint64(1234),
			RawValue:     uint64(1234),
			Timestamp:    time.Date(2026, 6, 12, 0, 0, 0, 0, time.UTC),
			DataType:     "counter",
			IfIndex:      &ifIndex,
			InterfaceUID: "ifindex:7",
		},
	}, metricEnvelopeContext{AgentID: "agent-1", GatewayID: "gateway-1", Partition: defaultPartition})
	require.NoError(t, err)

	batch := decodeMetricBatch(t, payload)
	require.Equal(t, "snmp-metrics", batch.IngestIdentity.Source)
	require.Len(t, batch.Metrics, 1)

	metric := batch.Metrics[0]
	require.Equal(t, "ifHCInOctets", metric.Name)
	require.Equal(t, "snmp", metric.MetricType)
	require.Equal(t, metricpb.MetricKind_METRIC_KIND_SUM, metric.Kind)
	require.Equal(t, metricpb.MetricTemporality_METRIC_TEMPORALITY_CUMULATIVE, metric.Temporality)
	require.True(t, metric.IsMonotonic)
	require.Equal(t, uint32(64), metric.CounterWidth)
	require.Equal(t, "10.0.0.20", entry(metric.Tags, "host"))

	point := metric.Points[0]
	require.InDelta(t, float64(1234), point.Value, 1e-9)
	require.Equal(t, "1234", point.RawValue)
	require.Equal(t, metricpb.MetricValueType_METRIC_VALUE_TYPE_UINT64, point.RawValueType)
	require.Equal(t, int32(7), point.IfIndex)
	require.Equal(t, "ifindex:7", point.InterfaceUid)
	require.Equal(t, "10.0.0.20", entry(point.Attributes, "host"))

	// The OID is metadata-only: it must stay observable but never feed the
	// series-key tags (which would fork the series per OID).
	require.Empty(t, entry(point.Attributes, "oid"))
	require.Equal(t, ".1.3.6.1.2.1.31.1.1.1.6.7", entry(point.Metadata, "oid"))
	require.Equal(t, ".1.3.6.1.2.1.31.1.1.1.6.7", entry(metric.Metadata, "oid"))
}

func TestMarshalSNMPMetricEnvelopeCarriesProfileIDInPointMetadata(t *testing.T) {
	t.Parallel()

	profileID := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	payload, err := marshalSNMPMetricEnvelope([]snmpMetricResult{
		{
			Target:    "clearpass-a",
			Host:      "10.0.0.8",
			Metric:    "node_version",
			OID:       ".1.3.6.1.4.1.14823.1.6.1.1.1.1.1.3.0",
			Value:     "6.11.15",
			RawValue:  "6.11.15",
			Timestamp: time.Date(2026, 8, 30, 0, 0, 0, 0, time.UTC),
			DataType:  "string",
			ProfileID: profileID,
		},
	}, metricEnvelopeContext{AgentID: "agent-1", GatewayID: "gateway-1", Partition: defaultPartition})
	require.NoError(t, err)

	batch := decodeMetricBatch(t, payload)
	require.Len(t, batch.Metrics, 1)

	point := batch.Metrics[0].Points[0]
	require.Equal(t, profileID, entry(point.Metadata, "snmp_profile_id"))
	require.Equal(t, "true", entry(point.Metadata, "non_numeric"))
	// Provenance must not fork the series: attributes feed the series key.
	require.Empty(t, entry(point.Attributes, "snmp_profile_id"))
}

func TestMarshalICMPMetricEnvelope(t *testing.T) {
	t.Parallel()

	payload, err := marshalICMPMetricEnvelope([]icmpCheckResult{
		{
			CheckID:        "check-1",
			CheckName:      "core-router",
			Target:         "10.0.0.30",
			DeviceID:       "sr:device-1",
			Available:      true,
			ResponseTimeNs: 12_345_678,
			PacketLoss:     0.25,
			Error:          "timeout waiting for reply",
			Timestamp:      time.Date(2026, 6, 12, 0, 0, 0, 0, time.UTC).UnixNano(),
		},
	}, metricEnvelopeContext{AgentID: "agent-1", GatewayID: "gateway-1", Partition: defaultPartition, KvStoreID: "kv-1"})
	require.NoError(t, err)

	batch := decodeMetricBatch(t, payload)
	require.Equal(t, metricEnvelopeSchemaVersion, batch.SchemaVersion)
	require.Equal(t, "icmp-metrics", batch.IngestIdentity.Source)
	require.Equal(t, "agent-icmp", batch.IngestIdentity.ProducerKind)
	require.Equal(t, "icmp_checks", batch.Resource.ServiceName)
	require.Equal(t, "icmp", batch.Resource.ServiceType)
	require.Equal(t, "kv-1", batch.Resource.KvStoreId)

	metrics := metricsByName(batch)
	require.Equal(t, metricpb.MetricKind_METRIC_KIND_GAUGE, metrics["icmp_response_time_ns"].Kind)
	require.Equal(t, "ns", metrics["icmp_response_time_ns"].Unit)
	require.InDelta(t, float64(12_345_678), metrics["icmp_response_time_ns"].Points[0].Value, 1e-9)
	require.Equal(t, "12345678", metrics["icmp_response_time_ns"].Points[0].RawValue)
	require.Equal(t, metricpb.MetricValueType_METRIC_VALUE_TYPE_INT64, metrics["icmp_response_time_ns"].Points[0].RawValueType)
	require.InDelta(t, 0.25, metrics["icmp_packet_loss"].Points[0].Value, 1e-9)
	require.InDelta(t, 1.0, metrics["icmp_available"].Points[0].Value, 1e-9)
	require.Equal(t, "true", metrics["icmp_available"].Points[0].RawValue)
	require.Equal(t, "check-1", entry(metrics["icmp_available"].Points[0].Attributes, "check_id"))
	require.Equal(t, "10.0.0.30", entry(metrics["icmp_available"].Points[0].Attributes, "target"))
	require.Equal(t, "sr:device-1", entry(metrics["icmp_available"].Points[0].Attributes, "device_id"))

	// The error string is observability-only: it must stay reachable via
	// metadata but never feed the series-key tags (which would fork the series
	// per distinct error message).
	for _, name := range []string{"icmp_response_time_ns", "icmp_packet_loss", "icmp_available"} {
		point := metrics[name].Points[0]
		require.Empty(t, entry(point.Attributes, "error"), name)
		require.Equal(t, "timeout waiting for reply", entry(point.Metadata, "error"), name)
	}
}

func TestMarshalMTRMetricEnvelope(t *testing.T) {
	t.Parallel()

	payload, err := marshalMTRMetricEnvelope([]mtrCheckResult{
		{
			CheckID:   "check-1",
			CheckName: "wan-path",
			Target:    "example.net",
			DeviceID:  "sr:device-1",
			Available: true,
			Timestamp: time.Date(2026, 6, 12, 0, 0, 0, 0, time.UTC).UnixNano(),
			Trace: &mtr.TraceResult{
				Target:        "example.net",
				TargetIP:      "203.0.113.10",
				TargetReached: true,
				TotalHops:     2,
				Protocol:      "icmp",
				IPVersion:     4,
				PacketSize:    64,
				Hops: []mtr.HopSnapshot{
					{
						HopNumber:            1,
						Addr:                 "192.0.2.1",
						Hostname:             "edge-router",
						Sent:                 10,
						Received:             10,
						LossPct:              0,
						LastUs:               1_200,
						AvgUs:                1_100,
						MinUs:                1_000,
						MaxUs:                1_300,
						StdDevUs:             20,
						JitterUs:             15,
						JitterWorstUs:        25,
						JitterInterarrivalUs: 12,
					},
				},
			},
		},
	}, metricEnvelopeContext{AgentID: "agent-1", GatewayID: "gateway-1", Partition: defaultPartition, KvStoreID: "kv-1"})
	require.NoError(t, err)

	batch := decodeMetricBatch(t, payload)
	require.Equal(t, metricEnvelopeSchemaVersion, batch.SchemaVersion)
	require.Equal(t, "mtr-metrics", batch.IngestIdentity.Source)
	require.Equal(t, "agent-mtr", batch.IngestIdentity.ProducerKind)
	require.Equal(t, "mtr_traces", batch.Resource.ServiceName)
	require.Equal(t, "mtr", batch.Resource.ServiceType)
	require.Equal(t, "kv-1", batch.Resource.KvStoreId)

	metrics := metricsByName(batch)
	require.Equal(t, metricpb.MetricKind_METRIC_KIND_GAUGE, metrics["mtr.available"].Kind)
	require.Equal(t, "1", metrics["mtr.available"].Unit)
	require.InDelta(t, 1.0, metrics["mtr.available"].Points[0].Value, 1e-9)
	require.Equal(t, "{hop}", metrics["mtr.total_hops"].Unit)
	require.InDelta(t, 2.0, metrics["mtr.total_hops"].Points[0].Value, 1e-9)

	lossPoint := metrics["mtr.hop.loss_percent"].Points[0]
	require.Equal(t, "example.net", entry(lossPoint.Attributes, "target"))
	require.Equal(t, "203.0.113.10", entry(lossPoint.Attributes, "target_ip"))
	require.Equal(t, "1", entry(lossPoint.Attributes, "hop_number"))
	require.Equal(t, "192.0.2.1", entry(lossPoint.Attributes, "addr"))
	require.Equal(t, "edge-router", entry(lossPoint.Attributes, "hostname"))
	require.Equal(t, "sr:device-1", entry(lossPoint.Attributes, "device_id"))

	require.Equal(t, "us", metrics["mtr.hop.avg_us"].Unit)
	require.InDelta(t, 1_100.0, metrics["mtr.hop.avg_us"].Points[0].Value, 1e-9)
	require.Equal(t, "1100", metrics["mtr.hop.avg_us"].Points[0].RawValue)
}

func TestMarshalSweepMetricEnvelope(t *testing.T) {
	t.Parallel()

	payload, err := marshalSweepMetricEnvelopeFromMap(map[string]any{
		"network":         "edge-lan",
		"execution_id":    "exec-1",
		"sweep_group_id":  "group-1",
		"total_hosts":     2,
		"available_hosts": 1,
		"last_sweep":      int64(1_780_000_000),
		"sequence":        42,
		"ports": []any{
			map[string]any{"port": 443, "available": 1},
		},
		"hosts": []any{
			map[string]any{
				"host":          "10.0.0.10",
				"hostname":      "node-a",
				"available":     true,
				"response_time": 123456,
				"icmp_status": map[string]any{
					"available":   true,
					"round_trip":  123456,
					"packet_loss": 0.01,
				},
				"port_results": []any{
					map[string]any{"port": 443, "available": true, "response_time": 222222, "service": "https"},
				},
			},
		},
		"scanner_stats": map[string]any{
			"protocol":             "icmp",
			"address_family":       "ipv4",
			"scanner_path":         "raw",
			"packets_sent":         100,
			"packets_recv":         99,
			"rx_drop_rate_percent": 0.5,
			"queue_depth":          3,
		},
		"banner_grab": map[string]any{
			"sweep_banner_grab_candidates_total":        7,
			"sweep_banner_grab_match_batch_bytes_total": 512,
			"sweep_banner_grab_inflight":                2,
		},
	}, metricEnvelopeContext{AgentID: "agent-1", GatewayID: "gateway-1", Partition: defaultPartition, KvStoreID: "kv-1"})
	require.NoError(t, err)

	batch := decodeMetricBatch(t, payload)
	require.Equal(t, metricEnvelopeSchemaVersion, batch.SchemaVersion)
	require.Equal(t, "sweep-metrics", batch.IngestIdentity.Source)
	require.Equal(t, "agent-sweep", batch.IngestIdentity.ProducerKind)
	require.Equal(t, networkSweepServiceName, batch.Resource.ServiceName)
	require.Equal(t, sweepType, batch.Resource.ServiceType)
	require.Equal(t, "kv-1", batch.Resource.KvStoreId)

	metrics := metricsByName(batch)
	require.InDelta(t, 2.0, metrics["sweep.total_hosts"].Points[0].Value, 1e-9)
	require.Equal(t, "{host}", metrics["sweep.total_hosts"].Unit)
	require.InDelta(t, 1.0, metrics["sweep.host.available"].Points[0].Value, 1e-9)
	require.Equal(t, "true", metrics["sweep.host.available"].Points[0].RawValue)
	require.Equal(t, "10.0.0.10", entry(metrics["sweep.host.available"].Points[0].Attributes, "target"))
	require.Equal(t, "node-a", entry(metrics["sweep.host.available"].Points[0].Attributes, "hostname"))
	require.Equal(t, "edge-lan", entry(metrics["sweep.host.available"].Points[0].Attributes, "network"))
	require.InDelta(t, 123456.0, metrics["sweep.host.icmp_response_time_ns"].Points[0].Value, 1e-9)
	require.InDelta(t, 0.01, metrics["sweep.host.icmp_packet_loss"].Points[0].Value, 1e-9)

	portPoint := metrics["sweep.host.port.available"].Points[0]
	require.Equal(t, "443", entry(portPoint.Attributes, "port"))
	require.Equal(t, "https", entry(portPoint.Attributes, "service"))
	require.InDelta(t, 1.0, portPoint.Value, 1e-9)

	scannerCounter := metrics["sweep.scanner.packets_sent"]
	require.Equal(t, metricpb.MetricKind_METRIC_KIND_SUM, scannerCounter.Kind)
	require.Equal(t, metricpb.MetricTemporality_METRIC_TEMPORALITY_CUMULATIVE, scannerCounter.Temporality)
	require.True(t, scannerCounter.IsMonotonic)
	require.Equal(t, "icmp", entry(scannerCounter.Points[0].Attributes, "protocol"))
	require.InDelta(t, 100.0, scannerCounter.Points[0].Value, 1e-9)
	require.Equal(t, "%", metrics["sweep.scanner.rx_drop_rate_percent"].Unit)
	require.InDelta(t, 0.5, metrics["sweep.scanner.rx_drop_rate_percent"].Points[0].Value, 1e-9)

	require.Equal(t, "By", metrics["sweep.banner_grab.match_batch_bytes_total"].Unit)
	require.InDelta(t, 512.0, metrics["sweep.banner_grab.match_batch_bytes_total"].Points[0].Value, 1e-9)
	require.InDelta(t, 2.0, metrics["sweep.banner_grab.inflight"].Points[0].Value, 1e-9)
}

func TestDefaultStatusSourceMarksRperfMetricEnvelope(t *testing.T) {
	t.Parallel()

	payload, err := proto.Marshal(&metricpb.MetricBatch{
		SchemaVersion: metricEnvelopeSchemaVersion,
		Metrics: []*metricpb.Metric{
			{
				Name:       "rperf.bits_per_second",
				MetricType: "rperf",
				Kind:       metricpb.MetricKind_METRIC_KIND_GAUGE,
				Points: []*metricpb.MetricPoint{
					{
						Value:              1600,
						ObservedAtUnixNano: uint64(time.Now().UnixNano()),
					},
				},
			},
		},
	})
	require.NoError(t, err)

	require.True(t, metricEnvelopePayload(payload))
	require.Equal(t, "rperf-metrics", defaultStatusSource(&srproto.StatusResponse{Message: payload}, "rperf", "rperf"))
	require.Equal(t, "status", defaultStatusSource(&srproto.StatusResponse{Message: []byte(`{"status":{}}`)}, "rperf", "rperf"))
	require.Equal(t, "status", defaultStatusSource(&srproto.StatusResponse{Message: payload}, "sweep", "sweep"))
}

func decodeMetricBatch(t *testing.T, payload []byte) *metricpb.MetricBatch {
	t.Helper()

	var batch metricpb.MetricBatch
	require.NoError(t, proto.Unmarshal(payload, &batch))
	return &batch
}

func metricsByName(batch *metricpb.MetricBatch) map[string]*metricpb.Metric {
	metrics := make(map[string]*metricpb.Metric, len(batch.Metrics))
	for _, metric := range batch.Metrics {
		metrics[metric.Name] = metric
	}

	return metrics
}

func metricsByNameAndObservedAt(batch *metricpb.MetricBatch, name string) map[uint64]*metricpb.Metric {
	metrics := make(map[uint64]*metricpb.Metric)
	for _, metric := range batch.Metrics {
		if metric.Name != name || len(metric.Points) == 0 {
			continue
		}

		metrics[metric.Points[0].ObservedAtUnixNano] = metric
	}

	return metrics
}

func entry(entries []*metricpb.StringMapEntry, key string) string {
	for _, entry := range entries {
		if entry.Key == key {
			return entry.Value
		}
	}

	return ""
}

// A string-typed OID - a software version, a node role, a service name - has no
// float representation, and used to be dropped here before it ever reached the
// consumer. That left it with nowhere to land at all, since
// timeseries_metrics.value is NOT NULL double precision.
func TestMarshalSNMPMetricEnvelopeKeepsStringReadings(t *testing.T) {
	t.Parallel()

	payload, err := marshalSNMPMetricEnvelope([]snmpMetricResult{
		{
			Target:    "clearpass-a",
			Host:      "10.0.0.30",
			Metric:    "node_version",
			OID:       ".1.3.6.1.4.1.14823.1.6.1.1.1.1.1.3.0",
			Value:     "6.11.15",
			RawValue:  "6.11.15",
			Timestamp: time.Date(2026, 6, 12, 0, 0, 0, 0, time.UTC),
			DataType:  "string",
		},
	}, metricEnvelopeContext{AgentID: "agent-1", GatewayID: "gateway-1", Partition: defaultPartition})
	require.NoError(t, err)

	batch := decodeMetricBatch(t, payload)
	require.Len(t, batch.Metrics, 1)

	point := batch.Metrics[0].Points[0]
	require.Equal(t, "6.11.15", point.RawValue)

	// The marker lives in metadata, never in tags or attributes: those feed the
	// consumer's series key, so a marker there would fork every SNMP series.
	require.Equal(t, "true", entry(point.Metadata, "non_numeric"))
	require.Empty(t, entry(point.Attributes, "non_numeric"))
	require.Empty(t, entry(batch.Metrics[0].Tags, "non_numeric"))
}

// A reading with neither a number nor a raw string is genuinely nothing to
// record, and must still be dropped rather than stored as an empty fact.
func TestMarshalSNMPMetricEnvelopeStillDropsValuelessReadings(t *testing.T) {
	t.Parallel()

	payload, err := marshalSNMPMetricEnvelope([]snmpMetricResult{
		{
			Target:    "clearpass-a",
			Host:      "10.0.0.30",
			Metric:    "node_version",
			OID:       ".1.3.6.1.4.1.14823.1.6.1.1.1.1.1.3.0",
			Value:     nil,
			RawValue:  nil,
			Timestamp: time.Date(2026, 6, 12, 0, 0, 0, 0, time.UTC),
			DataType:  "string",
		},
	}, metricEnvelopeContext{AgentID: "agent-1", GatewayID: "gateway-1", Partition: defaultPartition})

	require.ErrorIs(t, err, errSnmpNoMetricPoints)
	require.Nil(t, payload)
}

// The walk index rides as its own metadata field. Recovering it from
// interface_uid instead would be wrong for a scalar get on a non-interface OID
// whose last arc is a positive integer, where ifIndexForSNMPPoint derives
// "ifindex:<last arc>" from the OID itself.
func TestMarshalSNMPMetricEnvelopeCarriesRawOIDIndex(t *testing.T) {
	t.Parallel()

	payload, err := marshalSNMPMetricEnvelope([]snmpMetricResult{
		{
			Target:    "clearpass-a",
			Host:      "10.0.0.30",
			Metric:    "service_name",
			OID:       ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.2.4",
			OIDIndex:  "4",
			Value:     "radius",
			RawValue:  "radius",
			Timestamp: time.Date(2026, 6, 12, 0, 0, 0, 0, time.UTC),
			DataType:  "string",
		},
		{
			Target:    "clearpass-a",
			Host:      "10.0.0.30",
			Metric:    "node_role",
			OID:       ".1.3.6.1.4.1.14823.1.6.1.1.1.1.1.5.0",
			Value:     "publisher",
			RawValue:  "publisher",
			Timestamp: time.Date(2026, 6, 12, 0, 0, 0, 0, time.UTC),
			DataType:  "string",
		},
	}, metricEnvelopeContext{AgentID: "agent-1", GatewayID: "gateway-1", Partition: defaultPartition})
	require.NoError(t, err)

	batch := decodeMetricBatch(t, payload)
	require.Len(t, batch.Metrics, 2)

	byName := map[string]*metricpb.MetricPoint{}
	for _, metric := range batch.Metrics {
		byName[metric.Name] = metric.Points[0]
	}

	require.Equal(t, "4", entry(byName["service_name"].Metadata, "oid_index"))
	// A scalar get has no index, and must not be given one.
	require.Empty(t, entry(byName["node_role"].Metadata, "oid_index"))
}
