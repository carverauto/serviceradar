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
	"encoding/json"
	"io"
	"net"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// recordedPluginStream is one StreamStatus RPC as the gateway saw it on the wire.
type recordedPluginStream struct {
	assignments []string
	indexes     []int32
	totals      []int32
	finals      []bool
}

// partialAckGateway is a disposable AgentGatewayService peer. It speaks the real
// StreamStatus RPC so the agent's production push path, not the test seam, decides
// which retained plugin results to release.
type partialAckGateway struct {
	proto.UnimplementedAgentGatewayServiceServer

	mu      sync.Mutex
	streams []recordedPluginStream
	respond func(call int) *proto.GatewayStatusResponse
}

func (g *partialAckGateway) StreamStatus(stream grpc.ClientStreamingServer[proto.GatewayStatusChunk, proto.GatewayStatusResponse]) error {
	recorded := recordedPluginStream{}
	for {
		chunk, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		recorded.assignments = append(recorded.assignments, pluginAssignmentOnWire(chunk))
		recorded.indexes = append(recorded.indexes, chunk.GetChunkIndex())
		recorded.totals = append(recorded.totals, chunk.GetTotalChunks())
		recorded.finals = append(recorded.finals, chunk.GetIsFinal())
	}

	g.mu.Lock()
	call := len(g.streams)
	g.streams = append(g.streams, recorded)
	g.mu.Unlock()

	resp := g.respond(call)
	if resp == nil {
		resp = &proto.GatewayStatusResponse{Received: true}
	}
	return stream.SendAndClose(resp)
}

func (g *partialAckGateway) snapshot() []recordedPluginStream {
	g.mu.Lock()
	defer g.mu.Unlock()
	out := make([]recordedPluginStream, len(g.streams))
	copy(out, g.streams)
	return out
}

func pluginAssignmentOnWire(chunk *proto.GatewayStatusChunk) string {
	if chunk == nil || len(chunk.GetServices()) != 1 {
		return ""
	}
	var payload struct {
		Labels map[string]string `json:"labels"`
	}
	if err := json.Unmarshal(chunk.GetServices()[0].GetMessage(), &payload); err != nil {
		return ""
	}
	return payload.Labels["assignment_id"]
}

func startPartialAckGateway(t *testing.T, respond func(call int) *proto.GatewayStatusResponse) (*PushLoop, *PluginManager, *partialAckGateway, *agentgateway.GatewayClient) {
	t.Helper()
	t.Setenv("SR_ALLOW_INSECURE", "true")

	gw := &partialAckGateway{respond: respond}
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(server, gw)
	go func() { _ = server.Serve(lis) }()
	t.Cleanup(func() {
		server.Stop()
		_ = lis.Close()
	})

	client := agentgateway.NewGatewayClient(lis.Addr().String(), nil, logger.NewTestLogger())
	if err := client.Connect(t.Context()); err != nil {
		t.Fatalf("connect real gateway client: %v", err)
	}
	t.Cleanup(func() { _ = client.Disconnect() })

	manager := &PluginManager{results: make(chan PluginResult, 8)}
	loop := &PushLoop{
		server: &Server{
			config: &ServerConfig{
				AgentID:   "agent-1",
				Partition: "default",
				HostIP:    "192.0.2.10",
			},
			pluginManager: manager,
		},
		logger:  logger.NewTestLogger(),
		gateway: client,
	}
	return loop, manager, gw, client
}

func enqueuePluginResults(manager *PluginManager, assignments ...string) {
	for _, assignment := range assignments {
		manager.results <- PluginResult{
			AssignmentID: assignment,
			PluginID:     "plugin-1",
			PluginName:   "Plugin One",
			Payload:      []byte(`{"status":"OK","summary":"` + assignment + `"}`),
			ObservedAt:   time.Date(2026, 7, 12, 1, 2, 3, 0, time.UTC),
		}
	}
}

func requireStream(t *testing.T, got recordedPluginStream, assignments []string, totals int32) {
	t.Helper()
	if !slices.Equal(got.assignments, assignments) {
		t.Fatalf("stream assignments = %#v, want %#v", got.assignments, assignments)
	}
	wantIndexes := make([]int32, len(assignments))
	wantTotals := make([]int32, len(assignments))
	wantFinals := make([]bool, len(assignments))
	for i := range assignments {
		wantIndexes[i] = int32(i)
		wantTotals[i] = totals
		wantFinals[i] = i == len(assignments)-1
	}
	if !slices.Equal(got.indexes, wantIndexes) || !slices.Equal(got.totals, wantTotals) || !slices.Equal(got.finals, wantFinals) {
		t.Fatalf("stream shape indexes=%v totals=%v finals=%v, want indexes=%v totals=%v finals=%v", got.indexes, got.totals, got.finals, wantIndexes, wantTotals, wantFinals)
	}
}

// The agent push loop dials a real gRPC gateway and uses the production
// StreamStatus path. A NACK that names committed chunks must release only those
// results; the retry is a new contiguous stream and does not pick up results
// produced while the remainder was pending.
func TestPushPluginResultsPartialAckOverRealGatewayStream(t *testing.T) {
	const (
		first  = "assignment-1"
		second = "assignment-2"
		third  = "assignment-3"
		later  = "assignment-later"
	)
	all := []string{first, second, third}

	t.Run("partial commit retries only the uncommitted result", func(t *testing.T) {
		loop, manager, gw, client := startPartialAckGateway(t, func(call int) *proto.GatewayStatusResponse {
			if call == 0 {
				return &proto.GatewayStatusResponse{
					Received:              false,
					Directives:            nil,
					CommittedChunkIndexes: []int32{0, 2},
				}
			}
			return &proto.GatewayStatusResponse{Received: true}
		})
		enqueuePluginResults(manager, all...)

		if loop.pushPluginResults(t.Context()) {
			t.Fatal("negative acknowledgement must not count as a successful push")
		}
		if !client.IsConnected() {
			t.Fatal("negative acknowledgement dropped the shared gateway connection")
		}
		if got := len(loop.pendingPluginResults); got != 1 {
			t.Fatalf("pending after partial ack = %d, want 1", got)
		}

		enqueuePluginResults(manager, later)
		if !loop.pushPluginResults(t.Context()) {
			t.Fatal("acknowledgement of the remainder must succeed")
		}
		if got := len(loop.pendingPluginResults); got != 0 {
			t.Fatalf("pending after remainder ack = %d, want 0", got)
		}
		if !loop.pushPluginResults(t.Context()) {
			t.Fatal("result produced during the retry must be delivered on the next push")
		}

		streams := gw.snapshot()
		if len(streams) != 3 {
			t.Fatalf("stream count = %d, want 3", len(streams))
		}
		requireStream(t, streams[0], all, 3)
		requireStream(t, streams[1], []string{second}, 1)
		requireStream(t, streams[2], []string{later}, 1)
		t.Logf("partial-ack streams: first=%v retry=%v next=%v connected_after_nack=true", streams[0].assignments, streams[1].assignments, streams[2].assignments)
	})

	t.Run("absent committed indexes retry the whole stream", func(t *testing.T) {
		loop, manager, gw, client := startPartialAckGateway(t, func(call int) *proto.GatewayStatusResponse {
			if call == 0 {
				return &proto.GatewayStatusResponse{Received: false}
			}
			return &proto.GatewayStatusResponse{Received: true}
		})
		enqueuePluginResults(manager, all...)

		if loop.pushPluginResults(t.Context()) {
			t.Fatal("older-gateway negative acknowledgement must not count as success")
		}
		if !client.IsConnected() {
			t.Fatal("older-gateway negative acknowledgement dropped the shared gateway connection")
		}
		enqueuePluginResults(manager, later)
		if !loop.pushPluginResults(t.Context()) {
			t.Fatal("acknowledgement of the full retry must succeed")
		}

		streams := gw.snapshot()
		if len(streams) != 2 {
			t.Fatalf("stream count = %d, want 2", len(streams))
		}
		requireStream(t, streams[0], all, 3)
		requireStream(t, streams[1], all, 3)
		if !loop.pushPluginResults(t.Context()) {
			t.Fatal("result held behind the full retry must be delivered next")
		}
		streams = gw.snapshot()
		requireStream(t, streams[2], []string{later}, 1)
		t.Logf("older-gateway streams: first=%v retry=%v next=%v", streams[0].assignments, streams[1].assignments, streams[2].assignments)
	})

	t.Run("indexes outside the stream retry the whole stream", func(t *testing.T) {
		loop, manager, gw, _ := startPartialAckGateway(t, func(call int) *proto.GatewayStatusResponse {
			if call == 0 {
				return &proto.GatewayStatusResponse{Received: false, CommittedChunkIndexes: []int32{-1, 3, 99}}
			}
			return &proto.GatewayStatusResponse{Received: true}
		})
		enqueuePluginResults(manager, all...)
		if loop.pushPluginResults(t.Context()) {
			t.Fatal("out-of-range acknowledgement must not count as success")
		}
		if !loop.pushPluginResults(t.Context()) {
			t.Fatal("retry after out-of-range indexes must succeed")
		}
		streams := gw.snapshot()
		if len(streams) != 2 {
			t.Fatalf("stream count = %d, want 2", len(streams))
		}
		requireStream(t, streams[0], all, 3)
		requireStream(t, streams[1], all, 3)
		t.Logf("out-of-range streams: first=%v retry=%v", streams[0].assignments, streams[1].assignments)
	})

	t.Run("received true releases every result even when the index list is partial", func(t *testing.T) {
		loop, manager, gw, _ := startPartialAckGateway(t, func(int) *proto.GatewayStatusResponse {
			return &proto.GatewayStatusResponse{Received: true, CommittedChunkIndexes: []int32{0}}
		})
		enqueuePluginResults(manager, all...)
		if !loop.pushPluginResults(t.Context()) {
			t.Fatal("received true must release the stream")
		}
		if got := len(loop.pendingPluginResults); got != 0 {
			t.Fatalf("pending after received true = %d, want 0", got)
		}
		enqueuePluginResults(manager, later)
		if !loop.pushPluginResults(t.Context()) {
			t.Fatal("next result after a full acknowledgement must be delivered")
		}
		streams := gw.snapshot()
		if len(streams) != 2 {
			t.Fatalf("stream count = %d, want 2", len(streams))
		}
		requireStream(t, streams[0], all, 3)
		requireStream(t, streams[1], []string{later}, 1)
		t.Logf("received-true streams: first=%v next=%v", streams[0].assignments, streams[1].assignments)
	})

	t.Run("naming every chunk releases the set without refilling it", func(t *testing.T) {
		loop, manager, gw, client := startPartialAckGateway(t, func(call int) *proto.GatewayStatusResponse {
			if call == 0 {
				return &proto.GatewayStatusResponse{Received: false, CommittedChunkIndexes: []int32{2, 0, 0, 1}}
			}
			return &proto.GatewayStatusResponse{Received: true}
		})
		enqueuePluginResults(manager, all...)
		if loop.pushPluginResults(t.Context()) {
			t.Fatal("negative acknowledgement must not count as success when every chunk is named")
		}
		if !client.IsConnected() {
			t.Fatal("full partial acknowledgement dropped the shared gateway connection")
		}
		if got := len(loop.pendingPluginResults); got != 0 {
			t.Fatalf("pending after every chunk was named = %d, want 0", got)
		}
		enqueuePluginResults(manager, later)
		if !loop.pushPluginResults(t.Context()) {
			t.Fatal("a result produced after the set was released must be its own stream")
		}
		streams := gw.snapshot()
		if len(streams) != 2 {
			t.Fatalf("stream count = %d, want 2", len(streams))
		}
		requireStream(t, streams[0], all, 3)
		requireStream(t, streams[1], []string{later}, 1)
		t.Logf("all-named streams: first=%v next=%v", streams[0].assignments, streams[1].assignments)
	})
}
