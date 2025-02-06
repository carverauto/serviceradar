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

func TestWebhookAlerter_CheckCooldown(t *testing.T) {
	tests := []struct {
		name        string
		nodeID      string
		alertTitle  string
		cooldown    time.Duration
		setupFunc   func(*alerts.WebhookAlerter)
		wantError   error
		description string
	}{
		{
			name:        "first_alert_no_cooldown",
			nodeID:      "test-node",
			alertTitle:  "Service Failure",
			cooldown:    time.Minute,
			wantError:   nil,
			description: "First alert should not be in cooldown",
		},
		{
			name:       "repeat_alert_in_cooldown",
			nodeID:     "test-node",
			alertTitle: "Service Failure",
			cooldown:   time.Minute,
			setupFunc: func(w *alerts.WebhookAlerter) {
				key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure"}
				w.LastAlertTimes[key] = time.Now()
			},
			wantError:   alerts.ErrWebhookCooldown,
			description: "Repeat alert within cooldown period should return error",
		},
		{
			name:       "different_node_same_alert",
			nodeID:     "other-node",
			alertTitle: "Service Failure",
			cooldown:   time.Minute,
			setupFunc: func(w *alerts.WebhookAlerter) {
				key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure"}
				w.LastAlertTimes[key] = time.Now()
			},
			wantError:   nil,
			description: "Different node should not be affected by other node's cooldown",
		},
		{
			name:       "same_node_different_alert",
			nodeID:     "test-node",
			alertTitle: "Node Recovery",
			cooldown:   time.Minute,
			setupFunc: func(w *alerts.WebhookAlerter) {
				key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure"}
				w.LastAlertTimes[key] = time.Now()
			},
			wantError:   nil,
			description: "Different alert type should not be affected by other alert's cooldown",
		},
		{
			name:       "after_cooldown_period",
			nodeID:     "test-node",
			alertTitle: "Service Failure",
			cooldown:   time.Microsecond,
			setupFunc: func(w *alerts.WebhookAlerter) {
				key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure"}
				w.LastAlertTimes[key] = time.Now().Add(-time.Second)
			},
			wantError:   nil,
			description: "Alert after cooldown period should not return error",
		},
		{
			name:       "cooldown_disabled",
			nodeID:     "test-node",
			alertTitle: "Service Failure",
			cooldown:   0,
			setupFunc: func(w *alerts.WebhookAlerter) {
				key := alerts.AlertKey{NodeID: "test-node", Title: "Service Failure"}
				w.LastAlertTimes[key] = time.Now()
			},
			wantError:   nil,
			description: "Alert should not be blocked when cooldown is disabled",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			alerter := alerts.NewWebhookAlerter(alerts.WebhookConfig{
				Enabled:  true,
				Cooldown: tt.cooldown,
			})

			if tt.setupFunc != nil {
				tt.setupFunc(alerter)
			}

			err := alerter.CheckCooldown(tt.nodeID, tt.alertTitle)

			if tt.wantError != nil {
				assert.ErrorIs(t, err, tt.wantError, tt.description)
			} else {
				assert.NoError(t, err, tt.description)
			}
		})
	}
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
