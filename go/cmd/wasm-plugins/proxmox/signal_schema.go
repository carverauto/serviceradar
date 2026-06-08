package main

import "code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"

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

	proxmoxSignalSchemaProducerID             = "proxmox-inventory"
	proxmoxSignalSchemaProducerVersion        = "0.1.1"
	proxmoxSignalSchemaID                     = "com.carverauto.proxmox.resource_event"
	proxmoxSignalSchemaVersion                = "1.0.0"
	proxmoxSignalSchemaDisplayContractID      = "com.carverauto.proxmox.resource_event.display"
	proxmoxSignalSchemaDisplayContractVersion = "1.0.0"
	proxmoxSignalSchemaDisplayContractPath    = "display/resource_event.display.json"
)

func attachProxmoxSignalSchemaRef(event *sdk.OCSFEvent) {
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
		signalSchemaMetadataProducerID:             proxmoxSignalSchemaProducerID,
		signalSchemaMetadataProducerVersion:        proxmoxSignalSchemaProducerVersion,
		signalSchemaMetadataSchemaID:               proxmoxSignalSchemaID,
		signalSchemaMetadataSchemaVersion:          proxmoxSignalSchemaVersion,
		signalSchemaMetadataDisplayContractID:      proxmoxSignalSchemaDisplayContractID,
		signalSchemaMetadataDisplayContractVersion: proxmoxSignalSchemaDisplayContractVersion,
		signalSchemaMetadataDisplayContract:        proxmoxSignalSchemaDisplayContractPath,
		signalSchemaMetadataSignalType:             "event",
		signalSchemaMetadataPayloadKind:            "ocsf_event",
	}
}
