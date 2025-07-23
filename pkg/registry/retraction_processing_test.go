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
		// Test that a retraction event with IsAvailable=false is preserved through the registry processing
		retractionEvent := &models.DeviceUpdate{
			IP:          "192.168.1.100",
			DeviceID:    "default:192.168.1.100",
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Hostname:    &[]string{"retracted-device"}[0],
			Timestamp:   time.Now(),
			IsAvailable: false, // Key field for retraction
			Confidence:  models.GetSourceConfidence(models.DiscoverySourceArmis),
			Metadata: map[string]string{
				"_deleted":        "true",
				"armis_device_id": "123",
			},
		}

		// Setup mock expectations - registry now only publishes directly
		mockDB.EXPECT().
			PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
			DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
				require.Len(t, updates, 1)
				update := updates[0]

				// Critical test: IsAvailable field must be preserved as false
				assert.False(t, update.IsAvailable, "Retraction event IsAvailable field must be preserved as false")
				assert.Equal(t, "true", update.Metadata["_deleted"], "Retraction event must have _deleted metadata")
				assert.Equal(t, models.DiscoverySourceArmis, update.Source, "Discovery source must be preserved")

				return nil
			})

		// Process the retraction event
		err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{retractionEvent})
		require.NoError(t, err, "Retraction event should be processed successfully")
	})

	t.Run("NetBox retraction event preserves Available=false", func(t *testing.T) {
		retractionEvent := &models.DeviceUpdate{
			IP:          "192.168.2.50",
			DeviceID:    "default:192.168.2.50",
			Partition:   "default",
			Source:      models.DiscoverySourceNetbox,
			Hostname:    &[]string{"netbox-device"}[0],
			Timestamp:   time.Now(),
			IsAvailable: false, // Device retracted from NetBox
			Confidence:  models.GetSourceConfidence(models.DiscoverySourceNetbox),
			Metadata: map[string]string{
				"_deleted":       "true",
				"integration_id": "456",
			},
		}

		// Setup mock expectations - registry now only publishes directly
		mockDB.EXPECT().
			PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
			DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
				require.Len(t, updates, 1)
				update := updates[0]

				// Verify retraction event properties are preserved
				assert.False(t, update.IsAvailable, "NetBox retraction event IsAvailable field must be false")
				assert.Equal(t, "true", update.Metadata["_deleted"], "NetBox retraction must have _deleted metadata")
				assert.Equal(t, models.DiscoverySourceNetbox, update.Source, "Discovery source must be preserved")

				return nil
			})

		// Process the retraction event
		err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{retractionEvent})
		require.NoError(t, err, "NetBox retraction event should be processed successfully")
	})

	t.Run("Multiple retraction events batch processing", func(t *testing.T) {
		retractionEvents := []*models.DeviceUpdate{
			{
				IP:          "192.168.3.10",
				DeviceID:    "default:192.168.3.10",
				Partition:   "default",
				Source:      models.DiscoverySourceArmis,
				IsAvailable: false,
				Timestamp:   time.Now(),
				Confidence:  models.GetSourceConfidence(models.DiscoverySourceArmis),
				Metadata:    map[string]string{"_deleted": "true"},
			},
			{
				IP:          "192.168.3.11",
				DeviceID:    "default:192.168.3.11",
				Partition:   "default",
				Source:      models.DiscoverySourceNetbox,
				IsAvailable: false,
				Timestamp:   time.Now(),
				Confidence:  models.GetSourceConfidence(models.DiscoverySourceNetbox),
				Metadata:    map[string]string{"_deleted": "true"},
			},
		}

		// Setup mock expectations for batch processing
		mockDB.EXPECT().
			PublishBatchDeviceUpdates(gomock.Any(), gomock.Len(2)).
			DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
				require.Len(t, updates, 2)

				for i, update := range updates {
					assert.False(t, update.IsAvailable, "Retraction event %d IsAvailable field must be false", i)
					assert.Equal(t, "true", update.Metadata["_deleted"], "Retraction event %d must have _deleted metadata", i)
				}

				return nil
			})

		// Process multiple retraction events
		err := registry.ProcessBatchDeviceUpdates(ctx, retractionEvents)
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
		originalEvent := &models.DeviceUpdate{
			IP:          "192.168.5.100",
			DeviceID:    "test:192.168.5.100",
			Partition:   "test",
			Source:      models.DiscoverySourceArmis,
			Hostname:    &[]string{"special-device"}[0],
			MAC:         &[]string{"aa:bb:cc:dd:ee:ff"}[0],
			Timestamp:   time.Now(),
			IsAvailable: false,
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Confidence:  models.GetSourceConfidence(models.DiscoverySourceArmis),
			Metadata: map[string]string{
				"_deleted":        "true",
				"armis_device_id": "789",
				"special_field":   "special_value",
			},
		}

		// Setup mock expectations
		mockDB.EXPECT().
			PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
			DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
				require.Len(t, updates, 1)
				update := updates[0]

				// Verify all fields are preserved exactly
				assert.Equal(t, originalEvent.IP, update.IP)
				assert.Equal(t, originalEvent.DeviceID, update.DeviceID)
				assert.Equal(t, originalEvent.Partition, update.Partition)
				assert.Equal(t, originalEvent.Source, update.Source)
				assert.Equal(t, originalEvent.Hostname, update.Hostname)
				assert.Equal(t, originalEvent.MAC, update.MAC)
				assert.Equal(t, originalEvent.IsAvailable, update.IsAvailable)
				assert.Equal(t, originalEvent.AgentID, update.AgentID)
				assert.Equal(t, originalEvent.PollerID, update.PollerID)
				assert.Equal(t, originalEvent.Metadata, update.Metadata)

				return nil
			})

		// Process the event
		err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{originalEvent})
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
		mixedEvents := []*models.DeviceUpdate{
			{
				IP:          "192.168.6.100",
				DeviceID:    "default:192.168.6.100",
				Partition:   "default",
				Source:      models.DiscoverySourceArmis,
				IsAvailable: false, // Retraction event
				Timestamp:   time.Now(),
				Confidence:  models.GetSourceConfidence(models.DiscoverySourceArmis),
				Metadata:    map[string]string{"_deleted": "true"},
			},
			{
				IP:          "192.168.6.101",
				DeviceID:    "default:192.168.6.101",
				Partition:   "default",
				Source:      models.DiscoverySourceArmis,
				IsAvailable: true, // Discovery event
				Timestamp:   time.Now(),
				Confidence:  models.GetSourceConfidence(models.DiscoverySourceArmis),
				Metadata:    map[string]string{},
			},
		}

		// Setup mock expectations
		mockDB.EXPECT().
			PublishBatchDeviceUpdates(gomock.Any(), gomock.Len(2)).
			DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
				require.Len(t, updates, 2)

				// First event should be retraction (IsAvailable=false)
				assert.False(t, updates[0].IsAvailable, "First event should be retraction")
				assert.Equal(t, "true", updates[0].Metadata["_deleted"])

				// Second event should be discovery (IsAvailable=true)
				assert.True(t, updates[1].IsAvailable, "Second event should be discovery")

				return nil
			})

		// Process mixed events
		err := registry.ProcessBatchDeviceUpdates(ctx, mixedEvents)
		require.NoError(t, err)
	})
}
