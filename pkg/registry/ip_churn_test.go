package registry

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestIPChurn_SameStrongIdentity(t *testing.T) {
	// Scenario: Armis reports the same device twice (duplicate or update).
	// Should result in a standard merge/update, NOT an IP clear.
	
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	// 1. Existing device in DB
	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(ctx, gomock.Any(), gomock.Any()).
		Return([]*models.UnifiedDevice{
			{
				DeviceID: "sr:dev-a",
				IP:       "10.0.0.1",
				Metadata: &models.DiscoveredField[map[string]string]{
					Value: map[string]string{"armis_device_id": "armis-1"},
				},
			},
		}, nil).AnyTimes()

	mockDB.EXPECT().
		ExecuteQuery(ctx, gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{
			{
				"ip":        "10.0.0.1",
				"device_id": "sr:dev-a",
			},
		}, nil).AnyTimes()

	// 2. Capture published updates
	var published []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(ctx, gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			published = updates
			return nil
		}).Times(1)

	// 3. Incoming update with SAME Armis ID
	update := &models.DeviceUpdate{
		DeviceID:    "sr:dev-b", // Different UUID (maybe generated from new sighting), but same identity
		IP:          "10.0.0.1",
		Source:      models.DiscoverySourceArmis,
		Timestamp:   time.Now(),
		Metadata: map[string]string{
			"armis_device_id": "armis-1", // SAME ID
		},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
	require.NoError(t, err)

	// Expectation: Standard merge logic (tombstone sr:dev-b -> sr:dev-a)
	// because they are the same entity.
	
	require.NotEmpty(t, published)
	var tombstone *models.DeviceUpdate
	for _, u := range published {
		if u.Metadata != nil && u.Metadata["_merged_into"] == "sr:dev-a" {
			tombstone = u
		}
	}
	
	assert.NotNil(t, tombstone, "Should tombstone duplicate device with same strong identity")
}

func TestIPChurn_WeakVsStrongIdentity(t *testing.T) {
	// Scenario: Existing device is WEAK (just IP/scan). Incoming is STRONG (Armis).
	// Should merge (upgrade weak to strong), NOT clear IP.
	
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	// 1. Existing WEAK device
	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(ctx, gomock.Any(), gomock.Any()).
		Return([]*models.UnifiedDevice{
			{
				DeviceID: "sr:weak-dev",
				IP:       "10.0.0.1",
				Metadata: &models.DiscoveredField[map[string]string]{
					Value: map[string]string{}, // No strong ID
				},
			},
		}, nil).AnyTimes()

	mockDB.EXPECT().
		ExecuteQuery(ctx, gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{
			{
				"ip":        "10.0.0.1",
				"device_id": "sr:weak-dev",
			},
		}, nil).AnyTimes()

	var published []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(ctx, gomock.Any()).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			published = updates
			return nil
		}).Times(1)

	// 2. Incoming STRONG update
	update := &models.DeviceUpdate{
		DeviceID:    "sr:strong-dev",
		IP:          "10.0.0.1",
		Source:      models.DiscoverySourceArmis,
		Metadata: map[string]string{
			"armis_device_id": "armis-new",
		},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
	require.NoError(t, err)

	// Expectation: Conflict detected. 
	// Strong identities: Existing="", Update="armis-new".
	// Mismatch logic: (existing != "" && update != "" && ...) -> FALSE.
	// Fallback: Standard merge. Update (strong) conflicts with Existing (weak).
	// Existing (weak) should likely be merged into Update (strong) or vice versa depending on logic.
	// Currently `resolveIPConflictsWithDB` converts the NEW update to a tombstone pointing to EXISTING.
	// So "sr:strong-dev" becomes tombstone -> "sr:weak-dev".
	// AND "sr:weak-dev" gets updated with "armis-new". 
	// Effectively upgrading "sr:weak-dev" to have a strong identity.
	
	var tombstone *models.DeviceUpdate
	var merge *models.DeviceUpdate
	
	for _, u := range published {
		if u.Metadata != nil && u.Metadata["_merged_into"] == "sr:weak-dev" {
			tombstone = u
		}
		if u.DeviceID == "sr:weak-dev" {
			merge = u
		}
	}
	
	assert.NotNil(t, tombstone, "Should merge new strong device into existing weak device")
	assert.NotNil(t, merge, "Should update existing weak device with new details")
	if merge != nil {
		assert.Equal(t, "armis-new", merge.Metadata["armis_device_id"], "Existing device should inherit strong ID")
	}
}
