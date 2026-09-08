/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package addon

import (
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
)

const (
	SignalSchemaMetadataProducerID             = "serviceradar.signal_schema.producer_id"
	SignalSchemaMetadataProducerVersion        = "serviceradar.signal_schema.producer_version"
	SignalSchemaMetadataSchemaID               = "serviceradar.signal_schema.schema_id"
	SignalSchemaMetadataSchemaVersion          = "serviceradar.signal_schema.schema_version"
	SignalSchemaMetadataDisplayContractID      = "serviceradar.signal_schema.display_contract_id"
	SignalSchemaMetadataDisplayContractVersion = "serviceradar.signal_schema.display_contract_version"
	SignalSchemaMetadataDisplayContract        = "serviceradar.signal_schema.display_contract"
	SignalSchemaMetadataSignalType             = "serviceradar.signal_schema.signal_type"
	SignalSchemaMetadataPayloadKind            = "serviceradar.signal_schema.payload_kind"
)

// SignalSchemaRef is the bounded display/schema reference attached to package
// telemetry records. The referenced package bundle owns the full schemas and
// display contracts; records carry only this small pointer.
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

// AttachSignalSchemaRef stores a signal schema reference on a telemetry record's
// metadata map. Empty optional fields are omitted.
func AttachSignalSchemaRef(record *addonpb.TelemetryRecord, ref SignalSchemaRef) *addonpb.TelemetryRecord {
	if record == nil {
		return nil
	}
	if record.Metadata == nil {
		record.Metadata = map[string]string{}
	}

	putMetadata(record.Metadata, SignalSchemaMetadataProducerID, ref.ProducerID)
	putMetadata(record.Metadata, SignalSchemaMetadataProducerVersion, ref.ProducerVersion)
	putMetadata(record.Metadata, SignalSchemaMetadataSchemaID, ref.SchemaID)
	putMetadata(record.Metadata, SignalSchemaMetadataSchemaVersion, ref.SchemaVersion)
	putMetadata(record.Metadata, SignalSchemaMetadataDisplayContractID, ref.DisplayContractID)
	putMetadata(record.Metadata, SignalSchemaMetadataDisplayContractVersion, ref.DisplayContractVersion)
	putMetadata(record.Metadata, SignalSchemaMetadataDisplayContract, ref.DisplayContract)
	putMetadata(record.Metadata, SignalSchemaMetadataSignalType, ref.SignalType)
	putMetadata(record.Metadata, SignalSchemaMetadataPayloadKind, ref.PayloadKind)

	return record
}

func putMetadata(metadata map[string]string, key, value string) {
	if value != "" {
		metadata[key] = value
	}
}
