package sdk

import (
	"encoding/base64"
	"encoding/binary"
	"math"
	"time"
)

const MetricEnvelopeSchemaVersion = "serviceradar.metric.v1"

type MetricKind int32

const (
	MetricKindUnspecified MetricKind = 0
	MetricKindGauge       MetricKind = 1
	MetricKindSum         MetricKind = 2
	MetricKindHistogram   MetricKind = 3
)

type MetricTemporality int32

const (
	MetricTemporalityUnspecified MetricTemporality = 0
	MetricTemporalityDelta       MetricTemporality = 1
	MetricTemporalityCumulative  MetricTemporality = 2
)

type MetricValueType int32

const (
	MetricValueTypeUnspecified MetricValueType = 0
	MetricValueTypeDouble      MetricValueType = 1
	MetricValueTypeInt64       MetricValueType = 2
	MetricValueTypeUint64      MetricValueType = 3
	MetricValueTypeBool        MetricValueType = 4
	MetricValueTypeString      MetricValueType = 5
)

type MetricStringMapEntry struct {
	Key   string
	Value string
}

type MetricResource struct {
	AgentID        string
	GatewayID      string
	Partition      string
	ServiceName    string
	ServiceType    string
	HostID         string
	HostIP         string
	TargetDeviceIP string
	DeviceID       string
	KVStoreID      string
	Attributes     []MetricStringMapEntry
}

type MetricIngestIdentity struct {
	Source       string
	PayloadKind  string
	ProducerID   string
	ProducerKind string
	AttestedBy   string
	Attributes   []MetricStringMapEntry
}

type MetricPoint struct {
	Value              float64
	RawValue           string
	RawValueType       MetricValueType
	ObservedAtUnixNano uint64
	StartTimeUnixNano  uint64
	ResetAnchor        string
	IfIndex            int32
	InterfaceUID       string
	SeriesIdentityHint string
	Attributes         []MetricStringMapEntry
	Metadata           []MetricStringMapEntry
}

type Metric struct {
	Name         string
	MetricType   string
	Kind         MetricKind
	Temporality  MetricTemporality
	IsMonotonic  bool
	Unit         string
	Scale        float64
	CounterWidth uint32
	Points       []MetricPoint
	Tags         []MetricStringMapEntry
	Metadata     []MetricStringMapEntry
	Thresholds   []MetricStringMapEntry
}

type MetricBatch struct {
	SchemaVersion            string
	Resource                 MetricResource
	IngestIdentity           MetricIngestIdentity
	IngressID                string
	IngressTimestampUnixNano uint64
	EmittedAtUnixNano        uint64
	Metrics                  []Metric
}

// NewServiceRadarMetricTelemetryRecordFromBatch builds and wraps one canonical
// ServiceRadar metric batch. It uses a tiny protobuf encoder instead of the Go
// protobuf runtime so TinyGo plugins do not pull in reflection-heavy code.
func NewServiceRadarMetricTelemetryRecordFromBatch(eventID string, batch MetricBatch) TelemetryRecord {
	now := time.Now().UTC().UnixNano()
	if batch.EmittedAtUnixNano == 0 {
		batch.EmittedAtUnixNano = uint64(now)
	}

	return TelemetryRecord{
		EventID:              eventID,
		ObservedTimeUnixNano: now,
		EventTimeUnixNano:    now,
		PayloadKind:          SignalSchemaPayloadKindServiceRadarMetrics,
		Payload:              encodeBase64(metricBatchProto(batch)),
	}
}

// MarshalServiceRadarMetricBatch serializes a canonical metric batch for use
// with NewServiceRadarMetricTelemetryRecord. It exists for callers that need to
// set custom event timestamps on the TelemetryRecord.
func MarshalServiceRadarMetricBatch(batch MetricBatch) []byte {
	return metricBatchProto(batch)
}

func metricBatchProto(batch MetricBatch) []byte {
	if batch.SchemaVersion == "" {
		batch.SchemaVersion = MetricEnvelopeSchemaVersion
	}
	if batch.IngestIdentity.PayloadKind == "" {
		batch.IngestIdentity.PayloadKind = MetricEnvelopeSchemaVersion
	}

	var out []byte
	out = appendStringField(out, 1, batch.SchemaVersion)
	out = appendMessageField(out, 2, metricResourceProto(batch.Resource))
	out = appendMessageField(out, 3, metricIngestIdentityProto(batch.IngestIdentity))
	out = appendStringField(out, 4, batch.IngressID)
	out = appendUint64Field(out, 5, batch.IngressTimestampUnixNano)
	out = appendUint64Field(out, 6, batch.EmittedAtUnixNano)
	for _, metric := range batch.Metrics {
		out = appendMessageField(out, 20, metricProto(metric))
	}
	return out
}

func metricResourceProto(resource MetricResource) []byte {
	var out []byte
	out = appendStringField(out, 1, resource.AgentID)
	out = appendStringField(out, 2, resource.GatewayID)
	out = appendStringField(out, 3, resource.Partition)
	out = appendStringField(out, 4, resource.ServiceName)
	out = appendStringField(out, 5, resource.ServiceType)
	out = appendStringField(out, 6, resource.HostID)
	out = appendStringField(out, 7, resource.HostIP)
	out = appendStringField(out, 8, resource.TargetDeviceIP)
	out = appendStringField(out, 9, resource.DeviceID)
	out = appendStringField(out, 10, resource.KVStoreID)
	out = appendStringMapEntries(out, 20, resource.Attributes)
	return out
}

func metricIngestIdentityProto(identity MetricIngestIdentity) []byte {
	var out []byte
	out = appendStringField(out, 1, identity.Source)
	out = appendStringField(out, 2, identity.PayloadKind)
	out = appendStringField(out, 3, identity.ProducerID)
	out = appendStringField(out, 4, identity.ProducerKind)
	out = appendStringField(out, 5, identity.AttestedBy)
	out = appendStringMapEntries(out, 20, identity.Attributes)
	return out
}

func metricProto(metric Metric) []byte {
	var out []byte
	out = appendStringField(out, 1, metric.Name)
	out = appendStringField(out, 2, metric.MetricType)
	out = appendInt32Field(out, 3, int32(metric.Kind))
	out = appendInt32Field(out, 4, int32(metric.Temporality))
	out = appendBoolField(out, 5, metric.IsMonotonic)
	out = appendStringField(out, 6, metric.Unit)
	out = appendDoubleField(out, 7, metric.Scale)
	out = appendUint32Field(out, 8, metric.CounterWidth)
	for _, point := range metric.Points {
		out = appendMessageField(out, 20, metricPointProto(point))
	}
	out = appendStringMapEntries(out, 30, metric.Tags)
	out = appendStringMapEntries(out, 31, metric.Metadata)
	out = appendStringMapEntries(out, 32, metric.Thresholds)
	return out
}

func metricPointProto(point MetricPoint) []byte {
	var out []byte
	out = appendDoubleField(out, 1, point.Value)
	out = appendStringField(out, 2, point.RawValue)
	out = appendInt32Field(out, 3, int32(point.RawValueType))
	out = appendUint64Field(out, 4, point.ObservedAtUnixNano)
	out = appendUint64Field(out, 5, point.StartTimeUnixNano)
	out = appendStringField(out, 6, point.ResetAnchor)
	out = appendInt32Field(out, 7, point.IfIndex)
	out = appendStringField(out, 8, point.InterfaceUID)
	out = appendStringField(out, 9, point.SeriesIdentityHint)
	out = appendStringMapEntries(out, 20, point.Attributes)
	out = appendStringMapEntries(out, 21, point.Metadata)
	return out
}

func stringMapEntryProto(entry MetricStringMapEntry) []byte {
	var out []byte
	out = appendStringField(out, 1, entry.Key)
	out = appendStringField(out, 2, entry.Value)
	return out
}

func appendStringMapEntries(out []byte, field int, entries []MetricStringMapEntry) []byte {
	for _, entry := range entries {
		out = appendMessageField(out, field, stringMapEntryProto(entry))
	}
	return out
}

func appendStringField(out []byte, field int, value string) []byte {
	if value == "" {
		return out
	}
	out = appendTag(out, field, 2)
	out = binary.AppendUvarint(out, uint64(len(value)))
	return append(out, value...)
}

func appendMessageField(out []byte, field int, value []byte) []byte {
	if len(value) == 0 {
		return out
	}
	out = appendTag(out, field, 2)
	out = binary.AppendUvarint(out, uint64(len(value)))
	return append(out, value...)
}

func appendInt32Field(out []byte, field int, value int32) []byte {
	if value == 0 {
		return out
	}
	out = appendTag(out, field, 0)
	return binary.AppendUvarint(out, uint64(value))
}

func appendUint32Field(out []byte, field int, value uint32) []byte {
	if value == 0 {
		return out
	}
	out = appendTag(out, field, 0)
	return binary.AppendUvarint(out, uint64(value))
}

func appendUint64Field(out []byte, field int, value uint64) []byte {
	if value == 0 {
		return out
	}
	out = appendTag(out, field, 0)
	return binary.AppendUvarint(out, value)
}

func appendBoolField(out []byte, field int, value bool) []byte {
	if !value {
		return out
	}
	out = appendTag(out, field, 0)
	return append(out, 1)
}

func appendDoubleField(out []byte, field int, value float64) []byte {
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

func encodeBase64(payload []byte) string {
	return base64.StdEncoding.EncodeToString(payload)
}
