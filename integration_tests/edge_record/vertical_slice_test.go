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

// TestVerticalSlice is //integration_tests/edge_record:vertical_slice_test
// (unify-sweep-results-proto task 0.12, "FIRST GREEN VERTICAL SLICE"). It
// drives ONE committed bulk SweepObservationBatchV1 fixture through the REAL
// composed path:
//
//	record -> agent spool -> mTLS gRPC -> gateway -> JetStream PubAck
//	       -> EventWriter -> idempotent CNPG transaction -> query
//
// using a real embedded JetStream-enabled NATS broker (natsjwt.go), a real
// synthetic mTLS PKI (certs.go), the REAL serviceradar_agent_gateway and
// serviceradar_core_elx Mix release binaries started as literal `bin/<name>
// start` OS subprocesses (releases.go) -- mirroring how docker-compose.yml
// actually deploys them as separate services, so this target starts
// production supervision and configuration, not a hand-assembled substitute
// -- and the real go/cmd/agent binary (agentproc.go) in its normal push-mode
// entry point. Task 0.12's acceptance matrix (groups A-F) is CONJUNCTIVE;
// each is one t.Run subtest below, run in sequence (not parallel) because
// later groups depend on state earlier ones create.
//
// What is proven exactly, and what is a documented approximation, is called
// out per group below -- see each t.Run's doc comment. Groups E and F make
// claims about a request that is still outstanding, so they read the lane
// accountant's credit ledger (PublisherPool.ledger/1) from inside the gateway
// node over release `rpc` (ledgerwatch.go) while the gateway's NATS proxy
// holds that request in flight (natsproxy.go). Where a fully precise
// black-box proof was not achievable, the closest real approximation is used
// and clearly labeled, per this repo's Hard Rule that "a verification must be
// able to FAIL" -- an approximation that cannot fail is called out as such,
// not disguised as a stronger proof.
package verticalslice

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"github.com/bazelbuild/rules_go/go/runfiles"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/sender"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Bazel injects these at link time via x_defs (see BUILD.bazel) as
// rlocation-relative paths; mustRlocation resolves them to real filesystem
// paths at test runtime through the runfiles manifest.
var (
	gatewayReleaseTarRlocation string
	coreReleaseTarRlocation    string
	agentBinaryRlocation       string
	// provisionShardRlocation and describeShardRlocation are
	// //rust/integration-db:provision_generation_edge_record's and
	// :describe_shard's binaries, this test's only source of a CNPG
	// identity. This harness EXECS the binaries itself
	// rather than reading a JSON file written by an earlier buildbuddy.yaml
	// shell step and passed via --test_env, because a --test_env value
	// naming a host filesystem path is invisible to a remotely-executed test
	// sandbox (RBE) -- this repo's OWN pattern for crossing that exact
	// boundary (the "generation" database identity) never passes a loose
	// path through an env var either; it always resolves the typed
	// SERVICERADAR_ENV=ci identity from INSIDE the consuming process via
	// declared Bazel data. Running both as data-dependency subprocesses (same
	// technique as nats-server/the agent binary/the two Elixir releases)
	// keeps CNPG resolution on that same, sandbox-safe footing: their own
	// `data` dependencies (//build:run_id_file, the ci instance, the schema
	// generation manifest and policy) travel with them into this test's
	// runfiles.
	provisionShardRlocation string
	describeShardRlocation  string
)

const (
	edgeRecordStreamName = "TELEMETRY_EDGE_RECORD_V1_BULK"
	rpcTimeout           = 30 * time.Second
	pollTimeout          = 20 * time.Second
	pollInterval         = 250 * time.Millisecond
	agentPollInterval    = 200 * time.Millisecond
)

func resolveRlocation(rlocationPath string) (string, error) {
	if rlocationPath == "" {
		return "", fmt.Errorf("rlocation path not set -- BUILD.bazel x_defs missing for this variable")
	}
	return runfiles.Rlocation(rlocationPath)
}

func mustRlocation(t *testing.T, rlocationPath string) string {
	t.Helper()
	resolved, err := resolveRlocation(rlocationPath)
	if err != nil {
		t.Fatalf("resolve rlocation %s: %v", rlocationPath, err)
	}
	return resolved
}

// provisionAndDescribeShard creates this test's own disposable
// sr_core_test_<run>_<shard> database and returns its connection identity.
//
// The shard is SERVICERADAR_TEST_DB_SHARD, set by this target's BUILD `env`
// -- the same variable the Elixir lanes use to name their clones. Under the
// generation lifecycle buildbuddy.yaml runs, `sr_core_test_<run>` is only the
// generation lease id: the lanes' databases are `_<lane>` clones of the ready
// generation and no unsuffixed database exists, so this test clones a shard
// of its own the same way instead of assuming a shared run database.
func provisionAndDescribeShard() (*ShardCNPGConfig, error) {
	shard := os.Getenv("SERVICERADAR_TEST_DB_SHARD")
	if shard == "" {
		return nil, fmt.Errorf("SERVICERADAR_TEST_DB_SHARD is unset; BUILD.bazel's env names this target's disposable database shard")
	}
	if err := provisionShard(shard); err != nil {
		return nil, err
	}
	return describeShard()
}

// provisionShard executes //rust/integration-db:provision_generation_edge_record
// as a real subprocess to clone sr_core_test_<run>_<shard> from the READY
// schema generation the BazelCI lifecycle prepared (buildbuddy.yaml's
// prepare_generation step) -- the same clone_generation path
// provision_generation takes for the Elixir lanes, aimed at a shard no lane
// uses. The binary's Bazel `args`/`env` apply only under `bazel run`, so the
// operation and the shard list are passed explicitly here. teardown_db drops
// every sr_core_test_<run>_% database at the end of the run, so nothing new
// cleans up.
func provisionShard(shard string) error {
	binPath, err := resolveRlocation(provisionShardRlocation)
	if err != nil {
		return fmt.Errorf("resolve provision_generation_edge_record rlocation: %w", err)
	}

	var stdout, stderr bytes.Buffer
	cmd := exec.Command(binPath, "clone")
	cmd.Env = append(os.Environ(), "SERVICERADAR_TEST_DB_SHARDS="+shard)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("run provision_generation_edge_record clone: %w\nstderr: %s", err, stderr.String())
	}

	var out struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &out); err != nil {
		return fmt.Errorf("parse provision_generation_edge_record output %q: %w", stdout.String(), err)
	}
	if out.Status != "cloned" {
		return fmt.Errorf("provision_generation_edge_record reported status %q, want \"cloned\"", out.Status)
	}
	return nil
}

// describeShard executes //rust/integration-db:describe_shard as a real
// subprocess and parses its one line of stdout JSON into a ShardCNPGConfig
// (releases.go). It reads SERVICERADAR_TEST_DB_SHARD from this process's
// environment and only resolves and reports the identity, per its own
// moduledoc; provisionShard must already have created the clone.
func describeShard() (*ShardCNPGConfig, error) {
	binPath, err := resolveRlocation(describeShardRlocation)
	if err != nil {
		return nil, fmt.Errorf("resolve describe_shard rlocation: %w", err)
	}

	var stdout, stderr bytes.Buffer
	cmd := exec.Command(binPath)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("run describe_shard: %w\nstderr: %s", err, stderr.String())
	}

	var cfg ShardCNPGConfig
	if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &cfg); err != nil {
		return nil, fmt.Errorf("parse describe_shard output (%d bytes, withheld: it carries the fixture credentials): %w", stdout.Len(), err)
	}
	return &cfg, nil
}

// freePort binds an ephemeral TCP port on 127.0.0.1 and immediately releases
// it, so callers can hand a concrete port number to a subprocess's config
// before that subprocess starts listening. Not perfectly race-free against
// another process grabbing the same port in the interim, but this is the
// same best-effort technique Go's own net/http/httptest package uses, and
// good enough for one disposable, single-node test.
func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("allocate ephemeral port: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// harness bundles every live component of the composed path for one test
// run. All fields are safe to use directly from subtests; nothing here is
// torn down until the top-level test's Cleanup callbacks fire.
type harness struct {
	t *testing.T

	dir     string
	certSet *CertSet

	nats *NATSHarness
	// gwNATS is the relay the GATEWAY reaches NATS through. Groups E and F
	// withhold the broker's replies there to hold a publish request in
	// flight; core and the test's own clients connect to the broker directly.
	gwNATS *NATSProxy

	gatewayEnv GatewayEnvConfig
	coreEnv    CoreEnvConfig

	gwProc   *ReleaseProcess
	coreProc *ReleaseProcess
	agent    *AgentProcess

	sp *spool.Spool

	gatewayAddr       string
	gatewayServerName string

	// spoolID is the agent's own persistent lane spool id, read back from
	// disk after the agent process has started and written it (see
	// sender.PersistentSpoolID) -- Group C's conflict probe and Group F's
	// fencing probe both need to reuse this EXACT id on a second,
	// independent raw gRPC stream to land in the same delivery slot / lane.
	spoolID []byte

	// groupAFixture/groupASequence are Group A's accepted fixture and the
	// real spool sequence it landed at (expected 1) -- every later group
	// depends on this exact state.
	groupAFixture  *FixtureRecord
	groupASequence uint64
}

// preservedLogName is the flattened, h.dir-relative name a process log file
// is preserved under (each release/agent process writes its own workDir
// subdirectory): <dir>/core/serviceradar_core_elx.stderr.log becomes
// core__serviceradar_core_elx.stderr.log.
func (h *harness) preservedLogName(path string) string {
	rel, err := filepath.Rel(h.dir, path)
	if err != nil {
		rel = filepath.Base(path)
	}
	return strings.ReplaceAll(rel, string(filepath.Separator), "__")
}

// preserveProcessLogs copies every *.stdout.log/*.stderr.log file under h.dir
// into outDir under its preservedLogName, with both release configurations'
// Secrets() scrubbed, so a CI failure ("event_ledger row never appeared") has
// something to read beyond the bare error string -- see newHarness's
// registration comment for why this must run after every process's own
// Stop() cleanup.
func (h *harness) preserveProcessLogs(outDir string) {
	h.t.Helper()
	secrets := append(h.gatewayEnv.Secrets(), h.coreEnv.Secrets()...)

	_ = filepath.Walk(h.dir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil //nolint:nilerr // best-effort log salvage; a walk error must not fail the test
		}
		if !strings.HasSuffix(path, ".stdout.log") && !strings.HasSuffix(path, ".stderr.log") {
			return nil
		}

		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil //nolint:nilerr // best-effort; a partially-written log is still worth what we got
		}
		dest := filepath.Join(outDir, h.preservedLogName(path))
		if writeErr := os.WriteFile(dest, []byte(redactSecrets(string(data), secrets)), 0o600); writeErr != nil {
			h.t.Logf("preserveProcessLogs: write %s: %v", dest, writeErr)
		}
		return nil
	})
}

// newHarness brings up the complete real composed path once per top-level
// test. It is intentionally NOT reused across TestVerticalSlice invocations
// (there is exactly one) -- every subtest below shares this single instance.
func newHarness(t *testing.T) *harness {
	t.Helper()

	if testing.Short() {
		t.Skip("vertical slice harness needs real NATS/CNPG/Elixir releases/agent binary; skipped in -short mode (see go/pkg/cli/nats_bootstrap_acl_integration_test.go for the same repo convention). The primary gate is Bazel's requires_shared_fixture()-style tag, not this skip.")
	}

	dir := t.TempDir()
	h := &harness{t: t, dir: dir}

	// Registered FIRST so it runs LAST (t.Cleanup is LIFO) -- after every
	// process's own Stop() cleanup has flushed its stdout/stderr files.
	// t.TempDir() is deleted when the test ends, so without this, a CI
	// failure ("event_ledger row never appeared") leaves NO way to see
	// what the agent/gateway/core processes actually logged: BuildBuddy
	// only preserves files placed under TEST_UNDECLARED_OUTPUTS_DIR (the
	// standard Bazel test convention), which is empty outside `bazel test`.
	if outDir := os.Getenv("TEST_UNDECLARED_OUTPUTS_DIR"); outDir != "" {
		t.Cleanup(func() { h.preserveProcessLogs(outDir) })
	}

	certSet, err := GenerateCertSet(filepath.Join(dir, "certs"), "127.0.0.1")
	if err != nil {
		t.Fatalf("generate cert set: %v", err)
	}
	h.certSet = certSet
	h.gatewayServerName = certSet.GatewayServerName

	natsH, err := StartEmbeddedNATS(filepath.Join(dir, "nats-store"), filepath.Join(dir, "nats-creds"))
	if err != nil {
		t.Fatalf("start embedded nats: %v", err)
	}
	t.Cleanup(natsH.Shutdown)
	h.nats = natsH

	gwNATS, err := StartNATSProxy(natsH.URL)
	if err != nil {
		t.Fatalf("start gateway nats proxy: %v", err)
	}
	t.Cleanup(gwNATS.Close)
	h.gwNATS = gwNATS

	cnpg, cnpgCAFile := resolveCNPG(t, dir)

	grpcPort := freePort(t)
	gwMetricsPort := freePort(t)
	coreMetricsPort := freePort(t)

	h.gatewayAddr = fmt.Sprintf("127.0.0.1:%d", grpcPort)

	cloakKey, err := GenerateCloakKey()
	if err != nil {
		t.Fatalf("generate cloak key: %v", err)
	}

	// The gateway release bundles serviceradar_core as a normal mix
	// dependency and auto-starts it alongside serviceradar_agent_gateway in
	// the SAME process, so it independently needs DATABASE_URL/CLOAK_KEY too
	// -- see GatewayEnvConfig's doc comment for exactly why.
	h.gatewayEnv = GatewayEnvConfig{
		GRPCPort:      grpcPort,
		MetricsPort:   gwMetricsPort,
		CertDir:       certSet.Dir,
		NATSURL:       gwNATS.URL,
		NATSCredsFile: natsH.CredsPath,
		PartitionID:   certSet.PartitionID,
		GatewayID:     "vslice-gateway",
		Domain:        "vslice",
		CNPGHost:      cnpg.Host,
		CNPGPort:      cnpg.Port,
		CNPGDatabase:  cnpg.Database,
		CNPGUsername:  cnpg.Username,
		CNPGPassword:  cnpg.Password,
		CNPGSSLMode:   cnpg.SSLMode,
		CloakKey:      cloakKey,
	}

	h.coreEnv = CoreEnvConfig{
		MetricsPort:       coreMetricsPort,
		CNPGHost:          cnpg.Host,
		CNPGPort:          cnpg.Port,
		CNPGDatabase:      cnpg.Database,
		CNPGUsername:      cnpg.Username,
		CNPGPassword:      cnpg.Password,
		CNPGSSLMode:       cnpg.SSLMode,
		CNPGCAFile:        cnpgCAFile,
		CNPGTLSServerName: cnpg.TLSServerName,
		NATSURL:           natsH.URL,
		NATSCredsFile:     natsH.CredsPath,
		CloakKey:          cloakKey,
	}

	gatewayTarPath := mustRlocation(t, gatewayReleaseTarRlocation)
	coreTarPath := mustRlocation(t, coreReleaseTarRlocation)
	agentBinaryPath := mustRlocation(t, agentBinaryRlocation)

	gwProc, err := StartRelease(
		gatewayTarPath, "serviceradar_agent_gateway", filepath.Join(dir, "gateway"),
		h.gatewayEnv, fmt.Sprintf("http://127.0.0.1:%d/health", gwMetricsPort), 90*time.Second,
	)
	if err != nil {
		t.Fatalf("start gateway release: %v", err)
	}
	t.Cleanup(gwProc.Stop)
	h.gwProc = gwProc

	coreProc, err := StartRelease(
		coreTarPath, "serviceradar_core_elx", filepath.Join(dir, "core"),
		h.coreEnv, fmt.Sprintf("http://127.0.0.1:%d/health", coreMetricsPort), 90*time.Second,
	)
	if err != nil {
		t.Fatalf("start core release: %v", err)
	}
	t.Cleanup(coreProc.Stop)
	h.coreProc = coreProc
	h.installIngestProbe(t)

	agentProc, err := StartAgent(
		agentBinaryPath, filepath.Join(dir, "agent"), h.gatewayAddr, h.gatewayServerName,
		certSet.AgentComponentID, certSet.CACertPath, certSet.AgentCertPath, certSet.AgentKeyPath,
		agentPollInterval,
	)
	if err != nil {
		t.Fatalf("start agent: %v", err)
	}
	t.Cleanup(agentProc.Stop)
	h.agent = agentProc

	sp, err := spool.Open(agentProc.SpoolDir)
	if err != nil {
		t.Fatalf("open agent spool: %v", err)
	}
	h.sp = sp

	spoolID, err := waitForSpoolID(agentProc.SpoolDir, pollTimeout)
	if err != nil {
		t.Fatalf("read agent's persistent spool id: %v", err)
	}
	h.spoolID = spoolID

	return h
}

// resolveCNPG creates this test's own clone of the CI schema generation by
// EXECUTING //rust/integration-db's provision_generation_edge_record and
// describe_shard binaries as real subprocesses (their declared data
// dependencies travel with them into this test's runfiles -- see
// provisionShardRlocation's doc comment for why this must not be a
// JSON-file-plus-env-var handoff), returning the clone's identity and the
// path of its CA PEM written under dir ("" when the fixture reported none).
func resolveCNPG(t *testing.T, dir string) (*ShardCNPGConfig, string) {
	t.Helper()

	cfg, err := provisionAndDescribeShard()
	if err != nil {
		t.Fatalf("provision/describe shard database: %v", err)
	}
	caPath, err := cfg.WriteCAPEMFile(filepath.Join(dir, "cnpg-ca"))
	if err != nil {
		t.Fatalf("write CNPG CA pem: %v", err)
	}
	return cfg, caPath
}

// waitForSpoolID polls for sender.PersistentSpoolID's on-disk file, written
// by the real agent process the first time its edge-record sender loop
// runs (go/pkg/edge/sender.PersistentSpoolID), rather than assuming a fixed
// timing.
func waitForSpoolID(spoolDir string, timeout time.Duration) ([]byte, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		id, err := sender.PersistentSpoolID(spoolDir)
		if err == nil && len(id) == 16 {
			return id, nil
		}
		lastErr = err
		time.Sleep(100 * time.Millisecond)
	}
	return nil, fmt.Errorf("spool id file did not appear within %s: %w", timeout, lastErr)
}

func TestVerticalSlice(t *testing.T) {
	h := newHarness(t)

	// Group A also produces state (the accepted fixture) every later group
	// depends on, so it MUST run first and its failure should stop the rest.
	fxA := t.Run("GroupA_ProductionCompositionAndTrust", h.testGroupA)
	if !fxA {
		t.Fatal("Group A did not pass; stopping (later groups depend on its accepted fixture)")
	}

	t.Run("GroupB_ExactBytes", h.testGroupB)
	t.Run("GroupC_IdempotentTransaction", h.testGroupC)
	t.Run("GroupD_FailureAndWatermarkOrder", h.testGroupD)
	t.Run("GroupE_RestartOverlap", h.testGroupE)
	t.Run("GroupF_PostHandoffFencing", h.testGroupF)
}

// ---------------------------------------------------------------------------
// Shared CNPG query helpers (via the CORE release's OWN already-configured
// Ecto.Repo, over `bin/serviceradar_core_elx rpc` -- see releases.go's
// ReleaseProcess.RPC doc comment for why this, and not a bespoke Go CNPG
// client, is the harness's query path).
// ---------------------------------------------------------------------------

// uuidLiteral renders b (a 16-byte UUID) as a Postgres ”::uuid literal.
func uuidLiteral(b []byte) string {
	h := hex.EncodeToString(b)
	return fmt.Sprintf("'%s-%s-%s-%s-%s'::uuid", h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])
}

// byteaLiteral renders b as a Postgres ”::bytea literal.
func byteaLiteral(b []byte) string {
	return fmt.Sprintf("'\\x%s'::bytea", hex.EncodeToString(b))
}

// rpcQueryCount runs one Elixir expression over the core release's Repo and
// returns the resulting integer, for existence/row-count checks. sql MUST be
// a single SELECT whose first column is an integer.
func (h *harness) rpcQueryCount(t *testing.T, sql string) int {
	t.Helper()
	expr := fmt.Sprintf(
		`%%Postgrex.Result{rows: [[n]]} = ServiceRadar.Repo.query!(%q, []); IO.puts(n)`,
		sql,
	)
	out, err := h.coreProc.RPC(expr, rpcTimeout)
	if err != nil {
		t.Fatalf("rpc query count failed: %v\nsql: %s", err, sql)
	}
	var n int
	if _, err := fmt.Sscanf(strings.TrimSpace(out), "%d", &n); err != nil {
		t.Fatalf("rpc query count: unparsable output %q for sql %s: %v", out, sql, err)
	}
	return n
}

// rpcQueryRow runs sql (expected to return exactly zero or one row) and
// returns its columns rendered as Elixir `inspect/1` text via RPC, or "" if
// no row matched. Used for field-by-field assertions where a plain count
// isn't enough.
func (h *harness) rpcQueryRow(t *testing.T, sql string) string {
	t.Helper()
	expr := fmt.Sprintf(
		`case ServiceRadar.Repo.query!(%q, []) do %%Postgrex.Result{rows: [row]} -> IO.puts(inspect(row)); %%Postgrex.Result{rows: []} -> IO.puts("NONE") end`,
		sql,
	)
	out, err := h.coreProc.RPC(expr, rpcTimeout)
	if err != nil {
		t.Fatalf("rpc query row failed: %v\nsql: %s", err, sql)
	}
	return strings.TrimSpace(out)
}

func eventLedgerExistsSQL(networkScopeID, eventID []byte) string {
	return fmt.Sprintf(
		"SELECT count(*) FROM platform.event_ledger WHERE network_scope_id = %s AND event_id = %s",
		uuidLiteral(networkScopeID), uuidLiteral(eventID),
	)
}

func deliverySlotSQL(networkScopeID, authenticatedAgentID, spoolID []byte, sequence uint64) string {
	return fmt.Sprintf(
		"SELECT record_sha256, event_id FROM platform.edge_delivery_slots WHERE network_scope_id = %s AND authenticated_agent_id = %s AND spool_id = %s AND sequence = %d",
		uuidLiteral(networkScopeID), byteaLiteral(authenticatedAgentID), uuidLiteral(spoolID), sequence,
	)
}

// ---------------------------------------------------------------------------
// Group A: production composition and trust.
//
// Proves: the positive fixture reaches the production EventWriter through
// the real mTLS gRPC service, the real gateway publish pipeline, and the
// real JetStream route; its ledger/slot rows are absent before the send and
// exactly present (matching independently-computed expected values)
// afterward; and a client authenticated with the WRONG SPIFFE component
// type is refused at the mTLS/identity gate before any frame is even sent,
// with no side effect on the ledger.
// ---------------------------------------------------------------------------
func (h *harness) testGroupA(t *testing.T) {
	fx, err := BuildSweepFixture([]byte(h.certSet.AgentComponentID))
	if err != nil {
		t.Fatalf("build fixture: %v", err)
	}
	h.groupAFixture = fx

	// Absent before.
	if n := h.rpcQueryCount(t, eventLedgerExistsSQL(fx.NetworkScopeID, fx.EventID)); n != 0 {
		t.Fatalf("event_ledger row already present before send (count=%d) -- fixture ids not fresh", n)
	}

	seq, err := h.sp.Append(fx.EventID, fx.RecordBytes)
	if err != nil {
		t.Fatalf("append fixture to real spool: %v", err)
	}
	if seq != 1 {
		t.Fatalf("expected first spool append to get sequence 1, got %d", seq)
	}
	h.groupASequence = seq

	// Poll for the real path (agent sender -> gRPC -> gateway -> JetStream
	// -> EventWriter -> CNPG) to land the row -- gated on actual DB state,
	// not a fixed sleep.
	deadline := time.Now().Add(pollTimeout)
	var lastCount int
	for time.Now().Before(deadline) {
		lastCount = h.rpcQueryCount(t, eventLedgerExistsSQL(fx.NetworkScopeID, fx.EventID))
		if lastCount == 1 {
			break
		}
		time.Sleep(pollInterval)
	}
	if lastCount != 1 {
		t.Fatalf("event_ledger row for fixture never appeared within %s (last count=%d); see %s, %s and %s in this test's undeclared outputs (outputs.zip)",
			pollTimeout, lastCount,
			h.preservedLogName(h.agent.stderrPath), h.preservedLogName(h.gwProc.stderrPath), h.preservedLogName(h.coreProc.stderrPath))
	}

	h.assertCommittedFixtureValues(t, fx, h.spoolID, seq)

	h.testMismatchedIdentityControl(t, fx)
}

// assertCommittedFixtureValues matches every committed row fx's keys touch
// against independently computed expected values: the event_ledger digests,
// the delivery-slot binding at (spoolID, sequence), the sweep-batch-slot row
// counts, and the exact projected row-key set. Groups A, C and D share it so
// "the same exact expected values" means the same checks in each.
func (h *harness) assertCommittedFixtureValues(t *testing.T, fx *FixtureRecord, spoolID []byte, sequence uint64) {
	t.Helper()

	row := h.rpcQueryRow(t, fmt.Sprintf(
		"SELECT semantic_envelope_sha256, record_sha256 FROM platform.event_ledger WHERE network_scope_id = %s AND event_id = %s",
		uuidLiteral(fx.NetworkScopeID), uuidLiteral(fx.EventID),
	))
	if !strings.Contains(row, hexInspect(fx.SemanticEnvelopeSHA256)) {
		t.Errorf("event_ledger.semantic_envelope_sha256 mismatch: row=%s want digest=%x", row, fx.SemanticEnvelopeSHA256)
	}
	if !strings.Contains(row, hexInspect(fx.RecordSHA256)) {
		t.Errorf("event_ledger.record_sha256 mismatch: row=%s want digest=%x", row, fx.RecordSHA256)
	}

	slotRow := h.rpcQueryRow(t, deliverySlotSQL(fx.NetworkScopeID, []byte(h.certSet.AgentComponentID), spoolID, sequence))
	if !strings.Contains(slotRow, hexInspect(fx.RecordSHA256)) {
		t.Errorf("edge_delivery_slots.record_sha256 mismatch: row=%s want digest=%x", slotRow, fx.RecordSHA256)
	}

	batchRow := h.rpcQueryRow(t, fmt.Sprintf(
		"SELECT event_id, semantic_envelope_sha256, projected_row_count, committed_row_count FROM platform.edge_sweep_batch_slots WHERE network_scope_id = %s AND execution_id = %s AND execution_shard = %d AND assignment_epoch = %d AND batch_sequence = %d",
		uuidLiteral(fx.NetworkScopeID), uuidLiteral(fx.ExecutionID), fx.ExecutionShard, fx.AssignmentEpoch, fx.BatchSequence,
	))
	if batchRow == "NONE" {
		t.Fatalf("edge_sweep_batch_slots row missing for fixture's batch coordinate")
	}
	wantCounts := fmt.Sprintf("%d, %d", fx.ProjectedRowCount, fx.ProjectedRowCount)
	if !strings.Contains(batchRow, wantCounts) {
		t.Errorf("edge_sweep_batch_slots projected/committed row count mismatch: row=%s want both=%d", batchRow, fx.ProjectedRowCount)
	}

	// edge_sweep_projected_rows: exactly ProjectedRowCount rows, exact
	// row_key set match.
	gotCount := h.rpcQueryCount(t, fmt.Sprintf(
		"SELECT count(*) FROM platform.edge_sweep_projected_rows WHERE network_scope_id = %s AND event_id = %s",
		uuidLiteral(fx.NetworkScopeID), uuidLiteral(fx.EventID),
	))
	if gotCount != fx.ProjectedRowCount {
		t.Fatalf("edge_sweep_projected_rows count = %d, want %d", gotCount, fx.ProjectedRowCount)
	}
	h.assertProjectedRowKeySet(t, fx)
}

// hexInspect renders b the way Elixir's inspect/1 shows a binary column
// value fetched via Postgrex when it happens to print as a plain string --
// Postgrex actually returns raw binaries, which `inspect/1` renders as
// `<<1, 2, 3>>`; matching on the hex digest as a raw substring is fragile
// across encodings, so this helper renders the byte-list form Postgrex/
// Elixir's inspect emits for a `:binary` column instead.
func hexInspect(b []byte) string {
	parts := make([]string, len(b))
	for i, v := range b {
		parts[i] = fmt.Sprintf("%d", v)
	}
	return strings.Join(parts, ", ")
}

func (h *harness) assertProjectedRowKeySet(t *testing.T, fx *FixtureRecord) {
	t.Helper()
	out, err := h.coreProc.RPC(fmt.Sprintf(
		`%%Postgrex.Result{rows: rows} = ServiceRadar.Repo.query!(%q, []); rows |> Enum.map(fn [k] -> Base.encode16(k, case: :lower) end) |> Enum.sort() |> Enum.join(",") |> IO.puts()`,
		fmt.Sprintf("SELECT row_key FROM platform.edge_sweep_projected_rows WHERE network_scope_id = %s AND event_id = %s",
			uuidLiteral(fx.NetworkScopeID), uuidLiteral(fx.EventID)),
	), rpcTimeout)
	if err != nil {
		t.Fatalf("query projected row keys: %v", err)
	}

	got := strings.Split(strings.TrimSpace(out), ",")
	sort.Strings(got)

	want := make([]string, len(fx.RowKeys))
	for i, k := range fx.RowKeys {
		want[i] = hex.EncodeToString(k)
	}
	sort.Strings(want)

	if len(got) != len(want) {
		t.Fatalf("projected row key set size mismatch: got %d, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("projected row key set mismatch at index %d: got %s want %s", i, got[i], want[i])
			break
		}
	}
}

// testMismatchedIdentityControl sends the SAME fixture record over a
// SEPARATE raw gRPC session authenticated with the mismatched-identity
// client certificate (SPIFFE component_type=desktop). This is expected to
// be refused with permission_denied at lane_open, BEFORE any delivery_frame
// is even accepted, per edge_record_ingest_server.ex's
// require_agent_identity!/1 (runs on the very first message of the
// stream).
func (h *harness) testMismatchedIdentityControl(t *testing.T, fx *FixtureRecord) {
	t.Helper()

	tlsCfg, err := h.certSet.MismatchTLSConfig(h.gatewayServerName)
	if err != nil {
		t.Fatalf("mismatch tls config: %v", err)
	}

	conn, err := grpc.NewClient(h.gatewayAddr, grpc.WithTransportCredentials(credentials.NewTLS(tlsCfg)))
	if err != nil {
		t.Fatalf("dial gateway with mismatched identity: %v", err)
	}
	defer conn.Close()

	client := edgev1.NewEdgeRecordIngestServiceClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := client.Stream(ctx)
	if err != nil {
		t.Fatalf("open mismatched-identity stream: %v", err)
	}

	spoolID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("mismatch probe spool id: %v", err)
	}
	nonce := make([]byte, 32)
	open := &edgev1.EdgeRecordLaneOpen{
		RouteProfile:            edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:            edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		SpoolId:                 spoolID,
		SequenceBase:            1,
		FirstUnresolvedSequence: 1,
		SessionNonce:            nonce,
		RequestedByteCredits:    1 << 20,
		RequestedFrameCredits:   8,
	}
	if err := stream.Send(&edgev1.EdgeRecordClientMessage{Payload: &edgev1.EdgeRecordClientMessage_LaneOpen{LaneOpen: open}}); err != nil {
		t.Fatalf("send lane_open with mismatched identity: %v", err)
	}

	_, recvErr := stream.Recv()
	if recvErr == nil {
		t.Fatalf("expected mismatched-identity lane_open to be refused, got a successful reply")
	}
	st, ok := status.FromError(recvErr)
	if !ok || st.Code() != codes.PermissionDenied {
		t.Fatalf("expected PermissionDenied for mismatched identity, got: %v", recvErr)
	}

	// No side effect: no new ledger row for this fixture's identity beyond
	// what Group A's own (valid) send already created.
	if n := h.rpcQueryCount(t, eventLedgerExistsSQL(fx.NetworkScopeID, fx.EventID)); n != 1 {
		t.Errorf("mismatched-identity control had a side effect on event_ledger row count: got %d, want 1 (Group A's own row, unchanged)", n)
	}
}

// ---------------------------------------------------------------------------
// Group B: exact bytes.
//
// Proves: the exact bytes read back through the spool's public read path
// equal the exact bytes fetched independently through the JetStream
// consumer for the SAME committed record -- two independent reads, not two
// aliases of the same helper's output.
// ---------------------------------------------------------------------------
func (h *harness) testGroupB(t *testing.T) {
	fx := h.groupAFixture
	if fx == nil {
		t.Skip("Group A fixture unavailable")
	}

	// Read 1: the spool's own public read path.
	var spoolBytes []byte
	found := false
	if err := h.sp.ScanFrom(0, func(rec spool.Record) bool {
		if rec.Sequence == h.groupASequence {
			spoolBytes = append([]byte(nil), rec.Body...)
			found = true
		}
		return true
	}); err != nil {
		t.Fatalf("scan spool: %v", err)
	}
	if !found {
		t.Fatalf("spool no longer has sequence %d on its public read path", h.groupASequence)
	}

	// Read 2: the JetStream consumer, independently, over a fresh NATS
	// client connection using the same real .creds file the gateway/core
	// releases authenticate with.
	nc, err := nats.Connect(h.nats.URL, nats.UserCredentials(h.nats.CredsPath))
	if err != nil {
		t.Fatalf("connect to nats for group B read: %v", err)
	}
	defer nc.Close()

	js, err := jetstream.New(nc)
	if err != nil {
		t.Fatalf("jetstream context: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), rpcTimeout)
	defer cancel()

	stream, err := js.Stream(ctx, edgeRecordStreamName)
	if err != nil {
		t.Fatalf("open stream %s: %v (has the gateway published anything yet?)", edgeRecordStreamName, err)
	}
	info, err := stream.Info(ctx)
	if err != nil {
		t.Fatalf("stream info: %v", err)
	}
	if info.State.Msgs == 0 {
		t.Fatalf("stream %s has zero messages; Group A's publish did not land", edgeRecordStreamName)
	}

	raw, err := stream.GetMsg(ctx, info.State.FirstSeq)
	if err != nil {
		t.Fatalf("get first stored message (seq %d): %v", info.State.FirstSeq, err)
	}

	if !bytes.Equal(spoolBytes, raw.Data) {
		t.Errorf("spool-read bytes and JetStream-read bytes differ: spool=%d bytes, jetstream=%d bytes", len(spoolBytes), len(raw.Data))
	}
	if !bytes.Equal(spoolBytes, fx.RecordBytes) {
		t.Errorf("spool-read bytes differ from the fixture's own RecordBytes (unexpected: spool.Append should have stored them verbatim)")
	}
}

// ---------------------------------------------------------------------------
// Group C: idempotent CNPG transaction.
//
// Both sub-probes go through the production JetStream consumer, and neither
// calls a processor function directly:
//
//  1. Redelivery. A fresh fixture is published once over a real gRPC session.
//     The ingest probe (installIngestProbe) holds its FIRST delivery inside
//     the EventWriter batch after the CNPG transaction committed and before
//     the pipeline acknowledged the message, and the first-commit snapshot is
//     taken there. Once released, the probe raises, so the batch fails, the
//     production pipeline NAKs the message, and JetStream redelivers the SAME
//     stored message to the SAME durable consumer. That second entry into the
//     ledger path must report :replay and leave the snapshot unchanged. The
//     stream holds exactly one message carrying the fixture's bytes before
//     and after, so the second entry is a consumer redelivery, not a
//     publish-time duplicate.
//  2. Conflict. A second valid frame reusing the agent's (spool_id, sequence)
//     delivery slot with different record content is sent over a new real
//     gRPC session. The gateway accepts it: its PubAck is durable, and
//     Nats-Msg-Id binds record_sha256, so JetStream does not deduplicate it.
//     EventWriter then reaches it, and its transaction must end with
//     {:delivery_slot_conflict, existing} naming the first binding's
//     record_sha256, before any later write. The first binding stays
//     unchanged and no row appears for the conflicting content.
//
// ---------------------------------------------------------------------------
func (h *harness) testGroupC(t *testing.T) {
	fx := h.groupAFixture
	if fx == nil {
		t.Skip("Group A fixture unavailable")
	}

	tlsCfg, err := h.certSet.AgentTLSConfig(h.gatewayServerName)
	if err != nil {
		t.Fatalf("agent tls config: %v", err)
	}

	t.Run("Redelivery", func(t *testing.T) {
		fxC, err := BuildSweepFixture([]byte(h.certSet.AgentComponentID))
		if err != nil {
			t.Fatalf("build fixture: %v", err)
		}
		spoolID, err := edgerecord.NewUUIDv7()
		if err != nil {
			t.Fatalf("spool id: %v", err)
		}

		h.armIngestProbe(t, fxC.EventID, probeTransactionResult, 1, probeHoldThenRaise)

		before := h.snapshotFixtureRows(t, fxC, spoolID)
		if before != (fixtureRowSnapshot{}) {
			t.Fatalf("before snapshot = %+v, want no rows for a fresh fixture", before)
		}

		ack, err := h.sendOneRawFrame(t, tlsCfg, spoolID, 1, fxC.RecordBytes, fxC.RecordSHA256, 20*time.Second)
		if err != nil {
			t.Fatalf("send fixture: %v", err)
		}
		requireAcceptedAck(t, ack, spoolID, 1)

		first := h.waitIngestObservation(t, fxC.EventID, probeTransactionResult, 1)
		if first.Tag != "ok:inserted" {
			t.Fatalf("first delivery ended with %q, want ok:inserted", first.Tag)
		}

		want := fixtureRowSnapshot{Ledger: 1, Slots: 1, Batch: 1, Rows: fxC.ProjectedRowCount}
		firstCommit := h.snapshotFixtureRows(t, fxC, spoolID)
		if firstCommit != want {
			t.Fatalf("first-commit snapshot = %+v, want %+v", firstCommit, want)
		}
		h.assertCommittedFixtureValues(t, fxC, spoolID, 1)
		h.requireOneStoredMessage(t, fxC.RecordBytes)

		h.releaseIngestProbe(t, fxC.EventID, probeTransactionResult, 1)

		second := h.waitIngestObservation(t, fxC.EventID, probeTransactionResult, 2)
		if second.Tag != "ok:replay" {
			t.Fatalf("redelivery ended with %q, want ok:replay", second.Tag)
		}

		secondDelivery := h.snapshotFixtureRows(t, fxC, spoolID)
		if secondDelivery != firstCommit {
			t.Errorf("second-delivery snapshot = %+v, want the first-commit snapshot %+v", secondDelivery, firstCommit)
		}
		h.assertCommittedFixtureValues(t, fxC, spoolID, 1)
		h.requireOneStoredMessage(t, fxC.RecordBytes)
	})

	t.Run("Conflict", func(t *testing.T) {
		conflictFx, err := BuildConflictingSweepFixture(fx.NetworkScopeID, []byte(h.certSet.AgentComponentID))
		if err != nil {
			t.Fatalf("build conflicting fixture: %v", err)
		}

		agentID := []byte(h.certSet.AgentComponentID)
		beforeSlot := h.rpcQueryRow(t, deliverySlotSQL(fx.NetworkScopeID, agentID, h.spoolID, h.groupASequence))
		if beforeSlot == "NONE" {
			t.Fatalf("Group A's delivery-slot binding is missing before the conflict probe")
		}

		ack, err := h.sendOneRawFrame(
			t, tlsCfg, h.spoolID, h.groupASequence, conflictFx.RecordBytes, conflictFx.RecordSHA256, 20*time.Second,
		)
		if err != nil {
			t.Fatalf("conflicting frame was refused before JetStream publication: %v", err)
		}
		requireAcceptedAck(t, ack, h.spoolID, h.groupASequence)

		outcome := h.waitIngestObservation(t, conflictFx.EventID, probeTransactionResult, 1)
		if want := "error:delivery_slot_conflict:" + hex.EncodeToString(fx.RecordSHA256); outcome.Tag != want {
			t.Fatalf("conflicting frame ended with %q, want %q", outcome.Tag, want)
		}
		for _, o := range h.ingestObservations(t, conflictFx.EventID) {
			if o.Point == probeBeforeCommit {
				t.Errorf("conflicting frame completed its writes (%+v); the slot conflict must stop it first", o)
			}
		}

		if n := h.rpcQueryCount(t, eventLedgerExistsSQL(fx.NetworkScopeID, conflictFx.EventID)); n != 0 {
			t.Errorf("conflicting fixture's event_id leaked an event_ledger row (count=%d); conflict should roll back the whole transaction", n)
		}
		if n := h.rpcQueryCount(t, fmt.Sprintf(
			"SELECT count(*) FROM platform.edge_sweep_batch_slots WHERE network_scope_id = %s AND execution_id = %s",
			uuidLiteral(conflictFx.NetworkScopeID), uuidLiteral(conflictFx.ExecutionID),
		)); n != 0 {
			t.Errorf("conflicting fixture leaked an edge_sweep_batch_slots row (count=%d)", n)
		}

		afterSlot := h.rpcQueryRow(t, deliverySlotSQL(fx.NetworkScopeID, agentID, h.spoolID, h.groupASequence))
		if afterSlot != beforeSlot {
			t.Errorf("edge_delivery_slots binding changed after conflicting frame: before=%s after=%s (first binding must stay immutable)", beforeSlot, afterSlot)
		}
	})
}

// fixtureRowSnapshot counts every committed row one fixture's keys touch.
type fixtureRowSnapshot struct {
	Ledger, Slots, Batch, Rows int
}

// snapshotFixtureRows takes all four counts in one rpc call, so a probe that
// holds a delivery inside its CNPG transaction can snapshot while it holds.
func (h *harness) snapshotFixtureRows(t *testing.T, fx *FixtureRecord, spoolID []byte) fixtureRowSnapshot {
	t.Helper()
	expr := fmt.Sprintf(
		`[%q, %q, %q, %q] |> Enum.map(fn sql -> %%Postgrex.Result{rows: [[n]]} = ServiceRadar.Repo.query!(sql, []); n end) |> Enum.join(",") |> IO.puts()`,
		eventLedgerExistsSQL(fx.NetworkScopeID, fx.EventID),
		fmt.Sprintf(
			"SELECT count(*) FROM platform.edge_delivery_slots WHERE network_scope_id = %s AND spool_id = %s",
			uuidLiteral(fx.NetworkScopeID), uuidLiteral(spoolID),
		),
		fmt.Sprintf(
			"SELECT count(*) FROM platform.edge_sweep_batch_slots WHERE network_scope_id = %s AND execution_id = %s",
			uuidLiteral(fx.NetworkScopeID), uuidLiteral(fx.ExecutionID),
		),
		fmt.Sprintf(
			"SELECT count(*) FROM platform.edge_sweep_projected_rows WHERE network_scope_id = %s AND event_id = %s",
			uuidLiteral(fx.NetworkScopeID), uuidLiteral(fx.EventID),
		),
	)
	out, err := h.coreProc.RPC(expr, rpcTimeout)
	if err != nil {
		t.Fatalf("rpc fixture row snapshot: %v", err)
	}

	fields := strings.Split(strings.TrimSpace(out), ",")
	if len(fields) != 4 {
		t.Fatalf("rpc fixture row snapshot: unparsable output %q", out)
	}
	counts := make([]int, len(fields))
	for i, field := range fields {
		n, err := strconv.Atoi(field)
		if err != nil {
			t.Fatalf("rpc fixture row snapshot: unparsable output %q: %v", out, err)
		}
		counts[i] = n
	}
	return fixtureRowSnapshot{Ledger: counts[0], Slots: counts[1], Batch: counts[2], Rows: counts[3]}
}

// requireAcceptedAck fails t unless msg is an EdgeDeliveryAckV1 resolving
// sequence on spoolID as ACCEPTED_AUTHORITATIVE, the disposition the gateway
// writes only after a durable JetStream PubAck.
func requireAcceptedAck(t *testing.T, msg *edgev1.EdgeRecordServerMessage, spoolID []byte, sequence uint64) {
	t.Helper()
	ack := msg.GetAck()
	if ack == nil {
		t.Fatalf("expected an EdgeDeliveryAckV1, got %T", msg.GetPayload())
	}
	if !bytes.Equal(ack.GetSpoolId(), spoolID) || ack.GetResolvedThroughSequence() != sequence {
		t.Fatalf("ack spool_id/resolved_through_sequence = %x/%d, want %x/%d",
			ack.GetSpoolId(), ack.GetResolvedThroughSequence(), spoolID, sequence)
	}
	disps := ack.GetDispositions()
	if len(disps) != 1 || disps[0].GetSequence() != sequence ||
		disps[0].GetKind() != edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE {
		t.Fatalf("ack dispositions = %v, want one ACCEPTED_AUTHORITATIVE for sequence %d", disps, sequence)
	}
}

// edgeRecordStream opens the edge-record stream over a fresh NATS connection
// authenticated with the same .creds file the releases use. The connection
// closes when t ends.
func (h *harness) edgeRecordStream(t *testing.T) jetstream.Stream {
	t.Helper()
	nc, err := nats.Connect(h.nats.URL, nats.UserCredentials(h.nats.CredsPath))
	if err != nil {
		t.Fatalf("connect to nats: %v", err)
	}
	t.Cleanup(nc.Close)

	js, err := jetstream.New(nc)
	if err != nil {
		t.Fatalf("jetstream context: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), rpcTimeout)
	defer cancel()
	stream, err := js.Stream(ctx, edgeRecordStreamName)
	if err != nil {
		t.Fatalf("open stream %s: %v", edgeRecordStreamName, err)
	}
	return stream
}

// storedMessagesCarrying returns the stream sequence of every message stored
// in the edge-record stream whose body is exactly recordBytes.
func (h *harness) storedMessagesCarrying(t *testing.T, recordBytes []byte) []uint64 {
	t.Helper()
	stream := h.edgeRecordStream(t)
	ctx, cancel := context.WithTimeout(context.Background(), rpcTimeout)
	defer cancel()

	info, err := stream.Info(ctx)
	if err != nil {
		t.Fatalf("stream info: %v", err)
	}
	if info.State.Msgs == 0 {
		return nil
	}

	var seqs []uint64
	for seq := info.State.FirstSeq; seq <= info.State.LastSeq; seq++ {
		msg, err := stream.GetMsg(ctx, seq)
		if errors.Is(err, jetstream.ErrMsgNotFound) {
			continue
		}
		if err != nil {
			t.Fatalf("get stored message %d: %v", seq, err)
		}
		if bytes.Equal(msg.Data, recordBytes) {
			seqs = append(seqs, seq)
		}
	}
	return seqs
}

// requireOneStoredMessage fails t unless exactly one stored message carries
// recordBytes, and returns its stream sequence.
func (h *harness) requireOneStoredMessage(t *testing.T, recordBytes []byte) uint64 {
	t.Helper()
	seqs := h.storedMessagesCarrying(t, recordBytes)
	if len(seqs) != 1 {
		t.Fatalf("stream %s stores %d messages carrying this fixture's bytes (sequences %v), want exactly 1",
			edgeRecordStreamName, len(seqs), seqs)
	}
	return seqs[0]
}

// ---------------------------------------------------------------------------
// Ingest probe: observation and fault injection inside the core release.
//
// installIngestProbe starts an Agent registered as :vslice_edge_record_probe
// in the core node and installs the EdgeRecord processor's test-only hook
// (see "Test-only ingest hook" in ServiceRadar.EventWriter.Processors.
// EdgeRecord's moduledoc). Every hook call is recorded as (event_id, point,
// n), where n counts that event's calls at that point, so n == 2 at the same
// point is a second delivery of the event. A plan armed for one (event_id,
// point, n) makes that single call hold until released, raise, or both.
// Nothing here changes how the production consumer receives, NAKs or
// redelivers a message: a raise fails the batch the way any processor
// exception does.
// ---------------------------------------------------------------------------

const (
	probeBeforeCommit      = "before_commit"
	probeTransactionResult = "transaction_result"

	probeRaise         = "raise"
	probeHold          = "hold"
	probeHoldThenRaise = "hold_then_raise"
)

// ingestProbeInstallExpr is evaluated once in the core node. A hold that is
// never released (a failed subtest) ends after 60s, below the durable's 120s
// AckWait, so a stuck probe cannot wedge the consumer for the rest of the run.
const ingestProbeInstallExpr = `
if Process.whereis(:vslice_edge_record_probe) == nil do
  {:ok, _pid} = Agent.start(fn -> %{plans: %{}, obs: []} end, name: :vslice_edge_record_probe)
end

Application.put_env(:serviceradar_core, :edge_record_ingest_test_hook, fn point, event_id, result ->
  caller = self()

  {action, n} =
    Agent.get_and_update(:vslice_edge_record_probe, fn st ->
      n = Enum.count(st.obs, fn o -> o.event_id == event_id and o.point == point end) + 1
      obs = %{event_id: event_id, point: point, n: n, result: result, pid: caller}
      {{Map.get(st.plans, {event_id, point, n}, :pass), n}, %{st | obs: st.obs ++ [obs]}}
    end)

  if action in [:hold, :hold_then_raise] do
    receive do
      {:vslice_release, ^event_id, ^point, ^n} -> :ok
    after
      60_000 -> :ok
    end
  end

  if action in [:raise, :hold_then_raise] do
    raise "vertical_slice_test injected fault at #{point}, call #{n}"
  end

  :ok
end)

IO.puts("probe installed")
`

// ingestObservationsExpr prints one "obs|point|n|tag" line per recorded hook
// call for __EVENT_ID__, in call order.
const ingestObservationsExpr = `
id = Base.decode16!("__EVENT_ID__", case: :lower)

:vslice_edge_record_probe
|> Agent.get(fn st -> Enum.filter(st.obs, fn o -> o.event_id == id end) end)
|> Enum.each(fn o ->
  tag =
    case o.result do
      {:ok, outcome} ->
        "ok:#{outcome}"

      {:error, {:delivery_slot_conflict, %{record_sha256: sha}}} ->
        "error:delivery_slot_conflict:" <> Base.encode16(sha, case: :lower)

      other ->
        "other:" <> inspect(other, limit: 20)
    end

  IO.puts("obs|#{o.point}|#{o.n}|#{tag}")
end)
`

// ingestProbeReleaseExpr sends the release message to the process holding
// call __N__ at __POINT__ for __EVENT_ID__.
const ingestProbeReleaseExpr = `
id = Base.decode16!("__EVENT_ID__", case: :lower)

held =
  Agent.get(:vslice_edge_record_probe, fn st ->
    Enum.find(st.obs, fn o -> o.event_id == id and o.point == :__POINT__ and o.n == __N__ end)
  end)

case held do
  nil ->
    IO.puts("missing")

  o ->
    send(o.pid, {:vslice_release, id, o.point, o.n})
    IO.puts("released")
end
`

// ingestObservation is one recorded hook call. Tag is "ok:<outcome>",
// "error:delivery_slot_conflict:<hex record_sha256 of the existing binding>",
// or "other:<inspected result>".
type ingestObservation struct {
	Point string
	N     int
	Tag   string
}

func (h *harness) installIngestProbe(t *testing.T) {
	t.Helper()
	out, err := h.coreProc.RPC(ingestProbeInstallExpr, rpcTimeout)
	if err != nil {
		t.Fatalf("install ingest probe: %v", err)
	}
	if out != "probe installed" {
		t.Fatalf("install ingest probe: unexpected output %q", out)
	}
}

func (h *harness) armIngestProbe(t *testing.T, eventID []byte, point string, n int, action string) {
	t.Helper()
	expr := fmt.Sprintf(
		`Agent.update(:vslice_edge_record_probe, fn st -> %%{st | plans: Map.put(st.plans, {Base.decode16!(%q, case: :lower), :%s, %d}, :%s)} end); IO.puts("armed")`,
		hex.EncodeToString(eventID), point, n, action,
	)
	out, err := h.coreProc.RPC(expr, rpcTimeout)
	if err != nil || out != "armed" {
		t.Fatalf("arm ingest probe (%s call %d -> %s): output %q, err %v", point, n, action, out, err)
	}
}

func (h *harness) releaseIngestProbe(t *testing.T, eventID []byte, point string, n int) {
	t.Helper()
	expr := strings.NewReplacer(
		"__EVENT_ID__", hex.EncodeToString(eventID), "__POINT__", point, "__N__", strconv.Itoa(n),
	).Replace(ingestProbeReleaseExpr)
	out, err := h.coreProc.RPC(expr, rpcTimeout)
	if err != nil || out != "released" {
		t.Fatalf("release ingest probe (%s call %d): output %q, err %v", point, n, out, err)
	}
}

func (h *harness) ingestObservations(t *testing.T, eventID []byte) []ingestObservation {
	t.Helper()
	expr := strings.ReplaceAll(ingestObservationsExpr, "__EVENT_ID__", hex.EncodeToString(eventID))
	out, err := h.coreProc.RPC(expr, rpcTimeout)
	if err != nil {
		t.Fatalf("read ingest probe observations: %v", err)
	}

	var obs []ingestObservation
	for _, line := range strings.Split(out, "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), "|", 4)
		if len(parts) != 4 || parts[0] != "obs" {
			continue
		}
		n, err := strconv.Atoi(parts[2])
		if err != nil {
			t.Fatalf("unparsable ingest probe line %q: %v", line, err)
		}
		obs = append(obs, ingestObservation{Point: parts[1], N: n, Tag: parts[3]})
	}
	return obs
}

// waitIngestObservation polls until the probe has recorded call n at point
// for eventID, and fails t if EventWriter never gets there.
func (h *harness) waitIngestObservation(t *testing.T, eventID []byte, point string, n int) ingestObservation {
	t.Helper()
	deadline := time.Now().Add(pollTimeout)
	for {
		seen := h.ingestObservations(t, eventID)
		for _, o := range seen {
			if o.Point == point && o.N == n {
				return o
			}
		}
		if !time.Now().Before(deadline) {
			t.Fatalf("EventWriter never reached %s call %d for event %x within %s (observed %+v); see %s in this test's undeclared outputs",
				point, n, eventID, pollTimeout, seen, h.preservedLogName(h.coreProc.stderrPath))
		}
		time.Sleep(pollInterval)
	}
}

// ---------------------------------------------------------------------------
// Group D: failure and watermark order.
//
//  1. NATSCutAfterSpoolCommit disables JetStream on the embedded broker,
//     commits a fresh entry to the agent's spool, and reads the real agent's
//     own sender log. The broker and every client connection stay up, so the
//     gateway keeps opening lanes and what fails is the JetStream publish
//     itself. At least one failed sender run must have sent the entry, and no
//     sender run in the outage may report a remote resolved prefix covering
//     it, which means the gateway withheld its durability ack. The entry
//     stays above the local reclaim watermark, readable on the spool, and
//     absent from CNPG until JetStream is re-enabled. Then it lands.
//  2. RedeliveryAfterEventWriterRollback publishes a fresh fixture. The ingest
//     probe raises inside its FIRST CNPG transaction, after every write
//     succeeded, so the transaction really rolls back. EventWriter must not
//     ACK it: the probe sees a second delivery of the SAME stored message and
//     holds it inside its transaction. The hold keeps a pooled connection
//     checked out, and DBConnection disconnects a checkout older than the
//     repo timeout, so only broker reads and one snapshot rpc run while it is
//     held: no committed rows, and the durable's ack floor still below the
//     message. Once released, the probe must have recorded exactly two
//     deliveries reaching commit and one transaction result, :inserted, so
//     the released delivery is the one that committed. The ack floor then
//     passes the message.
//  3. RedeliveryAfterCoreKill appends a fresh entry to the agent's spool, lets
//     the agent publish it, SIGKILLs the core release before it can ack the
//     message, restarts core, and waits for the fixture to land. It is the
//     only coverage here of core crashing before it acknowledges and then
//     consuming again after a restart. The kill races EventWriter, so it does
//     not prove the message was still unacknowledged when core died. The
//     replacement core gets the ingest probe reinstalled.
//  4. PositiveAckDoesNotReclaimSpool reads the gateway's EdgeDeliveryAckV1s on
//     a real session and checks their spool-ID/session-nonce binding and
//     cumulative resolved_through_sequence with the agent's own
//     edgerecord.ValidateAck. It waits for the real agent to report a remote
//     resolved prefix covering every spool entry. Then it confirms neither
//     one moved the agent's local reclaim watermark or removed a record from
//     the spool's public read path.
//
// ---------------------------------------------------------------------------
func (h *harness) testGroupD(t *testing.T) {
	fx := h.groupAFixture
	if fx == nil {
		t.Skip("Group A fixture unavailable")
	}

	t.Run("NATSCutAfterSpoolCommit", func(t *testing.T) {
		// Disable JetStream FIRST, then commit a fresh entry, so every sender
		// run that can carry the entry runs into the outage.
		if err := h.nats.DisableJetStream(); err != nil {
			t.Fatalf("disable jetstream: %v", err)
		}
		cutAt := h.agent.logOffset(t)

		fx2, err := BuildSweepFixture([]byte(h.certSet.AgentComponentID))
		if err != nil {
			t.Fatalf("build fixture: %v", err)
		}
		seq, err := h.sp.Append(fx2.EventID, fx2.RecordBytes)
		if err != nil {
			t.Fatalf("append: %v", err)
		}

		h.waitAgentSenderRuns(t, cutAt, natsCutTimeout,
			fmt.Sprintf("a failed sender run that sent sequence %d during the JetStream outage", seq),
			func(runs []agentSenderRun) bool {
				for _, run := range runs {
					if run.Failed && run.HighestSent >= seq {
						return true
					}
				}
				return false
			})

		// Every run that ended during the outage, re-read just before
		// JetStream returns so no run in the window goes unchecked.
		for _, run := range h.agentSenderRuns(t, cutAt) {
			if run.RemoteResolvedThrough >= seq {
				t.Errorf("agent reported remote_resolved_through=%d covering withheld sequence %d during the JetStream outage (%+v); the gateway acknowledged an entry it could not have made durable",
					run.RemoteResolvedThrough, seq, run)
			}
		}
		h.requireSpoolEntryUnreclaimed(t, seq)
		if n := h.rpcQueryCount(t, eventLedgerExistsSQL(fx2.NetworkScopeID, fx2.EventID)); n != 0 {
			t.Errorf("event_ledger row appeared for an entry that should have been withheld by a JetStream outage")
		}

		if err := h.nats.EnableJetStream(); err != nil {
			t.Fatalf("re-enable jetstream after cut probe: %v", err)
		}

		deadline := time.Now().Add(natsCutTimeout)
		var landed int
		for time.Now().Before(deadline) {
			landed = h.rpcQueryCount(t, eventLedgerExistsSQL(fx2.NetworkScopeID, fx2.EventID))
			if landed == 1 {
				break
			}
			time.Sleep(pollInterval)
		}
		if landed != 1 {
			t.Fatalf("withheld entry never landed in event_ledger within %s after JetStream was re-enabled (count=%d); the gateway or core did not recover, so the rest of Group D, E and F cannot run against a live pipeline -- see %s, %s and %s in this test's undeclared outputs",
				natsCutTimeout, landed,
				h.preservedLogName(h.agent.stdoutPath), h.preservedLogName(h.gwProc.stderrPath), h.preservedLogName(h.coreProc.stderrPath))
		}
	})

	t.Run("RedeliveryAfterEventWriterRollback", func(t *testing.T) {
		h.requireJetStream(t)

		fx3, err := BuildSweepFixture([]byte(h.certSet.AgentComponentID))
		if err != nil {
			t.Fatalf("build fixture: %v", err)
		}
		spoolID, err := edgerecord.NewUUIDv7()
		if err != nil {
			t.Fatalf("spool id: %v", err)
		}
		tlsCfg, err := h.certSet.AgentTLSConfig(h.gatewayServerName)
		if err != nil {
			t.Fatalf("agent tls config: %v", err)
		}

		h.armIngestProbe(t, fx3.EventID, probeBeforeCommit, 1, probeRaise)
		h.armIngestProbe(t, fx3.EventID, probeBeforeCommit, 2, probeHold)

		ack, err := h.sendOneRawFrame(t, tlsCfg, spoolID, 1, fx3.RecordBytes, fx3.RecordSHA256, 20*time.Second)
		if err != nil {
			t.Fatalf("send fixture: %v", err)
		}
		requireAcceptedAck(t, ack, spoolID, 1)

		h.waitIngestObservation(t, fx3.EventID, probeBeforeCommit, 2)

		storedSeq := h.requireOneStoredMessage(t, fx3.RecordBytes)
		heldFloor := h.edgeRecordAckFloor(t)
		held := h.snapshotFixtureRows(t, fx3, spoolID)
		h.releaseIngestProbe(t, fx3.EventID, probeBeforeCommit, 2)

		if heldFloor >= storedSeq {
			t.Errorf("durable ack floor %d reached stream sequence %d before any delivery committed; EventWriter acknowledged a rolled-back message", heldFloor, storedSeq)
		}
		if held != (fixtureRowSnapshot{}) {
			t.Errorf("committed rows while the redelivery is held = %+v, want none: the first transaction must have rolled back", held)
		}

		h.waitIngestObservation(t, fx3.EventID, probeTransactionResult, 1)
		wantObservations := []ingestObservation{
			{Point: probeBeforeCommit, N: 1, Tag: "ok:inserted"},
			{Point: probeBeforeCommit, N: 2, Tag: "ok:inserted"},
			{Point: probeTransactionResult, N: 1, Tag: "ok:inserted"},
		}
		if got := h.ingestObservations(t, fx3.EventID); !slices.Equal(got, wantObservations) {
			t.Fatalf("ingest probe recorded %+v, want %+v: only the first delivery may abort inside its transaction, and the released redelivery must be the one that commits", got, wantObservations)
		}
		want := fixtureRowSnapshot{Ledger: 1, Slots: 1, Batch: 1, Rows: fx3.ProjectedRowCount}
		if got := h.snapshotFixtureRows(t, fx3, spoolID); got != want {
			t.Errorf("snapshot after the redelivery committed = %+v, want %+v", got, want)
		}
		h.assertCommittedFixtureValues(t, fx3, spoolID, 1)

		deadline := time.Now().Add(pollTimeout)
		floor := h.edgeRecordAckFloor(t)
		for floor < storedSeq && time.Now().Before(deadline) {
			time.Sleep(pollInterval)
			floor = h.edgeRecordAckFloor(t)
		}
		if floor < storedSeq {
			t.Errorf("durable ack floor %d never reached stream sequence %d within %s after the redelivery committed", floor, storedSeq, pollTimeout)
		}
	})

	t.Run("RedeliveryAfterCoreKill", func(t *testing.T) {
		h.requireJetStream(t)

		fx4, err := BuildSweepFixture([]byte(h.certSet.AgentComponentID))
		if err != nil {
			t.Fatalf("build fixture: %v", err)
		}
		if _, err := h.sp.Append(fx4.EventID, fx4.RecordBytes); err != nil {
			t.Fatalf("append: %v", err)
		}

		// Let the agent get it published to NATS (gateway ack does not
		// depend on core being alive), then SIGKILL core before it can
		// process/ack it. This is deliberately NOT ReleaseProcess.Stop:
		// Stop runs the release's graceful `stop` first, which drains the
		// EventWriter and commits fx4 before exit, so the redelivery path
		// would never execute. The SIGKILLed process is reaped by the
		// Stop cleanup newHarness registered for it.
		time.Sleep(3 * agentPollInterval)
		if h.coreProc == nil || h.coreProc.cmd == nil || h.coreProc.cmd.Process == nil {
			t.Fatal("core release has no OS process to SIGKILL")
		}
		if err := h.coreProc.cmd.Process.Kill(); err != nil {
			t.Fatalf("SIGKILL core release: %v", err)
		}

		coreTarPath := mustRlocation(t, coreReleaseTarRlocation)
		restarted, err := StartRelease(
			coreTarPath, "serviceradar_core_elx", filepath.Join(h.dir, "core-restart"),
			h.coreEnv, fmt.Sprintf("http://127.0.0.1:%d/health", h.coreEnv.MetricsPort), 90*time.Second,
		)
		if err != nil {
			t.Fatalf("restart core release: %v", err)
		}
		// Registered on the HARNESS test, not this subtest: a subtest-scoped
		// Cleanup would stop the replacement core the moment this subtest
		// returns, and every later query (PositiveAckDoesNotReclaimSpool,
		// Groups E and F) would then hit a node that no longer exists.
		h.t.Cleanup(restarted.Stop)
		h.coreProc = restarted
		h.installIngestProbe(t)

		deadline := time.Now().Add(pollTimeout)
		var n int
		for time.Now().Before(deadline) {
			n = h.rpcQueryCount(t, eventLedgerExistsSQL(fx4.NetworkScopeID, fx4.EventID))
			if n == 1 {
				break
			}
			time.Sleep(pollInterval)
		}
		if n != 1 {
			t.Errorf("fixture was not redelivered/processed after core restarted (count=%d)", n)
		}
	})

	t.Run("PositiveAckDoesNotReclaimSpool", func(t *testing.T) {
		agentOffset := h.agent.logOffset(t)

		h.assertCumulativeDeliveryAck(t)

		highest := h.sp.NextSequence() - 1
		h.waitAgentSenderRuns(t, agentOffset, pollTimeout,
			fmt.Sprintf("a successful sender run with remote_resolved_through >= %d", highest),
			func(runs []agentSenderRun) bool {
				for _, run := range runs {
					if !run.Failed && run.RemoteResolvedThrough >= highest {
						return true
					}
				}
				return false
			})

		// The gateway's acks and the agent's remote prefix are remote progress
		// only: neither may physically reclaim the local spool.
		freshSp, err := spool.Open(h.agent.SpoolDir)
		if err != nil {
			t.Fatalf("reopen spool: %v", err)
		}
		resolved := freshSp.Resolved()
		_ = freshSp.Close()
		if resolved != 0 {
			t.Errorf("spool local watermark advanced to %d even though nothing in this harness ever calls spool.Resolve -- ack alone must never physically reclaim the spool", resolved)
		}
		for seq := uint64(1); seq <= highest; seq++ {
			h.requireSpoolEntryUnreclaimed(t, seq)
		}

		if n := h.rpcQueryCount(t, eventLedgerExistsSQL(h.groupAFixture.NetworkScopeID, h.groupAFixture.EventID)); n != 1 {
			t.Errorf("expected Group A's fixture to still be committed (remote progress), got count=%d", n)
		}
	})
}

// assertCumulativeDeliveryAck opens a real lane with a random session nonce,
// sends two fresh fixtures on it, and checks each EdgeDeliveryAckV1 the
// gateway writes with edgerecord.ValidateAck, the agent's own check of the
// spool-ID/session-nonce binding and the cumulative watermark window. Each
// ack must resolve exactly through its frame's sequence as
// ACCEPTED_AUTHORITATIVE, and the record must already be stored in JetStream
// when the ack arrives.
func (h *harness) assertCumulativeDeliveryAck(t *testing.T) {
	t.Helper()

	tlsCfg, err := h.certSet.AgentTLSConfig(h.gatewayServerName)
	if err != nil {
		t.Fatalf("agent tls config: %v", err)
	}
	spoolID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("spool id: %v", err)
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatalf("session nonce: %v", err)
	}

	conn, err := grpc.NewClient(h.gatewayAddr, grpc.WithTransportCredentials(credentials.NewTLS(tlsCfg)))
	if err != nil {
		t.Fatalf("dial gateway: %v", err)
	}
	defer func() { _ = conn.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), rpcTimeout)
	defer cancel()
	stream, err := edgev1.NewEdgeRecordIngestServiceClient(conn).Stream(ctx)
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}

	open := &edgev1.EdgeRecordLaneOpen{
		RouteProfile:            edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:            edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		SpoolId:                 spoolID,
		SequenceBase:            1,
		FirstUnresolvedSequence: 1,
		SessionNonce:            nonce,
		RequestedByteCredits:    1 << 20,
		RequestedFrameCredits:   8,
	}
	if err := stream.Send(&edgev1.EdgeRecordClientMessage{Payload: &edgev1.EdgeRecordClientMessage_LaneOpen{LaneOpen: open}}); err != nil {
		t.Fatalf("send lane_open: %v", err)
	}
	openMsg, err := stream.Recv()
	if err != nil {
		t.Fatalf("recv lane_open_ack: %v", err)
	}
	if err := edgerecord.ValidateLaneOpenAck(openMsg.GetLaneOpenAck(), open); err != nil {
		t.Fatalf("lane_open_ack failed the agent's own validation: %v", err)
	}

	sess := edgerecord.Session{
		RouteProfile:    open.GetRouteProfile(),
		TrafficClass:    open.GetTrafficClass(),
		SpoolID:         spoolID,
		Nonce:           nonce,
		FirstUnresolved: 1,
		NextSequence:    1,
		SentEvents:      make(map[uint64][]byte),
	}

	for seq := uint64(1); seq <= 2; seq++ {
		fxN, err := BuildSweepFixture([]byte(h.certSet.AgentComponentID))
		if err != nil {
			t.Fatalf("build fixture %d: %v", seq, err)
		}
		frame := &edgev1.EdgeDeliveryFrameV1{
			SpoolId:      spoolID,
			Sequence:     seq,
			RecordSha256: fxN.RecordSHA256,
			RecordBytes:  fxN.RecordBytes,
		}
		if err := stream.Send(&edgev1.EdgeRecordClientMessage{Payload: &edgev1.EdgeRecordClientMessage_DeliveryFrame{DeliveryFrame: frame}}); err != nil {
			t.Fatalf("send delivery_frame %d: %v", seq, err)
		}
		sess.SentEvents[seq] = fxN.EventID
		sess.HighestSent = seq
		sess.NextSequence = seq + 1

		msg, err := stream.Recv()
		if err != nil {
			t.Fatalf("recv ack for sequence %d: %v", seq, err)
		}
		if err := edgerecord.ValidateAck(msg.GetAck(), sess, 0, 0); err != nil {
			t.Fatalf("gateway ack for sequence %d failed the agent's own ack validation: %v", seq, err)
		}
		requireAcceptedAck(t, msg, spoolID, seq)
		sess.ResolvedThrough = msg.GetAck().GetResolvedThroughSequence()

		h.requireOneStoredMessage(t, fxN.RecordBytes)
	}
	_ = stream.CloseSend()
}

// edgeRecordAckFloor returns the stream sequence through which the
// EventWriter's durable consumer on the edge-record stream has acknowledged
// every message. The harness reads with direct gets only, so that durable is
// the stream's one consumer.
func (h *harness) edgeRecordAckFloor(t *testing.T) uint64 {
	t.Helper()
	stream := h.edgeRecordStream(t)
	ctx, cancel := context.WithTimeout(context.Background(), rpcTimeout)
	defer cancel()

	lister := stream.ListConsumers(ctx)
	var consumers []*jetstream.ConsumerInfo
	for info := range lister.Info() {
		consumers = append(consumers, info)
	}
	if err := lister.Err(); err != nil {
		t.Fatalf("list consumers on %s: %v", edgeRecordStreamName, err)
	}
	if len(consumers) != 1 {
		names := make([]string, len(consumers))
		for i, c := range consumers {
			names[i] = c.Name
		}
		t.Fatalf("stream %s has consumers %v, want exactly EventWriter's durable", edgeRecordStreamName, names)
	}
	return consumers[0].AckFloor.Stream
}

// requireJetStream fails t when the broker has JetStream off, which only a
// cut probe that stopped before re-enabling it leaves behind.
func (h *harness) requireJetStream(t *testing.T) {
	t.Helper()
	if !h.nats.Server.JetStreamEnabled() {
		t.Fatalf("JetStream is unavailable when %s runs -- NATSCutAfterSpoolCommit must re-enable it via NATSHarness.EnableJetStream; a missing JetStream must fail loudly, never skip", t.Name())
	}
}

// requireSpoolEntryUnreclaimed reopens the agent's spool and fails t unless
// sequence is still above the local reclaim watermark and readable through
// the spool's public read path.
func (h *harness) requireSpoolEntryUnreclaimed(t *testing.T, sequence uint64) {
	t.Helper()
	sp, err := spool.Open(h.agent.SpoolDir)
	if err != nil {
		t.Fatalf("reopen spool: %v", err)
	}
	defer func() { _ = sp.Close() }()

	if resolved := sp.Resolved(); resolved >= sequence {
		t.Errorf("local reclaim watermark %d covers sequence %d; the entry was reclaimed", resolved, sequence)
	}
	found := false
	if err := sp.ScanFrom(0, func(rec spool.Record) bool {
		found = rec.Sequence == sequence
		return !found
	}); err != nil {
		t.Fatalf("scan spool: %v", err)
	}
	if !found {
		t.Errorf("sequence %d is no longer on the spool's public read path", sequence)
	}
}

// ---------------------------------------------------------------------------
// Agent sender log: the real agent's remote resolved prefix.
//
// go/pkg/edge/sender keeps the gateway-acknowledged prefix in memory only,
// and go/cmd/agent logs it (remote_resolved_through), with the highest
// sequence the run sent (highest_sent), once at the end of every sender run,
// successful or failed. The agent writes zerolog JSON, one object per line,
// to its stdout log.
// ---------------------------------------------------------------------------

const (
	agentSenderDrainedMessage = "Edge record sender drained spool lane"
	agentSenderFailedMessage  = "Edge record sender run failed"

	// natsCutTimeout bounds the JetStream outage's waits: for a failed sender
	// run that sent the withheld entry, and for that entry to land once
	// JetStream is back. A run whose publishes time out at the gateway takes
	// several seconds to fail.
	natsCutTimeout = 60 * time.Second
)

var (
	errAgentLogShorterThanOffset = errors.New("agent log is shorter than the requested offset")
	errSenderRunMissingPrefix    = errors.New("sender run line lacks highest_sent/remote_resolved_through")
)

// agentSenderRun is one sender run the agent logged when it ended.
type agentSenderRun struct {
	Failed                bool
	HighestSent           uint64
	RemoteResolvedThrough uint64
	Err                   string
}

// logOffset is the current size of the agent's stdout log.
func (p *AgentProcess) logOffset(t *testing.T) int64 {
	t.Helper()
	info, err := os.Stat(p.stdoutPath)
	if err != nil {
		t.Fatalf("stat agent log: %v", err)
	}
	return info.Size()
}

// senderRuns parses every sender run whose line the agent finished writing
// after offset. A run line without highest_sent or remote_resolved_through is
// an error: they are the observation, so an agent that stops logging them
// must fail the test rather than satisfy it vacuously.
func (p *AgentProcess) senderRuns(offset int64) ([]agentSenderRun, error) {
	data, err := os.ReadFile(p.stdoutPath)
	if err != nil {
		return nil, err
	}
	if offset > int64(len(data)) {
		return nil, fmt.Errorf("%w: %d bytes, offset %d", errAgentLogShorterThanOffset, len(data), offset)
	}
	data = data[offset:]
	data = data[:bytes.LastIndexByte(data, '\n')+1]

	var runs []agentSenderRun
	for _, line := range bytes.Split(data, []byte("\n")) {
		var entry struct {
			Message               string  `json:"message"`
			HighestSent           *uint64 `json:"highest_sent"`
			RemoteResolvedThrough *uint64 `json:"remote_resolved_through"`
			Error                 string  `json:"error"`
		}
		if json.Unmarshal(line, &entry) != nil {
			continue
		}
		if entry.Message != agentSenderDrainedMessage && entry.Message != agentSenderFailedMessage {
			continue
		}
		if entry.HighestSent == nil || entry.RemoteResolvedThrough == nil {
			return nil, fmt.Errorf("%w: %s", errSenderRunMissingPrefix, line)
		}
		runs = append(runs, agentSenderRun{
			Failed:                entry.Message == agentSenderFailedMessage,
			HighestSent:           *entry.HighestSent,
			RemoteResolvedThrough: *entry.RemoteResolvedThrough,
			Err:                   entry.Error,
		})
	}
	return runs, nil
}

func (h *harness) agentSenderRuns(t *testing.T, offset int64) []agentSenderRun {
	t.Helper()
	runs, err := h.agent.senderRuns(offset)
	if err != nil {
		t.Fatalf("read agent sender runs: %v", err)
	}
	return runs
}

// waitAgentSenderRuns polls the agent's log until done accepts the runs
// logged after offset, and fails t with what was seen if it never does.
func (h *harness) waitAgentSenderRuns(
	t *testing.T, offset int64, timeout time.Duration, what string, done func([]agentSenderRun) bool,
) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		runs := h.agentSenderRuns(t, offset)
		if done(runs) {
			return
		}
		if !time.Now().Before(deadline) {
			t.Fatalf("agent never logged %s within %s (runs after offset: %+v); see %s in this test's undeclared outputs",
				what, timeout, runs, h.preservedLogName(h.agent.stdoutPath))
		}
		time.Sleep(pollInterval)
	}
}

// ---------------------------------------------------------------------------
// Ledger observation for Groups E and F.
//
// Both groups read the gateway's :bulk lane accountant
// (ServiceRadar.Edge.PublisherPool.ledger/1) through ONE long-running rpc
// watcher inside the gateway node (ledgerwatch.go), and hold a real publish
// request in flight by withholding the broker's bytes at the NATS proxy the
// gateway connects through (natsproxy.go). The claims are then decided over
// the watcher's trace by analyzeRestartOverlap / analyzePostHandoffFencing,
// whose ability to fail is proven in ledgerwatch_selfcheck_test.go.
// ---------------------------------------------------------------------------

const (
	// ledgerWatchDeadline bounds a watcher nothing stops -- a subtest that
	// failed before stopping it. A passing subtest stops it far sooner.
	ledgerWatchDeadline = 120 * time.Second
	// inFlightTimeout bounds a wait on a held request: JetStreamPublisher's
	// 5s receive timeout, plus slack for a loaded executor.
	inFlightTimeout = 15 * time.Second

	groupEReadmittedEvent = "readmitted"
	groupFRetryEvent      = "retry-refused"
)

type ledgerWatcher struct {
	name   string
	dir    string
	result chan ledgerWatchResult
	done   *ledgerWatchResult
}

type ledgerWatchResult struct {
	out string
	err error
}

type frameResult struct {
	msg *edgev1.EdgeRecordServerMessage
	err error
}

// startLedgerWatcher starts a watcher over watched (see
// buildLedgerWatchExpr) and returns once it is sampling.
func (h *harness) startLedgerWatcher(t *testing.T, name string, watched, killWhenActive [][]byte) *ledgerWatcher {
	t.Helper()

	w := &ledgerWatcher{
		name:   name,
		dir:    filepath.Join(h.dir, "ledger-watch-"+name),
		result: make(chan ledgerWatchResult, 1),
	}
	if err := os.MkdirAll(w.dir, 0o700); err != nil {
		t.Fatalf("ledger watcher %s: mkdir: %v", name, err)
	}

	expr := buildLedgerWatchExpr(w.dir, watched, killWhenActive, ledgerWatchDeadline.Milliseconds())
	gw := h.gwProc
	go func() {
		out, err := gw.RPC(expr, ledgerWatchDeadline+rpcTimeout)
		w.result <- ledgerWatchResult{out: out, err: err}
	}()
	// A subtest that fails early must not leave the watcher sampling until
	// its deadline, into the next group.
	t.Cleanup(func() { _ = os.WriteFile(filepath.Join(w.dir, ledgerStopFile), nil, 0o600) })

	if err := w.waitMarker(ledgerMarkerReady, rpcTimeout); err != nil {
		t.Fatalf("ledger watcher %s did not start: %v", name, err)
	}
	return w
}

// waitMarker waits for the watcher to write marker, and fails at once if the
// watcher has already exited without writing it.
func (w *ledgerWatcher) waitMarker(marker string, timeout time.Duration) error {
	path := filepath.Join(w.dir, marker)
	deadline := time.Now().Add(timeout)
	for {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		if w.done == nil {
			select {
			case r := <-w.result:
				w.done = &r
			default:
			}
		}
		if w.done != nil {
			if _, err := os.Stat(path); err == nil {
				return nil
			}
			if w.done.err != nil {
				return fmt.Errorf("%w %q: %w; output=%s", errLedgerWatchExited, marker, w.done.err, w.done.out)
			}
			return fmt.Errorf("%w %q; output=%s", errLedgerWatchExited, marker, w.done.out)
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("%w: %q within %s", errLedgerMarkerWait, marker, timeout)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// record tells the watcher an action has finished and waits until the event
// is in the trace, so anything the test does next is ordered after it.
func (w *ledgerWatcher) record(t *testing.T, event string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(w.dir, ledgerEventPrefix+event), nil, 0o600); err != nil {
		t.Fatalf("ledger watcher %s: signal %s: %v", w.name, event, err)
	}
	if err := w.waitMarker(ledgerMarkerRecorded+event, rpcTimeout); err != nil {
		t.Fatalf("ledger watcher %s never recorded %s: %v", w.name, event, err)
	}
}

// stop ends the watch and returns its trace and raw output.
func (w *ledgerWatcher) stop(t *testing.T) (*ledgerTrace, string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(w.dir, ledgerStopFile), nil, 0o600); err != nil {
		t.Fatalf("ledger watcher %s: stop: %v", w.name, err)
	}
	if w.done == nil {
		select {
		case r := <-w.result:
			w.done = &r
		case <-time.After(rpcTimeout):
			t.Fatalf("ledger watcher %s did not exit within %s of being stopped", w.name, rpcTimeout)
		}
	}
	if w.done.err != nil {
		t.Fatalf("ledger watcher %s failed: %v", w.name, w.done.err)
	}
	tr, err := parseLedgerTrace(w.done.out)
	if err != nil && !errors.Is(err, errLedgerWatchTimeout) {
		t.Fatalf("ledger watcher %s: %v\noutput: %s", w.name, err, w.done.out)
	}
	return tr, w.done.out
}

func ledgerMarker(prefix string, spoolID []byte) string {
	return prefix + hex.EncodeToString(spoolID)
}

// freshPublication is a new fixture on its own fresh spool id: a publication
// no earlier group has touched.
func (h *harness) freshPublication(t *testing.T) (*FixtureRecord, []byte) {
	t.Helper()
	fx, err := BuildSweepFixture([]byte(h.certSet.AgentComponentID))
	if err != nil {
		t.Fatalf("build fixture: %v", err)
	}
	spoolID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("spool id: %v", err)
	}
	return fx, spoolID
}

func (h *harness) sendPublication(t *testing.T, tlsCfg *tls.Config, spoolID []byte, fx *FixtureRecord, timeout time.Duration) frameResult {
	t.Helper()
	msg, err := h.sendOneRawFrame(t, tlsCfg, spoolID, 1, fx.RecordBytes, fx.RecordSHA256, timeout)
	return frameResult{msg: msg, err: err}
}

// acceptedAck reports whether msg resolves sequence 1 -- the only sequence
// Groups E and F send, each publication on its own fresh spool id --
// ACCEPTED_AUTHORITATIVE.
func acceptedAck(msg *edgev1.EdgeRecordServerMessage) bool {
	for _, d := range msg.GetAck().GetDispositions() {
		if d.GetSequence() == 1 &&
			d.GetKind() == edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE {
			return true
		}
	}
	return false
}

// sendUntilAccepted re-sends one publication until the gateway accepts it.
// Only outcomes that published nothing are retried: a lane_open refused
// Unavailable while the lane's capability is not ready, and a stream that
// ended with no acknowledgement because the publish did not resolve (for
// example a replacement connection not yet registered). Neither leaves a
// request outstanding, and the broker deduplicates a republish.
func (h *harness) sendUntilAccepted(t *testing.T, tlsCfg *tls.Config, spoolID []byte, fx *FixtureRecord, timeout time.Duration) error {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		r := h.sendPublication(t, tlsCfg, spoolID, fx, 20*time.Second)
		if acceptedAck(r.msg) {
			return nil
		}
		retryable := status.Code(r.err) == codes.Unavailable || (r.msg == nil && errors.Is(r.err, io.EOF))
		if !retryable || !time.Now().Before(deadline) {
			return fmt.Errorf("not accepted within %s: msg=%v err=%w", timeout, r.msg, r.err)
		}
		time.Sleep(pollInterval)
	}
}

// awaitSingleLedgerRow waits for fx's event_ledger row and reports its count.
func (h *harness) awaitSingleLedgerRow(t *testing.T, fx *FixtureRecord) int {
	t.Helper()
	deadline := time.Now().Add(pollTimeout)
	var n int
	for time.Now().Before(deadline) {
		n = h.rpcQueryCount(t, eventLedgerExistsSQL(fx.NetworkScopeID, fx.EventID))
		if n == 1 {
			break
		}
		time.Sleep(pollInterval)
	}
	return n
}

// ---------------------------------------------------------------------------
// Group E: restart overlap.
//
// Task 0.12: "While one publish request is in flight, restart the lane
// publisher/pool and prove replacement state does not reopen capacity still
// occupied by that request. After that request's termination is observed,
// the replacement SHALL admit work within the original grant."
//
// The lane's restart unit is its TRANSPORT generation: LaneSupervisor keeps
// the accountant stable and replaces the transport (:rest_for_one, accountant
// first), so killing ServiceRadar.Edge.LaneTransportRuntime.via(:bulk) is the
// restart. The accountant being replaced instead would show up as a changed
// pool pid, which the analyzer rejects.
//
//  1. Three publications are sent with the broker's PubAcks withheld, so all
//     three requests stay outstanding. The watcher kills the transport the
//     moment it sees all three attempts active.
//  2. The watcher trace must then show a REPLACEMENT generation accepting
//     while all three request owners are still alive, with the SAME
//     accountant still charging all three reservations -- available frames
//     at most grant-3, bytes still outstanding -- and none of those attempts
//     on the replacement.
//  3. Each owner's exit (termination) is observed with its charge still held.
//  4. With the replacement proven able to publish, PubAcks are withheld
//     again while one terminated publication is re-sent and new work is
//     sent beside it. The ledger must show the retry as a NEW attempt on the
//     SAME reservation (never released in between, so no second credit) and
//     the new work admitted, with every earlier charge still counted and the
//     grant unchanged. Both are then accepted.
//  5. Every publication settles and lands in CNPG exactly once.
//
// ---------------------------------------------------------------------------
func (h *harness) testGroupE(t *testing.T) {
	h.requireJetStream(t)

	tlsCfg, err := h.certSet.AgentTLSConfig(h.gatewayServerName)
	if err != nil {
		t.Fatalf("agent tls config: %v", err)
	}

	const inFlight = 3
	fxs := make([]*FixtureRecord, inFlight)
	spools := make([][]byte, inFlight)
	for i := range fxs {
		fxs[i], spools[i] = h.freshPublication(t)
	}
	newWork, newWorkSpool := h.freshPublication(t)
	probe, probeSpool := h.freshPublication(t)

	w := h.startLedgerWatcher(t, "group-e", append(append([][]byte{}, spools...), newWorkSpool), spools)

	stalled := false
	stall := func() {
		if n := h.gwNATS.StallServerToClient(); n == 0 {
			t.Fatal("the gateway holds no NATS connection through the proxy; nothing can be held in flight")
		}
		stalled = true
	}
	resume := func() {
		if stalled {
			h.gwNATS.Resume()
			stalled = false
		}
	}
	defer resume()

	// (1) Hold three requests in flight; the watcher kills the transport.
	stall()
	results := make([]frameResult, inFlight)
	var wg sync.WaitGroup
	for i := range fxs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i] = h.sendPublication(t, tlsCfg, spools[i], fxs[i], 30*time.Second)
		}(i)
	}

	// (2, 3) Replacement accepting, then every owner's termination.
	waits := make([]string, 0, 2+len(spools))
	waits = append(waits, ledgerMarkerKilled, ledgerMarkerReplacementAccepted)
	for _, s := range spools {
		waits = append(waits, ledgerMarker(ledgerMarkerOwnerExited, s))
	}
	for _, m := range waits {
		if err := w.waitMarker(m, inFlightTimeout); err != nil {
			t.Fatalf("restart overlap: %v", err)
		}
	}
	wg.Wait()
	for i, r := range results {
		if acceptedAck(r.msg) {
			t.Errorf("in-flight request %d was accepted although its PubAck was withheld; nothing was held across the restart", i)
		}
	}
	resume()

	if err := w.waitMarker(ledgerMarkerConnectionReplaced, pollTimeout); err != nil {
		t.Fatalf("the killed transport's lane connection was never replaced: %v", err)
	}
	// The replacement carries a publish end to end before it is stalled, so
	// step 4 cannot catch its connection mid-handshake.
	if err := h.sendUntilAccepted(t, tlsCfg, probeSpool, probe, pollTimeout); err != nil {
		t.Fatalf("the replacement transport never carried a publish: %v", err)
	}

	// (4) Re-admission of a terminated publication beside new work, both
	// held so the ledger is read while they are outstanding.
	stall()
	readmitted := make(chan frameResult, 1)
	fresh := make(chan frameResult, 1)
	go func() { readmitted <- h.sendPublication(t, tlsCfg, spools[0], fxs[0], 30*time.Second) }()
	go func() { fresh <- h.sendPublication(t, tlsCfg, newWorkSpool, newWork, 30*time.Second) }()
	for _, m := range []string{ledgerMarker(ledgerMarkerReactivated, spools[0]), ledgerMarker(ledgerMarkerActive, newWorkSpool)} {
		if err := w.waitMarker(m, inFlightTimeout); err != nil {
			t.Fatalf("re-admission on the replacement: %v", err)
		}
	}
	w.record(t, groupEReadmittedEvent)
	resume()
	if r := <-readmitted; !acceptedAck(r.msg) {
		t.Errorf("the re-admitted publication was not accepted once its PubAck was released: msg=%v err=%v", r.msg, r.err)
	}
	if r := <-fresh; !acceptedAck(r.msg) {
		t.Errorf("new work on the replacement was not accepted once its PubAck was released: msg=%v err=%v", r.msg, r.err)
	}

	// (5) Settle the other two held publications on their original charges.
	for i := 1; i < inFlight; i++ {
		if err := h.sendUntilAccepted(t, tlsCfg, spools[i], fxs[i], pollTimeout); err != nil {
			t.Errorf("held publication %d was not accepted after the restart: %v", i, err)
		}
	}
	for _, s := range append(append([][]byte{}, spools...), newWorkSpool) {
		if err := w.waitMarker(ledgerMarker(ledgerMarkerReleased, s), pollTimeout); err != nil {
			t.Errorf("settlement: %v", err)
		}
	}

	tr, raw := w.stop(t)
	violations := analyzeRestartOverlap(tr, restartOverlapPlan{
		InFlight:        []string{hex.EncodeToString(spools[0]), hex.EncodeToString(spools[1]), hex.EncodeToString(spools[2])},
		Readmitted:      hex.EncodeToString(spools[0]),
		NewWork:         hex.EncodeToString(newWorkSpool),
		ReadmittedEvent: groupEReadmittedEvent,
	})
	for _, v := range violations {
		t.Errorf("restart overlap: %s", v)
	}
	if len(violations) > 0 {
		t.Logf("ledger trace: %s", raw)
	}

	if err := probeHealth(fmt.Sprintf("http://127.0.0.1:%d/health", h.gatewayEnv.MetricsPort), 10*time.Second); err != nil {
		t.Errorf("gateway health check failed after the lane transport restart: %v", err)
	}
	for i, fx := range append(append([]*FixtureRecord{}, fxs...), newWork, probe) {
		if n := h.awaitSingleLedgerRow(t, fx); n != 1 {
			t.Errorf("publication %d has %d event_ledger rows after the restart, want exactly 1", i, n)
		}
	}
}

// probeHealth is a single bounded HTTP health check, used post-chaos to
// confirm the release did not crash.
func probeHealth(url string, timeout time.Duration) error {
	client := &http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		resp, err := client.Get(url)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
			lastErr = fmt.Errorf("status %d", resp.StatusCode)
		} else {
			lastErr = err
		}
		time.Sleep(200 * time.Millisecond)
	}
	return lastErr
}

// ---------------------------------------------------------------------------
// Group F: post-handoff fencing.
//
// Task 0.12: "After a reservation is handed to its request owner, attempt a
// retry of that publication and observe refusal until the previous request
// is fenced by observable owner/start/termination state. After that fence,
// the same publication SHALL be admitted once and proceed."
//
//  1. One publication is sent with its PubAck withheld. The watcher sees the
//     hand-off: an ACTIVE attempt (the start) with token T1 and its owner, the
//     gateway stream process that will issue the request.
//  2. The identical publication is re-sent on a second stream. Its stream
//     must end with no acknowledgement, and the first sample after that
//     answer must still show T1 active under the same, living owner with a
//     transport accepting -- so the refusal was the in-flight attempt, not
//     missing transport, and the retry displaced nothing.
//  3. The fence: the first request's owner reports its termination, leaving
//     the reservation charged with no attempt, and exits.
//  4. Re-sent once more, the publication is accepted, is admitted at most once
//     (one new token), settles, and lands in CNPG exactly once.
//
// The refusal is decided by attempt state, never by the PubAck deadline: the
// retry is answered well inside the first attempt's deadline, and admission
// waits for the owner's termination. That a passed deadline authorises
// nothing is PublishWindow's own unit-tested contract.
// ---------------------------------------------------------------------------
func (h *harness) testGroupF(t *testing.T) {
	h.requireJetStream(t)

	tlsCfg, err := h.certSet.AgentTLSConfig(h.gatewayServerName)
	if err != nil {
		t.Fatalf("agent tls config: %v", err)
	}
	fx, spoolID := h.freshPublication(t)
	w := h.startLedgerWatcher(t, "group-f", [][]byte{spoolID}, nil)

	if n := h.gwNATS.StallServerToClient(); n == 0 {
		t.Fatal("the gateway holds no NATS connection through the proxy; nothing can be held in flight")
	}
	stalled := true
	defer func() {
		if stalled {
			h.gwNATS.Resume()
		}
	}()

	// (1) Hand the publication to its request owner.
	first := make(chan frameResult, 1)
	go func() { first <- h.sendPublication(t, tlsCfg, spoolID, fx, 30*time.Second) }()
	if err := w.waitMarker(ledgerMarker(ledgerMarkerActive, spoolID), inFlightTimeout); err != nil {
		t.Fatalf("the publication was never handed to a request owner: %v", err)
	}

	// (2) The retry, while that request is outstanding.
	retry := h.sendPublication(t, tlsCfg, spoolID, fx, inFlightTimeout)
	w.record(t, groupFRetryEvent)
	if retry.msg != nil {
		t.Errorf("a retry offered while the first request was outstanding got %v, want its stream to end with no acknowledgement", retry.msg)
	}
	if !errors.Is(retry.err, io.EOF) {
		t.Errorf("a retry offered while the first request was outstanding ended with %v, want a clean end of stream (refused before any I/O)", retry.err)
	}

	// (3) The fence: charged with no attempt, and the owner gone.
	for _, m := range []string{ledgerMarker(ledgerMarkerIdle, spoolID), ledgerMarker(ledgerMarkerOwnerExited, spoolID)} {
		if err := w.waitMarker(m, inFlightTimeout); err != nil {
			t.Fatalf("the first request was never fenced: %v", err)
		}
	}
	select {
	case r := <-first:
		if acceptedAck(r.msg) {
			t.Errorf("the first request was accepted although its PubAck was withheld; nothing was held for the retry to meet")
		}
	case <-time.After(inFlightTimeout):
		t.Fatal("the first request's stream did not end after its owner terminated")
	}
	h.gwNATS.Resume()
	stalled = false

	// (4) Admitted once after the fence.
	if r := h.sendPublication(t, tlsCfg, spoolID, fx, 20*time.Second); !acceptedAck(r.msg) {
		t.Fatalf("the publication was not accepted after its previous request was fenced: msg=%v err=%v", r.msg, r.err)
	}
	if err := w.waitMarker(ledgerMarker(ledgerMarkerReleased, spoolID), pollTimeout); err != nil {
		t.Errorf("settlement: %v", err)
	}

	tr, raw := w.stop(t)
	violations := analyzePostHandoffFencing(tr, hex.EncodeToString(spoolID), groupFRetryEvent)
	for _, v := range violations {
		t.Errorf("post-handoff fencing: %s", v)
	}
	if len(violations) > 0 {
		t.Logf("ledger trace: %s", raw)
	}

	if n := h.awaitSingleLedgerRow(t, fx); n != 1 {
		t.Errorf("the fenced-then-admitted publication has %d event_ledger rows, want exactly 1", n)
	}
}

// sendOneRawFrame opens a fresh gRPC stream, sends one lane_open + one
// delivery_frame carrying (recordBytes, recordSHA256) at the given spoolID/
// sequence, and returns the first server message received after the
// delivery_frame (which may be a disposition ack, or nil if the stream
// times out waiting -- callers decide what that means for their probe).
func (h *harness) sendOneRawFrame(
	t *testing.T, tlsCfg *tls.Config, spoolID []byte, sequence uint64,
	recordBytes, recordSHA256 []byte, timeout time.Duration,
) (*edgev1.EdgeRecordServerMessage, error) {
	t.Helper()

	conn, err := grpc.NewClient(h.gatewayAddr, grpc.WithTransportCredentials(credentials.NewTLS(tlsCfg)))
	if err != nil {
		return nil, fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	client := edgev1.NewEdgeRecordIngestServiceClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	stream, err := client.Stream(ctx)
	if err != nil {
		return nil, fmt.Errorf("open stream: %w", err)
	}

	nonce := make([]byte, 32)
	open := &edgev1.EdgeRecordLaneOpen{
		RouteProfile:            edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:            edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		SpoolId:                 spoolID,
		SequenceBase:            1,
		FirstUnresolvedSequence: sequence,
		SessionNonce:            nonce,
		RequestedByteCredits:    1 << 20,
		RequestedFrameCredits:   8,
	}
	if err := stream.Send(&edgev1.EdgeRecordClientMessage{Payload: &edgev1.EdgeRecordClientMessage_LaneOpen{LaneOpen: open}}); err != nil {
		return nil, fmt.Errorf("send lane_open: %w", err)
	}
	if _, err := stream.Recv(); err != nil {
		return nil, fmt.Errorf("recv lane_open_ack: %w", err)
	}

	frame := &edgev1.EdgeDeliveryFrameV1{
		SpoolId:      spoolID,
		Sequence:     sequence,
		RecordSha256: recordSHA256,
		RecordBytes:  recordBytes,
	}
	if err := stream.Send(&edgev1.EdgeRecordClientMessage{Payload: &edgev1.EdgeRecordClientMessage_DeliveryFrame{DeliveryFrame: frame}}); err != nil {
		return nil, fmt.Errorf("send delivery_frame: %w", err)
	}
	_ = stream.CloseSend()

	msg, err := stream.Recv()
	if err != nil {
		// A timeout/EOF here is a meaningful, real outcome for several
		// probes (e.g. a conflicting or fenced frame may never receive an
		// ack) -- callers interpret this via CNPG state, not this error
		// alone.
		return nil, err
	}
	return msg, nil
}
