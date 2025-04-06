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
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/db"
)

// PollerRecoveryManager handles poller recovery state transitions.
type PollerRecoveryManager struct {
	db          db.Service
	alerter     alerts.AlertService
	getHostname func() string
}

func (m *PollerRecoveryManager) processRecovery(ctx context.Context, pollerID string, lastSeen time.Time) error {
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

	status, err := m.db.GetPollerStatus(pollerID)
	if err != nil {
		return fmt.Errorf("get poller status: %w", err)
	}

	// Early return if the poller is already healthy
	if status.IsHealthy {
		return nil
	}

	// Update poller status
	status.IsHealthy = true
	status.LastSeen = lastSeen

	// Update the database BEFORE trying to send the alert
	if err = m.db.UpdatePollerStatus(status); err != nil {
		return fmt.Errorf("update poller status: %w", err)
	}

	// Send alert
	if err = m.sendRecoveryAlert(ctx, pollerID, lastSeen); err != nil {
		// Only treat the cooldown as non-error
		if !errors.Is(err, alerts.ErrWebhookCooldown) {
			return fmt.Errorf("send recovery alert: %w", err)
		}

		// Log the cooldown but proceed with the recovery
		log.Printf("Recovery alert for poller %s rate limited, but poller marked as recovered", pollerID)
	}

	// Commit the transaction
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}

	committed = true

	return nil
}

// sendRecoveryAlert handles alert creation and sending.
func (m *PollerRecoveryManager) sendRecoveryAlert(ctx context.Context, pollerID string, lastSeen time.Time) error {
	alert := &alerts.WebhookAlert{
		Level:     alerts.Info,
		Title:     "Poller Recovered",
		Message:   fmt.Sprintf("Poller '%s' is back online", pollerID),
		PollerID:  pollerID,
		Timestamp: lastSeen.UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname":      m.getHostname(),
			"recovery_time": lastSeen.Format(time.RFC3339),
		},
	}

	return m.alerter.Alert(ctx, alert)
}
