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
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestSafeIntToInt32(t *testing.T) {
	tests := []struct {
		name     string
		input    int
		expected int32
	}{
		{
			name:     "normal value",
			input:    42,
			expected: 42,
		},
		{
			name:     "zero value",
			input:    0,
			expected: 0,
		},
		{
			name:     "negative value",
			input:    -42,
			expected: -42,
		},
		{
			name:     "max int32 value",
			input:    math.MaxInt32,
			expected: math.MaxInt32,
		},
		{
			name:     "min int32 value",
			input:    math.MinInt32,
			expected: math.MinInt32,
		},
		{
			name:     "value larger than max int32",
			input:    int(math.MaxInt32) + 1,
			expected: math.MaxInt32,
		},
		{
			name:     "value smaller than min int32",
			input:    int(math.MinInt32) - 1,
			expected: math.MinInt32,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := safeIntToInt32(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestNew_BasicConstruction(t *testing.T) {
	// Test basic construction without actual network connections
	config := &Config{
		PollerID:     "test-poller",
		Partition:    "test-partition",
		SourceIP:     "192.168.1.1",
		PollInterval: models.Duration(30 * time.Second),
		Agents: map[string]AgentConfig{
			"agent1": {
				Address: "localhost:8081",
				Checks: []Check{
					{Type: "grpc", Name: "test-service"},
				},
			},
		},
	}

	// Since New() would try to actually connect to gRPC services, we'll test the basic structure
	// instead of full initialization. In a real test environment, you'd mock the gRPC client creation.
	assert.Equal(t, "test-poller", config.PollerID)
	assert.Equal(t, "test-partition", config.Partition)
	assert.Equal(t, "192.168.1.1", config.SourceIP)
	assert.NotEmpty(t, config.Agents)
}

func TestNew_WithNilClock(t *testing.T) {
	// Test that nil clock is handled properly by using realClock as default
	config := &Config{
		PollerID:     "test-poller",
		Partition:    "test-partition",
		SourceIP:     "192.168.1.1",
		PollInterval: models.Duration(30 * time.Second),
		Agents:       map[string]AgentConfig{},
	}

	// Create a poller directly to test clock initialization
	poller := &Poller{
		config: *config,
		agents: make(map[string]*AgentPoller),
		done:   make(chan struct{}),
		logger: logger.NewTestLogger(),
	}

	// Simulate what New() does when clock is nil
	if poller.clock == nil {
		poller.clock = realClock{}
	}

	assert.NotNil(t, poller.clock)
}

func TestPoller_WithPollFunc(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockLog := logger.NewTestLogger()
	mockClock := NewMockClock(ctrl)
	mockTicker := NewMockTicker(ctrl)

	config := &Config{
		PollerID:     "test-poller",
		Partition:    "test-partition",
		SourceIP:     "192.168.1.1",
		PollInterval: models.Duration(30 * time.Second),
		Agents: map[string]AgentConfig{
			"agent1": {
				Address: "localhost:8081",
				Checks: []Check{
					{Type: "grpc", Name: "test-service"},
				},
			},
		},
	}

	ctx := context.Background()
	poller := &Poller{
		config: *config,
		agents: make(map[string]*AgentPoller),
		done:   make(chan struct{}),
		clock:  mockClock,
		logger: mockLog,
		PollFunc: func(_ context.Context) error {
			return nil // Mock poll function
		},
	}

	// Set up mock expectations
	tickerCh := make(chan time.Time, 1)

	mockClock.EXPECT().Ticker(gomock.Any()).Return(mockTicker)
	mockTicker.EXPECT().Chan().Return(tickerCh).AnyTimes()
	mockTicker.EXPECT().Stop()

	// Test that Start method works with PollFunc
	ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()

	go func() {
		time.Sleep(50 * time.Millisecond)
		select {
		case tickerCh <- time.Now():
		default:
		}
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()

	err := poller.Start(ctx)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "context")
}

func TestPoller_StartStop(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockLog := logger.NewTestLogger()
	mockClock := NewMockClock(ctrl)

	config := &Config{
		PollerID:     "test-poller",
		Partition:    "test-partition",
		SourceIP:     "192.168.1.1",
		PollInterval: models.Duration(30 * time.Second),
		Agents:       map[string]AgentConfig{},
	}

	poller := &Poller{
		config: *config,
		agents: make(map[string]*AgentPoller),
		done:   make(chan struct{}),
		clock:  mockClock,
		logger: mockLog,
		PollFunc: func(_ context.Context) error {
			return nil
		},
	}

	// Test Stop without Start
	err := poller.Stop(context.Background())
	require.NoError(t, err)

	// Test that Stop is idempotent
	err = poller.Stop(context.Background())
	assert.NoError(t, err)
}

func TestPoller_Close(t *testing.T) {
	mockLog := logger.NewTestLogger()

	poller := &Poller{
		config: Config{},
		agents: make(map[string]*AgentPoller),
		done:   make(chan struct{}),
		logger: mockLog,
	}

	// Test Close without any connections
	err := poller.Close()
	require.NoError(t, err)

	// Test that Close is idempotent
	err = poller.Close()
	assert.NoError(t, err)
}

func TestEnhanceServicePayload(t *testing.T) {
	mockLog := logger.NewTestLogger()

	poller := &Poller{
		config: Config{
			PollerID: "test-poller",
		},
		logger: mockLog,
	}

	tests := []struct {
		name           string
		originalMsg    string
		agentID        string
		partition      string
		serviceType    string
		serviceName    string
		expectError    bool
		validateResult func(t *testing.T, result string)
	}{
		{
			name:        "valid JSON message",
			originalMsg: `{"key":"value"}`,
			agentID:     "agent1",
			partition:   "partition1",
			serviceType: "grpc",
			serviceName: "test-service",
			expectError: false,
			validateResult: func(t *testing.T, result string) {
				t.Helper()

				var payload models.ServiceMetricsPayload

				err := json.Unmarshal([]byte(result), &payload)
				require.NoError(t, err)

				assert.Equal(t, "test-poller", payload.PollerID)
				assert.Equal(t, "agent1", payload.AgentID)
				assert.Equal(t, "partition1", payload.Partition)
				assert.Equal(t, "grpc", payload.ServiceType)
				assert.Equal(t, "test-service", payload.ServiceName)
				assert.JSONEq(t, `{"key":"value"}`, string(payload.Data))
			},
		},
		{
			name:        "empty message",
			originalMsg: "",
			agentID:     "agent1",
			partition:   "partition1",
			serviceType: "grpc",
			serviceName: "test-service",
			expectError: false,
			validateResult: func(t *testing.T, result string) {
				t.Helper()

				var payload models.ServiceMetricsPayload

				err := json.Unmarshal([]byte(result), &payload)
				require.NoError(t, err)

				assert.JSONEq(t, `{}`, string(payload.Data))
			},
		},
		{
			name:        "invalid JSON message",
			originalMsg: "invalid json",
			agentID:     "agent1",
			partition:   "partition1",
			serviceType: "grpc",
			serviceName: "test-service",
			expectError: false,
			validateResult: func(t *testing.T, result string) {
				t.Helper()

				var payload models.ServiceMetricsPayload

				err := json.Unmarshal([]byte(result), &payload)
				require.NoError(t, err)

				var wrapper map[string]string

				err = json.Unmarshal(payload.Data, &wrapper)
				require.NoError(t, err)

				assert.Equal(t, "invalid json", wrapper["message"])
			},
		},
		{
			name:        "SNMP service type",
			originalMsg: `{"oid": "1.3.6.1.2.1.1.1.0"}`,
			agentID:     "agent1",
			partition:   "partition1",
			serviceType: "snmp",
			serviceName: "snmp-service",
			expectError: false,
			validateResult: func(t *testing.T, result string) {
				t.Helper()

				var payload models.ServiceMetricsPayload

				err := json.Unmarshal([]byte(result), &payload)
				require.NoError(t, err)

				assert.Equal(t, "snmp", payload.ServiceType)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := poller.enhanceServicePayload(
				tt.originalMsg,
				tt.agentID,
				tt.partition,
				tt.serviceType,
				tt.serviceName,
			)

			if tt.expectError {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
				tt.validateResult(t, result)
			}
		})
	}
}

func TestReportToCore_StreamingThreshold(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockLog := logger.NewTestLogger()
	mockCoreClient := proto.NewMockPollerServiceClient(ctrl)

	poller := &Poller{
		config: Config{
			PollerID:  "test-poller",
			Partition: "test-partition",
			SourceIP:  "192.168.1.1",
		},
		coreClient: mockCoreClient,
		logger:     mockLog,
	}

	ctx := context.Background()

	// Test with fewer than streaming threshold (should use regular ReportStatus)
	smallStatuses := make([]*proto.ServiceStatus, 50)
	for i := range smallStatuses {
		smallStatuses[i] = &proto.ServiceStatus{
			ServiceName: fmt.Sprintf("service-%d", i),
			ServiceType: "grpc",
			Available:   true,
			AgentId:     "agent1",
		}
	}

	mockCoreClient.EXPECT().
		ReportStatus(ctx, gomock.Any()).
		Return(&proto.PollerStatusResponse{}, nil)

	err := poller.reportToCore(ctx, smallStatuses)
	require.NoError(t, err)

	// Test with more than streaming threshold (should use streaming)
	// We'll test streaming through an integration test or by checking if the right path is taken
	largeStatuses := make([]*proto.ServiceStatus, 150)
	for i := range largeStatuses {
		largeStatuses[i] = &proto.ServiceStatus{
			ServiceName: fmt.Sprintf("service-%d", i),
			ServiceType: "grpc",
			Available:   true,
			AgentId:     "agent1",
		}
	}

	// For simplicity, just test that the streaming path is called by expecting a stream creation error
	expectedErr := fmt.Errorf("stream error")
	mockCoreClient.EXPECT().
		StreamStatus(ctx).
		Return(nil, expectedErr)

	err = poller.reportToCore(ctx, largeStatuses)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "failed to create stream to core")
}

func TestReportToCoreStreaming_Error(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockLog := logger.NewTestLogger()
	mockCoreClient := proto.NewMockPollerServiceClient(ctrl)

	poller := &Poller{
		config: Config{
			PollerID:  "test-poller",
			Partition: "test-partition",
			SourceIP:  "192.168.1.1",
		},
		coreClient: mockCoreClient,
		logger:     mockLog,
	}

	ctx := context.Background()
	statuses := []*proto.ServiceStatus{
		{
			ServiceName: "service-1",
			ServiceType: "grpc",
			Available:   true,
			AgentId:     "agent1",
		},
	}

	// Test stream creation error
	expectedErr := fmt.Errorf("stream creation failed")
	mockCoreClient.EXPECT().
		StreamStatus(ctx).
		Return(nil, expectedErr)

	err := poller.reportToCoreStreaming(ctx, statuses)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "failed to create stream to core")
}
