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

package agent

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// telemetryGrant is a standing telemetry batch grant for agentID. All
// identity material is synthetic, like metricsGrant.
func telemetryGrant(t *testing.T, agentID string) *proto.EdgeOutputGrant {
	return telemetryGrantMaxRows(t, agentID, 10_000)
}

func telemetryGrantMaxRows(t *testing.T, agentID string, maxRows uint32) *proto.EdgeOutputGrant {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	digest := sha256.Sum256([]byte("synthetic-telemetry-contract"))
	now := time.Now()
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("test-issuer"),
		IssuerKeyId:       []byte("test-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: now.Add(-time.Hour).UnixNano(),
		ExpiresAtUnixNano: now.Add(8 * 24 * time.Hour).UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId: edgerecord.TelemetryBatchContractID, ContractVersion: edgerecord.TelemetryBatchContractVersion,
			ContractBundleSha256: digest[:], RegistryEpoch: 1, RegistrySnapshotSha256: digest[:], EffectiveGrantSha256: digest[:],
			NetworkScopeId: testNetworkScopeID[:], ProducerAssignmentId: testAssignmentID[:], RunId: testAssignmentID[:],
			AuthorityEpoch: 1, ScopeId: testAssignmentID[:], ScopeSha256: digest[:],
			OriginKind: edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT, OriginPrincipalId: []byte(agentID), ProducerInstanceId: []byte(agentID),
			RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:    "serviceradar.agent.telemetry", PackageSha256: digest[:], CostModelVersion: 1,
			MaxProjectedRowCount: maxRows, MaxProjectedWriteBytes: uint64(maxRows) * edgerecord.TelemetryProjectedWriteBytesPerRecord,
		}},
	}
	edgerecord.SignCapability(capability, key)
	encoded, err := gproto.Marshal(capability)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{
		ContractId:           edgerecord.TelemetryBatchContractID,
		ContractVersion:      edgerecord.TelemetryBatchContractVersion,
		ProductionCapability: encoded,
	}
}

func telemetryCapability(t *testing.T, loop *PushLoop) *edgev1.EdgeSignedCapabilityV1 {
	t.Helper()
	return telemetryCapabilityMaxRows(t, loop, 10_000)
}

func telemetryCapabilityMaxRows(t *testing.T, loop *PushLoop, maxRows uint32) *edgev1.EdgeSignedCapabilityV1 {
	t.Helper()
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{telemetryGrantMaxRows(t, sysmonEdgeAgentID, maxRows)}, time.Now())
	capability := loop.edgeTelemetryCapability(time.Now())
	require.NotNil(t, capability)
	return capability
}

func telemetryLoop(t *testing.T, sp *spool.Spool) *PushLoop {
	t.Helper()
	loop := &PushLoop{
		server: &Server{
			config:         &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
			addonTelemetry: newAddonTelemetryBuffer(16),
		},
		logger: logger.NewTestLogger(),
	}
	loop.SetEdgeTelemetrySpool(sp)
	return loop
}

func spooledTelemetryBatches(t *testing.T, sp *spool.Spool) []*addonpb.TelemetryBatch {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	batches := make([]*addonpb.TelemetryBatch, 0, len(stored))
	for _, s := range stored {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, gproto.Unmarshal(s.Body, record))
		require.NoError(t, edgerecord.ValidateTelemetryBatchRecord(record))
		require.Nil(t, record.GetSourceAuthorization())
		batch := &addonpb.TelemetryBatch{}
		require.NoError(t, gproto.Unmarshal(recordBody(t, record), batch))
		batches = append(batches, batch)
	}
	return batches
}

func ocsfTelemetryRecord(payload string) *addonpb.TelemetryRecord {
	return &addonpb.TelemetryRecord{
		PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		Payload:     []byte(payload),
	}
}

func TestAddonTelemetryWithAGrantGoesOnlyToTheEdgeSpool(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := telemetryLoop(t, sp)
	telemetryCapability(t, loop)

	// The batch source claims another producer entirely; the host stamp
	// overwrites it from the envelope's add-on, so the spooled batch cannot
	// reattribute the telemetry.
	forged := &addonpb.TelemetryBatch{
		Source: &addonpb.TelemetrySource{Metadata: map[string]string{
			edgerecord.TelemetryProducerTypeMetadataKey: "plugin",
			edgerecord.TelemetryProducerIDMetadataKey:   "someone-else",
		}},
		Records: []*addonpb.TelemetryRecord{ocsfTelemetryRecord(`{"class_uid":4003}`)},
	}
	loop.server.addonTelemetry.enqueue("powerdns", forged)

	require.True(t, loop.pushAddonTelemetry(context.Background()))

	batches := spooledTelemetryBatches(t, sp)
	require.Len(t, batches, 1)
	producerType, producerID, ok := edgerecord.TelemetryBatchProducer(batches[0])
	require.True(t, ok)
	require.Equal(t, "addon", producerType)
	require.Equal(t, "powerdns", producerID)
}

func TestTelemetrySpoolRetryKeepsOriginalEventIDs(t *testing.T) {
	inner := openTestEdgeSpool(t)
	script := &appendScript{inner: inner, refuseAfter: 0}
	loop := telemetryLoop(t, nil)
	loop.edgeTelemetrySpool = script
	capability := telemetryCapability(t, loop)

	loop.server.addonTelemetry.enqueue("powerdns", &addonpb.TelemetryBatch{
		Records: []*addonpb.TelemetryRecord{ocsfTelemetryRecord(`{"class_uid":4003}`)},
	})
	envelopes, _, _ := loop.server.addonTelemetry.drain(10)
	require.Len(t, envelopes, 1)
	loop.addonTelemetryEdge.enqueue([]telemetryEdgeItem{{
		producerType: "addon", producerID: "powerdns",
		batch: envelopes[0].batch, envelope: &envelopes[0],
	}})

	require.False(t, loop.spoolTelemetry(edgeProducerAddonTelemetry, &loop.addonTelemetryEdge, capability),
		"a refusing spool reports nothing handed off")
	firstIDs := append([][]byte{}, script.ids...)
	require.NotEmpty(t, firstIDs)

	script.admitAll()
	require.True(t, loop.spoolTelemetry(edgeProducerAddonTelemetry, &loop.addonTelemetryEdge, capability))
	require.Equal(t, firstIDs, script.ids, "a retry appends the same records under their original event ids")
	require.Len(t, spooledTelemetryBatches(t, inner), 1)
}

func TestTelemetryBatchSplitsOversizedBatchesAndFiltersRelayKinds(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := telemetryLoop(t, sp)
	capability := telemetryCapability(t, loop)

	large := strings.Repeat("x", 200<<10)
	batch := &addonpb.TelemetryBatch{
		Counters: &addonpb.TelemetryCounters{Received: 4},
		Records: []*addonpb.TelemetryRecord{
			ocsfTelemetryRecord(large), ocsfTelemetryRecord(large), ocsfTelemetryRecord(large), ocsfTelemetryRecord(large),
			{PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_LOGS, Payload: []byte("relay")},
		},
	}
	loop.addonTelemetryEdge.enqueue([]telemetryEdgeItem{{
		producerType: "addon", producerID: "powerdns", batch: batch,
	}})

	require.True(t, loop.spoolTelemetry(edgeProducerAddonTelemetry, &loop.addonTelemetryEdge, capability))

	batches := spooledTelemetryBatches(t, sp)
	require.Greater(t, len(batches), 1, "an over-cap batch splits into parts")
	total := 0
	for i, part := range batches {
		total += len(part.GetRecords())
		if i == 0 {
			require.EqualValues(t, 4, part.GetCounters().GetReceived(), "counters ride the first part")
		} else {
			require.Nil(t, part.GetCounters(), "later parts carry no counters")
		}
		for _, record := range part.GetRecords() {
			require.Equal(t, addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT, record.GetPayloadKind())
		}
	}
	require.Equal(t, 4, total, "the relay-kind record is filtered, the routed records all land")
}

func TestTelemetryTakeLeavesPartiallySpooledItemQueued(t *testing.T) {
	inner := openTestEdgeSpool(t)
	script := &appendScript{inner: inner, refuseAfter: 1}
	loop := telemetryLoop(t, nil)
	loop.edgeTelemetrySpool = script
	capability := telemetryCapability(t, loop)

	large := strings.Repeat("x", 300<<10)
	loop.addonTelemetryEdge.enqueue([]telemetryEdgeItem{
		{producerType: "addon", producerID: "powerdns", batch: &addonpb.TelemetryBatch{
			Records: []*addonpb.TelemetryRecord{ocsfTelemetryRecord(large), ocsfTelemetryRecord(large)},
		}},
		{producerType: "addon", producerID: "powerdns", batch: &addonpb.TelemetryBatch{
			Records: []*addonpb.TelemetryRecord{ocsfTelemetryRecord(`{"class_uid":4003}`)},
		}},
	})

	// One part lands, the rest is refused: the split item is committed to
	// the edge path.
	require.False(t, loop.spoolTelemetry(edgeProducerAddonTelemetry, &loop.addonTelemetryEdge, capability))

	taken := loop.addonTelemetryEdge.take()
	require.Len(t, taken, 1, "only the untouched second item may ride the legacy path")
	require.Len(t, taken[0].batch.GetRecords(), 1)
	require.NotNil(t, loop.addonTelemetryEdge.built, "the partially spooled item stays queued")
}

func TestTelemetryBatchSplitsAtGrantRowCeiling(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := telemetryLoop(t, sp)
	capability := telemetryCapabilityMaxRows(t, loop, 2)

	records := make([]*addonpb.TelemetryRecord, 0, 5)
	for range 5 {
		records = append(records, ocsfTelemetryRecord(`{"class_uid":4003}`))
	}
	loop.addonTelemetryEdge.enqueue([]telemetryEdgeItem{{
		producerType: "addon", producerID: "powerdns",
		batch: &addonpb.TelemetryBatch{Records: records},
	}})

	require.True(t, loop.spoolTelemetry(edgeProducerAddonTelemetry, &loop.addonTelemetryEdge, capability))

	batches := spooledTelemetryBatches(t, sp)
	require.Len(t, batches, 3, "five records under a two-row grant split into three records")
	total := 0
	for _, part := range batches {
		require.LessOrEqual(t, len(part.GetRecords()), 2)
		total += len(part.GetRecords())
	}
	require.Equal(t, 5, total)
}

func TestTelemetryBatchSplitAccountsForWholeRecordBound(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := telemetryLoop(t, sp)
	capability := telemetryCapability(t, loop)

	records := make([]*addonpb.TelemetryRecord, 0, 3)
	for seed := byte(1); seed <= 3; seed++ {
		records = append(records, &addonpb.TelemetryRecord{
			PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
			Payload:     incompressiblePayload(174_700, seed),
		})
	}
	loop.addonTelemetryEdge.enqueue([]telemetryEdgeItem{{
		producerType: "addon", producerID: "powerdns",
		batch: &addonpb.TelemetryBatch{Records: records},
	}})

	require.True(t, loop.spoolTelemetry(edgeProducerAddonTelemetry, &loop.addonTelemetryEdge, capability))

	batches := spooledTelemetryBatches(t, sp)
	require.Greater(t, len(batches), 1, "parts near the payload cap still fit the whole-record bound")
	total := 0
	for _, part := range batches {
		total += len(part.GetRecords())
	}
	require.Equal(t, 3, total)
}

func incompressiblePayload(size int, seed byte) []byte {
	out := make([]byte, 0, size)
	for len(out) < size {
		var counter [9]byte
		counter[0] = seed
		binary.BigEndian.PutUint64(counter[1:], uint64(len(out)/sha256.Size))
		block := sha256.Sum256(counter[:])
		out = append(out, block[:]...)
	}
	return out[:size]
}
