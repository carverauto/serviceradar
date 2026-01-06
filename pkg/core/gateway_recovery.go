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

// Package core /pkg/core/gateway_recovery.go
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

// GatewayRecoveryManager handles gateway recovery state transitions.
type GatewayRecoveryManager struct {
	db          db.Service
	alerter     alerts.AlertService
	getHostname func() string
}

func (m *GatewayRecoveryManager) processRecovery(ctx context.Context, gatewayID string, lastSeen time.Time) error {
	// Get the current gateway status
	status, err := m.db.GetGatewayStatus(ctx, gatewayID)
	if err != nil {
		return fmt.Errorf("get gateway status: %w", err)
	}

	// Early return if the gateway is already healthy
	if status.IsHealthy {
		return nil
	}

	// Update gateway status
	status.IsHealthy = true
	status.LastSeen = lastSeen

	// Update the database BEFORE trying to send the alert
	if err = m.db.UpdateGatewayStatus(ctx, status); err != nil {
		return fmt.Errorf("update gateway status: %w", err)
	}

	// Send alert
	if err = m.sendRecoveryAlert(ctx, gatewayID, lastSeen); err != nil {
		// Only treat the cooldown as non-error
		if !errors.Is(err, alerts.ErrWebhookCooldown) {
			return fmt.Errorf("send recovery alert: %w", err)
		}

		// Log the cooldown but proceed with the recovery
		log.Printf("Recovery alert for gateway %s rate limited, but gateway marked as recovered", gatewayID)
	}

	return nil
}

// sendRecoveryAlert handles alert creation and sending.
func (m *GatewayRecoveryManager) sendRecoveryAlert(ctx context.Context, gatewayID string, lastSeen time.Time) error {
	alert := &alerts.WebhookAlert{
		Level:     alerts.Info,
		Title:     "Gateway Recovered",
		Message:   fmt.Sprintf("Gateway '%s' is back online", gatewayID),
		GatewayID:  gatewayID,
		Timestamp: lastSeen.UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname":      m.getHostname(),
			"recovery_time": lastSeen.Format(time.RFC3339),
		},
	}

	return m.alerter.Alert(ctx, alert)
}
