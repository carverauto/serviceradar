package registry

import (
	"context"
	"errors"
	"testing"
	"time"

	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var errHydrateTestBoom = errors.New("boom")

func TestHydrateFromStoreLoadsDevices(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().WithTx(gomock.Any(), gomock.Any()).DoAndReturn(func(ctx context.Context, fn func(db.Service) error) error {
		return fn(mockDB)
	}).AnyTimes()
	mockDB.EXPECT().LockOCSFDevices(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	reg := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	first := time.Unix(1700000000, 0).UTC()
	last := first.Add(5 * time.Minute)
	isAvailable := true

	batch := []*models.OCSFDevice{
		{
			UID:              "device-1",
			IP:               "10.0.0.10",
			FirstSeenTime:    &first,
			LastSeenTime:     &last,
			IsAvailable:      &isAvailable,
			AgentID:          "agent-1",
			PollerID:         "poller-1",
			DiscoverySources: []string{string(models.DiscoverySourceSweep)},
		},
		{
			UID:              "device-2",
			IP:               "10.0.0.20",
			FirstSeenTime:    &first,
			LastSeenTime:     &last,
			AgentID:          "agent-2",
			PollerID:         "poller-2",
			DiscoverySources: []string{string(models.DiscoverySourceNetbox)},
		},
	}

	mockDB.EXPECT().
		ListOCSFDevices(gomock.Any(), hydrateBatchSize, 0).
		Return(batch, nil)

	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]any{}, nil)

	mockDB.EXPECT().
		CountOCSFDevices(gomock.Any()).
		Return(int64(len(batch)), nil)

	count, err := reg.HydrateFromStore(context.Background())
	if err != nil {
		t.Fatalf("hydrate returned error: %v", err)
	}
	if count != len(batch) {
		t.Fatalf("expected %d records, got %d", len(batch), count)
	}

	for _, device := range batch {
		if got, ok := reg.GetDeviceRecord(device.UID); !ok || got == nil {
			t.Fatalf("expected device %s in registry", device.UID)
		}
	}
}

func TestHydrateFromStorePreservesExistingStateOnError(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().WithTx(gomock.Any(), gomock.Any()).DoAndReturn(func(ctx context.Context, fn func(db.Service) error) error {
		return fn(mockDB)
	}).AnyTimes()
	mockDB.EXPECT().LockOCSFDevices(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	reg := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	existing := &DeviceRecord{
		DeviceID: "existing-device",
		IP:       "10.0.0.5",
		LastSeen: time.Now(),
	}
	reg.UpsertDeviceRecord(existing)

	mockDB.EXPECT().
		ListOCSFDevices(gomock.Any(), hydrateBatchSize, 0).
		Return(nil, errHydrateTestBoom)

	if _, err := reg.HydrateFromStore(context.Background()); err == nil {
		t.Fatalf("expected error from hydration")
	}

	if _, ok := reg.GetDeviceRecord("existing-device"); !ok {
		t.Fatalf("expected existing device to remain after failed hydration")
	}
}

func TestHydrateFromStoreHonorsContextCancellation(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().WithTx(gomock.Any(), gomock.Any()).DoAndReturn(func(ctx context.Context, fn func(db.Service) error) error {
		return fn(mockDB)
	}).AnyTimes()
	mockDB.EXPECT().LockOCSFDevices(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	reg := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, err := reg.HydrateFromStore(ctx); err == nil {
		t.Fatalf("expected cancellation error")
	}
}
