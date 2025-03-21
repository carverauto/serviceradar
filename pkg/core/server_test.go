/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package core

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestNewServer(t *testing.T) {
	tests := []struct {
		name          string
		config        *Config
		expectedError bool
		setupMock     func(*gomock.Controller) db.Service
	}{
		{
			name: "minimal_config",
			config: &Config{
				AlertThreshold: 5 * time.Minute,
				Metrics:        Metrics{Enabled: true, Retention: 100, MaxNodes: 1000},
			},
			setupMock: func(ctrl *gomock.Controller) db.Service {
				return db.NewMockService(ctrl)
			},
		},
		{
			name: "with_webhooks",
			config: &Config{
				AlertThreshold: 5 * time.Minute,
				Webhooks:       []alerts.WebhookConfig{{Enabled: true, URL: "https://example.com/webhook"}},
			},
			setupMock: func(ctrl *gomock.Controller) db.Service {
				return db.NewMockService(ctrl)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := tt.setupMock(ctrl)

			// Override db.New to return the mock
			originalDBNew := dbNew
			dbNew = func(string) (db.Service, error) { return mockDB, nil }
			defer func() { dbNew = originalDBNew }()

			t.Setenv("JWT_SECRET", "test-secret")

			server, err := NewServer(context.Background(), tt.config)
			if tt.expectedError {
				assert.Error(t, err)
				return
			}
			assert.NoError(t, err)
			assert.NotNil(t, server)
			assert.Equal(t, mockDB, server.db) // Should now match
			if tt.name == "with_webhooks" {
				assert.Len(t, server.webhooks, 1)
			}
		})
	}
}

// Mock the db.New function to inject our mock
var dbNew = db.New

func TestProcessStatusReport(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRow := db.NewMockRow(ctrl)
	mockTx := db.NewMockTransaction(ctrl)

	mockDB.EXPECT().QueryRow("SELECT is_healthy FROM nodes WHERE node_id = ?", "test-poller").Return(mockRow)
	mockRow.EXPECT().Scan(gomock.Any()).Return(nil)
	mockDB.EXPECT().Begin().Return(mockTx, nil)
	mockTx.EXPECT().QueryRow("SELECT EXISTS(SELECT 1 FROM nodes WHERE node_id = ?)", "test-poller").Return(mockRow)
	mockRow.EXPECT().Scan(gomock.Any()).Return(nil)
	mockTx.EXPECT().Exec(gomock.Any(), gomock.Any(), gomock.Any(), gomock.Any(), gomock.Any()).Return(nil, nil).Times(2) // Update/Insert + History
	mockTx.EXPECT().Commit().Return(nil)
	mockTx.EXPECT().Rollback().Return(nil).AnyTimes()
	mockDB.EXPECT().UpdateServiceStatus(gomock.Any()).Return(nil)

	server := &Server{
		db:             mockDB,
		alertThreshold: 5 * time.Minute,
		config:         &Config{KnownPollers: []string{"test-poller"}},
	}

	now := time.Now()
	req := &proto.PollerStatusRequest{
		PollerId:  "test-poller",
		Timestamp: now.Unix(),
		Services:  []*proto.ServiceStatus{{ServiceName: "test-service", ServiceType: "process", Available: true, Message: `{"status":"running","pid":1234}`}},
	}

	apiStatus, err := server.processStatusReport(context.Background(), req, now)
	require.NoError(t, err)
	assert.NotNil(t, apiStatus)
}

func TestReportStatus(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRow := db.NewMockRow(ctrl)
	mockTx := db.NewMockTransaction(ctrl)
	mockMetrics := metrics.NewMockMetricCollector(ctrl)
	mockAPI := api.NewMockService(ctrl)

	mockDB.EXPECT().QueryRow("SELECT is_healthy FROM nodes WHERE node_id = ?", gomock.Any()).Return(mockRow).AnyTimes()
	mockRow.EXPECT().Scan(gomock.Any()).Return(nil).AnyTimes()
	mockDB.EXPECT().Begin().Return(mockTx, nil).AnyTimes()
	mockTx.EXPECT().QueryRow(gomock.Any(), gomock.Any()).Return(mockRow).AnyTimes()
	mockRow.EXPECT().Scan(gomock.Any()).Return(nil).AnyTimes()
	mockTx.EXPECT().Exec(gomock.Any(), gomock.Any(), gomock.Any(), gomock.Any(), gomock.Any()).Return(nil, nil).AnyTimes()
	mockTx.EXPECT().Commit().Return(nil).AnyTimes()
	mockTx.EXPECT().Rollback().Return(nil).AnyTimes()
	mockDB.EXPECT().UpdateServiceStatus(gomock.Any()).Return(nil).AnyTimes()
	mockMetrics.EXPECT().AddMetric(gomock.Any(), gomock.Any(), gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	mockAPI.EXPECT().UpdateNodeStatus(gomock.Any(), gomock.Any()).AnyTimes()

	server := &Server{
		db:        mockDB,
		config:    &Config{KnownPollers: []string{"test-poller"}},
		metrics:   mockMetrics,
		apiServer: mockAPI,
	}

	// Test unknown poller
	resp, err := server.ReportStatus(context.Background(), &proto.PollerStatusRequest{PollerId: "unknown-poller"})
	assert.NoError(t, err)
	assert.True(t, resp.Received)

	// Test valid poller
	resp, err = server.ReportStatus(context.Background(), &proto.PollerStatusRequest{
		PollerId:  "test-poller",
		Timestamp: time.Now().Unix(),
		Services:  []*proto.ServiceStatus{{ServiceName: "icmp-service", ServiceType: "icmp", Available: true, Message: `{"host":"192.168.1.1","response_time":10,"packet_loss":0,"available":true}`}},
	})
	assert.NoError(t, err)
	assert.True(t, resp.Received)
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

	for _, tt := range tests {
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

func TestProcessSNMPMetrics(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().StoreMetric(gomock.Any(), gomock.Any()).Return(nil).Times(2)

	server := &Server{
		db: mockDB,
	}

	nodeID := "test-node"
	now := time.Now()

	// Test data
	detailsJSON := `{
		"router.example.com": {
			"available": true,
			"last_poll": "2025-03-20T12:34:56Z",
			"oid_status": {
				"1.3.6.1.2.1.1.3.0": {
					"last_value": 123456789,
					"last_update": "2025-03-20T12:34:56Z",
					"error_count": 0
				},
				"1.3.6.1.2.1.2.2.1.10.1": {
					"last_value": 987654321,
					"last_update": "2025-03-20T12:34:56Z",
					"error_count": 0
				}
			}
		}
	}`

	var details json.RawMessage
	err := json.Unmarshal([]byte(detailsJSON), &details)
	require.NoError(t, err)

	err = server.processSNMPMetrics(nodeID, details, now)
	assert.NoError(t, err)
}

func TestUpdateNodeStatus(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockTx := db.NewMockTransaction(ctrl)
	mockRow := db.NewMockRow(ctrl)

	mockDB.EXPECT().Begin().Return(mockTx, nil)
	mockTx.EXPECT().QueryRow("SELECT EXISTS(SELECT 1 FROM nodes WHERE node_id = ?)", "test-node").Return(mockRow)
	mockRow.EXPECT().Scan(gomock.Any()).Return(nil)
	mockTx.EXPECT().Exec(gomock.Any(), "test-node", gomock.Any(), gomock.Any(), true).Return(nil, nil) // 5 args: query + 4 params
	mockTx.EXPECT().Exec(gomock.Any(), "test-node", gomock.Any(), true).Return(nil, nil)               // History insert
	mockTx.EXPECT().Commit().Return(nil)
	mockTx.EXPECT().Rollback().Return(nil).AnyTimes()

	server := &Server{db: mockDB}
	err := server.updateNodeStatus("test-node", true, time.Now())
	assert.NoError(t, err)
}

func TestHandleNodeRecovery(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockWebhook := alerts.NewMockAlertService(ctrl)
	mockWebhook.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil)

	server := &Server{
		webhooks: []alerts.AlertService{mockWebhook},
	}

	nodeID := "test-node"
	apiStatus := &api.NodeStatus{
		NodeID:     nodeID,
		IsHealthy:  true,
		LastUpdate: time.Now(),
	}

	// No error should be returned
	server.handleNodeRecovery(context.Background(), nodeID, apiStatus, time.Now())
}

func TestHandleNodeDown(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockTx := db.NewMockTransaction(ctrl)
	mockWebhook := alerts.NewMockAlertService(ctrl)
	mockAPI := api.NewMockService(ctrl)
	mockRow := db.NewMockRow(ctrl)

	mockDB.EXPECT().Begin().Return(mockTx, nil)
	mockTx.EXPECT().QueryRow("SELECT EXISTS(SELECT 1 FROM nodes WHERE node_id = ?)", "test-node").Return(mockRow)
	mockRow.EXPECT().Scan(gomock.Any()).Return(nil)
	mockTx.EXPECT().Exec(gomock.Any(), "test-node", gomock.Any(), gomock.Any(), false).Return(nil, nil) // Update/Insert
	mockTx.EXPECT().Exec(gomock.Any(), "test-node", gomock.Any(), false).Return(nil, nil)               // History
	mockTx.EXPECT().Commit().Return(nil)
	mockTx.EXPECT().Rollback().Return(nil).AnyTimes()
	mockWebhook.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil)
	mockAPI.EXPECT().UpdateNodeStatus("test-node", gomock.Any())

	server := &Server{
		db:        mockDB,
		webhooks:  []alerts.AlertService{mockWebhook},
		apiServer: mockAPI,
	}

	err := server.handleNodeDown(context.Background(), "test-node", time.Now().Add(-10*time.Minute))
	assert.NoError(t, err)
}

func TestEvaluateNodeHealth(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockTx := db.NewMockTransaction(ctrl)
	mockWebhook := alerts.NewMockAlertService(ctrl)
	mockAPI := api.NewMockService(ctrl)
	mockRow := db.NewMockRow(ctrl)

	mockDB.EXPECT().Begin().Return(mockTx, nil).AnyTimes()
	mockTx.EXPECT().QueryRow(gomock.Any(), gomock.Any()).Return(mockRow).AnyTimes()
	mockRow.EXPECT().Scan(gomock.Any()).Return(nil).AnyTimes()
	mockTx.EXPECT().Exec(gomock.Any(), "test-node", gomock.Any(), gomock.Any(), false).Return(nil, nil).AnyTimes()
	mockTx.EXPECT().Exec(gomock.Any(), "test-node", gomock.Any(), false).Return(nil, nil).AnyTimes()
	mockTx.EXPECT().Commit().Return(nil).AnyTimes()
	mockTx.EXPECT().Rollback().Return(nil).AnyTimes()
	mockWebhook.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	mockAPI.EXPECT().UpdateNodeStatus(gomock.Any(), gomock.Any()).AnyTimes()
	mockDB.EXPECT().QueryRow("SELECT is_healthy FROM nodes WHERE node_id = ?", "test-node").Return(mockRow).AnyTimes()

	server := &Server{
		db:        mockDB,
		webhooks:  []alerts.AlertService{mockWebhook},
		apiServer: mockAPI,
	}

	now := time.Now()
	threshold := now.Add(-5 * time.Minute)

	err := server.evaluateNodeHealth(context.Background(), "test-node", now.Add(-10*time.Minute), true, threshold)
	assert.NoError(t, err)
}

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
