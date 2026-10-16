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
	"encoding/json"
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
	"google.golang.org/grpc"
)

// The running agent probes sockets once at startup, logs that result once, and
// both enrollment hello and the agent capability status advertise it.
func TestRunningAgentAdvertisesItsStartupSocketProbe(t *testing.T) {
	binary := os.Getenv("SERVICERADAR_TEST_AGENT_BINARY")
	if binary == "" {
		if os.Getenv("TEST_SRCDIR") != "" {
			t.Fatal("Bazel did not supply the declared agent executable")
		}
		t.Skip("the executable is supplied by the Bazel agent_test target")
	}
	if !filepath.IsAbs(binary) {
		binary = filepath.Join(os.Getenv("TEST_SRCDIR"), os.Getenv("TEST_WORKSPACE"), binary)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	gateway := &startupProbeGateway{}
	lis, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(server, gateway)
	go func() {
		if err := server.Serve(lis); err != nil && !strings.Contains(err.Error(), "use of closed") {
			t.Logf("gateway serve ended: %v", err)
		}
	}()
	t.Cleanup(server.Stop)

	root := t.TempDir()
	checkers := filepath.Join(root, "checkers")
	if err := os.MkdirAll(checkers, 0o755); err != nil {
		t.Fatalf("checkers dir: %v", err)
	}
	configPath := filepath.Join(root, "agent.json")
	config := fmt.Sprintf(`{
		"agent_id": "socket-probe-live",
		"checkers_dir": %q,
		"partition": "default",
		"gateway_addr": %q,
		"push_interval": "1s",
		"gateway_security": {"mode": "none"},
		"logging": {"level": "info", "output": "stdout"}
	}`, checkers, lis.Addr().String())
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cmd := exec.CommandContext(ctx, binary, "--config", configPath)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "SR_ALLOW_INSECURE=true")
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

	deadline := time.Now().Add(40 * time.Second)
	var icmpLine, mtrLine string
	var hello, status []string
	for time.Now().Before(deadline) {
		icmpLine, mtrLine = socketProbeLogLines(logs.snapshot())
		hello = gateway.helloCapabilities()
		status = gateway.statusCapabilities()
		if icmpLine != "" && mtrLine != "" && hello != nil && status != nil {
			break
		}
		select {
		case <-ctx.Done():
		case <-time.After(100 * time.Millisecond):
		}
	}
	if cmd.Process != nil {
		_ = cmd.Process.Kill()
	}

	logText := string(logs.snapshot())
	if icmpLine == "" || mtrLine == "" {
		t.Fatalf("startup log missing a single ICMP and MTR probe line\nicmp=%q\nmtr=%q\nlog:\n%s", icmpLine, mtrLine, logText)
	}
	if hello == nil || status == nil {
		t.Fatalf("agent did not enroll and push capability status\nhello=%v\nstatus=%v\nlog:\n%s", hello, status, logText)
	}

	want := socketCapabilitiesFromProbeLog(icmpLine, mtrLine)
	gotHello := socketCapabilities(hello)
	gotStatus := socketCapabilities(status)
	t.Logf("icmp log: %s", icmpLine)
	t.Logf("mtr log: %s", mtrLine)
	t.Logf("hello socket capabilities: %v", gotHello)
	t.Logf("status socket capabilities: %v", gotStatus)

	if strings.Join(gotHello, ",") != strings.Join(want, ",") {
		t.Errorf("hello socket capabilities = %v, log calls for %v", gotHello, want)
	}
	if strings.Join(gotStatus, ",") != strings.Join(want, ",") {
		t.Errorf("status socket capabilities = %v, log calls for %v", gotStatus, want)
	}
}

// agentOutput is the running agent's combined log. exec writes it from its
// own goroutines, and the test reads it while that copy is still running.
type agentOutput struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (o *agentOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buf.Write(p)
}

func (o *agentOutput) snapshot() []byte {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]byte(nil), o.buf.Bytes()...)
}

type startupProbeGateway struct {
	proto.UnimplementedAgentGatewayServiceServer
	mu     sync.Mutex
	hello  []string
	status []string
}

func (g *startupProbeGateway) Hello(_ context.Context, req *proto.AgentHelloRequest) (*proto.AgentHelloResponse, error) {
	g.mu.Lock()
	g.hello = append([]string(nil), req.GetCapabilities()...)
	g.mu.Unlock()
	return &proto.AgentHelloResponse{
		Accepted:             true,
		AgentId:              req.GetAgentId(),
		GatewayId:            "disposable-gateway",
		HeartbeatIntervalSec: 1,
	}, nil
}

func (g *startupProbeGateway) GetConfig(context.Context, *proto.AgentConfigRequest) (*proto.AgentConfigResponse, error) {
	return &proto.AgentConfigResponse{NotModified: true}, nil
}

func (g *startupProbeGateway) PushStatus(_ context.Context, req *proto.GatewayStatusRequest) (*proto.GatewayStatusResponse, error) {
	for _, service := range req.GetServices() {
		if service.GetServiceName() != "agent" || service.GetServiceType() != "agent" {
			continue
		}
		var payload struct {
			Capabilities []string `json:"capabilities"`
		}
		if err := json.Unmarshal(service.GetMessage(), &payload); err != nil || len(payload.Capabilities) == 0 {
			continue
		}
		g.mu.Lock()
		g.status = append([]string(nil), payload.Capabilities...)
		g.mu.Unlock()
	}
	return &proto.GatewayStatusResponse{Received: true}, nil
}

func (g *startupProbeGateway) helloCapabilities() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.hello == nil {
		return nil
	}
	return append([]string(nil), g.hello...)
}

func (g *startupProbeGateway) statusCapabilities() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.status == nil {
		return nil
	}
	return append([]string(nil), g.status...)
}

func socketProbeLogLines(raw []byte) (icmpLine, mtrLine string) {
	var icmpCount, mtrCount int
	for _, line := range bytes.Split(raw, []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		var event struct {
			Message string `json:"message"`
			TCPSyn  *bool  `json:"tcpSyn"`
		}
		message := string(line)
		if err := json.Unmarshal(line, &event); err == nil && event.Message != "" {
			message = event.Message
			if event.TCPSyn != nil && strings.Contains(message, "MTR capability") {
				message += fmt.Sprintf(" tcpSyn=%t", *event.TCPSyn)
			}
		}
		if strings.Contains(message, "ICMP sweep capability") {
			icmpCount++
			icmpLine = message
		}
		if strings.Contains(message, "MTR capability") {
			mtrCount++
			mtrLine = message
		}
	}
	if icmpCount != 1 {
		icmpLine = ""
	}
	if mtrCount != 1 {
		mtrLine = ""
	}
	return icmpLine, mtrLine
}

func socketCapabilitiesFromProbeLog(icmpLine, mtrLine string) []string {
	caps := make([]string, 0, 4)
	if strings.Contains(icmpLine, "unavailable") {
		caps = append(caps, "icmp.unavailable")
	} else {
		caps = append(caps, "icmp")
	}
	if strings.Contains(mtrLine, "unavailable") {
		caps = append(caps, "mtr.unavailable")
		return caps
	}
	if strings.Contains(mtrLine, "tcpSyn=true") {
		caps = append(caps, "mtr_tcp_syn")
	}
	caps = append(caps, "mtr", "mtr_protocol_set")
	return caps
}

func socketCapabilities(caps []string) []string {
	known := map[string]struct{}{
		"icmp":             {},
		"icmp.unavailable": {},
		"mtr":              {},
		"mtr.unavailable":  {},
		"mtr_protocol_set": {},
		"mtr_tcp_syn":      {},
	}
	out := make([]string, 0, 4)
	for _, cap := range caps {
		if _, ok := known[cap]; ok {
			out = append(out, cap)
		}
	}
	return out
}
