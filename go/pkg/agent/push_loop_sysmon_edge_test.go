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
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net"
	"slices"
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
	return metricsGrantRows(t, agentID, notBefore, expires, 10_000)
}

func metricsGrantRows(t *testing.T, agentID string, notBefore, expires time.Time, maxRows uint32) *proto.EdgeOutputGrant {
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
			MaxProjectedRowCount: maxRows, MaxProjectedWriteBytes: uint64(maxRows) * edgeMetricsProjectedRowBytes,
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

func TestOversizedSysmonSampleIsSplitAcrossRecords(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, gw, collector := sysmonEdgeLoop(t, sp)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

	sample, original := sysmonSampleOverPayloadCap(t, loop.metricEnvelopeContext())
	collector.queued = []*sysmon.MetricSample{sample}

	require.True(t, loop.pushSysmonStatus(context.Background(), nil))

	require.Zero(t, gw.sysmonStatuses())
	require.Empty(t, loop.sysmonEdgePending)
	require.Zero(t, sysmonEdgeDrops(loop, edgeDropInvalidRecord))
	batches := spooledMetricBatches(t, sp)
	require.Greater(t, len(batches), 1)
	require.Equal(t, flattenedMetricPoints([]*metricpb.MetricBatch{original}), flattenedMetricPoints(batches))
	assertSysmonRecordsWithinCaps(t, sp, batches, 10_000)
}

func TestSysmonSampleOverRowCeilingIsSplitAcrossRecords(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, gw, collector := sysmonEdgeLoop(t, sp)
	now := time.Now()
	grant := metricsGrantRows(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{grant}, now)

	sample := syntheticSysmonSamples(1)[0]
	collector.queued = []*sysmon.MetricSample{sample}
	original, err := buildSysmonMetricBatch([]*sysmon.MetricSample{sample}, loop.metricEnvelopeContext())
	require.NoError(t, err)
	require.Greater(t, len(original.GetMetrics()), 1)

	require.True(t, loop.pushSysmonStatus(context.Background(), nil))

	require.Zero(t, gw.sysmonStatuses())
	require.Empty(t, loop.sysmonEdgePending)
	require.Zero(t, sysmonEdgeDrops(loop, edgeDropInvalidRecord))
	batches := spooledMetricBatches(t, sp)
	require.Greater(t, len(batches), 1)
	require.Equal(t, flattenedMetricPoints([]*metricpb.MetricBatch{original}), flattenedMetricPoints(batches))
	assertSysmonRecordsWithinCaps(t, sp, batches, 1)
}

func TestSysmonPrefixOverCanonicalRecordLimitIsShortened(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, gw, collector := sysmonEdgeLoop(t, sp)
	now := time.Now()
	grant := currentMetricsGrant(t)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{grant}, now)

	first, second := sysmonSamplesAtCanonicalBoundary(t, grant, loop.metricEnvelopeContext())
	original, err := buildSysmonMetricBatch([]*sysmon.MetricSample{first, second}, loop.metricEnvelopeContext())
	require.NoError(t, err)
	collector.queued = []*sysmon.MetricSample{first, second}

	require.True(t, loop.pushSysmonStatus(context.Background(), nil))

	require.Zero(t, gw.sysmonStatuses())
	require.Empty(t, loop.sysmonEdgePending)
	require.Zero(t, sysmonEdgeDrops(loop, edgeDropInvalidRecord))
	batches := spooledMetricBatches(t, sp)
	require.Greater(t, len(batches), 1, "the combined record does not fit, so the prefix is shortened")
	require.Equal(t, flattenedMetricPoints([]*metricpb.MetricBatch{original}), flattenedMetricPoints(batches))
	assertSysmonRecordsWithinCaps(t, sp, batches, 10_000)
}

func sysmonEdgeDrops(loop *PushLoop, reason edgeDropReason) uint64 {
	return loop.server.edgeProducerDrops.dropped[edgeProducerSysmon][reason].Load()
}

func sysmonSampleOverPayloadCap(t *testing.T, ctx metricEnvelopeContext) (*sysmon.MetricSample, *metricpb.MetricBatch) {
	t.Helper()
	for n := 256; n <= 1<<16; n *= 2 {
		sample := processHeavySample(n, func(i int) string { return fmt.Sprintf("process-%d", i) })
		batch, err := buildSysmonMetricBatch([]*sysmon.MetricSample{sample}, ctx)
		require.NoError(t, err)
		if gproto.Size(batch) > edgeMetricsMaxPayloadBytes {
			return sample, batch
		}
	}
	t.Fatal("a process list never exceeded the metrics payload cap")
	return nil, nil
}

func sysmonSamplesAtCanonicalBoundary(t *testing.T, grant *proto.EdgeOutputGrant, ctx metricEnvelopeContext) (*sysmon.MetricSample, *sysmon.MetricSample) {
	t.Helper()
	capability := &edgev1.EdgeSignedCapabilityV1{}
	require.NoError(t, gproto.Unmarshal(grant.GetProductionCapability(), capability))
	maxRows := min(uint64(capability.GetProduction().GetMaxProjectedRowCount()),
		capability.GetProduction().GetMaxProjectedWriteBytes()/edgeMetricsProjectedRowBytes)

	best := 0
	lo, hi := 1, edgeMetricsMaxPayloadBytes
	for lo <= hi {
		mid := lo + (hi-lo)/2
		if gproto.Size(twoDiskSamplesBatch(t, ctx, mid)) <= edgeMetricsMaxPayloadBytes {
			best = mid
			lo = mid + 1
			continue
		}
		hi = mid - 1
	}
	require.Positive(t, best)

	first := diskNoiseSample(best, 1)
	second := diskNoiseSample(best, 2)
	oneBatch, err := buildSysmonMetricBatch([]*sysmon.MetricSample{first}, ctx)
	require.NoError(t, err)
	both, err := buildSysmonMetricBatch([]*sysmon.MetricSample{first, second}, ctx)
	require.NoError(t, err)
	require.LessOrEqual(t, gproto.Size(both), edgeMetricsMaxPayloadBytes)
	_, err = metricsEdgeRecord(oneBatch, capability, maxRows)
	require.NoError(t, err)
	_, err = metricsEdgeRecord(both, capability, maxRows)
	require.ErrorIs(t, err, edgerecord.ErrRecordTooLarge)
	return first, second
}

func twoDiskSamplesBatch(t *testing.T, ctx metricEnvelopeContext, noise int) *metricpb.MetricBatch {
	t.Helper()
	batch, err := buildSysmonMetricBatch([]*sysmon.MetricSample{diskNoiseSample(noise, 1), diskNoiseSample(noise, 2)}, ctx)
	require.NoError(t, err)
	return batch
}

func diskNoiseSample(noise int, seed byte) *sysmon.MetricSample {
	sample := syntheticSysmonSamples(1)[0]
	sample.Disks = []sysmon.DiskMetric{{
		MountPoint: asciiNoise(noise, seed),
		UsedBytes:  1,
		TotalBytes: 2,
	}}
	return sample
}

func asciiNoise(n int, seed byte) string {
	if n < 0 {
		n = 0
	}
	out := make([]byte, n)
	var counter uint32
	filled := 0
	for filled < n {
		counter++
		block := sha256.Sum256([]byte{seed, byte(counter), byte(counter >> 8), byte(counter >> 16), byte(counter >> 24)})
		for _, by := range block {
			if filled == n {
				break
			}
			out[filled] = 0x21 + by%94
			filled++
		}
	}
	return string(out)
}

func processHeavySample(processes int, nameOf func(int) string) *sysmon.MetricSample {
	sample := syntheticSysmonSamples(1)[0]
	sample.Processes = make([]sysmon.ProcessMetric, processes)
	for i := range sample.Processes {
		sample.Processes[i] = sysmon.ProcessMetric{
			PID:         uint32(i + 1),
			Name:        nameOf(i),
			CPUUsage:    1.25,
			MemoryUsage: uint64(i + 1),
			Status:      "running",
			StartTime:   "2026-11-01T00:00:00Z",
		}
	}
	return sample
}

func flattenedMetricPoints(batches []*metricpb.MetricBatch) []string {
	var keys []string
	for _, batch := range batches {
		if batch == nil {
			continue
		}
		for _, metric := range batch.GetMetrics() {
			points := metric.GetPoints()
			if len(points) == 0 {
				keys = append(keys, metric.GetName())
				continue
			}
			for _, point := range points {
				keys = append(keys, metric.GetName()+"\t"+point.GetSeriesIdentityHint()+"\t"+point.GetRawValue())
			}
		}
	}
	return keys
}

// appendScript is a spool that accepts a fixed number of appends and then
// refuses. permanentOn is the 1-based append in this phase that is permanent;
// 0 means none. refuseAfter is how many appends succeed before a retryable
// refusal; negative means every non-permanent append is admitted.
type appendScript struct {
	inner       *spool.Spool
	refuseAfter int
	permanentOn int
	ids         [][]byte
	bodies      [][]byte
}

func (a *appendScript) Append(eventID, body []byte) (uint64, error) {
	n := len(a.ids) + 1
	a.ids = append(a.ids, bytes.Clone(eventID))
	a.bodies = append(a.bodies, bytes.Clone(body))
	if a.permanentOn == n {
		return 0, spool.ErrPermanent
	}
	if a.refuseAfter >= 0 && n > a.refuseAfter {
		return 0, spool.ErrAdmissionRefused
	}
	return a.inner.Append(eventID, body)
}

func (a *appendScript) reset(refuseAfter, permanentOn int) {
	a.refuseAfter = refuseAfter
	a.permanentOn = permanentOn
	a.ids = nil
	a.bodies = nil
}

func TestSysmonSplitRetryAppendsEachPartOnce(t *testing.T) {
	inner := openTestEdgeSpool(t)
	script := &appendScript{inner: inner, refuseAfter: 1}
	loop, gw, collector := sysmonEdgeLoop(t, nil)
	loop.edgeMetricsSpool = script
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

	sample, original := sysmonSampleOverPayloadCap(t, loop.metricEnvelopeContext())
	collector.queued = []*sysmon.MetricSample{sample}
	require.True(t, loop.pushSysmonStatus(context.Background(), nil))
	require.GreaterOrEqual(t, len(script.ids), 2, "the spool refused after admitting one part")
	require.Len(t, spooledMetricBatches(t, inner), 1)
	require.NotEmpty(t, loop.sysmonEdgePending)
	require.Nil(t, loop.sysmonEdgePending[0].sample, "the unsent tail is queued as built records")
	refused := bytes.Clone(script.ids[1])
	admitted := bytes.Clone(script.ids[0])

	script.reset(-1, 0)
	require.True(t, loop.pushSysmonStatus(context.Background(), nil))

	require.NotEmpty(t, script.ids)
	require.Equal(t, refused, script.ids[0], "the refused part keeps its event id")
	for _, id := range script.ids {
		require.NotEqual(t, admitted, id, "an admitted part is not appended again")
	}
	require.Zero(t, gw.sysmonStatuses())
	require.Empty(t, loop.sysmonEdgePending)
	batches := spooledMetricBatches(t, inner)
	require.Equal(t, flattenedMetricPoints([]*metricpb.MetricBatch{original}), flattenedMetricPoints(batches))
	require.Len(t, uniqueEventIDs(t, inner), len(batches))
}

func TestSysmonSplitRemainderStaysOffStreamStatusWithoutAGrant(t *testing.T) {
	inner := openTestEdgeSpool(t)
	script := &appendScript{inner: inner, refuseAfter: 1}
	loop, gw, collector := sysmonEdgeLoop(t, nil)
	loop.edgeMetricsSpool = script
	now := time.Now()
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, now)

	sample, original := sysmonSampleOverPayloadCap(t, loop.metricEnvelopeContext())
	collector.queued = []*sysmon.MetricSample{sample}
	require.True(t, loop.pushSysmonStatus(context.Background(), nil))
	require.GreaterOrEqual(t, len(script.ids), 2)
	queued := len(loop.sysmonEdgePending)
	require.Positive(t, queued)
	stored := len(spooledMetricBatches(t, inner))

	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, nil, now)
	require.False(t, loop.pushSysmonStatus(context.Background(), nil))

	require.Zero(t, gw.sysmonStatuses(), "a partly admitted sample does not take StreamStatus")
	require.Len(t, loop.sysmonEdgePending, queued)
	require.Len(t, spooledMetricBatches(t, inner), stored)

	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, now)
	script.reset(-1, 0)
	require.True(t, loop.pushSysmonStatus(context.Background(), nil))
	require.Zero(t, gw.sysmonStatuses())
	require.Empty(t, loop.sysmonEdgePending)
	require.Equal(t, flattenedMetricPoints([]*metricpb.MetricBatch{original}), flattenedMetricPoints(spooledMetricBatches(t, inner)))
}

func TestSysmonSplitPermanentRefusalDropsOnlyThatPart(t *testing.T) {
	inner := openTestEdgeSpool(t)
	script := &appendScript{inner: inner, refuseAfter: -1, permanentOn: 2}
	loop, gw, collector := sysmonEdgeLoop(t, nil)
	loop.edgeMetricsSpool = script
	now := time.Now()
	grant := metricsGrantRows(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{grant}, now)

	sample := syntheticSysmonSamples(1)[0]
	original, err := buildSysmonMetricBatch([]*sysmon.MetricSample{sample}, loop.metricEnvelopeContext())
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(original.GetMetrics()), 3)
	collector.queued = []*sysmon.MetricSample{sample}
	require.True(t, loop.pushSysmonStatus(context.Background(), nil))

	require.GreaterOrEqual(t, len(script.ids), 3, "parts after the permanent refusal are still admitted")
	require.Zero(t, gw.sysmonStatuses())
	require.Empty(t, loop.sysmonEdgePending)
	require.Equal(t, uint64(1), sysmonEdgeDrops(loop, edgeDropRefused))
	require.Len(t, spooledMetricBatches(t, inner), len(script.ids)-1)

	permanent := flattenedMetricPoints([]*metricpb.MetricBatch{batchFromCanonical(t, script.bodies[1])})
	want, ok := spliceOut(flattenedMetricPoints([]*metricpb.MetricBatch{original}), permanent)
	require.True(t, ok, "the refused part is a contiguous slice of the original points")
	require.Equal(t, want, flattenedMetricPoints(spooledMetricBatches(t, inner)))
}

func TestSysmonUnsplittablePointIsCountedOnceAcrossRetries(t *testing.T) {
	inner := openTestEdgeSpool(t)
	script := &appendScript{inner: inner, refuseAfter: 0}
	loop, gw, collector := sysmonEdgeLoop(t, nil)
	loop.edgeMetricsSpool = script
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

	sample, original := sysmonSampleWithUnsplittablePoint(t, loop.metricEnvelopeContext())
	collector.queued = []*sysmon.MetricSample{sample}
	require.False(t, loop.pushSysmonStatus(context.Background(), nil))
	drops := sysmonEdgeDrops(loop, edgeDropInvalidRecord)
	require.Equal(t, uint64(1), drops)
	require.Zero(t, gw.sysmonStatuses())
	require.Empty(t, spooledMetricBatches(t, inner))

	require.False(t, loop.pushSysmonStatus(context.Background(), nil))
	require.Equal(t, drops, sysmonEdgeDrops(loop, edgeDropInvalidRecord), "a retry does not count the unsplittable point again")

	script.reset(-1, 0)
	require.True(t, loop.pushSysmonStatus(context.Background(), nil))
	require.Equal(t, drops, sysmonEdgeDrops(loop, edgeDropInvalidRecord))
	require.Zero(t, gw.sysmonStatuses())
	got := flattenedMetricPoints(spooledMetricBatches(t, inner))
	originalPoints := flattenedMetricPoints([]*metricpb.MetricBatch{original})
	require.True(t, metricNamed(originalPoints, "disk.used_percent"))
	require.False(t, metricNamed(got, "disk.used_percent"))
	require.True(t, metricNamed(got, "memory.used_percent"))
}

func metricNamed(keys []string, name string) bool {
	prefix := name + "\t"
	for _, key := range keys {
		if key == name || strings.HasPrefix(key, prefix) {
			return true
		}
	}
	return false
}

func sysmonSampleWithUnsplittablePoint(t *testing.T, ctx metricEnvelopeContext) (*sysmon.MetricSample, *metricpb.MetricBatch) {
	t.Helper()
	sample := syntheticSysmonSamples(1)[0]
	sample.Disks = []sysmon.DiskMetric{{
		MountPoint: asciiNoise(edgeMetricsMaxPayloadBytes+4096, 7),
		UsedBytes:  1,
		TotalBytes: 2,
	}}
	batch, err := buildSysmonMetricBatch([]*sysmon.MetricSample{sample}, ctx)
	require.NoError(t, err)
	require.Greater(t, gproto.Size(batch), edgeMetricsMaxPayloadBytes)
	return sample, batch
}

func batchFromCanonical(t *testing.T, body []byte) *metricpb.MetricBatch {
	t.Helper()
	record := &edgev1.EdgeRecordV1{}
	require.NoError(t, gproto.Unmarshal(body, record))
	batch := &metricpb.MetricBatch{}
	require.NoError(t, gproto.Unmarshal(recordBody(t, record), batch))
	return batch
}

func uniqueEventIDs(t *testing.T, sp *spool.Spool) [][]byte {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	ids := make([][]byte, 0, len(stored))
	seen := map[string]struct{}{}
	for _, s := range stored {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, gproto.Unmarshal(s.Body, record))
		id := string(record.GetEventId())
		require.NotContains(t, seen, id)
		seen[id] = struct{}{}
		ids = append(ids, record.GetEventId())
	}
	return ids
}

func spliceOut(all, gap []string) ([]string, bool) {
	if len(gap) == 0 || len(gap) > len(all) {
		return nil, false
	}
	for i := 0; i+len(gap) <= len(all); i++ {
		if !slices.Equal(all[i:i+len(gap)], gap) {
			continue
		}
		out := make([]string, 0, len(all)-len(gap))
		out = append(out, all[:i]...)
		out = append(out, all[i+len(gap):]...)
		return out, true
	}
	return nil, false
}

func assertSysmonRecordsWithinCaps(t *testing.T, sp *spool.Spool, batches []*metricpb.MetricBatch, maxRows int) {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	require.Len(t, stored, len(batches))
	for _, storedRecord := range stored {
		require.LessOrEqual(t, len(storedRecord.Body), edgerecord.MaxRecordBytes)
	}
	for _, batch := range batches {
		payload, err := gproto.MarshalOptions{Deterministic: true}.Marshal(batch)
		require.NoError(t, err)
		require.LessOrEqual(t, len(payload), edgeMetricsMaxPayloadBytes)
		require.LessOrEqual(t, len(batch.GetMetrics()), maxRows)
		require.NotEmpty(t, batch.GetMetrics())
	}
}
