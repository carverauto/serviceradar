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
	"fmt"
	"testing"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestResultsPoller_buildResultsRequest(t *testing.T) {
	rp := &ResultsPoller{
		check: Check{
			Type:    "grpc",
			Name:    "test-service",
			Details: "test-details",
		},
		agentName:    "test-agent",
		pollerID:     "test-poller",
		lastSequence: "seq-123",
		logger:       logger.NewTestLogger(),
	}

	req := rp.buildResultsRequest()

	assert.Equal(t, "test-service", req.ServiceName)
	assert.Equal(t, "grpc", req.ServiceType)
	assert.Equal(t, "test-agent", req.AgentId)
	assert.Equal(t, "test-poller", req.PollerId)
	assert.Equal(t, "test-details", req.Details)
	assert.Equal(t, "seq-123", req.LastSequence)
}

func TestResultsPoller_handleGetResultsError(t *testing.T) {
	rp := &ResultsPoller{
		check: Check{
			Type: "grpc",
			Name: "test-service",
		},
		agentName: "test-agent",
		pollerID:  "test-poller",
		logger:    logger.NewTestLogger(),
	}

	tests := []struct {
		name           string
		err            error
		expectNil      bool
		expectedStatus *proto.ServiceStatus
	}{
		{
			name:      "unimplemented error returns nil",
			err:       status.Error(codes.Unimplemented, "not implemented"),
			expectNil: true,
		},
		{
			name:      "other error returns service status",
			err:       fmt.Errorf("connection failed"),
			expectNil: false,
			expectedStatus: &proto.ServiceStatus{
				ServiceName: "test-service",
				Available:   false,
				ServiceType: "grpc",
				PollerId:    "test-poller",
				AgentId:     "test-agent",
				Source:      "results",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := rp.handleGetResultsError(tt.err)

			if tt.expectNil {
				assert.Nil(t, result)
			} else {
				require.NotNil(t, result)
				assert.Equal(t, tt.expectedStatus.ServiceName, result.ServiceName)
				assert.Equal(t, tt.expectedStatus.Available, result.Available)
				assert.Equal(t, tt.expectedStatus.ServiceType, result.ServiceType)
				assert.Equal(t, tt.expectedStatus.PollerId, result.PollerId)
				assert.Equal(t, tt.expectedStatus.AgentId, result.AgentId)
				assert.Equal(t, tt.expectedStatus.Source, result.Source)
				assert.Contains(t, string(result.Message), "GetResults failed")
			}
		})
	}
}

func TestResultsPoller_updateSequenceTracking(t *testing.T) {
	tests := []struct {
		name             string
		results          *proto.ResultsResponse
		expectedSequence string
	}{
		{
			name: "updates sequence when present",
			results: &proto.ResultsResponse{
				CurrentSequence: "new-seq",
			},
			expectedSequence: "new-seq",
		},
		{
			name: "keeps old sequence when empty",
			results: &proto.ResultsResponse{
				CurrentSequence: "",
			},
			expectedSequence: "old-seq",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rp := &ResultsPoller{
				lastSequence: "old-seq",
				logger:       logger.NewTestLogger(),
			}
			rp.updateSequenceTracking(tt.results)
			assert.Equal(t, tt.expectedSequence, rp.lastSequence)
		})
	}
}

func TestResultsPoller_shouldSkipCoreSubmission(t *testing.T) {
	tests := []struct {
		name       string
		checkName  string
		checkType  string
		hasNewData bool
		expectSkip bool
	}{
		{
			name:       "sync service never skips",
			checkName:  "sync",
			checkType:  "grpc",
			hasNewData: false,
			expectSkip: false,
		},
		{
			name:       "sync service with data never skips",
			checkName:  "sync",
			checkType:  "grpc",
			hasNewData: true,
			expectSkip: false,
		},
		{
			name:       "service containing sync never skips",
			checkName:  "armis-sync",
			checkType:  "grpc",
			hasNewData: false,
			expectSkip: false,
		},
		{
			name:       "sweep service with no new data skips",
			checkName:  "test-service",
			checkType:  "sweep",
			hasNewData: false,
			expectSkip: true,
		},
		{
			name:       "sweep service with new data does not skip",
			checkName:  "test-service",
			checkType:  "sweep",
			hasNewData: true,
			expectSkip: false,
		},
		{
			name:       "other service types do not skip",
			checkName:  "test-service",
			checkType:  "grpc",
			hasNewData: false,
			expectSkip: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rp := &ResultsPoller{
				check: Check{
					Name: tt.checkName,
					Type: tt.checkType,
				},
				logger: logger.NewTestLogger(),
			}

			results := &proto.ResultsResponse{
				HasNewData: tt.hasNewData,
			}

			shouldSkip := rp.shouldSkipCoreSubmission(results)
			assert.Equal(t, tt.expectSkip, shouldSkip)
		})
	}
}

func TestResultsPoller_convertToServiceStatus(t *testing.T) {
	rp := &ResultsPoller{
		check: Check{
			Name: "test-service",
			Type: "grpc",
		},
		pollerID: "test-poller",
		logger:   logger.NewTestLogger(),
	}

	results := &proto.ResultsResponse{
		Available:    true,
		Data:         []byte("test-data"),
		ServiceName:  "test-service",
		ServiceType:  "grpc",
		ResponseTime: 1000000,
		AgentId:      "test-agent",
	}

	serviceStatus := rp.convertToServiceStatus(results)

	assert.Equal(t, "test-service", serviceStatus.ServiceName)
	assert.True(t, serviceStatus.Available)
	assert.Equal(t, []byte("test-data"), serviceStatus.Message)
	assert.Equal(t, "grpc", serviceStatus.ServiceType)
	assert.Equal(t, int64(1000000), serviceStatus.ResponseTime)
	assert.Equal(t, "test-agent", serviceStatus.AgentId)
	assert.Equal(t, "test-poller", serviceStatus.PollerId)
	assert.Equal(t, "results", serviceStatus.Source)
}

func TestResultsPoller_executeGetResults_Unary(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)

	rp := &ResultsPoller{
		client: mockClient,
		check: Check{
			Name: "test-service",
			Type: "grpc", // Not sync or sweep, so uses unary
		},
		agentName: "test-agent",
		pollerID:  "test-poller",
		logger:    logger.NewTestLogger(),
	}

	expectedReq := &proto.ResultsRequest{
		ServiceName: "test-service",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}

	expectedResults := &proto.ResultsResponse{
		Available:       true,
		Data:            []byte("test-data"),
		ServiceName:     "test-service",
		ServiceType:     "grpc",
		HasNewData:      true,
		CurrentSequence: "seq-123",
	}

	mockClient.EXPECT().
		GetResults(gomock.Any(), gomock.Eq(expectedReq)).
		Return(expectedResults, nil)

	ctx := context.Background()
	status := rp.executeGetResults(ctx)

	require.NotNil(t, status)
	assert.Equal(t, "test-service", status.ServiceName)
	assert.True(t, status.Available)
	assert.Equal(t, []byte("test-data"), status.Message)
	assert.Equal(t, "seq-123", rp.lastSequence)
}

func TestResultsPoller_executeGetResults_Error(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)

	rp := &ResultsPoller{
		client: mockClient,
		check: Check{
			Name: "test-service",
			Type: "grpc",
		},
		agentName: "test-agent",
		pollerID:  "test-poller",
		logger:    logger.NewTestLogger(),
	}

	expectedErr := fmt.Errorf("connection failed")
	mockClient.EXPECT().
		GetResults(gomock.Any(), gomock.Any()).
		Return(nil, expectedErr)

	ctx := context.Background()
	status := rp.executeGetResults(ctx)

	require.NotNil(t, status)
	assert.Equal(t, "test-service", status.ServiceName)
	assert.False(t, status.Available)
	assert.Contains(t, string(status.Message), "GetResults failed")
}

func TestResultsPoller_executeGetResults_NilResponse(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)

	rp := &ResultsPoller{
		client: mockClient,
		check: Check{
			Name: "test-service",
			Type: "grpc",
		},
		agentName: "test-agent",
		pollerID:  "test-poller",
		logger:    logger.NewTestLogger(),
	}

	mockClient.EXPECT().
		GetResults(gomock.Any(), gomock.Any()).
		Return(nil, nil)

	ctx := context.Background()
	status := rp.executeGetResults(ctx)

	assert.Nil(t, status)
}

func TestResultsPoller_executeStreamResults_StreamError(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)

	rp := &ResultsPoller{
		client: mockClient,
		check: Check{
			Name: "sync-service",
			Type: "sync",
		},
		logger: logger.NewTestLogger(),
	}

	req := &proto.ResultsRequest{
		ServiceName: "sync-service",
		ServiceType: "sync",
	}

	expectedErr := fmt.Errorf("stream creation failed")
	mockClient.EXPECT().
		StreamResults(gomock.Any(), gomock.Eq(req)).
		Return(nil, expectedErr)

	ctx := context.Background()
	results, err := rp.executeStreamResults(ctx, req)

	require.Error(t, err)
	assert.Nil(t, results)
}

func TestResultsPoller_executeGetResults_StreamingRoute(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)

	rp := &ResultsPoller{
		client: mockClient,
		check: Check{
			Name: "sync-service",
			Type: "sync", // Should trigger streaming route
		},
		agentName: "test-agent",
		pollerID:  "test-poller",
		logger:    logger.NewTestLogger(),
	}

	// Test that it calls StreamResults instead of GetResults for sync type
	expectedErr := fmt.Errorf("stream error")
	mockClient.EXPECT().
		StreamResults(gomock.Any(), gomock.Any()).
		Return(nil, expectedErr)

	ctx := context.Background()
	status := rp.executeGetResults(ctx)

	require.NotNil(t, status)
	assert.Equal(t, "sync-service", status.ServiceName)
	assert.False(t, status.Available)
	assert.Contains(t, string(status.Message), "stream error")
}

func TestResultsPoller_executeGetResults_WithSubmission(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentServiceClient(ctrl)

	rp := &ResultsPoller{
		client: mockClient,
		check: Check{
			Name: "test-service",
			Type: "grpc", // Use grpc type to avoid streaming
		},
		agentName: "test-agent",
		pollerID:  "test-poller",
		logger:    logger.NewTestLogger(),
	}

	expectedResults := &proto.ResultsResponse{
		Available:       true,
		Data:            []byte("test-data"),
		ServiceName:     "test-service",
		ServiceType:     "grpc",
		HasNewData:      true,
		CurrentSequence: "seq-789",
	}

	mockClient.EXPECT().
		GetResults(gomock.Any(), gomock.Any()).
		Return(expectedResults, nil)

	ctx := context.Background()
	status := rp.executeGetResults(ctx)

	// Should return status since no skip conditions are met
	require.NotNil(t, status)
	assert.Equal(t, "test-service", status.ServiceName)
	assert.True(t, status.Available)
	// Sequence should be updated
	assert.Equal(t, "seq-789", rp.lastSequence)
}
