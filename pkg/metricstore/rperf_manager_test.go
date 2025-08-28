package metricstore

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestRperfManager_StoreAndGetRperfMetric(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	// Set up expectation for StoreMetrics
	mockDB.EXPECT().StoreMetrics(
		gomock.Any(),  // Context
		"test-poller", // PollerID
		gomock.Any(),  // Slice of TimeseriesMetric
	).Return(nil).Times(1)

	// Set up expectation for GetMetricsByType
	mockDB.EXPECT().GetMetricsByType(
		gomock.Any(),  // Context
		"test-poller", // PollerID
		"rperf",       // Metric type
		gomock.Any(),  // Start time
		gomock.Any(),  // End time
	).Return([]models.TimeseriesMetric{ // Note: Use []models.TimeseriesMetric, not []*models.TimeseriesMetric
		{
			Name:           "rperf_test-target_bandwidth_mbps",
			Value:          "1.00",
			Type:           "rperf",
			Timestamp:      time.Now(),
			Metadata:       `{"target":"test-target","success":true,"bits_per_second":1000000,"jitter_ms":5.0,"loss_percent":0.1}`,
			TargetDeviceIP: "", // Optional, depending on your use case
			IfIndex:        0,  // Optional
		},
	}, nil).Times(1)

	manager := NewRperfManager(mockDB)
	metric := &models.RperfMetric{
		Target:      "test-target",
		Success:     true,
		BitsPerSec:  1000000,
		JitterMs:    5.0,
		LossPercent: 0.1,
	}

	err := manager.StoreRperfMetric(context.Background(), "test-poller", metric, time.Now())
	require.NoError(t, err)

	metrics, err := manager.GetRperfMetrics(context.Background(), "test-poller", time.Now().Add(-1*time.Hour), time.Now())
	require.NoError(t, err)
	assert.NotEmpty(t, metrics)
	assert.Equal(t, "test-target", metrics[0].Target)
}
