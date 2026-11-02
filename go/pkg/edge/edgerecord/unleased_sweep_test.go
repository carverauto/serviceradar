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

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// unleasedSweepRecord is a valid unleased sweep results record over batch, with
// its projected row count equal to rows.
func unleasedSweepRecord(t *testing.T, batch *edgev1.UnleasedSweepResultsBatchV1, rows uint32) *edgev1.EdgeRecordV1 {
	t.Helper()
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	r := validRecord(t)
	r.OutputContract.ContractId = UnleasedSweepResultsContractID
	r.OutputContract.ContractVersion = UnleasedSweepResultsContractVersion
	r.Payload, r.PayloadSha256 = payload, sum[:]
	r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(payload))
	r.ProjectedRowCount, r.ProjectedWriteBytes = rows, uint64(rows)*2048
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	return r
}

// unleasedSweepBatch is a synthetic two-host batch testing ICMP and one TCP port.
func unleasedSweepBatch() *edgev1.UnleasedSweepResultsBatchV1 {
	return &edgev1.UnleasedSweepResultsBatchV1{
		ExecutionId: d32(0x11)[:16],
		TestedChecks: []*edgev1.SweepTestV1{
			{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP},
			{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, Port: 443},
		},
		Hosts: []*edgev1.SweepHostObservationV1{
			{Address: []byte{192, 0, 2, 10}, OpenPorts: []*edgev1.SweepOpenPortV1{{TestedCheckIndex: 1}}},
			{Address: []byte{192, 0, 2, 11}, PortErrors: []*edgev1.SweepPortErrorV1{{TestedCheckIndex: 1, ErrorCode: "closed"}}},
		},
		HostResults: []*edgev1.UnleasedSweepHostResultV1{{Available: true}, {}},
	}
}

func TestValidateUnleasedSweepResultsRecord(t *testing.T) {
	if err := ValidateUnleasedSweepResultsRecord(unleasedSweepRecord(t, unleasedSweepBatch(), 2)); err != nil {
		t.Fatalf("valid unleased sweep results record: %v", err)
	}

	other := unleasedSweepRecord(t, unleasedSweepBatch(), 2)
	other.OutputContract.ContractId = MetricsBatchContractID
	other.ProductionCapability = productionCap(t, other)
	reseal(other)

	sourced := unleasedSweepRecord(t, unleasedSweepBatch(), 2)
	ctx, scope := mustUUID(t), mustUUID(t)
	sourced.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability: sourceCap(t, sourced, ctx, scope, edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK),
		ContextId:  ctx, ScopeId: scope, ScopeSha256: d32(0xAA),
	}
	reseal(sourced)

	shortExecution := unleasedSweepBatch()
	shortExecution.ExecutionId = shortExecution.ExecutionId[:8]
	badGroup := unleasedSweepBatch()
	badGroup.SweepGroupId = []byte{1, 2, 3}
	badAddress := unleasedSweepBatch()
	badAddress.Hosts[0].Address = []byte{192, 0, 2}
	openOutOfRange := unleasedSweepBatch()
	openOutOfRange.Hosts[0].OpenPorts[0].TestedCheckIndex = 2
	missingResult := unleasedSweepBatch()
	missingResult.HostResults = missingResult.HostResults[:1]
	errorOutOfRange := unleasedSweepBatch()
	errorOutOfRange.Hosts[1].PortErrors[0].TestedCheckIndex = 2

	cases := map[string]struct {
		record *edgev1.EdgeRecordV1
		want   error
	}{
		"another contract":                  {other, ErrContractDispatch},
		"a source authorization":            {sourced, ErrUnleasedSweepSourceAuthorization},
		"an 8-byte execution id":            {unleasedSweepRecord(t, shortExecution, 2), ErrUnleasedSweepBatch},
		"a 3-byte sweep group id":           {unleasedSweepRecord(t, badGroup, 2), ErrUnleasedSweepBatch},
		"a 3-byte host address":             {unleasedSweepRecord(t, badAddress, 2), ErrUnleasedSweepBatch},
		"an open port naming no check":      {unleasedSweepRecord(t, openOutOfRange, 2), ErrUnleasedSweepBatch},
		"a host without its host result":    {unleasedSweepRecord(t, missingResult, 2), ErrUnleasedSweepBatch},
		"a port error naming no check":      {unleasedSweepRecord(t, errorOutOfRange, 2), ErrUnleasedSweepBatch},
		"rows that disagree with the hosts": {unleasedSweepRecord(t, unleasedSweepBatch(), 1), ErrUnleasedSweepBatch},
	}
	for name, tc := range cases {
		if err := ValidateUnleasedSweepResultsRecord(tc.record); !errors.Is(err, tc.want) {
			t.Errorf("record with %s = %v, want %v", name, err, tc.want)
		}
	}
}
