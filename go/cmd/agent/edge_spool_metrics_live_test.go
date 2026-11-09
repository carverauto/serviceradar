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
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/fairsched"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/grpc"
)

// rfc9562UUIDv7 builds a version-7 UUID from RFC 9562 §5.7: the first 48 bits
// are a big-endian Unix millisecond timestamp, the high nibble of byte 6 is
// version 7, and the high bits of byte 8 are the RFC variant. It does not call
// the spool decoder or the production UUIDv7 helper.
func rfc9562UUIDv7(unixMilli uint64) []byte {
	id := make([]byte, 16)
	var be [8]byte
	binary.BigEndian.PutUint64(be[:], unixMilli<<16)
	copy(id[:6], be[:6])
	id[6] = 0x70
	id[8] = 0x80
	return id
}

type spooledRecord struct {
	eventID []byte
	body    []byte
}

// TestRunningAgentExportsEdgeSpoolMetrics scrapes the agent process the same
// way an operator does: HTTP GET /metrics on the pprof listener. The oracle
// for age is the RFC 9562 timestamp embedded in the event id, compared with
// the wall clock. A decoder that ignored the version nibble, or that picked
// the newest id, would report a different age. Bytes are the sum of committed
// record bodies.
func TestRunningAgentExportsEdgeSpoolMetrics(t *testing.T) {
	binaryPath := agentTestBinary(t)
	now := time.Now()
	older := now.Add(-120 * time.Second).UnixMilli()
	newer := now.Add(-10 * time.Second).UnixMilli()
	nonV7 := rfc9562UUIDv7(uint64(now.Add(-48 * time.Hour).UnixMilli()))
	nonV7[6] = 0x40

	body := scrapeRunningAgent(t, binaryPath, []spooledRecord{
		{eventID: rfc9562UUIDv7(uint64(newer)), body: []byte("ab")},
		{eventID: rfc9562UUIDv7(uint64(older)), body: []byte("cdef")},
		{eventID: nonV7, body: []byte("zz")},
	}, true)

	if got := promGauge(t, body, "agent_edge_spool_unresolved_bytes"); got != 8 {
		t.Fatalf("unresolved bytes = %g, want 8 (2+4+2 body bytes)\n%s", got, body)
	}
	age := promGauge(t, body, "agent_edge_spool_oldest_unresolved_age_seconds")
	want := time.Since(time.UnixMilli(older)).Seconds()
	if age < want-5 || age > want+5 {
		t.Fatalf("oldest age = %g, want about %g seconds from the older UUIDv7\n%s", age, want, body)
	}
	if age < 100 {
		t.Fatalf("oldest age = %g, the newer 10s record won", age)
	}
	if age > 3600 {
		t.Fatalf("oldest age = %g, the non-v7 id was treated as a timestamp", age)
	}
	if got := promGauge(t, body, "agent_edge_spool_admission_paused"); got != 0 {
		t.Fatalf("admission paused = %g for a spool far below its low water, want 0\n%s", got, body)
	}
	t.Logf("scrape:\n%s", edgeSpoolLines(body))
}

func TestRunningAgentOmitsAgeWhenNoRecordIsUUIDv7(t *testing.T) {
	binaryPath := agentTestBinary(t)
	id := rfc9562UUIDv7(uint64(time.Now().Add(-90 * time.Second).UnixMilli()))
	id[6] = 0x40
	body := scrapeRunningAgent(t, binaryPath, []spooledRecord{{eventID: id, body: []byte("body")}}, true)
	if got := promGauge(t, body, "agent_edge_spool_unresolved_bytes"); got != 4 {
		t.Fatalf("unresolved bytes = %g, want 4\n%s", got, body)
	}
	if strings.Contains(body, "agent_edge_spool_oldest_unresolved_age_seconds") {
		t.Fatalf("age published for a version-4 event id:\n%s", body)
	}
	t.Logf("scrape:\n%s", edgeSpoolLines(body))
}

func TestRunningAgentClampsAFutureSpoolEventToZero(t *testing.T) {
	binaryPath := agentTestBinary(t)
	future := uint64(time.Now().Add(30 * time.Second).UnixMilli())
	body := scrapeRunningAgent(t, binaryPath, []spooledRecord{{eventID: rfc9562UUIDv7(future), body: []byte("x")}}, true)
	if got := promGauge(t, body, "agent_edge_spool_unresolved_bytes"); got != 1 {
		t.Fatalf("unresolved bytes = %g, want 1\n%s", got, body)
	}
	if got := promGauge(t, body, "agent_edge_spool_oldest_unresolved_age_seconds"); got != 0 {
		t.Fatalf("future age = %g, want 0\n%s", got, body)
	}
	t.Logf("scrape:\n%s", edgeSpoolLines(body))
}

// A spool that cannot be opened does not stop the agent: it keeps serving its
// exporter, with no spool series to publish.
func TestRunningAgentRunsOnWhenTheSpoolCannotOpen(t *testing.T) {
	binaryPath := agentTestBinary(t)
	body := scrapeRunningAgent(t, binaryPath, nil, false)
	if !strings.Contains(body, "sweep_banner_grab_candidates_total") {
		t.Fatalf("metrics endpoint did not serve the agent exporter:\n%s", body)
	}
	if strings.Contains(body, "agent_edge_spool_") {
		t.Fatalf("edge spool series published for a spool that did not open:\n%s", body)
	}
	t.Logf("spool unavailable; scrape has banner metrics and no agent_edge_spool series")
}

func agentTestBinary(t *testing.T) string {
	t.Helper()
	binaryPath := os.Getenv("SERVICERADAR_TEST_AGENT_BINARY")
	if binaryPath == "" {
		if os.Getenv("TEST_SRCDIR") != "" {
			t.Fatal("Bazel did not supply the declared agent executable")
		}
		t.Skip("the executable is supplied by the Bazel agent_test target")
	}
	if !filepath.IsAbs(binaryPath) {
		binaryPath = filepath.Join(os.Getenv("TEST_SRCDIR"), os.Getenv("TEST_WORKSPACE"), binaryPath)
	}
	return binaryPath
}

// scrapeRunningAgent runs the agent over a spool seeded with records, or, with
// openableSpool false, over a spool directory that cannot be created.
func scrapeRunningAgent(t *testing.T, binaryPath string, records []spooledRecord, openableSpool bool) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()

	lis, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	gateway := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(gateway, &startupProbeGateway{})
	go func() {
		_ = gateway.Serve(lis)
	}()
	t.Cleanup(gateway.Stop)

	metricsLis, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("metrics listen: %v", err)
	}
	metricsAddr := metricsLis.Addr().String()
	if err := metricsLis.Close(); err != nil {
		t.Fatalf("metrics listen close: %v", err)
	}

	root := t.TempDir()
	checkers := filepath.Join(root, "checkers")
	if err := os.MkdirAll(checkers, 0o755); err != nil {
		t.Fatalf("checkers dir: %v", err)
	}

	spoolDir := filepath.Join(root, "spool")
	if openableSpool {
		commitSpool(t, spoolDir, records)
	} else {
		blocker := filepath.Join(root, "not-a-directory")
		if err := os.WriteFile(blocker, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		spoolDir = filepath.Join(blocker, "spool")
	}
	edgeJSON := fmt.Sprintf(`,
		"edge_record_sender": {
			"spool_dir": %q,
			"poll_interval": "1h"
		}`, spoolDir)

	configPath := filepath.Join(root, "agent.json")
	config := fmt.Sprintf(`{
		"agent_id": "edge-spool-metrics",
		"checkers_dir": %q,
		"partition": "default",
		"gateway_addr": %q,
		"push_interval": "1h",
		"gateway_security": {"mode": "none"},
		"logging": {"level": "info", "output": "stdout"}%s
	}`, checkers, lis.Addr().String(), edgeJSON)
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

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

	url := "http://" + metricsAddr + "/metrics"
	deadline := time.Now().Add(15 * time.Second)
	var last string
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			break
		}
		payload, ok, detail := scrapeMetricsOnce(ctx, t, url)
		if ok {
			return payload
		}
		last = detail
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("agent /metrics did not become ready: %s\nlog:\n%s", last, logs.snapshot())
	return ""
}

// scrapeMetricsOnce fetches /metrics once. The per-request context stays live
// until the body is fully read: cancelling it after Do returns would abort any
// body larger than the transport's first read.
func scrapeMetricsOnce(ctx context.Context, t *testing.T, url string) (string, bool, string) {
	t.Helper()
	reqCtx, reqCancel := context.WithTimeout(ctx, time.Second)
	defer reqCancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", false, err.Error()
	}
	defer func() { _ = resp.Body.Close() }()

	payload, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", false, fmt.Sprintf("status %d read body: %v", resp.StatusCode, err)
	}
	if resp.StatusCode == http.StatusOK && strings.Contains(string(payload), "sweep_banner_grab_candidates_total") {
		return string(payload), true, ""
	}
	return "", false, fmt.Sprintf("status %d body %s", resp.StatusCode, payload)
}

// These fixtures exercise transport/header metrics, not producer authorization.
// Real producer admission is covered by the running sweep and sealed facade tests.
func commitSpool(t *testing.T, dir string, records []spooledRecord) {
	t.Helper()
	lanes, identity, key := testTransportLanes(t, dir)
	for _, record := range records {
		if _, err := lanes.Append(key, identity, record.eventID, record.body); err != nil {
			t.Fatal(err)
		}
	}
	if err := lanes.Close(); err != nil {
		t.Fatal(err)
	}
}

func testTransportLanes(t *testing.T, dir string) (*spool.LaneSet, spool.Identity, spool.LaneKey) {
	t.Helper()
	id, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatal(err)
	}
	identity := spool.Identity{NetworkScopeID: id, AgentID: []byte("agent-demo")}
	key := spool.LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}
	control := spool.LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}
	taxonomy, err := fairsched.NewLaneTaxonomy([]fairsched.LanePolicy{{Key: key, WeightBytes: 1}, {Key: control, WeightBytes: 1}}, control)
	if err != nil {
		t.Fatal(err)
	}
	lanes, err := spool.OpenLanes(filepath.Join(dir, "lanes"), identity, taxonomy)
	if err != nil {
		t.Fatal(err)
	}
	return lanes, identity, key
}

func edgeSpoolLines(body string) string {
	var b strings.Builder
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, "agent_edge_spool_") {
			b.WriteString(line)
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func promGauge(t *testing.T, body, name string) float64 {
	t.Helper()
	prefix := name + " "
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, prefix) {
			value, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimPrefix(line, prefix)), 64)
			if err != nil {
				t.Fatalf("parse %s: %v", name, err)
			}
			return value
		}
	}
	t.Fatalf("metric %s missing:\n%s", name, body)
	return 0
}
