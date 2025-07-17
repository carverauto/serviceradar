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

	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

// TestSimplifiedRegistryBehavior verifies the simplified registry implementation
// that directly publishes results without complex optimization logic
func TestSimplifiedRegistryBehavior(t *testing.T) {
	tests := []struct {
		name          string
		sightingCount int
		description   string
	}{
		{
			name:          "Small batch processing",
			sightingCount: 5,
			description:   "Small batches should process efficiently",
		},
		{
			name:          "Large batch processing",
			sightingCount: 100,
			description:   "Large batches should process efficiently",
		},
		{
			name:          "Single sighting processing",
			sightingCount: 1,
			description:   "Single sightings should process efficiently",
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

			// The simplified registry only calls PublishBatchSweepResults
			// No batch optimization queries are performed
			mockDB.EXPECT().
				PublishBatchSweepResults(ctx, gomock.Len(tt.sightingCount)).
				Return(nil).
				Times(1)

			// Execute
			start := time.Now()
			err := registry.ProcessBatchSweepResults(ctx, sightings)
			duration := time.Since(start)

			// Verify
			require.NoError(t, err)
			t.Logf("%s: Processed %d sightings in %v", tt.description, tt.sightingCount, duration)
		})
	}
}

// TestEmptyBatchHandling verifies that empty batches are handled correctly
func TestEmptyBatchHandling(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	ctx := context.Background()

	// Empty batch should not call any database methods
	// No expectations set means no calls should be made

	// Execute with empty slice
	err := registry.ProcessBatchSweepResults(ctx, []*models.SweepResult{})

	// Verify
	require.NoError(t, err)
}

// TestNormalizationBehavior verifies that basic normalization still occurs
func TestNormalizationBehavior(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	// Create a sighting with missing partition
	sighting := &models.SweepResult{
		IP:              "192.168.1.100",
		DeviceID:        "", // Empty device ID
		Partition:       "", // Empty partition
		DiscoverySource: "armis",
		Available:       true,
		Timestamp:       time.Now(),
	}

	ctx := context.Background()

	// Verify normalization occurs by checking the published results
	mockDB.EXPECT().
		PublishBatchSweepResults(ctx, gomock.Any()).
		DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
			require.Len(t, results, 1)
			result := results[0]

			// Verify normalization occurred
			require.Equal(t, "default:192.168.1.100", result.DeviceID)
			require.Equal(t, "default", result.Partition)

			return nil
		}).
		Times(1)

	// Execute
	err := registry.ProcessBatchSweepResults(ctx, []*models.SweepResult{sighting})

	// Verify
	require.NoError(t, err)
}

// Helper functions

func createTestSightings(count int) []*models.SweepResult {
	sightings := make([]*models.SweepResult, count)

	for i := 0; i < count; i++ {
		hostname := fmt.Sprintf("device-%d", i+1)
		sightings[i] = &models.SweepResult{
			IP:              fmt.Sprintf("192.168.1.%d", i+1),
			DeviceID:        fmt.Sprintf("default:192.168.1.%d", i+1),
			Partition:       "default",
			DiscoverySource: "armis",
			Available:       true,
			Hostname:        &hostname,
			Timestamp:       time.Now(),
		}
	}

	return sightings
}
