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
	"encoding/json"
	"net"
	"strings"
	"sync"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type capturingTestLogger struct {
	mu  sync.Mutex
	buf bytes.Buffer
	log zerolog.Logger
}

func newCapturingTestLogger() *capturingTestLogger {
	c := &capturingTestLogger{}
	c.log = zerolog.New(c).Level(zerolog.DebugLevel)
	return c
}

func (c *capturingTestLogger) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.Write(p)
}

func (c *capturingTestLogger) Trace() *zerolog.Event { return c.log.Trace() }
func (c *capturingTestLogger) Debug() *zerolog.Event { return c.log.Debug() }
func (c *capturingTestLogger) Info() *zerolog.Event  { return c.log.Info() }
func (c *capturingTestLogger) Warn() *zerolog.Event  { return c.log.Warn() }
func (c *capturingTestLogger) Error() *zerolog.Event { return c.log.Error() }
func (c *capturingTestLogger) Fatal() *zerolog.Event { return c.log.Fatal() }
func (c *capturingTestLogger) Panic() *zerolog.Event { return c.log.Panic() }
func (c *capturingTestLogger) With() zerolog.Context { return c.log.With() }
func (c *capturingTestLogger) WithComponent(component string) zerolog.Logger {
	return c.log.With().Str("component", component).Logger()
}
func (c *capturingTestLogger) WithFields(fields map[string]interface{}) zerolog.Logger {
	return c.log.With().Fields(fields).Logger()
}
func (c *capturingTestLogger) SetLevel(level zerolog.Level) { c.log = c.log.Level(level) }
func (*capturingTestLogger) SetDebug(_ bool)                {}

func (c *capturingTestLogger) messagesAtLevel(t *testing.T, level string) []string {
	t.Helper()
	c.mu.Lock()
	raw := c.buf.String()
	c.mu.Unlock()

	var messages []string
	for _, line := range strings.Split(strings.TrimSpace(raw), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("decode log entry %q: %v", line, err)
		}
		if entry["level"] == level {
			msg, _ := entry["message"].(string)
			messages = append(messages, msg)
		}
	}

	return messages
}

// transientPluginGateway fails the first status push and accepts the rest.
type transientPluginGateway struct {
	proto.UnimplementedAgentGatewayServiceServer

	mu             sync.Mutex
	pushCalls      int
	pushedRequests []*proto.GatewayStatusRequest
}

func (g *transientPluginGateway) PushStatus(
	_ context.Context,
	req *proto.GatewayStatusRequest,
) (*proto.GatewayStatusResponse, error) {
	g.mu.Lock()
	g.pushCalls++
	call := g.pushCalls
	if call > 1 {
		g.pushedRequests = append(g.pushedRequests, req)
	}
	g.mu.Unlock()

	if call == 1 {
		return nil, status.Error(codes.Unavailable, "gateway restarting")
	}

	return &proto.GatewayStatusResponse{Received: true}, nil
}

func TestPushPluginTelemetryTransientGatewayFailureLogsWarnAndDeliversOnNextCycle(t *testing.T) {
	t.Setenv("SR_ALLOW_INSECURE", "true")

	gw := &transientPluginGateway{}
	lis, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	grpcServer := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(grpcServer, gw)
	go func() { _ = grpcServer.Serve(lis) }()
	t.Cleanup(func() {
		grpcServer.Stop()
		_ = lis.Close()
	})

	client := agentgateway.NewGatewayClient(lis.Addr().String(), nil, logger.NewTestLogger())
	if err := client.Connect(t.Context()); err != nil {
		t.Fatalf("connect gateway client: %v", err)
	}
	t.Cleanup(func() { _ = client.Disconnect() })

	manager := &PluginManager{
		stats: pluginEngineStats{
			assignmentsTotal:    1,
			assignmentsAdmitted: 1,
			execTotal:           3,
		},
	}

	logCapture := newCapturingTestLogger()
	loop := &PushLoop{
		server: &Server{
			config: &ServerConfig{
				AgentID:   "agent-1",
				Partition: "default",
				HostIP:    "192.0.2.10",
			},
			pluginManager: manager,
		},
		logger:  logCapture,
		gateway: client,
	}

	// Cycle 1: the gateway fails the status push once.
	if loop.pushPluginTelemetry(t.Context()) {
		t.Fatal("transient PushStatus failure must not report success")
	}
	if errMsgs := logCapture.messagesAtLevel(t, "error"); len(errMsgs) != 0 {
		t.Fatalf("transient plugin telemetry failure logged at error: %v, want warn only", errMsgs)
	}
	if warnMsgs := logCapture.messagesAtLevel(t, "warn"); len(warnMsgs) == 0 {
		t.Fatal("expected a warning log for the plugin telemetry retry")
	}

	// Cycle 2: the gateway recovers and the engine counters arrive.
	if err := client.Connect(t.Context()); err != nil {
		t.Fatalf("reconnect for second push cycle: %v", err)
	}
	if !loop.pushPluginTelemetry(t.Context()) {
		t.Fatal("second push cycle must deliver plugin telemetry")
	}

	gw.mu.Lock()
	gotRequests := append([]*proto.GatewayStatusRequest(nil), gw.pushedRequests...)
	gw.mu.Unlock()

	if len(gotRequests) != 1 || len(gotRequests[0].GetServices()) != 1 {
		t.Fatalf("delivered plugin telemetry requests = %#v, want 1 service status", gotRequests)
	}
	var telemetryPayload struct {
		Executions struct {
			Total uint64 `json:"total"`
		} `json:"executions"`
		Assignments struct {
			Admitted int `json:"admitted"`
		} `json:"assignments"`
	}
	if err := json.Unmarshal(gotRequests[0].GetServices()[0].GetMessage(), &telemetryPayload); err != nil {
		t.Fatalf("decode plugin telemetry payload: %v", err)
	}
	if telemetryPayload.Executions.Total != 3 || telemetryPayload.Assignments.Admitted != 1 {
		t.Fatalf("delivered plugin telemetry payload = %+v, want total=3 admitted=1", telemetryPayload)
	}
}
