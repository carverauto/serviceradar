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
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func discoveryGrant(t *testing.T, contractID string, bytesPerRow uint64, packageID string) *proto.EdgeOutputGrant {
	t.Helper()
	version, ok := map[string]uint32{
		edgerecord.MapperDevicesContractID:      edgerecord.MapperDevicesContractVersion,
		edgerecord.MapperInterfacesContractID:   edgerecord.MapperInterfacesContractVersion,
		edgerecord.MapperTopologyContractID:     edgerecord.MapperTopologyContractVersion,
		edgerecord.NetprobeDiscoveryContractID:  edgerecord.NetprobeDiscoveryContractVersion,
		edgerecord.SyncPageContractID:           edgerecord.SyncPageContractVersion,
		edgerecord.K8sPublicEndpointsContractID: edgerecord.K8sPublicEndpointsContractVersion,
		edgerecord.EndpointInventoryContractID:  edgerecord.EndpointInventoryContractVersion,
	}[contractID]
	require.True(t, ok, "unknown discovery contract %s", contractID)
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	digest := sha256.Sum256([]byte("synthetic-" + contractID))
	now := time.Now()
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("test-issuer"),
		IssuerKeyId:       []byte("test-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: now.Add(-time.Hour).UnixNano(),
		ExpiresAtUnixNano: now.Add(8 * 24 * time.Hour).UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId: contractID, ContractVersion: version,
			ContractBundleSha256: digest[:], RegistryEpoch: 1, RegistrySnapshotSha256: digest[:], EffectiveGrantSha256: digest[:],
			NetworkScopeId: testNetworkScopeID[:], ProducerAssignmentId: testAssignmentID[:], RunId: testAssignmentID[:],
			AuthorityEpoch: 1, ScopeId: testAssignmentID[:], ScopeSha256: digest[:],
			OriginKind: edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT, OriginPrincipalId: []byte(sysmonEdgeAgentID), ProducerInstanceId: []byte(sysmonEdgeAgentID),
			RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:    packageID, PackageSha256: digest[:], CostModelVersion: 1,
			MaxProjectedRowCount: 10_000, MaxProjectedWriteBytes: 10_000 * bytesPerRow,
		}},
	}
	edgerecord.SignCapability(capability, key)
	encoded, err := gproto.Marshal(capability)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{
		ContractId:           contractID,
		ContractVersion:      version,
		ProductionCapability: encoded,
	}
}

func discoveryLoop(t *testing.T, sp *spool.Spool) *PushLoop {
	t.Helper()
	loop := &PushLoop{
		server: &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"}},
		logger: logger.NewTestLogger(),
	}
	loop.SetEdgeDiscoverySpool(sp)
	return loop
}

func grantDiscovery(t *testing.T, loop *PushLoop) {
	t.Helper()
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{
		discoveryGrant(t, edgerecord.MapperDevicesContractID, edgerecord.MapperDevicesProjectedWriteBytesPerRecord, "serviceradar.agent.mapper"),
		discoveryGrant(t, edgerecord.NetprobeDiscoveryContractID, edgerecord.NetprobeDiscoveryProjectedWriteBytesPerRecord, "serviceradar.agent.netprobe"),
		discoveryGrant(t, edgerecord.SyncPageContractID, edgerecord.SyncPageProjectedWriteBytesPerRecord, "serviceradar.agent.sync"),
	}, time.Now())
}

func spooledRecords(t *testing.T, sp *spool.Spool) []*edgev1.EdgeRecordV1 {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	records := make([]*edgev1.EdgeRecordV1, 0, len(stored))
	for _, s := range stored {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, gproto.Unmarshal(s.Body, record))
		records = append(records, record)
	}
	return records
}

func mapperDeviceUpdates() []map[string]interface{} {
	return []map[string]interface{}{
		{
			"device_id":    "sr:00000000-0000-4000-8000-000000000101",
			"ip":           "192.0.2.10",
			"source":       "mapper",
			"timestamp":    "2026-07-14T00:00:00Z",
			"is_available": true,
			"hostname":     "sw-core-01.example.com",
			"mac":          "00:53:00:00:00:10",
			"metadata": map[string]string{
				"source":            "mapper",
				"identity_mac_kind": "primary",
				"sys_name":          "sw-core-01.example.com",
			},
			"snmp_fingerprint": map[string]interface{}{
				"system": map[string]interface{}{
					"sys_name": "sw-core-01.example.com", "sys_descr": "Synthetic Switch OS 1.0",
					"sys_object_id": ".1.3.6.1.4.1.55555.1.1", "ip_forwarding": 1,
				},
			},
		},
	}
}

func TestMapperDevicesWithAGrantGoOnlyToTheEdgeSpool(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := discoveryLoop(t, sp)
	grantDiscovery(t, loop)

	payload, err := buildMapperResultsPayload(mapperDeviceUpdates(), sysmonEdgeAgentID, "default")
	require.NoError(t, err)

	sent := loop.pushDiscovery(discoveryMapperDevices, sysmonEdgeAgentID, "default", drainOf(new(int), payload), func([]byte) bool {
		t.Fatal("legacy path used while a grant is current")
		return false
	})
	require.True(t, sent)

	records := spooledRecords(t, sp)
	require.Len(t, records, 1)
	require.NoError(t, edgerecord.ValidateMapperDeviceRecord(records[0]))
	batch := &edgev1.MapperDeviceBatchV1{}
	require.NoError(t, gproto.Unmarshal(recordBody(t, records[0]), batch))
	require.Equal(t, sysmonEdgeAgentID, batch.GetAgentId())
	require.Len(t, batch.GetDevices(), 1)
	device := batch.GetDevices()[0]
	require.Equal(t, "192.0.2.10", device.GetIp())
	require.Equal(t, "00:53:00:00:00:10", device.GetMac())
	require.Equal(t, "primary", device.GetMetadata()["identity_mac_kind"])
	require.Equal(t, sysmonEdgeAgentID, device.GetMetadata()["sync_service_id"],
		"the builder's host stamp reaches the record")
	require.Equal(t, "sw-core-01.example.com", device.GetSnmpFingerprint().GetSystem().GetSysName())
	require.Equal(t, int32(1), device.GetSnmpFingerprint().GetSystem().GetIpForwarding())
}

// drainOf is a family drain that yields payloads on its first call and
// nothing after, counting every call in calls.
func drainOf(calls *int, payloads ...[]byte) func() [][]byte {
	return func() [][]byte {
		*calls++
		if *calls > 1 {
			return nil
		}
		return payloads
	}
}

func TestFailedLegacyDiscoverySendDropsTheDrainUncounted(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := discoveryLoop(t, sp)

	payload, err := buildMapperResultsPayload(mapperDeviceUpdates(), sysmonEdgeAgentID, "default")
	require.NoError(t, err)

	legacySent, legacyAttempts := 0, 0
	legacyOK := true
	legacySend := func([]byte) bool {
		legacyAttempts++
		if legacyOK {
			legacySent++
		}
		return legacyOK
	}

	calls := 0
	require.True(t, loop.pushDiscovery(discoveryMapperDevices, sysmonEdgeAgentID, "default",
		drainOf(&calls, payload), legacySend))
	require.Equal(t, 1, legacySent)

	legacyOK = false
	calls = 0
	require.False(t, loop.pushDiscovery(discoveryMapperDevices, sysmonEdgeAgentID, "default",
		drainOf(&calls, payload), legacySend))
	require.Equal(t, 2, legacyAttempts, "the failed drain is sent once, not retried")
	require.Nil(t, loop.mapperDevicesEdge.built, "a failed legacy send retains nothing")
	for reason := edgeDropReason(0); reason < edgeDropReasonCount; reason++ {
		require.Zero(t, edgeDrops(loop, edgeProducerMapper, reason),
			"a failed legacy send is logged, not counted as an edge drop")
	}

	// Once a grant is current only the next drain spools; the dropped one
	// is gone.
	grantDiscovery(t, loop)
	legacyOK = true
	calls = 0
	require.True(t, loop.pushDiscovery(discoveryMapperDevices, sysmonEdgeAgentID, "default",
		drainOf(&calls, payload), func([]byte) bool {
			t.Fatal("legacy path used while a grant is current")
			return false
		}))
	require.Len(t, spooledRecords(t, sp), 1)
}

func TestRefusedSpoolHoldsOneDrainAndStopsDrainingTheSource(t *testing.T) {
	loop := discoveryLoop(t, refusingEdgeSpool(t))
	grantDiscovery(t, loop)

	payload, err := buildMapperResultsPayload(mapperDeviceUpdates(), sysmonEdgeAgentID, "default")
	require.NoError(t, err)
	noLegacy := func([]byte) bool {
		t.Fatal("a drain held for the spool must not ride the legacy path")
		return false
	}

	calls := 0
	drain := drainOf(&calls, payload)
	require.False(t, loop.pushDiscovery(discoveryMapperDevices, sysmonEdgeAgentID, "default", drain, noLegacy))
	require.Equal(t, 1, calls)
	require.NotNil(t, loop.mapperDevicesEdge.built, "the refused drain is held")

	require.False(t, loop.pushDiscovery(discoveryMapperDevices, sysmonEdgeAgentID, "default", drain, noLegacy))
	require.Equal(t, 1, calls, "the source is not drained while a drain is held")

	// The grant lapses: the held drain still waits for the spool, never legacy.
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, nil, time.Now())
	require.False(t, loop.pushDiscovery(discoveryMapperDevices, sysmonEdgeAgentID, "default", drain, noLegacy))
	require.Equal(t, 1, calls)

	// The spool admits again: the held drain lands, then the source drains.
	accepting := openTestEdgeSpool(t)
	loop.SetEdgeDiscoverySpool(accepting)
	require.True(t, loop.pushDiscovery(discoveryMapperDevices, sysmonEdgeAgentID, "default", drain, noLegacy))
	require.Equal(t, 2, calls, "the source drains once the held drain is admitted")
	require.Nil(t, loop.mapperDevicesEdge.built)
	records := spooledRecords(t, accepting)
	require.Len(t, records, 1)
	require.NoError(t, edgerecord.ValidateMapperDeviceRecord(records[0]))
	require.Zero(t, edgeDrops(loop, edgeProducerMapper, edgeDropRetryBufferFull))
}

func TestNetprobeDiscoverySpoolsMetadataVerbatim(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := discoveryLoop(t, sp)
	grantDiscovery(t, loop)

	updates := []map[string]any{
		{
			"ip": "192.0.2.44", "agent_id": sysmonEdgeAgentID, "gateway_id": "gw-1",
			"partition": "default", "source": "passive-netprobe",
			"metadata": map[string]string{
				"discovery_source":              "passive-netprobe",
				"passive_fingerprint.os_family": "SyntheticOS",
				"_alias_collector_ip":           "192.0.2.1",
			},
			"timestamp": "2026-07-14T00:00:00Z",
		},
	}
	payloads, skipped, err := buildNetprobeResultsPayloads(updates, 0, 0)
	require.NoError(t, err)
	require.Zero(t, skipped)
	require.Len(t, payloads, 1)

	require.True(t, loop.pushDiscovery(discoveryNetprobe, sysmonEdgeAgentID, "default", drainOf(new(int), payloads[0]), func([]byte) bool {
		t.Fatal("legacy path used while a grant is current")
		return false
	}))

	records := spooledRecords(t, sp)
	require.Len(t, records, 1)
	require.NoError(t, edgerecord.ValidateNetprobeDiscoveryRecord(records[0]))
	batch := &edgev1.NetprobeDiscoveryBatchV1{}
	require.NoError(t, gproto.Unmarshal(recordBody(t, records[0]), batch))
	record := batch.GetRecords()[0]
	require.Equal(t, "192.0.2.44", record.GetIp())
	require.Equal(t, "SyntheticOS", record.GetMetadata()["passive_fingerprint.os_family"])
	require.Equal(t, "192.0.2.1", record.GetCollectorIp())
}

func TestOversizedDiscoveryUpdateDropsAlone(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := discoveryLoop(t, sp)
	grantDiscovery(t, loop)

	updates := mapperDeviceUpdates()
	big := map[string]interface{}{
		"device_id": "sr:00000000-0000-4000-8000-000000000102",
		"ip":        "192.0.2.11",
		"source":    "mapper",
		"timestamp": "2026-07-14T00:00:00Z",
		// Incompressible-ish bulk well past the 512 KiB record bound.
		"metadata": map[string]string{"bulk": strings.Repeat("0123456789abcdef", 48*1024)},
	}
	updates = append([]map[string]interface{}{big}, updates...)
	payload, err := buildMapperResultsPayload(updates, sysmonEdgeAgentID, "default")
	require.NoError(t, err)

	require.True(t, loop.pushDiscovery(discoveryMapperDevices, sysmonEdgeAgentID, "default", drainOf(new(int), payload), func([]byte) bool {
		t.Fatal("legacy path used while a grant is current")
		return false
	}))

	records := spooledRecords(t, sp)
	require.Len(t, records, 1)
	batch := &edgev1.MapperDeviceBatchV1{}
	require.NoError(t, gproto.Unmarshal(recordBody(t, records[0]), batch))
	require.Len(t, batch.GetDevices(), 1)
	require.Equal(t, "192.0.2.10", batch.GetDevices()[0].GetIp(),
		"the oversized head is dropped alone; the rest of the drain spools")
}

func TestAnchorlessDiscoveryUpdateDropsAloneMidDrain(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := discoveryLoop(t, sp)
	grantDiscovery(t, loop)

	device := func(id, ip string) map[string]interface{} {
		return map[string]interface{}{
			"device_id": id, "ip": ip, "source": "mapper", "agent_id": sysmonEdgeAgentID,
			"gateway_id": sysmonEdgeAgentID, "partition": "default",
			"hostname": "host.example.com", "timestamp": "2026-07-14T00:00:00Z",
		}
	}
	payload, err := json.Marshal([]map[string]interface{}{
		device("sr:00000000-0000-4000-8000-000000000201", "192.0.2.21"),
		device("sr:00000000-0000-4000-8000-000000000202", "192.0.2.22"),
		device("", ""),
		device("sr:00000000-0000-4000-8000-000000000204", "192.0.2.24"),
		device("sr:00000000-0000-4000-8000-000000000205", "192.0.2.25"),
	})
	require.NoError(t, err)

	require.True(t, loop.pushDiscovery(discoveryMapperDevices, sysmonEdgeAgentID, "default", drainOf(new(int), payload), func([]byte) bool {
		t.Fatal("legacy path used while a grant is current")
		return false
	}))

	records := spooledRecords(t, sp)
	ips := make([]string, 0, 4)
	for _, record := range records {
		require.NoError(t, edgerecord.ValidateMapperDeviceRecord(record))
		batch := &edgev1.MapperDeviceBatchV1{}
		require.NoError(t, gproto.Unmarshal(recordBody(t, record), batch))
		for _, d := range batch.GetDevices() {
			ips = append(ips, d.GetIp())
		}
	}
	require.Equal(t, []string{"192.0.2.21", "192.0.2.22", "192.0.2.24", "192.0.2.25"}, ips,
		"only the anchorless update drops; the updates after it still spool")
}

type recordingSyncGateway struct{ calls int }

func (g *recordingSyncGateway) StreamStatus(context.Context, []*proto.GatewayStatusChunk) (*proto.GatewayStatusResponse, error) {
	g.calls++
	return &proto.GatewayStatusResponse{}, nil
}

func (g *recordingSyncGateway) GetGatewayID() string { return "gw-test" }

func syncTestRuntime(t *testing.T, sp *spool.Spool, gateway *recordingSyncGateway) (*PushLoop, *SyncRuntime) {
	t.Helper()
	server := &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"}}
	runtime := &SyncRuntime{
		server:  server,
		gateway: gateway,
		logger:  logger.NewTestLogger(),
	}
	loop := &PushLoop{server: server, logger: logger.NewTestLogger(), syncRuntime: runtime}
	loop.SetEdgeSyncSpool(sp)
	return loop, runtime
}

func syncUpdate(uid, ip string) map[string]interface{} {
	return map[string]interface{}{
		"uid": uid, "ip": ip, "source": "synthetic-sync",
		"agent_id": sysmonEdgeAgentID, "gateway_id": "gw-test", "partition": "default",
		"hostname":  "host-" + uid + ".example.com",
		"metadata":  map[string]string{"source_device_id": uid},
		"timestamp": "2026-07-14T00:00:00Z",
	}
}

func decodeSyncPages(t *testing.T, sp *spool.Spool) []*edgev1.SyncPageBatchV1 {
	t.Helper()
	records := spooledRecords(t, sp)
	pages := make([]*edgev1.SyncPageBatchV1, 0, len(records))
	for _, record := range records {
		require.NoError(t, edgerecord.ValidateSyncPageRecord(record))
		page := &edgev1.SyncPageBatchV1{}
		require.NoError(t, gproto.Unmarshal(recordBody(t, record), page))
		pages = append(pages, page)
	}
	return pages
}

func TestSyncPagesSpoolWithRunMetaAndPopulationOnlyOnFinal(t *testing.T) {
	sp := openTestEdgeSpool(t)
	gateway := &recordingSyncGateway{}
	loop, runtime := syncTestRuntime(t, sp, gateway)
	grantDiscovery(t, loop)

	runner := &syncSourceRunner{config: models.SourceConfig{SyncServiceID: "svc-synthetic-1"}}
	population := &syncsources.PopulationStats{
		RawRows: 4, ValidOccurrences: 3, DistinctSourceIDs: 3,
		ConflictingDuplicateIDs: []string{"src-b"},
	}

	chunks, err := runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{syncUpdate("src-a", "192.0.2.60")}, "run-1", 1, 0, false, population)
	require.NoError(t, err)
	require.Equal(t, 1, chunks)

	chunks, err = runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{syncUpdate("src-b", "192.0.2.61"), syncUpdate("src-c", "192.0.2.62")},
		"run-1", 3, chunks, true, population)
	require.NoError(t, err)
	require.Equal(t, 1, chunks)

	control := map[string]interface{}{
		syncControlKey: syncCollectionFinal,
		"timestamp":    "2026-07-14T00:01:00Z",
	}
	chunks, err = runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{control}, "run-2", 0, 0, true, population)
	require.NoError(t, err)
	require.Equal(t, 1, chunks)

	require.Zero(t, gateway.calls, "legacy gateway must not be used while a grant is current")

	pages := decodeSyncPages(t, sp)
	require.Len(t, pages, 3)

	first := pages[0].GetSyncMeta()
	require.Equal(t, "svc-synthetic-1", first.GetSyncServiceId())
	require.Equal(t, "run-1", first.GetSyncRunId())
	require.Equal(t, int32(0), first.GetChunkIndex())
	require.Equal(t, int32(0), first.GetTotalChunks(), "total chunks stamp only on the final page")
	require.False(t, first.GetIsFinal())
	require.Nil(t, first.GetPopulation())

	final := pages[1].GetSyncMeta()
	require.Equal(t, int32(1), final.GetChunkIndex())
	require.Equal(t, int32(2), final.GetTotalChunks())
	require.True(t, final.GetIsFinal())
	require.Equal(t, int64(4), final.GetPopulation().GetRawRows())
	require.Equal(t, int64(1), final.GetPopulation().GetConflictingDuplicateIds())
	require.Equal(t, "src-b", pages[1].GetDevices()[0].GetUid())

	controlPage := pages[2]
	require.Empty(t, controlPage.GetDevices())
	require.Equal(t, syncCollectionFinal, controlPage.GetControlMarker().GetControlType())
	require.True(t, controlPage.GetSyncMeta().GetIsFinal())
}

func TestAnchorlessSyncDeviceDropsAloneAndThePageSpools(t *testing.T) {
	sp := openTestEdgeSpool(t)
	gateway := &recordingSyncGateway{}
	loop, runtime := syncTestRuntime(t, sp, gateway)
	grantDiscovery(t, loop)

	anchorless := syncUpdate("", "")
	delete(anchorless, "uid")
	delete(anchorless, "ip")
	runner := &syncSourceRunner{config: models.SourceConfig{SyncServiceID: "svc-synthetic-1"}}
	chunks, err := runtime.sendSyncUpdates(context.Background(), runner, []map[string]interface{}{
		syncUpdate("src-a", "192.0.2.80"),
		anchorless,
		syncUpdate("src-c", "192.0.2.82"),
	}, "run-13", 3, 0, true, nil)
	require.NoError(t, err, "one anchorless device must not fail the page")
	require.Positive(t, chunks)

	var uids []string
	for _, page := range decodeSyncPages(t, sp) {
		for _, device := range page.GetDevices() {
			uids = append(uids, device.GetUid())
		}
	}
	require.Equal(t, []string{"src-a", "src-c"}, uids)
	require.Zero(t, gateway.calls)
}

func TestSyncFinalPageWhoseDevicesAllDropFailsTheRun(t *testing.T) {
	sp := openTestEdgeSpool(t)
	gateway := &recordingSyncGateway{}
	loop, runtime := syncTestRuntime(t, sp, gateway)
	grantDiscovery(t, loop)

	anchorless := syncUpdate("", "")
	delete(anchorless, "uid")
	delete(anchorless, "ip")
	runner := &syncSourceRunner{config: models.SourceConfig{SyncServiceID: "svc-synthetic-1"}}
	chunks, err := runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{anchorless}, "run-14", 1, 0, true, nil)
	require.ErrorIs(t, err, errSyncFinalPageEmpty, "a run must not report success without its final record")
	require.Zero(t, chunks)
	require.Empty(t, spooledRecords(t, sp))
	require.Zero(t, gateway.calls)

	chunks, err = runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{anchorless}, "run-15", 1, 0, false, nil)
	require.NoError(t, err, "a non-final page still drops its unusable devices and continues")
	require.Zero(t, chunks)
}

func TestSyncRunRefusesToSplitAcrossPaths(t *testing.T) {
	sp := openTestEdgeSpool(t)
	gateway := &recordingSyncGateway{}
	loop, runtime := syncTestRuntime(t, sp, gateway)
	grantDiscovery(t, loop)

	runner := &syncSourceRunner{config: models.SourceConfig{SyncServiceID: "svc-synthetic-1"}}
	_, err := runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{syncUpdate("src-a", "192.0.2.60")}, "run-9", 1, 0, false, nil)
	require.NoError(t, err)
	require.Len(t, spooledRecords(t, sp), 1)

	// A later page whose every update is oversized appends nothing; the
	// run has still spooled a page.
	oversized := syncUpdate("src-x", "192.0.2.69")
	oversized["metadata"] = map[string]string{"bulk": strings.Repeat("0123456789abcdef", 48*1024)}
	chunks, err := runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{oversized}, "run-9", 2, 1, false, nil)
	require.NoError(t, err)
	require.Zero(t, chunks)

	// The grant lapses mid-run: the next page must fail rather than ride
	// the legacy path past the spooled page.
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, nil, time.Now())
	_, err = runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{syncUpdate("src-b", "192.0.2.61")}, "run-9", 3, 1, true, nil)
	require.ErrorContains(t, err, "refusing to split")
	require.Zero(t, gateway.calls)

	// A different run still takes the legacy path.
	_, err = runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{syncUpdate("src-b", "192.0.2.61")}, "run-10", 1, 0, true, nil)
	require.NoError(t, err)
	require.Equal(t, 1, gateway.calls)
}

func TestFailedSpooledSyncRunForgetsItsSplitGuard(t *testing.T) {
	sp := openTestEdgeSpool(t)
	gateway := &recordingSyncGateway{}
	loop, runtime := syncTestRuntime(t, sp, gateway)
	runtime.drivers = fakeSyncDrivers()
	grantDiscovery(t, loop)

	runner := newFakeSourceRunner(map[string]string{"pages": "3", "fail_after_pages": "2"})
	_, err := runtime.runSourceOnce(context.Background(), runner, "scheduled", "run-12")
	require.ErrorIs(t, err, errFakeSyncDriverFailed)
	require.NotEmpty(t, spooledRecords(t, sp), "the failed run spooled pages before failing")

	inFlight := 0
	runtime.edgeRuns.Range(func(any, any) bool { inFlight++; return true })
	require.Zero(t, inFlight, "a finished run must not keep its split guard")

	// Without a grant the same run id is no longer held to the spool.
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, nil, time.Now())
	_, err = runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{syncUpdate("src-z", "192.0.2.70")}, "run-12", 1, 0, true, nil)
	require.NoError(t, err)
	require.Equal(t, 1, gateway.calls)
}
