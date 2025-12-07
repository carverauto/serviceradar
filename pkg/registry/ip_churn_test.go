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
	mockDB.EXPECT().WithTx(gomock.Any(), gomock.Any()).DoAndReturn(func(ctx context.Context, fn func(db.Service) error) error {
		return fn(mockDB)
	}).AnyTimes()
	mockDB.EXPECT().LockUnifiedDevices(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
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
	// New behavior (as of fix): Should SPLIT (clear IP of weak, create new strong).
	// Previously we merged, but that caused inventory loss during churn.
	
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().WithTx(gomock.Any(), gomock.Any()).DoAndReturn(func(ctx context.Context, fn func(db.Service) error) error {
		return fn(mockDB)
	}).AnyTimes()
	mockDB.EXPECT().LockUnifiedDevices(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
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

	
	// Expectation: Split.
	// 1. Update clearing IP of weak device (soft delete).
	// 2. New strong device update.
	// NO tombstones.
	
	var clearUpdate *models.DeviceUpdate
	var strongUpdate *models.DeviceUpdate
	var tombstone *models.DeviceUpdate
	
	for _, u := range published {
		if u.DeviceID == "sr:weak-dev" && u.IP == "0.0.0.0" {
			clearUpdate = u
		}
		if u.DeviceID == "sr:strong-dev" {
			strongUpdate = u
		}
		if u.Metadata != nil && u.Metadata["_merged_into"] != "" {
			tombstone = u
		}
	}
	
	assert.Nil(t, tombstone, "Should NOT merge/tombstone weak device into strong device")
	assert.NotNil(t, clearUpdate, "Should clear IP of weak device")
	assert.NotNil(t, strongUpdate, "Should process strong device update")
	
	if clearUpdate != nil {
		assert.Equal(t, "true", clearUpdate.Metadata["_ip_cleared_due_to_churn"])
		assert.Equal(t, "true", clearUpdate.Metadata["_deleted"])
	}
}
