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

package registry

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBatchOptimization(t *testing.T) {
	tests := []struct {
		name           string
		sightingCount  int
		expectBatch    bool
		expectFallback bool
	}{
		{
			name:          "Small batch uses individual queries",
			sightingCount: 5,
			expectBatch:   false,
		},
		{
			name:          "Large batch uses batch optimization",
			sightingCount: 100,
			expectBatch:   true,
		},
		{
			name:           "Batch failure triggers fallback",
			sightingCount:  50,
			expectBatch:    true,
			expectFallback: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := db.NewMockService(ctrl)
			registry := NewDeviceRegistry(mockDB)

			// Create test sightings
			sightings := createTestSightings(tt.sightingCount)

			ctx := context.Background()

			if tt.expectBatch {
				if tt.expectFallback {
					// First call to ListUnifiedDevices fails
					mockDB.EXPECT().
						ListUnifiedDevices(ctx, 0, 0).
						Return(nil, assert.AnError).
						Times(1)

					// Fallback to individual queries for each sighting
					setupIndividualQueryMocks(ctx, mockDB, sightings)
				} else {
					// Successful batch query
					existingDevices := createTestUnifiedDevices(10)
					mockDB.EXPECT().
						ListUnifiedDevices(ctx, 0, 0).
						Return(existingDevices, nil).
						Times(1)
				}
			} else {
				// Small batch - individual queries
				setupIndividualQueryMocks(ctx, mockDB, sightings)
			}

			// Mock the final publish call
			mockDB.EXPECT().
				PublishBatchSweepResults(ctx, gomock.Any()).
				Return(nil).
				Times(1)

			// Execute
			start := time.Now()
			err := registry.ProcessBatchSightings(ctx, sightings)
			duration := time.Since(start)

			// Verify
			require.NoError(t, err)

			if tt.expectBatch && !tt.expectFallback {
				// Batch processing should be significantly faster
				assert.Less(t, duration, 100*time.Millisecond, "Batch processing should be fast")
			}

			t.Logf("Processed %d sightings in %v", tt.sightingCount, duration)
		})
	}
}

func TestBatchOptimizationDatabaseCalls(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	// Create 1000 sightings to trigger batch optimization
	sightings := createTestSightings(1000)
	existingDevices := createTestUnifiedDevices(500)

	ctx := context.Background()

	// Should make exactly 1 call to ListUnifiedDevices (not 1000 individual calls)
	mockDB.EXPECT().
		ListUnifiedDevices(ctx, 0, 0).
		Return(existingDevices, nil).
		Times(1) // This is the key assertion - only 1 database call

	// Mock the final publish call
	mockDB.EXPECT().
		PublishBatchSweepResults(ctx, gomock.Any()).
		Return(nil).
		Times(1)

	// Execute
	err := registry.ProcessBatchSightings(ctx, sightings)

	// Verify
	require.NoError(t, err)
}

func TestBatchQueryUsage(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	// Create enough sightings to trigger batch optimization (>10)
	sightings := createTestSightings(15) // This will trigger batch optimization

	existingDevices := createTestUnifiedDevices(5)

	ctx := context.Background()

	// Should use batch query for device lookup
	mockDB.EXPECT().
		ListUnifiedDevices(ctx, 0, 0).
		Return(existingDevices, nil).
		Times(1)

	// Should publish results
	mockDB.EXPECT().
		PublishBatchSweepResults(ctx, gomock.Len(15)).
		Return(nil).
		Times(1)

	// Execute
	err := registry.ProcessBatchSightings(ctx, sightings)

	// Verify
	require.NoError(t, err)
}

// var testHostname = "test-device" // Unused variable

// Helper functions

func createTestSightings(count int) []*models.SweepResult {
	sightings := make([]*models.SweepResult, count)

	for i := 0; i < count; i++ {
		hostname := fmt.Sprintf("device-%d", i+1)
		sightings[i] = &models.SweepResult{
			IP:              fmt.Sprintf("192.168.1.%d", i+1),
			DeviceID:        fmt.Sprintf("default:192.168.1.%d", i+1),
			Partition:       "default", // Add partition to avoid warnings
			DiscoverySource: "armis",
			Available:       true,
			Hostname:        &hostname,
			Timestamp:       time.Now(),
		}
	}

	return sightings
}

func createTestUnifiedDevices(count int) []*models.UnifiedDevice {
	devices := make([]*models.UnifiedDevice, count)
	for i := 0; i < count; i++ {
		devices[i] = &models.UnifiedDevice{
			DeviceID:    fmt.Sprintf("default:10.0.0.%d", i+1),
			IP:          fmt.Sprintf("10.0.0.%d", i+1),
			IsAvailable: true,
			Hostname:    &models.DiscoveredField[string]{Value: fmt.Sprintf("existing-device-%d", i+1)},
		}
	}

	return devices
}

func setupIndividualQueryMocks(ctx context.Context, mockDB *db.MockService, sightings []*models.SweepResult) {
	for _, sighting := range sightings {
		mockDB.EXPECT().
			GetUnifiedDevicesByIP(ctx, sighting.IP).
			Return([]*models.UnifiedDevice{}, nil).
			Times(1)
	}
}
