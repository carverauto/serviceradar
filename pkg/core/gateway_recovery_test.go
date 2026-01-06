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
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"go.uber.org/mock/gomock"
)

const (
	testHostID = "test-host"
)

func TestGatewayRecoveryManager_ProcessRecovery_WithCooldown(t *testing.T) {
	tests := []struct {
		name             string
		gatewayID         string
		lastSeen         time.Time
		getCurrentGateway *models.GatewayStatus
		dbError          error
		alertError       error
		expectError      string
	}{
		{
			name:     "successful_recovery_with_cooldown",
			gatewayID: "test-gateway",
			lastSeen: time.Now(),
			getCurrentGateway: &models.GatewayStatus{
				GatewayID:  "test-gateway",
				IsHealthy: false,
				LastSeen:  time.Now().Add(-time.Hour),
			},
			alertError: alerts.ErrWebhookCooldown,
		},
		{
			name:     "successful_recovery_no_cooldown",
			gatewayID: "test-gateway",
			lastSeen: time.Now(),
			getCurrentGateway: &models.GatewayStatus{
				GatewayID:  "test-gateway",
				IsHealthy: false,
				LastSeen:  time.Now().Add(-time.Hour),
			},
		},
		{
			name:     "already_healthy",
			gatewayID: "test-gateway",
			lastSeen: time.Now(),
			getCurrentGateway: &models.GatewayStatus{
				GatewayID:  "test-gateway",
				IsHealthy: true,
				LastSeen:  time.Now(),
			},
		},
		{
			name:        "db_error",
			gatewayID:    "test-gateway",
			lastSeen:    time.Now(),
			dbError:     db.ErrDatabaseError,
			expectError: "get gateway status",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := db.NewMockService(ctrl)
			mockAlerter := alerts.NewMockAlertService(ctrl)

			// Setup GetGatewayStatus expectation
			mockDB.EXPECT().GetGatewayStatus(gomock.Any(), tt.gatewayID).Return(tt.getCurrentGateway, tt.dbError)

			if tt.getCurrentGateway != nil && !tt.getCurrentGateway.IsHealthy && tt.dbError == nil {
				// Expect gateway status update
				mockDB.EXPECT().UpdateGatewayStatus(gomock.Any(), gomock.Any()).Return(nil)

				// Expect alert attempt
				mockAlerter.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(tt.alertError)
			}

			mgr := &GatewayRecoveryManager{
				db:          mockDB,
				alerter:     mockAlerter,
				getHostname: func() string { return testHostID },
			}

			err := mgr.processRecovery(context.Background(), tt.gatewayID, tt.lastSeen)

			if tt.expectError != "" {
				assert.ErrorContains(t, err, tt.expectError)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestGatewayRecoveryManager_ProcessRecovery(t *testing.T) {
	tests := []struct {
		name          string
		gatewayID      string
		currentStatus *models.GatewayStatus
		dbError       error
		expectAlert   bool
		expectedError string
	}{
		{
			name:     "successful_recovery",
			gatewayID: "test-gateway",
			currentStatus: &models.GatewayStatus{
				GatewayID:  "test-gateway",
				IsHealthy: false,
				LastSeen:  time.Now().Add(-time.Hour),
			},
			expectAlert: true,
		},
		{
			name:     "already_healthy",
			gatewayID: "test-gateway",
			currentStatus: &models.GatewayStatus{
				GatewayID:  "test-gateway",
				IsHealthy: true,
				LastSeen:  time.Now(),
			},
		},
		{
			name:          "db_error",
			gatewayID:      "test-gateway",
			dbError:       db.ErrDatabaseError,
			expectedError: "get gateway status",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := db.NewMockService(ctrl)
			mockAlerter := alerts.NewMockAlertService(ctrl)

			// Setup GetGatewayStatus expectation
			mockDB.EXPECT().GetGatewayStatus(gomock.Any(), tt.gatewayID).Return(tt.currentStatus, tt.dbError)

			if tt.currentStatus != nil && !tt.currentStatus.IsHealthy && tt.dbError == nil {
				// Expect gateway status update
				mockDB.EXPECT().UpdateGatewayStatus(gomock.Any(), gomock.Any()).Return(nil)

				if tt.expectAlert {
					mockAlerter.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil)
				}
			}

			mgr := &GatewayRecoveryManager{
				db:          mockDB,
				alerter:     mockAlerter,
				getHostname: func() string { return testHostID },
			}

			err := mgr.processRecovery(context.Background(), tt.gatewayID, time.Now())

			if tt.expectedError != "" {
				assert.ErrorContains(t, err, tt.expectedError)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestGatewayRecoveryManager_SendRecoveryAlert(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockAlerter := alerts.NewMockAlertService(ctrl)
	mgr := &GatewayRecoveryManager{
		alerter:     mockAlerter,
		getHostname: func() string { return testHostID },
	}

	// Verify alert properties
	mockAlerter.EXPECT().
		Alert(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, alert *alerts.WebhookAlert) error {
			assert.Equal(t, alerts.Info, alert.Level)
			assert.Equal(t, "Gateway Recovered", alert.Title)
			assert.Equal(t, "test-gateway", alert.GatewayID)
			assert.Equal(t, testHostID, alert.Details["hostname"])
			assert.Contains(t, alert.Message, "test-gateway")

			return nil
		})

	err := mgr.sendRecoveryAlert(context.Background(), "test-gateway", time.Now())
	assert.NoError(t, err)
}
