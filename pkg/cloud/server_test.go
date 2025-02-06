package cloud

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/cloud/alerts"
	"github.com/mfreeman451/serviceradar/pkg/cloud/api"
	"github.com/mfreeman451/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func setupAlerter(cooldown time.Duration, setupFunc func(*alerts.WebhookAlerter)) *alerts.WebhookAlerter {
	alerter := alerts.NewWebhookAlerter(alerts.WebhookConfig{
		Enabled:  true,
		Cooldown: cooldown,
	})

	if setupFunc != nil {
		setupFunc(alerter)
	}

	return alerter
}

func TestWebhookAlerter_FirstAlertNoCooldown(t *testing.T) {
	alerter := setupAlerter(time.Minute, nil)
	err := alerter.CheckCooldown("test-node", "Service Failure", "service-1")
	assert.NoError(t, err, "First alert should not be in cooldown")
}

func TestWebhookAlerter_RepeatAlertInCooldown(t *testing.T) {
	alerter := setupAlerter(time.Minute, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("test-node", "Service Failure", "service-1")
	assert.ErrorIs(t, err, alerts.ErrWebhookCooldown, "Repeat alert within cooldown should return error")
}

func TestWebhookAlerter_DifferentNodeSameAlert(t *testing.T) {
	alerter := setupAlerter(time.Minute, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("other-node", "Service Failure", "service-1")
	assert.NoError(t, err, "Different node should not be affected by other node's cooldown")
}

func TestWebhookAlerter_SameNodeDifferentAlert(t *testing.T) {
	alerter := setupAlerter(time.Minute, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("test-node", "Node Recovery", "") // Different title
	assert.NoError(t, err, "Different alert type should not be affected by other alert's cooldown")
}

func TestWebhookAlerter_AfterCooldownPeriod(t *testing.T) {
	alerter := setupAlerter(time.Microsecond, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now().Add(-time.Second)
	})
	err := alerter.CheckCooldown("test-node", "Service Failure", "service-1")
	assert.NoError(t, err, "Alert after cooldown period should not return error")
}

func TestWebhookAlerter_CooldownDisabled(t *testing.T) {
	alerter := setupAlerter(0, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("test-node", "Service Failure", "service-1")
	assert.NoError(t, err, "Alert should not be blocked when cooldown is disabled")
}

func TestWebhookAlerter_SameNodeSameAlertDifferentService(t *testing.T) {
	alerter := setupAlerter(time.Minute, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("test-node", "Service Failure", "service-2") // Different service
	assert.NoError(t, err, "Different service on same node should not be affected by cooldown")
}

func TestWebhookAlerter_SameNodeServiceFailureThenNodeOffline(t *testing.T) {
	alerter := setupAlerter(time.Minute, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("test-node", "Node Offline", "") // Different title, no service
	assert.NoError(t, err, "Node Offline alert should not be blocked by Service Failure cooldown")
}

func TestProcessSweepData(t *testing.T) {
	server := &Server{}
	now := time.Now()

	tests := []struct {
		name          string
		inputMessage  string
		expectedSweep proto.SweepServiceStatus
		expectError   bool
	}{
		{
			name:         "Valid timestamp",
			inputMessage: `{"network": "192.168.1.0/24", "total_hosts": 10, "available_hosts": 5, "last_sweep": 1678886400}`, // Example timestamp
			expectedSweep: proto.SweepServiceStatus{
				Network:        "192.168.1.0/24",
				TotalHosts:     10,
				AvailableHosts: 5,
				LastSweep:      1678886400,
			},
			expectError: false,
		},
		{
			name:         "Invalid timestamp (far future)",
			inputMessage: `{"network": "192.168.1.0/24", "total_hosts": 10, "available_hosts": 5, "last_sweep": 4102444800}`, // 2100-01-01
			expectedSweep: proto.SweepServiceStatus{
				Network:        "192.168.1.0/24",
				TotalHosts:     10,
				AvailableHosts: 5,
				LastSweep:      now.Unix(),
			},
			expectError: false,
		},
		{
			name:         "Invalid JSON",
			inputMessage: `{"network": "192.168.1.0/24", "total_hosts": "invalid", "available_hosts": 5, "last_sweep": 1678886400}`,
			expectError:  true,
		},
	}

	for i := range tests {
		tt := &tests[i] // Correctly get a pointer to the test case
		t.Run(tt.name, func(t *testing.T) {
			svc := &api.ServiceStatus{
				Message: tt.inputMessage,
			}

			err := server.processSweepData(svc, now)

			if tt.expectError {
				assert.Error(t, err)
			} else {
				require.NoError(t, err)

				var sweepData proto.SweepServiceStatus
				err = json.Unmarshal([]byte(svc.Message), &sweepData)
				require.NoError(t, err)

				assert.Equal(t, tt.expectedSweep.Network, sweepData.Network)
				assert.Equal(t, tt.expectedSweep.TotalHosts, sweepData.TotalHosts)
				assert.Equal(t, tt.expectedSweep.AvailableHosts, sweepData.AvailableHosts)

				// For timestamps, compare with a small delta to account for processing time
				if tt.expectedSweep.LastSweep == now.Unix() {
					assert.InDelta(t, tt.expectedSweep.LastSweep, sweepData.LastSweep, 5) // Allow 5 seconds difference
				} else {
					assert.Equal(t, tt.expectedSweep.LastSweep, sweepData.LastSweep)
				}
			}
		})
	}
}
