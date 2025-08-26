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
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// TestArmisNetBoxStreamResults tests that both Armis and NetBox data is properly streamed through StreamResults
func TestArmisNetBoxStreamResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Mock dependencies
	mockKVClient := NewMockKVClient(ctrl)
	mockGRPCClient := NewMockGRPCClient(ctrl)

	// Create test config with both Armis and NetBox sources
	config := &Config{
		AgentID:           "test-agent",
		PollerID:          "test-poller",
		DiscoveryInterval: models.Duration(30 * time.Second),
		UpdateInterval:    models.Duration(60 * time.Second),
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:     "armis",
				AgentID:  "test-agent",
				PollerID: "test-poller",
			},
			"netbox": {
				Type:     "netbox",
				AgentID:  "test-agent",
				PollerID: "test-poller",
			},
		},
	}

	// Create mock integrations that return test data
	mockArmisIntegration := NewMockIntegration(ctrl)
	mockNetBoxIntegration := NewMockIntegration(ctrl)

	// Create service with mocked integrations
	service := &SimpleSyncService{
		config:     *config,
		kvClient:   mockKVClient,
		grpcClient: mockGRPCClient,
		sources: map[string]Integration{
			"armis":  mockArmisIntegration,
			"netbox": mockNetBoxIntegration,
		},
		resultsStore: &StreamingResultsStore{
			results: make(map[string][]*models.DeviceUpdate),
		},
		logger: logger.NewTestLogger(),
	}

	// Set up test data
	armisDevices := []*models.DeviceUpdate{
		{
			DeviceID:    "test:192.168.1.1",
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Source:      models.DiscoverySourceArmis,
			IP:          "192.168.1.1",
			IsAvailable: true,
			Timestamp:   time.Now(),
			Metadata: map[string]string{
				"integration_type": "armis",
				"integration_id":   "1001",
			},
		},
		{
			DeviceID:    "test:192.168.1.2",
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Source:      models.DiscoverySourceArmis,
			IP:          "192.168.1.2",
			IsAvailable: true,
			Timestamp:   time.Now(),
			Metadata: map[string]string{
				"integration_type": "armis",
				"integration_id":   "1002",
			},
		},
	}

	netboxDevices := []*models.DeviceUpdate{
		{
			DeviceID:    "test:10.0.0.1",
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Source:      models.DiscoverySourceNetbox,
			IP:          "10.0.0.1",
			IsAvailable: false, // NetBox doesn't set this to true
			Timestamp:   time.Now(),
			Metadata: map[string]string{
				"integration_type": "netbox",
				"integration_id":   "2001",
			},
		},
		{
			DeviceID:    "test:10.0.0.2",
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Source:      models.DiscoverySourceNetbox,
			IP:          "10.0.0.2",
			IsAvailable: false, // NetBox doesn't set this to true
			Timestamp:   time.Now(),
			Metadata: map[string]string{
				"integration_type": "netbox",
				"integration_id":   "2002",
			},
		},
	}

	// Simulate discovery storing results
	service.resultsStore.mu.Lock()
	service.resultsStore.results["armis"] = armisDevices
	service.resultsStore.results["netbox"] = netboxDevices
	service.resultsStore.updated = time.Now()
	service.resultsStore.mu.Unlock()

	// Create a mock stream to capture results
	mockStream := NewMockAgentService_StreamResultsServer[*proto.ResultsChunk](ctrl)

	var capturedChunks []*proto.ResultsChunk

	mockStream.EXPECT().Send(gomock.Any()).DoAndReturn(func(chunk *proto.ResultsChunk) error {
		capturedChunks = append(capturedChunks, chunk)
		return nil
	}).Times(1) // Expecting 1 chunk for 4 devices

	// Create request
	req := &proto.ResultsRequest{
		ServiceName: "test-service",
		ServiceType: "sync",
		AgentId:     "test-agent",
		PollerId:    "test-poller",
	}

	// Call StreamResults
	err := service.StreamResults(req, mockStream)
	require.NoError(t, err)

	// Verify results
	require.Len(t, capturedChunks, 1, "Expected 1 chunk")
	chunk := capturedChunks[0]

	// Unmarshal the chunk data
	var receivedDevices []*models.DeviceUpdate

	err = json.Unmarshal(chunk.Data, &receivedDevices)
	require.NoError(t, err)

	// Should have all 4 devices (2 from Armis, 2 from NetBox)
	assert.Len(t, receivedDevices, 4, "Should have all devices from both sources")

	// Count devices by source
	armisCount := 0
	netboxCount := 0

	for _, device := range receivedDevices {
		switch device.Source {
		case models.DiscoverySourceArmis:
			armisCount++

			assert.True(t, device.IsAvailable, "Armis devices should have IsAvailable=true")
			assert.Equal(t, "armis", device.Metadata["integration_type"])
		case models.DiscoverySourceNetbox:
			netboxCount++

			assert.False(t, device.IsAvailable, "NetBox devices should have IsAvailable=false")
			assert.Equal(t, "netbox", device.Metadata["integration_type"])
		case models.DiscoverySourceSNMP:
			// Not expected in this test
		case models.DiscoverySourceMapper:
			// Not expected in this test
		case models.DiscoverySourceIntegration:
			// Not expected in this test
		case models.DiscoverySourceNetFlow:
			// Not expected in this test
		case models.DiscoverySourceManual:
			// Not expected in this test
		case models.DiscoverySourceSweep:
			// Not expected in this test
		case models.DiscoverySourceSelfReported:
			// Not expected in this test
		case models.DiscoverySourceSysmon:
		}
	}

	assert.Equal(t, 2, armisCount, "Should have 2 Armis devices")
	assert.Equal(t, 2, netboxCount, "Should have 2 NetBox devices")
}

// TestGetResultsWithArmisAndNetBox tests the legacy GetResults method with both sources
func TestGetResultsWithArmisAndNetBox(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Mock dependencies
	mockKVClient := NewMockKVClient(ctrl)
	mockGRPCClient := NewMockGRPCClient(ctrl)

	// Create test config
	config := &Config{
		AgentID:  "test-agent",
		PollerID: "test-poller",
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type: "armis",
			},
			"netbox": {
				Type: "netbox",
			},
		},
	}

	// Create service
	service := &SimpleSyncService{
		config:     *config,
		kvClient:   mockKVClient,
		grpcClient: mockGRPCClient,
		resultsStore: &StreamingResultsStore{
			results: make(map[string][]*models.DeviceUpdate),
		},
		logger: logger.NewTestLogger(),
	}

	// Set up test data
	armisDevice := &models.DeviceUpdate{
		DeviceID:    "test:192.168.1.1",
		Source:      models.DiscoverySourceArmis,
		IP:          "192.168.1.1",
		IsAvailable: true,
		Metadata: map[string]string{
			"integration_type": "armis",
		},
	}

	netboxDevice := &models.DeviceUpdate{
		DeviceID:    "test:10.0.0.1",
		Source:      models.DiscoverySourceNetbox,
		IP:          "10.0.0.1",
		IsAvailable: false,
		Metadata: map[string]string{
			"integration_type": "netbox",
		},
	}

	// Store results
	service.resultsStore.mu.Lock()
	service.resultsStore.results["armis"] = []*models.DeviceUpdate{armisDevice}
	service.resultsStore.results["netbox"] = []*models.DeviceUpdate{netboxDevice}
	service.resultsStore.updated = time.Now()
	service.resultsStore.mu.Unlock()

	// Call GetResults
	req := &proto.ResultsRequest{
		ServiceName: "test-service",
		ServiceType: "sync",
		PollerId:    "test-poller",
	}

	resp, err := service.GetResults(ctx, req)
	require.NoError(t, err)
	require.NotNil(t, resp)

	// Unmarshal response
	var devices []*models.DeviceUpdate

	err = json.Unmarshal(resp.Data, &devices)
	require.NoError(t, err)

	// Should have both devices
	assert.Len(t, devices, 2, "Should have devices from both sources")

	// Verify both sources are represented
	hasArmis := false
	hasNetBox := false

	for _, device := range devices {
		switch device.Source { //nolint:exhaustive // only checking specific cases in test
		case models.DiscoverySourceArmis:
			hasArmis = true
		case models.DiscoverySourceNetbox:
			hasNetBox = true
		}
	}

	assert.True(t, hasArmis, "Should have Armis device")
	assert.True(t, hasNetBox, "Should have NetBox device")
}
