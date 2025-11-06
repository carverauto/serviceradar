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

func TestHydrateFromStoreLoadsDevices(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	reg := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	first := time.Unix(1700000000, 0).UTC()
	last := first.Add(5 * time.Minute)

	batch := []*models.UnifiedDevice{
		{
			DeviceID:    "device-1",
			IP:          "10.0.0.10",
			FirstSeen:   first,
			LastSeen:    last,
			IsAvailable: true,
			DiscoverySources: []models.DiscoverySourceInfo{
				{
					Source:     models.DiscoverySourceSweep,
					AgentID:    "agent-1",
					PollerID:   "poller-1",
					Confidence: 5,
					LastSeen:   last,
				},
			},
		},
		{
			DeviceID:  "device-2",
			IP:        "10.0.0.20",
			FirstSeen: first,
			LastSeen:  last,
			DiscoverySources: []models.DiscoverySourceInfo{
				{
					Source:     models.DiscoverySourceNetbox,
					AgentID:    "agent-2",
					PollerID:   "poller-2",
					Confidence: 7,
					LastSeen:   last,
				},
			},
		},
	}

	mockDB.EXPECT().
		ListUnifiedDevices(gomock.Any(), hydrateBatchSize, 0).
		Return(batch, nil)

	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]any{}, nil)

	mockDB.EXPECT().
		CountUnifiedDevices(gomock.Any()).
		Return(int64(len(batch)), nil)

	count, err := reg.HydrateFromStore(context.Background())
	if err != nil {
		t.Fatalf("hydrate returned error: %v", err)
	}
	if count != len(batch) {
		t.Fatalf("expected %d records, got %d", len(batch), count)
	}

	for _, device := range batch {
		if got, ok := reg.GetDeviceRecord(device.DeviceID); !ok || got == nil {
			t.Fatalf("expected device %s in registry", device.DeviceID)
		}
	}
}

func TestHydrateFromStorePreservesExistingStateOnError(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	reg := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	existing := &DeviceRecord{
		DeviceID: "existing-device",
		IP:       "10.0.0.5",
		LastSeen: time.Now(),
	}
	reg.UpsertDeviceRecord(existing)

	mockDB.EXPECT().
		ListUnifiedDevices(gomock.Any(), hydrateBatchSize, 0).
		Return(nil, errors.New("boom"))

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
	reg := NewDeviceRegistry(mockDB, logger.NewTestLogger())

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, err := reg.HydrateFromStore(ctx); err == nil {
		t.Fatalf("expected cancellation error")
	}
}
