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

		// Setup mock expectations - registry now only publishes directly
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
		err := registry.ProcessBatchSweepResults(ctx, []*models.SweepResult{retractionEvent})
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

		// Setup mock expectations - registry now only publishes directly
		mockDB.EXPECT().
			PublishBatchSweepResults(gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})).
			DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				require.Len(t, results, 1)
				result := results[0]

				// Verify retraction event properties are preserved
				assert.False(t, result.Available, "NetBox retraction event Available field must be false")
				assert.Equal(t, "true", result.Metadata["_deleted"], "NetBox retraction must have _deleted metadata")
				assert.Equal(t, "netbox", result.DiscoverySource, "Discovery source must be preserved")

				return nil
			})

		// Process the retraction event
		err := registry.ProcessBatchSweepResults(ctx, []*models.SweepResult{retractionEvent})
		require.NoError(t, err, "NetBox retraction event should be processed successfully")
	})

	t.Run("Multiple retraction events batch processing", func(t *testing.T) {
		retractionEvents := []*models.SweepResult{
			{
				IP:              "192.168.3.10",
				DeviceID:        "default:192.168.3.10",
				Partition:       "default",
				DiscoverySource: "armis",
				Available:       false,
				Timestamp:       time.Now(),
				Metadata:        map[string]string{"_deleted": "true"},
			},
			{
				IP:              "192.168.3.11",
				DeviceID:        "default:192.168.3.11",
				Partition:       "default",
				DiscoverySource: "netbox",
				Available:       false,
				Timestamp:       time.Now(),
				Metadata:        map[string]string{"_deleted": "true"},
			},
		}

		// Setup mock expectations for batch processing
		mockDB.EXPECT().
			PublishBatchSweepResults(gomock.Any(), gomock.Len(2)).
			DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				require.Len(t, results, 2)

				for i, result := range results {
					assert.False(t, result.Available, "Retraction event %d Available field must be false", i)
					assert.Equal(t, "true", result.Metadata["_deleted"], "Retraction event %d must have _deleted metadata", i)
				}

				return nil
			})

		// Process multiple retraction events
		err := registry.ProcessBatchSweepResults(ctx, retractionEvents)
		require.NoError(t, err, "Multiple retraction events should be processed successfully")
	})
}

func TestDeviceRegistry_RetractionEventFieldPreservation(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	t.Run("All retraction event fields are preserved", func(t *testing.T) {
		originalEvent := &models.SweepResult{
			IP:              "192.168.5.100",
			DeviceID:        "test:192.168.5.100",
			Partition:       "test",
			DiscoverySource: "armis",
			Hostname:        &[]string{"special-device"}[0],
			MAC:             &[]string{"aa:bb:cc:dd:ee:ff"}[0],
			Timestamp:       time.Now(),
			Available:       false,
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Metadata: map[string]string{
				"_deleted":        "true",
				"armis_device_id": "789",
				"special_field":   "special_value",
			},
		}

		// Setup mock expectations
		mockDB.EXPECT().
			PublishBatchSweepResults(gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})).
			DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				require.Len(t, results, 1)
				result := results[0]

				// Verify all fields are preserved exactly
				assert.Equal(t, originalEvent.IP, result.IP)
				assert.Equal(t, originalEvent.DeviceID, result.DeviceID)
				assert.Equal(t, originalEvent.Partition, result.Partition)
				assert.Equal(t, originalEvent.DiscoverySource, result.DiscoverySource)
				assert.Equal(t, originalEvent.Hostname, result.Hostname)
				assert.Equal(t, originalEvent.MAC, result.MAC)
				assert.Equal(t, originalEvent.Available, result.Available)
				assert.Equal(t, originalEvent.AgentID, result.AgentID)
				assert.Equal(t, originalEvent.PollerID, result.PollerID)
				assert.Equal(t, originalEvent.Metadata, result.Metadata)

				return nil
			})

		// Process the event
		err := registry.ProcessBatchSweepResults(ctx, []*models.SweepResult{originalEvent})
		require.NoError(t, err)
	})
}

func TestDeviceRegistry_RetractionVsDiscoveryEvents(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	t.Run("Retraction and discovery events processed together", func(t *testing.T) {
		mixedEvents := []*models.SweepResult{
			{
				IP:              "192.168.6.100",
				DeviceID:        "default:192.168.6.100",
				Partition:       "default",
				DiscoverySource: "armis",
				Available:       false, // Retraction event
				Timestamp:       time.Now(),
				Metadata:        map[string]string{"_deleted": "true"},
			},
			{
				IP:              "192.168.6.101",
				DeviceID:        "default:192.168.6.101",
				Partition:       "default",
				DiscoverySource: "armis",
				Available:       true, // Discovery event
				Timestamp:       time.Now(),
				Metadata:        map[string]string{},
			},
		}

		// Setup mock expectations
		mockDB.EXPECT().
			PublishBatchSweepResults(gomock.Any(), gomock.Len(2)).
			DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				require.Len(t, results, 2)

				// First event should be retraction (Available=false)
				assert.False(t, results[0].Available, "First event should be retraction")
				assert.Equal(t, "true", results[0].Metadata["_deleted"])

				// Second event should be discovery (Available=true)  
				assert.True(t, results[1].Available, "Second event should be discovery")

				return nil
			})

		// Process mixed events
		err := registry.ProcessBatchSweepResults(ctx, mixedEvents)
		require.NoError(t, err)
	})
}