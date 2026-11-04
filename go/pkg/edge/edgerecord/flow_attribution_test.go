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

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func validFlowAttributionBatchFixture() *netprobepb.FlowAttributionEventBatch {
	return &netprobepb.FlowAttributionEventBatch{
		BatchStartUnixNano: 1_700_000_000_000_000_000,
		BatchEndUnixNano:   1_700_000_001_000_000_000,
		DroppedSinceLast:   2,
		Events: []*netprobepb.FlowAttributionEvent{
			{
				LocalIp:           "192.0.2.10",
				LocalPort:         51420,
				RemoteIp:          "198.51.100.20",
				RemotePort:        443,
				TransportProtocol: "TCP",
				Pid:               4242,
				Comm:              "synthetic-worker",
			},
			{
				LocalIp:           "192.0.2.10",
				LocalPort:         51421,
				RemoteIp:          "198.51.100.21",
				RemotePort:        8443,
				TransportProtocol: "TCP",
				Pid:               4243,
				Comm:              "synthetic-helper",
			},
		},
	}
}

func validFlowAttributionRecord(t *testing.T, batch *netprobepb.FlowAttributionEventBatch) *edgev1.EdgeRecordV1 {
	t.Helper()
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		t.Fatalf("proto.Marshal: %v", err)
	}
	sum := sha256.Sum256(payload)
	rows := uint32(len(batch.GetEvents()))
	writeBytes := uint64(rows) * FlowAttributionWriteBytesPerRow

	r := validRecord(t)
	r.OutputContract.ContractId = FlowAttributionContractID
	r.OutputContract.ContractVersion = FlowAttributionContractVersion
	r.Payload, r.PayloadSha256 = payload, sum[:]
	r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(payload))
	r.ProjectedRowCount, r.ProjectedWriteBytes = rows, writeBytes
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	return r
}

func TestValidateFlowAttributionRecordAcceptsStandingGrantBatch(t *testing.T) {
	t.Parallel()
	r := validFlowAttributionRecord(t, validFlowAttributionBatchFixture())
	if err := ValidateFlowAttributionRecord(r); err != nil {
		t.Fatalf("ValidateFlowAttributionRecord failed: %v", err)
	}
}

func TestValidateFlowAttributionRecordRejectsSourceAuthorization(t *testing.T) {
	t.Parallel()
	r := validFlowAttributionRecord(t, validFlowAttributionBatchFixture())
	ctx, scope := mustUUID(t), mustUUID(t)
	r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability: sourceCap(t, r, ctx, scope, edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK),
		ContextId:  ctx, ScopeId: scope, ScopeSha256: d32(0xAA),
	}
	reseal(r)
	if err := ValidateFlowAttributionRecord(r); !errors.Is(err, ErrFlowAttributionSourceAuthorization) {
		t.Fatalf("expected ErrFlowAttributionSourceAuthorization, got %v", err)
	}
}

func TestValidateFlowAttributionRecordRejectsRowAndCostMismatch(t *testing.T) {
	t.Parallel()
	r := validFlowAttributionRecord(t, validFlowAttributionBatchFixture())
	r.ProjectedRowCount = 99
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	if err := ValidateFlowAttributionRecord(r); !errors.Is(err, ErrFlowAttributionBatch) {
		t.Fatalf("expected ErrFlowAttributionBatch for row count mismatch, got %v", err)
	}

	r = validFlowAttributionRecord(t, validFlowAttributionBatchFixture())
	r.ProjectedWriteBytes++
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	if err := ValidateFlowAttributionRecord(r); !errors.Is(err, ErrFlowAttributionBatch) {
		t.Fatalf("expected ErrFlowAttributionBatch for write bytes mismatch, got %v", err)
	}
}

func TestValidateFlowAttributionBatchInvariants(t *testing.T) {
	t.Parallel()
	if err := ValidateFlowAttributionBatch(nil); !errors.Is(err, ErrFlowAttributionBatch) {
		t.Fatalf("expected ErrFlowAttributionBatch for nil batch, got %v", err)
	}

	empty := &netprobepb.FlowAttributionEventBatch{}
	if err := ValidateFlowAttributionBatch(empty); !errors.Is(err, ErrFlowAttributionBatch) {
		t.Fatalf("expected ErrFlowAttributionBatch for empty events, got %v", err)
	}

	inverted := validFlowAttributionBatchFixture()
	inverted.BatchStartUnixNano = 200
	inverted.BatchEndUnixNano = 100
	if err := ValidateFlowAttributionBatch(inverted); !errors.Is(err, ErrFlowAttributionBatch) {
		t.Fatalf("expected ErrFlowAttributionBatch for inverted window, got %v", err)
	}

	negative := validFlowAttributionBatchFixture()
	negative.BatchStartUnixNano = -1
	if err := ValidateFlowAttributionBatch(negative); !errors.Is(err, ErrFlowAttributionBatch) {
		t.Fatalf("expected ErrFlowAttributionBatch for negative timestamp, got %v", err)
	}

	tooMany := &netprobepb.FlowAttributionEventBatch{
		Events: make([]*netprobepb.FlowAttributionEvent, FlowAttributionMaxRows+1),
	}
	for i := range tooMany.Events {
		tooMany.Events[i] = &netprobepb.FlowAttributionEvent{Pid: uint32(i + 1)}
	}
	if err := ValidateFlowAttributionBatch(tooMany); !errors.Is(err, ErrFlowAttributionBatch) {
		t.Fatalf("expected ErrFlowAttributionBatch for >4096 events, got %v", err)
	}
}
