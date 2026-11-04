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

package main

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/grpc"
	gproto "google.golang.org/protobuf/proto"
)

// spoolHelloGateway is a disposable gateway that keeps every hello the running
// agent sends and answers GetConfig with a chosen spool byte budget. With
// ingest set it also drains the agent's edge-record lane (grantLiveGateway).
type spoolHelloGateway struct {
	*grantLiveGateway

	budget uint64

	helloMu sync.Mutex
	hellos  []*proto.AgentHelloRequest
	configs int
}

func (g *spoolHelloGateway) Hello(ctx context.Context, req *proto.AgentHelloRequest) (*proto.AgentHelloResponse, error) {
	g.helloMu.Lock()
	g.hellos = append(g.hellos, gproto.Clone(req).(*proto.AgentHelloRequest))
	g.helloMu.Unlock()
	return g.grantLiveGateway.Hello(ctx, req)
}

func (g *spoolHelloGateway) GetConfig(context.Context, *proto.AgentConfigRequest) (*proto.AgentConfigResponse, error) {
	g.helloMu.Lock()
	g.configs++
	g.helloMu.Unlock()
	return &proto.AgentConfigResponse{ConfigVersion: "spool-budget-v1", EdgeSpoolMaxBytes: g.budget}, nil
}

func (g *spoolHelloGateway) lastHello() (*proto.AgentHelloRequest, int) {
	g.helloMu.Lock()
	defer g.helloMu.Unlock()
	if len(g.hellos) == 0 {
		return nil, g.configs
	}
	return g.hellos[len(g.hellos)-1], g.configs
}

func listenSpoolHelloGateway(t *testing.T, ingest bool, budget uint64) (*spoolHelloGateway, string) {
	t.Helper()
	lis, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	gw := &spoolHelloGateway{
		grantLiveGateway: &grantLiveGateway{startupProbeGateway: &startupProbeGateway{}},
		budget:           budget,
	}
	server := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(server, gw)
	if ingest {
		edgev1.RegisterEdgeRecordIngestServiceServer(server, gw)
	}
	go func() { _ = server.Serve(lis) }()
	t.Cleanup(func() {
		server.Stop()
		_ = lis.Close()
	})
	return gw, lis.Addr().String()
}

// runSpoolAgent starts the agent binary with senderBlock as its
// edge_record_sender JSON object and returns its log and metrics URL.
func runSpoolAgent(t *testing.T, gatewayAddr, senderBlock string) (*agentOutput, string) {
	t.Helper()
	binaryPath := agentTestBinary(t)
	root := t.TempDir()
	checkers := filepath.Join(root, "checkers")
	if err := os.MkdirAll(checkers, 0o755); err != nil {
		t.Fatalf("checkers dir: %v", err)
	}
	metricsLis, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("metrics listen: %v", err)
	}
	metricsAddr := metricsLis.Addr().String()
	_ = metricsLis.Close()

	configPath := filepath.Join(root, "agent.json")
	config := fmt.Sprintf(`{
		"agent_id": "edge-spool-default-on",
		"checkers_dir": %q,
		"partition": "default",
		"gateway_addr": %q,
		"push_interval": "1h",
		"gateway_security": {"mode": "none"},
		"logging": {"level": "info", "output": "stdout"},
		"edge_record_sender": %s
	}`, checkers, gatewayAddr, senderBlock)
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	cmd := exec.CommandContext(ctx, binaryPath, "--config", configPath)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "SR_ALLOW_INSECURE=true", "SERVICERADAR_AGENT_PPROF_ADDR="+metricsAddr)
	logs := &agentOutput{}
	cmd.Stdout = logs
	cmd.Stderr = logs
	if err := cmd.Start(); err != nil {
		t.Fatalf("start agent: %v", err)
	}
	t.Cleanup(func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_, _ = cmd.Process.Wait()
	})
	return logs, "http://" + metricsAddr + "/metrics"
}

func waitForHello(t *testing.T, gw *spoolHelloGateway, logs *agentOutput) *proto.AgentHelloRequest {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if hello, _ := gw.lastHello(); hello != nil {
			return hello
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("agent sent no hello within 20s\nlog:\n%s", logs.snapshot())
	return nil
}

// An agent config written for the opt-in sender, with the sender switched off
// and every producer opt-in and the local budget set, still loads: the keys are
// ignored, the sender drains the spool anyway, and the hello says the spool is
// available.
func TestRunningAgentIgnoresTheRemovedSenderSwitches(t *testing.T) {
	now := time.Now()
	first := spooledEdgeRecord(t, now.Add(2*time.Hour))
	second := spooledEdgeRecord(t, now.Add(2*time.Hour))
	gw, addr := listenSpoolHelloGateway(t, true, 0)

	spoolDir := filepath.Join(t.TempDir(), "spool")
	commitSpool(t, spoolDir, []spooledRecord{first, second})
	block := fmt.Sprintf(`{
		"enabled": false,
		"sweep_enabled": false,
		"metrics_enabled": false,
		"telemetry_enabled": false,
		"plugin_results_enabled": false,
		"discovery_enabled": false,
		"sync_enabled": false,
		"max_bytes": 4096,
		"spool_dir": %q,
		"poll_interval": "1s"
	}`, spoolDir)
	logs, _ := runSpoolAgent(t, addr, block)

	hello := waitForHello(t, gw, logs)
	spoolStatus := hello.GetEdgeRecordSpool()
	if spoolStatus == nil || !spoolStatus.GetAvailable() || spoolStatus.GetError() != "" {
		t.Fatalf("hello edge_record_spool = %v, want available with no error\nlog:\n%s", spoolStatus, logs.snapshot())
	}

	deadline := time.Now().Add(25 * time.Second)
	for time.Now().Before(deadline) {
		if _, frames := gw.snapshot(); framesCoverBothSequences(frames) {
			for _, frame := range frames {
				want := first.body
				if frame.GetSequence() == 2 {
					want = second.body
				}
				if !bytes.Equal(frame.GetRecordBytes(), want) {
					t.Fatalf("sequence %d bytes differ from the spooled record", frame.GetSequence())
				}
			}
			t.Logf("legacy switches ignored; hello spool=%v; delivered %d frames", spoolStatus, len(frames))
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	_, frames := gw.snapshot()
	t.Fatalf("sender did not drain despite enabled=false being ignored: frames=%d\nlog:\n%s", len(frames), logs.snapshot())
}

// A spool directory the agent cannot create does not stop it: the agent keeps
// checking in, and its hello carries available=false and the open error.
func TestRunningAgentReportsAnUnavailableSpoolInItsHello(t *testing.T) {
	gw, addr := listenSpoolHelloGateway(t, false, 0)
	blocker := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	logs, _ := runSpoolAgent(t, addr, fmt.Sprintf(`{"spool_dir": %q}`, filepath.Join(blocker, "spool")))

	hello := waitForHello(t, gw, logs)
	spoolStatus := hello.GetEdgeRecordSpool()
	if spoolStatus == nil || spoolStatus.GetAvailable() {
		t.Fatalf("hello edge_record_spool = %v, want available=false\nlog:\n%s", spoolStatus, logs.snapshot())
	}
	if !strings.Contains(spoolStatus.GetError(), "not-a-directory") {
		t.Fatalf("hello spool error %q does not name the directory that failed", spoolStatus.GetError())
	}
	t.Logf("hello edge_record_spool = {available:false error:%q}", spoolStatus.GetError())
}

// scrapeAfterConfig waits until the agent has fetched its config at least once
// and the log says how the budget was handled, then scrapes /metrics.
func scrapeAfterConfig(t *testing.T, gw *spoolHelloGateway, logs *agentOutput, url, logWant string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	for ctx.Err() == nil {
		_, configs := gw.lastHello()
		if configs > 0 && (logWant == "" || bytes.Contains(logs.snapshot(), []byte(logWant))) {
			if body, ok, _ := scrapeMetricsOnce(ctx, t, url); ok && strings.Contains(body, "agent_edge_spool_admission_paused") {
				return body
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("agent did not fetch config and serve spool metrics within 25s\nlog:\n%s", logs.snapshot())
	return ""
}

// Core's spool budget applies at admission. One unresolved 3.2 MB record sits in
// the spool and the gateway cannot ingest it. Under the 1 GiB default the gate
// is open. A 4 MiB budget from core leaves 1.5 MiB of ordinary room after the
// 1.5 MiB recovery reserve and 1 MiB min-free, so the same spool is over the
// budget: admission pauses, and the held record is kept, not evicted.
func TestRunningAgentAppliesTheSpoolBudgetFromConfig(t *testing.T) {
	const bodyLen = 3_200_000
	seed := func(t *testing.T) string {
		t.Helper()
		dir := filepath.Join(t.TempDir(), "spool")
		id := rfc9562UUIDv7(uint64(time.Now().Add(-30 * time.Second).UnixMilli()))
		commitSpool(t, dir, []spooledRecord{{eventID: id, body: bytes.Repeat([]byte("b"), bodyLen)}})
		return dir
	}
	cases := []struct {
		name       string
		budget     uint64
		logWant    string
		wantPaused float64
	}{
		{name: "older core sends no budget", budget: 0, wantPaused: 0},
		{name: "core sends 4 MiB", budget: 4 << 20, logWant: "Applied edge spool budget from config", wantPaused: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gw, addr := listenSpoolHelloGateway(t, false, tc.budget)
			logs, url := runSpoolAgent(t, addr, fmt.Sprintf(`{"spool_dir": %q, "poll_interval": "1h"}`, seed(t)))
			body := scrapeAfterConfig(t, gw, logs, url, tc.logWant)
			if got := promGauge(t, body, "agent_edge_spool_admission_paused"); got != tc.wantPaused {
				t.Fatalf("admission paused = %g, want %g\n%s\nlog:\n%s", got, tc.wantPaused, edgeSpoolLines(body), logs.snapshot())
			}
			if got := promGauge(t, body, "agent_edge_spool_unresolved_bytes"); got != bodyLen {
				t.Fatalf("unresolved bytes = %g, want the held record %d", got, bodyLen)
			}
			t.Logf("budget %d: scrape:\n%s", tc.budget, edgeSpoolLines(body))
		})
	}
}

// A package- or Ansible-installed agent whose config has no edge_record_sender
// block still runs the spool, at the documented default directory
// /var/lib/serviceradar/agent/edge-records (OpenSpec
// enable-edge-record-pipeline-by-default, task 4.1). The hello always carries a
// spool status: available when that directory could be created, otherwise
// unavailable with an error that names it. A build that skipped the sender
// without a block would send no status at all.
func TestRunningAgentWithoutASenderBlockUsesTheDefaultSpoolDir(t *testing.T) {
	const wantDir = "/var/lib/serviceradar/agent/edge-records"
	gw, addr := listenSpoolHelloGateway(t, false, 0)
	logs, _ := runSpoolAgent(t, addr, "null")

	hello := waitForHello(t, gw, logs)
	spoolStatus := hello.GetEdgeRecordSpool()
	if spoolStatus == nil {
		t.Fatalf("hello carried no edge_record_spool status\nlog:\n%s", logs.snapshot())
	}
	if spoolStatus.GetAvailable() {
		if info, err := os.Stat(wantDir); err != nil || !info.IsDir() {
			t.Fatalf("spool reported available but %s is not a directory: %v", wantDir, err)
		}
	} else if !strings.Contains(spoolStatus.GetError(), wantDir) {
		t.Fatalf("hello spool error %q does not name the default directory %s\nlog:\n%s",
			spoolStatus.GetError(), wantDir, logs.snapshot())
	}
	t.Logf("no sender block: hello edge_record_spool = {available:%v error:%q}",
		spoolStatus.GetAvailable(), spoolStatus.GetError())
}
