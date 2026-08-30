/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
	gproto "google.golang.org/protobuf/proto"
)

const (
	metricEnvelopeSchemaVersion = "serviceradar.metric.v1"

	// sysmonNetworkMetricType is the metric_type stamped on cumulative sysmon
	// network counter metrics.
	sysmonNetworkMetricType = "sysmon.network"

	// rawBoolFalse / rawBoolTrue are the canonical raw string forms used for
	// boolean metric points.
	rawBoolFalse = "false"
	rawBoolTrue  = "true"
)

var (
	// errSysmonSampleNil is returned when a nil sysmon sample is marshaled.
	errSysmonSampleNil = errors.New("sysmon sample is nil")
	// errSysmonSampleBatchEmpty is returned when a sysmon sample batch contains
	// no usable samples.
	errSysmonSampleBatchEmpty = errors.New("sysmon sample batch is empty")
	// errSysmonNoScalarMetrics is returned when a sysmon sample batch produces no
	// scalar metrics.
	errSysmonNoScalarMetrics = errors.New("sysmon sample batch has no scalar metrics")
	// errSnmpNoMetricPoints is returned when an SNMP payload yields no numeric
	// metric points.
	// Not "no numeric points": a payload of only string-typed readings is
	// legitimate now and must not be refused. This fires only when nothing at
	// all was recordable.
	errSnmpNoMetricPoints = errors.New("snmp payload has no recordable metric points")
	// errICMPNoMetricPoints is returned when an ICMP payload yields no metric
	// points.
	errICMPNoMetricPoints = errors.New("icmp payload has no metric points")
	// errMTRNoMetricPoints is returned when an MTR payload yields no metric
	// points.
	errMTRNoMetricPoints = errors.New("mtr payload has no metric points")
	// errSweepPayloadEmpty is returned when a sweep payload is empty.
	errSweepPayloadEmpty = errors.New("sweep payload is empty")
	// errSweepNoMetricPoints is returned when a sweep payload yields no metric
	// points.
	errSweepNoMetricPoints = errors.New("sweep payload has no metric points")
)

type metricEnvelopeContext struct {
	AgentID   string
	GatewayID string
	Partition string
	KvStoreID string
}

func marshalSysmonMetricEnvelope(sample *sysmon.MetricSample, ctx metricEnvelopeContext) ([]byte, error) {
	if sample == nil {
		return nil, errSysmonSampleNil
	}

	return marshalSysmonMetricEnvelopeBatch([]*sysmon.MetricSample{sample}, ctx)
}

func marshalSysmonMetricEnvelopeBatch(samples []*sysmon.MetricSample, ctx metricEnvelopeContext) ([]byte, error) {
	sample := firstSysmonMetricSample(samples)
	if sample == nil {
		return nil, errSysmonSampleBatchEmpty
	}

	batch := &metricpb.MetricBatch{
		SchemaVersion: metricEnvelopeSchemaVersion,
		Resource: &metricpb.MetricResource{
			AgentId:     firstMetricNonEmpty(sample.AgentID, ctx.AgentID),
			GatewayId:   ctx.GatewayID,
			Partition:   firstMetricNonEmpty(ptrString(sample.Partition), ctx.Partition),
			ServiceName: "sysmon",
			ServiceType: "sysmon",
			HostId:      sample.HostID,
			HostIp:      sample.HostIP,
			KvStoreId:   ctx.KvStoreID,
		},
		IngestIdentity: &metricpb.IngestIdentity{
			Source:       "sysmon-metrics",
			PayloadKind:  "serviceradar.metric.v1",
			ProducerKind: "agent-sysmon",
			ProducerId:   firstMetricNonEmpty(sample.AgentID, ctx.AgentID),
			AttestedBy:   ctx.GatewayID,
		},
		EmittedAtUnixNano: uint64(time.Now().UnixNano()),
	}

	for _, sample := range samples {
		if sample == nil {
			continue
		}

		observedAt := parseMetricTimeNano(sample.Timestamp, time.Now())
		batch.Metrics = append(batch.Metrics, sysmonCPUMetrics(sample, observedAt)...)
		batch.Metrics = append(batch.Metrics, sysmonMemoryMetrics(sample, observedAt)...)
		batch.Metrics = append(batch.Metrics, sysmonDiskMetrics(sample, observedAt)...)
		batch.Metrics = append(batch.Metrics, sysmonNetworkMetrics(sample, observedAt)...)
		batch.Metrics = append(batch.Metrics, sysmonProcessMetrics(sample, observedAt)...)
	}

	if len(batch.Metrics) == 0 {
		return nil, errSysmonNoScalarMetrics
	}

	return gproto.Marshal(batch)
}

func firstSysmonMetricSample(samples []*sysmon.MetricSample) *sysmon.MetricSample {
	for _, sample := range samples {
		if sample != nil {
			return sample
		}
	}

	return nil
}

func marshalSNMPMetricEnvelope(results []snmpMetricResult, ctx metricEnvelopeContext) ([]byte, error) {
	batch := &metricpb.MetricBatch{
		SchemaVersion: metricEnvelopeSchemaVersion,
		Resource: &metricpb.MetricResource{
			AgentId:     ctx.AgentID,
			GatewayId:   ctx.GatewayID,
			Partition:   ctx.Partition,
			ServiceName: "snmp",
			ServiceType: "snmp",
			KvStoreId:   ctx.KvStoreID,
		},
		IngestIdentity: &metricpb.IngestIdentity{
			Source:       "snmp-metrics",
			PayloadKind:  "serviceradar.metric.v1",
			ProducerKind: "agent-snmp",
			ProducerId:   ctx.AgentID,
			AttestedBy:   ctx.GatewayID,
		},
		EmittedAtUnixNano: uint64(time.Now().UnixNano()),
		Metrics:           make([]*metricpb.Metric, 0, len(results)),
	}

	for _, result := range results {
		value, numeric := numericMetricValue(result.Value)
		raw := rawMetricValue(result.RawValue, result.Value)

		// A string-typed OID - a software version, a node role, a service name -
		// is a legal SNMP reading with no float representation, and it used to be
		// discarded right here. That left it with nowhere to land at all, since
		// timeseries_metrics.value is NOT NULL double precision. It now rides
		// through carrying value 0 plus an explicit marker, and the consumer
		// routes marked points to device_snmp_facts while keeping them OUT of the
		// time series. A reading with neither a number nor a raw string is still
		// genuinely nothing to record.
		if !numeric && raw == "" {
			continue
		}

		observedAt := timeToUnixNano(result.Timestamp, time.Now())
		kind := metricKind(result.Kind, result.DataType, result.Delta)

		point := &metricpb.MetricPoint{
			Value:              value,
			RawValue:           raw,
			RawValueType:       metricValueType(result.RawValue, result.Value),
			ObservedAtUnixNano: observedAt,
			IfIndex:            int32Value(result.IfIndex),
			InterfaceUid:       result.InterfaceUID,
			// Attributes feed the consumer's series-key tags, so keep them limited to
			// real series identity. The OID is metadata-only and must not fork the
			// series per OID, so it lives in point.Metadata (excluded from the series
			// key on both the row and sample/anomaly paths) instead.
			Attributes: entries(map[string]string{
				"target": result.Target,
				"host":   result.Host,
			}),
			Metadata: entries(snmpPointMetadata(result, numeric)),
		}

		metric := &metricpb.Metric{
			Name:         result.Metric,
			MetricType:   "snmp",
			Kind:         kind,
			Temporality:  metricTemporality(result.Temporality, result.Delta, kind),
			IsMonotonic:  metricIsMonotonic(result, kind),
			Scale:        result.Scale,
			CounterWidth: metricCounterWidth(result.CounterWidth, kind),
			Points:       []*metricpb.MetricPoint{point},
			Tags: entries(map[string]string{
				"target":        result.Target,
				"host":          result.Host,
				"interface_uid": result.InterfaceUID,
			}),
			Metadata: entries(map[string]string{
				"data_type": result.DataType,
				"oid":       result.OID,
			}),
		}

		if result.Host != "" {
			metric.Metadata = append(metric.Metadata, &metricpb.StringMapEntry{Key: "target_device_ip", Value: result.Host})
		}

		batch.Metrics = append(batch.Metrics, metric)
	}

	if len(batch.Metrics) == 0 {
		return nil, errSnmpNoMetricPoints
	}

	return gproto.Marshal(batch)
}

func marshalICMPMetricEnvelope(results []icmpCheckResult, ctx metricEnvelopeContext) ([]byte, error) {
	batch := &metricpb.MetricBatch{
		SchemaVersion: metricEnvelopeSchemaVersion,
		Resource: &metricpb.MetricResource{
			AgentId:     ctx.AgentID,
			GatewayId:   ctx.GatewayID,
			Partition:   ctx.Partition,
			ServiceName: "icmp_checks",
			ServiceType: "icmp",
			KvStoreId:   ctx.KvStoreID,
		},
		IngestIdentity: &metricpb.IngestIdentity{
			Source:       "icmp-metrics",
			PayloadKind:  metricEnvelopeSchemaVersion,
			ProducerKind: "agent-icmp",
			ProducerId:   ctx.AgentID,
			AttestedBy:   ctx.GatewayID,
		},
		EmittedAtUnixNano: uint64(time.Now().UnixNano()),
		Metrics: []*metricpb.Metric{
			icmpMetric("icmp_response_time_ns", "ns"),
			icmpMetric("icmp_packet_loss", "1"),
			icmpMetric("icmp_available", "1"),
		},
	}

	for _, result := range results {
		observedAt := uint64(result.Timestamp)
		if result.Timestamp <= 0 {
			observedAt = uint64(time.Now().UnixNano())
		}

		// Attributes feed the consumer's series-key tags, so keep them limited to
		// real series identity. A changing error string must not fork the series
		// per distinct error, so it lives in point.Metadata (excluded from the
		// series key on both the row and sample/anomaly paths) instead.
		attrs := map[string]string{
			"check_id":   result.CheckID,
			"check_name": result.CheckName,
			"target":     result.Target,
			"device_id":  result.DeviceID,
		}
		meta := map[string]string{
			"error": result.Error,
		}

		if result.ResponseTimeNs >= 0 {
			batch.Metrics[0].Points = append(batch.Metrics[0].Points, &metricpb.MetricPoint{
				Value:              float64(result.ResponseTimeNs),
				RawValue:           strconv.FormatInt(result.ResponseTimeNs, 10),
				RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_INT64,
				ObservedAtUnixNano: observedAt,
				Attributes:         entries(attrs),
				Metadata:           entries(meta),
			})
		}

		batch.Metrics[1].Points = append(batch.Metrics[1].Points, &metricpb.MetricPoint{
			Value:              result.PacketLoss,
			RawValue:           strconv.FormatFloat(result.PacketLoss, 'f', -1, 64),
			RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_DOUBLE,
			ObservedAtUnixNano: observedAt,
			Attributes:         entries(attrs),
			Metadata:           entries(meta),
		})

		availableValue := 0.0
		rawAvailable := rawBoolFalse
		if result.Available {
			availableValue = 1.0
			rawAvailable = rawBoolTrue
		}

		batch.Metrics[2].Points = append(batch.Metrics[2].Points, &metricpb.MetricPoint{
			Value:              availableValue,
			RawValue:           rawAvailable,
			RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_BOOL,
			ObservedAtUnixNano: observedAt,
			Attributes:         entries(attrs),
			Metadata:           entries(meta),
		})
	}

	batch.Metrics = metricsWithPoints(batch.Metrics)
	if len(batch.Metrics) == 0 {
		return nil, errICMPNoMetricPoints
	}

	return gproto.Marshal(batch)
}

func marshalMTRMetricEnvelope(results []mtrCheckResult, ctx metricEnvelopeContext) ([]byte, error) {
	batch := &metricpb.MetricBatch{
		SchemaVersion: metricEnvelopeSchemaVersion,
		Resource: &metricpb.MetricResource{
			AgentId:     ctx.AgentID,
			GatewayId:   ctx.GatewayID,
			Partition:   ctx.Partition,
			ServiceName: mtrServiceName,
			ServiceType: mtrServiceType,
			KvStoreId:   ctx.KvStoreID,
		},
		IngestIdentity: &metricpb.IngestIdentity{
			Source:       "mtr-metrics",
			PayloadKind:  metricEnvelopeSchemaVersion,
			ProducerKind: "agent-mtr",
			ProducerId:   ctx.AgentID,
			AttestedBy:   ctx.GatewayID,
		},
		EmittedAtUnixNano: uint64(time.Now().UnixNano()),
		Metrics: []*metricpb.Metric{
			mtrMetric("mtr.available", "1"),
			mtrMetric("mtr.total_hops", "{hop}"),
			mtrMetric("mtr.hop.loss_percent", "%"),
			mtrMetric("mtr.hop.last_us", "us"),
			mtrMetric("mtr.hop.avg_us", "us"),
			mtrMetric("mtr.hop.min_us", "us"),
			mtrMetric("mtr.hop.max_us", "us"),
			mtrMetric("mtr.hop.stddev_us", "us"),
			mtrMetric("mtr.hop.jitter_us", "us"),
			mtrMetric("mtr.hop.jitter_worst_us", "us"),
			mtrMetric("mtr.hop.jitter_interarrival_us", "us"),
		},
	}

	for _, result := range results {
		observedAt := uint64(result.Timestamp)
		if result.Timestamp <= 0 {
			observedAt = uint64(time.Now().UnixNano())
		}

		attrs := map[string]string{
			"check_id":   result.CheckID,
			"check_name": result.CheckName,
			"target":     result.Target,
			"device_id":  result.DeviceID,
			"error":      result.Error,
		}

		pushGaugePoint(batch.Metrics[0], boolMetricValue(result.Available), observedAt, attrs)

		if result.Trace == nil {
			continue
		}

		traceAttrs := cloneMetricAttrs(attrs)
		traceAttrs["target_ip"] = result.Trace.TargetIP
		traceAttrs["protocol"] = result.Trace.Protocol
		traceAttrs["ip_version"] = strconv.Itoa(result.Trace.IPVersion)

		pushGaugePoint(batch.Metrics[1], float64(result.Trace.TotalHops), observedAt, traceAttrs)

		for _, hop := range result.Trace.Hops {
			hopAttrs := cloneMetricAttrs(traceAttrs)
			hopAttrs["hop_number"] = strconv.Itoa(hop.HopNumber)
			hopAttrs["addr"] = hop.Addr
			hopAttrs["hostname"] = hop.Hostname

			pushGaugePoint(batch.Metrics[2], hop.LossPct, observedAt, hopAttrs)
			pushNonZeroIntPoint(batch.Metrics[3], hop.LastUs, observedAt, hopAttrs)
			pushNonZeroIntPoint(batch.Metrics[4], hop.AvgUs, observedAt, hopAttrs)
			pushNonZeroIntPoint(batch.Metrics[5], hop.MinUs, observedAt, hopAttrs)
			pushNonZeroIntPoint(batch.Metrics[6], hop.MaxUs, observedAt, hopAttrs)
			pushNonZeroIntPoint(batch.Metrics[7], hop.StdDevUs, observedAt, hopAttrs)
			pushNonZeroIntPoint(batch.Metrics[8], hop.JitterUs, observedAt, hopAttrs)
			pushNonZeroIntPoint(batch.Metrics[9], hop.JitterWorstUs, observedAt, hopAttrs)
			pushNonZeroIntPoint(batch.Metrics[10], hop.JitterInterarrivalUs, observedAt, hopAttrs)
		}
	}

	batch.Metrics = metricsWithPoints(batch.Metrics)
	if len(batch.Metrics) == 0 {
		return nil, errMTRNoMetricPoints
	}

	return gproto.Marshal(batch)
}

func marshalSweepMetricEnvelopeFromMap(decoded map[string]any, ctx metricEnvelopeContext) ([]byte, error) {
	if len(decoded) == 0 {
		return nil, errSweepPayloadEmpty
	}

	observedAt := sweepObservedAt(decoded)
	baseAttrs := sweepBaseAttrs(decoded)
	builder := newSweepMetricBuilder(ctx)

	builder.gauge("sweep.total_hosts", "{host}", numberFromAny(decoded["total_hosts"]), observedAt, baseAttrs)
	builder.gauge("sweep.available_hosts", "{host}", numberFromAny(decoded["available_hosts"]), observedAt, baseAttrs)
	builder.gauge("sweep.sequence", "1", numberFromAny(decoded["sequence"]), observedAt, baseAttrs)

	for _, portValue := range listFromAny(decoded["ports"]) {
		port, ok := mapFromAny(portValue)
		if !ok {
			continue
		}
		attrs := cloneMetricAttrs(baseAttrs)
		if value, ok := intLikeFromAny(port["port"]); ok {
			attrs["port"] = strconv.FormatInt(value, 10)
		}
		builder.gauge("sweep.port.available_hosts", "{host}", numberFromAny(port["available"]), observedAt, attrs)
	}

	for _, hostValue := range listFromAny(decoded["hosts"]) {
		host, ok := mapFromAny(hostValue)
		if !ok {
			continue
		}
		attrs := cloneMetricAttrs(baseAttrs)
		hostName := stringFromAny(host["host"])
		if hostName == "" {
			continue
		}
		attrs["target"] = hostName
		if hostname := stringFromAny(host["hostname"]); hostname != "" {
			attrs["hostname"] = hostname
		}

		builder.boolGauge("sweep.host.available", boolFromAny(host["available"]), observedAt, attrs)
		builder.gauge("sweep.host.response_time_ns", "ns", durationNumberFromAny(host["response_time"]), observedAt, attrs)

		if icmpStatus, ok := mapFromAny(host["icmp_status"]); ok {
			builder.boolGauge("sweep.host.icmp_available", boolFromAny(icmpStatus["available"]), observedAt, attrs)
			builder.gauge("sweep.host.icmp_response_time_ns", "ns", durationNumberFromAny(icmpStatus["round_trip"]), observedAt, attrs)
			builder.gauge("sweep.host.icmp_packet_loss", "1", numberFromAny(icmpStatus["packet_loss"]), observedAt, attrs)
		}

		for _, portValue := range listFromAny(host["port_results"]) {
			port, ok := mapFromAny(portValue)
			if !ok {
				continue
			}
			portAttrs := cloneMetricAttrs(attrs)
			if value, ok := intLikeFromAny(port["port"]); ok {
				portAttrs["port"] = strconv.FormatInt(value, 10)
			}
			if service := stringFromAny(port["service"]); service != "" {
				portAttrs["service"] = service
			}
			builder.boolGauge("sweep.host.port.available", boolFromAny(port["available"]), observedAt, portAttrs)
			builder.gauge("sweep.host.port.response_time_ns", "ns", durationNumberFromAny(port["response_time"]), observedAt, portAttrs)
		}
	}

	if scannerStats, ok := mapFromAny(decoded["scanner_stats"]); ok {
		attrs := cloneMetricAttrs(baseAttrs)
		for _, key := range []string{"protocol", "address_family", "scanner_path"} {
			if value := stringFromAny(scannerStats[key]); value != "" {
				attrs[key] = value
			}
		}
		builder.scannerStats(scannerStats, observedAt, attrs)
	}

	if bannerStats, ok := mapFromAny(firstMetricNonNil(decoded["banner_grab"], decoded["bannerGrab"])); ok {
		builder.bannerStats(bannerStats, observedAt, baseAttrs)
	}

	if len(builder.batch.Metrics) == 0 {
		return nil, errSweepNoMetricPoints
	}

	return gproto.Marshal(builder.batch)
}

type sweepMetricBuilder struct {
	batch   *metricpb.MetricBatch
	metrics map[string]*metricpb.Metric
}

func newSweepMetricBuilder(ctx metricEnvelopeContext) *sweepMetricBuilder {
	return &sweepMetricBuilder{
		batch: &metricpb.MetricBatch{
			SchemaVersion: metricEnvelopeSchemaVersion,
			Resource: &metricpb.MetricResource{
				AgentId:     ctx.AgentID,
				GatewayId:   ctx.GatewayID,
				Partition:   ctx.Partition,
				ServiceName: networkSweepServiceName,
				ServiceType: sweepType,
				KvStoreId:   ctx.KvStoreID,
			},
			IngestIdentity: &metricpb.IngestIdentity{
				Source:       "sweep-metrics",
				PayloadKind:  metricEnvelopeSchemaVersion,
				ProducerKind: "agent-sweep",
				ProducerId:   ctx.AgentID,
				AttestedBy:   ctx.GatewayID,
			},
			EmittedAtUnixNano: uint64(time.Now().UnixNano()),
		},
		metrics: make(map[string]*metricpb.Metric),
	}
}

func (b *sweepMetricBuilder) gauge(name, unit string, value *float64, observedAt uint64, attrs map[string]string) {
	if value == nil {
		return
	}
	metric := b.metric(name, unit, metricpb.MetricKind_METRIC_KIND_GAUGE, metricpb.MetricTemporality_METRIC_TEMPORALITY_UNSPECIFIED, false)
	pushGaugePoint(metric, *value, observedAt, attrs)
}

func (b *sweepMetricBuilder) boolGauge(name string, value *bool, observedAt uint64, attrs map[string]string) {
	if value == nil {
		return
	}
	metric := b.metric(name, "1", metricpb.MetricKind_METRIC_KIND_GAUGE, metricpb.MetricTemporality_METRIC_TEMPORALITY_UNSPECIFIED, false)
	raw := rawBoolFalse
	numeric := 0.0
	if *value {
		raw = rawBoolTrue
		numeric = 1.0
	}
	metric.Points = append(metric.Points, &metricpb.MetricPoint{
		Value:              numeric,
		RawValue:           raw,
		RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_BOOL,
		ObservedAtUnixNano: observedAt,
		Attributes:         entries(attrs),
	})
}

func (b *sweepMetricBuilder) counter(name, unit string, value *float64, observedAt uint64, attrs map[string]string) {
	if value == nil {
		return
	}
	metric := b.metric(name, unit, metricpb.MetricKind_METRIC_KIND_SUM, metricpb.MetricTemporality_METRIC_TEMPORALITY_CUMULATIVE, true)
	metric.Points = append(metric.Points, &metricpb.MetricPoint{
		Value:              *value,
		RawValue:           strconv.FormatFloat(*value, 'f', -1, 64),
		RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_DOUBLE,
		ObservedAtUnixNano: observedAt,
		Attributes:         entries(attrs),
	})
}

func (b *sweepMetricBuilder) metric(
	name string,
	unit string,
	kind metricpb.MetricKind,
	temporality metricpb.MetricTemporality,
	monotonic bool,
) *metricpb.Metric {
	if metric, ok := b.metrics[name]; ok {
		return metric
	}
	metric := &metricpb.Metric{
		Name:        name,
		MetricType:  "sweep",
		Kind:        kind,
		Temporality: temporality,
		IsMonotonic: monotonic,
		Unit:        unit,
		Tags: entries(map[string]string{
			"metric_family": "sweep",
		}),
	}
	b.metrics[name] = metric
	b.batch.Metrics = append(b.batch.Metrics, metric)
	return metric
}

func (b *sweepMetricBuilder) scannerStats(stats map[string]any, observedAt uint64, attrs map[string]string) {
	counterKeys := []string{
		"packets_sent", "packets_recv", "packets_dropped", "ring_blocks_processed", "ring_blocks_dropped",
		"retries_attempted", "retries_successful", "ports_allocated", "ports_released", "port_exhaustion_count",
		"rate_limit_deferrals", "rate_limit_waits", "source_port_waits", "rate_limit_wait_time_ms",
		"source_port_wait_time_ms", "dials_started", "dials_succeeded", "dial_timeouts", "dial_resets",
		"dial_resource_errors",
	}
	for _, key := range counterKeys {
		b.counter("sweep.scanner."+key, sweepScannerUnit(key), numberFromAny(stats[key]), observedAt, attrs)
	}
	for _, key := range []string{"rx_drop_rate_percent", "active_dials", "max_active_dials", "queue_depth", "max_queue_depth"} {
		b.gauge("sweep.scanner."+key, sweepScannerUnit(key), numberFromAny(stats[key]), observedAt, attrs)
	}
}

func (b *sweepMetricBuilder) bannerStats(stats map[string]any, observedAt uint64, attrs map[string]string) {
	counterKeys := []string{
		"sweep_banner_grab_candidates_total", "sweep_banner_grab_probes_total",
		"sweep_banner_grab_match_batches_total", "sweep_banner_grab_match_batch_bytes_total",
		"sweep_banner_grab_bytes_received_total", "sweep_banner_grab_skipped_fresh_total",
		"sweep_banner_grab_skipped_backoff_total", "sweep_banner_grab_matches_total",
		"sweep_banner_grab_empty_response_total", "sweep_banner_grab_connection_reset_total",
		"sweep_banner_grab_timeout_total", "sweep_banner_grab_errors_total",
	}
	for _, key := range counterKeys {
		b.counter("sweep.banner_grab."+strings.TrimPrefix(key, "sweep_banner_grab_"), sweepBannerUnit(key), numberFromAny(stats[key]), observedAt, attrs)
	}
	for _, key := range []string{"sweep_banner_grab_inflight", "sweep_banner_grab_queue_depth"} {
		b.gauge("sweep.banner_grab."+strings.TrimPrefix(key, "sweep_banner_grab_"), "1", numberFromAny(stats[key]), observedAt, attrs)
	}
}

func sweepScannerUnit(key string) string {
	switch {
	case strings.HasSuffix(key, "_time_ms"):
		return "ms"
	case key == "rx_drop_rate_percent":
		return "%"
	default:
		return "1"
	}
}

func sweepBannerUnit(key string) string {
	if strings.Contains(key, "_bytes_") || strings.HasSuffix(key, "_bytes_total") {
		return "By"
	}
	return "1"
}

func sweepObservedAt(payload map[string]any) uint64 {
	if value, ok := intLikeFromAny(payload["last_sweep"]); ok && value > 0 {
		return uint64(value) * uint64(time.Second/time.Nanosecond)
	}
	return uint64(time.Now().UnixNano())
}

func sweepBaseAttrs(payload map[string]any) map[string]string {
	attrs := map[string]string{
		"network":        stringFromAny(payload["network"]),
		"execution_id":   stringFromAny(firstMetricNonNil(payload["execution_id"], payload["executionId"])),
		"sweep_group_id": stringFromAny(payload["sweep_group_id"]),
	}
	for key, value := range attrs {
		if value == "" {
			delete(attrs, key)
		}
	}
	return attrs
}

func mtrMetric(name, unit string) *metricpb.Metric {
	return &metricpb.Metric{
		Name:        name,
		MetricType:  "mtr",
		Kind:        metricpb.MetricKind_METRIC_KIND_GAUGE,
		Temporality: metricpb.MetricTemporality_METRIC_TEMPORALITY_UNSPECIFIED,
		Unit:        unit,
		Tags: entries(map[string]string{
			"metric_family": "mtr",
		}),
	}
}

func pushNonZeroIntPoint(metric *metricpb.Metric, value int64, observedAt uint64, attrs map[string]string) {
	if value == 0 {
		return
	}

	pushGaugePoint(metric, float64(value), observedAt, attrs)
}

func pushGaugePoint(metric *metricpb.Metric, value float64, observedAt uint64, attrs map[string]string) {
	metric.Points = append(metric.Points, &metricpb.MetricPoint{
		Value:              value,
		RawValue:           strconv.FormatFloat(value, 'f', -1, 64),
		RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_DOUBLE,
		ObservedAtUnixNano: observedAt,
		Attributes:         entries(attrs),
	})
}

func boolMetricValue(value bool) float64 {
	if value {
		return 1
	}

	return 0
}

func cloneMetricAttrs(attrs map[string]string) map[string]string {
	clone := make(map[string]string, len(attrs)+4)
	for key, value := range attrs {
		clone[key] = value
	}

	return clone
}

func metricEnvelopePayload(data []byte) bool {
	if len(data) == 0 {
		return false
	}

	var batch metricpb.MetricBatch
	if err := gproto.Unmarshal(data, &batch); err != nil {
		return false
	}

	return batch.GetSchemaVersion() == metricEnvelopeSchemaVersion && len(batch.GetMetrics()) > 0
}

func icmpMetric(name, unit string) *metricpb.Metric {
	return &metricpb.Metric{
		Name:        name,
		MetricType:  "icmp",
		Kind:        metricpb.MetricKind_METRIC_KIND_GAUGE,
		Temporality: metricpb.MetricTemporality_METRIC_TEMPORALITY_UNSPECIFIED,
		Unit:        unit,
		Tags: entries(map[string]string{
			"metric_family": "icmp_check",
		}),
	}
}

func metricsWithPoints(metrics []*metricpb.Metric) []*metricpb.Metric {
	filtered := metrics[:0]
	for _, metric := range metrics {
		if len(metric.Points) > 0 {
			filtered = append(filtered, metric)
		}
	}

	return filtered
}

func firstMetricNonNil(values ...any) any {
	for _, value := range values {
		if value != nil {
			return value
		}
	}

	return nil
}

func listFromAny(value any) []any {
	if values, ok := value.([]any); ok {
		return values
	}

	return nil
}

func mapFromAny(value any) (map[string]any, bool) {
	values, ok := value.(map[string]any)

	return values, ok
}

func stringFromAny(value any) string {
	switch v := value.(type) {
	case string:
		return strings.TrimSpace(v)
	case fmt.Stringer:
		return strings.TrimSpace(v.String())
	default:
		return ""
	}
}

func boolFromAny(value any) *bool {
	switch v := value.(type) {
	case bool:
		return &v
	case string:
		parsed, err := strconv.ParseBool(strings.TrimSpace(v))
		if err != nil {
			return nil
		}

		return &parsed
	default:
		return nil
	}
}

func numberFromAny(value any) *float64 {
	parsed, ok := numericMetricValue(value)
	if !ok || math.IsNaN(parsed) || math.IsInf(parsed, 0) {
		return nil
	}

	return &parsed
}

func durationNumberFromAny(value any) *float64 {
	if parsed := numberFromAny(value); parsed != nil {
		return parsed
	}

	text := stringFromAny(value)
	if text == "" {
		return nil
	}

	if duration, err := time.ParseDuration(text); err == nil {
		value := float64(duration.Nanoseconds())

		return &value
	}

	return nil
}

func intLikeFromAny(value any) (int64, bool) {
	switch v := value.(type) {
	case int:
		return int64(v), true
	case int8:
		return int64(v), true
	case int16:
		return int64(v), true
	case int32:
		return int64(v), true
	case int64:
		return v, true
	case uint:
		if uint64(v) > math.MaxInt64 {
			return 0, false
		}

		return int64(v), true
	case uint8:
		return int64(v), true
	case uint16:
		return int64(v), true
	case uint32:
		return int64(v), true
	case uint64:
		if v > math.MaxInt64 {
			return 0, false
		}

		return int64(v), true
	case float32:
		value := float64(v)
		if math.Trunc(value) != value || value > math.MaxInt64 || value < math.MinInt64 {
			return 0, false
		}

		return int64(value), true
	case float64:
		if math.Trunc(v) != v || v > math.MaxInt64 || v < math.MinInt64 {
			return 0, false
		}

		return int64(v), true
	case json.Number:
		parsed, err := v.Int64()
		if err == nil {
			return parsed, true
		}
	case string:
		parsed, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		if err == nil {
			return parsed, true
		}
	}

	return 0, false
}

func sysmonCPUMetrics(sample *sysmon.MetricSample, observedAt uint64) []*metricpb.Metric {
	metrics := make([]*metricpb.Metric, 0, len(sample.CPUs)+len(sample.Clusters))

	for _, cpu := range sample.CPUs {
		metrics = append(metrics, gaugeMetric(
			"cpu.usage_percent",
			"sysmon.cpu",
			"%",
			cpu.UsagePercent,
			observedAt,
			map[string]string{
				"core_id": strconv.Itoa(int(cpu.CoreID)),
				"label":   cpu.Label,
				"cluster": cpu.Cluster,
			},
		))

		if cpu.FrequencyHz > 0 {
			metrics = append(metrics, gaugeMetric(
				"cpu.frequency_hz",
				"sysmon.cpu",
				"Hz",
				cpu.FrequencyHz,
				observedAt,
				map[string]string{
					"core_id": strconv.Itoa(int(cpu.CoreID)),
					"label":   cpu.Label,
					"cluster": cpu.Cluster,
				},
			))
		}
	}

	for _, cluster := range sample.Clusters {
		if cluster.FrequencyHz <= 0 {
			continue
		}

		metrics = append(metrics, gaugeMetric(
			"cpu.cluster.frequency_hz",
			"sysmon.cpu",
			"Hz",
			cluster.FrequencyHz,
			observedAt,
			map[string]string{"cluster": cluster.Name},
		))
	}

	return metrics
}

func sysmonMemoryMetrics(sample *sysmon.MetricSample, observedAt uint64) []*metricpb.Metric {
	if sample.Memory.TotalBytes == 0 {
		return nil
	}

	return []*metricpb.Metric{
		gaugeMetric(
			"memory.used_percent",
			"sysmon.memory",
			"%",
			float64(sample.Memory.UsedBytes)*100.0/float64(sample.Memory.TotalBytes),
			observedAt,
			map[string]string{
				"used_bytes":  strconv.FormatUint(sample.Memory.UsedBytes, 10),
				"total_bytes": strconv.FormatUint(sample.Memory.TotalBytes, 10),
			},
		),
	}
}

func sysmonDiskMetrics(sample *sysmon.MetricSample, observedAt uint64) []*metricpb.Metric {
	metrics := make([]*metricpb.Metric, 0, len(sample.Disks))

	for _, disk := range sample.Disks {
		if disk.TotalBytes == 0 {
			continue
		}

		metrics = append(metrics, gaugeMetric(
			"disk.used_percent",
			"sysmon.disk",
			"%",
			float64(disk.UsedBytes)*100.0/float64(disk.TotalBytes),
			observedAt,
			map[string]string{
				"mount_point": disk.MountPoint,
				"used_bytes":  strconv.FormatUint(disk.UsedBytes, 10),
				"total_bytes": strconv.FormatUint(disk.TotalBytes, 10),
			},
		))
	}

	return metrics
}

func sysmonNetworkMetrics(sample *sysmon.MetricSample, observedAt uint64) []*metricpb.Metric {
	metrics := make([]*metricpb.Metric, 0, len(sample.Network)*4)

	for _, network := range sample.Network {
		attrs := map[string]string{"interface": network.Interface}
		metrics = append(metrics, cumulativeMetric("network.bytes_sent", "By", network.BytesSent, observedAt, attrs))
		metrics = append(metrics, cumulativeMetric("network.bytes_recv", "By", network.BytesRecv, observedAt, attrs))
		metrics = append(metrics, cumulativeMetric("network.packets_sent", "{packet}", network.PacketsSent, observedAt, attrs))
		metrics = append(metrics, cumulativeMetric("network.packets_recv", "{packet}", network.PacketsRecv, observedAt, attrs))
	}

	return metrics
}

func sysmonProcessMetrics(sample *sysmon.MetricSample, observedAt uint64) []*metricpb.Metric {
	metrics := make([]*metricpb.Metric, 0, 3)
	metrics = append(metrics,
		gaugeMetric("process.count", "sysmon.process", "{process}", float64(sysmonProcessCount(sample)), observedAt, nil),
	)

	if len(sample.Processes) == 0 {
		return metrics
	}

	cpu := &metricpb.Metric{
		Name:       "process.cpu_usage",
		MetricType: "sysmon.process",
		Kind:       metricpb.MetricKind_METRIC_KIND_GAUGE,
		Unit:       "%",
		Points:     make([]*metricpb.MetricPoint, 0, len(sample.Processes)),
	}

	memory := &metricpb.Metric{
		Name:       "process.memory_usage",
		MetricType: "sysmon.process",
		Kind:       metricpb.MetricKind_METRIC_KIND_GAUGE,
		Unit:       "By",
		Points:     make([]*metricpb.MetricPoint, 0, len(sample.Processes)),
	}

	for _, process := range sample.Processes {
		attrs := processAttributes(process)
		seriesHint := processSeriesHint(process)

		cpu.Points = append(cpu.Points, &metricpb.MetricPoint{
			Value:              float64(process.CPUUsage),
			RawValue:           strconv.FormatFloat(float64(process.CPUUsage), 'f', -1, 64),
			RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_DOUBLE,
			ObservedAtUnixNano: observedAt,
			SeriesIdentityHint: seriesHint,
			Attributes:         entries(attrs),
		})

		memory.Points = append(memory.Points, &metricpb.MetricPoint{
			Value:              float64(process.MemoryUsage),
			RawValue:           strconv.FormatUint(process.MemoryUsage, 10),
			RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_UINT64,
			ObservedAtUnixNano: observedAt,
			SeriesIdentityHint: seriesHint,
			Attributes:         entries(attrs),
		})
	}

	metrics = append(metrics, cpu, memory)

	return metrics
}

func sysmonProcessCount(sample *sysmon.MetricSample) int {
	if sample.ProcessCount > 0 {
		return sample.ProcessCount
	}

	return len(sample.Processes)
}

func processAttributes(process sysmon.ProcessMetric) map[string]string {
	return map[string]string{
		"pid":        strconv.FormatUint(uint64(process.PID), 10),
		"name":       process.Name,
		"status":     process.Status,
		"start_time": process.StartTime,
	}
}

func processSeriesHint(process sysmon.ProcessMetric) string {
	return fmt.Sprintf("process:%d:%s", process.PID, strings.TrimSpace(process.Name))
}

func gaugeMetric(name, metricType, unit string, value float64, observedAt uint64, attrs map[string]string) *metricpb.Metric {
	return &metricpb.Metric{
		Name:        name,
		MetricType:  metricType,
		Kind:        metricpb.MetricKind_METRIC_KIND_GAUGE,
		Temporality: metricpb.MetricTemporality_METRIC_TEMPORALITY_UNSPECIFIED,
		Unit:        unit,
		Points: []*metricpb.MetricPoint{{
			Value:              value,
			RawValue:           strconv.FormatFloat(value, 'f', -1, 64),
			RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_DOUBLE,
			ObservedAtUnixNano: observedAt,
			Attributes:         entries(attrs),
		}},
	}
}

func cumulativeMetric(name, unit string, value uint64, observedAt uint64, attrs map[string]string) *metricpb.Metric {
	return &metricpb.Metric{
		Name:         name,
		MetricType:   sysmonNetworkMetricType,
		Kind:         metricpb.MetricKind_METRIC_KIND_SUM,
		Temporality:  metricpb.MetricTemporality_METRIC_TEMPORALITY_CUMULATIVE,
		IsMonotonic:  true,
		Unit:         unit,
		CounterWidth: 64,
		Points: []*metricpb.MetricPoint{{
			Value:              float64(value),
			RawValue:           strconv.FormatUint(value, 10),
			RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_UINT64,
			ObservedAtUnixNano: observedAt,
			Attributes:         entries(attrs),
		}},
	}
}

func parseMetricTimeNano(value string, fallback time.Time) uint64 {
	if parsed, err := time.Parse(time.RFC3339Nano, value); err == nil {
		return timeToUnixNano(parsed, fallback)
	}

	return timeToUnixNano(fallback, time.Now())
}

func timeToUnixNano(value time.Time, fallback time.Time) uint64 {
	if value.IsZero() {
		value = fallback
	}

	unixNano := value.UnixNano()
	if unixNano <= 0 {
		return uint64(time.Now().UnixNano())
	}

	return uint64(unixNano)
}

func entries(values map[string]string) []*metricpb.StringMapEntry {
	if len(values) == 0 {
		return nil
	}

	entries := make([]*metricpb.StringMapEntry, 0, len(values))
	for key, value := range values {
		if strings.TrimSpace(key) == "" || strings.TrimSpace(value) == "" {
			continue
		}

		entries = append(entries, &metricpb.StringMapEntry{Key: key, Value: value})
	}

	return entries
}

// snmpPointMetadata carries the per-point facts that must NOT fork the metric
// series. Tags and attributes feed TimeseriesSeriesKey (see
// observability/timeseries_series_key.ex canonical_components/1, which reads
// tags but never metadata), so a marker placed there would split every existing
// SNMP series in two.
func snmpPointMetadata(result snmpMetricResult, numeric bool) map[string]string {
	metadata := map[string]string{
		"oid":       result.OID,
		"oid_index": result.OIDIndex,
	}

	if result.ProfileID != "" {
		metadata["snmp_profile_id"] = result.ProfileID
	}

	if !numeric {
		metadata["non_numeric"] = "true"
	}

	return metadata
}

func numericMetricValue(value any) (float64, bool) {
	switch v := value.(type) {
	case float64:
		return v, true
	case float32:
		return float64(v), true
	case int:
		return float64(v), true
	case int64:
		return float64(v), true
	case uint64:
		return float64(v), true
	case uint:
		return float64(v), true
	case json.Number:
		parsed, err := v.Float64()
		return parsed, err == nil
	case string:
		parsed, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
		return parsed, err == nil
	default:
		return 0, false
	}
}

func rawMetricValue(values ...any) string {
	for _, value := range values {
		if value == nil {
			continue
		}

		return fmt.Sprint(value)
	}

	return ""
}

func metricValueType(values ...any) metricpb.MetricValueType {
	for _, value := range values {
		switch value.(type) {
		case float64, float32:
			return metricpb.MetricValueType_METRIC_VALUE_TYPE_DOUBLE
		case int, int64:
			return metricpb.MetricValueType_METRIC_VALUE_TYPE_INT64
		case uint, uint64:
			return metricpb.MetricValueType_METRIC_VALUE_TYPE_UINT64
		case bool:
			return metricpb.MetricValueType_METRIC_VALUE_TYPE_BOOL
		case string:
			return metricpb.MetricValueType_METRIC_VALUE_TYPE_STRING
		}
	}

	return metricpb.MetricValueType_METRIC_VALUE_TYPE_UNSPECIFIED
}

func metricKind(kind, dataType string, delta bool) metricpb.MetricKind {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "sum", "counter":
		return metricpb.MetricKind_METRIC_KIND_SUM
	case "gauge":
		return metricpb.MetricKind_METRIC_KIND_GAUGE
	}

	if delta || strings.Contains(strings.ToLower(dataType), "counter") {
		return metricpb.MetricKind_METRIC_KIND_SUM
	}

	return metricpb.MetricKind_METRIC_KIND_GAUGE
}

func metricTemporality(temporality string, delta bool, kind metricpb.MetricKind) metricpb.MetricTemporality {
	switch strings.ToLower(strings.TrimSpace(temporality)) {
	case "delta":
		return metricpb.MetricTemporality_METRIC_TEMPORALITY_DELTA
	case "cumulative":
		return metricpb.MetricTemporality_METRIC_TEMPORALITY_CUMULATIVE
	}

	if delta {
		return metricpb.MetricTemporality_METRIC_TEMPORALITY_DELTA
	}

	if kind == metricpb.MetricKind_METRIC_KIND_SUM {
		return metricpb.MetricTemporality_METRIC_TEMPORALITY_CUMULATIVE
	}

	return metricpb.MetricTemporality_METRIC_TEMPORALITY_UNSPECIFIED
}

func metricIsMonotonic(result snmpMetricResult, kind metricpb.MetricKind) bool {
	if result.IsMonotonic {
		return true
	}

	return kind == metricpb.MetricKind_METRIC_KIND_SUM &&
		!result.Delta &&
		strings.Contains(strings.ToLower(result.DataType), "counter")
}

func metricCounterWidth(width int, kind metricpb.MetricKind) uint32 {
	if width > 0 {
		return uint32(width)
	}

	if kind == metricpb.MetricKind_METRIC_KIND_SUM {
		return 64
	}

	return 0
}

func ptrString(value *string) string {
	if value == nil {
		return ""
	}

	return *value
}

func firstMetricNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}

	return ""
}

func int32Value(value *int) int32 {
	if value == nil {
		return 0
	}

	return int32(*value)
}
