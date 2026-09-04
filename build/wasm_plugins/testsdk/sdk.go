package sdk

const (
	SignalSchemaSignalTypeEvent      = "event"
	SignalSchemaPayloadKindOCSFEvent = "ocsf_event"
)

// SignalSchemaRef exactly mirrors the package-managed display reference in the
// pinned serviceradar-sdk-go v0.3.1. The rest of this file is the smallest
// compile-only surface needed to build the real plugin signal_schema.go files.
type SignalSchemaRef struct {
	ProducerID             string
	ProducerVersion        string
	SchemaID               string
	SchemaVersion          string
	DisplayContractID      string
	DisplayContractVersion string
	DisplayContract        string
	SignalType             string
	PayloadKind            string
}

type OCSFEvent struct{}

type TelemetryRecord struct{}

func NewOCSFTelemetryRecord(OCSFEvent) TelemetryRecord {
	return TelemetryRecord{}
}

func (record TelemetryRecord) WithSignalSchemaRef(SignalSchemaRef) TelemetryRecord {
	return record
}

type TelemetrySource struct {
	SourceType     string
	SourceInstance string
}

type TelemetryBatch struct {
	Source  TelemetrySource
	Records []TelemetryRecord
}

func EmitTelemetry(TelemetryBatch) error {
	return nil
}

type Logger struct{}

func (Logger) Warn(string) {}

var Log Logger
