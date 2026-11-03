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

func discoveryGrant(t *testing.T, contractID string, version uint32, bytesPerRow uint64, packageID string) *proto.EdgeOutputGrant {
	t.Helper()
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
		discoveryGrant(t, edgerecord.MapperDevicesContractID, edgerecord.MapperDevicesContractVersion, edgerecord.MapperDevicesProjectedWriteBytesPerRecord, "serviceradar.agent.mapper"),
		discoveryGrant(t, edgerecord.NetprobeDiscoveryContractID, edgerecord.NetprobeDiscoveryContractVersion, edgerecord.NetprobeDiscoveryProjectedWriteBytesPerRecord, "serviceradar.agent.netprobe"),
		discoveryGrant(t, edgerecord.SyncPageContractID, edgerecord.SyncPageContractVersion, edgerecord.SyncPageProjectedWriteBytesPerRecord, "serviceradar.agent.sync"),
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

	sent := loop.pushDiscoveryPayload(context.Background(), discoveryMapperDevices, payload,
		sysmonEdgeAgentID, "default", func([]byte) bool {
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

func TestDiscoveryWithoutAGrantUsesLegacyThenRetainsOrderOnceGranted(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop := discoveryLoop(t, sp)

	payload, err := buildMapperResultsPayload(mapperDeviceUpdates(), sysmonEdgeAgentID, "default")
	require.NoError(t, err)

	var legacySeen [][]byte
	legacyOK := true
	legacySend := func(data []byte) bool {
		if legacyOK {
			legacySeen = append(legacySeen, append([]byte(nil), data...))
		}
		return legacyOK
	}

	require.True(t, loop.pushDiscoveryPayload(context.Background(), discoveryMapperDevices,
		payload, sysmonEdgeAgentID, "default", legacySend))
	require.Len(t, legacySeen, 1)

	// A failed legacy send retains the drain instead of losing it.
	legacyOK = false
	require.False(t, loop.pushDiscoveryPayload(context.Background(), discoveryMapperDevices,
		payload, sysmonEdgeAgentID, "default", legacySend))
	require.Len(t, legacySeen, 1)

	// Once a grant is current the retained payload spools (and only spools).
	grantDiscovery(t, loop)
	require.True(t, loop.pushDiscoveryPayload(context.Background(), discoveryMapperDevices,
		payload, sysmonEdgeAgentID, "default", legacySend))
	require.Len(t, legacySeen, 1, "retained payload must not ride legacy after the grant")
	require.Len(t, spooledRecords(t, sp), 2, "retained payload and the new drain both spool")
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

	require.True(t, loop.pushDiscoveryPayload(context.Background(), discoveryNetprobe,
		payloads[0], sysmonEdgeAgentID, "default", func([]byte) bool {
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

	require.True(t, loop.pushDiscoveryPayload(context.Background(), discoveryMapperDevices,
		payload, sysmonEdgeAgentID, "default", func([]byte) bool {
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
	var pages []*edgev1.SyncPageBatchV1
	for _, record := range spooledRecords(t, sp) {
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

	// The grant lapses mid-run: the next page must fail rather than ride
	// the legacy path past the spooled page.
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, nil, time.Now())
	_, err = runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{syncUpdate("src-b", "192.0.2.61")}, "run-9", 2, 1, true, nil)
	require.ErrorContains(t, err, "refusing to split")
	require.Zero(t, gateway.calls)

	// A different run still takes the legacy path.
	_, err = runtime.sendSyncUpdates(context.Background(), runner,
		[]map[string]interface{}{syncUpdate("src-b", "192.0.2.61")}, "run-10", 1, 0, true, nil)
	require.NoError(t, err)
	require.Equal(t, 1, gateway.calls)
}
