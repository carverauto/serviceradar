package main

import (
	"encoding/base64"
	"encoding/binary"
	"math"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const (
	metricEnvelopeSchemaVersion = "serviceradar.metric.v1"
	metricPayloadKind           = "serviceradar_metrics"
)

type metricTelemetrySample struct {
	Name  string
	Value float64
	Unit  string
}

func emitProtectMetricTelemetry(sourceInstance string, cameraCount, streamCount, eventCount int) {
	now := uint64(time.Now().UTC().UnixNano())
	payload := encodeMetricBatch(metricBatch{
		Resource: metricResource{
			ServiceName: protectSignalSchemaProducerID,
			ServiceType: "wasm-plugin",
			Attributes: []metricStringMapEntry{
				{Key: "controller_host", Value: sourceInstance},
			},
		},
		IngestIdentity: metricIngestIdentity{
			Source:       "plugin-metrics",
			ProducerID:   protectSignalSchemaProducerID,
			ProducerKind: "wasm-plugin",
		},
		EmittedAtUnixNano: now,
		ObservedAt:        now,
		Samples: []metricTelemetrySample{
			{Name: "unifi_protect_camera_total", Value: float64(cameraCount), Unit: "count"},
			{Name: "unifi_protect_stream_total", Value: float64(streamCount), Unit: "count"},
			{Name: "unifi_protect_event_total", Value: float64(eventCount), Unit: "count"},
		},
	})

	err := sdk.EmitTelemetry(sdk.TelemetryBatch{
		Source: sdk.TelemetrySource{
			SourceType:     protectSignalSchemaProducerID,
			SourceInstance: sourceInstance,
		},
		Records: []sdk.TelemetryRecord{{
			EventID:              "unifi-protect-metrics-" + strconv.FormatUint(now, 10),
			ObservedTimeUnixNano: int64(now),
			EventTimeUnixNano:    int64(now),
			PayloadKind:          metricPayloadKind,
			Payload:              base64.StdEncoding.EncodeToString(payload),
		}},
	})
	if err != nil {
		sdk.Log.Warn("failed to emit unifi protect metric telemetry: " + err.Error())
	}
}

type metricBatch struct {
	Resource          metricResource
	IngestIdentity    metricIngestIdentity
	EmittedAtUnixNano uint64
	Samples           []metricTelemetrySample
	ObservedAt        uint64
}

type metricResource struct {
	ServiceName string
	ServiceType string
	Attributes  []metricStringMapEntry
}

type metricIngestIdentity struct {
	Source       string
	ProducerID   string
	ProducerKind string
}

type metricStringMapEntry struct {
	Key   string
	Value string
}

func encodeMetricBatch(batch metricBatch) []byte {
	var out []byte
	out = appendString(out, 1, metricEnvelopeSchemaVersion)
	out = appendMessage(out, 2, encodeMetricResource(batch.Resource))
	out = appendMessage(out, 3, encodeMetricIngestIdentity(batch.IngestIdentity))
	out = appendUint64(out, 6, batch.EmittedAtUnixNano)
	for _, sample := range batch.Samples {
		out = appendMessage(out, 20, encodeMetric(sample, batch.ObservedAt))
	}
	return out
}

func encodeMetricResource(resource metricResource) []byte {
	var out []byte
	out = appendString(out, 4, resource.ServiceName)
	out = appendString(out, 5, resource.ServiceType)
	for _, attr := range resource.Attributes {
		out = appendMessage(out, 20, encodeMetricStringMapEntry(attr))
	}
	return out
}

func encodeMetricIngestIdentity(identity metricIngestIdentity) []byte {
	var out []byte
	out = appendString(out, 1, identity.Source)
	out = appendString(out, 2, metricEnvelopeSchemaVersion)
	out = appendString(out, 3, identity.ProducerID)
	out = appendString(out, 4, identity.ProducerKind)
	return out
}

func encodeMetric(sample metricTelemetrySample, observedAt uint64) []byte {
	var out []byte
	out = appendString(out, 1, sample.Name)
	out = appendString(out, 2, "plugin")
	out = appendInt32(out, 3, 1)
	out = appendString(out, 6, sample.Unit)
	out = appendMessage(out, 20, encodeMetricPoint(sample.Value, observedAt))
	return out
}

func encodeMetricPoint(value float64, observedAt uint64) []byte {
	var out []byte
	out = appendDouble(out, 1, value)
	out = appendString(out, 2, strconv.FormatFloat(value, 'f', -1, 64))
	out = appendInt32(out, 3, 1)
	out = appendUint64(out, 4, observedAt)
	return out
}

func encodeMetricStringMapEntry(entry metricStringMapEntry) []byte {
	var out []byte
	out = appendString(out, 1, entry.Key)
	out = appendString(out, 2, entry.Value)
	return out
}

func appendString(out []byte, field int, value string) []byte {
	if value == "" {
		return out
	}
	out = appendTag(out, field, 2)
	out = binary.AppendUvarint(out, uint64(len(value)))
	return append(out, value...)
}

func appendMessage(out []byte, field int, value []byte) []byte {
	if len(value) == 0 {
		return out
	}
	out = appendTag(out, field, 2)
	out = binary.AppendUvarint(out, uint64(len(value)))
	return append(out, value...)
}

func appendInt32(out []byte, field int, value int32) []byte {
	if value == 0 {
		return out
	}
	out = appendTag(out, field, 0)
	return binary.AppendUvarint(out, uint64(value))
}

func appendUint64(out []byte, field int, value uint64) []byte {
	if value == 0 {
		return out
	}
	out = appendTag(out, field, 0)
	return binary.AppendUvarint(out, value)
}

func appendDouble(out []byte, field int, value float64) []byte {
	if value == 0 {
		return out
	}
	out = appendTag(out, field, 1)
	var buf [8]byte
	binary.LittleEndian.PutUint64(buf[:], math.Float64bits(value))
	return append(out, buf[:]...)
}

func appendTag(out []byte, field int, wireType int) []byte {
	return binary.AppendUvarint(out, uint64(field<<3|wireType))
}
