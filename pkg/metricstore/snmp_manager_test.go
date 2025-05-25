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

/*
func TestSNMPManager_GetSNMPMetrics(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	manager := NewSNMPManager(mockDB)
	// Insert test data
	tsMetric := &models.TimeseriesMetric{
		Name:      "sysUpTime",
		Type:      "snmp",
		Value:     "12345",
		Timestamp: time.Now(),
		Metadata:  `{"scale":2.0,"is_delta":true}`,
	}


	err := db.StoreMetric(context.Background(), "test-poller", tsMetric)
	assert.NoError(t, err)

	metrics, err := manager.GetSNMPMetrics(context.Background(), "test-poller", time.Now().Add(-1*time.Hour), time.Now())
	assert.NoError(t, err)
	assert.NotEmpty(t, metrics)
	assert.Equal(t, 2.0, metrics[0].Scale)
	assert.True(t, metrics[0].IsDelta)
}


*/
