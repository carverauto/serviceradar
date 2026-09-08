package main

import (
	"encoding/binary"
	"math"
	"testing"
)

func TestEncodeMetricBatchProducesCanonicalMetricEnvelope(t *testing.T) {
	payload := encodeMetricBatch(metricBatch{
		Resource: metricResource{
			ServiceName: axisSignalSchemaProducerID,
			ServiceType: "wasm-plugin",
		},
		IngestIdentity: metricIngestIdentity{
			Source:       "plugin-metrics",
			ProducerID:   axisSignalSchemaProducerID,
			ProducerKind: "wasm-plugin",
		},
		EmittedAtUnixNano: 123,
		ObservedAt:        456,
		Samples: []metricTelemetrySample{{
			Name:  "axis_endpoint_success_total",
			Value: 3,
			Unit:  "count",
		}},
	})

	root := parseProtoFields(t, payload)
	if got := protoString(t, root, 1); got != metricEnvelopeSchemaVersion {
		t.Fatalf("schema_version = %q", got)
	}
	resource := parseSingleMessage(t, root, 2)
	if got := protoString(t, resource, 4); got != axisSignalSchemaProducerID {
		t.Fatalf("resource.service_name = %q", got)
	}
	identity := parseSingleMessage(t, root, 3)
	if got := protoString(t, identity, 2); got != metricEnvelopeSchemaVersion {
		t.Fatalf("ingest payload_kind = %q", got)
	}
	metric := parseSingleMessage(t, root, 20)
	if got := protoString(t, metric, 1); got != "axis_endpoint_success_total" {
		t.Fatalf("metric name = %q", got)
	}
	if got := protoVarint(t, metric, 3); got != 1 {
		t.Fatalf("metric kind = %d", got)
	}
	point := parseSingleMessage(t, metric, 20)
	if got := protoDouble(t, point, 1); got != 3 {
		t.Fatalf("point value = %v", got)
	}
}

type parsedProtoField struct {
	wire   int
	data   []byte
	varint uint64
	fixed  uint64
}

func parseProtoFields(t *testing.T, payload []byte) map[int][]parsedProtoField {
	t.Helper()
	out := map[int][]parsedProtoField{}
	for len(payload) > 0 {
		tag, n := binary.Uvarint(payload)
		if n <= 0 {
			t.Fatalf("invalid protobuf tag in %x", payload)
		}
		payload = payload[n:]
		field := int(tag >> 3)
		wire := int(tag & 0x7)
		parsed := parsedProtoField{wire: wire}
		switch wire {
		case 0:
			value, n := binary.Uvarint(payload)
			if n <= 0 {
				t.Fatalf("invalid varint for field %d", field)
			}
			parsed.varint = value
			payload = payload[n:]
		case 1:
			if len(payload) < 8 {
				t.Fatalf("short fixed64 for field %d", field)
			}
			parsed.fixed = binary.LittleEndian.Uint64(payload[:8])
			payload = payload[8:]
		case 2:
			size, n := binary.Uvarint(payload)
			if n <= 0 || uint64(len(payload[n:])) < size {
				t.Fatalf("invalid length-delimited field %d", field)
			}
			payload = payload[n:]
			parsed.data = append([]byte(nil), payload[:size]...)
			payload = payload[size:]
		default:
			t.Fatalf("unsupported wire type %d for field %d", wire, field)
		}
		out[field] = append(out[field], parsed)
	}
	return out
}

func parseSingleMessage(t *testing.T, fields map[int][]parsedProtoField, field int) map[int][]parsedProtoField {
	t.Helper()
	values := fields[field]
	if len(values) != 1 || values[0].wire != 2 {
		t.Fatalf("field %d is not one message: %#v", field, values)
	}
	return parseProtoFields(t, values[0].data)
}

func protoString(t *testing.T, fields map[int][]parsedProtoField, field int) string {
	t.Helper()
	values := fields[field]
	if len(values) != 1 || values[0].wire != 2 {
		t.Fatalf("field %d is not one string: %#v", field, values)
	}
	return string(values[0].data)
}

func protoVarint(t *testing.T, fields map[int][]parsedProtoField, field int) uint64 {
	t.Helper()
	values := fields[field]
	if len(values) != 1 || values[0].wire != 0 {
		t.Fatalf("field %d is not one varint: %#v", field, values)
	}
	return values[0].varint
}

func protoDouble(t *testing.T, fields map[int][]parsedProtoField, field int) float64 {
	t.Helper()
	values := fields[field]
	if len(values) != 1 || values[0].wire != 1 {
		t.Fatalf("field %d is not one fixed64: %#v", field, values)
	}
	return math.Float64frombits(values[0].fixed)
}
