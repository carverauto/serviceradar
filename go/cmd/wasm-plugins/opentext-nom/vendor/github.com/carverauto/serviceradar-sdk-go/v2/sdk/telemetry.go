package sdk

import (
	"encoding/base64"
	"encoding/json"
	"time"
)

const (
	telemetryMetadataPrefix = "serviceradar.signal_schema."
)

// TelemetrySource identifies the plugin telemetry producer instance.
type TelemetrySource struct {
	SourceType     string            `json:"source_type,omitempty"`
	SourceInstance string            `json:"source_instance,omitempty"`
	Metadata       map[string]string `json:"metadata,omitempty"`
}

// TelemetryRecord is one plugin-emitted observability signal.
type TelemetryRecord struct {
	EventID              string            `json:"event_id,omitempty"`
	ObservedTimeUnixNano int64             `json:"observed_time_unix_nano,omitempty"`
	EventTimeUnixNano    int64             `json:"event_time_unix_nano,omitempty"`
	PayloadKind          string            `json:"payload_kind"`
	Payload              any               `json:"payload"`
	Metadata             map[string]string `json:"metadata,omitempty"`
}

// TelemetryBatch is the JSON ABI payload accepted by env.emit_telemetry.
type TelemetryBatch struct {
	Source  TelemetrySource   `json:"source,omitempty"`
	Records []TelemetryRecord `json:"records"`
}

// NewOCSFTelemetryRecord wraps an OCSF event for first-class plugin telemetry emission.
func NewOCSFTelemetryRecord(event OCSFEvent) TelemetryRecord {
	eventTime := event.Time
	if eventTime.IsZero() {
		eventTime = time.Now().UTC()
		event.Time = eventTime
	}

	return TelemetryRecord{
		EventID:              event.ID,
		ObservedTimeUnixNano: time.Now().UTC().UnixNano(),
		EventTimeUnixNano:    eventTime.UnixNano(),
		PayloadKind:          SignalSchemaPayloadKindOCSFEvent,
		Payload:              event,
	}
}

// NewOTELLogTelemetryRecord wraps an OTEL-style JSON log record for first-class plugin telemetry emission.
func NewOTELLogTelemetryRecord(eventID string, log map[string]any) TelemetryRecord {
	now := time.Now().UTC().UnixNano()

	return TelemetryRecord{
		EventID:              eventID,
		ObservedTimeUnixNano: now,
		EventTimeUnixNano:    now,
		PayloadKind:          SignalSchemaPayloadKindOTELLog,
		Payload:              log,
	}
}

// NewServiceRadarMetricTelemetryRecord wraps a marshaled
// serviceradar.metric.v1.MetricBatch for first-class metric telemetry emission.
func NewServiceRadarMetricTelemetryRecord(eventID string, metricBatchProto []byte) TelemetryRecord {
	now := time.Now().UTC().UnixNano()

	return TelemetryRecord{
		EventID:              eventID,
		ObservedTimeUnixNano: now,
		EventTimeUnixNano:    now,
		PayloadKind:          SignalSchemaPayloadKindServiceRadarMetrics,
		Payload:              base64.StdEncoding.EncodeToString(metricBatchProto),
	}
}

// AttachSignalSchemaRef stores a flat signal schema reference on a telemetry record.
func (r *TelemetryRecord) AttachSignalSchemaRef(ref SignalSchemaRef) *TelemetryRecord {
	if r == nil {
		return nil
	}
	if r.Metadata == nil {
		r.Metadata = map[string]string{}
	}

	putTelemetrySignalSchemaField(r.Metadata, SignalSchemaMetadataProducerID, ref.ProducerID)
	putTelemetrySignalSchemaField(r.Metadata, SignalSchemaMetadataProducerVersion, ref.ProducerVersion)
	putTelemetrySignalSchemaField(r.Metadata, SignalSchemaMetadataSchemaID, ref.SchemaID)
	putTelemetrySignalSchemaField(r.Metadata, SignalSchemaMetadataSchemaVersion, ref.SchemaVersion)
	putTelemetrySignalSchemaField(r.Metadata, SignalSchemaMetadataDisplayContractID, ref.DisplayContractID)
	putTelemetrySignalSchemaField(r.Metadata, SignalSchemaMetadataDisplayContractVersion, ref.DisplayContractVersion)
	putTelemetrySignalSchemaField(r.Metadata, SignalSchemaMetadataDisplayContract, ref.DisplayContract)
	putTelemetrySignalSchemaField(r.Metadata, SignalSchemaMetadataSignalType, ref.SignalType)
	putTelemetrySignalSchemaField(r.Metadata, SignalSchemaMetadataPayloadKind, ref.PayloadKind)

	return r
}

// WithSignalSchemaRef returns a copy of the record with signal schema metadata attached.
func (r TelemetryRecord) WithSignalSchemaRef(ref SignalSchemaRef) TelemetryRecord {
	r.AttachSignalSchemaRef(ref)
	return r
}

// Serialize returns the env.emit_telemetry JSON payload.
func (b TelemetryBatch) Serialize() ([]byte, error) {
	return json.Marshal(b)
}

// EmitTelemetry sends a first-class telemetry batch to the ServiceRadar host.
func EmitTelemetry(batch TelemetryBatch) error {
	payload, err := batch.Serialize()
	if err != nil {
		return err
	}
	if len(payload) == 0 {
		return HostError{Code: hostErrInvalid, Op: "emit_telemetry"}
	}

	res := callHostEmitTelemetry(payload)
	return hostErr(res, "emit_telemetry")
}

func putTelemetrySignalSchemaField(metadata map[string]string, key, value string) {
	if value != "" {
		metadata[telemetryMetadataPrefix+key] = value
	}
}
