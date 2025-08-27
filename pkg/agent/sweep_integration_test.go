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

package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// Integration test that demonstrates the complete sequencing flow
func TestSweepSequencing_EndToEndIntegration(t *testing.T) {
	// Setup: Create a mock sweeper that simulates real sweep data changes
	initialSweepTime := time.Now().Unix()

	mockSweeperInstance := &mockSweeper{
		summary: &models.SweepSummary{
			TotalHosts:     100,
			AvailableHosts: 85,
			LastSweep:      initialSweepTime,
			Hosts: []models.HostResult{
				{Host: "192.168.1.1", Available: true},
				{Host: "192.168.1.2", Available: true},
				{Host: "192.168.1.3", Available: false},
			},
			Ports: []models.PortCount{
				{Port: 80, Available: 50},
				{Port: 443, Available: 35},
			},
		},
	}

	// Create sweep service
	sweepService := &SweepService{
		sweeper:            mockSweeperInstance,
		config:             &models.Config{Networks: []string{"192.168.1.0/24"}},
		stats:              newScanStats(),
		logger:             createTestLogger(),
		cachedResults:      nil,
		lastSweepTimestamp: 0,
		currentSequence:    0,
	}

	// Create server with sweep service
	server := &Server{
		config:   &ServerConfig{AgentID: "integration-test-agent"},
		services: []Service{sweepService},
		logger:   createTestLogger(),
	}

	ctx := context.Background()

	// === PHASE 1: Initial poll (should get new data) ===
	t.Log("Phase 1: Initial poll - expecting new data")

	req1 := &proto.ResultsRequest{
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		AgentId:      "integration-test-agent",
		PollerId:     "test-poller",
		LastSequence: "", // Initial call
	}

	response1, err := server.GetResults(ctx, req1)
	require.NoError(t, err)
	require.NotNil(t, response1)

	// Verify initial response
	assert.True(t, response1.HasNewData, "Initial call should have new data")
	assert.Equal(t, "1", response1.CurrentSequence, "Initial sequence should be 1")
	assert.True(t, response1.Available)
	assert.NotEmpty(t, response1.Data)

	// Verify the data structure
	var initialData models.SweepSummary

	err = json.Unmarshal(response1.Data, &initialData)
	require.NoError(t, err)
	assert.Equal(t, 100, initialData.TotalHosts)
	assert.Equal(t, 85, initialData.AvailableHosts)
	assert.Len(t, initialData.Hosts, 3)

	// === PHASE 2: Immediate second poll (should get no new data) ===
	t.Log("Phase 2: Immediate second poll - expecting no new data")

	req2 := &proto.ResultsRequest{
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		AgentId:      "integration-test-agent",
		PollerId:     "test-poller",
		LastSequence: "1", // Same as returned sequence
	}

	response2, err := server.GetResults(ctx, req2)
	require.NoError(t, err)
	require.NotNil(t, response2)

	// Should indicate no new data
	assert.False(t, response2.HasNewData, "Second call should have no new data")
	assert.Equal(t, "1", response2.CurrentSequence, "Sequence should remain 1")
	assert.Empty(t, response2.Data, "No data should be returned when HasNewData is false")

	// === PHASE 3: Simulate sweep data change ===
	t.Log("Phase 3: Simulating sweep data change")

	// Update the mock sweeper with new data (simulating a completed sweep cycle)
	// Make sure we have a different timestamp to trigger change detection
	newSweepTime := initialSweepTime + 3600 // 1 hour later
	updatedSummary := &models.SweepSummary{
		TotalHosts:     120,          // Changed: more hosts discovered
		AvailableHosts: 95,           // Changed: more hosts available
		LastSweep:      newSweepTime, // Changed: new sweep timestamp
		Hosts: []models.HostResult{
			{Host: "192.168.1.1", Available: true},
			{Host: "192.168.1.2", Available: true},
			{Host: "192.168.1.3", Available: true}, // Changed: now available
			{Host: "192.168.1.4", Available: true}, // New: additional host discovered
		},
		Ports: []models.PortCount{
			{Port: 80, Available: 60},  // Changed: more port 80 services
			{Port: 443, Available: 35}, // Unchanged
			{Port: 22, Available: 15},  // New: SSH services discovered
		},
	}
	mockSweeperInstance.updateSummary(updatedSummary)

	// === PHASE 4: Poll after data change (should get new data) ===
	t.Log("Phase 4: Poll after data change - expecting new data")

	req3 := &proto.ResultsRequest{
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		AgentId:      "integration-test-agent",
		PollerId:     "test-poller",
		LastSequence: "1", // Previous sequence
	}

	response3, err := server.GetResults(ctx, req3)
	require.NoError(t, err)
	require.NotNil(t, response3)

	// Should detect change and return new data
	assert.True(t, response3.HasNewData, "Third call should detect changes and have new data")
	assert.Equal(t, "2", response3.CurrentSequence, "Sequence should increment to 2")
	assert.True(t, response3.Available)
	assert.NotEmpty(t, response3.Data)

	// Verify the updated data
	var updatedData models.SweepSummary

	err = json.Unmarshal(response3.Data, &updatedData)
	require.NoError(t, err)
	assert.Equal(t, 120, updatedData.TotalHosts, "Should reflect updated host count")
	assert.Equal(t, 95, updatedData.AvailableHosts, "Should reflect updated available count")
	assert.Len(t, updatedData.Hosts, 4, "Should include new host")
	assert.Len(t, updatedData.Ports, 3, "Should include new port service")

	// Verify specific changes
	assert.True(t, updatedData.Hosts[2].Available, "Previously unavailable host should now be available")
	assert.Equal(t, "192.168.1.4", updatedData.Hosts[3].Host, "Should include newly discovered host")

	// === PHASE 5: Another immediate poll (should get no new data again) ===
	t.Log("Phase 5: Poll with current sequence - expecting no new data")

	req4 := &proto.ResultsRequest{
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		AgentId:      "integration-test-agent",
		PollerId:     "test-poller",
		LastSequence: "2", // Current sequence
	}

	response4, err := server.GetResults(ctx, req4)
	require.NoError(t, err)
	require.NotNil(t, response4)

	// Should again indicate no new data
	assert.False(t, response4.HasNewData, "Fourth call should have no new data")
	assert.Equal(t, "2", response4.CurrentSequence, "Sequence should remain 2")
	assert.Empty(t, response4.Data, "No data should be returned when HasNewData is false")

	t.Log("Integration test completed successfully - sequencing behavior validated")
}

// This test demonstrates the performance benefit of the sequencing approach
// by simulating a high-frequency polling scenario
func TestSweepSequencing_PerformanceReduction(t *testing.T) {
	mockSweeperInstance := &mockSweeper{
		summary: &models.SweepSummary{
			TotalHosts:     6000, // Production-scale host count
			AvailableHosts: 5850,
			LastSweep:      time.Now().Unix(),
			Hosts:          generateTestHosts(100), // Representative sample
			Ports: []models.PortCount{
				{Port: 80, Available: 1200},
				{Port: 443, Available: 800},
				{Port: 22, Available: 600},
			},
		},
	}

	sweepService := &SweepService{
		sweeper:            mockSweeperInstance,
		config:             &models.Config{Networks: []string{"10.0.0.0/8"}},
		stats:              newScanStats(),
		logger:             createTestLogger(),
		cachedResults:      nil,
		lastSweepTimestamp: 0,
		currentSequence:    0,
	}

	server := &Server{
		config:   &ServerConfig{AgentID: "perf-test-agent"},
		services: []Service{sweepService},
		logger:   createTestLogger(), // Reduce log noise
	}

	ctx := context.Background()

	var dataTransferredCount int

	var dataSkippedCount int

	// Simulate 20 polling cycles (e.g., every 30 seconds for 10 minutes)
	for i := 0; i < 20; i++ {
		req := &proto.ResultsRequest{
			ServiceName:  "network_sweep",
			ServiceType:  "sweep",
			AgentId:      "perf-test-agent",
			PollerId:     "test-poller",
			LastSequence: "1", // Keep same sequence to simulate no changes
		}

		// Only the first call should return data
		if i == 0 {
			req.LastSequence = "" // Initial call
		}

		response, err := server.GetResults(ctx, req)
		require.NoError(t, err)
		require.NotNil(t, response)

		if response.HasNewData {
			dataTransferredCount++

			t.Logf("Poll %d: Data transferred (sequence: %s, data size: %d bytes)",
				i+1, response.CurrentSequence, len(response.Data))
		} else {
			dataSkippedCount++

			t.Logf("Poll %d: Data skipped (sequence: %s)", i+1, response.CurrentSequence)
		}
	}

	// Verify performance improvement
	assert.Equal(t, 1, dataTransferredCount, "Only first poll should transfer data")
	assert.Equal(t, 19, dataSkippedCount, "Remaining 19 polls should skip data transfer")

	reductionPercentage := float64(dataSkippedCount) / float64(dataTransferredCount+dataSkippedCount) * 100
	t.Logf("Data transfer reduction: %.1f%% (%d transfers avoided out of %d polls)",
		reductionPercentage, dataSkippedCount, dataTransferredCount+dataSkippedCount)

	assert.InDelta(t, 95.0, reductionPercentage, 0.1, "Should achieve 95% reduction in data transfers")
}

// Helper function to generate test hosts
func generateTestHosts(count int) []models.HostResult {
	hosts := make([]models.HostResult, count)
	for i := 0; i < count; i++ {
		hosts[i] = models.HostResult{
			Host:      fmt.Sprintf("10.0.%d.%d", i/256, i%256),
			Available: i%10 != 0, // 90% availability rate
			FirstSeen: time.Now().Add(-24 * time.Hour),
			LastSeen:  time.Now(),
		}

		// Add some port results for available hosts
		if hosts[i].Available {
			hosts[i].PortResults = []*models.PortResult{
				{Port: 80, Available: true, RespTime: time.Millisecond * 10},
				{Port: 443, Available: i%3 == 0, RespTime: time.Millisecond * 15},
			}
		}
	}

	return hosts
}
