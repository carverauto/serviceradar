package cloud

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/cloud/alerts"
	"github.com/mfreeman451/serviceradar/pkg/db"
	"github.com/stretchr/testify/assert"
	"go.uber.org/mock/gomock"
)

func TestNodeRecoveryManager_ProcessRecovery_WithCooldown(t *testing.T) {
	tests := []struct {
		name           string
		nodeID         string
		lastSeen       time.Time
		getCurrentNode *db.NodeStatus
		dbError        error
		alertError     error
		expectCommit   bool
		expectError    string
	}{
		{
			name:     "successful_recovery_with_cooldown",
			nodeID:   "test-node",
			lastSeen: time.Now(),
			getCurrentNode: &db.NodeStatus{
				NodeID:    "test-node",
				IsHealthy: false,
				LastSeen:  time.Now().Add(-time.Hour),
			},
			alertError:   alerts.ErrWebhookCooldown,
			expectCommit: true,
		},
		{
			name:     "successful_recovery_no_cooldown",
			nodeID:   "test-node",
			lastSeen: time.Now(),
			getCurrentNode: &db.NodeStatus{
				NodeID:    "test-node",
				IsHealthy: false,
				LastSeen:  time.Now().Add(-time.Hour),
			},
			expectCommit: true,
		},
		{
			name:     "already_healthy",
			nodeID:   "test-node",
			lastSeen: time.Now(),
			getCurrentNode: &db.NodeStatus{
				NodeID:    "test-node",
				IsHealthy: true,
				LastSeen:  time.Now(),
			},
		},
		{
			name:        "db_error",
			nodeID:      "test-node",
			lastSeen:    time.Now(),
			dbError:     db.ErrDatabaseError,
			expectError: "get node status",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := db.NewMockService(ctrl)
			mockAlerter := alerts.NewMockAlertService(ctrl)
			mockTx := db.NewMockTransaction(ctrl)

			// Setup Begin() expectation
			mockDB.EXPECT().Begin().Return(mockTx, nil)

			// Setup GetNodeStatus expectation
			mockDB.EXPECT().GetNodeStatus(tt.nodeID).Return(tt.getCurrentNode, tt.dbError)

			if tt.getCurrentNode != nil && !tt.getCurrentNode.IsHealthy {
				// Expect node status update
				mockDB.EXPECT().UpdateNodeStatus(gomock.Any()).Return(nil)

				// Always expect Rollback() due to defer
				mockTx.EXPECT().Rollback().Return(nil).AnyTimes()

				// Expect alert attempt
				mockAlerter.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(tt.alertError)

				if tt.expectCommit {
					mockTx.EXPECT().Commit().Return(nil)
				}
			} else {
				// For non-recovery cases, expect Rollback()
				mockTx.EXPECT().Rollback().Return(nil).AnyTimes()
			}

			mgr := &NodeRecoveryManager{
				db:          mockDB,
				alerter:     mockAlerter,
				getHostname: func() string { return "test-host" },
			}

			err := mgr.processRecovery(context.Background(), tt.nodeID, tt.lastSeen)

			if tt.expectError != "" {
				assert.ErrorContains(t, err, tt.expectError)
			} else if errors.Is(tt.alertError, alerts.ErrWebhookCooldown) {
				assert.NoError(t, err)
			}
		})
	}
}

func TestNodeRecoveryManager_ProcessRecovery(t *testing.T) {
	tests := []struct {
		name          string
		nodeID        string
		currentStatus *db.NodeStatus
		dbError       error
		expectAlert   bool
		expectedError string
	}{
		{
			name:   "successful_recovery",
			nodeID: "test-node",
			currentStatus: &db.NodeStatus{
				NodeID:    "test-node",
				IsHealthy: false,
				LastSeen:  time.Now().Add(-time.Hour),
			},
			expectAlert: true,
		},
		{
			name:   "already_healthy",
			nodeID: "test-node",
			currentStatus: &db.NodeStatus{
				NodeID:    "test-node",
				IsHealthy: true,
				LastSeen:  time.Now(),
			},
		},
		{
			name:          "db_error",
			nodeID:        "test-node",
			dbError:       db.ErrDatabaseError,
			expectedError: "get node status",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			defer ctrl.Finish()

			mockDB := db.NewMockService(ctrl)
			mockAlerter := alerts.NewMockAlertService(ctrl)
			mockTx := db.NewMockTransaction(ctrl)

			// Setup Begin() expectation
			mockDB.EXPECT().Begin().Return(mockTx, nil)

			// Always expect Rollback() due to defer
			mockTx.EXPECT().Rollback().Return(nil).AnyTimes()

			// Setup GetNodeStatus expectation
			mockDB.EXPECT().GetNodeStatus(tt.nodeID).Return(tt.currentStatus, tt.dbError)

			if tt.currentStatus != nil && !tt.currentStatus.IsHealthy {
				// Expect node status update
				mockDB.EXPECT().UpdateNodeStatus(gomock.Any()).Return(nil)

				if tt.expectAlert {
					mockAlerter.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil)
					mockTx.EXPECT().Commit().Return(nil)
				}
			}

			mgr := &NodeRecoveryManager{
				db:          mockDB,
				alerter:     mockAlerter,
				getHostname: func() string { return "test-host" },
			}

			err := mgr.processRecovery(context.Background(), tt.nodeID, time.Now())

			if tt.expectedError != "" {
				assert.ErrorContains(t, err, tt.expectedError)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestNodeRecoveryManager_SendRecoveryAlert(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockAlerter := alerts.NewMockAlertService(ctrl)
	mgr := &NodeRecoveryManager{
		alerter:     mockAlerter,
		getHostname: func() string { return "test-host" },
	}

	// Verify alert properties
	mockAlerter.EXPECT().
		Alert(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, alert *alerts.WebhookAlert) error {
			assert.Equal(t, alerts.Info, alert.Level)
			assert.Equal(t, "Node Recovered", alert.Title)
			assert.Equal(t, "test-node", alert.NodeID)
			assert.Equal(t, "test-host", alert.Details["hostname"])
			assert.Contains(t, alert.Message, "test-node")

			return nil
		})

	err := mgr.sendRecoveryAlert(context.Background(), "test-node", time.Now())
	assert.NoError(t, err)
}
