package core

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	syncpkg "github.com/carverauto/serviceradar/pkg/sync"
	"github.com/carverauto/serviceradar/proto"
)

func TestBackfillIdentityTombstonesSeedKVOnlySkipsPublishing(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockKV := syncpkg.NewMockKVClient(ctrl)
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

	mockDB.EXPECT().PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).Times(0)

	mockKV.EXPECT().Get(gomock.Any(), gomock.Any()).Return(&proto.GetResponse{Found: false}, nil).Times(4)
	mockKV.EXPECT().PutIfAbsent(gomock.Any(), gomock.Any()).Return(&proto.PutResponse{}, nil).Times(4)
	mockKV.EXPECT().Update(gomock.Any(), gomock.Any()).Times(0)

	opts := BackfillOptions{SeedKVOnly: true}

	err := BackfillIdentityTombstones(context.Background(), mockDB, mockKV, log, opts)
	require.NoError(t, err)
}

func TestBackfillIdentityTombstonesPublishesWhenKVOutdated(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockKV := syncpkg.NewMockKVClient(ctrl)
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

	staleRecord := &identitymap.Record{CanonicalDeviceID: "default:stale", Partition: "default", MetadataHash: "stale"}
	stalePayload, err := identitymap.MarshalRecord(staleRecord)
	require.NoError(t, err)

	mockKV.EXPECT().Get(gomock.Any(), gomock.Any()).Return(&proto.GetResponse{Found: true, Revision: 2, Value: stalePayload}, nil).Times(4)
	mockKV.EXPECT().PutIfAbsent(gomock.Any(), gomock.Any()).Times(0)
	mockKV.EXPECT().Update(gomock.Any(), gomock.Any()).Return(&proto.UpdateResponse{}, nil).Times(4)

	mockDB.EXPECT().PublishBatchDeviceUpdates(gomock.Any(), gomock.Len(1)).DoAndReturn(
		func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Len(t, updates, 1)
			require.Equal(t, "default:duplicate", updates[0].DeviceID)
			require.Equal(t, "default:canonical", updates[0].Metadata["_merged_into"])
			return nil
		}).Times(1)

	opts := BackfillOptions{}

	err = BackfillIdentityTombstones(context.Background(), mockDB, mockKV, log, opts)
	require.NoError(t, err)
}

func TestBackfillIPAliasTombstonesSkipsWhenKVCanonical(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockKV := syncpkg.NewMockKVClient(ctrl)
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
	mockDB.EXPECT().PublishBatchDeviceUpdates(gomock.Any(), gomock.Any()).Times(0)

	record := &identitymap.Record{CanonicalDeviceID: "default:canonical", Partition: "default", MetadataHash: identitymap.HashMetadata(map[string]string{"armis_device_id": "ARM-1", "all_ips": "10.0.0.2"})}
	payload, err := identitymap.MarshalRecord(record)
	require.NoError(t, err)

	mockKV.EXPECT().Get(gomock.Any(), gomock.Any()).Return(&proto.GetResponse{Found: true, Value: payload, Revision: 3}, nil).AnyTimes()
	mockKV.EXPECT().PutIfAbsent(gomock.Any(), gomock.Any()).Times(0)
	mockKV.EXPECT().Update(gomock.Any(), gomock.Any()).Times(0)

	opts := BackfillOptions{}

	err = BackfillIPAliasTombstones(context.Background(), mockDB, mockKV, log, opts)
	require.NoError(t, err)
}
