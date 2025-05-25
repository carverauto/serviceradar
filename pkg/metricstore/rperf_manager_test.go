package metricstore

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

func TestRperfManager_StoreAndGetRperfMetric(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

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
