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
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	gproto "google.golang.org/protobuf/proto"

	agentgateway "github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
)

// The agent id the loop under test runs as.
const sysmonEdgeAgentID = "agent-test-01"

// metricsGrant is a standing metrics batch grant for agentID, valid in
// [notBefore, expires). All identity material is synthetic.
func metricsGrant(t *testing.T, agentID string, notBefore, expires time.Time) *proto.EdgeOutputGrant {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	digest := sha256.Sum256([]byte("synthetic-metrics-contract"))
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("test-issuer"),
		IssuerKeyId:       []byte("test-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: notBefore.UnixNano(),
		ExpiresAtUnixNano: expires.UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId: edgerecord.MetricsBatchContractID, ContractVersion: edgerecord.MetricsBatchContractVersion,
			ContractBundleSha256: digest[:], RegistryEpoch: 1, RegistrySnapshotSha256: digest[:], EffectiveGrantSha256: digest[:],
			NetworkScopeId: testNetworkScopeID[:], ProducerAssignmentId: testAssignmentID[:], RunId: testAssignmentID[:],
			AuthorityEpoch: 1, ScopeId: testAssignmentID[:], ScopeSha256: digest[:],
			OriginKind: edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT, OriginPrincipalId: []byte(agentID), ProducerInstanceId: []byte(agentID),
			RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:    "serviceradar.agent.metrics", PackageSha256: digest[:], CostModelVersion: 1,
			MaxProjectedRowCount: 10_000, MaxProjectedWriteBytes: 10_000 * edgeMetricsProjectedRowBytes,
		}},
	}
	edgerecord.SignCapability(capability, key)
	encoded, err := gproto.Marshal(capability)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{
		ContractId:           edgerecord.MetricsBatchContractID,
		ContractVersion:      edgerecord.MetricsBatchContractVersion,
		ProductionCapability: encoded,
	}
}

func currentMetricsGrant(t *testing.T) *proto.EdgeOutputGrant {
	t.Helper()
	now := time.Now()
	return metricsGrant(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour))
}

func TestEdgeOutputGrantIntake(t *testing.T) {
	now := time.Now()
	otherContract := currentMetricsGrant(t)
	otherContract.ContractId = "serviceradar.sweep.observation"

	cases := map[string]struct {
		grant   *proto.EdgeOutputGrant
		current bool
	}{
		"a current grant":                  {currentMetricsGrant(t), true},
		"a grant for another agent":        {metricsGrant(t, "agent-test-02", now.Add(-time.Hour), now.Add(48*time.Hour)), false},
		"an expired grant":                 {metricsGrant(t, sysmonEdgeAgentID, now.Add(-48*time.Hour), now.Add(-time.Hour)), false},
		"a grant naming another contract":  {otherContract, false},
		"a grant inside its expiry margin": {metricsGrant(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(edgeOutputGrantDeliveryMargin/2)), false},
	}
	for name, tc := range cases {
		var grants edgeOutputGrants
		grants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{tc.grant}, now)
		got := grants.current(edgerecord.MetricsBatchContractID, now) != nil
		require.Equal(t, tc.current, got, name)
	}

	var grants edgeOutputGrants
	grants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, now)
	grants.replace(sysmonEdgeAgentID, nil, now)
	require.Nil(t, grants.current(edgerecord.MetricsBatchContractID, now), "an empty grant list withdraws the grant")
}

// fakeSysmonCollector hands out queued samples on Drain.
type fakeSysmonCollector struct {
	sysmon.Collector
	queued []*sysmon.MetricSample
}

func (c *fakeSysmonCollector) Drain() []*sysmon.MetricSample {
	out := c.queued
	c.queued = nil
	return out
}

func syntheticSysmonSamples(n int) []*sysmon.MetricSample {
	samples := make([]*sysmon.MetricSample, n)
	for i := range samples {
		samples[i] = &sysmon.MetricSample{
			Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
			HostID:    "host01.example.com",
			HostIP:    "192.0.2.10",
			AgentID:   sysmonEdgeAgentID,
			CPUs:      []sysmon.CPUMetric{{CoreID: 0, UsagePercent: 12.5}, {CoreID: 1, UsagePercent: 40}},
			Memory:    sysmon.MemoryMetric{UsedBytes: 1 << 30, TotalBytes: 4 << 30},
		}
	}
	return samples
}

// sysmonStatusGateway is a disposable AgentGatewayService peer that counts the
// sysmon statuses the agent streams to it over the real StreamStatus RPC.
type sysmonStatusGateway struct {
	proto.UnimplementedAgentGatewayServiceServer

	mu     sync.Mutex
	sysmon int
}

func (g *sysmonStatusGateway) StreamStatus(stream grpc.ClientStreamingServer[proto.GatewayStatusChunk, proto.GatewayStatusResponse]) error {
	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return stream.SendAndClose(&proto.GatewayStatusResponse{Received: true})
		}
		if err != nil {
			return err
		}
		for _, status := range chunk.GetServices() {
			if status.GetSource() == "sysmon-metrics" {
				g.mu.Lock()
				g.sysmon++
				g.mu.Unlock()
			}
		}
	}
}

func (g *sysmonStatusGateway) sysmonStatuses() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.sysmon
}

// sysmonEdgeLoop is a push loop with a real gateway client and server, a sysmon
// service draining the fake collector, and sp as its metrics edge spool.
func sysmonEdgeLoop(t *testing.T, sp *spool.Spool) (*PushLoop, *sysmonStatusGateway, *fakeSysmonCollector) {
	t.Helper()
	t.Setenv("SR_ALLOW_INSECURE", "true")

	gw := &sysmonStatusGateway{}
	lis, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	require.NoError(t, err)
	server := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(server, gw)
	go func() { _ = server.Serve(lis) }()
	t.Cleanup(func() {
		server.Stop()
		_ = lis.Close()
	})
	client := agentgateway.NewGatewayClient(lis.Addr().String(), nil, logger.NewTestLogger())
	require.NoError(t, client.Connect(t.Context()))
	t.Cleanup(func() { _ = client.Disconnect() })

	collector := &fakeSysmonCollector{}
	loop := &PushLoop{
		server: &Server{
			config:        &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default", HostIP: "192.0.2.10"},
			sysmonService: &SysmonService{collector: collector},
		},
		logger:  logger.NewTestLogger(),
		gateway: client,
	}
	loop.SetEdgeMetricsSpool(sp)
	return loop, gw, collector
}

func openTestEdgeSpool(t *testing.T, opts ...spool.Option) *spool.Spool {
	t.Helper()
	sp, err := spool.Open(t.TempDir(), opts...)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	return sp
}

// spooledMetricBatches decodes every record in sp, requiring each to pass the
// metrics batch contract.
func spooledMetricBatches(t *testing.T, sp *spool.Spool) []*metricpb.MetricBatch {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	batches := make([]*metricpb.MetricBatch, 0, len(stored))
	for _, s := range stored {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, gproto.Unmarshal(s.Body, record))
		require.NoError(t, edgerecord.ValidateMetricBatchRecord(record))
		require.Nil(t, record.GetSourceAuthorization())
		batch := &metricpb.MetricBatch{}
		require.NoError(t, gproto.Unmarshal(recordBody(t, record), batch))
		batches = append(batches, batch)
	}
	return batches
}

func TestSysmonMetricsWithAGrantGoOnlyToTheEdgeSpool(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, gw, collector := sysmonEdgeLoop(t, sp)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())
	collector.queued = syntheticSysmonSamples(3)

	require.True(t, loop.pushSysmonStatus(context.Background(), nil))

	require.Zero(t, gw.sysmonStatuses(), "no legacy StreamStatus while the agent holds a metrics grant")
	batches := spooledMetricBatches(t, sp)
	require.Len(t, batches, 1, "three small samples fit one record")
	require.Equal(t, "sysmon-metrics", batches[0].GetIngestIdentity().GetSource())
	want, err := buildSysmonMetricBatch(syntheticSysmonSamples(3), loop.metricEnvelopeContext())
	require.NoError(t, err)
	require.Len(t, batches[0].GetMetrics(), len(want.GetMetrics()))
}

func TestSysmonMetricsWithoutAGrantKeepTheLegacyPath(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, gw, collector := sysmonEdgeLoop(t, sp)
	collector.queued = syntheticSysmonSamples(3)

	require.True(t, loop.pushSysmonStatus(context.Background(), nil))

	require.Equal(t, 1, gw.sysmonStatuses(), "sysmon metrics take StreamStatus without a grant")
	require.Empty(t, spooledMetricBatches(t, sp))
}

// refusingEdgeSpool admits nothing: its allocator leaves no ordinary headroom
// for even one metrics record.
func refusingEdgeSpool(t *testing.T) *spool.Spool {
	t.Helper()
	footprint := spool.Footprint{DestinationSegment: 1024, AttributionSidecar: 64, JournalCopy: 64, ManifestPages: 64, Mapping: 64, FilesystemMetadata: 64}
	perRecovery, err := footprint.PerRecovery()
	require.NoError(t, err)
	const minFree = 4096
	alloc, err := spool.NewAllocator(spool.AllocatorConfig{Capacity: perRecovery + minFree + 256, Recovery: footprint, MaxConcurrentRecoveries: 1, MinFree: minFree})
	require.NoError(t, err)
	return openTestEdgeSpool(t, spool.WithAllocator(alloc))
}

func TestARefusedSysmonEdgeAppendRetainsSamplesAndCountsOverflow(t *testing.T) {
	loop, gw, collector := sysmonEdgeLoop(t, refusingEdgeSpool(t))
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

	collector.queued = syntheticSysmonSamples(maxPendingSysmonEdgeSamples + 5)
	require.False(t, loop.pushSysmonStatus(context.Background(), nil))

	require.Zero(t, gw.sysmonStatuses(), "a refused append never falls back to StreamStatus")
	require.Len(t, loop.sysmonEdgePending, maxPendingSysmonEdgeSamples)
	var metrics strings.Builder
	require.NoError(t, loop.server.edgeProducerDrops.write(&metrics))
	require.Contains(t, metrics.String(), `agent_edge_record_dropped_samples_total{producer="sysmon",reason="retry_buffer_full"} 5`)

	// Once the spool admits again, the retained samples are spooled first.
	roomy := openTestEdgeSpool(t)
	loop.SetEdgeMetricsSpool(roomy)
	require.True(t, loop.pushSysmonStatus(context.Background(), nil))
	require.Empty(t, loop.sysmonEdgePending)
	spooled := 0
	for _, batch := range spooledMetricBatches(t, roomy) {
		spooled += len(batch.GetMetrics())
	}
	perSample, err := buildSysmonMetricBatch(syntheticSysmonSamples(1), loop.metricEnvelopeContext())
	require.NoError(t, err)
	require.Equal(t, maxPendingSysmonEdgeSamples*len(perSample.GetMetrics()), spooled)
}
