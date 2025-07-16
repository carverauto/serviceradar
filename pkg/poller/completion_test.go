/*
 * Copyright 2025 Carver Automation Corporation.
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

package poller

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestPollerCompletionTracking(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	clock := NewMockClock(ctrl)
	log := createTestLogger()

	config := &Config{
		PollerID: "test-poller",
	}

	poller, err := New(context.Background(), config, clock, log)
	require.NoError(t, err)
	require.NotNil(t, poller)

	// Test updating agent completion
	completionStatus := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_IN_PROGRESS,
		TargetSequence:   "seq-123",
		TotalTargets:     10,
		CompletedTargets: 5,
		CompletionTime:   0,
	}

	poller.updateAgentCompletion("agent1", completionStatus)

	// Verify completion was stored
	poller.completionMu.RLock()
	stored, exists := poller.agentCompletions["agent1"]
	poller.completionMu.RUnlock()

	require.True(t, exists, "Agent completion should be stored")
	assert.Equal(t, proto.SweepCompletionStatus_IN_PROGRESS, stored.Status)
	assert.Equal(t, "seq-123", stored.TargetSequence)
	assert.Equal(t, int32(10), stored.TotalTargets)
	assert.Equal(t, int32(5), stored.CompletedTargets)
}

func TestPollerAggregatedCompletion(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	clock := NewMockClock(ctrl)
	log := createTestLogger()

	config := &Config{
		PollerID: "test-poller",
	}

	poller, err := New(context.Background(), config, clock, log)
	require.NoError(t, err)

	// Add completion status from multiple agents
	agent1Status := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_IN_PROGRESS,
		TargetSequence:   "seq-123",
		TotalTargets:     10,
		CompletedTargets: 8,
		CompletionTime:   0,
	}

	agent2Status := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		TargetSequence:   "seq-123",
		TotalTargets:     15,
		CompletedTargets: 15,
		CompletionTime:   time.Now().Unix(),
	}

	poller.updateAgentCompletion("agent1", agent1Status)
	poller.updateAgentCompletion("agent2", agent2Status)

	// Get aggregated completion
	aggregated := poller.getAggregatedCompletion()

	require.NotNil(t, aggregated, "Should return aggregated completion")
	assert.Equal(t, proto.SweepCompletionStatus_COMPLETED, aggregated.Status, "Should use highest status")
	assert.Equal(t, "seq-123", aggregated.TargetSequence)
	assert.Equal(t, int32(25), aggregated.TotalTargets, "Should sum total targets")
	assert.Equal(t, int32(23), aggregated.CompletedTargets, "Should sum completed targets")
	assert.Equal(t, agent2Status.CompletionTime, aggregated.CompletionTime, "Should use latest completion time")
}

func TestPollerAggregatedCompletion_NoAgents(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	clock := NewMockClock(ctrl)
	log := createTestLogger()

	config := &Config{
		PollerID: "test-poller",
	}

	poller, err := New(context.Background(), config, clock, log)
	require.NoError(t, err)

	// Get aggregated completion with no agents
	aggregated := poller.getAggregatedCompletion()
	assert.Nil(t, aggregated, "Should return nil when no agent completions exist")
}

func TestResultsPollerCompletionForwarding(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := &MockAgentServiceClient{}
	clock := NewMockClock(ctrl)
	log := createTestLogger()

	// Create poller
	config := &Config{
		PollerID: "test-poller",
	}

	poller, err := New(context.Background(), config, clock, log)
	require.NoError(t, err)

	// Add some agent completion status to the poller
	agentCompletion := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		TargetSequence:   "seq-123",
		TotalTargets:     10,
		CompletedTargets: 10,
		CompletionTime:   time.Now().Unix(),
	}
	poller.updateAgentCompletion("agent1", agentCompletion)

	// Create ResultsPoller for sync service
	resultsPoller := &ResultsPoller{
		client:    mockClient,
		check:     Check{Name: "sync", Type: "grpc"},
		pollerID:  "test-poller",
		agentName: "sync-agent",
		interval:  time.Minute,
		poller:    poller,
		logger:    log,
	}

	// Mock GetResults call to sync service - should include completion status
	expectedRequest := &proto.ResultsRequest{
		ServiceName:  "sync",
		ServiceType:  "grpc",
		AgentId:      "sync-agent",
		PollerId:     "test-poller",
		Details:      "",
		LastSequence: "",
		CompletionStatus: &proto.SweepCompletionStatus{
			Status:           proto.SweepCompletionStatus_COMPLETED,
			TargetSequence:   "seq-123",
			TotalTargets:     10,
			CompletedTargets: 10,
			CompletionTime:   agentCompletion.CompletionTime,
		},
	}

	mockResponse := &proto.ResultsResponse{
		Available:       true,
		Data:            []byte("[]"),
		ServiceName:     "sync",
		ServiceType:     "grpc",
		CurrentSequence: "1",
		HasNewData:      true,
		AgentId:         "sync-agent",
	}

	mockClient.On("GetResults", context.Background(), expectedRequest).Return(mockResponse, nil)

	// Execute GetResults - should forward completion status
	status := resultsPoller.executeGetResults(context.Background())

	require.NotNil(t, status, "Should return status")
	assert.Equal(t, "sync", status.ServiceName)
	assert.True(t, status.Available)
}

func TestResultsPollerCompletionForwarding_NonSyncService(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := &MockAgentServiceClient{}
	clock := NewMockClock(ctrl)
	log := createTestLogger()

	// Create poller
	config := &Config{
		PollerID: "test-poller",
	}

	poller, err := New(context.Background(), config, clock, log)
	require.NoError(t, err)

	// Add some agent completion status to the poller
	agentCompletion := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		TargetSequence:   "seq-123",
		TotalTargets:     10,
		CompletedTargets: 10,
		CompletionTime:   time.Now().Unix(),
	}
	poller.updateAgentCompletion("agent1", agentCompletion)

	// Create ResultsPoller for regular agent service (not sync)
	resultsPoller := &ResultsPoller{
		client:    mockClient,
		check:     Check{Name: "sweep", Type: "sweep"},
		pollerID:  "test-poller",
		agentName: "regular-agent",
		interval:  time.Minute,
		poller:    poller,
		logger:    log,
	}

	// Mock GetResults call to regular agent - should NOT include completion status
	expectedRequest := &proto.ResultsRequest{
		ServiceName:  "sweep",
		ServiceType:  "sweep",
		AgentId:      "regular-agent",
		PollerId:     "test-poller",
		Details:      "",
		LastSequence: "",
		// No CompletionStatus field set
	}

	mockResponse := &proto.ResultsResponse{
		Available:       true,
		Data:            []byte("[]"),
		ServiceName:     "sweep",
		ServiceType:     "sweep",
		CurrentSequence: "1",
		HasNewData:      true,
		AgentId:         "regular-agent",
		SweepCompletion: &proto.SweepCompletionStatus{
			Status:           proto.SweepCompletionStatus_IN_PROGRESS,
			TargetSequence:   "seq-456",
			TotalTargets:     5,
			CompletedTargets: 3,
		},
	}

	mockClient.On("GetResults", context.Background(), expectedRequest).Return(mockResponse, nil)

	// Execute GetResults - should capture completion status from response
	status := resultsPoller.executeGetResults(context.Background())

	require.NotNil(t, status, "Should return status")
	assert.Equal(t, "sweep", status.ServiceName)
	assert.True(t, status.Available)

	// Verify completion status was captured from response
	assert.NotNil(t, resultsPoller.lastCompletionStatus)
	assert.Equal(t, proto.SweepCompletionStatus_IN_PROGRESS, resultsPoller.lastCompletionStatus.Status)
	assert.Equal(t, "seq-456", resultsPoller.lastCompletionStatus.TargetSequence)

	// Verify it was also stored in the poller's aggregation
	poller.completionMu.RLock()
	storedStatus, exists := poller.agentCompletions["regular-agent"]
	poller.completionMu.RUnlock()

	require.True(t, exists, "Agent completion should be stored in poller")
	assert.Equal(t, proto.SweepCompletionStatus_IN_PROGRESS, storedStatus.Status)
	assert.Equal(t, "seq-456", storedStatus.TargetSequence)
	assert.Equal(t, int32(5), storedStatus.TotalTargets)
	assert.Equal(t, int32(3), storedStatus.CompletedTargets)
}

// createTestLogger creates a simple logger for tests
func createTestLogger() logger.Logger {
	return logger.NewTestLogger()
}
