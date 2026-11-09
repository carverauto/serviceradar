package main

// Live first-start coverage for enable-edge-record-pipeline-by-default 6.3:
// a producer emits only while holding its grant. The sysmon metrics producer
// runs every push cycle; without a metrics production grant its samples are
// held (never built or appended), and the first push under a grant spools and
// delivers them. Unit tests pin the hold/build split per producer family;
// this test pins it end to end at a running agent.

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// productionGrantSwitch hands the fake gateway's GetConfig a mutable set of
// production grants, so a test can start grantless and grant mid-run.
type productionGrantSwitch struct {
	mu     sync.Mutex
	grants []*proto.EdgeOutputGrant
}

func (s *productionGrantSwitch) set(grants []*proto.EdgeOutputGrant) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.grants = grants
}

func (s *productionGrantSwitch) get() []*proto.EdgeOutputGrant {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]*proto.EdgeOutputGrant(nil), s.grants...)
}

// liveGrantScopeIDs returns synthetic canonical UUIDs for the minted
// production grant. The producer-context and network-scope claims must be
// versioned, variant-correct UUIDs (ValidateCanonicalUUID), not digests: the
// spool-path record validator fail-closes on them, and the packer reports
// any per-record validation failure as an oversize item.
func liveGrantScopeIDs() (networkScope, assignment uuid.UUID) {
	return uuid.MustParse("11111111-2222-4333-8444-555555555555"),
		uuid.MustParse("66666666-7777-4888-8999-000000000000")
}

// mintMetricsProductionGrant builds a structurally valid metrics production
// grant for agentID. The agent never verifies capability signatures (the
// gateway does), so an ephemeral key stands in for core's issuer; the
// wilful fields mirror metricsGrantRows in go/pkg/agent.
func mintMetricsProductionGrant(t *testing.T, agentID string) *proto.EdgeOutputGrant {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	digest := sha256.Sum256([]byte("synthetic-metrics-contract"))
	networkScope, assignment := liveGrantScopeIDs()
	now := time.Now()
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("synthetic-core"),
		IssuerKeyId:       []byte("synthetic-core-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: now.Add(-time.Hour).UnixNano(),
		ExpiresAtUnixNano: now.Add(24 * time.Hour).UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId: edgerecord.MetricsBatchContractID, ContractVersion: edgerecord.MetricsBatchContractVersion,
			ContractBundleSha256: digest[:], RegistryEpoch: 1, RegistrySnapshotSha256: digest[:], EffectiveGrantSha256: digest[:],
			NetworkScopeId: networkScope[:], ProducerAssignmentId: assignment[:], RunId: assignment[:],
			AuthorityEpoch: 1, ScopeId: assignment[:], ScopeSha256: digest[:],
			OriginKind: edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT, OriginPrincipalId: []byte(agentID), ProducerInstanceId: []byte(agentID),
			RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:    "serviceradar.agent.metrics", PackageSha256: digest[:], CostModelVersion: 1,
			MaxProjectedRowCount: 10_000, MaxProjectedWriteBytes: 10_000 * 1_024,
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

// metricsFrames returns the delivered frames whose record carries the metrics
// batch contract.
func metricsFrames(t *testing.T, frames []*edgev1.EdgeDeliveryFrameV1) []*edgev1.EdgeDeliveryFrameV1 {
	t.Helper()
	var out []*edgev1.EdgeDeliveryFrameV1
	for _, frame := range frames {
		record, err := edgerecord.DecodeRecord(frame.GetRecordBytes())
		require.NoError(t, err)
		if record.GetOutputContract().GetContractId() == edgerecord.MetricsBatchContractID {
			out = append(out, frame)
		}
	}
	return out
}

// framesUnderGrant returns the delivered metrics frames whose record was
// produced under grant's production capability, so a frame left in a shared
// spool by an earlier run, under another grant, never counts.
func framesUnderGrant(t *testing.T, frames []*edgev1.EdgeDeliveryFrameV1, grant *proto.EdgeOutputGrant) []*edgev1.EdgeDeliveryFrameV1 {
	t.Helper()
	want := &edgev1.EdgeSignedCapabilityV1{}
	require.NoError(t, gproto.Unmarshal(grant.GetProductionCapability(), want))
	var out []*edgev1.EdgeDeliveryFrameV1
	for _, frame := range metricsFrames(t, frames) {
		record, err := edgerecord.DecodeRecord(frame.GetRecordBytes())
		require.NoError(t, err)
		if gproto.Equal(record.GetProductionCapability(), want) {
			out = append(out, frame)
		}
	}
	return out
}

func waitForMetricsFrames(t *testing.T, gw *grantLiveGateway, logs *agentOutput, url string, grant *proto.EdgeOutputGrant, timeout time.Duration) []*edgev1.EdgeDeliveryFrameV1 {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		_, frames := gw.snapshot()
		if got := framesUnderGrant(t, frames, grant); len(got) > 0 {
			return got
		}
		time.Sleep(200 * time.Millisecond)
	}
	diagnoseNoDelivery(t, gw, logs, url)
	t.Fatalf("no metrics batch frames under this run's grant delivered within %s", timeout)
	return nil
}

// firstN returns at most n lines for failure output.
func firstN(lines []string, n int) []string {
	if len(lines) > n {
		return lines[:n]
	}
	return lines
}

// diagnoseNoDelivery dumps the gateway frames by contract, the agent log tail
// and the spool/drop telemetry for a delivery timeout.
func diagnoseNoDelivery(t *testing.T, gw *grantLiveGateway, logs *agentOutput, url string) {
	t.Helper()
	_, frames := gw.snapshot()
	contracts := map[string]int{}
	for _, frame := range frames {
		record, err := edgerecord.DecodeRecord(frame.GetRecordBytes())
		if err != nil {
			contracts["undecodable"]++
			continue
		}
		contracts[record.GetOutputContract().GetContractId()]++
	}
	t.Logf("frames by contract: %v", contracts)
	full := logs.snapshot()
	var refused, lifecycle []string
	for _, line := range strings.Split(string(full), "\n") {
		if strings.Contains(line, "Refused edge output grant") {
			refused = append(refused, line)
		}
		lower := strings.ToLower(line)
		if strings.Contains(lower, "sysmon service") ||
			strings.Contains(lower, "edge spool") ||
			strings.Contains(lower, "sender") ||
			strings.Contains(lower, "applied edge") ||
			strings.Contains(lower, "push loop") {
			lifecycle = append(lifecycle, line)
		}
	}
	t.Logf("refused production grants: %d (showing up to 3): %v", len(refused), firstN(refused, 3))
	t.Logf("lifecycle lines (up to 15): %v", firstN(lifecycle, 15))
	var interesting []string
	for _, line := range strings.Split(string(full), "\n") {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "sysmon") ||
			strings.Contains(lower, "grant") ||
			strings.Contains(lower, "spool") ||
			strings.Contains(lower, "sender") ||
			strings.Contains(lower, "config") ||
			strings.Contains(lower, "drop") ||
			strings.Contains(lower, "invalid") ||
			strings.Contains(lower, "too large") ||
			strings.Contains(lower, "push") {
			interesting = append(interesting, line)
		}
	}
	t.Logf("interesting agent lines (%d, up to 40): %v", len(interesting), firstN(interesting, 40))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if body, ok, _ := scrapeMetricsOnce(ctx, t, url); ok {
		var kept strings.Builder
		for _, line := range strings.Split(body, "\n") {
			if strings.Contains(line, "agent_edge_spool_") ||
				strings.Contains(line, "agent_edge_record_dropped_samples_total") ||
				strings.Contains(line, "agent_edge_record_grant_holds_total") {
				kept.WriteString(line + "\n")
			}
		}
		t.Logf("spool/drop telemetry:\n%s", kept.String())
	}
}

// scopedSysmonJSON collects memory scalars only, keeping batches small so the
// tests stay about the grant gate rather than record packing.
const scopedSysmonJSON = `{"enabled": true, "sample_interval": "2s",
  "collect_cpu": false, "collect_memory": true,
  "collect_disk": false, "collect_network": false, "collect_processes": false}`

// A grantless sysmon producer holds its samples: several push cycles deliver
// no metrics frames, while the agent stays alive and fetching config (so the
// zero is a held producer, not a dead agent). Its granted twin below proves
// the same setup delivers, so the hold is meaningful rather than vacuous.
func TestRunningAgentHoldsProducerRecordsWithoutAGrant(t *testing.T) {
	gw, addr := listenSpoolHelloGateway(t, true, 0)

	logs, _ := runSpoolAgentFull(t, addr, "producer-grant-live",
		fmt.Sprintf(`{"spool_dir": %q, "poll_interval": "1s"}`, filepath.Join(t.TempDir(), "spool")),
		"3s", scopedSysmonJSON)

	waitForHello(t, gw, logs)
	time.Sleep(10 * time.Second)
	_, configs := gw.lastHello()
	require.NotZero(t, configs, "agent must be fetching config while holding\nlog:\n%s", logs.snapshot())
	_, frames := gw.snapshot()
	require.Empty(t, metricsFrames(t, frames),
		"grantless producer must not deliver metrics frames\nlog:\n%s", logs.snapshot())
}

// The granted twin of the hold test: the first config carries a metrics
// production grant, and the sysmon producer's batches are delivered. Together
// the pair is the 6.3 producer claim: emits only while holding its grant.
func TestRunningAgentDeliversProducerRecordsWithAGrant(t *testing.T) {
	const agentID = "producer-grant-delivers"
	grants := &productionGrantSwitch{}
	gw, addr := listenSpoolHelloGateway(t, true, 0)
	gw.productionGrants = grants
	grant := mintMetricsProductionGrant(t, agentID)
	grants.set([]*proto.EdgeOutputGrant{grant})

	logs, url := runSpoolAgentFull(t, addr, agentID,
		fmt.Sprintf(`{"spool_dir": %q, "poll_interval": "1s"}`, filepath.Join(t.TempDir(), "spool")),
		"3s", scopedSysmonJSON)

	delivered := waitForMetricsFrames(t, gw.grantLiveGateway, logs, url, grant, 30*time.Second)
	require.NotEmpty(t, delivered, "granted producer must deliver metrics frames\nlog:\n%s",
		logs.snapshot())
}

// The first start of a package-installed agent whose config has no
// edge_record_sender block (6.3, 7.3). The package provides the runtime
// directory /var/lib/serviceradar/agent and nothing under it; the agent must
// create its spool at <state dir>/agent/edge-records (task 4.1), apply the
// spool budget core sends in its first config, take the metrics production
// grant from that same config, and deliver the sysmon producer's batches made
// under that grant on the default sender cadence. The test stands in for the
// package: it skips only when this user cannot provide that runtime directory,
// and once the agent runs, an unavailable spool fails.
func TestRunningAgentWithoutASenderBlockDeliversFromTheDefaultSpool(t *testing.T) {
	const (
		agentID    = "edge-spool-default-on"
		runtimeDir = "/var/lib/serviceradar/agent"
		spoolDir   = runtimeDir + "/edge-records"
		budget     = 256 << 20
	)
	if err := provideFreshRuntimeDir(runtimeDir, spoolDir); err != nil {
		t.Skipf("cannot provide the package runtime directory %s as this user: %v", runtimeDir, err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(spoolDir) })

	grants := &productionGrantSwitch{}
	gw, addr := listenSpoolHelloGateway(t, true, budget)
	gw.productionGrants = grants
	grant := mintMetricsProductionGrant(t, agentID)
	grants.set([]*proto.EdgeOutputGrant{grant})

	logs, url := runSpoolAgentFull(t, addr, agentID, "null", "3s", scopedSysmonJSON)

	hello := waitForHello(t, gw, logs)
	spoolStatus := hello.GetEdgeRecordSpool()
	require.True(t, spoolStatus.GetAvailable(), "hello edge_record_spool = %v, want available\nlog:\n%s",
		spoolStatus, logs.snapshot())
	info, err := os.Stat(spoolDir)
	require.NoError(t, err, "agent did not create the default spool directory")
	require.True(t, info.IsDir(), "%s is not a directory", spoolDir)

	// No sender block means the default sender cadence (30s), so the wait
	// must cover a full default drain interval plus margin.
	delivered := waitForMetricsFrames(t, gw.grantLiveGateway, logs, url, grant, 75*time.Second)
	require.NotEmpty(t, delivered, "no-block sender must deliver from the default spool")

	var appliedLine string
	for _, line := range strings.Split(string(logs.snapshot()), "\n") {
		if strings.Contains(line, "Applied edge spool budget from config") && strings.Contains(line, strconv.Itoa(budget)) {
			appliedLine = line
		}
	}
	require.NotEmpty(t, appliedLine, "agent did not apply the %d-byte spool budget from its config\nlog:\n%s",
		budget, logs.snapshot())
}

// provideFreshRuntimeDir does what the package postinstall does for the agent
// runtime directory and leaves no spool under it, as on a fresh install. It
// fails when this user could not create the spool leaf there.
func provideFreshRuntimeDir(runtimeDir, spoolDir string) error {
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		return err
	}
	if err := os.RemoveAll(spoolDir); err != nil {
		return err
	}
	if err := os.Mkdir(spoolDir, 0o755); err != nil {
		return err
	}
	return os.Remove(spoolDir)
}
