package main

import "github.com/carverauto/serviceradar-sdk-go/v2/sdk"

const (
	protectSignalSchemaProducerID             = "unifi-protect-camera"
	protectSignalSchemaProducerVersion        = "0.1.4"
	protectSignalSchemaID                     = "com.carverauto.unifi_protect.camera_event"
	protectSignalSchemaVersion                = "1.0.0"
	protectSignalSchemaDisplayContractID      = "com.carverauto.unifi_protect.camera_event.display"
	protectSignalSchemaDisplayContractVersion = "1.1.0"
	protectSignalSchemaDisplayContractPath    = "display/camera_event.display.json"
)

func protectSignalSchemaRef() sdk.SignalSchemaRef {
	return sdk.SignalSchemaRef{
		ProducerID:             protectSignalSchemaProducerID,
		ProducerVersion:        protectSignalSchemaProducerVersion,
		SchemaID:               protectSignalSchemaID,
		SchemaVersion:          protectSignalSchemaVersion,
		DisplayContractID:      protectSignalSchemaDisplayContractID,
		DisplayContractVersion: protectSignalSchemaDisplayContractVersion,
		DisplayContract:        protectSignalSchemaDisplayContractPath,
		SignalType:             sdk.SignalSchemaSignalTypeEvent,
		PayloadKind:            sdk.SignalSchemaPayloadKindOCSFEvent,
	}
}

func emitProtectTelemetry(events []sdk.OCSFEvent, sourceInstance string) {
	if len(events) == 0 {
		return
	}

	ref := protectSignalSchemaRef()
	records := make([]sdk.TelemetryRecord, 0, len(events))
	for _, event := range events {
		records = append(records, sdk.NewOCSFTelemetryRecord(event).WithSignalSchemaRef(ref))
	}

	err := sdk.EmitTelemetry(sdk.TelemetryBatch{
		Source: sdk.TelemetrySource{
			SourceType:     protectSignalSchemaProducerID,
			SourceInstance: sourceInstance,
		},
		Records: records,
	})
	if err != nil {
		sdk.Log.Warn("failed to emit unifi protect telemetry: " + err.Error())
	}
}
