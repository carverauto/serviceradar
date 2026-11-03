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

// pluginResultRecord is a valid plugin results record over batch, with its
// projected row count equal to rows.
func pluginResultRecord(t *testing.T, batch *edgev1.WasmPluginResultBatchV1, rows uint32) *edgev1.EdgeRecordV1 {
	t.Helper()
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	r := validRecord(t)
	r.OutputContract.ContractId = PluginResultsContractID
	r.OutputContract.ContractVersion = PluginResultsContractVersion
	r.Payload, r.PayloadSha256 = payload, sum[:]
	r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(payload))
	r.ProjectedRowCount, r.ProjectedWriteBytes = rows, uint64(rows)*PluginResultsProjectedWriteBytesPerRecord
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	return r
}

func pluginResultBatch() *edgev1.WasmPluginResultBatchV1 {
	return &edgev1.WasmPluginResultBatchV1{
		Provenance: &edgev1.PluginResultProvenanceV1{
			AssignmentId: "asgn-synthetic-1",
			PluginId:     "http-synthetic-check",
		},
		Results: []*edgev1.WasmPluginResultItemV1{
			{SchemaVersion: 1, Status: edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_OK, Summary: "synthetic check healthy"},
			{SchemaVersion: 1, Status: edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_CRITICAL, Summary: "synthetic check down"},
		},
	}
}

func TestValidatePluginResultRecord(t *testing.T) {
	if err := ValidatePluginResultRecord(pluginResultRecord(t, pluginResultBatch(), 2)); err != nil {
		t.Fatalf("valid plugin result record: %v", err)
	}

	other := pluginResultRecord(t, pluginResultBatch(), 2)
	other.OutputContract.ContractId = MetricsBatchContractID
	other.ProductionCapability = productionCap(t, other)
	reseal(other)

	sourced := pluginResultRecord(t, pluginResultBatch(), 2)
	ctx, scope := mustUUID(t), mustUUID(t)
	sourced.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability: sourceCap(t, sourced, ctx, scope, edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK),
		ContextId:  ctx, ScopeId: scope, ScopeSha256: d32(0xAA),
	}
	reseal(sourced)

	noProvenance := pluginResultBatch()
	noProvenance.Provenance = nil
	noAssignment := pluginResultBatch()
	noAssignment.Provenance.AssignmentId = "  "
	noResults := pluginResultBatch()
	noResults.Results = nil
	noStatus := pluginResultBatch()
	noStatus.Results[1].Status = edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_UNSPECIFIED
	noSummary := pluginResultBatch()
	noSummary.Results[0].Summary = " "

	cases := map[string]struct {
		record *edgev1.EdgeRecordV1
		want   error
	}{
		"another contract":                {other, ErrContractDispatch},
		"a source authorization":          {sourced, ErrPluginResultSourceAuthorization},
		"no provenance":                   {pluginResultRecord(t, noProvenance, 2), ErrPluginResultBatch},
		"no assignment provenance":        {pluginResultRecord(t, noAssignment, 2), ErrPluginResultBatch},
		"no results":                      {pluginResultRecord(t, noResults, 0), ErrPluginResultBatch},
		"a result with no status":         {pluginResultRecord(t, noStatus, 2), ErrPluginResultBatch},
		"a result with no summary":        {pluginResultRecord(t, noSummary, 2), ErrPluginResultBatch},
		"rows that disagree with results": {pluginResultRecord(t, pluginResultBatch(), 1), ErrPluginResultBatch},
	}
	for name, tc := range cases {
		if err := ValidatePluginResultRecord(tc.record); !errors.Is(err, tc.want) {
			t.Errorf("record with %s = %v, want %v", name, err, tc.want)
		}
	}
}
