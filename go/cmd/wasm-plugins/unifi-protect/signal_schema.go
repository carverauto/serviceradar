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

	protectSignalSchemaProducerID             = "unifi-protect-camera"
	protectSignalSchemaProducerVersion        = "0.1.0"
	protectSignalSchemaID                     = "com.carverauto.unifi_protect.camera_event"
	protectSignalSchemaVersion                = "1.0.0"
	protectSignalSchemaDisplayContractID      = "com.carverauto.unifi_protect.camera_event.display"
	protectSignalSchemaDisplayContractVersion = "1.0.0"
	protectSignalSchemaDisplayContractPath    = "display/camera_event.display.json"
)

func attachProtectSignalSchemaRef(event *sdk.OCSFEvent) {
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
		signalSchemaMetadataProducerID:             protectSignalSchemaProducerID,
		signalSchemaMetadataProducerVersion:        protectSignalSchemaProducerVersion,
		signalSchemaMetadataSchemaID:               protectSignalSchemaID,
		signalSchemaMetadataSchemaVersion:          protectSignalSchemaVersion,
		signalSchemaMetadataDisplayContractID:      protectSignalSchemaDisplayContractID,
		signalSchemaMetadataDisplayContractVersion: protectSignalSchemaDisplayContractVersion,
		signalSchemaMetadataDisplayContract:        protectSignalSchemaDisplayContractPath,
		signalSchemaMetadataSignalType:             "event",
		signalSchemaMetadataPayloadKind:            "ocsf_event",
	}
}
