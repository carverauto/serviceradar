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
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func pluginResultsGrant(t *testing.T, agentID string) *proto.EdgeOutputGrant {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	digest := sha256.Sum256([]byte("synthetic-plugin-results-contract"))
	now := time.Now()
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("test-issuer"),
		IssuerKeyId:       []byte("test-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: now.Add(-time.Hour).UnixNano(),
		ExpiresAtUnixNano: now.Add(8 * 24 * time.Hour).UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId: edgerecord.PluginResultsContractID, ContractVersion: edgerecord.PluginResultsContractVersion,
			ContractBundleSha256: digest[:], RegistryEpoch: 1, RegistrySnapshotSha256: digest[:], EffectiveGrantSha256: digest[:],
			NetworkScopeId: testNetworkScopeID[:], ProducerAssignmentId: testAssignmentID[:], RunId: testAssignmentID[:],
			AuthorityEpoch: 1, ScopeId: testAssignmentID[:], ScopeSha256: digest[:],
			OriginKind: edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT, OriginPrincipalId: []byte(agentID), ProducerInstanceId: []byte(agentID),
			RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:    "serviceradar.agent.plugin_results", PackageSha256: digest[:], CostModelVersion: 1,
			MaxProjectedRowCount: 10_000, MaxProjectedWriteBytes: 10_000 * edgerecord.PluginResultsProjectedWriteBytesPerRecord,
		}},
	}
	edgerecord.SignCapability(capability, key)
	encoded, err := gproto.Marshal(capability)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{
		ContractId:           edgerecord.PluginResultsContractID,
		ContractVersion:      edgerecord.PluginResultsContractVersion,
		ProductionCapability: encoded,
	}
}

func pluginResultsLoop(t *testing.T, sp *spool.Spool) *PushLoop {
	t.Helper()
	loop := &PushLoop{
		server: &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"}},
		logger: logger.NewTestLogger(),
	}
	loop.SetEdgePluginResultSpool(sp)
	return loop
}

func pluginResultsCapability(t *testing.T, loop *PushLoop) *edgev1.EdgeSignedCapabilityV1 {
	t.Helper()
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID,
		[]*proto.EdgeOutputGrant{pluginResultsGrant(t, sysmonEdgeAgentID)}, time.Now())
	capability := loop.edgePluginResultsCapability(time.Now())
	require.NotNil(t, capability)
	return capability
}

func spooledPluginResultBatches(t *testing.T, sp *spool.Spool) []*edgev1.WasmPluginResultBatchV1 {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	batches := make([]*edgev1.WasmPluginResultBatchV1, 0, len(stored))
	for _, s := range stored {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, gproto.Unmarshal(s.Body, record))
		require.NoError(t, edgerecord.ValidatePluginResultRecord(record))
		require.Nil(t, record.GetSourceAuthorization())
		batch := &edgev1.WasmPluginResultBatchV1{}
		require.NoError(t, gproto.Unmarshal(recordBody(t, record), batch))
		batches = append(batches, batch)
	}
	return batches
}

func hostPluginResult(payload string) PluginResult {
	return PluginResult{
		AssignmentID:   "assignment-9",
		PluginID:       "synthetic-check",
		PluginName:     "synthetic-check",
		PackageID:      "pkg-synthetic-1",
		PackageVersion: "1.0.0",
		ContentHash:    strings.Repeat("ab", 32),
		Payload:        []byte(payload),
		ObservedAt:     time.Date(2026, 7, 14, 0, 0, 0, 0, time.UTC),
	}
}

func TestPluginResultsWithAGrantGoOnlyToTheEdgeSpool(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := pluginResultsLoop(t, sp)
	pluginResultsCapability(t, loop)

	acknowledged := hostPluginResult(`{
			"status":"OK","summary":"synthetic check healthy","schema_version":1,
			"labels":{"env":"lab"},
			"events":[{"id":"evt-1","time":"2026-07-14T00:00:00Z","class_uid":1008,"category_uid":1,
			  "type_uid":100801,"activity_id":1,"severity_id":1,"severity":"Informational","message":"probe ok"}],
			"device_discovery":[{"schema":"serviceradar.device_discovery.v1","collection_id":"col-1",
			  "devices":[{"device_id":"dev-1","hostname":"sensor.example.com","ip":"192.0.2.10","is_available":true}]}]
		}`)
	acknowledged.AcknowledgedRunOverrides = []string{"override-f1"}

	loop.pendingPluginResults = []PluginResult{
		acknowledged,
		hostPluginResult(`{"status":"CRITICAL","summary":"synthetic check down"}`),
	}

	require.True(t, loop.pushPluginResults(context.Background()))
	require.Empty(t, loop.pendingPluginResults)

	batches := spooledPluginResultBatches(t, sp)
	require.Len(t, batches, 1, "one provenance group spools as one batch")
	batch := batches[0]
	require.Equal(t, "assignment-9", batch.GetProvenance().GetAssignmentId())
	require.Equal(t, "synthetic-check", batch.GetProvenance().GetPluginId())
	require.Equal(t, strings.Repeat("ab", 32), batch.GetProvenance().GetContentHash())
	require.Len(t, batch.GetResults(), 2)

	first := batch.GetResults()[0]
	require.Equal(t, edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_OK, first.GetStatus())
	require.Equal(t, "synthetic check healthy", first.GetSummary())
	require.Equal(t, "synthetic-check", first.GetServiceName())
	require.Equal(t, "plugin", first.GetServiceType())
	require.Equal(t, []string{"override-f1"}, first.GetRunOverridesAcknowledged(),
		"the host-authored acknowledgement list reaches the edge record")
	require.Equal(t, "assignment-9", first.GetLabels()["assignment_id"], "host labels are stamped")
	require.Equal(t, sysmonEdgeAgentID, first.GetLabels()["agent_id"])
	require.Len(t, first.GetEvents(), 1)
	require.Contains(t, string(first.GetEvents()[0].GetPayloadJson()), `"evt-1"`)
	require.Len(t, first.GetDeviceDiscovery(), 1)
	require.Equal(t, "192.0.2.10", first.GetDeviceDiscovery()[0].GetDevices()[0].GetIp())
	require.True(t, first.GetDeviceDiscovery()[0].GetDevices()[0].GetHasIsAvailable())
	require.Equal(t, edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_CRITICAL, batch.GetResults()[1].GetStatus())
}

func TestPluginResultsInvalidPayloadBecomesUnknownLikeLegacy(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := pluginResultsLoop(t, sp)
	pluginResultsCapability(t, loop)

	loop.pendingPluginResults = []PluginResult{
		hostPluginResult(`{"summary":"missing status"}`),
	}
	require.True(t, loop.pushPluginResults(context.Background()))

	batches := spooledPluginResultBatches(t, sp)
	require.Len(t, batches, 1)
	require.Equal(t, edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_UNKNOWN, batches[0].GetResults()[0].GetStatus())
	require.Contains(t, batches[0].GetResults()[0].GetSummary(), "plugin result invalid")
}

func TestPluginResultsRecordBoundDropsOnlyTheOversizedResult(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := pluginResultsLoop(t, sp)
	capability := pluginResultsCapability(t, loop)
	details := pluginResultDetailsAtRecordBound(t, loop, capability)

	loop.pendingPluginResults = []PluginResult{
		hostPluginResult(`{"status":"OK","summary":"small before"}`),
		hostPluginResult(pluginResultPayload(t, "oversized details", details)),
		hostPluginResult(`{"status":"OK","summary":"small after"}`),
	}
	require.True(t, loop.pushPluginResults(context.Background()))
	require.Empty(t, loop.pendingPluginResults)
	require.Zero(t, loop.pluginResultsEdge.queuedResults())

	var summaries []string
	for _, batch := range spooledPluginResultBatches(t, sp) {
		require.Equal(t, "assignment-9", batch.GetProvenance().GetAssignmentId())
		for _, result := range batch.GetResults() {
			summaries = append(summaries, result.GetSummary())
			require.Less(t, len(result.GetDetails()), 64)
		}
	}
	require.Equal(t, []string{"small before", "small after"}, summaries)
	require.Equal(t, uint64(1), edgeDrops(loop, edgeProducerPluginResults, edgeDropInvalidRecord))
}

// pluginResultDetailsAtRecordBound is the largest high-entropy details string
// whose one-result batch still fits the 512 KiB payload cap and whose wrapped
// record ValidateRecord rejects with ErrRecordTooLarge. The oracle is that
// bound, not the producer's drop counter: a payload over the cap would already
// have been a per-result miss before the record-bound fix.
func pluginResultDetailsAtRecordBound(t *testing.T, loop *PushLoop, capability *edgev1.EdgeSignedCapabilityV1) string {
	t.Helper()
	best := ""
	lo, hi := 1, edgePluginResultsMaxPayloadBytes
	for lo <= hi {
		mid := lo + (hi-lo)/2
		details := asciiNoise(mid, 5)
		payloadLen, err := pluginResultRecordAttempt(t, loop, capability, details)
		switch {
		case payloadLen > edgePluginResultsMaxPayloadBytes || errors.Is(err, errPluginResultTooLarge):
			hi = mid - 1
		case errors.Is(err, edgerecord.ErrRecordTooLarge):
			best = details
			lo = mid + 1
		case err != nil:
			t.Fatalf("details %d: %v", mid, err)
		default:
			lo = mid + 1
		}
	}
	require.NotEmpty(t, best, "no details length is under the payload cap and over the record bound")
	require.Greater(t, len(best), 400<<10, "the record-bound window sits just under the 512 KiB payload cap")
	return best
}

func pluginResultRecordAttempt(
	t *testing.T,
	loop *PushLoop,
	capability *edgev1.EdgeSignedCapabilityV1,
	details string,
) (int, error) {
	t.Helper()
	result := hostPluginResult(pluginResultPayload(t, "oversized details", details))
	item := groupPluginResults([]PluginResult{result})[0]
	batch := &edgev1.WasmPluginResultBatchV1{
		Provenance: item.provenance,
		Results:    []*edgev1.WasmPluginResultItemV1{loop.convertPluginResult(result, sysmonEdgeAgentID, "default")},
	}
	payload, err := gproto.MarshalOptions{Deterministic: true}.Marshal(batch)
	require.NoError(t, err)
	_, _, recErr := pluginResultEdgeRecord(batch, capability)
	return len(payload), recErr
}

func pluginResultPayload(t *testing.T, summary, details string) string {
	t.Helper()
	raw, err := json.Marshal(map[string]string{
		"status":  "OK",
		"summary": summary,
		"details": details,
	})
	require.NoError(t, err)
	return string(raw)
}

func TestPluginResultsTakeLeavesPartiallySpooledGroupQueued(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := pluginResultsLoop(t, sp)
	capability := pluginResultsCapability(t, loop)

	big := strings.Repeat("x", 300<<10)
	loop.pluginResultsEdge.enqueue(groupPluginResults([]PluginResult{
		hostPluginResult(`{"status":"OK","summary":"big one","details":"` + big + `"}`),
		hostPluginResult(`{"status":"OK","summary":"big two","details":"` + big + `"}`),
	}))

	// Spool only the first part, then lose the grant: the partially spooled
	// group must stay queued and never rejoin the legacy set.
	built, _, err := loop.buildPluginResultItem(loop.pluginResultsEdge.pending[0], capability, sysmonEdgeAgentID, "default")
	require.NoError(t, err)
	require.Greater(t, len(built.records), 1)
	loop.pluginResultsEdge.pending = loop.pluginResultsEdge.pending[1:]
	loop.pluginResultsEdge.built = built
	require.True(t, loop.appendPluginResultBuilt(built) || built.next > 0)
	built.next = 1

	taken := loop.pluginResultsEdge.take(maxPluginResultsPerStream)
	require.Empty(t, taken)
	require.NotNil(t, loop.pluginResultsEdge.built, "the partially spooled group stays queued")
}

func TestPluginResultsLegacyFallbackStaysWithinOneStream(t *testing.T) {
	const groups, perGroup = 3, 5
	manager := &PluginManager{results: make(chan PluginResult, maxPluginResultsPerStream)}
	for i := 0; i < maxPluginResultsPerStream; i++ {
		manager.results <- testPendingPluginResult("fresh", "fresh")
	}

	var streams [][]string
	loop := &PushLoop{
		server: &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID}, pluginManager: manager},
		logger: logger.NewTestLogger(),
		pluginResultStreamStatus: func(
			_ context.Context,
			chunks []*proto.GatewayStatusChunk,
		) (*proto.GatewayStatusResponse, error) {
			streams = append(streams, pluginResultAssignments(t, chunks))
			return &proto.GatewayStatusResponse{Received: true}, nil
		},
	}
	for g := 0; g < groups; g++ {
		queued := make([]PluginResult, 0, perGroup)
		for i := 0; i < perGroup; i++ {
			queued = append(queued, testPendingPluginResult(fmt.Sprintf("queued-%d", g), "queued"))
		}
		loop.pluginResultsEdge.enqueue(groupPluginResults(queued))
	}

	for cycle := 0; cycle < 3; cycle++ {
		require.True(t, loop.pushPluginResults(context.Background()))
		require.LessOrEqual(t, len(streams[cycle]), maxPluginResultsPerStream,
			"a legacy stream never exceeds the gateway retained-stream chunk cap")
		if cycle == 0 {
			require.Equal(t, perGroup, loop.pluginResultsEdge.queuedResults(), "the remainder stays queued")
			require.Len(t, manager.results, maxPluginResultsPerStream, "nothing fresh drains while queued items remain")
		}
	}

	want := [][]string{
		append(slices.Repeat([]string{"queued-0"}, perGroup), slices.Repeat([]string{"queued-1"}, perGroup)...),
		slices.Repeat([]string{"queued-2"}, perGroup),
		slices.Repeat([]string{"fresh"}, maxPluginResultsPerStream),
	}
	require.Equal(t, want, streams)
	require.Zero(t, loop.pluginResultsEdge.queuedResults())
}
