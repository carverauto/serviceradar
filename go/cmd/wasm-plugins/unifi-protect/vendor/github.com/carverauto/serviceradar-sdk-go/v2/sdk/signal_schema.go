package sdk

const (
	SignalSchemaMetadataServiceRadar           = "service_radar"
	SignalSchemaMetadataSignalSchema           = "signal_schema"
	SignalSchemaMetadataProducerID             = "producer_id"
	SignalSchemaMetadataProducerVersion        = "producer_version"
	SignalSchemaMetadataSchemaID               = "schema_id"
	SignalSchemaMetadataSchemaVersion          = "schema_version"
	SignalSchemaMetadataDisplayContractID      = "display_contract_id"
	SignalSchemaMetadataDisplayContractVersion = "display_contract_version"
	SignalSchemaMetadataDisplayContract        = "display_contract"
	SignalSchemaMetadataSignalType             = "signal_type"
	SignalSchemaMetadataPayloadKind            = "payload_kind"
	SignalSchemaSignalTypeEvent                = "event"
	SignalSchemaSignalTypeLog                  = "log"
	SignalSchemaPayloadKindOCSFEvent           = "ocsf_event"
	SignalSchemaPayloadKindOTELLog             = "otel_log"
	SignalSchemaPayloadKindServiceRadarMetrics = "serviceradar_metrics"
)

// SignalSchemaRef identifies the package-managed schema and display contract
// that should be used to render an emitted plugin signal.
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

// AttachSignalSchemaRef stores a signal schema/display reference in the
// ServiceRadar extension metadata for an OCSF event.
func AttachSignalSchemaRef(event *OCSFEvent, ref SignalSchemaRef) *OCSFEvent {
	if event == nil {
		return nil
	}
	if event.Metadata == nil {
		event.Metadata = map[string]any{}
	}

	serviceRadar, _ := event.Metadata[SignalSchemaMetadataServiceRadar].(map[string]any)
	if serviceRadar == nil {
		serviceRadar = map[string]any{}
		event.Metadata[SignalSchemaMetadataServiceRadar] = serviceRadar
	}

	signalSchema := map[string]any{}
	putSignalSchemaField(signalSchema, SignalSchemaMetadataProducerID, ref.ProducerID)
	putSignalSchemaField(signalSchema, SignalSchemaMetadataProducerVersion, ref.ProducerVersion)
	putSignalSchemaField(signalSchema, SignalSchemaMetadataSchemaID, ref.SchemaID)
	putSignalSchemaField(signalSchema, SignalSchemaMetadataSchemaVersion, ref.SchemaVersion)
	putSignalSchemaField(signalSchema, SignalSchemaMetadataDisplayContractID, ref.DisplayContractID)
	putSignalSchemaField(signalSchema, SignalSchemaMetadataDisplayContractVersion, ref.DisplayContractVersion)
	putSignalSchemaField(signalSchema, SignalSchemaMetadataDisplayContract, ref.DisplayContract)
	putSignalSchemaField(signalSchema, SignalSchemaMetadataSignalType, ref.SignalType)
	putSignalSchemaField(signalSchema, SignalSchemaMetadataPayloadKind, ref.PayloadKind)

	serviceRadar[SignalSchemaMetadataSignalSchema] = signalSchema

	return event
}

func putSignalSchemaField(metadata map[string]any, key, value string) {
	if value != "" {
		metadata[key] = value
	}
}
