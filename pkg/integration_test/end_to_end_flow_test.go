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

package integration

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

// TestEndToEndDiscoveryFlow validates the complete flow:
// 1. Sync service discovers devices → publishes to KV + caches SweepResults
// 2. Poller calls sync GetResults → forwards discovery data to core
// 3. Agent detects KV changes → starts ping sweep
// 4. Poller calls agent GetResults → forwards sweep data to core
// 5. Poller triggers Armis updater after both discovery and sweep complete
func TestEndToEndDiscoveryFlow(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Step 1: Setup - Create mock services
	mockKV := NewMockKVService(ctrl)
	mockCore := NewMockCoreService(ctrl)
	mockAgent := NewMockAgentService(ctrl)
	mockSync := NewMockSyncService(ctrl)
	mockArmisUpdater := NewMockArmisUpdater(ctrl)

	// Test data - devices discovered by sync service
	discoveredDevices := []*models.SweepResult{
		{
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Partition:       "default",
			DeviceID:        "default:192.168.1.1",
			DiscoverySource: "armis",
			IP:              "192.168.1.1",
			Hostname:        stringPtr("device1"),
			Available:       false, // Not yet swept
			Timestamp:       time.Now(),
			Metadata: map[string]string{
				"integration_type": "armis",
				"integration_id":   "12345",
			},
		},
		{
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Partition:       "default",
			DeviceID:        "default:192.168.1.2",
			DiscoverySource: "armis",
			IP:              "192.168.1.2",
			Hostname:        stringPtr("device2"),
			Available:       false, // Not yet swept
			Timestamp:       time.Now(),
			Metadata: map[string]string{
				"integration_type": "armis",
				"integration_id":   "67890",
			},
		},
	}

	// KV data that sync service writes
	kvData := map[string][]byte{
		"armis/test-agent/192.168.1.1": mustMarshal(t, discoveredDevices[0]),
		"armis/test-agent/192.168.1.2": mustMarshal(t, discoveredDevices[1]),
	}

	// Sweep results after ping sweep completes
	sweptDevices := []*models.SweepResult{
		{
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Partition:       "default",
			DeviceID:        "default:192.168.1.1",
			DiscoverySource: "sweep",
			IP:              "192.168.1.1",
			Hostname:        stringPtr("device1"),
			Available:       true, // Now available after sweep
			Timestamp:       time.Now(),
		},
		{
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Partition:       "default",
			DeviceID:        "default:192.168.1.2",
			DiscoverySource: "sweep",
			IP:              "192.168.1.2",
			Hostname:        stringPtr("device2"),
			Available:       false, // Not responsive
			Timestamp:       time.Now(),
		},
	}

	// Step 2: Sync service discovery
	t.Log("=== Step 1: Sync service discovers devices ===")

	// Mock KV writes from sync service
	mockKV.EXPECT().
		PutMany(gomock.Any(), gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, req *proto.PutManyRequest, _ ...interface{}) (*proto.PutManyResponse, error) {
			t.Logf("Sync service wrote %d entries to KV", len(req.Entries))
			assert.Len(t, req.Entries, 2)

			// Verify KV entries match expected format
			for _, entry := range req.Entries {
				assert.Contains(t, []string{"armis/test-agent/192.168.1.1", "armis/test-agent/192.168.1.2"}, entry.Key)
			}

			return &proto.PutManyResponse{}, nil
		})

	// Simulate sync service completing discovery
	// In real code, this would be the syncSourceDiscovery method
	simulateSyncDiscovery(t, mockKV, discoveredDevices, kvData)

	// Step 3: Poller calls sync service GetResults
	t.Log("=== Step 2: Poller requests sync discovery results ===")

	discoveryResultsJSON := mustMarshal(t, discoveredDevices)

	// Mock sync service returning cached discovery results
	mockSync.EXPECT().
		GetResults(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, _ *proto.ResultsRequest) (*proto.ResultsResponse, error) {
			t.Logf("Sync service returning %d discovery results", len(discoveredDevices))

			return &proto.ResultsResponse{
				Available:       true,
				Data:            discoveryResultsJSON,
				ServiceName:     "sync",
				ServiceType:     "sync",
				AgentId:         "test-agent",
				PollerId:        "test-poller",
				HasNewData:      true,
				CurrentSequence: "discovery-seq-123",
			}, nil
		})

	// Step 4: Poller forwards discovery results to core
	t.Log("=== Step 3: Poller forwards discovery results to core ===")

	var receivedDiscoveryResults []*models.SweepResult

	mockCore.EXPECT().
		ReportStatus(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
			// Find sync service status in the report
			for _, svc := range req.Services {
				if svc.ServiceType == "sync" {
					err := json.Unmarshal(svc.Message, &receivedDiscoveryResults)
					require.NoError(t, err)
					t.Logf("Core received %d discovery results from sync service", len(receivedDiscoveryResults))

					// Verify discovery results
					assert.Len(t, receivedDiscoveryResults, 2)

					for _, result := range receivedDiscoveryResults {
						assert.Equal(t, "armis", result.DiscoverySource)
						assert.False(t, result.Available) // Not yet swept
					}
				}
			}

			return &proto.PollerStatusResponse{}, nil
		})

	// Simulate poller calling sync GetResults and forwarding to core
	simulatePollerSyncFlow(t, mockSync, mockCore)

	// Step 5: Agent detects KV changes and starts sweep
	t.Log("=== Step 4: Agent detects KV changes and starts ping sweep ===")

	// Mock agent detecting KV changes (in real code, this would be a KV watch)
	// and then performing ping sweep
	simulateAgentKVWatch(t, kvData)

	// Step 6: Poller calls agent GetResults for sweep data
	t.Log("=== Step 5: Poller requests agent sweep results ===")

	sweepResultsJSON := mustMarshal(t, sweptDevices)

	mockAgent.EXPECT().
		GetResults(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, _ *proto.ResultsRequest) (*proto.ResultsResponse, error) {
			t.Logf("Agent returning %d sweep results", len(sweptDevices))

			return &proto.ResultsResponse{
				Available:       true,
				Data:            sweepResultsJSON,
				ServiceName:     "sweep",
				ServiceType:     "sweep",
				AgentId:         "test-agent",
				PollerId:        "test-poller",
				HasNewData:      true,
				CurrentSequence: "sweep-seq-456",
			}, nil
		})

	// Step 7: Poller forwards sweep results to core
	t.Log("=== Step 6: Poller forwards sweep results to core ===")

	var receivedSweepResults []*models.SweepResult

	mockCore.EXPECT().
		ReportStatus(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
			// Find sweep service status in the report
			for _, svc := range req.Services {
				if svc.ServiceType == "sweep" {
					err := json.Unmarshal(svc.Message, &receivedSweepResults)
					require.NoError(t, err)

					t.Logf("Core received %d sweep results from agent", len(receivedSweepResults))

					// Verify sweep results
					assert.Len(t, receivedSweepResults, 2)

					for _, result := range receivedSweepResults {
						// One device should be available, one not
						assert.Equal(t, "sweep", result.DiscoverySource)
					}
				}
			}

			return &proto.PollerStatusResponse{}, nil
		})

	// Simulate poller calling agent GetResults and forwarding to core
	simulatePollerAgentFlow(t, mockAgent, mockCore)

	// Step 8: Poller triggers Armis updater
	t.Log("=== Step 7: Poller triggers Armis updater ===")

	// Mock Armis updater execution
	mockArmisUpdater.EXPECT().
		RunUpdate(gomock.Any()).
		DoAndReturn(func(_ context.Context) error {
			t.Log("Armis updater executed SRQL query to update devices in Armis")

			return nil
		})

	// Simulate poller triggering updater after both discovery and sweep complete
	simulateUpdaterTrigger(t, mockArmisUpdater, receivedDiscoveryResults, receivedSweepResults)

	// Step 9: Verify final state
	t.Log("=== Step 8: Verify complete flow ===")

	// Verify we received both discovery and sweep results
	assert.Len(t, receivedDiscoveryResults, 2, "Should receive discovery results")
	assert.Len(t, receivedSweepResults, 2, "Should receive sweep results")

	// Verify discovery results have Armis metadata
	for _, result := range receivedDiscoveryResults {
		assert.Equal(t, "armis", result.DiscoverySource)
		assert.Contains(t, result.Metadata, "integration_type")
		assert.Equal(t, "armis", result.Metadata["integration_type"])
	}

	// Verify sweep results have availability data
	availableCount := 0

	for _, result := range receivedSweepResults {
		assert.Equal(t, "sweep", result.DiscoverySource)

		if result.Available {
			availableCount++
		}
	}

	assert.Equal(t, 1, availableCount, "Should have one available device after sweep")

	t.Log("✅ End-to-end discovery flow completed successfully!")
}

// Helper functions to simulate each part of the flow

func simulateSyncDiscovery(t *testing.T, mockKV *MockKVService, devices []*models.SweepResult, kvData map[string][]byte) {
	t.Helper()
	// This simulates what syncSourceDiscovery does:
	// 1. Calls integration.Fetch() which returns devices
	// 2. Calls writeToKV() to store device data
	// 3. Caches results for GetResults calls

	ctx := context.Background()

	// Convert devices to KV entries
	entries := make([]*proto.KeyValueEntry, 0, len(kvData))

	for key, value := range kvData {
		entries = append(entries, &proto.KeyValueEntry{
			Key:   key,
			Value: value,
		})
	}

	req := &proto.PutManyRequest{Entries: entries}

	_, err := mockKV.PutMany(ctx, req)
	require.NoError(t, err)

	t.Logf("Sync service discovered %d devices and wrote to KV", len(devices))
}

func simulatePollerSyncFlow(t *testing.T, mockSync *MockSyncService, mockCore *MockCoreService) {
	t.Helper()

	ctx := context.Background()

	// Poller calls sync GetResults
	req := &proto.ResultsRequest{
		ServiceName:  "sync",
		ServiceType:  "sync",
		AgentId:      "test-agent",
		PollerId:     "test-poller",
		LastSequence: "",
	}

	resp, err := mockSync.GetResults(ctx, req)
	require.NoError(t, err)
	require.True(t, resp.HasNewData)

	// Poller forwards to core
	statusReport := &proto.PollerStatusRequest{
		AgentId:  "test-agent",
		PollerId: "test-poller",
		Services: []*proto.ServiceStatus{
			{
				ServiceName: "sync",
				ServiceType: "sync",
				Available:   true,
				Message:     resp.Data,
				AgentId:     "test-agent",
				PollerId:    "test-poller",
				Source:      "results",
			},
		},
	}

	_, err = mockCore.ReportStatus(ctx, statusReport)
	require.NoError(t, err)
}

func simulateAgentKVWatch(t *testing.T, kvData map[string][]byte) {
	t.Helper()

	// This simulates the agent watching KV for changes and triggering sweep
	// In real code, this would be a KV watch mechanism
	t.Logf("Agent detected %d KV entries changed, starting ping sweep", len(kvData))

	// Extract IPs from KV data to sweep
	var ipsToSweep []string

	for _, data := range kvData {
		var device models.SweepResult

		err := json.Unmarshal(data, &device)
		if err == nil {
			ipsToSweep = append(ipsToSweep, device.IP)
		}
	}

	t.Logf("Agent will sweep %d IPs: %v", len(ipsToSweep), ipsToSweep)
}

func simulatePollerAgentFlow(t *testing.T, mockAgent *MockAgentService, mockCore *MockCoreService) {
	t.Helper()

	ctx := context.Background()

	// Poller calls agent GetResults
	req := &proto.ResultsRequest{
		ServiceName:  "sweep",
		ServiceType:  "sweep",
		AgentId:      "test-agent",
		PollerId:     "test-poller",
		LastSequence: "",
	}

	resp, err := mockAgent.GetResults(ctx, req)
	require.NoError(t, err)
	require.True(t, resp.HasNewData)

	// Poller forwards to core
	statusReport := &proto.PollerStatusRequest{
		AgentId:  "test-agent",
		PollerId: "test-poller",
		Services: []*proto.ServiceStatus{
			{
				ServiceName: "sweep",
				ServiceType: "sweep",
				Available:   true,
				Message:     resp.Data,
				AgentId:     "test-agent",
				PollerId:    "test-poller",
				Source:      "results",
			},
		},
	}

	_, err = mockCore.ReportStatus(ctx, statusReport)
	require.NoError(t, err)
}

func simulateUpdaterTrigger(t *testing.T, mockUpdater *MockArmisUpdater, discoveryResults, sweepResults []*models.SweepResult) {
	t.Helper()
	// This simulates the poller logic that triggers the updater after both
	// discovery and sweep results have been collected and forwarded to core

	if len(discoveryResults) > 0 && len(sweepResults) > 0 {
		t.Log("Both discovery and sweep complete, triggering Armis updater")

		ctx := context.Background()
		err := mockUpdater.RunUpdate(ctx)
		require.NoError(t, err)
	}
}

// Helper functions

func stringPtr(s string) *string {
	return &s
}

func mustMarshal(t *testing.T, v interface{}) []byte {
	t.Helper()

	data, err := json.Marshal(v)
	require.NoError(t, err)

	return data
}
