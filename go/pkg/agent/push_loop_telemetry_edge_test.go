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
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func telemetryGrantLimits(t *testing.T, agentID string, maxRows uint32, maxWriteBytes uint64) *proto.EdgeOutputGrant {
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
			MaxProjectedRowCount: maxRows, MaxProjectedWriteBytes: maxWriteBytes,
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
	return telemetryCapabilityLimits(t, loop, maxRows, uint64(maxRows)*edgerecord.TelemetryProjectedWriteBytesPerRecord)
}

func telemetryCapabilityLimits(t *testing.T, loop *PushLoop, maxRows uint32, maxWriteBytes uint64) *edgev1.EdgeSignedCapabilityV1 {
	t.Helper()
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{telemetryGrantLimits(t, sysmonEdgeAgentID, maxRows, maxWriteBytes)}, time.Now())
	capability := loop.edgeTelemetryCapability(time.Now())
	require.NotNil(t, capability)
	return capability
}

func telemetryLoop(t *testing.T, sp *RecordSpool) *PushLoop {
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

func spooledTelemetryBatches(t *testing.T, sp *RecordSpool) []*addonpb.TelemetryBatch {
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

	require.True(t, loop.pushAddonTelemetry())

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
		batch: envelopes[0].batch,
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

// warnCaptureLogger records Warn events and discards every other level.
type warnCaptureLogger struct {
	logger.Logger
	output zerolog.Logger
}

func (l warnCaptureLogger) Warn() *zerolog.Event { return l.output.Warn() }

func TestAddonTelemetryGrantReportsBufferDrops(t *testing.T) {
	sp := openTestEdgeSpool(t)
	var output bytes.Buffer
	loop := &PushLoop{
		server: &Server{
			config:         &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
			addonTelemetry: newAddonTelemetryBuffer(1),
		},
		logger: warnCaptureLogger{Logger: logger.NewTestLogger(), output: zerolog.New(&output)},
	}
	loop.SetEdgeTelemetrySpool(sp)
	telemetryCapability(t, loop)

	kept := ocsfTelemetryRecord(`{"class_uid":4003,"raw":"kept"}`)
	discarded := ocsfTelemetryRecord(`{"class_uid":4003,"raw":"discarded"}`)
	loop.server.addonTelemetry.enqueue("powerdns", &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{kept}})
	loop.server.addonTelemetry.enqueue("powerdns", &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{discarded}})

	require.True(t, loop.pushAddonTelemetry())

	batches := spooledTelemetryBatches(t, sp)
	require.Len(t, batches, 1)
	require.Equal(t, [][]byte{kept.GetPayload()}, telemetryPayloads(batches))

	reports := addonTelemetryDropReports(t, output.String())
	require.Len(t, reports, 1)
	require.EqualValues(t, 1, reports[0]["dropped_since_last"])
	require.EqualValues(t, 1, reports[0]["dropped_total"])
	require.Zero(t, edgeDrops(loop, edgeProducerAddonTelemetry, edgeDropRetryBufferFull))
	require.Zero(t, edgeDrops(loop, edgeProducerAddonTelemetry, edgeDropInvalidRecord))

	output.Reset()
	require.False(t, loop.pushAddonTelemetry())
	require.Empty(t, addonTelemetryDropReports(t, output.String()))
}

func telemetryPayloads(batches []*addonpb.TelemetryBatch) [][]byte {
	payloads := make([][]byte, 0, len(batches))
	for _, batch := range batches {
		for _, record := range batch.GetRecords() {
			payloads = append(payloads, record.GetPayload())
		}
	}
	return payloads
}

func addonTelemetryDropReports(t *testing.T, logged string) []map[string]any {
	t.Helper()
	var reports []map[string]any
	for _, line := range strings.Split(logged, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var event map[string]any
		require.NoError(t, json.Unmarshal([]byte(line), &event))
		if event["message"] == "Dropped add-on telemetry before push" {
			reports = append(reports, event)
		}
	}
	return reports
}

func TestTelemetryBatchSkipsHeadThatFailsRecordValidation(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := telemetryLoop(t, sp)
	// 256 KiB admits one row (projected write is 8192). The middle record's
	// batch stays under the 512 KiB payload cap and still cannot form a
	// part: its encoded edge record exceeds the whole-record bound.
	const writeCeiling = 256 * 1024
	capability := telemetryCapabilityLimits(t, loop, 4096, writeCeiling)

	smallA := ocsfTelemetryRecord(`{"class_uid":4003,"raw":"a"}`)
	smallB := ocsfTelemetryRecord(`{"class_uid":4003,"raw":"b"}`)
	head := &addonpb.TelemetryRecord{
		PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		Payload:     incompressiblePayload(edgeTelemetryMaxPayloadBytes-700, 5),
	}
	batch := &addonpb.TelemetryBatch{
		Counters: &addonpb.TelemetryCounters{Received: 3},
		Records:  []*addonpb.TelemetryRecord{smallA, head, smallB},
	}
	stamped := gproto.Clone(batch).(*addonpb.TelemetryBatch)
	stamped.Source = &addonpb.TelemetrySource{Metadata: map[string]string{
		edgerecord.TelemetryProducerTypeMetadataKey: "addon",
		edgerecord.TelemetryProducerIDMetadataKey:   "powerdns",
	}}
	stamped.Records = []*addonpb.TelemetryRecord{head}
	raw, err := gproto.Marshal(stamped)
	require.NoError(t, err)
	require.LessOrEqual(t, len(raw), edgeTelemetryMaxPayloadBytes, "the head is not refused by the payload cap")

	loop.addonTelemetryEdge.enqueue([]telemetryEdgeItem{{
		producerType: "addon", producerID: "powerdns", batch: batch,
	}})

	require.True(t, loop.spoolTelemetry(edgeProducerAddonTelemetry, &loop.addonTelemetryEdge, capability))

	var spooled [][]byte
	parts := spooledTelemetryBatches(t, sp)
	require.GreaterOrEqual(t, len(parts), 1)
	for i, part := range parts {
		if i == 0 {
			require.EqualValues(t, 3, part.GetCounters().GetReceived())
		} else {
			require.Nil(t, part.GetCounters())
		}
		for _, record := range part.GetRecords() {
			spooled = append(spooled, record.GetPayload())
		}
	}
	require.Equal(t, [][]byte{smallA.GetPayload(), smallB.GetPayload()}, spooled)
	require.Equal(t, uint64(1), edgeDrops(loop, edgeProducerAddonTelemetry, edgeDropInvalidRecord))
}

func TestTelemetryBatchKeepsRecordsBesideOneThatCannotFormAPart(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := telemetryLoop(t, sp)
	capability := telemetryCapability(t, loop)

	smallA := ocsfTelemetryRecord(`{"class_uid":4003,"raw":"a"}`)
	smallB := ocsfTelemetryRecord(`{"class_uid":4003,"raw":"b"}`)
	oversized := &addonpb.TelemetryRecord{
		PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
		Payload:     incompressiblePayload(edgeTelemetryMaxPayloadBytes+1, 9),
	}
	loop.addonTelemetryEdge.enqueue([]telemetryEdgeItem{{
		producerType: "addon", producerID: "powerdns",
		batch: &addonpb.TelemetryBatch{
			Counters: &addonpb.TelemetryCounters{Received: 4},
			Records: []*addonpb.TelemetryRecord{
				smallA, smallB, oversized,
				{PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_LOGS, Payload: []byte("relay")},
			},
		},
	}})

	require.True(t, loop.spoolTelemetry(edgeProducerAddonTelemetry, &loop.addonTelemetryEdge, capability))

	var spooled [][]byte
	for i, part := range spooledTelemetryBatches(t, sp) {
		if i == 0 {
			require.EqualValues(t, 4, part.GetCounters().GetReceived(), "counters ride the first part")
		} else {
			require.Nil(t, part.GetCounters(), "later parts carry no counters")
		}
		for _, record := range part.GetRecords() {
			spooled = append(spooled, record.GetPayload())
		}
	}
	require.Equal(t, [][]byte{smallA.GetPayload(), smallB.GetPayload()}, spooled)
	require.Equal(t, uint64(2), edgeDrops(loop, edgeProducerAddonTelemetry, edgeDropInvalidRecord),
		"the oversized record and the unrouted kind are each counted once")
	require.Zero(t, edgeDrops(loop, edgeProducerAddonTelemetry, edgeDropRetryBufferFull))
}

func TestTelemetryEnqueueKeepsABatchOverTheQueuedRecordCeiling(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := telemetryLoop(t, sp)
	capability := telemetryCapability(t, loop)

	const recordsInBatch = maxEdgeTelemetryQueuedRecords + 1
	records := make([]*addonpb.TelemetryRecord, recordsInBatch)
	for i := range records {
		records[i] = ocsfTelemetryRecord(`{"class_uid":4003}`)
	}
	dropped := loop.addonTelemetryEdge.enqueue([]telemetryEdgeItem{{
		producerType: "addon", producerID: "powerdns",
		batch: &addonpb.TelemetryBatch{Records: records},
	}})
	require.Zero(t, dropped, "a single batch over the queue ceiling is admitted and packed, not deleted")

	require.True(t, loop.spoolTelemetry(edgeProducerAddonTelemetry, &loop.addonTelemetryEdge, capability))

	total := 0
	for _, part := range spooledTelemetryBatches(t, sp) {
		total += len(part.GetRecords())
	}
	require.Equal(t, recordsInBatch, total)
	require.Zero(t, edgeDrops(loop, edgeProducerAddonTelemetry, edgeDropRetryBufferFull))
	require.Zero(t, loop.addonTelemetryEdge.queuedRecords())
}

func TestPluginSignalWithAGrantSpoolsTheAssignmentStamp(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := telemetryLoop(t, sp)
	telemetryCapability(t, loop)

	// The batch source claims an add-on. The host stamp comes from the
	// signal's assignment, so a guest cannot reattribute the record.
	forged := &addonpb.TelemetryBatch{
		Source: &addonpb.TelemetrySource{Metadata: map[string]string{
			edgerecord.TelemetryProducerTypeMetadataKey: "addon",
			edgerecord.TelemetryProducerIDMetadataKey:   "someone-else",
		}},
		Records: []*addonpb.TelemetryRecord{ocsfTelemetryRecord(`{"class_uid":4003}`)},
	}
	manager := &PluginManager{signals: make(chan PluginSignalTelemetry, 1)}
	manager.signals <- PluginSignalTelemetry{
		AssignmentID: "assignment-9",
		PluginID:     "plugin-9",
		Batch:        forged,
	}
	loop.server.pluginManager = manager

	require.True(t, loop.pushPluginSignals())

	batches := spooledTelemetryBatches(t, sp)
	require.Len(t, batches, 1)
	producerType, producerID, ok := edgerecord.TelemetryBatchProducer(batches[0])
	require.True(t, ok)
	require.Equal(t, "plugin", producerType)
	require.Equal(t, "assignment-9", producerID)
}

func TestAddonTelemetryWithoutAGrantIsHeldAndCountedUntilAGrantIsHeld(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := telemetryLoop(t, sp)

	// The older batch alone fills the queue's record bound; the newer one
	// pushes it out while no grant is held.
	older := make([]*addonpb.TelemetryRecord, maxEdgeTelemetryQueuedRecords)
	for i := range older {
		older[i] = ocsfTelemetryRecord(fmt.Sprintf(`{"class_uid":4003,"raw":"older-%d"}`, i))
	}
	newer := ocsfTelemetryRecord(`{"class_uid":4003,"raw":"newer"}`)

	loop.server.addonTelemetry.enqueue("powerdns", &addonpb.TelemetryBatch{Records: older})
	require.False(t, loop.pushAddonTelemetry(), "no grant: nothing is handed off")
	require.Equal(t, maxEdgeTelemetryQueuedRecords, loop.addonTelemetryEdge.queuedRecords(), "no grant: the batch is held")
	require.Empty(t, spooledTelemetryBatches(t, sp))

	loop.server.addonTelemetry.enqueue("powerdns", &addonpb.TelemetryBatch{Records: []*addonpb.TelemetryRecord{newer}})
	require.False(t, loop.pushAddonTelemetry())
	require.Equal(t, uint64(maxEdgeTelemetryQueuedRecords),
		edgeDrops(loop, edgeProducerAddonTelemetry, edgeDropAwaitingGrant),
		"overflow while waiting for a grant is counted, not silent")
	require.Zero(t, edgeDrops(loop, edgeProducerAddonTelemetry, edgeDropRetryBufferFull))
	require.Equal(t, uint64(2), loop.server.edgeProducerDrops.grantHolds[edgeProducerAddonTelemetry].Load())

	telemetryCapability(t, loop)
	require.True(t, loop.pushAddonTelemetry())
	require.Equal(t, [][]byte{newer.GetPayload()}, telemetryPayloads(spooledTelemetryBatches(t, sp)))
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
