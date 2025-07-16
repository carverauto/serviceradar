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
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Note: mockSweeper is defined in server_test.go to avoid duplication

func TestSweepService_GetSweepResults_InitialCall(t *testing.T) {
	// Setup mock sweeper with initial data
	mockSweeperInstance := &mockSweeper{
		summary: &models.SweepSummary{
			TotalHosts:     10,
			AvailableHosts: 8,
			LastSweep:      time.Now().Unix(),
			Hosts: []models.HostResult{
				{Host: "192.168.1.1", Available: true},
				{Host: "192.168.1.2", Available: true},
			},
			Ports: []models.PortCount{
				{Port: 80, Available: 5},
				{Port: 443, Available: 3},
			},
		},
	}

	sweepService := &SweepService{
		sweeper:            mockSweeperInstance,
		config:             &models.Config{},
		stats:              newScanStats(),
		cachedResults:      nil,
		lastSweepTimestamp: 0,
		currentSequence:    0,
	}

	ctx := context.Background()

	// Test initial call with empty sequence
	response, err := sweepService.GetSweepResults(ctx, "")
	require.NoError(t, err)
	require.NotNil(t, response)

	// Should return new data on first call
	assert.True(t, response.HasNewData)
	assert.Equal(t, "1", response.CurrentSequence)
	assert.Equal(t, "network_sweep", response.ServiceName)
	assert.Equal(t, "sweep", response.ServiceType)
	assert.True(t, response.Available)

	// Verify data is correctly marshaled
	var unmarshaledData models.SweepSummary
	err = json.Unmarshal(response.Data, &unmarshaledData)
	require.NoError(t, err)
	assert.Equal(t, 10, unmarshaledData.TotalHosts)
	assert.Equal(t, 8, unmarshaledData.AvailableHosts)
	assert.Len(t, unmarshaledData.Hosts, 2)
}

func TestSweepService_GetSweepResults_NoNewData(t *testing.T) {
	// Setup mock sweeper
	sweepTimestamp := time.Now().Unix()
	mockSweeperInstance := &mockSweeper{
		summary: &models.SweepSummary{
			TotalHosts:     5,
			AvailableHosts: 4,
			LastSweep:      sweepTimestamp,
			Hosts: []models.HostResult{
				{Host: "192.168.1.1", Available: true},
			},
		},
	}

	sweepService := &SweepService{
		sweeper:            mockSweeperInstance,
		config:             &models.Config{},
		stats:              newScanStats(),
		cachedResults:      mockSweeperInstance.summary,
		lastSweepTimestamp: sweepTimestamp,
		currentSequence:    1,
	}

	ctx := context.Background()

	// Test call with current sequence - should return no new data
	response, err := sweepService.GetSweepResults(ctx, "1")
	require.NoError(t, err)
	require.NotNil(t, response)

	// Should not return new data
	assert.False(t, response.HasNewData)
	assert.Equal(t, "1", response.CurrentSequence)
	assert.Equal(t, "network_sweep", response.ServiceName)
	assert.Equal(t, "sweep", response.ServiceType)
	assert.Empty(t, response.Data) // No data when HasNewData is false
}

func TestSweepService_GetSweepResults_NewDataAvailable(t *testing.T) {
	// Setup mock sweeper with initial data
	initialTimestamp := time.Now().Add(-1 * time.Hour).Unix()
	newTimestamp := time.Now().Unix()

	mockSweeperInstance := &mockSweeper{
		summary: &models.SweepSummary{
			TotalHosts:     15,           // Changed from 10
			AvailableHosts: 12,           // Changed from 8
			LastSweep:      newTimestamp, // New timestamp
			Hosts: []models.HostResult{
				{Host: "192.168.1.1", Available: true},
				{Host: "192.168.1.2", Available: true},
				{Host: "192.168.1.3", Available: true}, // New host
			},
		},
	}

	sweepService := &SweepService{
		sweeper: mockSweeperInstance,
		config:  &models.Config{},
		stats:   newScanStats(),
		cachedResults: &models.SweepSummary{
			TotalHosts:     10,
			AvailableHosts: 8,
			LastSweep:      initialTimestamp,
			Hosts: []models.HostResult{
				{Host: "192.168.1.1", Available: true},
				{Host: "192.168.1.2", Available: true},
			},
		},
		lastSweepTimestamp: initialTimestamp,
		currentSequence:    1,
	}

	ctx := context.Background()

	// Test call with old sequence - should detect change and return new data
	response, err := sweepService.GetSweepResults(ctx, "1")
	require.NoError(t, err)
	require.NotNil(t, response)

	// Should return new data with incremented sequence
	assert.True(t, response.HasNewData)
	assert.Equal(t, "2", response.CurrentSequence)
	assert.Equal(t, "network_sweep", response.ServiceName)
	assert.Equal(t, "sweep", response.ServiceType)
	assert.True(t, response.Available)

	// Verify updated data
	var unmarshaledData models.SweepSummary
	err = json.Unmarshal(response.Data, &unmarshaledData)
	require.NoError(t, err)
	assert.Equal(t, 15, unmarshaledData.TotalHosts)
	assert.Equal(t, 12, unmarshaledData.AvailableHosts)
	assert.Len(t, unmarshaledData.Hosts, 3) // Should have 3 hosts now
}

func TestSweepService_GetSweepResults_SequenceIncrementsCorrectly(t *testing.T) {
	// Setup mock sweeper
	baseTimestamp := time.Now().Unix()
	mockSweeperInstance := &mockSweeper{
		summary: &models.SweepSummary{
			TotalHosts:     5,
			AvailableHosts: 4,
			LastSweep:      baseTimestamp,
			Hosts:          []models.HostResult{{Host: "192.168.1.1", Available: true}},
		},
	}

	sweepService := &SweepService{
		sweeper:            mockSweeperInstance,
		config:             &models.Config{},
		stats:              newScanStats(),
		cachedResults:      nil,
		lastSweepTimestamp: 0,
		currentSequence:    0,
	}

	ctx := context.Background()

	// First call - should return sequence 1
	response1, err := sweepService.GetSweepResults(ctx, "")
	require.NoError(t, err)
	assert.True(t, response1.HasNewData)
	assert.Equal(t, "1", response1.CurrentSequence)

	// Second call with same data - should return no new data
	response2, err := sweepService.GetSweepResults(ctx, "1")
	require.NoError(t, err)
	assert.False(t, response2.HasNewData)
	assert.Equal(t, "1", response2.CurrentSequence)

	// Update sweep data
	mockSweeperInstance.updateSummary(&models.SweepSummary{
		TotalHosts:     6,                  // Changed
		AvailableHosts: 5,                  // Changed
		LastSweep:      baseTimestamp + 60, // New timestamp
		Hosts:          []models.HostResult{{Host: "192.168.1.1", Available: true}},
	})

	// Third call with updated data - should return sequence 2
	response3, err := sweepService.GetSweepResults(ctx, "1")
	require.NoError(t, err)
	assert.True(t, response3.HasNewData)
	assert.Equal(t, "2", response3.CurrentSequence)
}

func TestSweepService_GetStatus_LightweightResponse(t *testing.T) {
	// Setup mock sweeper
	mockSweeperInstance := &mockSweeper{
		summary: &models.SweepSummary{
			TotalHosts:     10,
			AvailableHosts: 8,
			LastSweep:      time.Now().Unix(),
			Hosts: []models.HostResult{
				{Host: "192.168.1.1", Available: true},
				{Host: "192.168.1.2", Available: true},
			},
			Ports: []models.PortCount{
				{Port: 80, Available: 5},
			},
		},
	}

	sweepService := &SweepService{
		sweeper: mockSweeperInstance,
		config: &models.Config{
			Networks: []string{"192.168.1.0/24"},
		},
		stats:           newScanStats(),
		currentSequence: 5,
	}

	ctx := context.Background()

	// Test GetStatus returns lightweight response
	response, err := sweepService.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, response)

	assert.True(t, response.Available)
	assert.Equal(t, "network_sweep", response.ServiceName)
	assert.Equal(t, "sweep", response.ServiceType)

	// Parse the status message
	var statusData map[string]interface{}
	err = json.Unmarshal(response.Message, &statusData)
	require.NoError(t, err)

	// Verify lightweight response (no hosts array)
	assert.InDelta(t, float64(10), statusData["total_hosts"], 0.1)
	assert.InDelta(t, float64(8), statusData["available_hosts"], 0.1)
	assert.InDelta(t, float64(5), statusData["sequence"], 0.1)
	assert.Equal(t, "192.168.1.0/24", statusData["network"])

	// Most importantly: verify hosts array is NOT included in GetStatus
	_, hasHosts := statusData["hosts"]
	assert.False(t, hasHosts, "GetStatus should not include hosts array for lightweight response")

	// But ports should still be included for summary statistics
	ports, hasPorts := statusData["ports"]
	assert.True(t, hasPorts)
	assert.NotEmpty(t, ports)
}
