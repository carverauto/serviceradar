package main

import "github.com/carverauto/serviceradar-sdk-go/sdk"

const (
	signalSchemaMetadataProducerID             = "producer_id"
	signalSchemaMetadataProducerVersion        = "producer_version"
	signalSchemaMetadataSchemaID               = "schema_id"
	signalSchemaMetadataSchemaVersion          = "schema_version"
	signalSchemaMetadataDisplayContractID      = "display_contract_id"
	signalSchemaMetadataDisplayContractVersion = "display_contract_version"
	signalSchemaMetadataDisplayContract        = "display_contract"
	signalSchemaMetadataSignalType             = "signal_type"
	signalSchemaMetadataPayloadKind            = "payload_kind"

	axisSignalSchemaProducerID             = "axis-camera"
	axisSignalSchemaProducerVersion        = "0.1.0"
	axisSignalSchemaID                     = "com.carverauto.axis_camera.event_log"
	axisSignalSchemaVersion                = "1.0.0"
	axisSignalSchemaDisplayContractID      = "com.carverauto.axis_camera.event_log.display"
	axisSignalSchemaDisplayContractVersion = "1.0.0"
	axisSignalSchemaDisplayContractPath    = "display/event_log_activity.display.json"
)

func attachAxisSignalSchemaRef(event *sdk.OCSFEvent) {
	if event == nil {
		return
	}
	if event.Metadata == nil {
		event.Metadata = map[string]any{}
	}

	serviceRadar, _ := event.Metadata["service_radar"].(map[string]any)
	if serviceRadar == nil {
		serviceRadar = map[string]any{}
		event.Metadata["service_radar"] = serviceRadar
	}

	serviceRadar["signal_schema"] = map[string]any{
		signalSchemaMetadataProducerID:             axisSignalSchemaProducerID,
		signalSchemaMetadataProducerVersion:        axisSignalSchemaProducerVersion,
		signalSchemaMetadataSchemaID:               axisSignalSchemaID,
		signalSchemaMetadataSchemaVersion:          axisSignalSchemaVersion,
		signalSchemaMetadataDisplayContractID:      axisSignalSchemaDisplayContractID,
		signalSchemaMetadataDisplayContractVersion: axisSignalSchemaDisplayContractVersion,
		signalSchemaMetadataDisplayContract:        axisSignalSchemaDisplayContractPath,
		signalSchemaMetadataSignalType:             "event",
		signalSchemaMetadataPayloadKind:            "ocsf_event",
	}
}
