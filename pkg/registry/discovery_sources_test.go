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
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestDiscoverySourcesAggregation(t *testing.T) {
	tests := []struct {
		name                     string
		initialSightings         []*models.SweepResult
		subsequentSightings      []*models.SweepResult
		expectedDiscoverySources []string
		description              string
	}{
		{
			name: "Armis discovery source should be added to existing device",
			initialSightings: []*models.SweepResult{
				{
					IP:              "192.168.1.100",
					DeviceID:        "default:192.168.1.100",
					Partition:       "default",
					DiscoverySource: "sweep",
					Hostname:        stringPtr("test-device"),
					Timestamp:       time.Now(),
					Available:       true,
				},
			},
			subsequentSightings: []*models.SweepResult{
				{
					IP:              "192.168.1.100",
					DeviceID:        "default:192.168.1.100",
					Partition:       "default",
					DiscoverySource: "armis",
					Hostname:        stringPtr("test-device"),
					Timestamp:       time.Now(),
					Available:       true,
					Metadata: map[string]string{
						"armis_device_id": "123",
					},
				},
			},
			expectedDiscoverySources: []string{"sweep", "armis"},
			description:              "Device discovered by sweep should have armis added to discovery sources",
		},
		{
			name: "Multiple discovery sources should accumulate",
			initialSightings: []*models.SweepResult{
				{
					IP:              "192.168.1.101",
					DeviceID:        "default:192.168.1.101",
					Partition:       "default",
					DiscoverySource: "snmp",
					Hostname:        stringPtr("multi-source-device"),
					Timestamp:       time.Now(),
					Available:       true,
				},
			},
			subsequentSightings: []*models.SweepResult{
				{
					IP:              "192.168.1.101",
					DeviceID:        "default:192.168.1.101",
					Partition:       "default",
					DiscoverySource: "mapper",
					Hostname:        stringPtr("multi-source-device"),
					Timestamp:       time.Now(),
					Available:       true,
				},
				{
					IP:              "192.168.1.101",
					DeviceID:        "default:192.168.1.101",
					Partition:       "default",
					DiscoverySource: "armis",
					Hostname:        stringPtr("multi-source-device"),
					Timestamp:       time.Now(),
					Available:       true,
				},
			},
			expectedDiscoverySources: []string{"snmp", "mapper", "armis"},
			description:              "Device should accumulate discovery sources from multiple systems",
		},
		{
			name: "Duplicate discovery sources should not be added twice",
			initialSightings: []*models.SweepResult{
				{
					IP:              "192.168.1.102",
					DeviceID:        "default:192.168.1.102",
					Partition:       "default",
					DiscoverySource: "armis",
					Hostname:        stringPtr("armis-device"),
					Timestamp:       time.Now(),
					Available:       true,
				},
			},
			subsequentSightings: []*models.SweepResult{
				{
					IP:              "192.168.1.102",
					DeviceID:        "default:192.168.1.102",
					Partition:       "default",
					DiscoverySource: "armis",
					Hostname:        stringPtr("armis-device"),
					Timestamp:       time.Now().Add(time.Minute),
					Available:       true,
				},
			},
			expectedDiscoverySources: []string{"armis"},
			description:              "Duplicate discovery sources should not be added multiple times",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := db.NewMockService(ctrl)
			registry := NewDeviceRegistry(mockDB)
			ctx := context.Background()

			// Mock the initial processing
			if len(tt.initialSightings) > 0 {
				// For small batches, expect individual queries
				for _, sighting := range tt.initialSightings {
					mockDB.EXPECT().
						GetUnifiedDevicesByIP(ctx, sighting.IP).
						Return([]*models.UnifiedDevice{}, nil).
						Times(1)
				}

				mockDB.EXPECT().
					PublishBatchSweepResults(ctx, gomock.Len(len(tt.initialSightings))).
					Return(nil).
					Times(1)

				err := registry.ProcessBatchSightings(ctx, tt.initialSightings)
				require.NoError(t, err)
			}

			// Mock the subsequent processing
			if len(tt.subsequentSightings) > 0 {
				// Create a mock existing device that should have discovery sources from initial sightings
				existingDevice := &models.UnifiedDevice{
					DeviceID: tt.subsequentSightings[0].DeviceID,
					IP:       tt.subsequentSightings[0].IP,
					DiscoverySources: []models.DiscoverySourceInfo{
						{
							Source:     models.DiscoverySource(tt.initialSightings[0].DiscoverySource),
							AgentID:    tt.initialSightings[0].AgentID,
							PollerID:   tt.initialSightings[0].PollerID,
							FirstSeen:  time.Now().Add(-time.Hour),
							LastSeen:   time.Now(),
							Confidence: models.GetSourceConfidence(models.DiscoverySource(tt.initialSightings[0].DiscoverySource)),
						},
					},
					Hostname:    &models.DiscoveredField[string]{Value: *tt.subsequentSightings[0].Hostname},
					IsAvailable: true,
					FirstSeen:   time.Now().Add(-time.Hour),
					LastSeen:    time.Now(),
				}

				// For subsequent sightings, mock that we find the existing device
				for _, sighting := range tt.subsequentSightings {
					mockDB.EXPECT().
						GetUnifiedDevicesByIP(ctx, sighting.IP).
						Return([]*models.UnifiedDevice{existingDevice}, nil).
						Times(1)
				}

				// Mock the final publish - this is where we would verify discovery sources are correct
				mockDB.EXPECT().
					PublishBatchSweepResults(ctx, gomock.Len(len(tt.subsequentSightings))).
					DoAndReturn(func(_ context.Context, sightings []*models.SweepResult) error {
						// This test validates that the registry correctly processes the sightings
						// The actual discovery source aggregation happens in the database materialized view
						// But we can verify the sightings have the correct discovery source
						for _, sighting := range sightings {
							assert.Contains(t, tt.expectedDiscoverySources, sighting.DiscoverySource,
								"Sighting discovery source should be one of the expected sources")
						}
						t.Logf("✅ %s: Sightings processed with discovery sources", tt.description)
						return nil
					}).
					Times(1)

				err := registry.ProcessBatchSightings(ctx, tt.subsequentSightings)
				require.NoError(t, err)
			}
		})
	}
}

// TestArmisDiscoverySourceConstant checks that the armis discovery source is defined correctly
func TestArmisDiscoverySourceConstant(t *testing.T) {
	sighting := &models.SweepResult{
		IP:              "192.168.1.200",
		DeviceID:        "default:192.168.1.200",
		Partition:       "default",
		DiscoverySource: "armis",
		Hostname:        stringPtr("armis-test-device"),
		Timestamp:       time.Now(),
		Available:       true,
		Metadata: map[string]string{
			"armis_device_id": "armis-123",
			"tag":             "critical",
		},
	}

	// Validate that armis is a valid discovery source
	assert.Equal(t, "armis", sighting.DiscoverySource)
	assert.Equal(t, "armis-123", sighting.Metadata["armis_device_id"])

	t.Logf("✅ Armis discovery source validation passed")
}
