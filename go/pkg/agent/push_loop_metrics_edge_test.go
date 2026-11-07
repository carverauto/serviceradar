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
	"fmt"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	snmpchecker "github.com/carverauto/serviceradar/go/pkg/agent/snmp"
	agentgateway "github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
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

// sysmonEdgeLoop is a push loop with an unconnected gateway client, a sysmon
// service draining the fake collector, and sp as its metrics edge spool.
func sysmonEdgeLoop(t *testing.T, sp *spool.Spool) (*PushLoop, *fakeSysmonCollector) {
	t.Helper()
	collector := &fakeSysmonCollector{}
	loop := &PushLoop{
		server: &Server{
			config:        &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default", HostIP: "192.0.2.10"},
			sysmonService: &SysmonService{collector: collector},
		},
		logger:  logger.NewTestLogger(),
		gateway: agentgateway.NewGatewayClient("192.0.2.1:50052", nil, logger.NewTestLogger()),
	}
	if sp != nil {
		loop.SetEdgeMetricsSpool(sp)
	}
	return loop, collector
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
	loop, collector := sysmonEdgeLoop(t, sp)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())
	collector.queued = syntheticSysmonSamples(3)

	require.True(t, loop.pushSysmonMetrics())

	batches := spooledMetricBatches(t, sp)
	require.Len(t, batches, 1, "three small samples fit one record")
	require.Equal(t, "sysmon-metrics", batches[0].GetIngestIdentity().GetSource())
	want, err := buildSysmonMetricBatch(syntheticSysmonSamples(3), loop.metricEnvelopeContext())
	require.NoError(t, err)
	require.Len(t, batches[0].GetMetrics(), len(want.GetMetrics()))
}

// Without a metrics grant a metric producer sends its items nowhere: they wait
// in its bounded queue, the oldest beyond the bound are dropped and counted as
// awaiting_grant, and the hold is counted. Once the grant is held the queued
// items are spooled first. The sysmon case drives the real sysmon push; the
// ICMP case the real ICMP push, whose check against a TEST-NET address returns
// a result whether or not it can probe.
func TestMetricsWithoutAGrantAreHeldUntilTheGrantIsHeld(t *testing.T) {
	t.Run("sysmon", func(t *testing.T) {
		sp := openTestEdgeSpool(t)
		loop, collector := sysmonEdgeLoop(t, sp)
		collector.queued = syntheticSysmonSamples(maxPendingEdgeMetrics + 5)

		require.False(t, loop.pushSysmonMetrics())
		require.Empty(t, spooledMetricBatches(t, sp))
		require.Len(t, queuedItemsOf(&loop.sysmonEdge), maxPendingEdgeMetrics)
		require.Equal(t, uint64(5), edgeDrops(loop, edgeProducerSysmon, edgeDropAwaitingGrant))
		require.Equal(t, uint64(1), loop.server.edgeProducerDrops.grantHolds[edgeProducerSysmon].Load())
		var metrics strings.Builder
		require.NoError(t, loop.server.edgeProducerDrops.write(&metrics))
		require.Contains(t, metrics.String(), `agent_edge_record_dropped_samples_total{producer="sysmon",reason="awaiting_grant"} 5`)
		require.Contains(t, metrics.String(), `agent_edge_record_grant_holds_total{producer="sysmon"} 1`)

		loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())
		require.True(t, loop.pushSysmonMetrics())
		require.Empty(t, loop.sysmonEdge.pending)
		spooled := 0
		for _, batch := range spooledMetricBatches(t, sp) {
			spooled += len(batch.GetMetrics())
		}
		perSample, err := buildSysmonMetricBatch(syntheticSysmonSamples(1), loop.metricEnvelopeContext())
		require.NoError(t, err)
		require.Equal(t, maxPendingEdgeMetrics*len(perSample.GetMetrics()), spooled)
	})
	t.Run("icmp", func(t *testing.T) {
		sp := openTestEdgeSpool(t)
		loop, _ := sysmonEdgeLoop(t, sp)
		loop.icmpChecks = map[string]*icmpCheckConfig{"icmp-check-01": {
			ID: "icmp-check-01", Name: "ping", Target: "192.0.2.50", Enabled: true,
			Interval: time.Hour, Timeout: 200 * time.Millisecond,
		}}
		loop.icmpLastRun = map[string]time.Time{}

		require.False(t, loop.pushICMPResults(context.Background()))
		require.Empty(t, spooledMetricBatches(t, sp))
		require.Len(t, queuedItemsOf(&loop.icmpEdge), 1, "the check result waits in the queue")
		require.Equal(t, uint64(1), loop.server.edgeProducerDrops.grantHolds[edgeProducerICMP].Load())

		loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())
		require.True(t, loop.pushICMPResults(context.Background()))
		require.Empty(t, loop.icmpEdge.pending)
		require.Len(t, spooledMetricBatches(t, sp), 1)
	})
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
	loop, collector := sysmonEdgeLoop(t, refusingEdgeSpool(t))
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

	collector.queued = syntheticSysmonSamples(maxPendingEdgeMetrics + 5)
	require.False(t, loop.pushSysmonMetrics())

	require.Len(t, loop.sysmonEdge.pending, maxPendingEdgeMetrics)
	var metrics strings.Builder
	require.NoError(t, loop.server.edgeProducerDrops.write(&metrics))
	require.Contains(t, metrics.String(), `agent_edge_record_dropped_samples_total{producer="sysmon",reason="retry_buffer_full"} 5`)

	// Once the spool admits again, the retained samples are spooled first.
	roomy := openTestEdgeSpool(t)
	loop.SetEdgeMetricsSpool(roomy)
	require.True(t, loop.pushSysmonMetrics())
	require.Empty(t, loop.sysmonEdge.pending)
	spooled := 0
	for _, batch := range spooledMetricBatches(t, roomy) {
		spooled += len(batch.GetMetrics())
	}
	perSample, err := buildSysmonMetricBatch(syntheticSysmonSamples(1), loop.metricEnvelopeContext())
	require.NoError(t, err)
	require.Equal(t, maxPendingEdgeMetrics*len(perSample.GetMetrics()), spooled)
}

func TestSysmonPrefixOverCanonicalRecordLimitIsShortened(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, collector := sysmonEdgeLoop(t, sp)
	now := time.Now()
	grant := currentMetricsGrant(t)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{grant}, now)

	first, second := sysmonSamplesAtCanonicalBoundary(t, grant, loop.metricEnvelopeContext())
	original, err := buildSysmonMetricBatch([]*sysmon.MetricSample{first, second}, loop.metricEnvelopeContext())
	require.NoError(t, err)
	collector.queued = []*sysmon.MetricSample{first, second}

	require.True(t, loop.pushSysmonMetrics())

	require.Empty(t, loop.sysmonEdge.pending)
	require.Zero(t, edgeDrops(loop, edgeProducerSysmon, edgeDropInvalidRecord))
	batches := spooledMetricBatches(t, sp)
	require.Greater(t, len(batches), 1, "the combined record does not fit, so the prefix is shortened")
	require.Equal(t, flattenedMetricPoints([]*metricpb.MetricBatch{original}), flattenedMetricPoints(batches))
	assertMetricsRecordsWithinCaps(t, sp, batches, 10_000)
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
	inner        *spool.Spool
	refuseAfter  int
	permanentOn  int
	ids          [][]byte
	bodies       [][]byte
	permanentErr error
}

func (a *appendScript) AppendFlow(flow string, eventID, body []byte) (uint64, error) {
	n := len(a.ids) + 1
	a.ids = append(a.ids, bytes.Clone(eventID))
	a.bodies = append(a.bodies, bytes.Clone(body))
	if a.permanentOn == n {
		if a.permanentErr != nil {
			return 0, a.permanentErr
		}
		return 0, spool.ErrPermanent
	}
	if a.refuseAfter >= 0 && n > a.refuseAfter {
		return 0, spool.ErrAdmissionRefused
	}
	return a.inner.AppendFlow(flow, eventID, body)
}

// admitAll starts a new phase in which every append is admitted.
func (a *appendScript) admitAll() {
	a.refuseAfter = -1
	a.permanentOn = 0
	a.ids = nil
	a.bodies = nil
}

func TestSysmonSplitRemainderIsHeldWithoutAGrant(t *testing.T) {
	inner := openTestEdgeSpool(t)
	script := &appendScript{inner: inner, refuseAfter: 1}
	loop, collector := sysmonEdgeLoop(t, nil)
	loop.edgeMetricsSpool = script
	now := time.Now()
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, now)

	sample, original := sysmonSampleOverPayloadCap(t, loop.metricEnvelopeContext())
	collector.queued = []*sysmon.MetricSample{sample}
	require.True(t, loop.pushSysmonMetrics())
	require.GreaterOrEqual(t, len(script.ids), 2)
	queued := len(loop.sysmonEdge.pending)
	require.Positive(t, queued)
	stored := len(spooledMetricBatches(t, inner))

	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, nil, now)
	require.False(t, loop.pushSysmonMetrics())

	require.Len(t, loop.sysmonEdge.pending, queued)
	require.Len(t, spooledMetricBatches(t, inner), stored)

	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, now)
	script.admitAll()
	require.True(t, loop.pushSysmonMetrics())
	require.Empty(t, loop.sysmonEdge.pending)
	require.Equal(t, flattenedMetricPoints([]*metricpb.MetricBatch{original}), flattenedMetricPoints(spooledMetricBatches(t, inner)))
}

func TestSysmonUnsplittablePointIsCountedOnceAcrossRetries(t *testing.T) {
	inner := openTestEdgeSpool(t)
	script := &appendScript{inner: inner, refuseAfter: 0}
	loop, collector := sysmonEdgeLoop(t, nil)
	loop.edgeMetricsSpool = script
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

	sample, original := sysmonSampleWithUnsplittablePoint(t, loop.metricEnvelopeContext())
	collector.queued = []*sysmon.MetricSample{sample}
	require.False(t, loop.pushSysmonMetrics())
	drops := edgeDrops(loop, edgeProducerSysmon, edgeDropInvalidRecord)
	require.Equal(t, uint64(1), drops)
	require.Empty(t, spooledMetricBatches(t, inner))

	require.False(t, loop.pushSysmonMetrics())
	require.Equal(t, drops, edgeDrops(loop, edgeProducerSysmon, edgeDropInvalidRecord), "a retry does not count the unsplittable point again")

	script.admitAll()
	require.True(t, loop.pushSysmonMetrics())
	require.Equal(t, drops, edgeDrops(loop, edgeProducerSysmon, edgeDropInvalidRecord))
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

func assertMetricsRecordsWithinCaps(t *testing.T, sp *spool.Spool, batches []*metricpb.MetricBatch, maxRows int) {
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

func syntheticSNMPResults(n int) []snmpMetricResult {
	results := make([]snmpMetricResult, n)
	for i := range results {
		results[i] = snmpMetricResult{
			Target: "router01.example.com", Host: "192.0.2.20", Metric: "ifHCInOctets",
			OID: "1.3.6.1.2.1.31.1.1.1.6", OIDIndex: strconv.Itoa(i + 1), Value: uint64(1000 + i),
			Timestamp: time.Now(), DataType: "counter", Scale: 1, Delta: true, InterfaceUID: "if-" + strconv.Itoa(i+1),
		}
	}
	return results
}

func syntheticICMPResults(n int) []icmpCheckResult {
	results := make([]icmpCheckResult, n)
	for i := range results {
		results[i] = icmpCheckResult{
			CheckID: "check-" + strconv.Itoa(i), CheckName: "ping", Target: "192.0.2." + strconv.Itoa(30+i),
			Available: true, ResponseTimeNs: int64(1_500_000 + i), Timestamp: time.Now().UnixNano(),
		}
	}
	return results
}

// withoutEmitTime clears the envelope's emission time, the one value two builds of
// the same items differ in, including on points stamped with it (the sweep
// summary times its summary points by emission).
func withoutEmitTime(batch *metricpb.MetricBatch) *metricpb.MetricBatch {
	clone := gproto.CloneOf(batch)
	emitted := clone.GetEmittedAtUnixNano()
	clone.EmittedAtUnixNano = 0
	for _, metric := range clone.GetMetrics() {
		for _, point := range metric.GetPoints() {
			if point.GetObservedAtUnixNano() == emitted {
				point.ObservedAtUnixNano = 0
			}
		}
	}
	return clone
}

func syntheticMTRResults(n int) []mtrCheckResult {
	results := make([]mtrCheckResult, n)
	for i := range results {
		results[i] = mtrCheckResult{
			CheckID: "mtr-check-" + strconv.Itoa(i), CheckName: "wan-path", Target: "path01.example.com",
			Available: true, Timestamp: time.Now().UnixNano(),
			Trace: &mtr.TraceResult{
				Target: "path01.example.com", TargetIP: "192.0.2.40", TargetReached: true, TotalHops: 1,
				Protocol: "icmp", IPVersion: 4, PacketSize: 64,
				Hops: []mtr.HopSnapshot{{
					HopNumber: 1, Addr: "192.0.2.1", Hostname: "hop01.example.com", Sent: 10, Received: 10,
					LastUs: 1_200 + int64(i), AvgUs: 1_100, MinUs: 1_000, MaxUs: 1_300, StdDevUs: 20,
				}},
			},
		}
	}
	return results
}

// syntheticSweepSummary is one periodic sweep summary payload, as a sweep
// service's GetStatusWithMetricPayload returns it.
func syntheticSweepSummary(sequence int) map[string]any {
	return map[string]any{
		"network": "lan01", "sweep_group_id": "group-01", "total_hosts": 4, "available_hosts": 3,
		"last_sweep": int64(1_780_000_000), "sequence": sequence,
		"ports": []any{map[string]any{"port": 443, "available": 2}},
	}
}

// spoolOnce sends items through a producer's edge path under a current grant and
// returns the batches the spool now holds, which must each be a valid metrics
// batch record.
func spoolOnce[T any](t *testing.T, m edgeMetricsProducer[T], items []T) (*PushLoop, []*metricpb.MetricBatch) {
	t.Helper()
	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())
	capability := loop.edgeMetricsCapability(time.Now())
	require.NotNil(t, capability)
	var queue edgeMetricsQueue[T]
	require.True(t, spoolEdgeMetrics(loop, m, &queue, items, capability))
	require.Empty(t, queue.pending)
	return loop, spooledMetricBatches(t, sp)
}

// Each producer's records carry exactly the envelope its builder makes for the
// same items.
func TestEdgeMetricsRecordsCarryTheProducerEnvelope(t *testing.T) {
	check := func(t *testing.T, batches []*metricpb.MetricBatch, want *metricpb.MetricBatch, source string) {
		t.Helper()
		require.Len(t, batches, 1)
		require.Equal(t, source, batches[0].GetIngestIdentity().GetSource())
		require.True(t, gproto.Equal(withoutEmitTime(want), withoutEmitTime(batches[0])))
	}

	t.Run("sysmon", func(t *testing.T) {
		items := syntheticSysmonSamples(3)
		loop, batches := spoolOnce(t, sysmonEdgeMetrics(), items)
		legacy, err := buildSysmonMetricBatch(items, loop.metricEnvelopeContext())
		require.NoError(t, err)
		check(t, batches, legacy, "sysmon-metrics")
	})
	t.Run("snmp", func(t *testing.T) {
		items := syntheticSNMPResults(4)
		loop, batches := spoolOnce(t, snmpEdgeMetrics(), items)
		legacy, err := buildSNMPMetricBatch(items, loop.metricEnvelopeContext())
		require.NoError(t, err)
		check(t, batches, legacy, "snmp-metrics")
	})
	t.Run("icmp", func(t *testing.T) {
		items := syntheticICMPResults(4)
		loop, batches := spoolOnce(t, icmpEdgeMetrics(), items)
		legacy, err := buildICMPMetricBatch(items, loop.metricEnvelopeContext())
		require.NoError(t, err)
		check(t, batches, legacy, "icmp-metrics")
	})
	t.Run("mtr", func(t *testing.T) {
		items := syntheticMTRResults(3)
		loop, batches := spoolOnce(t, mtrEdgeMetrics(), items)
		legacy, err := buildMTRMetricBatch(items, loop.metricEnvelopeContext())
		require.NoError(t, err)
		check(t, batches, legacy, "mtr-metrics")
	})
	t.Run("sweep summary", func(t *testing.T) {
		item := syntheticSweepSummary(7)
		loop, batches := spoolOnce(t, sweepSummaryEdgeMetrics(), []map[string]any{item})
		legacy, err := buildSweepMetricBatchFromMap(item, loop.metricEnvelopeContext())
		require.NoError(t, err)
		check(t, batches, legacy, "sweep-metrics")
	})
}

// Items whose envelope exceeds one record split across records, each within the
// payload bound, without losing, duplicating or reordering any item.
func TestEdgeMetricsSplitAcrossRecordsWithinThePayloadBound(t *testing.T) {
	items := syntheticSNMPResults(6000)
	loop, batches := spoolOnce(t, snmpEdgeMetrics(), items)
	require.Greater(t, len(batches), 1)

	legacy, err := buildSNMPMetricBatch(items, loop.metricEnvelopeContext())
	require.NoError(t, err)
	var spooled []*metricpb.Metric
	for _, batch := range batches {
		require.LessOrEqual(t, gproto.Size(batch), edgeMetricsMaxPayloadBytes)
		spooled = append(spooled, batch.GetMetrics()...)
	}
	require.Len(t, spooled, len(legacy.GetMetrics()))
	for i := range spooled {
		require.True(t, gproto.Equal(legacy.GetMetrics()[i], spooled[i]), "metric %d", i)
	}
}

// An item the envelope builder records nothing for is skipped, not counted as
// a dropped record.
func TestEdgeMetricsSkipItemsWithNothingToRecord(t *testing.T) {
	items := syntheticSNMPResults(2)
	empty := items[0]
	empty.Value, empty.RawValue = nil, nil
	loop, batches := spoolOnce(t, snmpEdgeMetrics(), []snmpMetricResult{empty, items[1]})

	require.Len(t, batches, 1)
	require.Len(t, batches[0].GetMetrics(), 1)
	var metrics strings.Builder
	require.NoError(t, loop.server.edgeProducerDrops.write(&metrics))
	require.Contains(t, metrics.String(), `agent_edge_record_dropped_samples_total{producer="snmp",reason="invalid_record"} 0`)
}

// scriptedMetricsLoop is a push loop whose metrics spool is script, holding a
// current grant of maxRows rows; it returns that grant's capability.
func scriptedMetricsLoop(t *testing.T, script edgeMetricsAppender, maxRows uint32) (*PushLoop, *edgev1.EdgeSignedCapabilityV1) {
	t.Helper()
	loop, _ := sysmonEdgeLoop(t, nil)
	loop.edgeMetricsSpool = script
	now := time.Now()
	grant := metricsGrantRows(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), maxRows)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{grant}, now)
	capability := loop.edgeMetricsCapability(now)
	require.NotNil(t, capability)
	return loop, capability
}

func edgeDrops(loop *PushLoop, producer edgeProducer, reason edgeDropReason) uint64 {
	return loop.server.edgeProducerDrops.dropped[producer][reason].Load()
}

// One ICMP check result carries three metrics, so a one-row grant splits it.
// The sysmon cases of these behaviours drive the real push loop above.
func icmpItemOverRowCeiling(t *testing.T, loop *PushLoop) ([]icmpCheckResult, *metricpb.MetricBatch) {
	t.Helper()
	items := syntheticICMPResults(1)
	legacy, err := buildICMPMetricBatch(items, loop.metricEnvelopeContext())
	require.NoError(t, err)
	require.Len(t, legacy.GetMetrics(), 3)
	return items, legacy
}

// An SNMP reading whose one point no record can hold is counted once, however
// often the readings queued behind it are retried.
func TestSNMPUnsplittableReadingIsCountedOnceAcrossRetries(t *testing.T) {
	inner := openTestEdgeSpool(t)
	script := &appendScript{inner: inner, refuseAfter: 0}
	loop, capability := scriptedMetricsLoop(t, script, 10_000)
	items := syntheticSNMPResults(2)
	items[0].Value, items[0].RawValue = nil, asciiNoise(edgeMetricsMaxPayloadBytes+4096, 9)

	var queue edgeMetricsQueue[snmpMetricResult]
	require.False(t, spoolEdgeMetrics(loop, snmpEdgeMetrics(), &queue, items, capability))
	require.Equal(t, uint64(1), edgeDrops(loop, edgeProducerSNMP, edgeDropInvalidRecord))
	require.Len(t, queue.pending, 1, "the recordable reading waits for the spool")

	require.False(t, spoolEdgeMetrics(loop, snmpEdgeMetrics(), &queue, nil, capability))
	require.Equal(t, uint64(1), edgeDrops(loop, edgeProducerSNMP, edgeDropInvalidRecord))

	script.admitAll()
	require.True(t, spoolEdgeMetrics(loop, snmpEdgeMetrics(), &queue, nil, capability))
	require.Equal(t, uint64(1), edgeDrops(loop, edgeProducerSNMP, edgeDropInvalidRecord))
	batches := spooledMetricBatches(t, inner)
	require.Len(t, batches, 1)
	require.Len(t, batches[0].GetMetrics(), 1)
}

// splitCase is one producer's item that a record cap forces across records, and
// the push that spools it. The sysmon cases drive the real push loop; the ICMP
// case drives the shared path its push loop calls.
type splitCase struct {
	original *metricpb.MetricBatch
	maxRows  int
	producer edgeProducer
	push     func() bool
	queued   func() int
}

func sysmonSplitCase(
	t *testing.T,
	sp edgeMetricsAppender,
	maxRows uint32,
	sample func(*testing.T, metricEnvelopeContext) (*sysmon.MetricSample, *metricpb.MetricBatch),
) splitCase {
	t.Helper()
	loop, collector := sysmonEdgeLoop(t, nil)
	loop.edgeMetricsSpool = sp
	now := time.Now()
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{metricsGrantRows(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), maxRows)}, now)
	item, original := sample(t, loop.metricEnvelopeContext())
	collector.queued = []*sysmon.MetricSample{item}
	return splitCase{
		original: original, maxRows: int(maxRows), producer: edgeProducerSysmon,
		push:   func() bool { return loop.pushSysmonMetrics() },
		queued: func() int { return len(loop.sysmonEdge.pending) },
	}
}

func icmpSplitCase(t *testing.T, sp edgeMetricsAppender) (splitCase, *PushLoop) {
	t.Helper()
	loop, capability := scriptedMetricsLoop(t, sp, 1)
	items, original := icmpItemOverRowCeiling(t, loop)
	var queue edgeMetricsQueue[icmpCheckResult]
	first := true
	return splitCase{
		original: original, maxRows: 1, producer: edgeProducerICMP,
		push: func() bool {
			drained := items
			if !first {
				drained = nil
			}
			first = false
			return spoolEdgeMetrics(loop, icmpEdgeMetrics(), &queue, drained, capability)
		},
		queued: func() int {
			if len(queue.pending) > 0 {
				require.False(t, queue.pending[0].hasItem, "unsent parts are queued as built records")
			}
			return len(queue.pending)
		},
	}, loop
}

// sysmonSampleOverRowCeiling is one sample whose batch has at least three
// metrics, so a one-row grant splits it.
func sysmonSampleOverRowCeiling(t *testing.T, ctx metricEnvelopeContext) (*sysmon.MetricSample, *metricpb.MetricBatch) {
	t.Helper()
	sample := syntheticSysmonSamples(1)[0]
	original, err := buildSysmonMetricBatch([]*sysmon.MetricSample{sample}, ctx)
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(original.GetMetrics()), 3)
	return sample, original
}

// An item over the payload cap or the grant's row ceiling is split into records
// that each fit, keeping every point in order.
func TestEdgeMetricsItemOverACapIsSplitAcrossRecords(t *testing.T) {
	cases := map[string]func(t *testing.T, sp edgeMetricsAppender) splitCase{
		"sysmon over the payload cap": func(t *testing.T, sp edgeMetricsAppender) splitCase {
			t.Helper()
			return sysmonSplitCase(t, sp, 10_000, sysmonSampleOverPayloadCap)
		},
		"sysmon over the row ceiling": func(t *testing.T, sp edgeMetricsAppender) splitCase {
			t.Helper()
			return sysmonSplitCase(t, sp, 1, sysmonSampleOverRowCeiling)
		},
		"icmp over the row ceiling": func(t *testing.T, sp edgeMetricsAppender) splitCase {
			t.Helper()
			c, _ := icmpSplitCase(t, sp)
			return c
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			inner := openTestEdgeSpool(t)
			c := setup(t, &appendScript{inner: inner, refuseAfter: -1})
			require.True(t, c.push())
			require.Zero(t, c.queued())
			batches := spooledMetricBatches(t, inner)
			require.Greater(t, len(batches), 1)
			require.Equal(t, flattenedMetricPoints([]*metricpb.MetricBatch{c.original}), flattenedMetricPoints(batches))
			assertMetricsRecordsWithinCaps(t, inner, batches, c.maxRows)
		})
	}
}

// A retryable refusal mid-item keeps only the unsent parts, under their event
// ids; the retry appends each of them exactly once.
func TestEdgeMetricsSplitRetryAppendsEachPartOnce(t *testing.T) {
	cases := map[string]func(t *testing.T, sp edgeMetricsAppender) splitCase{
		"sysmon": func(t *testing.T, sp edgeMetricsAppender) splitCase {
			t.Helper()
			return sysmonSplitCase(t, sp, 10_000, sysmonSampleOverPayloadCap)
		},
		"icmp": func(t *testing.T, sp edgeMetricsAppender) splitCase {
			t.Helper()
			c, _ := icmpSplitCase(t, sp)
			return c
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			inner := openTestEdgeSpool(t)
			script := &appendScript{inner: inner, refuseAfter: 1}
			c := setup(t, script)

			require.True(t, c.push())
			require.GreaterOrEqual(t, len(script.ids), 2, "one part admitted, the next refused")
			require.Len(t, spooledMetricBatches(t, inner), 1)
			require.Positive(t, c.queued())
			admitted, refused := bytes.Clone(script.ids[0]), bytes.Clone(script.ids[1])

			script.admitAll()
			require.True(t, c.push())
			require.Equal(t, refused, script.ids[0], "the refused part keeps its event id")
			for _, id := range script.ids {
				require.NotEqual(t, admitted, id, "an admitted part is not appended again")
			}
			require.Zero(t, c.queued())
			batches := spooledMetricBatches(t, inner)
			require.Equal(t, flattenedMetricPoints([]*metricpb.MetricBatch{c.original}), flattenedMetricPoints(batches))
			require.Len(t, uniqueEventIDs(t, inner), len(batches))
		})
	}
}

// A permanent refusal drops only the refused part; later parts are still admitted.
func TestEdgeMetricsSplitPermanentRefusalDropsOnlyThatPart(t *testing.T) {
	cases := map[string]func(t *testing.T, sp edgeMetricsAppender) (splitCase, func() *PushLoop){
		"sysmon": func(t *testing.T, sp edgeMetricsAppender) (splitCase, func() *PushLoop) {
			t.Helper()
			loop, collector := sysmonEdgeLoop(t, nil)
			loop.edgeMetricsSpool = sp
			now := time.Now()
			loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{metricsGrantRows(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1)}, now)
			item, original := sysmonSampleOverRowCeiling(t, loop.metricEnvelopeContext())
			collector.queued = []*sysmon.MetricSample{item}
			return splitCase{
				original: original, maxRows: 1, producer: edgeProducerSysmon,
				push:   func() bool { return loop.pushSysmonMetrics() },
				queued: func() int { return len(loop.sysmonEdge.pending) },
			}, func() *PushLoop { return loop }
		},
		"icmp": func(t *testing.T, sp edgeMetricsAppender) (splitCase, func() *PushLoop) {
			t.Helper()
			c, loop := icmpSplitCase(t, sp)
			return c, func() *PushLoop { return loop }
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			inner := openTestEdgeSpool(t)
			script := &appendScript{inner: inner, refuseAfter: -1, permanentOn: 2}
			c, loop := setup(t, script)

			require.True(t, c.push())
			require.GreaterOrEqual(t, len(script.ids), 3, "parts after the permanent refusal are still admitted")
			require.Zero(t, c.queued())
			require.Equal(t, uint64(1), edgeDrops(loop(), c.producer, edgeDropRefused))
			permanent := flattenedMetricPoints([]*metricpb.MetricBatch{batchFromCanonical(t, script.bodies[1])})
			want, ok := spliceOut(flattenedMetricPoints([]*metricpb.MetricBatch{c.original}), permanent)
			require.True(t, ok, "the refused part is a contiguous slice of the original points")
			require.Equal(t, want, flattenedMetricPoints(spooledMetricBatches(t, inner)))
		})
	}
}

// queuedItemsOf is the items of a queue's item entries, oldest first.
func queuedItemsOf[T any](q *edgeMetricsQueue[T]) []T {
	var items []T
	for _, entry := range q.pending {
		if entry.hasItem {
			items = append(items, entry.item)
		}
	}
	return items
}

// Invalid UTF-8 in a value is replaced by the envelope builder, so the item is
// spooled with its neighbours instead of failing the record.
func TestInvalidUTF8IsSpooledWithItsNeighbours(t *testing.T) {
	t.Run("sysmon process name", func(t *testing.T) {
		sp := openTestEdgeSpool(t)
		loop, collector := sysmonEdgeLoop(t, sp)
		loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())
		neighbor, bad := syntheticSysmonSamples(1)[0], syntheticSysmonSamples(1)[0]
		const pid = 7
		bad.Processes = []sysmon.ProcessMetric{{
			PID: pid, Name: "\xff\xfe", CPUUsage: 1.5, MemoryUsage: 4096, Status: "running", StartTime: "2026-11-01T00:00:00Z",
		}}
		collector.queued = []*sysmon.MetricSample{neighbor, bad}

		require.True(t, loop.pushSysmonMetrics())

		require.Empty(t, loop.sysmonEdge.pending)
		require.Zero(t, edgeDrops(loop, edgeProducerSysmon, edgeDropInvalidRecord))
		batches := spooledMetricBatches(t, sp)
		keys := flattenedMetricPoints(batches)
		require.Equal(t, 4, namedPointCount(keys, "cpu.usage_percent"), "the valid sample and the process sample both spool")
		replaced := strings.ToValidUTF8("\xff\xfe", "\uFFFD")
		require.Equal(t, []string{replaced, replaced}, pointAttributeValues(batches, "name"))
		require.Contains(t, keys, "process.cpu_usage\tprocess:"+fmt.Sprint(pid)+":"+replaced+"\t1.5")

		direct, err := buildSysmonMetricBatch([]*sysmon.MetricSample{bad}, loop.metricEnvelopeContext())
		require.NoError(t, err)
		require.Equal(t, []string{replaced, replaced}, pointAttributeValues([]*metricpb.MetricBatch{direct}, "name"))
	})
	t.Run("snmp target", func(t *testing.T) {
		items := syntheticSNMPResults(2)
		items[1].Target = "router\xff01.example.com"
		loop, batches := spoolOnce(t, snmpEdgeMetrics(), items)
		require.Zero(t, edgeDrops(loop, edgeProducerSNMP, edgeDropInvalidRecord))
		require.Len(t, batches, 1)
		require.Len(t, batches[0].GetMetrics(), 2, "the reading with invalid UTF-8 spools with its neighbour")
		replaced := strings.ToValidUTF8(items[1].Target, "\uFFFD")
		require.Contains(t, pointAttributeValues(batches, "target"), replaced)

		direct, err := buildSNMPMetricBatch(items, loop.metricEnvelopeContext())
		require.NoError(t, err)
		require.Contains(t, pointAttributeValues([]*metricpb.MetricBatch{direct}, "target"), replaced)
	})
}

// A metric whose batch cannot form a record for a reason other than size is
// dropped alone; its neighbours still form records.
func TestPackerKeepsNeighboursOfAnUnencodableMetric(t *testing.T) {
	grant := currentMetricsGrant(t)
	capability := &edgev1.EdgeSignedCapabilityV1{}
	require.NoError(t, gproto.Unmarshal(grant.GetProductionCapability(), capability))
	maxRows := min(uint64(capability.GetProduction().GetMaxProjectedRowCount()),
		capability.GetProduction().GetMaxProjectedWriteBytes()/edgeMetricsProjectedRowBytes)

	batch := &metricpb.MetricBatch{
		SchemaVersion: metricEnvelopeSchemaVersion,
		Resource: metricResource(
			sysmonEdgeAgentID, "gw", "default", "sysmon", "sysmon", "host", "192.0.2.10", "kv",
		),
		IngestIdentity: metricIngest(
			"sysmon-metrics", "agent-sysmon", sysmonEdgeAgentID, "gw",
		),
		Metrics: []*metricpb.Metric{
			onePointMetric("cpu.usage_percent", "11"),
			onePointMetric("\xff", "99"),
			onePointMetric("memory.used_percent", "22"),
		},
	}
	built, dropped := splitMetricBatch(batch, capability, maxRows)
	require.Equal(t, 1, dropped)
	require.Equal(t, []string{
		"cpu.usage_percent\t\t11",
		"memory.used_percent\t\t22",
	}, flattenedMetricPoints(builtPayloads(t, built)))
}

func namedPointCount(keys []string, name string) int {
	n := 0
	prefix := name + "\t"
	for _, key := range keys {
		if key == name || strings.HasPrefix(key, prefix) {
			n++
		}
	}
	return n
}

func pointAttributeValues(batches []*metricpb.MetricBatch, key string) []string {
	var values []string
	for _, batch := range batches {
		for _, metric := range batch.GetMetrics() {
			for _, point := range metric.GetPoints() {
				for _, attr := range point.GetAttributes() {
					if attr.GetKey() == key {
						values = append(values, attr.GetValue())
					}
				}
			}
		}
	}
	return values
}

func onePointMetric(name, raw string) *metricpb.Metric {
	return &metricpb.Metric{
		Name:       name,
		MetricType: "sysmon.cpu",
		Unit:       "%",
		Points: []*metricpb.MetricPoint{{
			Value:              1,
			RawValue:           raw,
			RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_DOUBLE,
			ObservedAtUnixNano: 1,
		}},
	}
}

func builtPayloads(t *testing.T, built []edgeMetricsBuilt) []*metricpb.MetricBatch {
	t.Helper()
	batches := make([]*metricpb.MetricBatch, 0, len(built))
	for _, piece := range built {
		batch := &metricpb.MetricBatch{}
		require.NoError(t, gproto.Unmarshal(piece.payload, batch))
		batches = append(batches, batch)
	}
	return batches
}

// fakeSweepSummaryService is a sweep status service whose metric payload is the
// periodic sweep summary sample.
type fakeSweepSummaryService struct {
	payload map[string]any
}

func (f *fakeSweepSummaryService) Start(context.Context) error       { return nil }
func (f *fakeSweepSummaryService) Stop(context.Context) error        { return nil }
func (f *fakeSweepSummaryService) Name() string                      { return networkSweepServiceName }
func (f *fakeSweepSummaryService) UpdateConfig(*models.Config) error { return nil }
func (f *fakeSweepSummaryService) GetStatus(context.Context) (*proto.StatusResponse, error) {
	return &proto.StatusResponse{Available: true, Message: []byte(`{"status":"ok"}`)}, nil
}

func (f *fakeSweepSummaryService) GetStatusWithMetricPayload(ctx context.Context) (*proto.StatusResponse, map[string]any, error) {
	status, err := f.GetStatus(ctx)
	return status, f.payload, err
}

func sweepMetricStatuses(statuses []*proto.GatewayServiceStatus) int {
	count := 0
	for _, status := range statuses {
		if status.GetSource() == "sweep-metrics" {
			count++
		}
	}
	return count
}

// The periodic sweep summary never rides the status push: it is spooled while
// the agent holds a metrics grant and held in its queue otherwise.
func TestSweepSummaryTakesOnePath(t *testing.T) {
	for name, granted := range map[string]bool{"with a grant": true, "without a grant": false} {
		t.Run(name, func(t *testing.T) {
			sp := openTestEdgeSpool(t)
			loop, _ := sysmonEdgeLoop(t, sp)
			loop.server.services = []Service{&fakeSweepSummaryService{payload: syntheticSweepSummary(1)}}
			if granted {
				loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())
			}

			statuses := loop.collectAllStatuses(context.Background())

			batches := spooledMetricBatches(t, sp)
			if granted {
				require.Zero(t, sweepMetricStatuses(statuses), "no sweep summary status while the agent holds a grant")
				require.Len(t, batches, 1)
				require.Equal(t, "sweep-metrics", batches[0].GetIngestIdentity().GetSource())
				return
			}
			require.Zero(t, sweepMetricStatuses(statuses), "no sweep summary status without a grant")
			require.Empty(t, batches)
			require.Len(t, queuedItemsOf(&loop.sweepSummary), 1, "the sample waits for the grant")
		})
	}
}

// Sweep summary samples each make their own envelope, so samples drained together
// are spooled one record each, never packed into one.
func TestSweepSummariesAreNeverPacked(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, capability := scriptedMetricsLoop(t, sp, 10_000)
	samples := []map[string]any{syntheticSweepSummary(1), syntheticSweepSummary(2)}

	var queue edgeMetricsQueue[map[string]any]
	require.True(t, spoolEdgeMetrics(loop, sweepSummaryEdgeMetrics(), &queue, samples, capability))

	require.Empty(t, queue.pending)
	batches := spooledMetricBatches(t, sp)
	require.Len(t, batches, 2)
	for i, batch := range batches {
		legacy, err := buildSweepMetricBatchFromMap(samples[i], loop.metricEnvelopeContext())
		require.NoError(t, err)
		require.True(t, gproto.Equal(withoutEmitTime(legacy), withoutEmitTime(batch)), "sample %d", i)
	}
}

// Every record a producer emits under one capability competes in one spool
// admission flow, and records under a different run or contract compete in
// their own, so the spool shares its room per producer run rather than per
// record.
func TestEdgeAdmissionFlowFollowsTheSignedProducerRun(t *testing.T) {
	record := func(edit func(*edgev1.EdgeProductionClaimsV1)) *edgev1.EdgeRecordV1 {
		t.Helper()
		capability := &edgev1.EdgeSignedCapabilityV1{}
		require.NoError(t, gproto.Unmarshal(currentMetricsGrant(t).GetProductionCapability(), capability))
		if edit != nil {
			edit(capability.GetProduction())
		}
		built, err := newEdgeRecord(capability, nil, []byte("synthetic payload"), 1, edgeMetricsProjectedRowBytes)
		require.NoError(t, err)
		return built
	}
	run := edgeAdmissionFlow(record(nil))
	require.Equal(t, run, edgeAdmissionFlow(record(nil)), "two records of one run")
	for name, edit := range map[string]func(*edgev1.EdgeProductionClaimsV1){
		"another run":        func(c *edgev1.EdgeProductionClaimsV1) { c.RunId = []byte("synthetic-run-02") },
		"another run shard":  func(c *edgev1.EdgeProductionClaimsV1) { c.RunShard = 1 },
		"another contract":   func(c *edgev1.EdgeProductionClaimsV1) { c.ContractId = edgerecord.UnleasedSweepResultsContractID },
		"another assignment": func(c *edgev1.EdgeProductionClaimsV1) { c.ProducerAssignmentId = []byte("synthetic-asgn-02") },
	} {
		require.NotEqual(t, run, edgeAdmissionFlow(record(edit)), name)
	}
}

type fakeRperfMetricsService struct {
	queued []*proto.StatusResponse
	polls  int
}

func (f *fakeRperfMetricsService) Start(context.Context) error       { return nil }
func (f *fakeRperfMetricsService) Stop(context.Context) error        { return nil }
func (f *fakeRperfMetricsService) Name() string                      { return "rperf" }
func (f *fakeRperfMetricsService) UpdateConfig(*models.Config) error { return nil }
func (f *fakeRperfMetricsService) GetStatus(context.Context) (*proto.StatusResponse, error) {
	f.polls++
	if len(f.queued) == 0 {
		return nil, nil
	}
	next := f.queued[0]
	f.queued = f.queued[1:]
	return next, nil
}

func syntheticRperfStatus(t *testing.T, metricsCount int) *proto.StatusResponse {
	t.Helper()
	observedAt := uint64(time.Now().UnixNano())
	metrics := make([]*metricpb.Metric, metricsCount)
	for i := range metrics {
		metrics[i] = &metricpb.Metric{
			Name:       fmt.Sprintf("rperf.bits_per_second.%d", i),
			MetricType: "rperf",
			Kind:       metricpb.MetricKind_METRIC_KIND_GAUGE,
			Unit:       "bit/s",
			Points: []*metricpb.MetricPoint{{
				Value:              float64(1_000_000 + i),
				RawValue:           strconv.Itoa(1_000_000 + i),
				RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_INT64,
				ObservedAtUnixNano: observedAt,
				Attributes: []*metricpb.StringMapEntry{
					{Key: "target", Value: "192.0.2.50"},
				},
			}},
		}
	}
	payload, err := gproto.Marshal(&metricpb.MetricBatch{
		SchemaVersion: metricEnvelopeSchemaVersion,
		Metrics:       metrics,
	})
	require.NoError(t, err)
	return &proto.StatusResponse{
		Available:   true,
		Message:     payload,
		ServiceName: "rperf",
		ServiceType: "rperf",
	}
}

func rperfMetricStatuses(statuses []*proto.GatewayServiceStatus) int {
	count := 0
	for _, status := range statuses {
		if status.GetSource() == "rperf-metrics" {
			count++
		}
	}
	return count
}

func TestRperfMetricsWithAGrantGoOnlyToTheEdgeSpool(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)
	svc := &fakeRperfMetricsService{queued: []*proto.StatusResponse{syntheticRperfStatus(t, 2)}}
	loop.server.services = []Service{svc}
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

	statuses := loop.collectAllStatuses(context.Background())

	batches := spooledMetricBatches(t, sp)
	require.Zero(t, rperfMetricStatuses(statuses), "no rperf-metrics status")
	require.Len(t, batches, 1)
	require.Equal(t, "rperf-metrics", batches[0].GetIngestIdentity().GetSource())
	require.Equal(t, "rperf-checker", batches[0].GetIngestIdentity().GetProducerKind())
	require.Equal(t, sysmonEdgeAgentID, batches[0].GetResource().GetAgentId())
	require.Equal(t, "rperf", batches[0].GetResource().GetServiceName())
	require.Equal(t, "rperf", batches[0].GetResource().GetServiceType())
	require.Len(t, batches[0].GetMetrics(), 2)
}

// Without a metrics grant one polled rperf status is held unbuilt and the rperf
// service is not polled again; once the grant is held the status is built,
// spooled, and polling resumes.
func TestRperfMetricsWithoutAGrantHoldOneStatusAndPausePolling(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)
	svc := &fakeRperfMetricsService{queued: []*proto.StatusResponse{syntheticRperfStatus(t, 2), syntheticRperfStatus(t, 1)}}
	loop.server.services = []Service{svc}

	statuses := loop.collectAllStatuses(context.Background())
	require.Zero(t, rperfMetricStatuses(statuses), "rperf metrics never ride the status push")
	require.Empty(t, spooledMetricBatches(t, sp))
	require.True(t, loop.rperfEdge.hasPending())
	require.Equal(t, 1, svc.polls)

	loop.collectAllStatuses(context.Background())
	require.Equal(t, 1, svc.polls, "rperf polling is paused while a status is held")
	require.Positive(t, loop.server.edgeProducerDrops.grantHolds[edgeProducerRperf].Load())

	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())
	loop.collectAllStatuses(context.Background())
	require.False(t, loop.rperfEdge.hasPending())
	require.Equal(t, 2, svc.polls, "polling resumes once the held status is spooled")
	batches := spooledMetricBatches(t, sp)
	require.Len(t, batches, 2)
	require.Len(t, batches[0].GetMetrics(), 2, "the held status is spooled first")
	require.Len(t, batches[1].GetMetrics(), 1)
}

func TestRperfEdgeSpoolBackpressurePausesPollingAndPreservesEventID(t *testing.T) {
	inner := openTestEdgeSpool(t)
	script := &appendScript{inner: inner, refuseAfter: 0}
	loop, _ := sysmonEdgeLoop(t, nil)
	loop.edgeMetricsSpool = script
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

	svc := &fakeRperfMetricsService{
		queued: []*proto.StatusResponse{
			syntheticRperfStatus(t, 1),
			syntheticRperfStatus(t, 2),
		},
	}
	loop.server.services = []Service{svc}

	// First push polls the first rperf status, builds its edge record, and holds
	// it in rperfEdge when the spool refuses admission.
	statuses := loop.collectAllStatuses(context.Background())
	require.Zero(t, rperfMetricStatuses(statuses))
	require.Equal(t, 1, svc.polls)
	require.Len(t, svc.queued, 1, "second status remains in the service until the first is admitted")
	require.True(t, loop.rperfEdge.hasPending())
	require.Len(t, script.ids, 1)
	firstEventID := bytes.Clone(script.ids[0])
	require.Empty(t, spooledMetricBatches(t, inner))

	// Second push while the spool still refuses retries the held record with its
	// original event_id and does not poll the rperf service again.
	statuses = loop.collectAllStatuses(context.Background())
	require.Zero(t, rperfMetricStatuses(statuses))
	require.Equal(t, 1, svc.polls, "rperf polling is paused while rperfEdge holds an undelivered item")
	require.Len(t, svc.queued, 1)
	require.True(t, loop.rperfEdge.hasPending())
	require.Len(t, script.ids, 2)
	require.Equal(t, firstEventID, script.ids[1])
	require.Zero(t, edgeDrops(loop, edgeProducerRperf, edgeDropRetryBufferFull))
	require.Zero(t, edgeDrops(loop, edgeProducerRperf, edgeDropInvalidRecord))

	// Once the spool admits, the retained record is written with its original
	// event_id and polling resumes for the next queued status.
	script.admitAll()
	statuses = loop.collectAllStatuses(context.Background())
	require.Zero(t, rperfMetricStatuses(statuses))
	require.False(t, loop.rperfEdge.hasPending())
	require.Equal(t, 2, svc.polls)
	require.Empty(t, svc.queued)
	require.Len(t, script.ids, 2)
	require.Equal(t, firstEventID, script.ids[0], "retained record keeps its original event_id")

	batches := spooledMetricBatches(t, inner)
	require.Len(t, batches, 2)
	require.Len(t, batches[0].GetMetrics(), 1)
	require.Len(t, batches[1].GetMetrics(), 2)
}

func TestRperfSplitAndDropInvalidPoint(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)
	now := time.Now()
	grant := metricsGrantRows(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), 2)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{grant}, now)

	status := syntheticRperfStatus(t, 3)
	var batch metricpb.MetricBatch
	require.NoError(t, gproto.Unmarshal(status.GetMessage(), &batch))
	batch.Metrics = append(batch.Metrics, &metricpb.Metric{
		Name:       "rperf.oversized",
		MetricType: "rperf",
		Kind:       metricpb.MetricKind_METRIC_KIND_GAUGE,
		Points: []*metricpb.MetricPoint{{
			Value:              1,
			RawValue:           asciiNoise(edgeMetricsMaxPayloadBytes+1024, 3),
			RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_STRING,
			ObservedAtUnixNano: uint64(now.UnixNano()),
		}},
	})
	encoded, err := gproto.Marshal(&batch)
	require.NoError(t, err)
	status.Message = encoded

	loop.server.services = []Service{&fakeRperfMetricsService{queued: []*proto.StatusResponse{status}}}

	statuses := loop.collectAllStatuses(context.Background())
	require.Zero(t, rperfMetricStatuses(statuses))
	require.Equal(t, uint64(1), edgeDrops(loop, edgeProducerRperf, edgeDropInvalidRecord))
	batches := spooledMetricBatches(t, sp)
	require.Len(t, batches, 2, "three valid metrics split across two maxRows=2 records")
	assertMetricsRecordsWithinCaps(t, sp, batches, 2)
}

// A target whose poll failed has no readings to spool; its availability point is
// spooled as a metrics record, value 0, carrying the target's identity and the
// poll's error whole.
func TestSNMPFailedPollSpoolsAvailabilityPointWithItsError(t *testing.T) {
	pollErr := "snmp get failed - request timeout (after 3 retries) " + strings.Repeat("x", 3000)
	observedAt := time.Date(2026, 6, 13, 18, 20, 0, 0, time.UTC)

	statuses := map[string]snmpchecker.TargetStatus{
		"switch01": {HostIP: "192.0.2.10", HostName: "switch01.example.com", Target: &snmpchecker.Target{}},
	}
	metrics := map[string][]snmpchecker.DataPoint{
		"switch01|" + snmpchecker.TargetAvailableMetric: {{
			OIDName: snmpchecker.TargetAvailableMetric, Value: 0.0, RawValue: false, Timestamp: observedAt,
			DataType: snmpchecker.TypeBoolean, Scale: 1, Kind: "gauge", Error: pollErr,
		}},
	}

	results := (&PushLoop{}).buildSNMPDrainedResults(statuses, metrics, "")
	_, batches := spoolOnce(t, snmpEdgeMetrics(), results)
	require.Len(t, batches, 1)
	require.Len(t, batches[0].GetMetrics(), 1)

	metric := batches[0].GetMetrics()[0]
	require.Equal(t, "snmp_target_available", metric.GetName())
	require.Len(t, metric.GetPoints(), 1)

	point := metric.GetPoints()[0]
	require.InDelta(t, 0.0, point.GetValue(), 0)
	require.Equal(t, "false", point.GetRawValue())
	require.Equal(t, uint64(observedAt.UnixNano()), point.GetObservedAtUnixNano())

	attributes := map[string]string{}
	for _, entry := range point.GetAttributes() {
		attributes[entry.GetKey()] = entry.GetValue()
	}
	require.Equal(t, map[string]string{"target": "switch01", "host": "192.0.2.10"}, attributes)

	metadata := map[string]string{}
	for _, entry := range point.GetMetadata() {
		metadata[entry.GetKey()] = entry.GetValue()
	}
	require.Equal(t, pollErr, metadata["error"])
	require.Equal(t, "switch01.example.com", metadata["host_name"])
}
