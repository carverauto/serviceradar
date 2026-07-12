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
	"encoding/json"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
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
			assertRetainedPluginResultCapability(t, chunks)
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
			assertRetainedPluginResultCapability(t, chunks)
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
	if got, want := pluginResultStreamTimeout(maxPluginResultsPerStream), 110*time.Second; got != want {
		t.Fatalf("full plugin result batch timeout = %s, want %s", got, want)
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

func assertRetainedPluginResultCapability(t *testing.T, chunks []*proto.GatewayStatusChunk) {
	t.Helper()

	for _, chunk := range chunks {
		if got, want := chunk.GetCapabilities(), []string{pluginResultRetainedDeliveryCapabilityV1}; !slices.Equal(got, want) {
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
