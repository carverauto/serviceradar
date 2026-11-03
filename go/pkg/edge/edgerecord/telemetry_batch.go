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

package edgerecord

import (
	"errors"
	"fmt"
	"strings"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The plugin and add-on telemetry output contract. Wasm plugins and native
// add-ons emit the SDK TelemetryBatch under a standing output grant — never a
// contract of their own — and their records carry no source authorization.
// The agent host stamps the producing package into the batch source metadata
// (TelemetryProducerTypeMetadataKey / TelemetryProducerIDMetadataKey) from its
// own assignment and add-on configuration; a guest-supplied value under those
// keys is overwritten before the batch is spooled, so they are the only copy
// of that identity the projector routes on.
const (
	TelemetryBatchContractID             = "serviceradar.telemetry.batch"
	TelemetryBatchContractVersion uint32 = 1

	// TelemetryProducerTypeMetadataKey names the host-stamped producer kind
	// ("plugin" or "addon") in a TelemetryBatch source's metadata.
	TelemetryProducerTypeMetadataKey = "serviceradar.producer_type"
	// TelemetryProducerIDMetadataKey names the host-stamped producer: the
	// plugin assignment id for a Wasm plugin, the add-on id for a native
	// add-on. It is the suffix the legacy status source carried
	// (`plugin:<id>` / `addon:<id>`).
	TelemetryProducerIDMetadataKey = "serviceradar.producer_id"

	// TelemetryProducerPlugin and TelemetryProducerAddon are the admitted
	// host-stamped producer kinds.
	TelemetryProducerPlugin = "plugin"
	TelemetryProducerAddon  = "addon"

	// TelemetryProjectedWriteBytesPerRecord is the per-record write cost the
	// producer stamps into projected_write_bytes. It must equal core's
	// catalog write_bytes_per_row for this contract, from which the
	// capability's max_projected_write_bytes is derived.
	TelemetryProjectedWriteBytesPerRecord = 8192
)

var (
	// ErrTelemetryBatch is returned for a telemetry batch body that breaks
	// the contract's payload rules.
	ErrTelemetryBatch = errors.New("edgerecord: invalid telemetry batch")
	// ErrTelemetryBatchSourceAuthorization is returned when a telemetry batch
	// record carries a source authorization, which a standing grant never issues.
	ErrTelemetryBatchSourceAuthorization = errors.New("edgerecord: telemetry batch record carries a source authorization")
)

// TelemetryBatchProducer is the host-stamped producer identity of a telemetry
// batch: its kind and the assignment or add-on that emitted it.
func TelemetryBatchProducer(batch *addonpb.TelemetryBatch) (producerType string, producerID string, ok bool) {
	metadata := batch.GetSource().GetMetadata()
	producerType = strings.TrimSpace(metadata[TelemetryProducerTypeMetadataKey])
	producerID = strings.TrimSpace(metadata[TelemetryProducerIDMetadataKey])
	if producerID == "" {
		return "", "", false
	}
	switch producerType {
	case TelemetryProducerPlugin, TelemetryProducerAddon:
		return producerType, producerID, true
	default:
		return "", "", false
	}
}

// TelemetryPayloadKindRouted reports whether the telemetry batch contract
// routes a payload kind: the SDK's closed routed kinds. The OTLP relay kinds
// ride their own contract and are not admitted here.
func TelemetryPayloadKindRouted(kind addonpb.TelemetryPayloadKind) bool {
	switch kind {
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTEL_LOG,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1:
		return true
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_UNSPECIFIED,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_LOGS,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_METRICS,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC:
		return false
	default:
		// Numeric values outside the enum are not routed payloads.
		return false
	}
}

// ValidateTelemetryBatch enforces the telemetry batch payload rules: at least
// one record, a host-stamped producer, every record's payload kind in the
// routed set, and discovery records only from a native add-on (a Wasm plugin
// reaches inventory through its scoped plugin-result route, never this one).
func ValidateTelemetryBatch(batch *addonpb.TelemetryBatch) error {
	if batch == nil {
		return fmt.Errorf("%w: empty batch", ErrTelemetryBatch)
	}
	if len(batch.GetRecords()) == 0 {
		return fmt.Errorf("%w: no records", ErrTelemetryBatch)
	}
	producerType, _, ok := TelemetryBatchProducer(batch)
	if !ok {
		return fmt.Errorf("%w: missing host producer stamp", ErrTelemetryBatch)
	}
	for _, record := range batch.GetRecords() {
		kind := record.GetPayloadKind()
		if !TelemetryPayloadKindRouted(kind) {
			return fmt.Errorf("%w: payload kind %s", ErrTelemetryBatch, kind)
		}
		if kind == addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1 &&
			producerType != TelemetryProducerAddon {
			return fmt.Errorf("%w: discovery record from a %s producer", ErrTelemetryBatch, producerType)
		}
	}
	return nil
}

// ValidateTelemetryBatchRecord is the composed validator a producer runs
// before it spools a telemetry batch record: the whole record
// (ValidateRecord), the exact telemetry batch contract, RECORD_BATCH_V1
// framing, no source authorization, the decoded body, and a projected row
// count equal to the body's record count. Signatures are verified by the
// gateway, which holds the trust snapshot.
func ValidateTelemetryBatchRecord(r *edgev1.EdgeRecordV1) error {
	if err := ValidateRecord(r); err != nil {
		return err
	}
	contract := r.GetOutputContract()
	if contract.GetContractId() != TelemetryBatchContractID ||
		contract.GetContractVersion() != TelemetryBatchContractVersion {
		return fmt.Errorf("%w: %s v%d", ErrContractDispatch, contract.GetContractId(), contract.GetContractVersion())
	}
	if err := requireFramingFamily(r); err != nil {
		return err
	}
	if r.GetSourceAuthorization() != nil {
		return ErrTelemetryBatchSourceAuthorization
	}
	inner, err := innerPayload(r)
	if err != nil {
		return err
	}
	var batch addonpb.TelemetryBatch
	if err := unmarshalPayload(inner, &batch); err != nil {
		return err
	}
	if err := ValidateTelemetryBatch(&batch); err != nil {
		return err
	}
	if uint64(r.GetProjectedRowCount()) != uint64(len(batch.GetRecords())) {
		return fmt.Errorf("%w: projected_row_count %d for %d records",
			ErrTelemetryBatch, r.GetProjectedRowCount(), len(batch.GetRecords()))
	}
	return nil
}
