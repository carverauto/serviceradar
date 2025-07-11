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

package sync

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// testLogger creates a no-op logger for tests
func testGRPCLogger() logger.Logger {
	config := &logger.Config{
		Level:  "disabled",
		Output: "stderr",
	}
	log, err := lifecycle.CreateLogger(config)
	if err != nil {
		panic(err)
	}
	return log
}

func TestPollerService_GetStatus(t *testing.T) {
	// Create a test service with some cached results
	service := &PollerService{
		config: Config{
			AgentID: "test-agent",
		},
		resultsCache: []*models.SweepResult{
			{
				IP:              "192.168.1.1",
				DiscoverySource: "armis",
				Available:       true,
				Timestamp:       time.Now(),
			},
			{
				IP:              "192.168.1.2",
				DiscoverySource: "armis",
				Available:       true,
				Timestamp:       time.Now(),
			},
		},
		logger: testGRPCLogger(),
	}

	req := &proto.StatusRequest{
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}

	ctx := context.Background()
	resp, err := service.GetStatus(ctx, req)

	require.NoError(t, err)
	require.NotNil(t, resp)

	// Verify response structure
	assert.True(t, resp.Available)
	assert.Equal(t, "test-agent", resp.AgentId)

	// Verify health check data (should be minimal)
	var healthData map[string]interface{}
	err = json.Unmarshal(resp.Message, &healthData)
	require.NoError(t, err)

	assert.Equal(t, "healthy", healthData["status"])
	assert.InDelta(t, float64(2), healthData["cached_devices"], 0.0001) // JSON unmarshal makes numbers float64
	assert.NotNil(t, healthData["timestamp"])

	// Verify it's NOT returning the full device list
	assert.NotContains(t, string(resp.Message), "192.168.1.1")
	assert.NotContains(t, string(resp.Message), "192.168.1.2")
}

func TestPollerService_GetResults(t *testing.T) {
	// Create test results
	testResults := []*models.SweepResult{
		{
			IP:              "192.168.1.1",
			DiscoverySource: "armis",
			Available:       true,
			Timestamp:       time.Now(),
		},
		{
			IP:              "192.168.1.2",
			DiscoverySource: "armis",
			Available:       true,
			Timestamp:       time.Now(),
		},
	}

	service := &PollerService{
		config: Config{
			AgentID: "test-agent",
		},
		resultsCache: testResults,
		logger:       testGRPCLogger(),
	}

	req := &proto.ResultsRequest{
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}

	ctx := context.Background()
	resp, err := service.GetResults(ctx, req)

	require.NoError(t, err)
	require.NotNil(t, resp)

	// Verify response structure
	assert.True(t, resp.Available)
	assert.Equal(t, "test-agent", resp.AgentId)
	assert.Equal(t, "test-poller", resp.PollerId)
	assert.Equal(t, "sync", resp.ServiceName)
	assert.Equal(t, "grpc", resp.ServiceType)
	assert.Positive(t, resp.Timestamp)

	// Verify full device data is returned
	var returnedResults []*models.SweepResult
	err = json.Unmarshal(resp.Data, &returnedResults)
	require.NoError(t, err)

	assert.Len(t, returnedResults, 2)
	assert.Equal(t, "192.168.1.1", returnedResults[0].IP)
	assert.Equal(t, "192.168.1.2", returnedResults[1].IP)
	assert.Equal(t, "armis", returnedResults[0].DiscoverySource)
	assert.Equal(t, "armis", returnedResults[1].DiscoverySource)
}

func TestPollerService_GetStatusVsGetResults_Separation(t *testing.T) {
	// Create a service with a larger number of cached results to test the separation
	testResults := make([]*models.SweepResult, 1000)
	for i := 0; i < 1000; i++ {
		testResults[i] = &models.SweepResult{
			IP:              fmt.Sprintf("192.168.1.%d", i+1),
			DiscoverySource: "armis",
			Available:       true,
			Timestamp:       time.Now(),
		}
	}

	service := &PollerService{
		config: Config{
			AgentID: "test-agent",
		},
		resultsCache: testResults,
		logger:       testGRPCLogger(),
	}

	ctx := context.Background()

	// Test GetStatus - should return minimal health data
	statusReq := &proto.StatusRequest{
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}

	statusResp, err := service.GetStatus(ctx, statusReq)
	require.NoError(t, err)

	// Test GetResults - should return full device data
	resultsReq := &proto.ResultsRequest{
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}

	resultsResp, err := service.GetResults(ctx, resultsReq)
	require.NoError(t, err)

	// Compare sizes - GetStatus should be much smaller
	statusSize := len(statusResp.Message)
	resultsSize := len(resultsResp.Data)

	t.Logf("GetStatus message size: %d bytes", statusSize)
	t.Logf("GetResults data size: %d bytes", resultsSize)

	// GetStatus should be dramatically smaller (< 1KB vs potentially MBs)
	assert.Less(t, statusSize, 1000, "GetStatus should return minimal data")
	assert.Greater(t, resultsSize, statusSize*10, "GetResults should return much more data")

	// Verify GetStatus contains health info
	var healthData map[string]interface{}
	err = json.Unmarshal(statusResp.Message, &healthData)
	require.NoError(t, err)
	assert.Equal(t, "healthy", healthData["status"])
	assert.InDelta(t, float64(1000), healthData["cached_devices"], 0.0001)

	// Verify GetResults contains actual device data
	var deviceData []*models.SweepResult
	err = json.Unmarshal(resultsResp.Data, &deviceData)
	require.NoError(t, err)
	assert.Len(t, deviceData, 1000)
	assert.Equal(t, "192.168.1.1", deviceData[0].IP)
}

func TestPollerService_GetResults_EmptyCache(t *testing.T) {
	service := &PollerService{
		config: Config{
			AgentID: "test-agent",
		},
		resultsCache: []*models.SweepResult{}, // Empty cache
		logger:       testGRPCLogger(),
	}

	req := &proto.ResultsRequest{
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}

	ctx := context.Background()
	resp, err := service.GetResults(ctx, req)

	require.NoError(t, err)
	require.NotNil(t, resp)

	// Should still return valid response
	assert.True(t, resp.Available)
	assert.Equal(t, "test-agent", resp.AgentId)

	// Should return empty array
	var results []*models.SweepResult

	err = json.Unmarshal(resp.Data, &results)
	require.NoError(t, err)
	assert.Empty(t, results, "Expected empty results when cache is empty")
}

func TestPollerService_GetStatus_EmptyCache(t *testing.T) {
	service := &PollerService{
		config: Config{
			AgentID: "test-agent",
		},
		resultsCache: []*models.SweepResult{}, // Empty cache
		logger:       testGRPCLogger(),
	}

	req := &proto.StatusRequest{
		ServiceName: "sync",
		ServiceType: "grpc",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}

	ctx := context.Background()
	resp, err := service.GetStatus(ctx, req)

	require.NoError(t, err)
	require.NotNil(t, resp)

	// Should still return valid response
	assert.True(t, resp.Available)
	assert.Equal(t, "test-agent", resp.AgentId)

	// Should return health data with 0 cached devices
	var healthData map[string]interface{}

	err = json.Unmarshal(resp.Message, &healthData)
	require.NoError(t, err)

	assert.Equal(t, "healthy", healthData["status"])
	assert.InDelta(t, float64(0), healthData["cached_devices"], 0.0001)
}
