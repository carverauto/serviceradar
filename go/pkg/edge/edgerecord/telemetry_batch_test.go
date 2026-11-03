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

// telemetryBatchRecord is a valid telemetry batch record from a plugin whose
// host stamped an assignment id, carrying records of the given kinds.
func telemetryBatchRecord(t *testing.T, kinds []addonpb.TelemetryPayloadKind, rows uint32) *edgev1.EdgeRecordV1 {
	t.Helper()
	return telemetryBatchRecordFrom(t, TelemetryProducerPlugin, "assignment-1", kinds, rows)
}

func telemetryBatchRecordFrom(
	t *testing.T,
	producerType string,
	producerID string,
	kinds []addonpb.TelemetryPayloadKind,
	rows uint32,
) *edgev1.EdgeRecordV1 {
	t.Helper()
	batch := telemetryBatchFrom(producerType, producerID, kinds)
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	r := validRecord(t)
	r.OutputContract.ContractId = TelemetryBatchContractID
	r.OutputContract.ContractVersion = TelemetryBatchContractVersion
	r.Payload, r.PayloadSha256 = payload, sum[:]
	r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(payload))
	r.ProjectedRowCount, r.ProjectedWriteBytes = rows, uint64(rows)*TelemetryProjectedWriteBytesPerRecord
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	return r
}

func telemetryBatchFrom(
	producerType string,
	producerID string,
	kinds []addonpb.TelemetryPayloadKind,
) *addonpb.TelemetryBatch {
	batch := &addonpb.TelemetryBatch{
		Source: &addonpb.TelemetrySource{
			Metadata: map[string]string{
				TelemetryProducerTypeMetadataKey: producerType,
				TelemetryProducerIDMetadataKey:   producerID,
			},
		},
	}
	for _, kind := range kinds {
		batch.Records = append(batch.Records, &addonpb.TelemetryRecord{
			PayloadKind: kind,
			Payload:     []byte(`{"ok":true}`),
		})
	}
	return batch
}

func TestValidateTelemetryBatchRecord(t *testing.T) {
	valid := []struct {
		producerType string
		producerID   string
		kinds        []addonpb.TelemetryPayloadKind
	}{
		{TelemetryProducerPlugin, "assignment-1", []addonpb.TelemetryPayloadKind{
			addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS,
			addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
			addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTEL_LOG,
		}},
		{TelemetryProducerAddon, "addon-1", []addonpb.TelemetryPayloadKind{
			addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1,
		}},
	}
	for _, tc := range valid {
		record := telemetryBatchRecordFrom(t, tc.producerType, tc.producerID, tc.kinds, uint32(len(tc.kinds)))
		if err := ValidateTelemetryBatchRecord(record); err != nil {
			t.Fatalf("valid %s telemetry batch record: %v", tc.producerType, err)
		}
	}

	sourced := telemetryBatchRecord(t, []addonpb.TelemetryPayloadKind{
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
	}, 1)
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
		"a source authorization": {sourced, ErrTelemetryBatchSourceAuthorization},
		"no records": {telemetryBatchRecordFrom(t, TelemetryProducerPlugin, "assignment-1", nil, 1),
			ErrTelemetryBatch},
		"no producer stamp": {telemetryBatchRecordFrom(t, "", "", []addonpb.TelemetryPayloadKind{
			addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		}, 1), ErrTelemetryBatch},
		"an unknown producer kind": {telemetryBatchRecordFrom(t, "sysmon", "x", []addonpb.TelemetryPayloadKind{
			addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		}, 1), ErrTelemetryBatch},
		"an OTLP relay payload kind": {telemetryBatchRecordFrom(t, TelemetryProducerAddon, "addon-1",
			[]addonpb.TelemetryPayloadKind{
				addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_LOGS,
			}, 1), ErrTelemetryBatch},
		"a discovery record from a plugin": {telemetryBatchRecordFrom(t, TelemetryProducerPlugin,
			"assignment-1", []addonpb.TelemetryPayloadKind{
				addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1,
			}, 1), ErrTelemetryBatch},
		"rows that disagree with the body": {telemetryBatchRecord(t, []addonpb.TelemetryPayloadKind{
			addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		}, 2), ErrTelemetryBatch},
	}
	for name, tc := range cases {
		if err := ValidateTelemetryBatchRecord(tc.record); !errors.Is(err, tc.want) {
			t.Errorf("record with %s = %v, want %v", name, err, tc.want)
		}
	}
}
