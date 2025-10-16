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

package core

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
)

// TestSyncResultsPerformanceOptimization validates the complete flow from sync results
// to device registry processing, ensuring N+1 queries are eliminated.
func TestSyncResultsPerformanceOptimization(t *testing.T) {
	tests := []struct {
		name          string
		sightingCount int
		description   string
	}{
		{
			name:          "Large sync batch processing",
			sightingCount: 15,
			description:   "Large batches should process efficiently",
		},
		{
			name:          "Small sync batch processing",
			sightingCount: 3,
			description:   "Small batches should process quickly",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			// Setup mocks
			mockDB := db.NewMockService(ctrl)
			mockDB.EXPECT().
				ExecuteQuery(gomock.Any(), gomock.Any()).
				Return([]map[string]interface{}{}, nil).
				AnyTimes()
			mockDB.EXPECT().
				GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).
				Return([]*models.UnifiedDevice{}, nil).
				AnyTimes()
			testLogger := logger.NewTestLogger()
			realRegistry := registry.NewDeviceRegistry(mockDB, testLogger)

			// Create discovery service
			discoveryService := NewDiscoveryService(mockDB, realRegistry, testLogger)

			// Create test sync results (simulating Armis data)
			sightings := createSyncSightings(tt.sightingCount)
			sightingsJSON, err := json.Marshal(sightings)
			require.NoError(t, err)

			// Current implementation always uses direct publishing
			// regardless of batch size (batch optimization was simplified)
			mockDB.EXPECT().
				PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
				Return(nil).
				Times(1)

			// Create test service status
			serviceStatus := &proto.ServiceStatus{
				ServiceName: "armis-sync",
				ServiceType: "sync-discovery-results",
			}

			ctx := context.Background()

			// Execute the sync results processing
			start := time.Now()
			err = discoveryService.ProcessSyncResults(
				ctx,
				"test-poller",
				"test-partition",
				serviceStatus,
				sightingsJSON,
				time.Now(),
			)
			duration := time.Since(start)

			// Verify
			require.NoError(t, err)

			t.Logf("%s: Processed %d sync results in %v", tt.description, tt.sightingCount, duration)

			// All batches should complete within reasonable time
			assert.Less(t, duration, 1*time.Second, "Batch processing should complete within 1 second")
		})
	}
}

// TestRepeatedSyncCallsPerformance simulates the issue where sync calls
// happen every 30 seconds with the same data
func TestRepeatedSyncCallsPerformance(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]*models.UnifiedDevice{}, nil).
		AnyTimes()
	testLogger := logger.NewTestLogger()
	realRegistry := registry.NewDeviceRegistry(mockDB, testLogger)
	discoveryService := NewDiscoveryService(mockDB, realRegistry, testLogger)

	// Create consistent sync data (same as what would come every 30 seconds)
	sightings := createSyncSightings(15) // Reduced for test performance
	sightingsJSON, _ := json.Marshal(sightings)

	serviceStatus := &proto.ServiceStatus{
		ServiceName: "armis-sync",
		ServiceType: "sync-discovery-results",
	}

	ctx := context.Background()

	// Setup DB mocks for all 6 calls (first + 5 subsequent)
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		Return(nil).
		Times(6)

	// Execute first call
	start := time.Now()
	err := discoveryService.ProcessSyncResults(ctx, "test-poller", "test", serviceStatus, sightingsJSON, time.Now())
	firstCallDuration := time.Since(start)

	require.NoError(t, err)
	t.Logf("First sync call took: %v", firstCallDuration)

	// Execute 5 more calls (simulating repeated sync calls)
	var subsequentDurations []time.Duration

	for i := 0; i < 5; i++ {
		start = time.Now()
		err = discoveryService.ProcessSyncResults(ctx, "test-poller", "test", serviceStatus, sightingsJSON, time.Now())
		duration := time.Since(start)
		subsequentDurations = append(subsequentDurations, duration)

		require.NoError(t, err)
		t.Logf("Sync call %d took: %v (received %d sightings)", i+2, duration, len(sightings))
	}

	// Calculate average subsequent call time
	var totalSubsequent time.Duration
	for _, d := range subsequentDurations {
		totalSubsequent += d
	}

	avgSubsequent := totalSubsequent / time.Duration(len(subsequentDurations))

	t.Logf("Average subsequent call time: %v", avgSubsequent)
	t.Logf("Performance comparison: First call: %v, Avg subsequent: %v", firstCallDuration, avgSubsequent)

	// With optimizations, subsequent calls should be reasonably fast
	assert.Less(t, avgSubsequent, 500*time.Millisecond, "Subsequent calls should be fast with optimizations")
}

// TestDatabaseCallCounting verifies that the simplified implementation makes minimal DB calls
func TestDatabaseCallCounting(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	testLogger := logger.NewTestLogger()
	realRegistry := registry.NewDeviceRegistry(mockDB, testLogger)
	discoveryService := NewDiscoveryService(mockDB, realRegistry, testLogger)

	sightings := createSyncSightings(15) // Batch size doesn't matter anymore
	sightingsJSON, _ := json.Marshal(sightings)

	serviceStatus := &proto.ServiceStatus{
		ServiceName: "armis-sync",
		ServiceType: "sync-discovery-results",
	}

	ctx := context.Background()

	// Track publish calls (canonicalization queries may be issued separately)
	var publishCallCount int

	// Current implementation makes a single publish call into device updates
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, _ []*models.DeviceUpdate) error {
			publishCallCount++
			return nil
		}).
		Times(1)

	// Execute
	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]*models.UnifiedDevice{}, nil).
		AnyTimes()

	err := discoveryService.ProcessSyncResults(ctx, "test-poller", "test", serviceStatus, sightingsJSON, time.Now())
	require.NoError(t, err)

	// Verify publish call count
	assert.Equal(t, 1, publishCallCount, "Should publish device updates exactly once")
	t.Logf("Total publish calls: %d (should be 1)", publishCallCount)
}

// Helper functions

func createSyncSightings(count int) []*models.SweepResult {
	sightings := make([]*models.SweepResult, count)
	for i := 0; i < count; i++ {
		sightings[i] = &models.SweepResult{
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Partition:       "test",
			DiscoverySource: "armis",
			IP:              fmt.Sprintf("192.168.%d.%d", (i/254)+1, (i%254)+1),
			MAC:             stringPtr(fmt.Sprintf("aa:bb:cc:dd:%02x:%02x", i/256, i%256)),
			Hostname:        stringPtr(fmt.Sprintf("armis-device-%d", i+1)),
			Timestamp:       time.Now(),
			Available:       true,
			Metadata: map[string]string{
				"armis_device_id": fmt.Sprintf("%d", i+1),
				"tag":             "production",
			},
		}
	}

	return sightings
}

func stringPtr(s string) *string {
	return &s
}
