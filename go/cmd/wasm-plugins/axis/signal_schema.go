package main

import "code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"

const (
	axisSignalSchemaProducerID             = "axis-camera"
	axisSignalSchemaProducerVersion        = "0.1.0"
	axisSignalSchemaID                     = "com.carverauto.axis_camera.event_log"
	axisSignalSchemaVersion                = "1.0.0"
	axisSignalSchemaDisplayContractID      = "com.carverauto.axis_camera.event_log.display"
	axisSignalSchemaDisplayContractVersion = "1.0.0"
	axisSignalSchemaDisplayContractPath    = "display/event_log_activity.display.json"
)

func attachAxisSignalSchemaRef(event *sdk.OCSFEvent) {
	sdk.AttachSignalSchemaRef(event, sdk.SignalSchemaRef{
		ProducerID:             axisSignalSchemaProducerID,
		ProducerVersion:        axisSignalSchemaProducerVersion,
		SchemaID:               axisSignalSchemaID,
		SchemaVersion:          axisSignalSchemaVersion,
		DisplayContractID:      axisSignalSchemaDisplayContractID,
		DisplayContractVersion: axisSignalSchemaDisplayContractVersion,
		DisplayContract:        axisSignalSchemaDisplayContractPath,
		SignalType:             sdk.SignalSchemaSignalTypeEvent,
		PayloadKind:            sdk.SignalSchemaPayloadKindOCSFEvent,
	})
}
