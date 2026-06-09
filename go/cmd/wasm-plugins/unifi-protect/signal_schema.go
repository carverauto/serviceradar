package main

import "code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"

const (
	protectSignalSchemaProducerID             = "unifi-protect-camera"
	protectSignalSchemaProducerVersion        = "0.1.0"
	protectSignalSchemaID                     = "com.carverauto.unifi_protect.camera_event"
	protectSignalSchemaVersion                = "1.0.0"
	protectSignalSchemaDisplayContractID      = "com.carverauto.unifi_protect.camera_event.display"
	protectSignalSchemaDisplayContractVersion = "1.0.0"
	protectSignalSchemaDisplayContractPath    = "display/camera_event.display.json"
)

func attachProtectSignalSchemaRef(event *sdk.OCSFEvent) {
	sdk.AttachSignalSchemaRef(event, sdk.SignalSchemaRef{
		ProducerID:             protectSignalSchemaProducerID,
		ProducerVersion:        protectSignalSchemaProducerVersion,
		SchemaID:               protectSignalSchemaID,
		SchemaVersion:          protectSignalSchemaVersion,
		DisplayContractID:      protectSignalSchemaDisplayContractID,
		DisplayContractVersion: protectSignalSchemaDisplayContractVersion,
		DisplayContract:        protectSignalSchemaDisplayContractPath,
		SignalType:             sdk.SignalSchemaSignalTypeEvent,
		PayloadKind:            sdk.SignalSchemaPayloadKindOCSFEvent,
	})
}
