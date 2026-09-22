package main

import "github.com/carverauto/serviceradar-sdk-go/v2/sdk"

const (
	proxmoxSignalSchemaProducerID             = "proxmox-inventory"
	proxmoxSignalSchemaProducerVersion        = "0.1.8"
	proxmoxSignalSchemaID                     = "com.carverauto.proxmox.resource_event"
	proxmoxSignalSchemaVersion                = "1.0.0"
	proxmoxSignalSchemaDisplayContractID      = "com.carverauto.proxmox.resource_event.display"
	proxmoxSignalSchemaDisplayContractVersion = "1.1.0"
	proxmoxSignalSchemaDisplayContractPath    = "display/resource_event.display.json"
)

func proxmoxSignalSchemaRef() sdk.SignalSchemaRef {
	return sdk.SignalSchemaRef{
		ProducerID:             proxmoxSignalSchemaProducerID,
		ProducerVersion:        proxmoxSignalSchemaProducerVersion,
		SchemaID:               proxmoxSignalSchemaID,
		SchemaVersion:          proxmoxSignalSchemaVersion,
		DisplayContractID:      proxmoxSignalSchemaDisplayContractID,
		DisplayContractVersion: proxmoxSignalSchemaDisplayContractVersion,
		DisplayContract:        proxmoxSignalSchemaDisplayContractPath,
		SignalType:             sdk.SignalSchemaSignalTypeEvent,
		PayloadKind:            sdk.SignalSchemaPayloadKindOCSFEvent,
	}
}

func emitProxmoxTelemetry(events []sdk.OCSFEvent, sourceInstance string) {
	if len(events) == 0 {
		return
	}

	ref := proxmoxSignalSchemaRef()
	records := make([]sdk.TelemetryRecord, 0, len(events))
	for _, event := range events {
		records = append(records, sdk.NewOCSFTelemetryRecord(event).WithSignalSchemaRef(ref))
	}

	err := sdk.EmitTelemetry(sdk.TelemetryBatch{
		Source: sdk.TelemetrySource{
			SourceType:     proxmoxSignalSchemaProducerID,
			SourceInstance: sourceInstance,
		},
		Records: records,
	})
	if err != nil {
		sdk.Log.Warn("failed to emit proxmox telemetry: " + err.Error())
	}
}
