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
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
)

// TestSyncResultsPerformanceOptimization validates the complete flow from sync results
// to device registry processing, ensuring N+1 queries are eliminated.
func TestSyncResultsPerformanceOptimization(t *testing.T) {
	tests := []struct {
		name                    string
		sightingCount           int
		existingDeviceCount     int
		expectBatchOptimization bool
		description             string
	}{
		{
			name:                    "Large sync batch triggers optimization",
			sightingCount:           15, // Minimal for test performance
			existingDeviceCount:     5,
			expectBatchOptimization: true,
			description:             "Large batches should use batch optimization to avoid N+1 queries",
		},
		{
			name:                    "Small sync batch uses individual queries",
			sightingCount:           3,
			existingDeviceCount:     2,
			expectBatchOptimization: false,
			description:             "Small batches can use individual queries without performance impact",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			// Setup mocks
			mockDB := db.NewMockService(ctrl)
			realRegistry := registry.NewDeviceRegistry(mockDB)

			// Create discovery service
			discoveryService := NewDiscoveryService(mockDB, realRegistry)

			// Create test sync results (simulating Armis data)
			sightings := createSyncSightings(tt.sightingCount)
			sightingsJSON, err := json.Marshal(sightings)
			require.NoError(t, err)

			// Setup expectations based on optimization
			if tt.expectBatchOptimization {
				// Large batch: should use batch optimization with 2 DB calls
				mockDB.EXPECT().
					ListUnifiedDevices(gomock.Any(), 0, 0).
					Return(createExistingDevices(tt.existingDeviceCount), nil).
					Times(1) // KEY: Only 1 database call for large batch

				mockDB.EXPECT().
					PublishBatchSweepResults(gomock.Any(), gomock.Any()).
					Return(nil).
					Times(1)
			} else {
				// Small batch: uses individual queries for each sighting
				for i := 0; i < tt.sightingCount; i++ {
					mockDB.EXPECT().
						GetUnifiedDevicesByIP(gomock.Any(), gomock.Any()).
						Return([]*models.UnifiedDevice{}, nil).
						Times(1)
				}

				mockDB.EXPECT().
					PublishBatchSweepResults(gomock.Any(), gomock.Any()).
					Return(nil).
					Times(1)
			}

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

			if tt.expectBatchOptimization {
				// Large batches should be fast due to optimization
				assert.Less(t, duration, 200*time.Millisecond, "Large batch should be fast with optimization")
			}
		})
	}
}

// TestRepeatedSyncCallsPerformance simulates the issue where sync calls
// happen every 30 seconds with the same data
func TestRepeatedSyncCallsPerformance(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	realRegistry := registry.NewDeviceRegistry(mockDB)
	discoveryService := NewDiscoveryService(mockDB, realRegistry)

	// Create consistent sync data (same as what would come every 30 seconds)
	sightings := createSyncSightings(15) // Reduced for test performance
	sightingsJSON, _ := json.Marshal(sightings)

	serviceStatus := &proto.ServiceStatus{
		ServiceName: "armis-sync",
		ServiceType: "sync-discovery-results",
	}

	ctx := context.Background()

	// First call: should process all sightings (new data)
	mockDB.EXPECT().
		ListUnifiedDevices(gomock.Any(), 0, 0).
		Return(createExistingDevices(5), nil).
		Times(1)

	mockDB.EXPECT().
		PublishBatchSweepResults(gomock.Any(), gomock.Any()).
		Return(nil).
		Times(1)


	// Execute first call
	start := time.Now()
	err := discoveryService.ProcessSyncResults(ctx, "test-poller", "test", serviceStatus, sightingsJSON, time.Now())
	firstCallDuration := time.Since(start)

	require.NoError(t, err)
	t.Logf("First sync call took: %v", firstCallDuration)

	// Subsequent calls: should still process but with optimizations
	// In a real scenario with Armis change detection, these would return empty results
	mockDB.EXPECT().
		ListUnifiedDevices(gomock.Any(), 0, 0).
		Return(createExistingDevices(5), nil).
		Times(5) // 5 subsequent calls

	mockDB.EXPECT().
		PublishBatchSweepResults(gomock.Any(), gomock.Any()).
		Return(nil).
		Times(5) // 5 subsequent calls

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

// TestDatabaseCallCounting verifies that the N+1 problem is actually solved
func TestDatabaseCallCounting(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	realRegistry := registry.NewDeviceRegistry(mockDB)
	discoveryService := NewDiscoveryService(mockDB, realRegistry)

	sightings := createSyncSightings(15) // Large enough to trigger batch optimization
	sightingsJSON, _ := json.Marshal(sightings)

	serviceStatus := &proto.ServiceStatus{
		ServiceName: "armis-sync",
		ServiceType: "sync-discovery-results",
	}

	ctx := context.Background()

	// Track database calls
	var dbCallCount int

	// This should make exactly 1 call to ListUnifiedDevices for batch optimization
	// NOT 1000 individual calls to GetUnifiedDevicesByIP
	mockDB.EXPECT().
		ListUnifiedDevices(gomock.Any(), 0, 0).
		DoAndReturn(func(_ context.Context, _, _ int) ([]*models.UnifiedDevice, error) {
			dbCallCount++
			return createExistingDevices(5), nil
		}).
		Times(1)

	mockDB.EXPECT().
		PublishBatchSweepResults(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, _ []*models.SweepResult) error {
			dbCallCount++
			return nil
		}).
		Times(1)

	// Execute
	err := discoveryService.ProcessSyncResults(ctx, "test-poller", "test", serviceStatus, sightingsJSON, time.Now())
	require.NoError(t, err)

	// Verify database call count
	assert.Equal(t, 2, dbCallCount, "Should make exactly 2 DB calls: 1 for batch query + 1 for publish (not 15+ individual queries)")
	t.Logf("Total database calls: %d (should be 2, not 15+)", dbCallCount)
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

func createExistingDevices(count int) []*models.UnifiedDevice {
	devices := make([]*models.UnifiedDevice, count)
	for i := 0; i < count; i++ {
		devices[i] = &models.UnifiedDevice{
			DeviceID:    fmt.Sprintf("test:10.0.%d.%d", (i/254)+1, (i%254)+1),
			IP:          fmt.Sprintf("10.0.%d.%d", (i/254)+1, (i%254)+1),
			IsAvailable: true,
			Hostname:    &models.DiscoveredField[string]{Value: fmt.Sprintf("existing-device-%d", i+1)},
			MAC:         &models.DiscoveredField[string]{Value: fmt.Sprintf("bb:cc:dd:ee:%02x:%02x", i/256, i%256)},
			DiscoverySources: []models.DiscoverySourceInfo{
				{
					Source:     models.DiscoverySourceArmis,
					Confidence: 7,
				},
			},
		}
	}

	return devices
}

func stringPtr(s string) *string {
	return &s
}
