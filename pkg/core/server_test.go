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

// Package core pkg/core/server_test.go
package core

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/otel"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/metricstore"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
)

func TestNewServer(t *testing.T) {
	tests := []struct {
		name          string
		config        *models.CoreServiceConfig
		expectedError bool
		setupMock     func(*gomock.Controller) db.Service
	}{
		{
			name: "minimal_config",
			config: &models.CoreServiceConfig{
				AlertThreshold: 5 * time.Minute,
				Metrics: models.Metrics{
					Enabled:    true,
					Retention:  100,
					MaxGateways: 1000,
				},
				DBPath: "", // Will be overridden in the test
			},
			setupMock: func(ctrl *gomock.Controller) db.Service {
				return db.NewMockService(ctrl)
			},
		},
		{
			name: "with_webhooks",
			config: &models.CoreServiceConfig{
				AlertThreshold: 5 * time.Minute,
				Webhooks: []alerts.WebhookConfig{
					{Enabled: true, URL: "https://example.com/webhook"},
				},
				DBPath: "", // Will be overridden in the test
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

			// Set JWT_SECRET before calling newServerWithDB
			t.Setenv("JWT_SECRET", "test-secret")

			// Use a temporary directory for DBPath to avoid permission issues
			tempDir := t.TempDir()
			tt.config.DBPath = tempDir + "/serviceradar.db"

			server, err := newServerWithDB(context.Background(), tt.config, mockDB)
			if tt.expectedError {
				assert.Error(t, err)
				return
			}

			require.NoError(t, err, "Expected no error from newServerWithDB")
			assert.NotNil(t, server, "Expected server to be non-nil")
			assert.Equal(t, mockDB, server.DB, "Expected server.db to be the mockDB")

			if tt.name == "with_webhooks" {
				assert.Len(t, server.webhooks, 1)
				assert.Equal(t, "https://example.com/webhook",
					server.webhooks[0].(*alerts.WebhookAlerter).Config.URL)
			}
		})
	}
}

func newServerWithDB(_ context.Context, config *models.CoreServiceConfig, database db.Service) (*Server, error) {
	normalizedConfig := normalizeConfig(config)
	metricsManager := metrics.NewManager(models.MetricsConfig{
		Enabled:    normalizedConfig.Metrics.Enabled,
		Retention:  normalizedConfig.Metrics.Retention,
		MaxGateways: normalizedConfig.Metrics.MaxGateways,
	}, database, logger.NewTestLogger())

	dbPath := getDBPath(normalizedConfig.DBPath)
	if err := ensureDataDirectory(dbPath); err != nil {
		return nil, fmt.Errorf("failed to create data directory: %w", err)
	}

	authConfig, err := initializeAuthConfig(normalizedConfig)
	if err != nil {
		return nil, err
	}

	server := &Server{
		DB:                  database,
		alertThreshold:      normalizedConfig.AlertThreshold,
		webhooks:            make([]alerts.AlertService, 0),
		ShutdownChan:        make(chan struct{}),
		gatewayPatterns:      normalizedConfig.GatewayPatterns,
		metrics:             metricsManager,
		snmpManager:         metricstore.NewSNMPManager(database),
		config:              normalizedConfig,
		authService:         auth.NewAuth(authConfig, database),
		metricBuffers:       make(map[string][]*models.TimeseriesMetric),
		serviceBuffers:      make(map[string][]*models.ServiceStatus),
		serviceListBuffers:  make(map[string][]*models.Service),
		sysmonBuffers:       make(map[string][]*sysmonMetricBuffer),
		gatewayStatusCache:   make(map[string]*models.GatewayStatus),
		gatewayStatusUpdates: make(map[string]*models.GatewayStatus),
		logger:              logger.NewTestLogger(),
		tracer:              otel.Tracer("serviceradar-core-test"),
	}

	server.initializeWebhooks(normalizedConfig.Webhooks)

	return server, nil
}

func TestReportStatus(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockAPI := api.NewMockService(ctrl)

	metricsManager := metrics.NewManager(models.MetricsConfig{
		Enabled:    true,
		Retention:  100,
		MaxGateways: 1000,
	}, mockDB, logger.NewTestLogger())

	mockDB.EXPECT().GetGatewayStatus(gomock.Any(), "test-gateway").Return(&models.GatewayStatus{
		GatewayID:  "test-gateway",
		IsHealthy: true,
		FirstSeen: time.Now().Add(-1 * time.Hour),
		LastSeen:  time.Now(),
	}, nil).AnyTimes()

	mockDB.EXPECT().UpdateGatewayStatus(
		gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, status *models.GatewayStatus) error {
		assert.Equal(t, "test-gateway", status.GatewayID)
		assert.True(t, status.IsHealthy)
		return nil
	}).AnyTimes()

	mockDB.EXPECT().UpdateServiceStatuses(
		gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, statuses []*models.ServiceStatus) error {
		t.Logf("TestReportStatus: UpdateServiceStatuses called with %d statuses: %+v", len(statuses), statuses)
		return nil
	}).AnyTimes()

	mockDB.EXPECT().StoreServices(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, services []*models.Service) error {
		t.Logf("StoreServices called with %d services", len(services))
		return nil
	}).AnyTimes()

	// Mock ExecuteQuery for device lookup
	mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).Return([]map[string]interface{}{}, nil).AnyTimes()
	mockDB.EXPECT().GetOCSFDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).Return([]*models.OCSFDevice{}, nil).AnyTimes()

	// Mock GetDeviceByID for device lookup
	mockDB.EXPECT().GetDeviceByID(gomock.Any(), gomock.Any()).Return(nil, nil).AnyTimes()

	// Mock UpsertOCSFAgent for agent registration
	mockDB.EXPECT().UpsertOCSFAgent(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()

	// Expect StoreMetrics for icmp-service
	mockDB.EXPECT().StoreMetrics(gomock.Any(), "test-gateway",
		gomock.Any()).DoAndReturn(func(_ context.Context, gatewayID string, metrics []*models.TimeseriesMetric) error {
		t.Logf("TestReportStatus: StoreMetrics called for gateway %s with %d metrics", gatewayID, len(metrics))
		return nil
	}).AnyTimes()

	mockAPI.EXPECT().UpdateGatewayStatus(gomock.Any(), gomock.Any()).AnyTimes()

	server := &Server{
		DB:                  mockDB,
		config:              &models.CoreServiceConfig{KnownGateways: []string{"test-gateway"}},
		metrics:             metricsManager,
		apiServer:           mockAPI,
		metricBuffers:       make(map[string][]*models.TimeseriesMetric),
		serviceBuffers:      make(map[string][]*models.ServiceStatus),
		serviceListBuffers:  make(map[string][]*models.Service),
		sysmonBuffers:       make(map[string][]*sysmonMetricBuffer),
		gatewayStatusCache:   make(map[string]*models.GatewayStatus),
		gatewayStatusUpdates: make(map[string]*models.GatewayStatus),
		logger:              logger.NewTestLogger(),
		tracer:              otel.Tracer("serviceradar-core-test"),
	}

	// Test unknown gateway
	server.serviceBufferMu.Lock()
	server.serviceBuffers = make(map[string][]*models.ServiceStatus)
	server.serviceBufferMu.Unlock()
	server.serviceListBufferMu.Lock()
	server.serviceListBuffers = make(map[string][]*models.Service)
	server.serviceListBufferMu.Unlock()
	t.Logf("TestReportStatus: serviceBuffers before unknown-gateway: %+v", server.serviceBuffers)

	resp, err := server.ReportStatus(context.Background(), &proto.GatewayStatusRequest{
		GatewayId:  "unknown-gateway",
		Partition: "test-partition",
		SourceIp:  "192.168.1.100",
	})
	require.NoError(t, err)
	assert.NotNil(t, resp)
	assert.True(t, resp.Received)

	server.flushAllBuffers(context.Background())
	server.serviceBufferMu.Lock()
	server.serviceBuffers = make(map[string][]*models.ServiceStatus)
	server.serviceBufferMu.Unlock()
	server.serviceListBufferMu.Lock()
	server.serviceListBuffers = make(map[string][]*models.Service)
	server.serviceListBufferMu.Unlock()
	t.Logf("TestReportStatus: serviceBuffers after unknown-gateway: %+v", server.serviceBuffers)

	// Test valid gateway with ICMP service
	server.serviceBufferMu.Lock()
	server.serviceBuffers = make(map[string][]*models.ServiceStatus)
	server.serviceBufferMu.Unlock()
	server.serviceListBufferMu.Lock()
	server.serviceListBuffers = make(map[string][]*models.Service)
	server.serviceListBufferMu.Unlock()
	t.Logf("TestReportStatus: serviceBuffers before test-gateway: %+v", server.serviceBuffers)

	icmpMessage := `{"host":"192.168.1.1","response_time":10,"packet_loss":0,"available":true}`
	resp, err = server.ReportStatus(context.Background(), &proto.GatewayStatusRequest{
		GatewayId:  "test-gateway",
		Timestamp: time.Now().Unix(),
		Partition: "test-partition",
		SourceIp:  "192.168.1.100",
		Services: []*proto.ServiceStatus{
			{
				ServiceName: "icmp-service",
				ServiceType: "icmp",
				Available:   true,
				Message:     []byte(icmpMessage), // Convert string to []byte
				AgentId:     "test-agent",
			},
		},
	})
	require.NoError(t, err)
	assert.NotNil(t, resp)
	assert.True(t, resp.Received)

	server.flushAllBuffers(context.Background())
	server.serviceBufferMu.Lock()
	server.serviceBuffers = make(map[string][]*models.ServiceStatus)
	server.serviceBufferMu.Unlock()
	server.serviceListBufferMu.Lock()
	server.serviceListBuffers = make(map[string][]*models.Service)
	server.serviceListBufferMu.Unlock()
	t.Logf("TestReportStatus: serviceBuffers after test-gateway: %+v", server.serviceBuffers)
}

// getSweepTestCases returns test cases for TestProcessSweepData
func getSweepTestCases(now time.Time) []struct {
	name          string
	inputMessage  string
	expectedSweep proto.SweepServiceStatus
	expectError   bool
	hasHosts      bool // Indicates if the input includes hosts
} {
	return []struct {
		name          string
		inputMessage  string
		expectedSweep proto.SweepServiceStatus
		expectError   bool
		hasHosts      bool
	}{
		{
			name:         "Valid timestamp",
			inputMessage: `{"network": "192.168.1.0/24", "total_hosts": 10, "available_hosts": 5, "last_sweep": 1678886400}`,
			expectedSweep: proto.SweepServiceStatus{
				Network:        "192.168.1.0/24",
				TotalHosts:     10,
				AvailableHosts: 5,
				LastSweep:      1678886400,
			},
			expectError: false,
			hasHosts:    false,
		},
		{
			name:         "Invalid timestamp (far future)",
			inputMessage: `{"network": "192.168.1.0/24", "total_hosts": 10, "available_hosts": 5, "last_sweep": 4102444800}`,
			expectedSweep: proto.SweepServiceStatus{
				Network:        "192.168.1.0/24",
				TotalHosts:     10,
				AvailableHosts: 5,
				LastSweep:      now.Unix(),
			},
			expectError: false,
			hasHosts:    false,
		},
		{
			name: "Valid timestamp with hosts",
			inputMessage: `{
"network": "192.168.1.0/24", "total_hosts": 10, "available_hosts": 5,
"last_sweep": 1678886400, "hosts": [{"host": "192.168.1.1", "available": true,
"mac": "00:11:22:33:44:55", "hostname": "host1"}]}`,
			expectedSweep: proto.SweepServiceStatus{
				Network:        "192.168.1.0/24",
				TotalHosts:     10,
				AvailableHosts: 5,
				LastSweep:      1678886400,
			},
			expectError: false,
			hasHosts:    true,
		},
		{
			name:         "Invalid JSON",
			inputMessage: `{"network": "192.168.1.0/24", "total_hosts": "invalid", "available_hosts": 5, "last_sweep": 1678886400}`,
			expectError:  true,
			hasHosts:     false,
		},
	}
}

func TestProcessSweepData(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDeviceRegistry := registry.NewMockManager(ctrl)

	mockDeviceRegistry.EXPECT().
		SetDeviceCapabilitySnapshot(gomock.Any(), gomock.AssignableToTypeOf(&models.DeviceCapabilitySnapshot{})).
		AnyTimes()
	mockDeviceRegistry.EXPECT().
		GetDevicesByIP(gomock.Any(), gomock.Any()).
		Return([]*models.OCSFDevice{}, nil).
		AnyTimes()

	server := &Server{
		DB:             mockDB,
		DeviceRegistry: mockDeviceRegistry,
		logger:         logger.NewTestLogger(),
		tracer:         otel.Tracer("serviceradar-core-test"),
	}
	now := time.Now()
	ctx := context.Background()
	tests := getSweepTestCases(now)

	mockDB.EXPECT().
		GetOCSFDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]*models.OCSFDevice{}, nil).
		AnyTimes()

	for i := range tests {
		t.Run(tests[i].name, func(t *testing.T) {
			tt := &tests[i]
			svc := &api.ServiceStatus{
				Message: []byte(tt.inputMessage), // Convert string to []byte
			}

			// Set up mock expectation for ProcessBatchSightings only when hosts are present
			if !tt.expectError && tt.hasHosts {
				mockDeviceRegistry.EXPECT().ProcessBatchDeviceUpdates(gomock.Any(), gomock.Any()).DoAndReturn(
					func(_ context.Context, results []*models.DeviceUpdate) error {
						if tt.name == "Valid timestamp with hosts" {
							assert.Len(t, results, 1, "Expected one sweep result")
							assert.Equal(t, "192.168.1.1", results[0].IP, "Expected correct IP")
							assert.Nil(t, results[0].MAC, "MAC should be nil for HostResult-based sweep results")
							assert.Nil(t, results[0].Hostname, "Hostname should be nil for HostResult-based sweep results")
							assert.True(t, results[0].IsAvailable, "Expected host to be available")
						}

						return nil
					})
			}

			verifySweepTestCase(ctx, t, server, svc, tt, now)
		})
	}
}

// verifySweepTestCase verifies a single test case for TestProcessSweepData
func verifySweepTestCase(ctx context.Context, t *testing.T, server *Server, svc *api.ServiceStatus,
	tt *struct {
		name          string
		inputMessage  string
		expectedSweep proto.SweepServiceStatus
		expectError   bool
		hasHosts      bool
	}, now time.Time) {
	t.Helper()

	err := server.processSweepData(ctx, svc, "default", now)
	if tt.expectError {
		assert.Error(t, err)
		return
	}

	require.NoError(t, err)

	var sweepData proto.SweepServiceStatus

	err = json.Unmarshal(svc.Message, &sweepData)
	require.NoError(t, err)

	assert.Equal(t, tt.expectedSweep.Network, sweepData.Network)
	assert.Equal(t, tt.expectedSweep.TotalHosts, sweepData.TotalHosts)
	assert.Equal(t, tt.expectedSweep.AvailableHosts, sweepData.AvailableHosts)

	if tt.expectedSweep.LastSweep == now.Unix() {
		assert.InDelta(t, tt.expectedSweep.LastSweep, sweepData.LastSweep, 5)
	} else {
		assert.Equal(t, tt.expectedSweep.LastSweep, sweepData.LastSweep)
	}
}

func TestProcessSNMPMetrics(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	// Expect StoreMetrics to be called once with two metrics
	mockDB.EXPECT().StoreMetrics(gomock.Any(), gomock.Eq("test-gateway"), gomock.Len(2)).Return(nil)
	mockDB.EXPECT().PublishDeviceUpdate(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()

	server := &Server{
		DB:            mockDB,
		metricBuffers: make(map[string][]*models.TimeseriesMetric),
		logger:        logger.NewTestLogger(),
		tracer:        otel.Tracer("serviceradar-core-test"),
	}

	gatewayID := testGatewayID
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

	err = server.processSNMPMetrics(
		context.Background(), gatewayID, "test-partition", "127.0.0.1", "test-agent", details, now)
	require.NoError(t, err)

	// Trigger flush to store buffered metrics
	server.flushAllBuffers(context.Background())
}

func TestUpdateGatewayStatus(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	// Mock GetGatewayStatus to simulate existing gateway
	mockDB.EXPECT().GetGatewayStatus(gomock.Any(), "test-gateway").Return(&models.GatewayStatus{
		GatewayID:  "test-gateway",
		IsHealthy: true,
		FirstSeen: time.Now().Add(-1 * time.Hour),
		LastSeen:  time.Now(),
	}, nil)

	// Mock UpdateGatewayStatus
	mockDB.EXPECT().UpdateGatewayStatus(gomock.Any(), gomock.Any()).Return(nil)

	server := &Server{
		DB:                  mockDB,
		gatewayStatusUpdates: make(map[string]*models.GatewayStatus),
		logger:              logger.NewTestLogger(),
		tracer:              otel.Tracer("serviceradar-core-test"),
	}

	err := server.updateGatewayStatus(context.Background(), "test-gateway", true, time.Now())
	assert.NoError(t, err)
}

func TestHandleGatewayRecovery(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockWebhook := alerts.NewMockAlertService(ctrl)
	mockWebhook.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil)

	server := &Server{
		webhooks: []alerts.AlertService{mockWebhook},
		logger:   logger.NewTestLogger(),
		tracer:   otel.Tracer("serviceradar-core-test"),
	}

	gatewayID := testGatewayID
	apiStatus := &api.GatewayStatus{
		GatewayID:   gatewayID,
		IsHealthy:  true,
		LastUpdate: time.Now(),
	}

	server.handleGatewayRecovery(context.Background(), gatewayID, apiStatus, time.Now(), nil)
}

func TestHandleGatewayDown(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping gateway down test in short mode")
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockAlerter := alerts.NewMockAlertService(ctrl)

	server := &Server{
		DB:                      mockDB,
		webhooks:                []alerts.AlertService{mockAlerter},
		gatewayStatusCache:       make(map[string]*models.GatewayStatus),
		gatewayStatusUpdates:     make(map[string]*models.GatewayStatus),
		ShutdownChan:            make(chan struct{}),
		cacheMutex:              sync.RWMutex{},
		gatewayStatusUpdateMutex: sync.Mutex{},
		logger:                  logger.NewTestLogger(),
		tracer:                  otel.Tracer("serviceradar-core-test"),
	}
	server.gatewayStatusInterval = 10 * time.Millisecond

	gatewayID := testGatewayID
	lastSeen := time.Now().Add(-10 * time.Minute)
	firstSeen := lastSeen.Add(-1 * time.Hour)

	// Set up gateway status cache
	server.gatewayStatusCache[gatewayID] = &models.GatewayStatus{
		GatewayID:  gatewayID,
		FirstSeen: firstSeen,
	}

	// Expect the alert to be sent
	mockAlerter.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil)

	// Expect the gateway status update
	mockDB.EXPECT().UpdateGatewayStatus(gomock.Any(), gomock.Any()).Return(nil)

	// Start the flushGatewayStatusUpdates goroutine
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go server.flushGatewayStatusUpdates(ctx)

	// Call handleGatewayDown
	err := server.handleGatewayDown(ctx, gatewayID, lastSeen)
	if err != nil {
		t.Fatalf("handleGatewayDown failed: %v", err)
	}

	// Wait for the flush to complete (give it some time to process)
	time.Sleep(5 * server.gatewayStatusIntervalOrDefault())
}

func TestEvaluateGatewayHealth(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockWebhook := alerts.NewMockAlertService(ctrl)
	mockAPI := api.NewMockService(ctrl)

	// Mock GetGatewayStatus
	mockDB.EXPECT().GetGatewayStatus(gomock.Any(), "test-gateway").Return(&models.GatewayStatus{
		GatewayID:  "test-gateway",
		IsHealthy: true,
		FirstSeen: time.Now().Add(-1 * time.Hour),
		LastSeen:  time.Now().Add(-10 * time.Minute),
	}, nil).AnyTimes()

	// Mock UpdateGatewayStatus for offline case
	mockDB.EXPECT().UpdateGatewayStatus(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()

	// Mock alert and API update for offline case
	mockWebhook.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	mockAPI.EXPECT().UpdateGatewayStatus(gomock.Any(), gomock.Any()).Return().AnyTimes() // Fixed: Removed Return(nil)

	server := &Server{
		DB:                  mockDB,
		webhooks:            []alerts.AlertService{mockWebhook},
		apiServer:           mockAPI,
		gatewayStatusCache:   make(map[string]*models.GatewayStatus),
		gatewayStatusUpdates: make(map[string]*models.GatewayStatus),
		alertThreshold:      5 * time.Minute, // Set threshold to match test
		logger:              logger.NewTestLogger(),
		tracer:              otel.Tracer("serviceradar-core-test"),
	}

	now := time.Now()
	threshold := now.Add(-5 * time.Minute)

	err := server.evaluateGatewayHealth(context.Background(), "test-gateway", now.Add(-10*time.Minute), true, threshold)
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
	err := alerter.CheckCooldown("test-gateway", "Service Failure", "service-1")
	assert.NoError(t, err, "First alert should not be in cooldown")
}

func TestWebhookAlerter_RepeatAlertInCooldown(t *testing.T) {
	alerter := setupAlerter(time.Minute, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{GatewayID: "test-gateway", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("test-gateway", "Service Failure", "service-1")
	assert.ErrorIs(t, err, alerts.ErrWebhookCooldown, "Repeat alert within cooldown should return error")
}

func TestWebhookAlerter_DifferentGatewaySameAlert(t *testing.T) {
	alerter := setupAlerter(time.Minute, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{GatewayID: "test-gateway", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("other-gateway", "Service Failure", "service-1")
	assert.NoError(t, err, "Different gateway should not be affected by other gateway's cooldown")
}

func TestWebhookAlerter_SameGatewayDifferentAlert(t *testing.T) {
	alerter := setupAlerter(time.Minute, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{GatewayID: "test-gateway", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("test-gateway", "Gateway Recovery", "")
	assert.NoError(t, err, "Different alert type should not be affected by other alert's cooldown")
}

func TestWebhookAlerter_AfterCooldownPeriod(t *testing.T) {
	alerter := setupAlerter(time.Microsecond, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{GatewayID: "test-gateway", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now().Add(-time.Second)
	})
	err := alerter.CheckCooldown("test-gateway", "Service Failure", "service-1")
	assert.NoError(t, err, "Alert after cooldown period should not return error")
}

func TestWebhookAlerter_CooldownDisabled(t *testing.T) {
	alerter := setupAlerter(0, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{GatewayID: "test-gateway", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("test-gateway", "Service Failure", "service-1")
	assert.NoError(t, err, "Alert should not be blocked when cooldown is disabled")
}

func TestWebhookAlerter_SameGatewaySameAlertDifferentService(t *testing.T) {
	alerter := setupAlerter(time.Minute, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{GatewayID: "test-gateway", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("test-gateway", "Service Failure", "service-2")
	assert.NoError(t, err, "Different service on same gateway should not be affected by cooldown")
}

func TestWebhookAlerter_SameGatewayServiceFailureThenGatewayOffline(t *testing.T) {
	alerter := setupAlerter(time.Minute, func(w *alerts.WebhookAlerter) {
		key := alerts.AlertKey{GatewayID: "test-gateway", Title: "Service Failure", ServiceName: "service-1"}
		w.LastAlertTimes[key] = time.Now()
	})
	err := alerter.CheckCooldown("test-gateway", "Gateway Offline", "")
	assert.NoError(t, err, "Gateway Offline alert should not be blocked by Service Failure cooldown")
}

// setupTestServer creates a server with mock dependencies for testing
func setupTestServer(
	t *testing.T,
	ctrl *gomock.Controller) (server *Server,
	dbService db.MockService, alertService alerts.MockAlertService, apiService api.MockService) {
	t.Helper()

	mockDB := db.NewMockService(ctrl)
	mockAlerter := alerts.NewMockAlertService(ctrl)
	mockAPIServer := api.NewMockService(ctrl)

	server = &Server{
		DB:                      mockDB,
		webhooks:                []alerts.AlertService{mockAlerter},
		apiServer:               mockAPIServer,
		serviceBuffers:          make(map[string][]*models.ServiceStatus),
		gatewayStatusUpdateMutex: sync.Mutex{},
		gatewayStatusUpdates:     make(map[string]*models.GatewayStatus),
		gatewayStatusCache:       make(map[string]*models.GatewayStatus),
		ShutdownChan:            make(chan struct{}),
		config:                  &models.CoreServiceConfig{KnownGateways: []string{"test-gateway"}},
		logger:                  logger.NewTestLogger(),
		tracer:                  otel.Tracer("serviceradar-core-test"),
	}

	// Clear all buffers and caches for isolation
	server.serviceBufferMu.Lock()
	server.serviceBuffers = make(map[string][]*models.ServiceStatus)
	server.serviceBufferMu.Unlock()
	server.serviceListBufferMu.Lock()
	server.serviceListBuffers = make(map[string][]*models.Service)
	server.serviceListBufferMu.Unlock()
	server.metricBufferMu.Lock()
	server.metricBuffers = make(map[string][]*models.TimeseriesMetric)
	server.metricBufferMu.Unlock()
	server.sysmonBufferMu.Lock()
	server.sysmonBuffers = make(map[string][]*sysmonMetricBuffer)
	server.sysmonBufferMu.Unlock()
	t.Logf("Initial serviceBuffers: %+v", server.serviceBuffers)

	server.cacheMutex.Lock()
	server.gatewayStatusCache = make(map[string]*models.GatewayStatus)
	server.cacheLastUpdated = time.Time{}
	server.cacheMutex.Unlock()

	server.gatewayStatusUpdateMutex.Lock()
	server.gatewayStatusUpdates = make(map[string]*models.GatewayStatus)
	server.gatewayStatusUpdateMutex.Unlock()

	dbService = *mockDB
	alertService = *mockAlerter
	apiService = *mockAPIServer

	return server, dbService, alertService, apiService
}

// createTestRequest creates a test GatewayStatusRequest with the given gateway and agent IDs
func createTestRequest(gatewayID, agentID string, now time.Time) *proto.GatewayStatusRequest {
	statusMessage := `{"status":"ok"}`

	return &proto.GatewayStatusRequest{
		GatewayId:  gatewayID,
		Timestamp: now.Unix(),
		Partition: "test-partition",
		SourceIp:  "192.168.1.100",
		Services: []*proto.ServiceStatus{
			{
				ServiceName: "test-service",
				ServiceType: "test",
				Available:   true,
				Message:     []byte(statusMessage), // Convert string to []byte
				AgentId:     agentID,
				GatewayId:    gatewayID,
			},
		},
	}
}

func TestProcessStatusReportWithAgentID(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	gatewayID := testGatewayID
	agentID := "agent-123"
	now := time.Now()

	server, mockDB, mockAlerter, mockAPIServer := setupTestServer(t, ctrl)
	req := createTestRequest(gatewayID, agentID, now)

	// Setup mock expectations
	mockDB.EXPECT().GetGatewayStatus(gomock.Any(), gatewayID).Return(&models.GatewayStatus{
		GatewayID:  gatewayID,
		IsHealthy: false,
		FirstSeen: now.Add(-1 * time.Hour),
		LastSeen:  now.Add(-10 * time.Minute),
	}, nil).Times(1)
	mockDB.EXPECT().ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).Return([]map[string]interface{}{}, nil).AnyTimes()
	mockDB.EXPECT().GetDeviceByID(gomock.Any(), gomock.Any()).Return(nil, nil).AnyTimes()
	mockDB.EXPECT().UpsertOCSFAgent(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	mockDB.EXPECT().UpdateGatewayStatus(gomock.Any(), gomock.Any()).Return(nil).Times(2)
	mockDB.EXPECT().UpdateServiceStatuses(gomock.Any(),
		gomock.Any()).DoAndReturn(func(_ context.Context, statuses []*models.ServiceStatus) error {
		t.Logf("UpdateServiceStatuses called with %d statuses: %+v", len(statuses), statuses)
		assert.Len(t, statuses, 1, "Expected exactly one status")
		assert.Equal(t, gatewayID, statuses[0].GatewayID)
		assert.Equal(t, "test-service", statuses[0].ServiceName)
		assert.Equal(t, "test", statuses[0].ServiceType)
		assert.True(t, statuses[0].Available)
		assert.JSONEq(t, `{"status":"ok"}`, string(statuses[0].Details))
		assert.Equal(t, agentID, statuses[0].AgentID)
		return nil
	}).Times(1)
	mockDB.EXPECT().StoreServices(gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, services []*models.Service) error {
		t.Logf("StoreServices called with %d services", len(services))
		return nil
	}).AnyTimes()
	mockAPIServer.EXPECT().UpdateGatewayStatus(gatewayID, gomock.Any()).Return().Times(1)
	mockAlerter.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()

	ctx := context.Background()

	// Clear buffers before ReportStatus
	server.serviceBufferMu.Lock()
	server.serviceBuffers = make(map[string][]*models.ServiceStatus)
	server.serviceBufferMu.Unlock()
	server.serviceListBufferMu.Lock()
	server.serviceListBuffers = make(map[string][]*models.Service)
	server.serviceListBufferMu.Unlock()
	t.Logf("serviceBuffers before ReportStatus: %+v", server.serviceBuffers)

	// Test the ReportStatus function
	reportStatusCount := 0
	wrappedReportStatus := func(ctx context.Context, req *proto.GatewayStatusRequest) (*proto.GatewayStatusResponse, error) {
		reportStatusCount++
		t.Logf("ReportStatus called %d times with GatewayID: %s", reportStatusCount, req.GatewayId)

		return server.ReportStatus(ctx, req)
	}

	resp, err := wrappedReportStatus(ctx, req)
	require.NoError(t, err)
	assert.NotNil(t, resp)
	assert.True(t, resp.Received)
	assert.Equal(t, 1, reportStatusCount, "ReportStatus should be called exactly once")

	// Cleanup
	server.flushAllBuffers(ctx)
	time.Sleep(100 * time.Millisecond) // Wait for flush
	server.serviceBufferMu.Lock()
	t.Logf("serviceBuffers after flush: %+v", server.serviceBuffers)
	server.serviceBuffers = make(map[string][]*models.ServiceStatus)
	server.serviceBufferMu.Unlock()
	server.serviceListBufferMu.Lock()
	server.serviceListBuffers = make(map[string][]*models.Service)
	server.serviceListBufferMu.Unlock()
}
