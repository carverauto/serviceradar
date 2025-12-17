package core

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBackfillIdentityTombstonesDryRunDoesNotPublish(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	log := logger.NewTestLogger()

	now := time.Now()

	armisRows := []map[string]interface{}{
		{
			"device_id": "default:canonical",
			"ip":        "10.0.0.1",
			"metadata": map[string]interface{}{
				"armis_device_id": "ARM-1",
			},
			"key":      "ARM-1",
			"_tp_time": now.Add(time.Minute),
		},
		{
			"device_id": "default:duplicate",
			"ip":        "10.0.0.2",
			"metadata": map[string]interface{}{
				"armis_device_id": "ARM-1",
			},
			"key":      "ARM-1",
			"_tp_time": now,
		},
	}

	gomock.InOrder(
		mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, query string, _ ...interface{}) ([]map[string]interface{}, error) {
			require.Contains(t, query, "armis_device_id")
			return armisRows, nil
		}),
		mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, query string, _ ...interface{}) ([]map[string]interface{}, error) {
			require.Contains(t, query, "integration_type")
			return []map[string]interface{}{}, nil
		}),
	)

	// In dry-run mode, no tombstones should be published
	mockDB.EXPECT().PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).Times(0)

	opts := BackfillOptions{DryRun: true}

	err := BackfillIdentityTombstones(context.Background(), mockDB, log, opts)
	require.NoError(t, err)
}

func TestBackfillIdentityTombstonesPublishesTombstones(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	log := logger.NewTestLogger()

	now := time.Now()

	armisRows := []map[string]interface{}{
		{
			"device_id": "default:canonical",
			"ip":        "10.0.0.1",
			"metadata": map[string]interface{}{
				"armis_device_id": "ARM-1",
			},
			"key":      "ARM-1",
			"_tp_time": now.Add(time.Minute),
		},
		{
			"device_id": "default:duplicate",
			"ip":        "10.0.0.2",
			"metadata": map[string]interface{}{
				"armis_device_id": "ARM-1",
			},
			"key":      "ARM-1",
			"_tp_time": now,
		},
	}

	gomock.InOrder(
		mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, query string, _ ...interface{}) ([]map[string]interface{}, error) {
			require.Contains(t, query, "armis_device_id")
			return armisRows, nil
		}),
		mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, query string, _ ...interface{}) ([]map[string]interface{}, error) {
			require.Contains(t, query, "integration_type")
			return []map[string]interface{}{}, nil
		}),
	)

	// Should publish tombstone for the duplicate device
	mockDB.EXPECT().PublishBatchDeviceUpdates(gomock.Any(), gomock.Len(1)).DoAndReturn(
		func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Len(t, updates, 1)
			require.Equal(t, "default:duplicate", updates[0].DeviceID)
			require.Equal(t, "default:canonical", updates[0].Metadata["_merged_into"])
			require.False(t, updates[0].IsAvailable)
			return nil
		}).Times(1)

	opts := BackfillOptions{}

	err := BackfillIdentityTombstones(context.Background(), mockDB, log, opts)
	require.NoError(t, err)
}

func TestBackfillIPAliasTombstonesPublishesTombstones(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	log := logger.NewTestLogger()

	canonicalMeta := map[string]interface{}{
		"armis_device_id": "ARM-1",
		"all_ips":         "10.0.0.2",
	}

	canonicalRows := []map[string]interface{}{
		{
			"device_id": "default:canonical",
			"ip":        "10.0.0.1",
			"metadata":  canonicalMeta,
			"_tp_time":  time.Now(),
		},
	}

	gomock.InOrder(
		mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, query string, _ ...interface{}) ([]map[string]interface{}, error) {
			require.Contains(t, query, "metadata")
			return canonicalRows, nil
		}),
		mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, query string, _ ...interface{}) ([]map[string]interface{}, error) {
			require.Contains(t, query, "device_id FROM table(unified_devices)")
			// Return an existing alias device that should be tombstoned
			aliasQueryResult := []map[string]interface{}{{"device_id": "default:10.0.0.2"}}
			return aliasQueryResult, nil
		}),
	)

	// Should publish tombstone for the alias device
	mockDB.EXPECT().PublishBatchDeviceUpdates(gomock.Any(), gomock.Len(1)).DoAndReturn(
		func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Len(t, updates, 1)
			require.Equal(t, "default:10.0.0.2", updates[0].DeviceID)
			require.Equal(t, "default:canonical", updates[0].Metadata["_merged_into"])
			require.False(t, updates[0].IsAvailable)
			return nil
		}).Times(1)

	opts := BackfillOptions{}

	err := BackfillIPAliasTombstones(context.Background(), mockDB, log, opts)
	require.NoError(t, err)
}

func TestBackfillIPAliasTombstonesDryRunDoesNotPublish(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	log := logger.NewTestLogger()

	canonicalMeta := map[string]interface{}{
		"armis_device_id": "ARM-1",
		"all_ips":         "10.0.0.2",
	}

	canonicalRows := []map[string]interface{}{
		{
			"device_id": "default:canonical",
			"ip":        "10.0.0.1",
			"metadata":  canonicalMeta,
			"_tp_time":  time.Now(),
		},
	}

	gomock.InOrder(
		mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, query string, _ ...interface{}) ([]map[string]interface{}, error) {
			require.Contains(t, query, "metadata")
			return canonicalRows, nil
		}),
		mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, query string, _ ...interface{}) ([]map[string]interface{}, error) {
			require.Contains(t, query, "device_id FROM table(unified_devices)")
			aliasQueryResult := []map[string]interface{}{{"device_id": "default:10.0.0.2"}}
			return aliasQueryResult, nil
		}),
	)

	// In dry-run mode, no tombstones should be published
	mockDB.EXPECT().PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).Times(0)

	opts := BackfillOptions{DryRun: true}

	err := BackfillIPAliasTombstones(context.Background(), mockDB, log, opts)
	require.NoError(t, err)
}
