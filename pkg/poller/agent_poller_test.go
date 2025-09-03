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
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	// errServiceUnavailable is used in tests to simulate service unavailability
	errServiceUnavailable = errors.New("service unavailable")
	// errStreamError is used in tests to simulate stream errors
	errStreamError = errors.New("stream error")
	// errConnectionFailed is used in tests to simulate connection failures
	errConnectionFailed = errors.New("connection failed")
)

func TestNewAgentPoller(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: mockLogger,
	}

	tests := []struct {
		name            string
		agentName       string
		config          *AgentConfig
		expectedChecks  int
		expectedResults int
	}{
		{
			name:      "agent with basic checks",
			agentName: "test-agent",
			config: &AgentConfig{
				Address: "localhost:8080",
				Checks: []Check{
					{Type: "grpc", Name: "service1"},
					{Type: "http", Name: "service2"},
				},
			},
			expectedChecks:  2,
			expectedResults: 0,
		},
		{
			name:      "agent with results polling",
			agentName: "test-agent",
			config: &AgentConfig{
				Address: "localhost:8080",
				Checks: []Check{
					{Type: "grpc", Name: "service1"},
					{
						Type:            "sync",
						Name:            "service2",
						ResultsInterval: &[]models.Duration{models.Duration(30 * time.Second)}[0],
					},
				},
			},
			expectedChecks:  1, // Only service1 should remain in regular checks (service2 goes to results pollers)
			expectedResults: 1,
		},
		{
			name:      "agent with multiple results pollers",
			agentName: "test-agent",
			config: &AgentConfig{
				Address: "localhost:8080",
				Checks: []Check{
					{
						Type:            "sync",
						Name:            "service1",
						ResultsInterval: &[]models.Duration{models.Duration(30 * time.Second)}[0],
					},
					{
						Type:            "sweep",
						Name:            "service2",
						ResultsInterval: &[]models.Duration{models.Duration(60 * time.Second)}[0],
					},
				},
			},
			expectedChecks:  0, // Both services have ResultsInterval, so no regular checks remain
			expectedResults: 2,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ap := newAgentPoller(tt.agentName, tt.config, mockClient, poller)

			assert.Equal(t, tt.agentName, ap.name)
			assert.Equal(t, tt.config.Address, ap.config.Address)
			assert.Equal(t, tt.config.Security, ap.config.Security)
			assert.Equal(t, mockClient, ap.client)
			assert.Equal(t, defaultTimeout, ap.timeout)
			assert.Equal(t, poller, ap.poller)
			assert.Len(t, ap.config.Checks, tt.expectedChecks)
			assert.Len(t, ap.resultsPollers, tt.expectedResults)

			// Verify results pollers are properly configured
			for i, rp := range ap.resultsPollers {
				assert.Equal(t, mockClient, rp.client)
				assert.Equal(t, "test-poller", rp.pollerID)
				assert.Equal(t, tt.agentName, rp.agentName)
				assert.Equal(t, poller, rp.poller)
				assert.Equal(t, mockLogger, rp.logger)

				// Find the corresponding check with ResultsInterval
				var foundCheck *Check

				for _, check := range tt.config.Checks {
					if check.ResultsInterval != nil && check.Name == rp.check.Name {
						foundCheck = &check
						break
					}
				}

				require.NotNil(t, foundCheck, "Should find corresponding check for results poller %d", i)
				assert.Equal(t, time.Duration(*foundCheck.ResultsInterval), rp.interval)
			}
		})
	}
}

func TestAgentPoller_ExecuteChecks(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: mockLogger,
	}

	config := &AgentConfig{
		Address: "localhost:8080",
		Checks: []Check{
			{Type: "grpc", Name: "service1"},
			{Type: "http", Name: "service2"},
			{Type: "port", Name: "service3", Port: 8080},
		},
	}

	ap := newAgentPoller("test-agent", config, mockClient, poller)

	// Set up mock expectations for each service check
	mockClient.EXPECT().
		GetStatus(gomock.Any(), gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, req *proto.StatusRequest, _ ...interface{}) (*proto.StatusResponse, error) {
			return &proto.StatusResponse{
				Available:    true,
				Message:      []byte(fmt.Sprintf(`{"service": "%s"}`, req.ServiceName)),
				ResponseTime: 1000000,
				AgentId:      "test-agent",
			}, nil
		}).
		Times(3)

	ctx := context.Background()
	statuses := ap.ExecuteChecks(ctx)

	assert.Len(t, statuses, 3)

	// Verify all services returned status
	serviceNames := make(map[string]bool)

	for _, status := range statuses {
		serviceNames[status.ServiceName] = true

		assert.True(t, status.Available)
		assert.Equal(t, "test-poller", status.PollerId)
		assert.Equal(t, "getStatus", status.Source)
	}

	assert.True(t, serviceNames["service1"])
	assert.True(t, serviceNames["service2"])
	assert.True(t, serviceNames["service3"])
}

func TestAgentPoller_ExecuteChecks_WithErrors(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: mockLogger,
	}

	config := &AgentConfig{
		Address: "localhost:8080",
		Checks: []Check{
			{Type: "grpc", Name: "working-service"},
			{Type: "grpc", Name: "failing-service"},
		},
	}

	ap := newAgentPoller("test-agent", config, mockClient, poller)

	// Set up mock expectations - one success, one failure
	mockClient.EXPECT().
		GetStatus(gomock.Any(), gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, req *proto.StatusRequest, _ ...interface{}) (*proto.StatusResponse, error) {
			if req.ServiceName == "working-service" {
				return &proto.StatusResponse{
					Available: true,
					Message:   []byte(`{"status": "ok"}`),
					AgentId:   "test-agent",
				}, nil
			}
			return nil, errServiceUnavailable
		}).
		Times(2)

	ctx := context.Background()
	statuses := ap.ExecuteChecks(ctx)

	assert.Len(t, statuses, 2)

	// Find each service status
	var workingStatus, failingStatus *proto.ServiceStatus

	for _, status := range statuses {
		switch status.ServiceName {
		case "working-service":
			workingStatus = status
		case "failing-service":
			failingStatus = status
		}
	}

	require.NotNil(t, workingStatus)
	require.NotNil(t, failingStatus)

	// Verify working service
	assert.True(t, workingStatus.Available)
	assert.JSONEq(t, `{"status": "ok"}`, string(workingStatus.Message))

	// Verify failing service
	assert.False(t, failingStatus.Available)
	assert.Contains(t, string(failingStatus.Message), "error")
}

func TestAgentPoller_ExecuteResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: mockLogger,
	}

	config := &AgentConfig{
		Address: "localhost:8080",
		Checks: []Check{
			{
				Type:            "sync",
				Name:            "sync-service",
				ResultsInterval: &[]models.Duration{models.Duration(10 * time.Millisecond)}[0],
			},
			{
				Type:            "sweep",
				Name:            "sweep-service",
				ResultsInterval: &[]models.Duration{models.Duration(1 * time.Hour)}[0],
			},
		},
	}

	ap := newAgentPoller("test-agent", config, mockClient, poller)

	// Set the lastResults time for the sweep service to recent (should not execute)
	// and for the sync service to old (should execute)
	now := time.Now()

	for _, rp := range ap.resultsPollers {
		switch rp.check.Name {
		case "sweep-service":
			rp.lastResults = now // Recent, should not execute
		case "sync-service":
			rp.lastResults = now.Add(-time.Hour) // Old, should execute
		}
	}

	// Only expect one call for the sync service (sweep should be skipped due to interval)
	mockClient.EXPECT().
		StreamResults(gomock.Any(), gomock.Any()).
		Return(nil, errStreamError).
		Times(1)

	ctx := context.Background()
	statuses := ap.ExecuteResults(ctx)

	// Should only get one status (from sync service that had an error)
	assert.Len(t, statuses, 1)
	assert.Equal(t, "sync-service", statuses[0].ServiceName)
	assert.False(t, statuses[0].Available)
	assert.Contains(t, string(statuses[0].Message), "stream error")
}

func TestAgentPoller_ExecuteResults_NoResultsPollers(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: mockLogger,
	}

	// Config with no ResultsInterval checks
	config := &AgentConfig{
		Address: "localhost:8080",
		Checks: []Check{
			{Type: "grpc", Name: "regular-service"},
		},
	}

	ap := newAgentPoller("test-agent", config, mockClient, poller)

	ctx := context.Background()
	statuses := ap.ExecuteResults(ctx)

	// Should return empty slice
	assert.Empty(t, statuses)
}

func TestServiceCheck_Execute_Success(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	check := Check{
		Type:    "grpc",
		Name:    "test-service",
		Details: "test-details",
	}

	sc := newServiceCheck(mockClient, check, "test-poller", "test-agent", "", mockLogger)

	expectedReq := &proto.StatusRequest{
		ServiceName: "test-service",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Details:     "test-details",
	}

	expectedResp := &proto.StatusResponse{
		Available:    true,
		Message:      []byte(`{"status": "healthy"}`),
		ResponseTime: 5000000,
		AgentId:      "test-agent",
	}

	mockClient.EXPECT().
		GetStatus(gomock.Any(), gomock.Eq(expectedReq), gomock.Any()).
		Return(expectedResp, nil)

	ctx := context.Background()
	status := sc.execute(ctx)

	require.NotNil(t, status)
	assert.Equal(t, "test-service", status.ServiceName)
	assert.True(t, status.Available)
	assert.JSONEq(t, `{"status": "healthy"}`, string(status.Message))
	assert.Equal(t, "grpc", status.ServiceType)
	assert.Equal(t, int64(5000000), status.ResponseTime)
	assert.Equal(t, "test-agent", status.AgentId)
	assert.Equal(t, "test-poller", status.PollerId)
	assert.Equal(t, "getStatus", status.Source)
}

func TestServiceCheck_Execute_PortType(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	check := Check{
		Type: "port",
		Name: "port-service",
		Port: 8080,
	}

	sc := newServiceCheck(mockClient, check, "test-poller", "test-agent", "", mockLogger)

	expectedReq := &proto.StatusRequest{
		ServiceName: "port-service",
		ServiceType: "port",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
		Port:        8080,
	}

	expectedResp := &proto.StatusResponse{
		Available: true,
		Message:   []byte(`{"port": 8080, "open": true}`),
		AgentId:   "test-agent",
	}

	mockClient.EXPECT().
		GetStatus(gomock.Any(), gomock.Eq(expectedReq), gomock.Any()).
		Return(expectedResp, nil)

	ctx := context.Background()
	status := sc.execute(ctx)

	require.NotNil(t, status)
	assert.Equal(t, "port-service", status.ServiceName)
	assert.True(t, status.Available)
	assert.Equal(t, "port", status.ServiceType)
}

func TestServiceCheck_Execute_Error(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	check := Check{
		Type: "grpc",
		Name: "failing-service",
	}

	sc := newServiceCheck(mockClient, check, "test-poller", "test-agent", "", mockLogger)

	expectedErr := errConnectionFailed
	mockClient.EXPECT().
		GetStatus(gomock.Any(), gomock.Any(), gomock.Any()).
		Return(nil, expectedErr)

	ctx := context.Background()
	status := sc.execute(ctx)

	require.NotNil(t, status)
	assert.Equal(t, "failing-service", status.ServiceName)
	assert.False(t, status.Available)
	assert.Equal(t, "grpc", status.ServiceType)
	assert.Equal(t, "test-poller", status.PollerId)
	assert.Equal(t, "getStatus", status.Source)

	// Verify error message is properly formatted
	var errorMsg map[string]string

	err := json.Unmarshal(status.Message, &errorMsg)
	require.NoError(t, err)

	assert.Equal(t, "Service check failed", errorMsg["error"])
}

func TestServiceCheck_Execute_JSONMarshalError(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	check := Check{
		Type: "grpc",
		Name: "failing-service",
	}

	sc := newServiceCheck(mockClient, check, "test-poller", "test-agent", "", mockLogger)

	expectedErr := errConnectionFailed
	mockClient.EXPECT().
		GetStatus(gomock.Any(), gomock.Any(), gomock.Any()).
		Return(nil, expectedErr)

	ctx := context.Background()
	status := sc.execute(ctx)

	require.NotNil(t, status)
	assert.Equal(t, "failing-service", status.ServiceName)
	assert.False(t, status.Available)

	// Should still contain valid JSON or fallback message
	if json.Valid(status.Message) {
		var errorMsg map[string]string

		err := json.Unmarshal(status.Message, &errorMsg)
		require.NoError(t, err)

		assert.Equal(t, "Service check failed", errorMsg["error"])
	} else {
		assert.Equal(t, []byte("Service check failed"), status.Message)
	}
}

func TestServiceCheck_WithKVStoreId(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	check := Check{
		Type:    "grpc",
		Name:    "kv-service",
		Details: "service with KV store",
	}

	kvStoreId := "kv-store-123"
	sc := newServiceCheck(mockClient, check, "test-poller", "test-agent", kvStoreId, mockLogger)

	expectedResp := &proto.StatusResponse{
		Available:    true,
		Message:      []byte(`{"status": "healthy"}`),
		ResponseTime: 5000000,
		AgentId:      "test-agent",
	}

	mockClient.EXPECT().
		GetStatus(gomock.Any(), gomock.Any(), gomock.Any()).
		Return(expectedResp, nil)

	ctx := context.Background()
	status := sc.execute(ctx)

	require.NotNil(t, status)
	assert.Equal(t, "kv-service", status.ServiceName)
	assert.Equal(t, "grpc", status.ServiceType)
	assert.True(t, status.Available)
	assert.Equal(t, kvStoreId, status.KvStoreId) // Verify KV store ID is set
	assert.Equal(t, "test-agent", status.AgentId)
	assert.Equal(t, "test-poller", status.PollerId)
	assert.JSONEq(t, `{"status": "healthy"}`, string(status.Message))
}

func TestAgentPoller_WithKVAddress(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	kvAddress := "localhost:6379"
	poller := &Poller{
		config: Config{
			PollerID:  "kv-poller",
			KVAddress: kvAddress,
		},
		logger: mockLogger,
	}

	config := &AgentConfig{
		Address: "localhost:8080",
		Checks: []Check{
			{Type: "grpc", Name: "kv-aware-service"},
			{Type: "http", Name: "legacy-service"},
		},
	}

	ap := newAgentPoller("kv-agent", config, mockClient, poller)

	// Set up mock expectations for both services
	mockClient.EXPECT().
		GetStatus(gomock.Any(), gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, req *proto.StatusRequest, _ ...interface{}) (*proto.StatusResponse, error) {
			return &proto.StatusResponse{
				Available:    true,
				Message:      []byte(fmt.Sprintf(`{"service": "%s"}`, req.ServiceName)),
				ResponseTime: 1000000,
				AgentId:      "kv-agent",
			}, nil
		}).
		Times(2)

	ctx := context.Background()
	statuses := ap.ExecuteChecks(ctx)

	assert.Len(t, statuses, 2)

	// Verify both services have KV store ID populated from poller config
	for _, status := range statuses {
		assert.Equal(t, kvAddress, status.KvStoreId)
		assert.Equal(t, "kv-poller", status.PollerId)
		assert.Equal(t, "kv-agent", status.AgentId)
		assert.True(t, status.Available)
	}
}

func TestNewServiceCheck_WithKVStoreId(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	check := Check{
		Type: "grpc",
		Name: "test-service",
	}

	kvStoreId := "test-kv-store"
	sc := newServiceCheck(mockClient, check, "test-poller", "test-agent", kvStoreId, mockLogger)

	// Verify the service check is properly configured with KV store ID
	assert.Equal(t, mockClient, sc.client)
	assert.Equal(t, check, sc.check)
	assert.Equal(t, "test-poller", sc.pollerID)
	assert.Equal(t, "test-agent", sc.agentName)
	assert.Equal(t, kvStoreId, sc.kvStoreId)
	assert.Equal(t, mockLogger, sc.logger)
}

func TestAgentPoller_ExecuteResults_IntervalLogic(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)
	mockLogger := logger.NewTestLogger()

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: mockLogger,
	}

	config := &AgentConfig{
		Address: "localhost:8080",
		Checks: []Check{
			{
				Type:            "grpc",
				Name:            "frequent-service",
				ResultsInterval: &[]models.Duration{models.Duration(10 * time.Millisecond)}[0],
			},
			{
				Type:            "grpc",
				Name:            "infrequent-service",
				ResultsInterval: &[]models.Duration{models.Duration(1 * time.Hour)}[0],
			},
		},
	}

	ap := newAgentPoller("test-agent", config, mockClient, poller)

	// Set up timing so frequent service should execute, infrequent should not
	now := time.Now()

	for _, rp := range ap.resultsPollers {
		if rp.check.Name == "frequent-service" {
			rp.lastResults = now.Add(-1 * time.Hour) // Long ago, should execute
		} else {
			rp.lastResults = now.Add(-1 * time.Minute) // Recent, should not execute
		}
	}

	// Only expect one call
	mockClient.EXPECT().
		GetResults(gomock.Any(), gomock.Any()).
		Return(&proto.ResultsResponse{
			Available:  true,
			Data:       []byte(`{"results": "data"}`),
			HasNewData: true,
		}, nil).
		Times(1)

	ctx := context.Background()
	statuses := ap.ExecuteResults(ctx)

	// Should only get results from the frequent service
	assert.Len(t, statuses, 1)
	assert.Equal(t, "frequent-service", statuses[0].ServiceName)

	// Verify lastResults was updated for the executed service
	for _, rp := range ap.resultsPollers {
		if rp.check.Name == "frequent-service" {
			assert.True(t, rp.lastResults.After(now.Add(-1*time.Second)))
		}
	}
}
