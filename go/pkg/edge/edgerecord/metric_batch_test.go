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
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
)

// metricBatchRecord is a valid sysmon metrics batch record carrying a synthetic
// batch of `metrics` gauges, with its projected row count equal to rows.
func metricBatchRecord(t *testing.T, metrics int, rows uint32) *edgev1.EdgeRecordV1 {
	t.Helper()
	return metricBatchRecordSource(t, metrics, rows, MetricsBatchSource)
}

func metricBatchRecordSource(t *testing.T, metrics int, rows uint32, source string) *edgev1.EdgeRecordV1 {
	t.Helper()
	batch := &metricpb.MetricBatch{
		SchemaVersion:  MetricBatchSchemaVersion,
		IngestIdentity: &metricpb.IngestIdentity{Source: source},
	}
	for range metrics {
		batch.Metrics = append(batch.Metrics, &metricpb.Metric{Name: "cpu.usage_percent", MetricType: "sysmon.cpu"})
	}
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	r := validRecord(t)
	r.OutputContract.ContractId = MetricsBatchContractID
	r.OutputContract.ContractVersion = MetricsBatchContractVersion
	r.Payload, r.PayloadSha256 = payload, sum[:]
	r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(payload))
	r.ProjectedRowCount, r.ProjectedWriteBytes = rows, uint64(rows)*1024
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	return r
}

func TestValidateMetricBatchRecord(t *testing.T) {
	if err := ValidateMetricBatchRecord(metricBatchRecord(t, 3, 3)); err != nil {
		t.Fatalf("valid metrics batch record: %v", err)
	}

	sweep := metricBatchRecord(t, 3, 3)
	sweep.OutputContract.ContractId = "serviceradar.sweep.observation"
	sweep.ProductionCapability = productionCap(t, sweep)
	reseal(sweep)

	sourced := metricBatchRecord(t, 3, 3)
	ctx, scope := mustUUID(t), mustUUID(t)
	sourced.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability: sourceCap(t, sourced, ctx, scope, edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK),
		ContextId:  ctx, ScopeId: scope, ScopeSha256: d32(0xAA),
	}
	reseal(sourced)

	cases := map[string]struct {
		record *edgev1.EdgeRecordV1
		want   error
	}{
		"another contract":                 {sweep, ErrContractDispatch},
		"a source authorization":           {sourced, ErrMetricBatchSourceAuthorization},
		"a non-sysmon source":              {metricBatchRecordSource(t, 3, 3, "snmp-metrics"), ErrMetricBatch},
		"rows that disagree with the body": {metricBatchRecord(t, 3, 2), ErrMetricBatch},
		"an empty batch":                   {metricBatchRecord(t, 0, 1), ErrMetricBatch},
	}
	for name, tc := range cases {
		if err := ValidateMetricBatchRecord(tc.record); !errors.Is(err, tc.want) {
			t.Errorf("record with %s = %v, want %v", name, err, tc.want)
		}
	}
}
