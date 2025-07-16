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

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestDeviceRegistry_ProcessRetractionEvents(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	t.Run("Armis retraction event preserves Available=false", func(t *testing.T) {
		// Test that a retraction event with Available=false is preserved through the registry processing
		retractionEvent := &models.SweepResult{
			IP:              "192.168.1.100",
			DeviceID:        "default:192.168.1.100",
			Partition:       "default",
			DiscoverySource: "armis",
			Hostname:        &[]string{"retracted-device"}[0],
			Timestamp:       time.Now(),
			Available:       false, // Key field for retraction
			Metadata: map[string]string{
				"_deleted":        "true",
				"armis_device_id": "123",
			},
		}

		// Setup mock expectations
		mockDB.EXPECT().
			GetUnifiedDevicesByIP(gomock.Any(), "192.168.1.100").
			Return([]*models.UnifiedDevice{}, nil)

		mockDB.EXPECT().
			PublishBatchSweepResults(gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})).
			DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				require.Len(t, results, 1)
				result := results[0]

				// Critical test: Available field must be preserved as false
				assert.False(t, result.Available, "Retraction event Available field must be preserved as false")
				assert.Equal(t, "true", result.Metadata["_deleted"], "Retraction event must have _deleted metadata")
				assert.Equal(t, "armis", result.DiscoverySource, "Discovery source must be preserved")

				return nil
			})

		// Process the retraction event
		err := registry.ProcessSighting(ctx, retractionEvent)
		require.NoError(t, err, "Retraction event should be processed successfully")
	})

	t.Run("NetBox retraction event preserves Available=false", func(t *testing.T) {
		retractionEvent := &models.SweepResult{
			IP:              "192.168.2.50",
			DeviceID:        "default:192.168.2.50",
			Partition:       "default",
			DiscoverySource: "netbox",
			Hostname:        &[]string{"netbox-device"}[0],
			Timestamp:       time.Now(),
			Available:       false, // Device retracted from NetBox
			Metadata: map[string]string{
				"_deleted":       "true",
				"integration_id": "456",
			},
		}

		// Setup mock expectations
		mockDB.EXPECT().
			GetUnifiedDevicesByIP(gomock.Any(), "192.168.2.50").
			Return([]*models.UnifiedDevice{}, nil)

		mockDB.EXPECT().
			PublishBatchSweepResults(gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})).
			DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				require.Len(t, results, 1)
				result := results[0]

				assert.False(t, result.Available, "NetBox retraction event Available field must be false")
				assert.Equal(t, "true", result.Metadata["_deleted"])
				assert.Equal(t, "netbox", result.DiscoverySource)

				return nil
			})

		err := registry.ProcessSighting(ctx, retractionEvent)
		require.NoError(t, err)
	})

	t.Run("Batch retraction events preserve Available=false for all events", func(t *testing.T) {
		// Test that when processing multiple retraction events, all Available=false values are preserved
		retractionEvents := []*models.SweepResult{
			{
				IP:              "192.168.3.10",
				DeviceID:        "default:192.168.3.10",
				Partition:       "default",
				DiscoverySource: "armis",
				Hostname:        &[]string{"batch-device-1"}[0],
				Timestamp:       time.Now(),
				Available:       false,
				Metadata: map[string]string{
					"_deleted":        "true",
					"armis_device_id": "100",
				},
			},
			{
				IP:              "192.168.3.11",
				DeviceID:        "default:192.168.3.11",
				Partition:       "default",
				DiscoverySource: "armis",
				Hostname:        &[]string{"batch-device-2"}[0],
				Timestamp:       time.Now(),
				Available:       false,
				Metadata: map[string]string{
					"_deleted":        "true",
					"armis_device_id": "101",
				},
			},
		}

		// Mock batch processing (registry will use GetUnifiedDevicesByIPsOrIDs for batches > 10)
		// Since we only have 2 events, it will call GetUnifiedDevicesByIP for each
		mockDB.EXPECT().
			GetUnifiedDevicesByIP(gomock.Any(), "192.168.3.10").
			Return([]*models.UnifiedDevice{}, nil)

		mockDB.EXPECT().
			GetUnifiedDevicesByIP(gomock.Any(), "192.168.3.11").
			Return([]*models.UnifiedDevice{}, nil)

		mockDB.EXPECT().
			PublishBatchSweepResults(gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})).
			DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				require.Len(t, results, 2)

				// All retraction events should have Available=false
				for _, result := range results {
					assert.False(t, result.Available, "All retraction events must have Available=false")
					assert.Equal(t, "true", result.Metadata["_deleted"])
					assert.Equal(t, "armis", result.DiscoverySource)
				}

				return nil
			})

		err := registry.ProcessBatchSightings(ctx, retractionEvents)
		require.NoError(t, err)
	})

	t.Run("Mixed available and retraction events preserve individual states", func(t *testing.T) {
		// Test a mix of available and unavailable devices to ensure the registry doesn't
		// accidentally modify the Available field
		mixedEvents := []*models.SweepResult{
			{
				IP:              "192.168.4.10",
				DeviceID:        "default:192.168.4.10",
				Partition:       "default",
				DiscoverySource: "armis",
				Hostname:        &[]string{"available-device"}[0],
				Timestamp:       time.Now(),
				Available:       true, // Still available
				Metadata: map[string]string{
					"armis_device_id": "200",
				},
			},
			{
				IP:              "192.168.4.11",
				DeviceID:        "default:192.168.4.11",
				Partition:       "default",
				DiscoverySource: "armis",
				Hostname:        &[]string{"retracted-device"}[0],
				Timestamp:       time.Now(),
				Available:       false, // Retracted
				Metadata: map[string]string{
					"_deleted":        "true",
					"armis_device_id": "201",
				},
			},
		}

		mockDB.EXPECT().
			GetUnifiedDevicesByIP(gomock.Any(), "192.168.4.10").
			Return([]*models.UnifiedDevice{}, nil)

		mockDB.EXPECT().
			GetUnifiedDevicesByIP(gomock.Any(), "192.168.4.11").
			Return([]*models.UnifiedDevice{}, nil)

		mockDB.EXPECT().
			PublishBatchSweepResults(gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})).
			DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				require.Len(t, results, 2)

				// Find and verify each type of device
				var availableCount, retractedCount int

				for _, result := range results {
					if result.Available {
						availableCount++

						assert.NotEqual(t, "true", result.Metadata["_deleted"], "Available device should not have _deleted metadata")
					} else {
						retractedCount++

						assert.Equal(t, "true", result.Metadata["_deleted"], "Retracted device must have _deleted metadata")
					}
				}

				assert.Equal(t, 1, availableCount, "Should have exactly 1 available device")
				assert.Equal(t, 1, retractedCount, "Should have exactly 1 retracted device")

				return nil
			})

		err := registry.ProcessBatchSightings(ctx, mixedEvents)
		require.NoError(t, err)
	})
}

func TestDeviceRegistry_RetractionEventFieldPreservation(t *testing.T) {
	// Comprehensive test to ensure all fields in retraction events are preserved
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	testTime := time.Now()
	retractionEvent := &models.SweepResult{
		AgentID:         "test-agent",
		PollerID:        "test-poller",
		Partition:       "test-partition",
		DeviceID:        "test-partition:192.168.5.100",
		DiscoverySource: "armis",
		IP:              "192.168.5.100",
		MAC:             &[]string{"aa:bb:cc:dd:ee:ff"}[0],
		Hostname:        &[]string{"comprehensive-test-device"}[0],
		Timestamp:       testTime,
		Available:       false, // Critical field for retraction
		Metadata: map[string]string{
			"_deleted":         "true",
			"armis_device_id":  "999",
			"custom_field":     "custom_value",
			"integration_type": "armis",
		},
	}

	mockDB.EXPECT().
		GetUnifiedDevicesByIP(gomock.Any(), "192.168.5.100").
		Return([]*models.UnifiedDevice{}, nil)

	mockDB.EXPECT().
		PublishBatchSweepResults(gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})).
		DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
			require.Len(t, results, 1)
			result := results[0]

			// Verify all fields are exactly preserved
			assert.Equal(t, "test-agent", result.AgentID, "AgentID must be preserved")
			assert.Equal(t, "test-poller", result.PollerID, "PollerID must be preserved")
			assert.Equal(t, "test-partition", result.Partition, "Partition must be preserved")
			assert.Equal(t, "test-partition:192.168.5.100", result.DeviceID, "DeviceID must be preserved")
			assert.Equal(t, "armis", result.DiscoverySource, "DiscoverySource must be preserved")
			assert.Equal(t, "192.168.5.100", result.IP, "IP must be preserved")
			assert.Equal(t, "aa:bb:cc:dd:ee:ff", *result.MAC, "MAC must be preserved")
			assert.Equal(t, "comprehensive-test-device", *result.Hostname, "Hostname must be preserved")
			assert.Equal(t, testTime, result.Timestamp, "Timestamp must be preserved")

			// Most critical assertion: Available field preservation
			assert.False(t, result.Available, "Available field must be preserved as false for retraction events")

			// Verify metadata preservation
			assert.Equal(t, "true", result.Metadata["_deleted"], "_deleted metadata must be preserved")
			assert.Equal(t, "999", result.Metadata["armis_device_id"], "armis_device_id metadata must be preserved")
			assert.Equal(t, "custom_value", result.Metadata["custom_field"], "custom metadata must be preserved")
			assert.Equal(t, "armis", result.Metadata["integration_type"], "integration_type metadata must be preserved")

			return nil
		})

	err := registry.ProcessSighting(ctx, retractionEvent)
	require.NoError(t, err, "Retraction event processing should succeed")
}

func TestDeviceRegistry_RetractionVsDiscoveryEvents(t *testing.T) {
	// Test that verifies the difference between discovery (Available=true) and retraction (Available=false) events
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	t.Run("Discovery event followed by retraction event", func(t *testing.T) {
		// First, process a discovery event
		discoveryEvent := &models.SweepResult{
			IP:              "192.168.6.100",
			DeviceID:        "default:192.168.6.100",
			Partition:       "default",
			DiscoverySource: "armis",
			Hostname:        &[]string{"lifecycle-test-device"}[0],
			Timestamp:       time.Now().Add(-time.Hour),
			Available:       true, // Device discovered
			Metadata: map[string]string{
				"armis_device_id": "500",
			},
		}

		mockDB.EXPECT().
			GetUnifiedDevicesByIP(gomock.Any(), "192.168.6.100").
			Return([]*models.UnifiedDevice{}, nil)

		mockDB.EXPECT().
			PublishBatchSweepResults(gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})).
			DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				require.Len(t, results, 1)
				assert.True(t, results[0].Available, "Discovery event must have Available=true")

				return nil
			})

		err := registry.ProcessSighting(ctx, discoveryEvent)
		require.NoError(t, err)

		// Then, process a retraction event for the same device
		retractionEvent := &models.SweepResult{
			IP:              "192.168.6.100",
			DeviceID:        "default:192.168.6.100",
			Partition:       "default",
			DiscoverySource: "armis",
			Hostname:        &[]string{"lifecycle-test-device"}[0],
			Timestamp:       time.Now(),
			Available:       false, // Device retracted
			Metadata: map[string]string{
				"_deleted":        "true",
				"armis_device_id": "500",
			},
		}

		mockDB.EXPECT().
			GetUnifiedDevicesByIP(gomock.Any(), "192.168.6.100").
			Return([]*models.UnifiedDevice{}, nil)

		mockDB.EXPECT().
			PublishBatchSweepResults(gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})).
			DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				require.Len(t, results, 1)
				assert.False(t, results[0].Available, "Retraction event must have Available=false")
				assert.Equal(t, "true", results[0].Metadata["_deleted"])

				return nil
			})

		err = registry.ProcessSighting(ctx, retractionEvent)
		require.NoError(t, err)
	})
}
