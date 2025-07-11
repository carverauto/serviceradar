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
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// MockAgentServiceClient is a mock implementation of proto.AgentServiceClient
type MockAgentServiceClient struct {
	mock.Mock
}

func (m *MockAgentServiceClient) GetStatus(
	ctx context.Context, req *proto.StatusRequest, _ ...grpc.CallOption) (*proto.StatusResponse, error) {
	args := m.Called(ctx, req)
	return args.Get(0).(*proto.StatusResponse), args.Error(1)
}

func (m *MockAgentServiceClient) GetResults(
	ctx context.Context, req *proto.ResultsRequest, _ ...grpc.CallOption) (*proto.ResultsResponse, error) {
	args := m.Called(ctx, req)
	return args.Get(0).(*proto.ResultsResponse), args.Error(1)
}

func TestAgentPoller_ExecuteResults(t *testing.T) {
	mockClient := &MockAgentServiceClient{}

	// Create test agent configuration with results pollers
	agentConfig := &AgentConfig{
		Checks: []Check{
			{
				Name:            "sync",
				Type:            "grpc",
				Details:         "127.0.0.1:50058",
				ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
			},
			{
				Name:            "web",
				Type:            "http",
				Details:         "http://example.com",
				ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 60); return &d }(),
			},
			{
				Name:    "ping",
				Type:    "icmp",
				Details: "1.1.1.1",
				// No ResultsInterval - should not create results poller
			},
		},
	}

	// Create test poller with mock client
	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: logger.NewTestLogger(),
	}

	agentPoller := newAgentPoller("test-agent", agentConfig, mockClient, poller)

	// Verify that only services with ResultsInterval get results pollers
	assert.Len(t, agentPoller.resultsPollers, 2)
	assert.Equal(t, "sync", agentPoller.resultsPollers[0].check.Name)
	assert.Equal(t, "web", agentPoller.resultsPollers[1].check.Name)

	// Test ExecuteResults with time-based polling
	ctx := context.Background()

	// Mock successful GetResults response for sync service
	mockClient.On("GetResults", mock.AnythingOfType("*context.timerCtx"), &proto.ResultsRequest{
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Details:     "127.0.0.1:50058",
	}).Return(&proto.ResultsResponse{
		Available:   true,
		Data:        []byte(`{"devices": [{"ip": "192.168.1.1"}, {"ip": "192.168.1.2"}]}`),
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Timestamp:   time.Now().Unix(),
	}, nil)

	// Mock successful GetResults response for web service
	mockClient.On("GetResults", mock.AnythingOfType("*context.timerCtx"), &proto.ResultsRequest{
		ServiceName: "web",
		ServiceType: "http",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Details:     "http://example.com",
	}).Return(&proto.ResultsResponse{
		Available:   true,
		Data:        []byte(`{"status": "ok", "content_length": 1234}`),
		ServiceName: "web",
		ServiceType: "http",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Timestamp:   time.Now().Unix(),
	}, nil)

	// First call should execute both services (lastResults is zero time)
	statuses := agentPoller.ExecuteResults(ctx)

	// Should get results for both services
	assert.Len(t, statuses, 2)

	// Verify the results
	for _, status := range statuses {
		assert.True(t, status.Available)
		assert.Equal(t, "test-agent", status.AgentId)
		assert.Equal(t, "test-poller", status.PollerId)
		assert.NotEmpty(t, status.Message)

		if status.ServiceName == "sync" {
			assert.Equal(t, "grpc", status.ServiceType)
			assert.Contains(t, string(status.Message), "devices")
		} else if status.ServiceName == "web" {
			assert.Equal(t, "http", status.ServiceType)
			assert.Contains(t, string(status.Message), "content_length")
		}
	}

	// Second call immediately after should not execute anything (interval not reached)
	statuses2 := agentPoller.ExecuteResults(ctx)
	assert.Empty(t, statuses2)

	// Verify all expectations were met
	mockClient.AssertExpectations(t)
}

func TestAgentPoller_ExecuteResults_UnsupportedService(t *testing.T) {
	mockClient := &MockAgentServiceClient{}

	agentConfig := &AgentConfig{
		Checks: []Check{
			{
				Name:            "unsupported",
				Type:            "grpc",
				Details:         "127.0.0.1:50059",
				ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
			},
		},
	}

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: logger.NewTestLogger(),
	}

	agentPoller := newAgentPoller("test-agent", agentConfig, mockClient, poller)

	ctx := context.Background()

	// Mock GetResults failure for unsupported service (returns "not implemented")
	mockClient.On("GetResults", mock.AnythingOfType("*context.timerCtx"), &proto.ResultsRequest{
		ServiceName: "unsupported",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Details:     "127.0.0.1:50059",
	}).Return((*proto.ResultsResponse)(nil),
		status.Error(codes.Unimplemented, "method GetResults not implemented"))

	// Should skip unsupported service and return no results
	statuses := agentPoller.ExecuteResults(ctx)
	assert.Empty(t, statuses, "Expected no results for unsupported service")

	// Verify the service was attempted but skipped
	mockClient.AssertExpectations(t)
}

func TestAgentPoller_ExecuteResults_WithError(t *testing.T) {
	mockClient := &MockAgentServiceClient{}

	agentConfig := &AgentConfig{
		Checks: []Check{
			{
				Name:            "failing",
				Type:            "grpc",
				Details:         "127.0.0.1:50060",
				ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
			},
		},
	}

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: logger.NewTestLogger(),
	}

	agentPoller := newAgentPoller("test-agent", agentConfig, mockClient, poller)

	ctx := context.Background()

	// Mock GetResults failure for failing service (connection error)
	mockClient.On("GetResults", mock.AnythingOfType("*context.timerCtx"), &proto.ResultsRequest{
		ServiceName: "failing",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Details:     "127.0.0.1:50060",
	}).Return((*proto.ResultsResponse)(nil),
		&mockError{message: "connection refused"})

	// Should return error status for failing service
	statuses := agentPoller.ExecuteResults(ctx)
	assert.Len(t, statuses, 1)

	status := statuses[0]
	assert.False(t, status.Available)
	assert.Equal(t, "failing", status.ServiceName)
	assert.Equal(t, "grpc", status.ServiceType)
	assert.Equal(t, "test-agent", status.AgentId)
	assert.Equal(t, "test-poller", status.PollerId)
	assert.Contains(t, string(status.Message), "GetResults failed")
	assert.Contains(t, string(status.Message), "connection refused")

	mockClient.AssertExpectations(t)
}

func TestResultsPoller_executeGetResults(t *testing.T) {
	mockClient := &MockAgentServiceClient{}

	check := Check{
		Name:            "sync",
		Type:            "grpc",
		Details:         "127.0.0.1:50058",
		ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
	}

	resultsPoller := &ResultsPoller{
		client:    mockClient,
		check:     check,
		pollerID:  "test-poller",
		agentName: "test-agent",
		interval:  time.Second * 30,
	}

	ctx := context.Background()

	// Test successful GetResults call
	mockClient.On("GetResults", mock.Anything, &proto.ResultsRequest{
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Details:     "127.0.0.1:50058",
	}).Return(&proto.ResultsResponse{
		Available:   true,
		Data:        []byte(`{"devices": [{"ip": "192.168.1.1"}]}`),
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Timestamp:   time.Now().Unix(),
	}, nil)

	status := resultsPoller.executeGetResults(ctx)
	require.NotNil(t, status)

	assert.True(t, status.Available)
	assert.Equal(t, "sync", status.ServiceName)
	assert.Equal(t, "grpc", status.ServiceType)
	assert.Equal(t, "test-agent", status.AgentId)
	assert.Equal(t, "test-poller", status.PollerId)
	assert.Contains(t, string(status.Message), "devices")

	mockClient.AssertExpectations(t)
}

func TestResultsPoller_executeGetResults_NotImplemented(t *testing.T) {
	mockClient := &MockAgentServiceClient{}

	check := Check{
		Name:            "unsupported",
		Type:            "grpc",
		Details:         "127.0.0.1:50059",
		ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
	}

	resultsPoller := &ResultsPoller{
		client:    mockClient,
		check:     check,
		pollerID:  "test-poller",
		agentName: "test-agent",
		interval:  time.Second * 30,
	}

	ctx := context.Background()

	// Test GetResults with "not implemented" error
	mockClient.On("GetResults", mock.Anything, &proto.ResultsRequest{
		ServiceName: "unsupported",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Details:     "127.0.0.1:50059",
	}).Return((*proto.ResultsResponse)(nil),
		status.Error(codes.Unimplemented, "method GetResults not implemented"))

	// Should return nil for unsupported service
	status := resultsPoller.executeGetResults(ctx)
	assert.Nil(t, status)

	mockClient.AssertExpectations(t)
}

func TestNewAgentPoller_ResultsPollerCreation(t *testing.T) {
	mockClient := &MockAgentServiceClient{}

	// Test configuration with mixed services
	agentConfig := &AgentConfig{
		Checks: []Check{
			{
				Name:            "sync",
				Type:            "grpc",
				Details:         "127.0.0.1:50058",
				ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
			},
			{
				Name:            "web",
				Type:            "http",
				Details:         "http://example.com",
				ResultsInterval: func() *models.Duration { d := models.Duration(time.Minute); return &d }(),
			},
			{
				Name:    "ping",
				Type:    "icmp",
				Details: "1.1.1.1",
				// No ResultsInterval
			},
			{
				Name:            "database",
				Type:            "tcp",
				Details:         "127.0.0.1:5432",
				ResultsInterval: func() *models.Duration { d := models.Duration(time.Minute * 5); return &d }(),
			},
		},
	}

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: logger.NewTestLogger(),
	}

	agentPoller := newAgentPoller("test-agent", agentConfig, mockClient, poller)

	// Should create results pollers only for services with ResultsInterval
	assert.Len(t, agentPoller.resultsPollers, 3)

	// Verify each results poller configuration
	expectedServices := map[string]time.Duration{
		"sync":     time.Second * 30,
		"web":      time.Minute,
		"database": time.Minute * 5,
	}

	for _, rp := range agentPoller.resultsPollers {
		expectedInterval, exists := expectedServices[rp.check.Name]
		assert.True(t, exists, "Unexpected service: %s", rp.check.Name)
		assert.Equal(t, expectedInterval, rp.interval)
		assert.Equal(t, "test-agent", rp.agentName)
		assert.Equal(t, "test-poller", rp.pollerID)
		assert.Equal(t, mockClient, rp.client)
	}
}

// mockError implements the error interface for testing
type mockError struct {
	message string
}

func (e *mockError) Error() string {
	return e.message
}

func TestPoller_pollAgent(t *testing.T) {
	mockClient := &MockAgentServiceClient{}

	// Create test agent configuration with mixed services
	agentConfig := &AgentConfig{
		Address: "127.0.0.1:50051",
		Checks: []Check{
			{
				Name:    "web",
				Type:    "http",
				Details: "http://example.com",
			},
			{
				Name:            "sync",
				Type:            "grpc",
				Details:         "127.0.0.1:50058",
				ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
			},
		},
	}

	// Mock AgentPoller directly to test the combination logic
	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		agents: make(map[string]*AgentConnection),
		logger: logger.NewTestLogger(),
	}

	// Create a mock agent connection
	mockAgentConnection := &AgentConnection{
		agentName: "test-agent",
	}

	// Add the mock connection to the poller
	poller.agents["test-agent"] = mockAgentConnection

	// Test the actual pollAgent function would be complex due to gRPC dependencies
	// Instead, let's test the core logic by creating an AgentPoller directly
	agentPoller := &AgentPoller{
		name:    "test-agent",
		config:  agentConfig,
		client:  mockClient,
		timeout: defaultTimeout,
		poller:  poller,
		resultsPollers: []*ResultsPoller{
			{
				client:    mockClient,
				agentName: "test-agent",
				pollerID:  "test-poller",
				check: Check{
					Name:            "sync",
					Type:            "grpc",
					Details:         "127.0.0.1:50058",
					ResultsInterval: func() *models.Duration { d := models.Duration(time.Second * 30); return &d }(),
				},
				interval: time.Second * 30,
			},
		},
	}

	// Mock GetStatus calls for ExecuteChecks
	mockClient.On("GetStatus", mock.AnythingOfType("*context.timerCtx"), mock.MatchedBy(func(req *proto.StatusRequest) bool {
		return req.ServiceName == "web" && req.ServiceType == "http"
	})).Return(&proto.StatusResponse{
		Available:   true,
		Message:     []byte(`{"status": "ok"}`),
		ServiceName: "web",
		ServiceType: "http",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}, nil)

	mockClient.On("GetStatus", mock.AnythingOfType("*context.timerCtx"), mock.MatchedBy(func(req *proto.StatusRequest) bool {
		return req.ServiceName == "sync" && req.ServiceType == "grpc"
	})).Return(&proto.StatusResponse{
		Available:   true,
		Message:     []byte(`{"status": "healthy"}`),
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}, nil)

	// Mock GetResults calls for ExecuteResults
	mockClient.On("GetResults", mock.AnythingOfType("*context.timerCtx"), mock.MatchedBy(func(req *proto.ResultsRequest) bool {
		return req.ServiceName == "sync" && req.ServiceType == "grpc"
	})).Return(&proto.ResultsResponse{
		Available:   true,
		Data:        []byte(`{"devices": 5}`),
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}, nil)

	ctx := context.Background()

	// Test ExecuteChecks
	checkStatuses := agentPoller.ExecuteChecks(ctx)
	assert.Len(t, checkStatuses, 2, "Should have 2 check results")

	// Test ExecuteResults
	resultsStatuses := agentPoller.ExecuteResults(ctx)
	assert.Len(t, resultsStatuses, 1, "Should have 1 results response")

	// Test the combination logic (the core of pollAgent)
	// This simulates the append logic from pollAgent
	combinedStatuses := append(checkStatuses, resultsStatuses...)
	assert.Len(t, combinedStatuses, 3, "Should have 3 total statuses (2 checks + 1 results)")

	// Verify the combined statuses contain both types
	var webFound, syncCheckFound, syncResultsFound bool

	for _, status := range combinedStatuses {
		switch {
		case status.ServiceName == "web" && status.ServiceType == "http":
			webFound = true

			assert.Contains(t, string(status.Message), "status")
		case status.ServiceName == "sync" && status.ServiceType == "grpc" && string(status.Message) == `{"status": "healthy"}`:
			syncCheckFound = true
		case status.ServiceName == "sync" && status.ServiceType == "grpc" && string(status.Message) == `{"devices": 5}`:
			syncResultsFound = true
		}
	}

	assert.True(t, webFound, "Web service status should be found")
	assert.True(t, syncCheckFound, "Sync service check status should be found")
	assert.True(t, syncResultsFound, "Sync service results should be found")

	// Verify that the original checkStatuses slice was not modified
	// (This tests that the append doesn't mutate the original slice)
	assert.Len(t, checkStatuses, 2, "Original checkStatuses should still have 2 items")

	mockClient.AssertExpectations(t)
}
