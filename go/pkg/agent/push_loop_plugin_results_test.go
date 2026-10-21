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
	"errors"
	"fmt"
	"io"
	"net"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestPushPluginResultsRetainsBatchUntilGatewayAcknowledges(t *testing.T) {
	manager := &PluginManager{results: make(chan PluginResult, 4)}
	first := testPendingPluginResult("assignment-1", "first")
	second := testPendingPluginResult("assignment-2", "second")
	third := testPendingPluginResult("assignment-3", "third")
	manager.results <- first
	manager.results <- second

	server := &Server{
		config: &ServerConfig{
			AgentID:   "agent-1",
			Partition: "default",
			HostIP:    "192.0.2.10",
		},
		pluginManager: manager,
	}

	var attempts [][]string
	streamAttempts := 0
	loop := &PushLoop{
		server: server,
		logger: logger.NewTestLogger(),
		pluginResultStreamStatus: func(
			_ context.Context,
			chunks []*proto.GatewayStatusChunk,
		) (*proto.GatewayStatusResponse, error) {
			assertPluginResultTransportCapabilities(t, chunks)
			streamAttempts++
			attempts = append(attempts, pluginResultAssignments(t, chunks))
			if streamAttempts == 1 {
				return nil, agentgateway.ErrGatewayNotConnected
			}

			return &proto.GatewayStatusResponse{Received: true}, nil
		},
	}

	if loop.pushPluginResults(t.Context()) {
		t.Fatal("failed stream must not report a successful plugin result push")
	}
	if got := len(loop.pendingPluginResults); got != 2 {
		t.Fatalf("pending plugin results after failure = %d, want 2", got)
	}

	// Results produced while a batch is pending remain in the manager queue and
	// cannot overtake the unacknowledged batch.
	manager.results <- third

	if !loop.pushPluginResults(t.Context()) {
		t.Fatal("acknowledged retry must report a successful plugin result push")
	}
	if got := len(loop.pendingPluginResults); got != 0 {
		t.Fatalf("pending plugin results after acknowledgement = %d, want 0", got)
	}
	if got, want := attempts, [][]string{{"assignment-1", "assignment-2"}, {"assignment-1", "assignment-2"}}; !equalStringMatrix(got, want) {
		t.Fatalf("delivery attempts = %#v, want %#v", got, want)
	}

	if !loop.pushPluginResults(t.Context()) {
		t.Fatal("queued result behind acknowledged batch must be delivered")
	}
	if got, want := attempts[2], []string{"assignment-3"}; !equalStrings(got, want) {
		t.Fatalf("third delivery attempt = %#v, want %#v", got, want)
	}
}

func TestPushPluginResultsBoundsStrictDeliveryBatch(t *testing.T) {
	manager := &PluginManager{results: make(chan PluginResult, maxPluginResultsPerStream+1)}
	for i := 0; i < maxPluginResultsPerStream+1; i++ {
		manager.results <- testPendingPluginResult(fmt.Sprintf("assignment-%d", i), "ok")
	}

	var batchSizes []int
	loop := &PushLoop{
		server: &Server{
			config:        &ServerConfig{AgentID: "agent-1", HostIP: "192.0.2.10"},
			pluginManager: manager,
		},
		logger: logger.NewTestLogger(),
		pluginResultStreamStatus: func(
			_ context.Context,
			chunks []*proto.GatewayStatusChunk,
		) (*proto.GatewayStatusResponse, error) {
			assertPluginResultTransportCapabilities(t, chunks)
			batchSizes = append(batchSizes, len(chunks))
			return &proto.GatewayStatusResponse{Received: true}, nil
		},
	}

	if !loop.pushPluginResults(t.Context()) {
		t.Fatal("first bounded plugin result batch must be acknowledged")
	}
	if !loop.pushPluginResults(t.Context()) {
		t.Fatal("second bounded plugin result batch must be acknowledged")
	}
	if got, want := batchSizes, []int{maxPluginResultsPerStream, 1}; !slices.Equal(got, want) {
		t.Fatalf("plugin result batch sizes = %#v, want %#v", got, want)
	}
	if got, want := pluginResultStreamTimeout(maxPluginResultsPerStream), 165*time.Second; got != want {
		t.Fatalf("full plugin result batch timeout = %s, want %s", got, want)
	}
}

func TestPluginResultStreamTimeoutUsesTwoWorkerWaves(t *testing.T) {
	tests := []struct {
		chunks int
		want   time.Duration
	}{
		{chunks: 1, want: 45 * time.Second},
		{chunks: 2, want: 45 * time.Second},
		{chunks: 3, want: 75 * time.Second},
		{chunks: 10, want: 165 * time.Second},
	}

	for _, tt := range tests {
		if got := pluginResultStreamTimeout(tt.chunks); got != tt.want {
			t.Errorf("pluginResultStreamTimeout(%d) = %s, want %s", tt.chunks, got, tt.want)
		}
	}
}

func TestPushPluginResultsRetainsBatchOnNegativeAcknowledgement(t *testing.T) {
	manager := &PluginManager{results: make(chan PluginResult, 1)}
	manager.results <- testPendingPluginResult("assignment-1", "first")

	loop := &PushLoop{
		server: &Server{
			config:        &ServerConfig{AgentID: "agent-1", HostIP: "192.0.2.10"},
			pluginManager: manager,
		},
		logger: logger.NewTestLogger(),
		pluginResultStreamStatus: func(
			_ context.Context,
			_ []*proto.GatewayStatusChunk,
		) (*proto.GatewayStatusResponse, error) {
			return &proto.GatewayStatusResponse{Received: false}, nil
		},
	}

	if loop.pushPluginResults(t.Context()) {
		t.Fatal("negative acknowledgement must not report a successful plugin result push")
	}
	if got := len(loop.pendingPluginResults); got != 1 {
		t.Fatalf("pending plugin results after negative acknowledgement = %d, want 1", got)
	}
}

func TestPushPluginResultsRetriesOnlyChunksTheNegativeAcknowledgementLeftUncommitted(t *testing.T) {
	all := []string{"assignment-1", "assignment-2", "assignment-3"}
	tests := []struct {
		name      string
		committed []int32
		wantRetry []string
	}{
		// A gateway that predates committed_chunk_indexes only says received=false.
		{name: "whole-stream negative acknowledgement", committed: nil, wantRetry: all},
		{name: "partial commit", committed: []int32{0, 2}, wantRetry: []string{"assignment-2"}},
		{name: "indexes outside the stream", committed: []int32{-1, 3}, wantRetry: all},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			manager := &PluginManager{results: make(chan PluginResult, len(all)+1)}
			for _, assignment := range all {
				manager.results <- testPendingPluginResult(assignment, assignment)
			}

			var attempts [][]string
			loop := &PushLoop{
				server: &Server{
					config:        &ServerConfig{AgentID: "agent-1", HostIP: "192.0.2.10"},
					pluginManager: manager,
				},
				logger: logger.NewTestLogger(),
				pluginResultStreamStatus: func(
					_ context.Context,
					chunks []*proto.GatewayStatusChunk,
				) (*proto.GatewayStatusResponse, error) {
					attempts = append(attempts, pluginResultAssignments(t, chunks))
					if len(attempts) == 1 {
						return &proto.GatewayStatusResponse{CommittedChunkIndexes: tt.committed}, nil
					}
					return &proto.GatewayStatusResponse{Received: true}, nil
				},
			}

			if loop.pushPluginResults(t.Context()) {
				t.Fatal("negative acknowledgement must not report a successful plugin result push")
			}
			// A result produced during the retry must not join the retained remainder.
			manager.results <- testPendingPluginResult("assignment-later", "later")
			if !loop.pushPluginResults(t.Context()) {
				t.Fatal("later positive acknowledgement must clear the retained set")
			}
			if got, want := attempts, [][]string{all, tt.wantRetry}; !equalStringMatrix(got, want) {
				t.Fatalf("delivery attempts = %#v, want %#v", got, want)
			}
			if got := len(loop.pendingPluginResults); got != 0 {
				t.Fatalf("pending plugin results = %d, want 0", got)
			}
		})
	}
}

func TestPushPluginResultsPoisonDropsCompleteSetAndLaterWorkProgresses(t *testing.T) {
	tests := []struct {
		name       string
		err        error
		wantReason poisonReason
	}{
		{name: "local chunk excess", err: agentgateway.ErrStreamStatusChunkTooLarge, wantReason: poisonReasonChunkTooLarge},
		{name: "local stream excess", err: agentgateway.ErrStreamStatusBudgetExceeded, wantReason: poisonReasonStreamBudgetExceeded},
		{name: "remote invalid argument", err: fmt.Errorf("stream failed: %w", status.Error(codes.InvalidArgument, "invalid plugin-result payload")), wantReason: poisonReasonInvalidArgument},
		{name: "remote payload too large", err: fmt.Errorf("stream failed: %w", status.Error(codes.ResourceExhausted, "payload_too_large")), wantReason: poisonReasonPayloadTooLarge},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			manager := &PluginManager{results: make(chan PluginResult, 3)}
			manager.results <- testPendingPluginResult("poison-1", "first")
			manager.results <- testPendingPluginResult("poison-2", "second")
			attempt := 0
			logCapture := newCapturingTestLogger()
			loop := &PushLoop{
				server: &Server{
					config:        &ServerConfig{AgentID: "agent-1", HostIP: "192.0.2.10"},
					pluginManager: manager,
				},
				logger: logCapture,
				pluginResultStreamStatus: func(
					_ context.Context,
					_ []*proto.GatewayStatusChunk,
				) (*proto.GatewayStatusResponse, error) {
					attempt++
					if attempt == 1 {
						return nil, tt.err
					}
					return &proto.GatewayStatusResponse{Received: true}, nil
				},
			}

			if loop.pushPluginResults(t.Context()) {
				t.Fatal("poison drop must not count as receipt")
			}
			if got := len(loop.pendingPluginResults); got != 0 {
				t.Fatalf("pending poison results = %d, want 0", got)
			}
			if errMsgs := logCapture.messagesAtLevel(t, "error"); len(errMsgs) != 1 {
				t.Fatalf("poison drop error logs = %v, want 1 error log", errMsgs)
			}
			items, bytes := loop.server.deliveryTelemetry.poisonDropTotals(retainedSourcePlugin, tt.wantReason)
			if items != 2 || bytes == 0 {
				t.Fatalf("poison totals = (items=%d, bytes=%d), want (2, >0)", items, bytes)
			}

			manager.results <- testPendingPluginResult("valid-later", "later")
			if !loop.pushPluginResults(t.Context()) {
				t.Fatal("later valid plugin result must progress")
			}
			if attempt != 2 {
				t.Fatalf("stream attempts = %d, want 2 (poison set must not replay)", attempt)
			}
		})
	}
}

func TestRetainedPoisonDropReasonPreservesRetryableFailures(t *testing.T) {
	tests := []error{
		agentgateway.ErrGatewayNotConnected,
		status.Error(codes.Unavailable, "transport unavailable"),
		status.Error(codes.ResourceExhausted, "configured lane capacity"),
		status.Error(codes.DeadlineExceeded, "lane execution timeout"),
	}

	for _, err := range tests {
		if reason, terminal := retainedPoisonDropReason(err); terminal {
			t.Errorf("retainedPoisonDropReason(%v) = (%q, true), want retryable", err, reason.label())
		}
	}
}

func TestPushPluginResultsTransportCapabilitiesAreHostAsserted(t *testing.T) {
	manager := &PluginManager{results: make(chan PluginResult, 1)}
	result := testPendingPluginResult("assignment-1", "ok")
	result.Payload = []byte(`{
		"status":"OK",
		"summary":"ok",
		"labels":{
			"capabilities":["forged:v1"],
			"plugin-host-authority:v1":"forged",
			"proxmox-identity:v3":"forged"
		}
	}`)
	manager.results <- result

	loop := &PushLoop{
		server: &Server{
			config:        &ServerConfig{AgentID: "agent-1", HostIP: "192.0.2.10"},
			pluginManager: manager,
		},
		logger: logger.NewTestLogger(),
		pluginResultStreamStatus: func(
			_ context.Context,
			chunks []*proto.GatewayStatusChunk,
		) (*proto.GatewayStatusResponse, error) {
			assertPluginResultTransportCapabilities(t, chunks)
			if got := len(chunks); got != 1 {
				t.Fatalf("plugin result chunk count = %d, want 1", got)
			}

			var payload struct {
				Labels map[string]interface{} `json:"labels"`
			}
			if err := json.Unmarshal(chunks[0].Services[0].Message, &payload); err != nil {
				t.Fatalf("decode plugin result payload: %v", err)
			}
			if got := payload.Labels["plugin-host-authority:v1"]; got != "forged" {
				t.Fatalf("plugin-controlled label = %#v, want it confined to the payload", got)
			}

			return &proto.GatewayStatusResponse{Received: true}, nil
		},
	}

	if !loop.pushPluginResults(t.Context()) {
		t.Fatal("host-asserted plugin result capability stream must be acknowledged")
	}
}

func testPendingPluginResult(assignmentID, summary string) PluginResult {
	return PluginResult{
		AssignmentID: assignmentID,
		PluginID:     "plugin-1",
		PluginName:   "Plugin One",
		Payload:      []byte(`{"status":"OK","summary":"` + summary + `"}`),
		ObservedAt:   time.Date(2026, 7, 12, 1, 2, 3, 0, time.UTC),
	}
}

func pluginResultAssignments(t *testing.T, chunks []*proto.GatewayStatusChunk) []string {
	t.Helper()

	assignments := make([]string, 0, len(chunks))
	for _, chunk := range chunks {
		if len(chunk.Services) != 1 {
			t.Fatalf("chunk service count = %d, want 1", len(chunk.Services))
		}

		assignments = append(assignments, pluginAssignmentIDFromMessage(t, chunk.Services[0].Message))
	}

	return assignments
}

func assertPluginResultTransportCapabilities(t *testing.T, chunks []*proto.GatewayStatusChunk) {
	t.Helper()

	for _, chunk := range chunks {
		if got, want := chunk.GetCapabilities(), pluginResultTransportCapabilities(); !slices.Equal(got, want) {
			t.Fatalf("plugin result delivery capabilities = %#v, want %#v", got, want)
		}
	}
}

func pluginAssignmentIDFromMessage(t *testing.T, message []byte) string {
	t.Helper()

	var payload struct {
		Labels map[string]string `json:"labels"`
	}
	if err := json.Unmarshal(message, &payload); err != nil {
		t.Fatalf("decode plugin result: %v", err)
	}

	return payload.Labels["assignment_id"]
}

func equalStringMatrix(left, right [][]string) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if !equalStrings(left[i], right[i]) {
			return false
		}
	}

	return true
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}

	return true
}

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

type transientPluginGateway struct {
	proto.UnimplementedAgentGatewayServiceServer

	mu                sync.Mutex
	streamCalls       int
	pushCalls         int
	streamAssignments [][]string
	pushedRequests    []*proto.GatewayStatusRequest
}

func (g *transientPluginGateway) StreamStatus(
	stream grpc.ClientStreamingServer[proto.GatewayStatusChunk, proto.GatewayStatusResponse],
) error {
	var assignments []string
	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if len(chunk.GetServices()) == 1 {
			var payload struct {
				Labels map[string]string `json:"labels"`
			}
			if err := json.Unmarshal(chunk.GetServices()[0].GetMessage(), &payload); err == nil {
				assignments = append(assignments, payload.Labels["assignment_id"])
			}
		}
	}

	g.mu.Lock()
	g.streamCalls++
	call := g.streamCalls
	if call > 1 {
		g.streamAssignments = append(g.streamAssignments, assignments)
	}
	g.mu.Unlock()

	if call == 1 {
		return status.Error(codes.Unavailable, "gateway restarting")
	}

	return stream.SendAndClose(&proto.GatewayStatusResponse{Received: true})
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

func TestPushPluginResultsAndTelemetryTransientGatewayFailureLogsWarnAndDeliversOnNextCycle(t *testing.T) {
	t.Setenv("SR_ALLOW_INSECURE", "true")
	const retryAssignment = "assignment-retry-1"

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
		results: make(chan PluginResult, 4),
		stats: pluginEngineStats{
			assignmentsTotal:    1,
			assignmentsAdmitted: 1,
			execTotal:           3,
		},
	}
	manager.results <- testPendingPluginResult(retryAssignment, "first")

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

	// Cycle 1: gateway fails both StreamStatus and PushStatus once.
	if loop.pushPluginResults(t.Context()) {
		t.Fatal("transient StreamStatus failure must not report success")
	}
	if got := len(loop.pendingPluginResults); got != 1 {
		t.Fatalf("pending plugin results after transient failure = %d, want 1", got)
	}
	if err := client.Connect(t.Context()); err != nil {
		t.Fatalf("reconnect after StreamStatus failure: %v", err)
	}
	if loop.pushPluginTelemetry(t.Context()) {
		t.Fatal("transient PushStatus failure must not report success")
	}

	if errMsgs := logCapture.messagesAtLevel(t, "error"); len(errMsgs) != 0 {
		t.Fatalf("transient plugin delivery failure logged at error: %v, want warn only", errMsgs)
	}
	warnMsgs := logCapture.messagesAtLevel(t, "warn")
	if len(warnMsgs) < 2 {
		t.Fatalf("expected warning logs for both plugin results and telemetry retry, got %v", warnMsgs)
	}

	// Cycle 2: gateway recovers; both the retained result and telemetry arrive.
	if err := client.Connect(t.Context()); err != nil {
		t.Fatalf("reconnect for second push cycle: %v", err)
	}
	if !loop.pushPluginResults(t.Context()) {
		t.Fatal("second push cycle must deliver retained plugin results")
	}
	if got := len(loop.pendingPluginResults); got != 0 {
		t.Fatalf("pending plugin results after retry success = %d, want 0", got)
	}
	if !loop.pushPluginTelemetry(t.Context()) {
		t.Fatal("second push cycle must deliver plugin telemetry")
	}

	gw.mu.Lock()
	gotStreams := slices.Clone(gw.streamAssignments)
	gotRequests := slices.Clone(gw.pushedRequests)
	gw.mu.Unlock()

	if !equalStringMatrix(gotStreams, [][]string{{retryAssignment}}) {
		t.Fatalf("delivered plugin result streams = %#v, want [[%q]]", gotStreams, retryAssignment)
	}
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
	if errMsgs := logCapture.messagesAtLevel(t, "error"); len(errMsgs) != 0 {
		t.Fatalf("unexpected error logs after retry cycle: %v", errMsgs)
	}
}
