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
			expectAlert: false,
		},
		{
			name:          "db_error",
			nodeID:        "test-node",
			dbError:       errors.New("db error"),
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

			// Mock Begin() call
			mockDB.EXPECT().Begin().Return(mockTx, nil)

			// Mock Rollback() as it's in a defer
			mockTx.EXPECT().Rollback().Return(nil).AnyTimes()

			// Mock GetNodeStatus
			mockDB.EXPECT().GetNodeStatus(tt.nodeID).Return(tt.currentStatus, tt.dbError)

			if tt.currentStatus != nil && !tt.currentStatus.IsHealthy {
				mockDB.EXPECT().UpdateNodeStatus(gomock.Any()).Return(nil)

				if tt.expectAlert {
					mockAlerter.EXPECT().Alert(gomock.Any(), gomock.Any()).Return(nil)
					// Mock the successful commit
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
				assert.Contains(t, err.Error(), tt.expectedError)
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

	mockAlerter.EXPECT().
		Alert(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, alert *alerts.WebhookAlert) error {
			assert.Equal(t, alerts.Info, alert.Level)
			assert.Equal(t, "Node Recovered", alert.Title)
			assert.Equal(t, "test-node", alert.NodeID)
			assert.Equal(t, "test-host", alert.Details["hostname"])
			return nil
		})

	err := mgr.sendRecoveryAlert(context.Background(), "test-node", time.Now())
	assert.NoError(t, err)
}
