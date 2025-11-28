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
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const testDeviceID = "default:172.18.0.2"

func allowCanonicalizationQueries(mockDB *db.MockService) {
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]*models.UnifiedDevice{}, nil).
		AnyTimes()
}

func strPtr(v string) *string {
	return &v
}

func TestProcessBatchDeviceUpdatesUpdatesStore(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		Return(nil)

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	hostname := "device-one"
	ts := time.Now().UTC()

	update := &models.DeviceUpdate{
		DeviceID:    "default:10.1.0.1",
		IP:          "10.1.0.1",
		PollerID:    "poller-1",
		AgentID:     "agent-1",
		Source:      models.DiscoverySourceSNMP,
		Timestamp:   ts,
		IsAvailable: true,
		Hostname:    &hostname,
		Metadata: map[string]string{
			"device_type":        "router",
			"integration_id":     "armis-42",
			"collector_agent_id": "agent-collector",
		},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
	require.NoError(t, err)

	record, ok := registry.GetDeviceRecord("default:10.1.0.1")
	require.True(t, ok)
	require.NotNil(t, record)

	assert.Equal(t, "10.1.0.1", record.IP)
	assert.Equal(t, "poller-1", record.PollerID)
	assert.Equal(t, "agent-1", record.AgentID)
	assert.Equal(t, []string{"snmp"}, record.DiscoverySources)
	assert.Equal(t, "router", record.DeviceType)
	require.NotNil(t, record.Hostname)
	assert.Equal(t, "device-one", *record.Hostname)
	require.NotNil(t, record.IntegrationID)
	assert.Equal(t, "armis-42", *record.IntegrationID)
	require.NotNil(t, record.CollectorAgentID)
	assert.Equal(t, "agent-collector", *record.CollectorAgentID)
	assert.WithinDuration(t, ts, record.LastSeen, time.Second)
}

func TestProcessBatchDeviceUpdatesRemovesDeletedRecords(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		Return(nil).
		Times(2)

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	initial := &DeviceRecord{
		DeviceID: "default:10.1.0.2",
		IP:       "10.1.0.2",
	}
	registry.UpsertDeviceRecord(initial)

	update := &models.DeviceUpdate{
		DeviceID:    "default:10.1.0.2",
		IP:          "10.1.0.2",
		Source:      models.DiscoverySourceMapper,
		Timestamp:   time.Now().UTC(),
		IsAvailable: false,
	}
	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update}))

	deleteUpdate := &models.DeviceUpdate{
		DeviceID:  "default:10.1.0.2",
		IP:        "10.1.0.2",
		Timestamp: time.Now().UTC(),
		Metadata: map[string]string{
			"_deleted": "true",
		},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{deleteUpdate})
	require.NoError(t, err)

	_, ok := registry.GetDeviceRecord("default:10.1.0.2")
	assert.False(t, ok, "device should be removed from store after deletion update")
}

func TestSearchDevices(t *testing.T) {
	reg := newTestDeviceRegistry()

	now := time.Now().UTC()

	reg.UpsertDeviceRecord(&DeviceRecord{
		DeviceID:         "default:10.3.0.1",
		IP:               "10.3.0.1",
		Hostname:         strPtr("edge-gateway"),
		DiscoverySources: []string{"snmp"},
		LastSeen:         now,
		FirstSeen:        now.Add(-10 * time.Minute),
		Metadata: map[string]string{
			"owner": "ops",
		},
	})

	reg.UpsertDeviceRecord(&DeviceRecord{
		DeviceID:         "default:10.3.0.2",
		IP:               "10.3.0.2",
		Hostname:         strPtr("core-router"),
		DiscoverySources: []string{"mapper"},
		LastSeen:         now.Add(-30 * time.Second),
		FirstSeen:        now.Add(-1 * time.Hour),
	})

	reg.UpsertDeviceRecord(&DeviceRecord{
		DeviceID:         "default:10.3.0.3",
		IP:               "10.3.0.3",
		Hostname:         strPtr("edge-switch"),
		DiscoverySources: []string{"mapper"},
		LastSeen:         now.Add(-10 * time.Second),
		FirstSeen:        now.Add(-2 * time.Hour),
	})

	results := reg.SearchDevices("edge", 10)
	require.Len(t, results, 2)
	assert.Equal(t, "default:10.3.0.1", results[0].DeviceID)

	results = reg.SearchDevices("10.3.0.", 1)
	require.Len(t, results, 1)
	assert.Equal(t, "default:10.3.0.1", results[0].DeviceID)

	results = reg.SearchDevices("default:10.3.0.2", 5)
	require.NotEmpty(t, results)
	assert.Equal(t, "default:10.3.0.2", results[0].DeviceID, "exact device_id match should rank highest")

	results = reg.SearchDevices("10.3.0.2", 5)
	require.NotEmpty(t, results)
	assert.Equal(t, "default:10.3.0.2", results[0].DeviceID, "exact IP match should outrank others")
}

func TestDeviceRegistry_ProcessBatchDeviceUpdates(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger, WithDeviceIdentityResolver(mockDB))
	require.NotNil(t, registry.deviceIdentityResolver)
	require.NotNil(t, registry.deviceIdentityResolver)

	tests := []struct {
		name        string
		updates     []*models.DeviceUpdate
		description string
		validate    func(t *testing.T, publishedUpdates []*models.DeviceUpdate)
	}{
		{
			name:        "Simple device with complete data",
			description: "Device with all required fields should be passed through without modification",
			updates: []*models.DeviceUpdate{
				{
					IP:          "216.17.46.98",
					DeviceID:    "default:216.17.46.98",
					Partition:   "default",
					Source:      models.DiscoverySourceSNMP, // mapper -> SNMP
					Hostname:    stringPtr("tonka01"),
					Timestamp:   time.Now(),
					IsAvailable: true,
					Confidence:  models.GetSourceConfidence(models.DiscoverySourceSNMP),
					Metadata: map[string]string{
						"alternate_ips":   `["192.168.10.1"]`,
						"controller_name": "Tonka",
						"source":          "unifi-api",
						"unifi_device_id": "39b54c6a-1598-3904-aa0c-96d9727f4d74",
					},
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()
				assert.Len(t, publishedUpdates, 1, "Should publish exactly one update")
				result := publishedUpdates[0]
				assert.True(t, strings.HasPrefix(result.DeviceID, "sr:"), "expected ServiceRadar UUID")
				assert.Equal(t, "216.17.46.98", result.IP)
				assert.Equal(t, "default", result.Partition)
				assert.Equal(t, models.DiscoverySourceSNMP, result.Source)
				assert.Equal(t, "tonka01", *result.Hostname)
				assert.True(t, result.IsAvailable)
				assert.Equal(t, `["192.168.10.1"]`, result.Metadata["alternate_ips"])
				require.NotEmpty(t, result.Metadata["_first_seen"])
				_, err := time.Parse(time.RFC3339Nano, result.Metadata["_first_seen"])
				require.NoError(t, err, "expected _first_seen to be RFC3339Nano timestamp")
			},
		},
		{
			name:        "Device with empty DeviceID gets normalized",
			description: "Device without DeviceID should get one generated from IP",
			updates: []*models.DeviceUpdate{
				{
					IP:          "192.168.1.100",
					DeviceID:    "", // Empty DeviceID
					Partition:   "default",
					Source:      models.DiscoverySourceMapper,
					Hostname:    stringPtr("test-device"),
					Timestamp:   time.Now(),
					IsAvailable: true,
					Confidence:  models.GetSourceConfidence(models.DiscoverySourceMapper),
					Metadata:    map[string]string{},
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()
				assert.Len(t, publishedUpdates, 1, "Should publish exactly one update")
				result := publishedUpdates[0]
				assert.True(t, strings.HasPrefix(result.DeviceID, "sr:"), "Should generate ServiceRadar ID")
				assert.Equal(t, "192.168.1.100", result.IP)
				assert.Equal(t, "default", result.Partition)
			},
		},
		{
			name:        "Device with empty Partition gets normalized",
			description: "Device without Partition should get default partition",
			updates: []*models.DeviceUpdate{
				{
					IP:          "192.168.10.5",
					DeviceID:    "default:192.168.10.5",
					Partition:   "", // Empty Partition
					Source:      models.DiscoverySourceSNMP,
					Hostname:    stringPtr("multi-ip-device"),
					Timestamp:   time.Now(),
					IsAvailable: true,
					Confidence:  models.GetSourceConfidence(models.DiscoverySourceSNMP),
					Metadata: map[string]string{
						"alternate_ips": `["192.168.10.1", "192.168.10.3", "192.168.10.8"]`,
					},
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()
				assert.Len(t, publishedUpdates, 1, "Should publish exactly one update")
				result := publishedUpdates[0]
				assert.Equal(t, "default", result.Partition, "Should extract partition from DeviceID")
				assert.True(t, strings.HasPrefix(result.DeviceID, "sr:"), "Should generate ServiceRadar ID")
			},
		},
		{
			name:        "Multiple devices in batch",
			description: "Multiple devices should all be processed and published",
			updates: []*models.DeviceUpdate{
				{
					IP:          "192.168.1.1",
					DeviceID:    "default:192.168.1.1",
					Partition:   "default",
					Source:      models.DiscoverySourceSNMP,
					Hostname:    stringPtr("device1"),
					Timestamp:   time.Now(),
					IsAvailable: true,
					Confidence:  models.GetSourceConfidence(models.DiscoverySourceSNMP),
					Metadata:    map[string]string{"type": "router"},
				},
				{
					IP:          "192.168.1.2",
					DeviceID:    "default:192.168.1.2",
					Partition:   "default",
					Source:      models.DiscoverySourceMapper,
					Hostname:    stringPtr("device2"),
					Timestamp:   time.Now(),
					IsAvailable: false,
					Confidence:  models.GetSourceConfidence(models.DiscoverySourceMapper),
					Metadata:    map[string]string{"type": "switch"},
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()

				assert.Len(t, publishedUpdates, 2, "Should publish both updates")

				// Check first device
				result1 := publishedUpdates[0]
				assert.True(t, strings.HasPrefix(result1.DeviceID, "sr:"), "Should generate ServiceRadar ID")
				assert.Equal(t, "192.168.1.1", result1.IP)
				assert.Equal(t, "device1", *result1.Hostname)
				assert.True(t, result1.IsAvailable)
				assert.Equal(t, "router", result1.Metadata["type"])

				// Check second device
				result2 := publishedUpdates[1]
				assert.True(t, strings.HasPrefix(result2.DeviceID, "sr:"), "Should generate ServiceRadar ID")
				assert.NotEqual(t, result1.DeviceID, result2.DeviceID, "Different devices should not share IDs")
				assert.Equal(t, "192.168.1.2", result2.IP)
				assert.Equal(t, "device2", *result2.Hostname)
				assert.False(t, result2.IsAvailable)
				assert.Equal(t, "switch", result2.Metadata["type"])
			},
		},
		{
			name:        "Empty batch",
			description: "Empty batch should not cause any database calls",
			updates:     []*models.DeviceUpdate{},
			validate: func(t *testing.T, _ []*models.DeviceUpdate) {
				t.Helper()

				// This test should not reach the validation function
				// since no ProcessBatchDeviceUpdates call should be made
				t.Error("Empty batch should not trigger database call")
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if len(tt.updates) == 0 {
				// For empty batches, no database call should be made
				// Execute the test
				err := registry.ProcessBatchDeviceUpdates(ctx, tt.updates)
				require.NoError(t, err, "ProcessBatchDeviceUpdates should handle empty batches")
			} else {
				// Mock: Expect PublishBatchDeviceUpdates to be called
				mockDB.EXPECT().PublishBatchDeviceUpdates(
					gomock.Any(),
					gomock.AssignableToTypeOf([]*models.DeviceUpdate{}),
				).DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
					// Validate the updates that would be published
					tt.validate(t, updates)
					return nil
				})

				// Execute the test
				err := registry.ProcessBatchDeviceUpdates(ctx, tt.updates)
				require.NoError(t, err, "ProcessBatchDeviceUpdates should not return error")
			}

			t.Logf("✅ Test passed: %s", tt.description)
		})
	}
}

func TestDeviceRegistry_ProcessDeviceUpdate(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger, WithDeviceIdentityResolver(mockDB))

	// Test single device update (should call ProcessBatchDeviceUpdates internally)
	update := &models.DeviceUpdate{
		DeviceID:    "default:192.168.1.1",
		IP:          "192.168.1.1",
		Partition:   "default",
		Source:      models.DiscoverySourceSNMP,
		Timestamp:   time.Now(),
		IsAvailable: true,
		Hostname:    stringPtr("single-device"),
		Metadata:    map[string]string{"test": "value"},
	}

	// Mock: Expect PublishBatchDeviceUpdates to be called with single item
	mockDB.EXPECT().PublishBatchDeviceUpdates(
		gomock.Any(),
		gomock.AssignableToTypeOf([]*models.DeviceUpdate{}),
	).DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
		assert.Len(t, updates, 1, "Should publish exactly one update")
		update = updates[0]
		assert.True(t, strings.HasPrefix(update.DeviceID, "sr:"), "Should generate ServiceRadar ID")
		assert.Equal(t, "192.168.1.1", update.IP)
		assert.Equal(t, "single-device", *update.Hostname)
		assert.Equal(t, "value", update.Metadata["test"])
		require.NotEmpty(t, update.Metadata["_first_seen"])
		_, err := time.Parse(time.RFC3339Nano, update.Metadata["_first_seen"])
		require.NoError(t, err)

		return nil
	})

	// Execute the test
	err := registry.ProcessDeviceUpdate(ctx, update)
	require.NoError(t, err, "ProcessDeviceUpdate should not return error")
}

func TestDeviceRegistry_NormalizationBehavior(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger, WithDeviceIdentityResolver(mockDB))

	tests := []struct {
		name        string
		input       *models.DeviceUpdate
		description string
		validate    func(t *testing.T, normalized *models.DeviceUpdate)
	}{
		{
			name:        "DeviceID and Partition both empty",
			description: "Should generate both DeviceID and Partition from IP",
			input: &models.DeviceUpdate{
				IP:          "192.168.1.100",
				DeviceID:    "",
				Partition:   "",
				Source:      models.DiscoverySourceMapper,
				Timestamp:   time.Now(),
				IsAvailable: true,
				Confidence:  models.GetSourceConfidence(models.DiscoverySourceMapper),
			},
			validate: func(t *testing.T, normalized *models.DeviceUpdate) {
				t.Helper()

				assert.True(t, strings.HasPrefix(normalized.DeviceID, "sr:"), "Should generate ServiceRadar ID")
				assert.Equal(t, "default", normalized.Partition)
			},
		},
		{
			name:        "Partition empty but DeviceID has valid format",
			description: "Should extract partition from DeviceID",
			input: &models.DeviceUpdate{
				IP:          "192.168.1.101",
				DeviceID:    "custom:192.168.1.101",
				Partition:   "",
				Source:      models.DiscoverySourceMapper,
				Timestamp:   time.Now(),
				IsAvailable: true,
				Confidence:  models.GetSourceConfidence(models.DiscoverySourceMapper),
			},
			validate: func(t *testing.T, normalized *models.DeviceUpdate) {
				t.Helper()

				assert.True(t, strings.HasPrefix(normalized.DeviceID, "sr:"), "Should canonicalize device ID")
				assert.Equal(t, "custom", normalized.Partition)
			},
		},
		{
			name:        "DeviceID malformed without colon",
			description: "Should fix malformed DeviceID and set default partition",
			input: &models.DeviceUpdate{
				IP:          "192.168.1.102",
				DeviceID:    "malformed-device-id",
				Partition:   "",
				Source:      models.DiscoverySourceMapper,
				Timestamp:   time.Now(),
				IsAvailable: true,
				Confidence:  models.GetSourceConfidence(models.DiscoverySourceMapper),
			},
			validate: func(t *testing.T, normalized *models.DeviceUpdate) {
				t.Helper()

				assert.True(t, strings.HasPrefix(normalized.DeviceID, "sr:"), "Should canonicalize malformed device ID")
				assert.Equal(t, "default", normalized.Partition)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Mock: Expect PublishBatchDeviceUpdates to be called
			mockDB.EXPECT().PublishBatchDeviceUpdates(
				gomock.Any(),
				gomock.AssignableToTypeOf([]*models.DeviceUpdate{}),
			).DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
				assert.Len(t, updates, 1, "Should publish exactly one update")
				tt.validate(t, updates[0])

				return nil
			})

			// Execute the test
			err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{tt.input})
			require.NoError(t, err, "ProcessBatchDeviceUpdates should not return error")

			t.Logf("✅ Test passed: %s", tt.description)
		})
	}
}

func TestDeviceRegistry_FirstSeenPreservedFromExistingRecord(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	existingFirstSeen := time.Date(2024, 12, 1, 15, 4, 5, 0, time.UTC)
	deviceID := "default:10.0.0.5"

	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)
	registry.UpsertDeviceRecord(&DeviceRecord{
		DeviceID:  deviceID,
		FirstSeen: existingFirstSeen,
	})

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Len(t, updates, 1)
			update := updates[0]
			require.Equal(t, deviceID, update.DeviceID)
			require.NotEmpty(t, update.Metadata["_first_seen"])

			parsed, err := time.Parse(time.RFC3339Nano, update.Metadata["_first_seen"])
			require.NoError(t, err)
			assert.Equal(t, existingFirstSeen, parsed)

			return nil
		})

	update := &models.DeviceUpdate{
		DeviceID:    deviceID,
		IP:          "10.0.0.5",
		Partition:   "default",
		Source:      models.DiscoverySourceIntegration,
		Timestamp:   time.Date(2025, 1, 1, 12, 0, 0, 0, time.UTC),
		IsAvailable: true,
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
	require.NoError(t, err)
}

func TestAnnotateFirstSeenUsesEarliestAcrossBatch(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	deviceID := "default:10.0.0.42"
	later := time.Date(2025, 1, 2, 15, 4, 5, 0, time.UTC)
	earlier := later.Add(-48 * time.Hour)

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger())
	registry.UpsertDeviceRecord(&DeviceRecord{
		DeviceID:  deviceID,
		FirstSeen: earlier,
	})

	updates := []*models.DeviceUpdate{
		{
			DeviceID:  deviceID,
			Partition: "default",
			Timestamp: later,
		},
		{
			DeviceID:  deviceID,
			Partition: "default",
			Timestamp: later.Add(time.Hour),
			Metadata: map[string]string{
				"_first_seen": earlier.Format(time.RFC3339Nano),
			},
		},
	}

	err := registry.annotateFirstSeen(ctx, updates)
	require.NoError(t, err)

	for _, update := range updates {
		require.NotNil(t, update.Metadata, "metadata should be populated")
		require.NotEmpty(t, update.Metadata["_first_seen"], "expected _first_seen to be set")

		got, err := time.Parse(time.RFC3339Nano, update.Metadata["_first_seen"])
		require.NoError(t, err)
		assert.Equal(t, earlier, got)
	}
}

func TestAnnotateFirstSeenUsesRegistryCache(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	var updates []*models.DeviceUpdate
	refTimes := make(map[string]time.Time)
	for i := 0; i < 7; i++ {
		deviceID := fmt.Sprintf("default:10.0.0.%d", i)
		firstSeen := time.Now().Add(-time.Duration(i) * time.Hour).UTC()
		refTimes[deviceID] = firstSeen
		registry.UpsertDeviceRecord(&DeviceRecord{
			DeviceID:  deviceID,
			FirstSeen: firstSeen,
		})

		updates = append(updates, &models.DeviceUpdate{
			DeviceID:  deviceID,
			Partition: "default",
			Timestamp: time.Now().UTC(),
		})
	}

	err := registry.annotateFirstSeen(ctx, updates)
	require.NoError(t, err)

	for _, update := range updates {
		require.NotNil(t, update.Metadata)
		got, err := time.Parse(time.RFC3339Nano, update.Metadata["_first_seen"])
		require.NoError(t, err)
		assert.Equal(t, refTimes[update.DeviceID], got)
	}
}

func TestAnnotateFirstSeenFallsBackToDB(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	deviceID := "default:10.9.8.7"
	existing := time.Date(2024, 11, 15, 10, 30, 0, 0, time.UTC)

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Nil(), gomock.AssignableToTypeOf([]string{})).
		Return([]*models.UnifiedDevice{
			{
				DeviceID:  deviceID,
				FirstSeen: existing,
			},
		}, nil).
		Times(1)

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	update := &models.DeviceUpdate{
		DeviceID:  deviceID,
		Partition: "default",
		Timestamp: time.Date(2025, 1, 5, 12, 0, 0, 0, time.UTC),
	}

	err := registry.annotateFirstSeen(ctx, []*models.DeviceUpdate{update})
	require.NoError(t, err)

	require.NotNil(t, update.Metadata)
	got, err := time.Parse(time.RFC3339Nano, update.Metadata["_first_seen"])
	require.NoError(t, err)
	assert.Equal(t, existing, got)
}

// Helper function
func stringPtr(s string) *string {
	return &s
}

func TestDeviceRegistry_ProcessBatchDeviceUpdates_CanonicalizesDuplicatesWithinBatch(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger, WithDeviceIdentityResolver(mockDB))

	primaryID := "default:10.0.0.1"
	updates := []*models.DeviceUpdate{
		{
			IP:          "10.0.0.1",
			DeviceID:    primaryID,
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			Metadata: map[string]string{
				"armis_device_id": "armis-123",
			},
		},
		{
			IP:          "10.0.0.2",
			DeviceID:    "default:10.0.0.2",
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			Metadata: map[string]string{
				"armis_device_id": "armis-123",
			},
		},
	}

	var published []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, batch []*models.DeviceUpdate) error {
			published = append([]*models.DeviceUpdate(nil), batch...)
			return nil
		})

	err := registry.ProcessBatchDeviceUpdates(ctx, updates)
	require.NoError(t, err)
	require.Len(t, published, 2, "expected canonical updates without tombstone when strong identifiers match")

	first := published[0]
	second := published[1]
	t.Logf("published device IDs: %s, %s", first.DeviceID, second.DeviceID)

	require.True(t, strings.HasPrefix(first.DeviceID, "sr:"), "device IDs should be canonical UUIDs")
	assert.Equal(t, first.DeviceID, second.DeviceID, "duplicate should re-use canonical id from batch")
	assert.Equal(t, "10.0.0.1", first.IP)

	assert.Equal(t, "10.0.0.2", second.IP)
	assert.Equal(t, "armis-123", second.Metadata["armis_device_id"])
}

func TestLookupCanonicalPrefersMACOverIP(t *testing.T) {
	registry := &DeviceRegistry{logger: logger.NewTestLogger()}
	mac := "AA:BB:CC:DD:EE:FF"
	update := &models.DeviceUpdate{
		IP:  "10.0.0.10",
		MAC: &mac,
	}
	maps := &identityMaps{
		armis: map[string]string{},
		netbx: map[string]string{},
		mac:   map[string]string{mac: "default:canonical-mac"},
		ip:    map[string]string{"10.0.0.10": "default:canonical-ip"},
	}

	canonical, via := registry.lookupCanonicalFromMaps(update, maps)

	require.Equal(t, "default:canonical-mac", canonical)
	require.Equal(t, identitySourceMAC, via)
}

func TestLookupCanonicalFallsBackToIP(t *testing.T) {
	registry := &DeviceRegistry{logger: logger.NewTestLogger()}
	update := &models.DeviceUpdate{
		IP: "10.0.0.11",
	}
	maps := &identityMaps{
		armis: map[string]string{},
		netbx: map[string]string{},
		mac:   map[string]string{},
		ip:    map[string]string{"10.0.0.11": "default:canonical-ip"},
	}

	canonical, via := registry.lookupCanonicalFromMaps(update, maps)

	require.Equal(t, "default:canonical-ip", canonical)
	require.Equal(t, "ip", via)
}

func TestProcessBatchPublishesSweepWithoutIdentity(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Len(t, updates, 1, "sweep without strong identity should still publish")
			require.Equal(t, models.DiscoverySourceSweep, updates[0].Source)
			require.Equal(t, "default:10.1.1.1", updates[0].DeviceID)
			return nil
		})

	update := &models.DeviceUpdate{
		IP:          "10.1.1.1",
		DeviceID:    "default:10.1.1.1",
		Partition:   "default",
		Source:      models.DiscoverySourceSweep,
		Timestamp:   time.Now(),
		IsAvailable: false,
		Metadata: map[string]string{
			"icmp_available": "false",
		},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
	require.NoError(t, err)
}

func TestProcessBatchDeviceUpdates_DropsSelfReportedAfterDelete(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]any{}, nil).
		AnyTimes()

	deviceID := testDeviceID
	deletedAt := time.Date(2025, 11, 2, 18, 45, 0, 0, time.UTC)

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.AssignableToTypeOf([]string{})).
		DoAndReturn(func(_ context.Context, _ []string, ids []string) ([]*models.UnifiedDevice, error) {
			if len(ids) == 1 && ids[0] == deviceID {
				return []*models.UnifiedDevice{
					{
						DeviceID: deviceID,
						Metadata: &models.DiscoveredField[map[string]string]{
							Value: map[string]string{
								"_deleted":    "true",
								"_deleted_at": deletedAt.Format(time.RFC3339Nano),
							},
						},
					},
				}, nil
			}
			return []*models.UnifiedDevice{}, nil
		}).
		AnyTimes()

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Empty(t, updates, "stale updates should be dropped before publishing")
			return nil
		})

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	// Update with timestamp BEFORE deletion should be dropped
	staleUpdate := &models.DeviceUpdate{
		DeviceID:    deviceID,
		Partition:   "default",
		IP:          "172.18.0.2",
		Source:      models.DiscoverySourceSelfReported,
		Timestamp:   deletedAt.Add(-10 * time.Minute), // Before deletion
		IsAvailable: true,
		Metadata: map[string]string{
			"last_update": deletedAt.Add(-5 * time.Minute).Format(time.RFC3339Nano),
		},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{staleUpdate})
	require.NoError(t, err)
}

func TestProcessBatchDeviceUpdates_AllowsSelfReportedReOnboarding(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]any{}, nil).
		AnyTimes()

	deviceID := testDeviceID
	deletedAt := time.Date(2025, 11, 2, 18, 45, 0, 0, time.UTC)

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.AssignableToTypeOf([]string{})).
		DoAndReturn(func(_ context.Context, _ []string, ids []string) ([]*models.UnifiedDevice, error) {
			if len(ids) == 1 && ids[0] == deviceID {
				return []*models.UnifiedDevice{
					{
						DeviceID: deviceID,
						Metadata: &models.DiscoveredField[map[string]string]{
							Value: map[string]string{
								"_deleted":    "true",
								"_deleted_at": deletedAt.Format(time.RFC3339Nano),
							},
						},
					},
				}, nil
			}
			return []*models.UnifiedDevice{}, nil
		}).
		AnyTimes()

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Len(t, updates, 1, "fresh self-reported update should be allowed for re-onboarding")
			require.Equal(t, deviceID, updates[0].DeviceID)
			return nil
		})

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	// Update with timestamp AFTER deletion should be allowed (re-onboarding)
	freshUpdate := &models.DeviceUpdate{
		DeviceID:    deviceID,
		Partition:   "default",
		IP:          "172.18.0.2",
		Source:      models.DiscoverySourceSelfReported,
		Timestamp:   deletedAt.Add(10 * time.Minute), // After deletion
		IsAvailable: true,
		Metadata: map[string]string{
			"last_update": deletedAt.Add(5 * time.Minute).Format(time.RFC3339Nano),
		},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{freshUpdate})
	require.NoError(t, err)
}

func TestResolveIPsToCanonicalUsesIdentityResolverBeforeDB(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	record := &identitymap.Record{
		CanonicalDeviceID: "default:canonical-ip",
	}
	payload, err := identitymap.MarshalRecord(record)
	require.NoError(t, err)

	key := identitymap.Key{Kind: identitymap.KindIP, Value: "10.0.0.42"}.KeyPath(identitymap.DefaultNamespace)
	kv := &fakeBatchGetter{
		results: map[string]*proto.BatchGetEntry{
			key: {
				Key:   key,
				Found: true,
				Value: payload,
			},
		},
	}

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger(), WithIdentityResolver(kv, identitymap.DefaultNamespace))

	maps, err := registry.buildIdentityMaps(ctx, []*models.DeviceUpdate{
		{IP: "10.0.0.42"},
	})
	require.NoError(t, err)

	require.Equal(t, "default:canonical-ip", maps.ip["10.0.0.42"])
}

func TestProcessBatchDeviceUpdates_AllowsFreshNonSelfReportedAfterDelete(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]any{}, nil).
		AnyTimes()

	deviceID := testDeviceID
	deletedAt := time.Date(2025, 11, 2, 18, 45, 0, 0, time.UTC)

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.AssignableToTypeOf([]string{})).
		DoAndReturn(func(_ context.Context, _ []string, ids []string) ([]*models.UnifiedDevice, error) {
			if len(ids) == 1 && ids[0] == deviceID {
				return []*models.UnifiedDevice{
					{
						DeviceID: deviceID,
						Metadata: &models.DiscoveredField[map[string]string]{
							Value: map[string]string{
								"_deleted":    "true",
								"_deleted_at": deletedAt.Format(time.RFC3339Nano),
							},
						},
					},
				}, nil
			}
			return []*models.UnifiedDevice{}, nil
		}).
		AnyTimes()

	allowCanonicalizationQueries(mockDB)

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Len(t, updates, 1, "fresh updates should bypass the tombstone filter")
			require.Equal(t, deviceID, updates[0].DeviceID)
			require.Equal(t, models.DiscoverySourceSNMP, updates[0].Source)
			return nil
		})

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	freshUpdate := &models.DeviceUpdate{
		DeviceID:    deviceID,
		Partition:   "default",
		IP:          "172.18.0.2",
		Source:      models.DiscoverySourceSNMP,
		Timestamp:   deletedAt.Add(10 * time.Minute),
		IsAvailable: true,
		Metadata: map[string]string{
			"last_update": deletedAt.Add(10 * time.Minute).Format(time.RFC3339Nano),
		},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{freshUpdate})
	require.NoError(t, err)
}

func TestEndToEndIngestWithChurnKeepsCardinality(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)

	type deviceStats struct {
		deviceIDs []string
		available []bool
		strongID  string
		seenIPs   []string
	}

	published := make(map[string]*deviceStats) // armis_device_id -> stats

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			for _, u := range updates {
				strong := strings.TrimSpace(u.Metadata["armis_device_id"])
				if strong == "" {
					strong = strings.TrimSpace(u.Metadata["canonical_device_id"])
				}
				stats, ok := published[strong]
				if !ok {
					stats = &deviceStats{strongID: strong}
					published[strong] = stats
				}
				stats.deviceIDs = append(stats.deviceIDs, u.DeviceID)
				stats.available = append(stats.available, u.IsAvailable)
				stats.seenIPs = append(stats.seenIPs, u.IP)
			}
			return nil
		}).
		Times(2) // initial ingest + churn batch

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger(), WithDeviceIdentityResolver(mockDB))

	const total = 20
	initial := make([]*models.DeviceUpdate, 0, total)
	for i := 0; i < total; i++ {
		mac := fmt.Sprintf("aa:bb:cc:dd:ee:%02x", i)
		armisID := fmt.Sprintf("armis-%d", i)
		initial = append(initial, &models.DeviceUpdate{
			IP:          fmt.Sprintf("10.10.0.%d", i+1),
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			MAC:         stringPtr(mac),
			IsAvailable: false,
			Metadata: map[string]string{
				"armis_device_id": armisID,
			},
		})
	}

	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, initial))

	churned := make([]*models.DeviceUpdate, 0, total)
	for i := 0; i < total; i++ {
		mac := fmt.Sprintf("aa:bb:cc:dd:ee:%02x", i)
		armisID := fmt.Sprintf("armis-%d", i)
		churned = append(churned, &models.DeviceUpdate{
			IP:          fmt.Sprintf("10.20.0.%d", i+10),
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			MAC:         stringPtr(mac),
			IsAvailable: false,
			Metadata: map[string]string{
				"armis_device_id": armisID,
			},
		})
	}

	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, churned))

	require.Len(t, published, total, "should track each strong ID")
	for armisID, stats := range published {
		require.Lenf(t, stats.deviceIDs, 2, "expected two updates per strong ID %s", armisID)
		require.NotEmpty(t, stats.deviceIDs[0])
		assert.Equalf(t, stats.deviceIDs[0], stats.deviceIDs[1], "strong ID %s must keep the same device across IP churn", armisID)
		for idx, avail := range stats.available {
			assert.Falsef(t, avail, "ingest should not mark availability true (strong ID %s update %d)", armisID, idx)
		}
	}
}

func TestAvailabilityRemainsUnknownUntilPositiveProbe(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)

	var published []*models.DeviceUpdate

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			published = append(published, updates...)
			return nil
		}).
		Times(2) // initial sighting promotion + positive probe

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger(), WithDeviceIdentityResolver(mockDB))

	mac := "aa:bb:cc:dd:ee:11"
	initial := &models.DeviceUpdate{
		IP:          "10.30.0.1",
		Partition:   "default",
		Source:      models.DiscoverySourceSighting,
		MAC:         &mac,
		IsAvailable: false,
		Metadata: map[string]string{
			"armis_device_id": "armis-availability",
			"sighting_id":     "s-1",
		},
	}

	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{initial}))

	positiveProbe := &models.DeviceUpdate{
		IP:          "10.30.0.1",
		Partition:   "default",
		Source:      models.DiscoverySourceSweep,
		MAC:         &mac,
		IsAvailable: true,
	}

	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{positiveProbe}))

	require.Len(t, published, 2)
	require.Equal(t, published[0].DeviceID, published[1].DeviceID, "same device should be updated by probe")
	assert.False(t, published[0].IsAvailable, "initial sighting-derived update should remain unavailable")
	assert.True(t, published[1].IsAvailable, "positive probe should flip availability")
}

func TestIngestHarnessWithProbesKeepsCardinalityAndAvailability(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)

	type deviceStats struct {
		deviceIDs []string
		updates   []*models.DeviceUpdate
	}

	published := make(map[string]*deviceStats)

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			for _, u := range updates {
				key := strings.TrimSpace(u.Metadata["armis_device_id"])
				stats, ok := published[key]
				if !ok {
					stats = &deviceStats{}
					published[key] = stats
				}
				stats.deviceIDs = append(stats.deviceIDs, u.DeviceID)
				stats.updates = append(stats.updates, u)
			}
			return nil
		}).
		Times(3) // initial ingest + churn + probes

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger(), WithDeviceIdentityResolver(mockDB))

	const total = 30
	initial := make([]*models.DeviceUpdate, 0, total)
	for i := 0; i < total; i++ {
		mac := fmt.Sprintf("aa:bb:cc:dd:ee:%02x", i)
		armisID := fmt.Sprintf("armis-%d", i)
		initial = append(initial, &models.DeviceUpdate{
			IP:          fmt.Sprintf("10.40.0.%d", i+1),
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			MAC:         stringPtr(mac),
			IsAvailable: false,
			Metadata: map[string]string{
				"armis_device_id": armisID,
			},
		})
	}

	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, initial))

	churn := make([]*models.DeviceUpdate, 0, total)
	for i := 0; i < total; i++ {
		mac := fmt.Sprintf("aa:bb:cc:dd:ee:%02x", i)
		armisID := fmt.Sprintf("armis-%d", i)
		churn = append(churn, &models.DeviceUpdate{
			IP:          fmt.Sprintf("10.41.0.%d", i+50),
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			MAC:         stringPtr(mac),
			IsAvailable: false,
			Metadata: map[string]string{
				"armis_device_id": armisID,
			},
		})
	}

	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, churn))

	probes := make([]*models.DeviceUpdate, 0, total/2)
	for i := 0; i < total; i += 2 {
		mac := fmt.Sprintf("aa:bb:cc:dd:ee:%02x", i)
		armisID := fmt.Sprintf("armis-%d", i)
		probes = append(probes, &models.DeviceUpdate{
			IP:          fmt.Sprintf("10.41.0.%d", i+50),
			Partition:   "default",
			Source:      models.DiscoverySourceSweep,
			MAC:         stringPtr(mac),
			IsAvailable: true,
			Metadata: map[string]string{
				"armis_device_id": armisID,
			},
		})
	}

	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, probes))

	require.Len(t, published, total, "should have stats per strong ID")

	uniqueDevices := make(map[string]struct{})
	for armisID, stats := range published {
		probed := strings.HasSuffix(armisID, "0") ||
			strings.HasSuffix(armisID, "2") ||
			strings.HasSuffix(armisID, "4") ||
			strings.HasSuffix(armisID, "6") ||
			strings.HasSuffix(armisID, "8")

		expectedCount := 2
		if probed {
			expectedCount = 3
		}

		require.Lenf(t, stats.deviceIDs, expectedCount, "unexpected update count for %s", armisID)
		require.NotEmpty(t, stats.deviceIDs[0])
		require.Equalf(t, stats.deviceIDs[0], stats.deviceIDs[1], "strong ID %s must keep same device across churn", armisID)
		if probed {
			require.Equalf(t, stats.deviceIDs[1], stats.deviceIDs[2], "strong ID %s must keep same device after probe", armisID)
		}

		last := stats.updates[len(stats.updates)-1]
		uniqueDevices[last.DeviceID] = struct{}{}

		if probed {
			assert.Truef(t, last.IsAvailable, "probed strong ID %s should be available", armisID)
		} else {
			assert.Falsef(t, last.IsAvailable, "unprobed strong ID %s should remain unavailable", armisID)
		}
	}

	assert.Len(t, uniqueDevices, total, "device count should match strong ID cardinality")
}

func TestDeviceIngestEndToEnd_StrongIDsSurviveIPChurn(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)

	published := make(map[string][]string) // armis_device_id -> []device_id

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			for _, u := range updates {
				id := strings.TrimSpace(u.Metadata["armis_device_id"])
				published[id] = append(published[id], u.DeviceID)
			}
			return nil
		}).
		Times(2) // initial ingest + churn

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger(), WithDeviceIdentityResolver(mockDB))

	batch1 := []*models.DeviceUpdate{
		{
			IP:        "10.10.0.1",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			MAC:       stringPtr("aa:bb:cc:dd:ee:01"),
			Metadata: map[string]string{
				"armis_device_id": "armis-1",
			},
		},
		{
			IP:        "10.10.0.2",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			MAC:       stringPtr("aa:bb:cc:dd:ee:02"),
			Metadata: map[string]string{
				"armis_device_id": "armis-2",
			},
		},
		{
			IP:        "10.10.0.3",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			MAC:       stringPtr("aa:bb:cc:dd:ee:03"),
			Metadata: map[string]string{
				"armis_device_id": "armis-3",
			},
		},
	}

	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, batch1))

	batch2 := []*models.DeviceUpdate{
		{
			IP:        "10.20.0.10",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			MAC:       stringPtr("aa:bb:cc:dd:ee:01"),
			Metadata: map[string]string{
				"armis_device_id": "armis-1",
			},
		},
		{
			IP:        "10.20.0.20",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			MAC:       stringPtr("aa:bb:cc:dd:ee:02"),
			Metadata: map[string]string{
				"armis_device_id": "armis-2",
			},
		},
		{
			IP:        "10.20.0.30",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			MAC:       stringPtr("aa:bb:cc:dd:ee:03"),
			Metadata: map[string]string{
				"armis_device_id": "armis-3",
			},
		},
	}

	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, batch2))

	require.Len(t, published, 3)
	for armisID, ids := range published {
		require.Lenf(t, ids, 2, "expected two updates for %s", armisID)
		require.NotEmpty(t, ids[0])
		assert.Equalf(t, ids[0], ids[1], "strong IDs must map to the same device across IP churn for %s", armisID)
	}
}

func TestReconcileSightingsBlocksOnCardinalityDrift(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().
		CountUnifiedDevices(gomock.Any()).
		Return(int64(52000), nil)
	mockDB.EXPECT().
		ListActiveSightings(gomock.Any(), "", sweepSightingMergeBatchSize, 0).
		Return([]*models.NetworkSighting{}, nil)
	mockDB.EXPECT().
		ListPromotableSightings(gomock.Any(), gomock.Any()).
		Times(0)

	cfg := &models.IdentityReconciliationConfig{
		Enabled:       true,
		SightingsOnly: false,
		Promotion: models.PromotionConfig{
			Enabled:        true,
			ShadowMode:     false,
			MinPersistence: 0,
		},
		Drift: models.IdentityDriftConfig{
			BaselineDevices:  50000,
			TolerancePercent: 0,
			PauseOnDrift:     true,
			AlertOnDrift:     false,
		},
	}

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger(), WithIdentityReconciliationConfig(cfg))

	err := registry.ReconcileSightings(ctx)
	require.NoError(t, err)
}

func TestProcessBatchDeviceUpdates_MergesSweepIntoCanonicalDevice(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	cfg := &models.IdentityReconciliationConfig{Enabled: true}
	registry := NewDeviceRegistry(
		mockDB,
		logger.NewTestLogger(),
		WithIdentityReconciliationConfig(cfg),
		WithCNPGIdentityResolver(mockDB),
	)

	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, ips []string, deviceIDs []string) ([]*models.UnifiedDevice, error) {
			if len(ips) > 0 {
				return []*models.UnifiedDevice{
					{
						DeviceID: "sr:canonical",
						IP:       ips[0],
						MAC:      &models.DiscoveredField[string]{Value: "aa:bb:cc:dd:ee:ff"},
					},
				}, nil
			}
			if len(deviceIDs) > 0 {
				return []*models.UnifiedDevice{
					{
						DeviceID: deviceIDs[0],
						IP:       "10.1.1.1",
						MAC:      &models.DiscoveredField[string]{Value: "aa:bb:cc:dd:ee:ff"},
					},
				}, nil
			}
			return []*models.UnifiedDevice{}, nil
		}).
		AnyTimes()

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Len(t, updates, 1)
			assert.Equal(t, "sr:canonical", updates[0].DeviceID)
			assert.Equal(t, models.DiscoverySourceSweep, updates[0].Source)
			assert.True(t, updates[0].IsAvailable)
			return nil
		})

	sweepUpdate := &models.DeviceUpdate{
		IP:          "10.1.1.1",
		Partition:   "default",
		Source:      models.DiscoverySourceSweep,
		Timestamp:   time.Now().UTC(),
		IsAvailable: true,
	}

	require.NoError(t, registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{sweepUpdate}))
}

func TestReconcileSightingsMergesSweepSightingsByIP(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	cfg := &models.IdentityReconciliationConfig{
		Enabled: true,
		Promotion: models.PromotionConfig{
			Enabled:    false,
			ShadowMode: false,
		},
	}

	registry := NewDeviceRegistry(
		mockDB,
		logger.NewTestLogger(),
		WithIdentityReconciliationConfig(cfg),
		WithCNPGIdentityResolver(mockDB),
	)

	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()

	sighting := &models.NetworkSighting{
		SightingID: "s-merge",
		Partition:  "default",
		IP:         "10.2.2.2",
		Source:     models.DiscoverySourceSweep,
		Status:     models.SightingStatusActive,
		FirstSeen:  time.Now().Add(-30 * time.Minute),
		LastSeen:   time.Now(),
		Metadata: map[string]string{
			"hostname":     "sweep-host",
			"is_available": "true",
		},
	}

	mockDB.EXPECT().
		ListActiveSightings(gomock.Any(), "", sweepSightingMergeBatchSize, 0).
		Return([]*models.NetworkSighting{sighting}, nil)

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, ips []string, deviceIDs []string) ([]*models.UnifiedDevice, error) {
			if len(ips) > 0 {
				return []*models.UnifiedDevice{
					{
						DeviceID: "sr:merge-target",
						IP:       ips[0],
						MAC:      &models.DiscoveredField[string]{Value: "AA:BB:CC:DD:EE:11"},
					},
				}, nil
			}
			if len(deviceIDs) > 0 {
				return []*models.UnifiedDevice{
					{
						DeviceID: deviceIDs[0],
						IP:       "10.2.2.2",
						MAC:      &models.DiscoveredField[string]{Value: "AA:BB:CC:DD:EE:11"},
					},
				}, nil
			}
			return []*models.UnifiedDevice{}, nil
		}).
		AnyTimes()

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Len(t, updates, 1)
			assert.Equal(t, "sr:merge-target", updates[0].DeviceID)
			assert.Equal(t, models.DiscoverySourceSweep, updates[0].Source)
			assert.True(t, updates[0].IsAvailable)
			assert.Equal(t, "s-merge", updates[0].Metadata["sighting_id"])
			return nil
		})

	mockDB.EXPECT().
		MarkSightingsPromoted(gomock.Any(), gomock.Any()).
		Return(int64(1), nil)

	mockDB.EXPECT().
		InsertSightingEvents(gomock.Any(), gomock.AssignableToTypeOf([]*models.SightingEvent{})).
		Return(nil)

	err := registry.ReconcileSightings(ctx)
	require.NoError(t, err)
}

func TestReconcileSightingsPromotesEligibleSightings(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)

	now := time.Now().UTC()
	sighting := &models.NetworkSighting{
		SightingID: "s-123",
		Partition:  "default",
		IP:         "10.50.0.5",
		Source:     models.DiscoverySourceSweep,
		Status:     models.SightingStatusActive,
		FirstSeen:  now.Add(-2 * time.Hour),
		LastSeen:   now,
		Metadata: map[string]string{
			"hostname":         "demo-host",
			"mac":              "aa:bb:cc:dd:ee:ff",
			"armis_device_id":  "armis-eligible",
			"fingerprint_hash": "fp-123",
		},
	}

	mockDB.EXPECT().
		ListActiveSightings(gomock.Any(), "", sweepSightingMergeBatchSize, 0).
		Return([]*models.NetworkSighting{}, nil)

	mockDB.EXPECT().
		ListPromotableSightings(gomock.Any(), gomock.Any()).
		Return([]*models.NetworkSighting{sighting}, nil)

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			for _, u := range updates {
				if u.DeviceID == "" {
					u.DeviceID = "default:" + u.IP
				}
			}
			return nil
		})

	mockDB.EXPECT().
		MarkSightingsPromoted(gomock.Any(), gomock.Any()).
		Return(int64(1), nil)

	mockDB.EXPECT().
		UpsertDeviceIdentifiers(gomock.Any(), gomock.Any()).
		Return(nil)

	mockDB.EXPECT().
		InsertSightingEvents(gomock.Any(), gomock.Any()).
		Return(nil)

	cfg := &models.IdentityReconciliationConfig{
		Enabled: true,
		Promotion: models.PromotionConfig{
			Enabled:        true,
			ShadowMode:     false,
			MinPersistence: 0,
		},
	}

	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger(), WithIdentityReconciliationConfig(cfg))

	err := registry.ReconcileSightings(ctx)
	require.NoError(t, err)
}
