package cloud

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/cloud/alerts"
	"github.com/mfreeman451/serviceradar/pkg/db"
)

// NodeRecoveryManager handles node recovery state transitions.
type NodeRecoveryManager struct {
	db          db.Service
	alerter     alerts.AlertService
	getHostname func() string
}

func newNodeRecoveryManager(d db.Service, alerter alerts.AlertService) *NodeRecoveryManager {
	return &NodeRecoveryManager{
		db:      d,
		alerter: alerter,
		getHostname: func() string {
			hostname, err := os.Hostname()
			if err != nil {
				return statusUnknown
			}
			return hostname
		},
	}
}

func (m *NodeRecoveryManager) processRecovery(ctx context.Context, nodeID string, lastSeen time.Time) error {
	tx, err := m.db.Begin()
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}

	var committed bool
	defer func() {
		if !committed {
			if rbErr := tx.Rollback(); rbErr != nil {
				log.Printf("Error rolling back transaction: %v", rbErr)
			}
		}
	}()

	status, err := m.db.GetNodeStatus(nodeID)
	if err != nil {
		return fmt.Errorf("get node status: %w", err)
	}

	// Early return if the node is already healthy
	if status.IsHealthy {
		return nil
	}

	// Update node status
	status.IsHealthy = true
	status.LastSeen = lastSeen

	// Update the database BEFORE trying to send the alert
	if err = m.db.UpdateNodeStatus(status); err != nil {
		return fmt.Errorf("update node status: %w", err)
	}

	// Send alert
	if err = m.sendRecoveryAlert(ctx, nodeID, lastSeen); err != nil {
		// Only treat the cooldown as non-error
		if !errors.Is(err, alerts.ErrWebhookCooldown) {
			return fmt.Errorf("send recovery alert: %w", err)
		}

		// Log the cooldown but proceed with the recovery
		log.Printf("Recovery alert for node %s rate limited, but node marked as recovered", nodeID)
	}

	// Commit the transaction
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}

	committed = true

	return nil
}

// sendRecoveryAlert handles alert creation and sending.
func (m *NodeRecoveryManager) sendRecoveryAlert(ctx context.Context, nodeID string, lastSeen time.Time) error {
	alert := &alerts.WebhookAlert{
		Level:     alerts.Info,
		Title:     "Node Recovered",
		Message:   fmt.Sprintf("Node '%s' is back online", nodeID),
		NodeID:    nodeID,
		Timestamp: lastSeen.UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname":      m.getHostname(),
			"recovery_time": lastSeen.Format(time.RFC3339),
		},
	}

	return m.alerter.Alert(ctx, alert)
}
