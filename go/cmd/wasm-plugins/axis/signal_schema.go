package main

import "github.com/carverauto/serviceradar-sdk-go/v2/sdk"

const (
	axisSignalSchemaProducerID             = "axis-camera"
	axisSignalSchemaProducerVersion        = "0.1.3"
	axisSignalSchemaID                     = "com.carverauto.axis_camera.event_log"
	axisSignalSchemaVersion                = "1.0.0"
	axisSignalSchemaDisplayContractID      = "com.carverauto.axis_camera.event_log.display"
	axisSignalSchemaDisplayContractVersion = "1.1.0"
	axisSignalSchemaDisplayContractPath    = "display/event_log_activity.display.json"
)

func axisSignalSchemaRef() sdk.SignalSchemaRef {
	return sdk.SignalSchemaRef{
		ProducerID:             axisSignalSchemaProducerID,
		ProducerVersion:        axisSignalSchemaProducerVersion,
		SchemaID:               axisSignalSchemaID,
		SchemaVersion:          axisSignalSchemaVersion,
		DisplayContractID:      axisSignalSchemaDisplayContractID,
		DisplayContractVersion: axisSignalSchemaDisplayContractVersion,
		DisplayContract:        axisSignalSchemaDisplayContractPath,
		SignalType:             sdk.SignalSchemaSignalTypeEvent,
		PayloadKind:            sdk.SignalSchemaPayloadKindOCSFEvent,
	}
}

func emitAxisTelemetry(events []sdk.OCSFEvent, sourceInstance string) {
	if len(events) == 0 {
		return
	}

	ref := axisSignalSchemaRef()
	records := make([]sdk.TelemetryRecord, 0, len(events))
	for _, event := range events {
		records = append(records, sdk.NewOCSFTelemetryRecord(event).WithSignalSchemaRef(ref))
	}

	err := sdk.EmitTelemetry(sdk.TelemetryBatch{
		Source: sdk.TelemetrySource{
			SourceType:     axisSignalSchemaProducerID,
			SourceInstance: sourceInstance,
		},
		Records: records,
	})
	if err != nil {
		sdk.Log.Warn("failed to emit axis telemetry: " + err.Error())
	}
}
