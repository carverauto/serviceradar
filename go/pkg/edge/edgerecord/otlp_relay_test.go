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
	"crypto/sha256"
	"errors"
	"testing"

	"google.golang.org/protobuf/proto"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func validOtlpRelayFrameFixture() *addonpb.OtlpRelayFrame {
	return &addonpb.OtlpRelayFrame{
		RelayId: 7,
		Batch: &addonpb.TelemetryBatch{
			Records: []*addonpb.TelemetryRecord{
				{
					PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
					Payload:     []byte{0x0a, 0x04, 's', 'p', 'a', 'n'},
				},
				{
					PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_METRICS,
					Payload:     []byte{0x0a, 0x06, 'm', 'e', 't', 'r', 'i', 'c'},
				},
			},
		},
	}
}

func validOtlpRelayRecord(t *testing.T, frame *addonpb.OtlpRelayFrame) *edgev1.EdgeRecordV1 {
	t.Helper()
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(frame)
	if err != nil {
		t.Fatalf("proto.Marshal: %v", err)
	}
	sum := sha256.Sum256(payload)
	rows := uint32(len(frame.GetBatch().GetRecords()))

	r := validRecord(t)
	r.OutputContract.ContractId = OtlpRelayContractID
	r.OutputContract.ContractVersion = OtlpRelayContractVersion
	r.Payload, r.PayloadSha256 = payload, sum[:]
	r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(payload))
	r.ProjectedRowCount, r.ProjectedWriteBytes = rows, uint64(len(payload))
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	return r
}

func TestValidateOtlpRelayRecordAcceptsStandingGrantFrame(t *testing.T) {
	t.Parallel()
	r := validOtlpRelayRecord(t, validOtlpRelayFrameFixture())
	if err := ValidateOtlpRelayRecord(r); err != nil {
		t.Fatalf("ValidateOtlpRelayRecord failed: %v", err)
	}
}

func TestValidateOtlpRelayRecordRejectsSourceAuthorization(t *testing.T) {
	t.Parallel()
	r := validOtlpRelayRecord(t, validOtlpRelayFrameFixture())
	ctx, scope := mustUUID(t), mustUUID(t)
	r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability: sourceCap(t, r, ctx, scope, edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK),
		ContextId:  ctx, ScopeId: scope, ScopeSha256: d32(0xAA),
	}
	reseal(r)
	if err := ValidateOtlpRelayRecord(r); !errors.Is(err, ErrOtlpRelaySourceAuthorization) {
		t.Fatalf("expected ErrOtlpRelaySourceAuthorization, got %v", err)
	}
}

func TestValidateOtlpRelayRecordRejectsRowAndCostMismatch(t *testing.T) {
	t.Parallel()
	r := validOtlpRelayRecord(t, validOtlpRelayFrameFixture())
	r.ProjectedRowCount = 99
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	if err := ValidateOtlpRelayRecord(r); !errors.Is(err, ErrOtlpRelayFrame) {
		t.Fatalf("expected ErrOtlpRelayFrame for row count mismatch, got %v", err)
	}

	r = validOtlpRelayRecord(t, validOtlpRelayFrameFixture())
	r.ProjectedWriteBytes++
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	if err := ValidateOtlpRelayRecord(r); !errors.Is(err, ErrOtlpRelayFrame) {
		t.Fatalf("expected ErrOtlpRelayFrame for write bytes mismatch, got %v", err)
	}
}

func TestValidateOtlpRelayFrameInvariants(t *testing.T) {
	t.Parallel()
	if err := ValidateOtlpRelayFrame(nil); !errors.Is(err, ErrOtlpRelayFrame) {
		t.Fatalf("expected ErrOtlpRelayFrame for nil frame, got %v", err)
	}

	zeroRelay := validOtlpRelayFrameFixture()
	zeroRelay.RelayId = 0
	if err := ValidateOtlpRelayFrame(zeroRelay); !errors.Is(err, ErrOtlpRelayFrame) {
		t.Fatalf("expected ErrOtlpRelayFrame for relay_id=0, got %v", err)
	}

	badKind := validOtlpRelayFrameFixture()
	badKind.Batch.Records[0].PayloadKind = addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT
	if err := ValidateOtlpRelayFrame(badKind); !errors.Is(err, ErrOtlpRelayFrame) {
		t.Fatalf("expected ErrOtlpRelayFrame for non-OTLP payload_kind, got %v", err)
	}

	emptyPayload := validOtlpRelayFrameFixture()
	emptyPayload.Batch.Records[0].Payload = nil
	if err := ValidateOtlpRelayFrame(emptyPayload); !errors.Is(err, ErrOtlpRelayFrame) {
		t.Fatalf("expected ErrOtlpRelayFrame for empty payload, got %v", err)
	}
}
