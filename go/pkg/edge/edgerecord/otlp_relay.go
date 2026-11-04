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

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	// OtlpRelayContractID is the canonical output contract for collector OTLP relay frames.
	OtlpRelayContractID = "serviceradar.otlp.relay"
	// OtlpRelayContractVersion is the v1 schema version for OTLP relay frames.
	OtlpRelayContractVersion uint32 = 1
)

var (
	// ErrOtlpRelayFrame reports a malformed or out-of-contract OtlpRelayFrame payload.
	ErrOtlpRelayFrame = errors.New("edgerecord: invalid OTLP relay frame payload")
	// ErrOtlpRelaySourceAuthorization reports a standing-grant OTLP relay record carrying source_authorization.
	ErrOtlpRelaySourceAuthorization = errors.New("edgerecord: OTLP relay record must not carry source authorization")
)

// ValidateOtlpRelayRecord validates an EdgeRecordV1 under the standing-grant
// contract serviceradar.otlp.relay v1, decompresses its inner OtlpRelayFrame
// payload, and checks the frame and cost invariants.
func ValidateOtlpRelayRecord(r *edgev1.EdgeRecordV1) error {
	if err := ValidateRecord(r); err != nil {
		return err
	}
	contract := r.GetOutputContract()
	if contract.GetContractId() != OtlpRelayContractID ||
		contract.GetContractVersion() != OtlpRelayContractVersion {
		return fmt.Errorf("%w: %s v%d", ErrContractDispatch, contract.GetContractId(), contract.GetContractVersion())
	}
	if err := requireFramingFamily(r); err != nil {
		return err
	}
	if r.GetSourceAuthorization() != nil {
		return ErrOtlpRelaySourceAuthorization
	}
	inner, err := innerPayload(r)
	if err != nil {
		return err
	}
	var frame addonpb.OtlpRelayFrame
	if err := unmarshalPayload(inner, &frame); err != nil {
		return err
	}
	if err := ValidateOtlpRelayFrame(&frame); err != nil {
		return err
	}
	expectedRows := uint64(len(frame.GetBatch().GetRecords()))
	if uint64(r.GetProjectedRowCount()) != expectedRows {
		return fmt.Errorf(
			"%w: projected_row_count %d != records %d",
			ErrOtlpRelayFrame, r.GetProjectedRowCount(), expectedRows,
		)
	}
	expectedWriteBytes := uint64(r.GetUncompressedSize())
	if r.GetProjectedWriteBytes() != expectedWriteBytes {
		return fmt.Errorf(
			"%w: projected_write_bytes %d != uncompressed_size %d",
			ErrOtlpRelayFrame, r.GetProjectedWriteBytes(), expectedWriteBytes,
		)
	}
	return nil
}

// ValidateOtlpRelayFrame validates a decoded OtlpRelayFrame against the
// serviceradar.otlp.relay v1 contract rules.
func ValidateOtlpRelayFrame(frame *addonpb.OtlpRelayFrame) error {
	if frame == nil {
		return fmt.Errorf("%w: nil frame", ErrOtlpRelayFrame)
	}
	if frame.GetRelayId() == 0 {
		return fmt.Errorf("%w: relay_id must be > 0", ErrOtlpRelayFrame)
	}
	batch := frame.GetBatch()
	if batch == nil {
		return fmt.Errorf("%w: batch required", ErrOtlpRelayFrame)
	}
	records := batch.GetRecords()
	if len(records) == 0 {
		return fmt.Errorf("%w: batch.records required", ErrOtlpRelayFrame)
	}
	for i, rec := range records {
		if rec == nil {
			return fmt.Errorf("%w: records[%d]: nil record", ErrOtlpRelayFrame, i)
		}
		if !ValidOtlpRelayPayloadKind(rec.GetPayloadKind()) {
			return fmt.Errorf(
				"%w: records[%d]: unsupported payload_kind %v",
				ErrOtlpRelayFrame, i, rec.GetPayloadKind(),
			)
		}
		if len(rec.GetPayload()) == 0 {
			return fmt.Errorf("%w: records[%d]: payload required", ErrOtlpRelayFrame, i)
		}
	}
	return nil
}

// ValidOtlpRelayPayloadKind reports whether kind is an OTLP relay payload.
// The other telemetry kinds belong to the telemetry batch contract.
func ValidOtlpRelayPayloadKind(kind addonpb.TelemetryPayloadKind) bool {
	switch kind {
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_LOGS,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_METRICS,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC:
		return true
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_UNSPECIFIED,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTEL_LOG,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1:
		return false
	default:
		return false
	}
}
