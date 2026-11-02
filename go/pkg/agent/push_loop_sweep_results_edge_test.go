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
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Synthetic sweep group ids: one the agent runs from its own config, one core
// leases slots for.
const (
	unleasedTestGroupID = "00000000-0000-4000-8000-0000000000a1"
	leasedTestGroupID   = "00000000-0000-4000-8000-0000000000b2"
)

// unleasedSweepGrant is a standing unleased sweep results grant for the loop's
// agent, current now and admitting maxRows hosts per record.
func unleasedSweepGrant(t *testing.T, maxRows uint32) *proto.EdgeOutputGrant {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	digest := sha256.Sum256([]byte("synthetic-unleased-sweep-contract"))
	now := time.Now()
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("test-issuer"),
		IssuerKeyId:       []byte("test-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: now.Add(-time.Hour).UnixNano(),
		ExpiresAtUnixNano: now.Add(8 * 24 * time.Hour).UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId: edgerecord.UnleasedSweepResultsContractID, ContractVersion: edgerecord.UnleasedSweepResultsContractVersion,
			ContractBundleSha256: digest[:], RegistryEpoch: 1, RegistrySnapshotSha256: digest[:], EffectiveGrantSha256: digest[:],
			NetworkScopeId: testNetworkScopeID[:], ProducerAssignmentId: testAssignmentID[:], RunId: testAssignmentID[:],
			AuthorityEpoch: 1, ScopeId: testAssignmentID[:], ScopeSha256: digest[:],
			OriginKind: edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT, OriginPrincipalId: []byte(sysmonEdgeAgentID), ProducerInstanceId: []byte(sysmonEdgeAgentID),
			RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:    "serviceradar.agent.sweep_results", PackageSha256: digest[:], CostModelVersion: 1,
			MaxProjectedRowCount: maxRows, MaxProjectedWriteBytes: uint64(maxRows) * unleasedSweepProjectedRowBytes,
		}},
	}
	edgerecord.SignCapability(capability, key)
	encoded, err := gproto.Marshal(capability)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{
		ContractId:           edgerecord.UnleasedSweepResultsContractID,
		ContractVersion:      edgerecord.UnleasedSweepResultsContractVersion,
		ProductionCapability: encoded,
	}
}

// scriptedSweepResults serves queued results responses the way the sweep service
// does: the head response is returned again until it is acknowledged.
type scriptedSweepResults struct {
	mu        sync.Mutex
	responses []*proto.ResultsResponse
	leased    map[string]bool
	acks      []string
	reads     int
}

func (*scriptedSweepResults) Start(context.Context) error       { return nil }
func (*scriptedSweepResults) Stop(context.Context) error        { return nil }
func (*scriptedSweepResults) Name() string                      { return "sweep" }
func (*scriptedSweepResults) UpdateConfig(*models.Config) error { return nil }
func (*scriptedSweepResults) GetConfigHash() string             { return "" }

func (s *scriptedSweepResults) GetSweepResults(context.Context, string) (*proto.ResultsResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.reads++
	if len(s.responses) == 0 {
		return &proto.ResultsResponse{ServiceName: networkSweepServiceName, ServiceType: sweepType}, nil
	}
	return s.responses[0], nil
}

func (s *scriptedSweepResults) AcknowledgeSweepResults(groupID, sequence string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.acks = append(s.acks, groupID+"/"+sequence)
	if len(s.responses) > 0 && s.responses[0].SweepGroupId == groupID && s.responses[0].CurrentSequence == sequence {
		s.responses = s.responses[1:]
	}
}

func (s *scriptedSweepResults) GroupLeaseDriven(groupID string) bool { return s.leased[groupID] }

func (s *scriptedSweepResults) acked() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.acks...)
}

// sweepResultsResponse is a results response carrying hosts as the sweep service
// encodes them.
func sweepResultsResponse(t *testing.T, groupID, sequence string, hosts []models.HostResult, extra map[string]any) *proto.ResultsResponse {
	t.Helper()
	available := 0
	for i := range hosts {
		if hosts[i].Available {
			available++
		}
	}
	doc := map[string]any{
		"network": "192.0.2.0/24", "total_hosts": len(hosts), "available_hosts": available,
		"last_sweep": int64(1_780_000_000), "ports": []models.PortCount{{Port: 22, Available: available}},
		"hosts": hosts, "execution_id": uuid.NewSHA1(uuid.NameSpaceOID, []byte(groupID+sequence)).String(),
		"sweep_group_id": groupID,
	}
	for k, v := range extra {
		doc[k] = v
	}
	data, err := json.Marshal(doc)
	require.NoError(t, err)
	return &proto.ResultsResponse{
		HasNewData: true, CurrentSequence: sequence, Data: data, SweepGroupId: groupID,
		ServiceName: networkSweepServiceName, ServiceType: sweepType, Timestamp: 1_780_000_000,
	}
}

// reachableHost is a synthetic host ICMP reached with SSH open and HTTPS closed.
func reachableHost(addr string) models.HostResult {
	seen := time.Unix(1_780_000_000, 0)
	return models.HostResult{
		Host: addr, Available: true, FirstSeen: seen.Add(-time.Hour), LastSeen: seen.Add(-2 * time.Second),
		ICMPStatus:   &models.ICMPStatus{Available: true, RoundTrip: 1500*time.Microsecond + 3},
		ResponseTime: 1500 * time.Microsecond,
		PortResults: []*models.PortResult{
			{Port: 443, Available: false, RespTime: 900*time.Microsecond + 7},
			{Port: 22, Available: true, RespTime: 2 * time.Millisecond, Service: "ssh"},
		},
		SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
	}
}

// unleasedSweepLoop is a push loop with sp as its edge spool, svc as its sweep
// results provider, and the given standing grants.
func unleasedSweepLoop(t *testing.T, sp *spool.Spool, svc *scriptedSweepResults, grants ...*proto.EdgeOutputGrant) (*PushLoop, *sysmonStatusGateway) {
	t.Helper()
	loop, gw, _ := sysmonEdgeLoop(t, sp)
	loop.server.services = []Service{svc}
	require.Empty(t, loop.edgeOutputGrants.replace(sysmonEdgeAgentID, grants, time.Now()))
	return loop, gw
}

// spooledUnleasedSweep decodes the spool's unleased results records, each of
// which must pass the contract validator, and counts its metrics batch records.
func spooledUnleasedSweep(t *testing.T, sp *spool.Spool) ([]*edgev1.EdgeRecordV1, []*edgev1.UnleasedSweepResultsBatchV1, int) {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	var records []*edgev1.EdgeRecordV1
	var batches []*edgev1.UnleasedSweepResultsBatchV1
	metrics := 0
	for _, s := range stored {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, gproto.Unmarshal(s.Body, record))
		if record.GetOutputContract().GetContractId() == edgerecord.MetricsBatchContractID {
			require.NoError(t, edgerecord.ValidateMetricBatchRecord(record))
			metrics++
			continue
		}
		require.NoError(t, edgerecord.ValidateUnleasedSweepResultsRecord(record))
		batch := &edgev1.UnleasedSweepResultsBatchV1{}
		require.NoError(t, gproto.Unmarshal(recordBody(t, record), batch))
		records = append(records, record)
		batches = append(batches, batch)
	}
	return records, batches, metrics
}

// Every field core's sweep results ingest reads from the legacy JSON travels in
// the typed batch, so the projector can rebuild what the legacy path ingested.
func TestUnleasedSweepResultsBatchCarriesTheIngestedFields(t *testing.T) {
	loop, _ := unleasedSweepLoop(t, openTestEdgeSpool(t), &scriptedSweepResults{}, unleasedSweepGrant(t, 10_000))
	capability := loop.edgeOutputGrants.current(edgerecord.UnleasedSweepResultsContractID, time.Now())
	require.NotNil(t, capability)

	// The agent calls this host available although no check it reports reached
	// it; core must keep that verdict rather than recompute one.
	unreached := models.HostResult{
		Host: "192.0.2.11", Available: true, ICMPStatus: &models.ICMPStatus{PacketLoss: 100},
		PortResults: []*models.PortResult{{Port: 22}},
	}
	tcpOnly := models.HostResult{
		Host: "2001:db8::12", Available: true, ResponseTime: 3*time.Millisecond + 7,
		PortResults: []*models.PortResult{{Port: 443, Available: true, RespTime: 3*time.Millisecond + 7}},
		MTRStatus:   &models.MTRStatus{Reached: true, RoundTrip: 4*time.Millisecond + 3, PacketLoss: 12.5, TotalHops: 6},
	}
	response := sweepResultsResponse(t, unleasedTestGroupID, "7",
		[]models.HostResult{reachableHost("192.0.2.10"), unreached, tcpOnly},
		map[string]any{
			"cancelled":     true,
			"scanner_stats": &models.ScannerStats{Protocol: "tcp", PacketsSent: 40, DialsStarted: 6, RxDropRatePercent: 0.5},
			"banner_grab":   &models.BannerGrabStats{CandidatesTotal: 3, MatchesTotal: 2, BannerBytesTotal: 512},
		})

	parts, metricPayloads, err := buildSweepResultsEdgeRecords(response, capability)
	require.NoError(t, err)
	require.Len(t, parts, 1)
	require.Len(t, metricPayloads, 1)
	require.Nil(t, parts[0].payload, "results records feed no add-on metric feed")

	record := parts[0].record
	require.NoError(t, edgerecord.ValidateUnleasedSweepResultsRecord(record))
	require.Nil(t, record.GetSourceAuthorization())
	require.EqualValues(t, 3, record.GetProjectedRowCount())
	require.EqualValues(t, 3*unleasedSweepProjectedRowBytes, record.GetProjectedWriteBytes())

	batch := &edgev1.UnleasedSweepResultsBatchV1{}
	require.NoError(t, gproto.Unmarshal(recordBody(t, record), batch))

	var doc sweepResultsJSON
	require.NoError(t, json.Unmarshal(response.Data, &doc))
	require.Equal(t, uuid.MustParse(doc.ExecutionID), uuid.UUID(batch.GetExecutionId()))
	require.Equal(t, uuid.MustParse(unleasedTestGroupID), uuid.UUID(batch.GetSweepGroupId()))
	require.Equal(t, "192.0.2.0/24", batch.GetNetworkCidr())
	require.EqualValues(t, 3, batch.GetExpectedTotalHosts())
	require.EqualValues(t, 3, batch.GetAvailableHosts())
	require.EqualValues(t, 1_780_000_000*int64(time.Second), batch.GetLastSweepUnixNano())
	require.True(t, batch.GetIsCancelled())
	require.True(t, batch.GetIsFinal())
	require.EqualValues(t, 1, batch.GetTotalChunks())
	require.Len(t, batch.GetPortCounts(), 1)
	require.EqualValues(t, 22, batch.GetPortCounts()[0].GetPort())
	require.EqualValues(t, 3, batch.GetPortCounts()[0].GetAvailable())
	require.Equal(t, "tcp", batch.GetScannerStats().GetProtocol())
	require.EqualValues(t, 40, batch.GetScannerStats().GetPacketsSent())
	require.EqualValues(t, 6, batch.GetScannerStats().GetDialsStarted())
	require.InDelta(t, 0.5, batch.GetScannerStats().GetRxDropRatePercent(), 0)
	require.EqualValues(t, 3, batch.GetBannerGrabSummary().GetCandidatesTotal())
	require.EqualValues(t, 2, batch.GetBannerGrabSummary().GetMatchesTotal())
	require.EqualValues(t, 512, batch.GetBannerGrabSummary().GetBytesReceivedTotal())

	// Checks: ICMP, MTR, then each tested TCP port ascending.
	checks := batch.GetTestedChecks()
	require.Len(t, checks, 4)
	require.Equal(t, edgev1.SweepMode_SWEEP_MODE_ICMP, checks[0].GetMode())
	require.Equal(t, edgev1.SweepMode_SWEEP_MODE_MTR, checks[1].GetMode())
	require.Equal(t, edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, checks[2].GetMode())
	require.EqualValues(t, 22, checks[2].GetPort())
	require.EqualValues(t, 443, checks[3].GetPort())
	port := func(index uint32) uint32 { return checks[index].GetPort() }

	hosts := batch.GetHosts()
	require.Len(t, hosts, 3)
	require.Equal(t, netip.MustParseAddr("192.0.2.10").AsSlice(), hosts[0].GetAddress())
	require.True(t, hosts[0].GetIcmp().GetTargetReached())
	require.EqualValues(t, 1500, hosts[0].GetIcmp().GetRoundTripMicro())
	require.Len(t, hosts[0].GetOpenPorts(), 1)
	require.EqualValues(t, 22, port(hosts[0].GetOpenPorts()[0].GetTestedCheckIndex()))
	require.EqualValues(t, 2*time.Millisecond, hosts[0].GetOpenPorts()[0].GetResponseTimeNano())
	require.Equal(t, "ssh", hosts[0].GetOpenPorts()[0].GetService())
	require.Len(t, hosts[0].GetPortErrors(), 1)
	require.EqualValues(t, 443, port(hosts[0].GetPortErrors()[0].GetTestedCheckIndex()))
	require.Equal(t, unleasedSweepClosedPort, hosts[0].GetPortErrors()[0].GetErrorCode())
	require.Equal(t, -2*int64(time.Second), hosts[0].GetLastSeenDeltaNano())
	require.Equal(t, -int64(time.Hour), hosts[0].GetFirstSeenDeltaNano())

	// Every host's legacy JSON is recoverable from the batch byte for byte.
	require.Len(t, batch.GetHostResults(), len(doc.Hosts))
	for i := range doc.Hosts {
		want, err := json.Marshal(doc.Hosts[i])
		require.NoError(t, err)
		got, err := json.Marshal(legacyHostFromBatch(t, batch, i))
		require.NoError(t, err)
		require.JSONEq(t, string(want), string(got))
		require.Equal(t, string(want), string(got))
	}

	require.Equal(t, netip.MustParseAddr("192.0.2.11").AsSlice(), hosts[1].GetAddress())
	require.False(t, hosts[1].GetIcmp().GetTargetReached())
	require.InDelta(t, 100, hosts[1].GetIcmp().GetPacketLossPct(), 0)
	require.Empty(t, hosts[1].GetOpenPorts())
	require.EqualValues(t, 22, port(hosts[1].GetPortErrors()[0].GetTestedCheckIndex()))

	require.Equal(t, netip.MustParseAddr("2001:db8::12").AsSlice(), hosts[2].GetAddress())
	require.Nil(t, hosts[2].GetIcmp())
	require.EqualValues(t, 443, port(hosts[2].GetOpenPorts()[0].GetTestedCheckIndex()))
	require.EqualValues(t, 3*time.Millisecond+7, hosts[2].GetOpenPorts()[0].GetResponseTimeNano())

	// The chunk's metric batch is the envelope the legacy push sends.
	chunks, err := buildSweepResultsChunks(response)
	require.NoError(t, err)
	require.Equal(t, chunks[0].MetricPayload, metricPayloads[0])
}

// legacyHostFromBatch rebuilds host i of batch as the agent's results JSON host,
// from the frozen observation and its legacy host result: what core rebuilds.
func legacyHostFromBatch(t *testing.T, batch *edgev1.UnleasedSweepResultsBatchV1, i int) models.HostResult {
	t.Helper()
	host, result := batch.GetHosts()[i], batch.GetHostResults()[i]
	addr, ok := netip.AddrFromSlice(host.GetAddress())
	require.True(t, ok)
	firstSeen, err := time.Parse(time.RFC3339Nano, result.GetFirstSeen())
	require.NoError(t, err)
	lastSeen, err := time.Parse(time.RFC3339Nano, result.GetLastSeen())
	require.NoError(t, err)
	out := models.HostResult{
		Host: addr.String(), Available: result.GetAvailable(), FirstSeen: firstSeen, LastSeen: lastSeen,
		ResponseTime: time.Duration(result.GetResponseTimeNano()),
	}
	for _, port := range result.GetPortResults() {
		out.PortResults = append(out.PortResults, &models.PortResult{
			Port: int(port.GetPort()), Available: port.GetAvailable(),
			RespTime: time.Duration(port.GetResponseTimeNano()), Service: port.GetService(),
		})
	}
	if icmp := host.GetIcmp(); icmp != nil {
		out.ICMPStatus = &models.ICMPStatus{
			Available: icmp.GetTargetReached(), RoundTrip: time.Duration(result.GetIcmpRoundTripNano()),
			PacketLoss: icmp.GetPacketLossPct(),
		}
	}
	if mtr := host.GetMtr(); mtr != nil {
		out.MTRStatus = &models.MTRStatus{
			Reached: mtr.GetTargetReached(), RoundTrip: time.Duration(result.GetMtrRoundTripNano()),
			PacketLoss: mtr.GetPacketLossPct(), TotalHops: int(mtr.GetTotalHops()),
		}
	}
	for _, mode := range result.GetSweepModes() {
		out.SweepModes = append(out.SweepModes, models.SweepMode(mode))
	}
	return out
}

// A response larger than one record's row ceiling or payload cap is split
// across records, numbered across the response, each within both bounds, with
// every host carried once and in order.
func TestUnleasedSweepResultsSplitAcrossRecordsWithinTheGrant(t *testing.T) {
	const total = 20_001
	cases := map[string]struct {
		host    func(addr string) models.HostResult
		maxRows uint32
		// largest is the host count of the largest record: just under the row
		// ceiling when halving stops at it, further under when the payload cap does.
		check func(t *testing.T, largest uint32)
	}{
		"bare hosts split at the row ceiling": {
			host:    func(addr string) models.HostResult { return models.HostResult{Host: addr} },
			maxRows: 2_000,
			check: func(t *testing.T, largest uint32) {
				t.Helper()
				require.Greater(t, largest, uint32(1_000))
			},
		},
		"probed hosts split at the payload cap": {
			host:    reachableHost,
			maxRows: 10_000,
			check: func(t *testing.T, largest uint32) {
				t.Helper()
				require.Less(t, largest, uint32(5_000))
			},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Setenv("SWEEP_RESULTS_MAX_HOSTS_PER_CHUNK", "50000")
			t.Setenv("SWEEP_RESULTS_MAX_CHUNK_BYTES", strconv.Itoa(64<<20))
			loop, _ := unleasedSweepLoop(t, openTestEdgeSpool(t), &scriptedSweepResults{}, unleasedSweepGrant(t, tc.maxRows))
			capability := loop.edgeOutputGrants.current(edgerecord.UnleasedSweepResultsContractID, time.Now())

			hosts := make([]models.HostResult, total)
			for i := range hosts {
				hosts[i] = tc.host(fmt.Sprintf("2001:db8::%x", i+1))
			}
			response := sweepResultsResponse(t, unleasedTestGroupID, "1", hosts, nil)

			parts, metricPayloads, err := buildSweepResultsEdgeRecords(response, capability)
			require.NoError(t, err)
			require.Len(t, metricPayloads, 1, "one legacy chunk, one metric batch")

			next, largest := 1, uint32(0)
			for i, part := range parts {
				record := part.record
				require.NoError(t, edgerecord.ValidateUnleasedSweepResultsRecord(record))
				require.LessOrEqual(t, record.GetProjectedRowCount(), tc.maxRows)
				largest = max(largest, record.GetProjectedRowCount())
				body := recordBody(t, record)
				require.LessOrEqual(t, len(body), edgeMetricsMaxPayloadBytes)
				batch := &edgev1.UnleasedSweepResultsBatchV1{}
				require.NoError(t, gproto.Unmarshal(body, batch))
				require.EqualValues(t, i, batch.GetChunkIndex())
				require.EqualValues(t, len(parts), batch.GetTotalChunks())
				require.Equal(t, i == len(parts)-1, batch.GetIsFinal())
				require.EqualValues(t, total, batch.GetExpectedTotalHosts())
				for _, host := range batch.GetHosts() {
					require.Equal(t, netip.MustParseAddr(fmt.Sprintf("2001:db8::%x", next)).AsSlice(), host.GetAddress())
					next++
				}
			}
			require.Equal(t, total+1, next)
			tc.check(t, largest)
		})
	}
}

// Each response takes one path: an unleased group's results go to the spool
// while the agent holds both grants, a leased group's keep the legacy push, and
// both are acknowledged once.
func TestUnleasedSweepResultsTakeOnePathPerGroup(t *testing.T) {
	sp := openTestEdgeSpool(t)
	svc := &scriptedSweepResults{
		leased: map[string]bool{leasedTestGroupID: true},
		responses: []*proto.ResultsResponse{
			sweepResultsResponse(t, unleasedTestGroupID, "1", []models.HostResult{reachableHost("192.0.2.10")}, nil),
			sweepResultsResponse(t, leasedTestGroupID, "1", []models.HostResult{reachableHost("192.0.2.20")}, nil),
		},
	}
	loop, gw := unleasedSweepLoop(t, sp, svc, currentMetricsGrant(t), unleasedSweepGrant(t, 10_000))

	require.True(t, loop.pushSweepResults(t.Context()))

	_, batches, metrics := spooledUnleasedSweep(t, sp)
	require.Len(t, batches, 1)
	require.Equal(t, uuid.MustParse(unleasedTestGroupID), uuid.UUID(batches[0].GetSweepGroupId()))
	require.Equal(t, 1, metrics)
	require.Equal(t, 1, gw.statusesFrom("results"), "only the leased group's chunk is pushed")
	require.Equal(t, 1, gw.statusesFrom("sweep-metrics"))
	require.Equal(t, []string{unleasedTestGroupID + "/1", leasedTestGroupID + "/1"}, svc.acked())
}

// Without both grants every response keeps the legacy push and nothing is spooled.
func TestUnleasedSweepResultsKeepTheLegacyPathWithoutBothGrants(t *testing.T) {
	for name, grants := range map[string]func(*testing.T) []*proto.EdgeOutputGrant{
		"no grant": func(*testing.T) []*proto.EdgeOutputGrant { return nil },
		"only results grant": func(t *testing.T) []*proto.EdgeOutputGrant {
			t.Helper()
			return []*proto.EdgeOutputGrant{unleasedSweepGrant(t, 10_000)}
		},
		"only metrics grant": func(t *testing.T) []*proto.EdgeOutputGrant {
			t.Helper()
			return []*proto.EdgeOutputGrant{currentMetricsGrant(t)}
		},
	} {
		t.Run(name, func(t *testing.T) {
			sp := openTestEdgeSpool(t)
			svc := &scriptedSweepResults{responses: []*proto.ResultsResponse{
				sweepResultsResponse(t, unleasedTestGroupID, "1", []models.HostResult{reachableHost("192.0.2.10")}, nil),
			}}
			loop, gw := unleasedSweepLoop(t, sp, svc, grants(t)...)

			require.True(t, loop.pushSweepResults(t.Context()))

			_, batches, metrics := spooledUnleasedSweep(t, sp)
			require.Empty(t, batches)
			require.Zero(t, metrics)
			require.Equal(t, 1, gw.statusesFrom("results"))
			require.Equal(t, []string{unleasedTestGroupID + "/1"}, svc.acked())
		})
	}
}

// A response the typed batch cannot carry keeps the legacy push whole.
func TestUnconvertibleSweepResultsKeepTheLegacyPath(t *testing.T) {
	for name, response := range map[string]func(*testing.T) *proto.ResultsResponse{
		"an address that does not parse": func(t *testing.T) *proto.ResultsResponse {
			t.Helper()
			return sweepResultsResponse(t, unleasedTestGroupID, "1", []models.HostResult{reachableHost("host01.example.com")}, nil)
		},
		"an address not in canonical form": func(t *testing.T) *proto.ResultsResponse {
			t.Helper()
			return sweepResultsResponse(t, unleasedTestGroupID, "1", []models.HostResult{reachableHost("2001:DB8::1")}, nil)
		},
		"an upper-case execution id": func(t *testing.T) *proto.ResultsResponse {
			t.Helper()
			return sweepResultsResponse(t, unleasedTestGroupID, "1", []models.HostResult{reachableHost("192.0.2.10")},
				map[string]any{"execution_id": "00000000-0000-4000-8000-00000000ABCD"})
		},
		"a group id that is not a uuid": func(t *testing.T) *proto.ResultsResponse {
			t.Helper()
			return sweepResultsResponse(t, unleasedTestGroupID, "1", []models.HostResult{reachableHost("192.0.2.10")},
				map[string]any{"sweep_group_id": "group-01"})
		},
		"no execution id": func(t *testing.T) *proto.ResultsResponse {
			t.Helper()
			return sweepResultsResponse(t, unleasedTestGroupID, "1", []models.HostResult{reachableHost("192.0.2.10")},
				map[string]any{"execution_id": ""})
		},
	} {
		t.Run(name, func(t *testing.T) {
			sp := openTestEdgeSpool(t)
			svc := &scriptedSweepResults{responses: []*proto.ResultsResponse{response(t)}}
			loop, gw := unleasedSweepLoop(t, sp, svc, currentMetricsGrant(t), unleasedSweepGrant(t, 10_000))

			require.True(t, loop.pushSweepResults(t.Context()))

			_, batches, metrics := spooledUnleasedSweep(t, sp)
			require.Empty(t, batches)
			require.Zero(t, metrics)
			require.Equal(t, 1, gw.statusesFrom("results"))
			require.Equal(t, []string{unleasedTestGroupID + "/1"}, svc.acked())
		})
	}
}

// A spool refusal part way through a response, at its metric batch or at a
// results record, leaves it unacknowledged and unread again; the next push
// appends only the unsent records, under their original event ids, on the edge
// path even after the grants are withdrawn, and only then acknowledges the
// response once.
func TestARefusedUnleasedSweepAppendResumesWithTheUnsentRecords(t *testing.T) {
	// One metric batch, then three results records of at most two hosts.
	const records = 4
	for name, admitted := range map[string]int{"at the metric batch": 0, "at a results record": 2} {
		t.Run(name, func(t *testing.T) {
			inner := openTestEdgeSpool(t)
			hosts := make([]models.HostResult, 5)
			for i := range hosts {
				hosts[i] = reachableHost(fmt.Sprintf("192.0.2.%d", 10+i))
			}
			svc := &scriptedSweepResults{responses: []*proto.ResultsResponse{
				sweepResultsResponse(t, unleasedTestGroupID, "3", hosts, nil),
			}}
			loop, gw := unleasedSweepLoop(t, inner, svc, currentMetricsGrant(t), unleasedSweepGrant(t, 2))
			script := &appendScript{inner: inner, refuseAfter: admitted}
			loop.edgeMetricsSpool = script

			require.Equal(t, admitted > 0, loop.pushSweepResults(t.Context()))
			require.Len(t, script.ids, admitted+1)
			refused := script.ids[admitted]
			require.Empty(t, svc.acked())
			require.Equal(t, 1, svc.reads)

			require.False(t, loop.pushSweepResults(t.Context()), "nothing more is admitted")
			require.Equal(t, refused, script.ids[admitted+1], "the retry reuses the refused record's event id")
			require.Equal(t, 1, svc.reads, "no response is read while one is pending")

			require.Empty(t, loop.edgeOutputGrants.replace(sysmonEdgeAgentID, nil, time.Now()))
			script.admitAll()
			require.True(t, loop.pushSweepResults(t.Context()))
			require.Equal(t, refused, script.ids[0])
			require.Len(t, script.ids, records-admitted, "only the unsent records are appended")

			spooled, batches, metrics := spooledUnleasedSweep(t, inner)
			require.Equal(t, 1, metrics)
			require.Len(t, spooled, records-1)
			seen := map[string]bool{}
			carried := 0
			for i, record := range spooled {
				require.False(t, seen[string(record.GetEventId())])
				seen[string(record.GetEventId())] = true
				require.EqualValues(t, i, batches[i].GetChunkIndex())
				carried += len(batches[i].GetHosts())
			}
			require.Equal(t, len(hosts), carried)
			require.Zero(t, gw.statusesFrom("results"))
			require.Zero(t, gw.statusesFrom("sweep-metrics"))
			require.Equal(t, []string{unleasedTestGroupID + "/3"}, svc.acked())
		})
	}
}

// The fidelity fixture shared with core's EdgeRecord DB test: one legacy results
// response and the unleased batch the agent converts it to. Core ingests the JSON
// through the legacy results path and the batch through the projector and
// requires identical rows. Regenerate with EDGE_GOLDEN_UPDATE=1.
const (
	fidelityResultsFixture = "unleased_sweep_fidelity_results.json"
	fidelityBatchFixture   = "unleased_sweep_fidelity_body.bin"
	fidelityGroupID        = "00000000-0000-4000-8000-0000000000f1"
)

func TestUnleasedSweepFidelityFixture(t *testing.T) {
	seen := time.Date(2026, 6, 1, 12, 0, 0, 123_456_789, time.UTC)
	icmp := models.HostResult{
		Host: "192.0.2.10", Available: true, FirstSeen: seen.Add(-time.Hour), LastSeen: seen,
		ICMPStatus:   &models.ICMPStatus{Available: true, RoundTrip: 1_234_567, PacketLoss: 0},
		ResponseTime: 1_234_567,
		PortResults: []*models.PortResult{
			{Port: 443, Available: false, RespTime: 900_507},
			{Port: 22, Available: true, RespTime: 2_000_123, Service: "ssh"},
		},
		SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCPConnect},
	}
	unreached := models.HostResult{
		Host: "192.0.2.11", FirstSeen: seen.Add(-time.Hour), LastSeen: seen,
		ICMPStatus:  &models.ICMPStatus{PacketLoss: 100},
		PortResults: []*models.PortResult{{Port: 22, RespTime: 1_000_001}},
		SweepModes:  []models.SweepMode{models.ModeICMP, models.ModeTCPConnect},
	}
	tcpOnly := models.HostResult{
		Host: "192.0.2.12", Available: true, FirstSeen: seen.Add(-time.Hour), LastSeen: seen,
		ResponseTime: 3_000_007,
		PortResults:  []*models.PortResult{{Port: 443, Available: true, RespTime: 3_000_007}},
		SweepModes:   []models.SweepMode{models.ModeTCPConnect},
	}
	// The agent's verdict is available although no check it reports reached the host.
	verdict := models.HostResult{
		Host: "192.0.2.13", Available: true, FirstSeen: seen.Add(-time.Hour), LastSeen: seen,
		ICMPStatus: &models.ICMPStatus{PacketLoss: 100},
		SweepModes: []models.SweepMode{models.ModeICMP},
	}
	response := sweepResultsResponse(t, fidelityGroupID, "4", []models.HostResult{icmp, unreached, tcpOnly, verdict},
		map[string]any{
			"scanner_stats": &models.ScannerStats{Protocol: "tcp", ScannerPath: "connect", PacketsSent: 8, DialsStarted: 3, RxDropRatePercent: 0.19},
			"banner_grab":   &models.BannerGrabStats{CandidatesTotal: 2, MatchesTotal: 1, BannerBytesTotal: 64},
		})

	loop, _ := unleasedSweepLoop(t, openTestEdgeSpool(t), &scriptedSweepResults{}, unleasedSweepGrant(t, 10_000))
	parts, _, err := buildSweepResultsEdgeRecords(response,
		loop.edgeOutputGrants.current(edgerecord.UnleasedSweepResultsContractID, time.Now()))
	require.NoError(t, err)
	require.Len(t, parts, 1)

	agentGolden(t, fidelityResultsFixture, response.Data)
	agentGolden(t, fidelityBatchFixture, recordBody(t, parts[0].record))
}

// agentGolden writes or compares a fixture under proto/edge/v1/testdata, where
// core's tests read it, under go test and under Bazel (edge_testdata data dep).
func agentGolden(t *testing.T, name string, b []byte) {
	t.Helper()
	path := filepath.Join("..", "..", "..", "proto", "edge", "v1", "testdata", name)
	if os.Getenv("EDGE_GOLDEN_UPDATE") == "1" {
		require.NoError(t, os.WriteFile(path, b, 0o600))
		return
	}
	if dir := os.Getenv("TEST_SRCDIR"); dir != "" {
		path = filepath.Join(dir, "_main", "proto", "edge", "v1", "testdata", name)
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err, "regenerate with EDGE_GOLDEN_UPDATE=1")
	require.Equal(t, want, b, "%s drifted; regenerate with EDGE_GOLDEN_UPDATE=1", name)
}
