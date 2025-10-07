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

func TestSNMPManager_StoreSNMPMetric(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	manager := NewSNMPManager(mockDB)
	metric := &models.SNMPMetric{
		OIDName:   "sysUpTime",
		Value:     12345,
		ValueType: "integer",
		Timestamp: time.Now(),
		Scale:     2.0,
		IsDelta:   true,
	}

	// Set up expectation for StoreMetric
	mockDB.EXPECT().StoreMetric(
		gomock.Any(),  // Context
		"test-poller", // PollerID
		gomock.Any(),  // TimeseriesMetric (use Any for simplicity, or match specific fields)
	).Return(nil).Times(1)

	// Test valid metric
	err := manager.StoreSNMPMetric(context.Background(), "test-poller", metric, time.Now())
	require.NoError(t, err)

	// Test invalid metric
	err = manager.StoreSNMPMetric(context.Background(), "test-poller", nil, time.Now())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "SNMP metric is nil")

	// Test empty OIDName
	metric.OIDName = ""
	err = manager.StoreSNMPMetric(context.Background(), "test-poller", metric, time.Now())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "OIDName is empty")
}
