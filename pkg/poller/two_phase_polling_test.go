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
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
)

// MockPollerServiceClient is a mock for testing core reporting
type MockPollerServiceClient struct {
	mock.Mock
}

func (m *MockPollerServiceClient) ReportStatus(
	ctx context.Context, req *proto.PollerStatusRequest, _ ...grpc.CallOption) (*proto.PollerStatusResponse, error) {
	args := m.Called(ctx, req)
	return args.Get(0).(*proto.PollerStatusResponse), args.Error(1)
}

// TestTwoPhasePolling_SweepThenSync tests the core two-phase polling behavior
func TestTwoPhasePolling_SweepThenSync(t *testing.T) {
	mockAgentClient := &MockAgentServiceClient{}
	mockCoreClient := &MockPollerServiceClient{}

	// Create poller with mixed services
	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
			Agents: map[string]AgentConfig{
				"sweep-agent": {
					Address: "127.0.0.1:50051",
					Checks: []Check{
						{
							Name:            "network_sweep",
							Type:            serviceTypeSweep,
							Details:         "192.168.1.0/24",
							ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
						},
					},
				},
				"sync-agent": {
					Address: "127.0.0.1:50052",
					Checks: []Check{
						{
							Name:            "sync",
							Type:            checkTypeGRPC,
							Details:         "127.0.0.1:50058",
							ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
						},
					},
				},
			},
		},
		coreClient:       mockCoreClient,
		agents:           make(map[string]*AgentPoller),
		agentCompletions: make(map[string]*proto.SweepCompletionStatus),
		logger:           logger.NewTestLogger(),
	}

	// Create mock agent pollers
	sweepAgentConfig := poller.config.Agents["sweep-agent"]
	syncAgentConfig := poller.config.Agents["sync-agent"]
	sweepAgent := newAgentPoller("sweep-agent", &sweepAgentConfig, mockAgentClient, poller)
	syncAgent := newAgentPoller("sync-agent", &syncAgentConfig, mockAgentClient, poller)

	poller.agents["sweep-agent"] = sweepAgent
	poller.agents["sync-agent"] = syncAgent

	// Variables to track call order
	var callOrder []string

	var mu sync.Mutex

	// Mock sweep service GetStatus (called in phase 1)
	mockAgentClient.On("GetStatus", mock.Anything, mock.MatchedBy(func(req *proto.StatusRequest) bool {
		return req.ServiceName == "network_sweep" && req.ServiceType == serviceTypeSweep
	})).Return(&proto.StatusResponse{
		Available:   true,
		Message:     []byte(`{"status": "active"}`),
		ServiceName: "network_sweep",
		ServiceType: serviceTypeSweep,
		AgentId:     "sweep-agent",
	}, nil)

	// Mock sync service GetStatus (called in phase 2)
	mockAgentClient.On("GetStatus", mock.Anything, mock.MatchedBy(func(req *proto.StatusRequest) bool {
		return req.ServiceName == "sync" && req.ServiceType == checkTypeGRPC
	})).Return(&proto.StatusResponse{
		Available:   true,
		Message:     []byte(`{"status": "healthy"}`),
		ServiceName: "sync",
		ServiceType: checkTypeGRPC,
		AgentId:     "sync-agent",
	}, nil)

	// Mock sweep service GetResults - returns IN_PROGRESS first, then COMPLETED
	mockAgentClient.On("GetResults", mock.Anything, mock.MatchedBy(func(req *proto.ResultsRequest) bool {
		return req.ServiceName == "network_sweep" && req.ServiceType == serviceTypeSweep
	})).Return(&proto.ResultsResponse{
		Available:       true,
		Data:            []byte(`{"total_hosts": 10, "available_hosts": 8}`),
		ServiceName:     "network_sweep",
		ServiceType:     serviceTypeSweep,
		AgentId:         "sweep-agent",
		PollerId:        "test-poller",
		CurrentSequence: "1",
		HasNewData:      true,
		SweepCompletion: &proto.SweepCompletionStatus{
			Status:           proto.SweepCompletionStatus_COMPLETED,
			CompletionTime:   time.Now().Unix(),
			TargetSequence:   "seq-1",
			TotalTargets:     10,
			CompletedTargets: 10,
		},
	}, nil).Run(func(_ mock.Arguments) {
		mu.Lock()
		defer mu.Unlock()

		callOrder = append(callOrder, "sweep-results")
	})

	// Mock sync service GetResults - should be called after sweep completion
	mockAgentClient.On("GetResults", mock.Anything, mock.MatchedBy(func(req *proto.ResultsRequest) bool {
		return req.ServiceName == "sync" && req.ServiceType == checkTypeGRPC
	})).Return(&proto.ResultsResponse{
		Available:       true,
		Data:            []byte(`{"devices": [{"ip": "192.168.1.1", "source": "netbox"}]}`),
		ServiceName:     "sync",
		ServiceType:     checkTypeGRPC,
		AgentId:         "sync-agent",
		PollerId:        "test-poller",
		CurrentSequence: "sync-1",
		HasNewData:      true,
	}, nil).Run(func(args mock.Arguments) {
		mu.Lock()
		defer mu.Unlock()

		callOrder = append(callOrder, "sync-results")

		// Verify completion status was forwarded to sync service
		req := args.Get(1).(*proto.ResultsRequest)
		assert.NotNil(t, req.CompletionStatus, "Sync service should receive completion status")
		assert.Equal(t, proto.SweepCompletionStatus_COMPLETED, req.CompletionStatus.Status)
	})

	// Mock core service ReportStatus
	mockCoreClient.On("ReportStatus", mock.Anything, mock.MatchedBy(func(req *proto.PollerStatusRequest) bool {
		return req.PollerId == "test-poller" && len(req.Services) > 0
	})).Return(&proto.PollerStatusResponse{
		Received: true,
	}, nil).Run(func(_ mock.Arguments) {
		mu.Lock()
		defer mu.Unlock()

		callOrder = append(callOrder, "core-report")
	})

	// Execute the poll
	ctx := context.Background()
	err := poller.poll(ctx)

	// Verify no errors
	require.NoError(t, err)

	// Verify call order: sweep → sync → core
	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, []string{"sweep-results", "sync-results", "core-report"}, callOrder)

	// Verify all expectations were met
	mockAgentClient.AssertExpectations(t)
	mockCoreClient.AssertExpectations(t)
}

// TestTwoPhasePolling_SweepTimeout tests behavior when sweep doesn't complete within timeout
func TestTwoPhasePolling_SweepTimeout(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping timeout test in short mode")
	}

	mockAgentClient := &MockAgentServiceClient{}
	mockCoreClient := &MockPollerServiceClient{}

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
			Agents: map[string]AgentConfig{
				"sweep-agent": {
					Address: "127.0.0.1:50051",
					Checks: []Check{
						{
							Name:            "network_sweep",
							Type:            serviceTypeSweep,
							Details:         "192.168.1.0/24",
							ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
						},
					},
				},
				"sync-agent": {
					Address: "127.0.0.1:50052",
					Checks: []Check{
						{
							Name:            "sync",
							Type:            checkTypeGRPC,
							Details:         "127.0.0.1:50058",
							ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
						},
					},
				},
			},
		},
		coreClient:       mockCoreClient,
		agents:           make(map[string]*AgentPoller),
		agentCompletions: make(map[string]*proto.SweepCompletionStatus),
		logger:           logger.NewTestLogger(),
	}

	// Create mock agent pollers
	sweepAgentConfig := poller.config.Agents["sweep-agent"]
	syncAgentConfig := poller.config.Agents["sync-agent"]
	sweepAgent := newAgentPoller("sweep-agent", &sweepAgentConfig, mockAgentClient, poller)
	syncAgent := newAgentPoller("sync-agent", &syncAgentConfig, mockAgentClient, poller)

	poller.agents["sweep-agent"] = sweepAgent
	poller.agents["sync-agent"] = syncAgent

	// Mock sweep service GetStatus (called in phase 1)
	mockAgentClient.On("GetStatus", mock.Anything, mock.MatchedBy(func(req *proto.StatusRequest) bool {
		return req.ServiceName == "network_sweep" && req.ServiceType == serviceTypeSweep
	})).Return(&proto.StatusResponse{
		Available:   true,
		Message:     []byte(`{"status": "active"}`),
		ServiceName: "network_sweep",
		ServiceType: serviceTypeSweep,
		AgentId:     "sweep-agent",
	}, nil)

	// Mock sync service GetStatus (called in phase 2)
	mockAgentClient.On("GetStatus", mock.Anything, mock.MatchedBy(func(req *proto.StatusRequest) bool {
		return req.ServiceName == "sync" && req.ServiceType == checkTypeGRPC
	})).Return(&proto.StatusResponse{
		Available:   true,
		Message:     []byte(`{"status": "healthy"}`),
		ServiceName: "sync",
		ServiceType: checkTypeGRPC,
		AgentId:     "sync-agent",
	}, nil)

	// Mock sweep service GetResults - returns IN_PROGRESS (never completes)
	mockAgentClient.On("GetResults", mock.Anything, mock.MatchedBy(func(req *proto.ResultsRequest) bool {
		return req.ServiceName == "network_sweep" && req.ServiceType == serviceTypeSweep
	})).Return(&proto.ResultsResponse{
		Available:       true,
		Data:            []byte(`{"total_hosts": 10, "available_hosts": 8}`),
		ServiceName:     "network_sweep",
		ServiceType:     serviceTypeSweep,
		AgentId:         "sweep-agent",
		PollerId:        "test-poller",
		CurrentSequence: "1",
		HasNewData:      true,
		SweepCompletion: &proto.SweepCompletionStatus{
			Status:           proto.SweepCompletionStatus_IN_PROGRESS,
			CompletionTime:   0,
			TargetSequence:   "seq-1",
			TotalTargets:     10,
			CompletedTargets: 5, // Only half complete
		},
	}, nil)

	// Mock sync service GetResults - should still be called after timeout
	mockAgentClient.On("GetResults", mock.Anything, mock.MatchedBy(func(req *proto.ResultsRequest) bool {
		return req.ServiceName == "sync" && req.ServiceType == checkTypeGRPC
	})).Return(&proto.ResultsResponse{
		Available:       true,
		Data:            []byte(`{"devices": [{"ip": "192.168.1.1", "source": "netbox"}]}`),
		ServiceName:     "sync",
		ServiceType:     checkTypeGRPC,
		AgentId:         "sync-agent",
		PollerId:        "test-poller",
		CurrentSequence: "sync-1",
		HasNewData:      true,
	}, nil).Run(func(args mock.Arguments) {
		// Verify incomplete completion status was forwarded to sync service
		req := args.Get(1).(*proto.ResultsRequest)
		assert.NotNil(t, req.CompletionStatus, "Sync service should receive completion status")
		assert.Equal(t, proto.SweepCompletionStatus_IN_PROGRESS, req.CompletionStatus.Status)
		assert.Equal(t, int32(5), req.CompletionStatus.CompletedTargets)
	})

	// Mock core service ReportStatus
	mockCoreClient.On("ReportStatus", mock.Anything, mock.MatchedBy(func(req *proto.PollerStatusRequest) bool {
		return req.PollerId == "test-poller" && len(req.Services) > 0
	})).Return(&proto.PollerStatusResponse{
		Received: true,
	}, nil)

	// Execute the poll with a short timeout to test timeout behavior
	// Use a context with timeout shorter than the default 30 seconds maxWaitTime
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	start := time.Now()
	err := poller.poll(ctx)
	duration := time.Since(start)

	// Verify no errors
	require.NoError(t, err)

	// Verify timeout occurred quickly due to context cancellation
	assert.GreaterOrEqual(t, duration, 900*time.Millisecond, "Should wait for most of the context timeout")
	assert.Less(t, duration, 2*time.Second, "Should timeout within expected timeframe")

	// Verify all expectations were met
	mockAgentClient.AssertExpectations(t)
	mockCoreClient.AssertExpectations(t)
}

// TestPollSweepServices tests the sweep-only phase
func TestPollSweepServices(t *testing.T) {
	mockAgentClient := &MockAgentServiceClient{}

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
			Agents: map[string]AgentConfig{
				"sweep-agent": {
					Address: "127.0.0.1:50051",
					Checks: []Check{
						{
							Name:            "network_sweep",
							Type:            serviceTypeSweep,
							Details:         "192.168.1.0/24",
							ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
						},
					},
				},
				"non-sweep-agent": {
					Address: "127.0.0.1:50052",
					Checks: []Check{
						{
							Name:    "http-check",
							Type:    "http",
							Details: "http://example.com",
						},
					},
				},
			},
		},
		agents:           make(map[string]*AgentPoller),
		agentCompletions: make(map[string]*proto.SweepCompletionStatus),
		logger:           logger.NewTestLogger(),
	}

	// Create mock agent pollers
	sweepAgentConfig := poller.config.Agents["sweep-agent"]
	nonSweepAgentConfig := poller.config.Agents["non-sweep-agent"]
	sweepAgent := newAgentPoller("sweep-agent", &sweepAgentConfig, mockAgentClient, poller)
	nonSweepAgent := newAgentPoller("non-sweep-agent", &nonSweepAgentConfig, mockAgentClient, poller)

	poller.agents["sweep-agent"] = sweepAgent
	poller.agents["non-sweep-agent"] = nonSweepAgent

	// Mock sweep service GetStatus
	mockAgentClient.On("GetStatus", mock.Anything, mock.MatchedBy(func(req *proto.StatusRequest) bool {
		return req.ServiceName == "network_sweep" && req.ServiceType == serviceTypeSweep
	})).Return(&proto.StatusResponse{
		Available:   true,
		Message:     []byte(`{"status": "active"}`),
		ServiceName: "network_sweep",
		ServiceType: serviceTypeSweep,
		AgentId:     "sweep-agent",
	}, nil)

	// Mock sweep service GetResults
	mockAgentClient.On("GetResults", mock.Anything, mock.MatchedBy(func(req *proto.ResultsRequest) bool {
		return req.ServiceName == "network_sweep" && req.ServiceType == serviceTypeSweep
	})).Return(&proto.ResultsResponse{
		Available:       true,
		Data:            []byte(`{"total_hosts": 10, "available_hosts": 8}`),
		ServiceName:     "network_sweep",
		ServiceType:     serviceTypeSweep,
		AgentId:         "sweep-agent",
		PollerId:        "test-poller",
		CurrentSequence: "1",
		HasNewData:      true,
		SweepCompletion: &proto.SweepCompletionStatus{
			Status:           proto.SweepCompletionStatus_COMPLETED,
			CompletionTime:   time.Now().Unix(),
			TargetSequence:   "seq-1",
			TotalTargets:     10,
			CompletedTargets: 10,
		},
	}, nil)

	// NO MOCK for non-sweep-agent - it should not be called in this phase

	// Execute pollSweepServices
	ctx := context.Background()
	statuses := poller.pollSweepServices(ctx)

	// Should return 2 statuses: 1 check + 1 result for sweep service
	assert.Len(t, statuses, 2)

	// Find the sweep result status
	var sweepResultStatus *proto.ServiceStatus

	for _, status := range statuses {
		if status.Source == "results" && status.ServiceType == serviceTypeSweep {
			sweepResultStatus = status
			break
		}
	}

	require.NotNil(t, sweepResultStatus, "Should find sweep result status")
	assert.Equal(t, "network_sweep", sweepResultStatus.ServiceName)
	assert.Equal(t, serviceTypeSweep, sweepResultStatus.ServiceType)
	assert.Equal(t, "sweep-agent", sweepResultStatus.AgentId)

	// Verify completion tracking was updated
	aggregatedCompletion := poller.getAggregatedCompletion()
	require.NotNil(t, aggregatedCompletion)
	assert.Equal(t, proto.SweepCompletionStatus_COMPLETED, aggregatedCompletion.Status)

	// Verify all expectations were met
	mockAgentClient.AssertExpectations(t)
}

// TestPollSyncAndOtherServices tests the sync-and-other phase
func TestPollSyncAndOtherServices(t *testing.T) {
	mockAgentClient := &MockAgentServiceClient{}

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
			Agents: map[string]AgentConfig{
				"sweep-agent": {
					Address: "127.0.0.1:50051",
					Checks: []Check{
						{
							Name:            "network_sweep",
							Type:            serviceTypeSweep,
							Details:         "192.168.1.0/24",
							ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
						},
					},
				},
				"sync-agent": {
					Address: "127.0.0.1:50052",
					Checks: []Check{
						{
							Name:            "sync",
							Type:            checkTypeGRPC,
							Details:         "127.0.0.1:50058",
							ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
						},
					},
				},
				"other-agent": {
					Address: "127.0.0.1:50053",
					Checks: []Check{
						{
							Name:    "http-check",
							Type:    "http",
							Details: "http://example.com",
						},
					},
				},
			},
		},
		agents:           make(map[string]*AgentPoller),
		agentCompletions: make(map[string]*proto.SweepCompletionStatus),
		logger:           logger.NewTestLogger(),
	}

	// Create mock agent pollers
	sweepAgentConfig := poller.config.Agents["sweep-agent"]
	syncAgentConfig := poller.config.Agents["sync-agent"]
	otherAgentConfig := poller.config.Agents["other-agent"]
	sweepAgent := newAgentPoller("sweep-agent", &sweepAgentConfig, mockAgentClient, poller)
	syncAgent := newAgentPoller("sync-agent", &syncAgentConfig, mockAgentClient, poller)
	otherAgent := newAgentPoller("other-agent", &otherAgentConfig, mockAgentClient, poller)

	poller.agents["sweep-agent"] = sweepAgent
	poller.agents["sync-agent"] = syncAgent
	poller.agents["other-agent"] = otherAgent

	// Set up sweep completion status so sync service gets it
	poller.agentCompletions["sweep-agent"] = &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		CompletionTime:   time.Now().Unix(),
		TargetSequence:   "seq-1",
		TotalTargets:     10,
		CompletedTargets: 10,
	}

	// Mock sweep service GetStatus (should be called)
	mockAgentClient.On("GetStatus", mock.Anything, mock.MatchedBy(func(req *proto.StatusRequest) bool {
		return req.ServiceName == "network_sweep" && req.ServiceType == serviceTypeSweep
	})).Return(&proto.StatusResponse{
		Available:   true,
		Message:     []byte(`{"status": "active"}`),
		ServiceName: "network_sweep",
		ServiceType: serviceTypeSweep,
		AgentId:     "sweep-agent",
	}, nil)

	// Mock sync service GetStatus
	mockAgentClient.On("GetStatus", mock.Anything, mock.MatchedBy(func(req *proto.StatusRequest) bool {
		return req.ServiceName == "sync" && req.ServiceType == checkTypeGRPC
	})).Return(&proto.StatusResponse{
		Available:   true,
		Message:     []byte(`{"status": "healthy"}`),
		ServiceName: "sync",
		ServiceType: checkTypeGRPC,
		AgentId:     "sync-agent",
	}, nil)

	// Mock other service GetStatus
	mockAgentClient.On("GetStatus", mock.Anything, mock.MatchedBy(func(req *proto.StatusRequest) bool {
		return req.ServiceName == "http-check" && req.ServiceType == "http"
	})).Return(&proto.StatusResponse{
		Available:   true,
		Message:     []byte(`{"response_time": 150}`),
		ServiceName: "http-check",
		ServiceType: "http",
		AgentId:     "other-agent",
	}, nil)

	// Mock sweep service GetResults (might be called by results poller)
	mockAgentClient.On("GetResults", mock.Anything, mock.MatchedBy(func(req *proto.ResultsRequest) bool {
		return req.ServiceName == "network_sweep" && req.ServiceType == serviceTypeSweep
	})).Return(&proto.ResultsResponse{
		Available:       true,
		Data:            []byte(`{"total_hosts": 10, "available_hosts": 8}`),
		ServiceName:     "network_sweep",
		ServiceType:     serviceTypeSweep,
		AgentId:         "sweep-agent",
		PollerId:        "test-poller",
		CurrentSequence: "1",
		HasNewData:      true,
		SweepCompletion: &proto.SweepCompletionStatus{
			Status:           proto.SweepCompletionStatus_COMPLETED,
			CompletionTime:   time.Now().Unix(),
			TargetSequence:   "seq-1",
			TotalTargets:     10,
			CompletedTargets: 10,
		},
	}, nil)

	// Mock sync service GetResults (should receive completion status)
	mockAgentClient.On("GetResults", mock.Anything, mock.MatchedBy(func(req *proto.ResultsRequest) bool {
		return req.ServiceName == "sync" && req.ServiceType == checkTypeGRPC
	})).Return(&proto.ResultsResponse{
		Available:       true,
		Data:            []byte(`{"devices": [{"ip": "192.168.1.1", "source": "netbox"}]}`),
		ServiceName:     "sync",
		ServiceType:     checkTypeGRPC,
		AgentId:         "sync-agent",
		PollerId:        "test-poller",
		CurrentSequence: "sync-1",
		HasNewData:      true,
	}, nil).Run(func(args mock.Arguments) {
		// Verify completion status was forwarded to sync service
		req := args.Get(1).(*proto.ResultsRequest)
		assert.NotNil(t, req.CompletionStatus, "Sync service should receive completion status")
		assert.Equal(t, proto.SweepCompletionStatus_COMPLETED, req.CompletionStatus.Status)
	})

	// NO MOCK for sweep service GetResults - it should not be called in this phase

	// Execute pollSyncAndOtherServices
	ctx := context.Background()
	statuses := poller.pollSyncAndOtherServices(ctx)

	// Should return 4 statuses: 3 checks + 1 sync result (sweep results excluded)
	assert.Len(t, statuses, 4)

	// Verify we have the expected services
	serviceNames := make(map[string]bool)
	for _, status := range statuses {
		serviceNames[status.ServiceName] = true
	}

	// Should have sweep status check, sync check, sync results, and http check
	assert.True(t, serviceNames["network_sweep"], "Should have sweep service check")
	assert.True(t, serviceNames["sync"], "Should have sync service")
	assert.True(t, serviceNames["http-check"], "Should have http check")

	// Verify we have both sync check and sync result
	var syncCheckFound, syncResultFound bool

	for _, status := range statuses {
		if status.ServiceName == "sync" {
			if status.Source == "results" {
				syncResultFound = true
			} else {
				syncCheckFound = true
			}
		}
	}

	assert.True(t, syncCheckFound, "Should have sync check")
	assert.True(t, syncResultFound, "Should have sync result")

	// Verify all expectations were met
	mockAgentClient.AssertExpectations(t)
}

// TestWaitForSweepCompletion tests the sweep completion waiting logic
func TestWaitForSweepCompletion(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping timeout test in short mode")
	}

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		agentCompletions: make(map[string]*proto.SweepCompletionStatus),
		logger:           logger.NewTestLogger(),
	}

	// Test immediate completion
	t.Run("ImmediateCompletion", func(t *testing.T) {
		// Set up completed status
		poller.agentCompletions["sweep-agent"] = &proto.SweepCompletionStatus{
			Status:           proto.SweepCompletionStatus_COMPLETED,
			CompletionTime:   time.Now().Unix(),
			TargetSequence:   "seq-1",
			TotalTargets:     10,
			CompletedTargets: 10,
		}

		ctx := context.Background()
		start := time.Now()
		completed := poller.waitForSweepCompletion(ctx, 10*time.Second)
		duration := time.Since(start)

		assert.True(t, completed, "Should complete immediately")
		assert.Less(t, duration, 1*time.Second, "Should return quickly")
	})

	// Test timeout scenario
	t.Run("Timeout", func(t *testing.T) {
		// Set up incomplete status
		poller.agentCompletions["sweep-agent"] = &proto.SweepCompletionStatus{
			Status:           proto.SweepCompletionStatus_IN_PROGRESS,
			CompletionTime:   0,
			TargetSequence:   "seq-1",
			TotalTargets:     10,
			CompletedTargets: 5,
		}

		// Use context with timeout to prevent test hanging
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()

		start := time.Now()
		completed := poller.waitForSweepCompletion(ctx, 5*time.Second) // maxWaitTime longer than context timeout
		duration := time.Since(start)

		assert.False(t, completed, "Should timeout")
		assert.GreaterOrEqual(t, duration, 1*time.Second, "Should wait for most of the timeout")
		assert.Less(t, duration, 3*time.Second, "Should not wait too long")
	})

	// Test no completion status
	t.Run("NoStatus", func(t *testing.T) {
		// Clear completion status
		poller.agentCompletions = make(map[string]*proto.SweepCompletionStatus)

		// Use context with timeout to prevent test hanging
		ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
		defer cancel()

		start := time.Now()
		completed := poller.waitForSweepCompletion(ctx, 10*time.Second) // maxWaitTime longer than context timeout
		duration := time.Since(start)

		assert.False(t, completed, "Should timeout with no status")
		assert.GreaterOrEqual(t, duration, 800*time.Millisecond, "Should wait for most of the timeout")
		assert.Less(t, duration, 2*time.Second, "Should not wait too long")
	})
}
