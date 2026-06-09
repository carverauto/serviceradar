package main

import "code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"

const (
	proxmoxSignalSchemaProducerID             = "proxmox-inventory"
	proxmoxSignalSchemaProducerVersion        = "0.1.1"
	proxmoxSignalSchemaID                     = "com.carverauto.proxmox.resource_event"
	proxmoxSignalSchemaVersion                = "1.0.0"
	proxmoxSignalSchemaDisplayContractID      = "com.carverauto.proxmox.resource_event.display"
	proxmoxSignalSchemaDisplayContractVersion = "1.0.0"
	proxmoxSignalSchemaDisplayContractPath    = "display/resource_event.display.json"
)

func attachProxmoxSignalSchemaRef(event *sdk.OCSFEvent) {
	sdk.AttachSignalSchemaRef(event, sdk.SignalSchemaRef{
		ProducerID:             proxmoxSignalSchemaProducerID,
		ProducerVersion:        proxmoxSignalSchemaProducerVersion,
		SchemaID:               proxmoxSignalSchemaID,
		SchemaVersion:          proxmoxSignalSchemaVersion,
		DisplayContractID:      proxmoxSignalSchemaDisplayContractID,
		DisplayContractVersion: proxmoxSignalSchemaDisplayContractVersion,
		DisplayContract:        proxmoxSignalSchemaDisplayContractPath,
		SignalType:             sdk.SignalSchemaSignalTypeEvent,
		PayloadKind:            sdk.SignalSchemaPayloadKindOCSFEvent,
	})
}
