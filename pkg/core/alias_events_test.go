package core

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

func TestBuildAliasLifecycleEvents_NewAlias(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	server := &Server{
		DB:     mockDB,
		logger: logger.NewTestLogger(),
	}

	deviceID := "default:10.0.0.5"
	timestamp := time.Date(2025, 11, 3, 15, 0, 0, 0, time.UTC)

	update := &models.DeviceUpdate{
		DeviceID:  deviceID,
		Partition: "default",
		Timestamp: timestamp,
		Metadata: map[string]string{
			"_alias_last_seen_at":                  timestamp.Format(time.RFC3339Nano),
			"_alias_last_seen_service_id":          "serviceradar:agent:new",
			"_alias_last_seen_ip":                  "10.0.0.5",
			"service_alias:serviceradar:agent:new": timestamp.Format(time.RFC3339Nano),
			"ip_alias:10.0.0.5":                    timestamp.Format(time.RFC3339Nano),
		},
	}

	existingMetadata := map[string]string{
		"_alias_last_seen_service_id": "serviceradar:agent:old",
		"_alias_last_seen_at":         timestamp.Add(-time.Hour).Format(time.RFC3339Nano),
	}

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Nil(), []string{deviceID}).
		Return([]*models.UnifiedDevice{
			{
				DeviceID: deviceID,
				Metadata: &models.DiscoveredField[map[string]string]{Value: existingMetadata},
			},
		}, nil)

	events, err := server.buildAliasLifecycleEvents(context.Background(), []*models.DeviceUpdate{update})
	require.NoError(t, err)
	require.Len(t, events, 1)

	event := events[0]
	assert.Equal(t, "alias_updated", event.Action)
	assert.Equal(t, "alias_change", event.Reason)
	assert.Equal(t, deviceID, event.DeviceID)
	assert.Equal(t, "serviceradar:agent:new", event.Metadata["alias_current_service_id"])
	assert.Equal(t, "serviceradar:agent:old", event.Metadata["previous_service_id"])
	assert.Equal(t, "Low", event.Severity)
	assert.Equal(t, int32(6), event.Level)
}

func TestBuildAliasLifecycleEvents_NoChange(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	server := &Server{
		DB:     mockDB,
		logger: logger.NewTestLogger(),
	}

	deviceID := "default:10.0.0.5"
	timestamp := time.Date(2025, 11, 3, 16, 0, 0, 0, time.UTC)

	update := &models.DeviceUpdate{
		DeviceID:  deviceID,
		Partition: "default",
		Timestamp: timestamp,
		Metadata: map[string]string{
			"_alias_last_seen_at":                  timestamp.Format(time.RFC3339Nano),
			"_alias_last_seen_service_id":          "serviceradar:agent:new",
			"_alias_last_seen_ip":                  "10.0.0.5",
			"service_alias:serviceradar:agent:new": timestamp.Format(time.RFC3339Nano),
			"ip_alias:10.0.0.5":                    timestamp.Format(time.RFC3339Nano),
		},
	}

	existingMetadata := map[string]string{
		"_alias_last_seen_service_id": "serviceradar:agent:new",
		"_alias_last_seen_ip":         "10.0.0.5",
	}

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Nil(), []string{deviceID}).
		Return([]*models.UnifiedDevice{
			{
				DeviceID: deviceID,
				Metadata: &models.DiscoveredField[map[string]string]{Value: existingMetadata},
			},
		}, nil)

	events, err := server.buildAliasLifecycleEvents(context.Background(), []*models.DeviceUpdate{update})
	require.NoError(t, err)
	assert.Empty(t, events)
}
