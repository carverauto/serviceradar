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
	"strconv"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// testIntegrationLogger creates a no-op logger for tests
func testIntegrationLogger() logger.Logger {
	config := &logger.Config{
		Level:  "disabled",
		Output: "stderr",
	}

	log, err := lifecycle.CreateLogger(context.Background(), config)
	if err != nil {
		panic(err)
	}

	return log
}

func TestSequenceTrackingIntegration_SimulatePollerBehavior(t *testing.T) {
	// Create a sync service with some initial cached results
	service := &PollerService{
		config: Config{
			AgentID: "test-agent",
		},
		resultsCache: map[string]*CachedResults{},
		logger:       testIntegrationLogger(),
	}

	ctx := context.Background()

	// Simulate sequence 1: First sweep populates cache
	t.Run("First Sweep - Populate Cache", func(t *testing.T) {
		// Simulate sweep populating cache with sequence
		now := time.Now()
		sequence := strconv.FormatInt(now.UnixNano(), 10)

		service.resultsCache["netbox"] = &CachedResults{
			Results: []*models.SweepResult{
				{
					IP:              "192.168.1.1",
					DiscoverySource: "netbox",
					Available:       true,
					Timestamp:       now,
				},
				{
					IP:              "192.168.1.2",
					DiscoverySource: "netbox",
					Available:       true,
					Timestamp:       now,
				},
			},
			Sequence:  sequence,
			Timestamp: now,
		}

		// First GetResults call (no last_sequence)
		req := &proto.ResultsRequest{
			ServiceName:  "sync",
			ServiceType:  "grpc",
			AgentId:      "test-agent",
			PollerId:     "test-poller",
			LastSequence: "", // First call
		}

		resp, err := service.GetResults(ctx, req)
		require.NoError(t, err)
		require.NotNil(t, resp)

		// Should return data and sequence
		assert.True(t, resp.HasNewData)
		assert.Equal(t, "netbox:"+sequence, resp.CurrentSequence)
		assert.Contains(t, string(resp.Data), "192.168.1.1")
		assert.Contains(t, string(resp.Data), "192.168.1.2")
	})

	// Simulate sequence 2: Poller calls again with same sequence
	t.Run("Second Call - Same Sequence", func(t *testing.T) {
		// Get current sequence from cache
		cached := service.resultsCache["netbox"]
		require.NotNil(t, cached)

		// Second GetResults call with same sequence
		req := &proto.ResultsRequest{
			ServiceName:  "sync",
			ServiceType:  "grpc",
			AgentId:      "test-agent",
			PollerId:     "test-poller",
			LastSequence: "netbox:" + cached.Sequence, // Same sequence in new format
		}

		resp, err := service.GetResults(ctx, req)
		require.NoError(t, err)
		require.NotNil(t, resp)

		// Should NOT return data (has_new_data = false)
		assert.False(t, resp.HasNewData)
		assert.Equal(t, "netbox:"+cached.Sequence, resp.CurrentSequence)
		assert.Equal(t, "[]", string(resp.Data))
	})

	// Simulate sequence 3: New sweep with different results
	t.Run("Third Call - New Sweep Results", func(t *testing.T) {
		// Simulate new sweep with additional device
		now := time.Now()
		newSequence := strconv.FormatInt(now.UnixNano(), 10)

		service.resultsCache["netbox"] = &CachedResults{
			Results: []*models.SweepResult{
				{
					IP:              "192.168.1.1",
					DiscoverySource: "netbox",
					Available:       true,
					Timestamp:       now,
				},
				{
					IP:              "192.168.1.2",
					DiscoverySource: "netbox",
					Available:       true,
					Timestamp:       now,
				},
				{
					IP:              "192.168.1.3",
					DiscoverySource: "netbox",
					Available:       true,
					Timestamp:       now,
				},
			},
			Sequence:  newSequence,
			Timestamp: now,
		}

		// Get old sequence for comparison
		oldSequence := "1720906448000000000" // Some old sequence

		// Third GetResults call with old sequence
		req := &proto.ResultsRequest{
			ServiceName:  "sync",
			ServiceType:  "grpc",
			AgentId:      "test-agent",
			PollerId:     "test-poller",
			LastSequence: oldSequence, // Old sequence
		}

		resp, err := service.GetResults(ctx, req)
		require.NoError(t, err)
		require.NotNil(t, resp)

		// Should return new data
		assert.True(t, resp.HasNewData)
		assert.Equal(t, "netbox:"+newSequence, resp.CurrentSequence)
		assert.Contains(t, string(resp.Data), "192.168.1.1")
		assert.Contains(t, string(resp.Data), "192.168.1.2")
		assert.Contains(t, string(resp.Data), "192.168.1.3")
	})

	// Simulate sequence 4: Multiple pollers with same sequence
	t.Run("Fourth Call - Different Poller Same Sequence", func(t *testing.T) {
		// Get current sequence from cache
		cached := service.resultsCache["netbox"]
		require.NotNil(t, cached)

		// Call from different poller with same sequence
		req := &proto.ResultsRequest{
			ServiceName:  "sync",
			ServiceType:  "grpc",
			AgentId:      "test-agent",
			PollerId:     "different-poller",          // Different poller
			LastSequence: "netbox:" + cached.Sequence, // Same sequence in new format
		}

		resp, err := service.GetResults(ctx, req)
		require.NoError(t, err)
		require.NotNil(t, resp)

		// Should NOT return data (sequence-based, not poller-based)
		assert.False(t, resp.HasNewData)
		assert.Equal(t, "netbox:"+cached.Sequence, resp.CurrentSequence)
		assert.Equal(t, "[]", string(resp.Data))
	})
}

func TestSequenceTrackingIntegration_MultiSourceBehavior(t *testing.T) {
	// Test behavior with multiple integration sources
	service := &PollerService{
		config: Config{
			AgentID: "test-agent",
		},
		resultsCache: map[string]*CachedResults{},
		logger:       testIntegrationLogger(),
	}

	ctx := context.Background()
	now := time.Now()

	// Populate cache with multiple sources at different times
	service.resultsCache["netbox"] = &CachedResults{
		Results: []*models.SweepResult{
			{IP: "192.168.1.1", DiscoverySource: "netbox", Available: true, Timestamp: now},
		},
		Sequence:  "1720906400000000000", // Older
		Timestamp: now.Add(-10 * time.Minute),
	}

	service.resultsCache["armis"] = &CachedResults{
		Results: []*models.SweepResult{
			{IP: "192.168.1.10", DiscoverySource: "armis", Available: true, Timestamp: now},
		},
		Sequence:  "1720906500000000000", // Newer
		Timestamp: now,
	}

	// GetResults should use the latest sequence across all sources
	req := &proto.ResultsRequest{
		ServiceName:  "sync",
		ServiceType:  "grpc",
		AgentId:      "test-agent",
		PollerId:     "test-poller",
		LastSequence: "1720906400000000000", // Match netbox sequence
	}

	resp, err := service.GetResults(ctx, req)
	require.NoError(t, err)
	require.NotNil(t, resp)

	// Should return data because armis has newer sequence
	assert.True(t, resp.HasNewData)
	assert.Equal(t, "armis:1720906500000000000;netbox:1720906400000000000", resp.CurrentSequence) // Combined sequence

	// Should return data from both sources
	assert.Contains(t, string(resp.Data), "192.168.1.1")  // netbox
	assert.Contains(t, string(resp.Data), "192.168.1.10") // armis
}

func TestSequenceTrackingIntegration_EmptyCacheBehavior(t *testing.T) {
	// Test behavior when cache is empty
	service := &PollerService{
		config: Config{
			AgentID: "test-agent",
		},
		resultsCache: map[string]*CachedResults{}, // Empty cache
		logger:       testIntegrationLogger(),
	}

	ctx := context.Background()

	req := &proto.ResultsRequest{
		ServiceName:  "sync",
		ServiceType:  "grpc",
		AgentId:      "test-agent",
		PollerId:     "test-poller",
		LastSequence: "1720906400000000000", // Some sequence
	}

	resp, err := service.GetResults(ctx, req)
	require.NoError(t, err)
	require.NotNil(t, resp)

	// Should return new data because sequence changed from old to "0"
	assert.True(t, resp.HasNewData)
	assert.Equal(t, "0", resp.CurrentSequence)
	assert.Equal(t, "[]", string(resp.Data))
}
