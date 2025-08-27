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

func TestPollerRecoveryManager_ProcessRecovery_WithCooldown(t *testing.T) {
	tests := []struct {
		name             string
		pollerID         string
		lastSeen         time.Time
		getCurrentPoller *models.PollerStatus
		dbError          error
		alertError       error
		expectError      string
	}{
		{
			name:     "successful_recovery_with_cooldown",
			pollerID: "test-poller",
			lastSeen: time.Now(),
			getCurrentPoller: &models.PollerStatus{
				PollerID:  "test-poller",
				IsHealthy: false,
				LastSeen:  time.Now().Add(-time.Hour),
			},
			alertError: alerts.ErrWebhookCooldown,
		},
		{
			name:     "successful_recovery_no_cooldown",
			pollerID: "test-poller",
			lastSeen: time.Now(),
			getCurrentPoller: &models.PollerStatus{
				PollerID:  "test-poller",
				IsHealthy: false,
				LastSeen:  time.Now().Add(-time.Hour),
			},
		},
		{
			name:     "already_healthy",
			pollerID: "test-poller",
			lastSeen: time.Now(),
			getCurrentPoller: &models.PollerStatus{
				PollerID:  "test-poller",
				IsHealthy: true,
				LastSeen:  time.Now(),
			},
		},
		{
			name:        "db_error",
			pollerID:    "test-poller",
			lastSeen:    time.Now(),
			dbError:     db.ErrDatabaseError,
			expectError: "get poller status",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := db.NewMockService(ctrl)
			mockAlerter := alerts.NewMockAlertService(ctrl)

			// Setup GetPollerStatus expectation
			mockDB.EXPECT().GetPollerStatus(gomock.Any(), tt.pollerID).Return(tt.getCurrentPoller, tt.dbError)

			if tt.getCurrentPoller != nil && !tt.getCurrentPoller.IsHealthy && tt.dbError == nil {
				// Expect poller status update
				mockDB.EXPECT().UpdatePollerStatus(gomock.Any(), gomock.Any()).Return(nil)

				// Expect alert attempt
				mockAlerter.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(tt.alertError)
			}

			mgr := &PollerRecoveryManager{
				db:          mockDB,
				alerter:     mockAlerter,
				getHostname: func() string { return testHostID },
			}

			err := mgr.processRecovery(context.Background(), tt.pollerID, tt.lastSeen)

			if tt.expectError != "" {
				assert.ErrorContains(t, err, tt.expectError)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestPollerRecoveryManager_ProcessRecovery(t *testing.T) {
	tests := []struct {
		name          string
		pollerID      string
		currentStatus *models.PollerStatus
		dbError       error
		expectAlert   bool
		expectedError string
	}{
		{
			name:     "successful_recovery",
			pollerID: "test-poller",
			currentStatus: &models.PollerStatus{
				PollerID:  "test-poller",
				IsHealthy: false,
				LastSeen:  time.Now().Add(-time.Hour),
			},
			expectAlert: true,
		},
		{
			name:     "already_healthy",
			pollerID: "test-poller",
			currentStatus: &models.PollerStatus{
				PollerID:  "test-poller",
				IsHealthy: true,
				LastSeen:  time.Now(),
			},
		},
		{
			name:          "db_error",
			pollerID:      "test-poller",
			dbError:       db.ErrDatabaseError,
			expectedError: "get poller status",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := db.NewMockService(ctrl)
			mockAlerter := alerts.NewMockAlertService(ctrl)

			// Setup GetPollerStatus expectation
			mockDB.EXPECT().GetPollerStatus(gomock.Any(), tt.pollerID).Return(tt.currentStatus, tt.dbError)

			if tt.currentStatus != nil && !tt.currentStatus.IsHealthy && tt.dbError == nil {
				// Expect poller status update
				mockDB.EXPECT().UpdatePollerStatus(gomock.Any(), gomock.Any()).Return(nil)

				if tt.expectAlert {
					mockAlerter.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil)
				}
			}

			mgr := &PollerRecoveryManager{
				db:          mockDB,
				alerter:     mockAlerter,
				getHostname: func() string { return testHostID },
			}

			err := mgr.processRecovery(context.Background(), tt.pollerID, time.Now())

			if tt.expectedError != "" {
				assert.ErrorContains(t, err, tt.expectedError)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestPollerRecoveryManager_SendRecoveryAlert(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockAlerter := alerts.NewMockAlertService(ctrl)
	mgr := &PollerRecoveryManager{
		alerter:     mockAlerter,
		getHostname: func() string { return testHostID },
	}

	// Verify alert properties
	mockAlerter.EXPECT().
		Alert(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, alert *alerts.WebhookAlert) error {
			assert.Equal(t, alerts.Info, alert.Level)
			assert.Equal(t, "Poller Recovered", alert.Title)
			assert.Equal(t, "test-poller", alert.PollerID)
			assert.Equal(t, testHostID, alert.Details["hostname"])
			assert.Contains(t, alert.Message, "test-poller")

			return nil
		})

	err := mgr.sendRecoveryAlert(context.Background(), "test-poller", time.Now())
	assert.NoError(t, err)
}
