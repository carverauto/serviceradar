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
	"io"
	"net"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
)

const defaultPartition = "default"

func (s *Server) MonitorGateways(ctx context.Context) {
	ticker := time.NewTicker(monitorInterval)
	defer ticker.Stop()

	cleanupTicker := time.NewTicker(dailyCleanupInterval)
	defer cleanupTicker.Stop()

	if err := s.checkGatewayStatus(ctx); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Initial state check failed")
	}

	if err := s.checkNeverReportedGateways(ctx); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Initial never-reported check failed")
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.ShutdownChan:
			return
		case <-ticker.C:
			s.handleMonitorTick(ctx)
		case <-cleanupTicker.C:
			if err := s.cleanupUnknownGateways(ctx); err != nil {
				s.logger.Error().
					Err(err).
					Msg("Daily cleanup of unknown gateways failed")
			}
		}
	}
}

func (s *Server) handleMonitorTick(ctx context.Context) {
	if err := s.checkGatewayStatus(ctx); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Gateway state check failed")
	}

	if err := s.checkNeverReportedGateways(ctx); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Never-reported check failed")
	}
}

func (s *Server) checkGatewayStatus(ctx context.Context) error {
	// Get all gateway statuses
	gatewayStatuses, err := s.getGatewayStatuses(ctx, false)
	if err != nil {
		return fmt.Errorf("failed to get gateway statuses: %w", err)
	}

	threshold := time.Now().Add(-s.alertThreshold)

	batchCtx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	// Process all gateways in a single pass
	for _, ps := range gatewayStatuses {
		// Skip gateways evaluated recently
		if time.Since(ps.LastEvaluated) < defaultSkipInterval {
			continue
		}

		// Mark as evaluated
		ps.LastEvaluated = time.Now()

		// Handle gateway status
		if err := s.handleGateway(batchCtx, ps, threshold); err != nil {
			s.logger.Error().
				Err(err).
				Str("gateway_id", ps.GatewayID).
				Msg("Error handling gateway")
		}
	}

	return nil
}

// handleGateway processes an individual gateway's status (offline or recovered).
func (s *Server) handleGateway(batchCtx context.Context, ps *models.GatewayStatus, threshold time.Time) error {
	if ps.IsHealthy && ps.LastSeen.Before(threshold) {
		// Gateway appears to be offline
		if !ps.AlertSent {
			duration := time.Since(ps.LastSeen).Round(time.Second)
			s.logger.Warn().
				Str("gateway_id", ps.GatewayID).
				Dur("duration", duration).
				Msg("Gateway appears to be offline")

			if err := s.handleGatewayDown(batchCtx, ps.GatewayID, ps.LastSeen); err != nil {
				return err
			}

			ps.AlertSent = true
		}
	} else if !ps.IsHealthy && !ps.LastSeen.Before(threshold) && ps.AlertSent {
		// Backup recovery mechanism: gateway is marked unhealthy but has reported recently
		// Primary recovery now happens in PushStatus, but this serves as a safety net
		s.logger.Info().
			Str("gateway_id", ps.GatewayID).
			Msg("Gateway detected as recovered via periodic check (backup mechanism)")

		// Simply clear the alert flag and mark as healthy - PushStatus handles proper recovery events
		ps.AlertSent = false
		ps.IsHealthy = true
	}

	return nil
}

func (s *Server) flushGatewayStatusUpdates(ctx context.Context) {
	interval := s.gatewayStatusIntervalOrDefault()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.ShutdownChan:
			return
		case <-ticker.C:
			s.gatewayStatusUpdateMutex.Lock()
			updates := s.gatewayStatusUpdates

			s.gatewayStatusUpdates = make(map[string]*models.GatewayStatus)
			s.gatewayStatusUpdateMutex.Unlock()

			if len(updates) == 0 {
				continue
			}

			s.logger.Debug().
				Int("update_count", len(updates)).
				Msg("Flushing gateway status updates")

			// Convert to a slice for batch processing
			statuses := make([]*models.GatewayStatus, 0, len(updates))

			for _, status := range updates {
				statuses = append(statuses, status)
			}

			// Update in batches if your DB supports it
			// Otherwise, loop and update individually
			for _, status := range statuses {
				if err := s.DB.UpdateGatewayStatus(ctx, status); err != nil {
					s.logger.Error().
						Err(err).
						Str("gateway_id", status.GatewayID).
						Msg("Error updating gateway status")
				}
			}
		}
	}
}

func (s *Server) evaluateGatewayHealth(
	ctx context.Context, gatewayID string, lastSeen time.Time, isHealthy bool, threshold time.Time) error {
	s.logger.Debug().
		Str("gateway_id", gatewayID).
		Time("last_seen", lastSeen).
		Bool("is_healthy", isHealthy).
		Time("threshold", threshold).
		Msg("Evaluating gateway health")

	if isHealthy && lastSeen.Before(threshold) {
		duration := time.Since(lastSeen).Round(time.Second)
		s.logger.Warn().
			Str("gateway_id", gatewayID).
			Dur("duration", duration).
			Msg("Gateway appears to be offline")

		return s.handleGatewayDown(ctx, gatewayID, lastSeen)
	}

	if isHealthy && !lastSeen.Before(threshold) {
		return nil
	}

	if !lastSeen.Before(threshold) {
		currentHealth, err := s.getGatewayHealthState(ctx, gatewayID)
		if err != nil {
			s.logger.Error().
				Err(err).
				Str("gateway_id", gatewayID).
				Msg("Error getting current health state for gateway")

			return fmt.Errorf("failed to get current health state: %w", err)
		}

		if !isHealthy && currentHealth {
			return s.handlePotentialRecovery(ctx, gatewayID, lastSeen)
		}
	}

	return nil
}

func (s *Server) handlePotentialRecovery(ctx context.Context, gatewayID string, lastSeen time.Time) error {
	apiStatus := &api.GatewayStatus{
		GatewayID:  gatewayID,
		LastUpdate: lastSeen,
		Services:   make([]api.ServiceStatus, 0),
	}

	s.handleGatewayRecovery(ctx, gatewayID, apiStatus, lastSeen, nil)

	return nil
}

func (s *Server) handleGatewayDown(ctx context.Context, gatewayID string, lastSeen time.Time) error {
	// Get the existing firstSeen value
	firstSeen := lastSeen

	s.cacheMutex.RLock()

	if ps, ok := s.gatewayStatusCache[gatewayID]; ok {
		firstSeen = ps.FirstSeen
	}

	s.cacheMutex.RUnlock()

	s.queueGatewayStatusUpdate(gatewayID, false, lastSeen, firstSeen)

	// Emit offline event to NATS if event publisher is available
	if s.eventPublisher != nil {
		// TODO: Extract source IP and partition from gateway cache if available
		sourceIP := ""
		partition := ""

		if err := s.eventPublisher.PublishGatewayOfflineEvent(ctx, gatewayID, sourceIP, partition, lastSeen); err != nil {
			s.logger.Error().
				Err(err).
				Str("gateway_id", gatewayID).
				Msg("Failed to publish gateway offline event")
			s.handleEventPublishError(err, "gateway_offline")
		} else {
			s.logger.Info().
				Str("gateway_id", gatewayID).
				Msg("Published gateway offline event")
		}
	}

	alert := &alerts.WebhookAlert{
		Level:     alerts.Error,
		Title:     "Gateway Offline",
		Message:   fmt.Sprintf("Gateway '%s' is offline", gatewayID),
		GatewayID: gatewayID,
		Timestamp: lastSeen.UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname": getHostname(),
			"duration": time.Since(lastSeen).String(),
		},
	}

	if err := s.sendAlert(ctx, alert); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Failed to send down alert")
	}

	if s.apiServer != nil {
		s.apiServer.UpdateGatewayStatus(gatewayID, &api.GatewayStatus{
			GatewayID:  gatewayID,
			IsHealthy:  false,
			LastUpdate: lastSeen,
		})
	}

	return nil
}

func (s *Server) handleGatewayRecovery(
	ctx context.Context,
	gatewayID string,
	apiStatus *api.GatewayStatus,
	timestamp time.Time,
	req *proto.GatewayStatusRequest) {
	// Emit recovery event to NATS if event publisher is available
	if s.eventPublisher != nil {
		sourceIP := ""
		partition := ""

		if req != nil {
			sourceIP = s.resolveServiceHostIP(ctx, req.GatewayId, req.AgentId, req.SourceIp)
			partition = req.Partition
		}

		// TODO: Extract remote address from gRPC context if needed
		remoteAddr := ""

		if err := s.eventPublisher.PublishGatewayRecoveryEvent(
			ctx, gatewayID, sourceIP, partition, remoteAddr, timestamp); err != nil {
			s.logger.Error().
				Err(err).
				Str("gateway_id", gatewayID).
				Msg("Failed to publish gateway recovery event")
			s.handleEventPublishError(err, "gateway_recovery")
		} else {
			s.logger.Info().
				Str("gateway_id", gatewayID).
				Msg("Published gateway recovery event")
		}
	}

	for _, webhook := range s.webhooks {
		alerter, ok := webhook.(*alerts.WebhookAlerter)
		if !ok {
			continue
		}

		// Check if the gateway was previously marked as down
		alerter.Mu.RLock()
		wasDown := alerter.NodeDownStates[gatewayID]
		alerter.Mu.RUnlock()

		if !wasDown {
			s.logger.Debug().
				Str("gateway_id", gatewayID).
				Msg("Skipping recovery alert: gateway was not marked as down")

			continue
		}

		alerter.MarkGatewayAsRecovered(gatewayID)
		alerter.MarkServiceAsRecovered(gatewayID)
	}

	alert := &alerts.WebhookAlert{
		Level:       alerts.Info,
		Title:       "Gateway Recovered",
		Message:     fmt.Sprintf("Gateway '%s' is back online", gatewayID),
		GatewayID:   gatewayID,
		Timestamp:   timestamp.UTC().Format(time.RFC3339),
		ServiceName: "",
		Details: map[string]any{
			"hostname":      getHostname(),
			"recovery_time": timestamp.Format(time.RFC3339),
			"services":      len(apiStatus.Services),
		},
	}

	if err := s.sendAlert(ctx, alert); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Failed to send recovery alert")
	}
}

func normalizeHostIP(raw string) string {
	ip := strings.TrimSpace(raw)
	if ip == "" {
		return ""
	}

	if host, _, err := net.SplitHostPort(ip); err == nil && host != "" {
		ip = host
	}

	if strings.HasPrefix(ip, "[") && strings.Contains(ip, "]") {
		if end := strings.Index(ip, "]"); end > 0 {
			ip = ip[1:end]
		}
	}

	ip = strings.TrimSpace(ip)
	if ip == "" {
		return ""
	}

	if net.ParseIP(ip) == nil {
		return ""
	}

	return ip
}

func (s *Server) storeGatewayStatus(ctx context.Context, gatewayID string, isHealthy bool, hostIP string, now time.Time) error {
	normIP := normalizeHostIP(hostIP)

	gatewayStatus := &models.GatewayStatus{
		GatewayID: gatewayID,
		IsHealthy: isHealthy,
		LastSeen:  now,
		HostIP:    normIP,
	}

	if err := s.DB.UpdateGatewayStatus(ctx, gatewayStatus); err != nil {
		return fmt.Errorf("failed to store gateway status: %w", err)
	}

	return nil
}

func (s *Server) updateGatewayStatus(ctx context.Context, gatewayID string, isHealthy bool, timestamp time.Time) error {
	gatewayStatus := &models.GatewayStatus{
		GatewayID: gatewayID,
		IsHealthy: isHealthy,
		LastSeen:  timestamp,
	}

	existingStatus, err := s.DB.GetGatewayStatus(ctx, gatewayID)
	if err != nil && !errors.Is(err, db.ErrFailedToQuery) {
		return fmt.Errorf("failed to check gateway existence: %w", err)
	}

	if err != nil {
		gatewayStatus.FirstSeen = timestamp
	} else {
		gatewayStatus.FirstSeen = existingStatus.FirstSeen
	}

	if err := s.DB.UpdateGatewayStatus(ctx, gatewayStatus); err != nil {
		return fmt.Errorf("failed to update gateway status: %w", err)
	}

	return nil
}

func (s *Server) updateGatewayState(
	ctx context.Context,
	gatewayID string,
	apiStatus *api.GatewayStatus,
	wasHealthy bool,
	now time.Time,
	req *proto.GatewayStatusRequest) error {
	sourceIP := s.resolveServiceHostIP(ctx, gatewayID, req.AgentId, req.SourceIp)

	if err := s.storeGatewayStatus(ctx, gatewayID, apiStatus.IsHealthy, sourceIP, now); err != nil {
		return err
	}

	if !wasHealthy && apiStatus.IsHealthy {
		s.handleGatewayRecovery(ctx, gatewayID, apiStatus, now, req)
	}

	return nil
}

func (s *Server) checkNeverReportedGateways(ctx context.Context) error {
	gatewayIDs, err := s.DB.ListNeverReportedGateways(ctx, s.gatewayPatterns)
	if err != nil {
		return fmt.Errorf("error querying unreported gateways: %w", err)
	}

	if len(gatewayIDs) > 0 {
		alert := &alerts.WebhookAlert{
			Level:     alerts.Warning,
			Title:     "Gateways Never Reported",
			Message:   fmt.Sprintf("%d gateway(s) have not reported since startup", len(gatewayIDs)),
			GatewayID: "core",
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			Details: map[string]any{
				"hostname":      getHostname(),
				"gateway_ids":   gatewayIDs,
				"gateway_count": len(gatewayIDs),
			},
		}

		if err := s.sendAlert(ctx, alert); err != nil {
			s.logger.Error().
				Err(err).
				Msg("Error sending unreported gateways alert")

			return err
		}
	}

	return nil
}

func (s *Server) CheckNeverReportedGatewaysStartup(ctx context.Context) {
	s.logger.Debug().
		Interface("gateway_patterns", s.gatewayPatterns).
		Msg("Checking for unreported gateways matching patterns")

	if len(s.gatewayPatterns) == 0 {
		s.logger.Debug().Msg("No gateway patterns configured, skipping unreported gateway check")

		return
	}

	// Clear gateway status cache
	s.cacheMutex.Lock()
	s.gatewayStatusCache = make(map[string]*models.GatewayStatus)
	s.cacheLastUpdated = time.Time{}
	s.cacheMutex.Unlock()

	s.logger.Debug().Msg("Cleared gateway status cache for startup check")

	gatewayIDs, err := s.DB.ListNeverReportedGateways(ctx, s.gatewayPatterns)
	if err != nil {
		s.logger.Error().
			Err(err).
			Msg("Error querying unreported gateways")

		return
	}

	s.logger.Info().
		Int("gateway_count", len(gatewayIDs)).
		Interface("gateway_ids", gatewayIDs).
		Msg("Found unreported gateways")

	if len(gatewayIDs) > 0 {
		s.sendUnreportedGatewaysAlert(ctx, gatewayIDs)
	} else {
		s.logger.Debug().Msg("No unreported gateways found")
	}
}

func (s *Server) sendUnreportedGatewaysAlert(ctx context.Context, gatewayIDs []string) {
	alert := &alerts.WebhookAlert{
		Level:     alerts.Warning,
		Title:     "Gateways Never Reported",
		Message:   fmt.Sprintf("%d gateway(s) have not reported since startup: %v", len(gatewayIDs), gatewayIDs),
		GatewayID: "core",
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname":      getHostname(),
			"gateway_ids":   gatewayIDs,
			"gateway_count": len(gatewayIDs),
		},
	}

	if err := s.sendAlert(ctx, alert); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Error sending unreported gateways alert")
	} else {
		s.logger.Info().
			Int("gateway_count", len(gatewayIDs)).
			Msg("Sent alert for unreported gateways")
	}
}

func (s *Server) processStatusReport(
	ctx context.Context, req *proto.GatewayStatusRequest, now time.Time, resolvedSourceIP string) (*api.GatewayStatus, error) {
	gatewayStatus := &models.GatewayStatus{
		GatewayID: req.GatewayId,
		IsHealthy: true,
		LastSeen:  now,
	}
	normSourceIP := normalizeHostIP(resolvedSourceIP)

	existingStatus, err := s.DB.GetGatewayStatus(ctx, req.GatewayId)
	if err == nil {
		gatewayStatus.FirstSeen = existingStatus.FirstSeen
		currentState := existingStatus.IsHealthy

		if err := s.DB.UpdateGatewayStatus(ctx, gatewayStatus); err != nil {
			s.logger.Error().
				Err(err).
				Str("gateway_id", req.GatewayId).
				Msg("Failed to store gateway status")

			return nil, fmt.Errorf("failed to store gateway status: %w", err)
		}

		apiStatus := s.createGatewayStatus(req, now)
		s.processServices(ctx, req.GatewayId, req.Partition, normSourceIP, apiStatus, req.Services, now)

		if err := s.updateGatewayState(ctx, req.GatewayId, apiStatus, currentState, now, req); err != nil {
			s.logger.Error().
				Err(err).
				Str("gateway_id", req.GatewayId).
				Msg("Failed to update gateway state")

			return nil, err
		}

		// Register the gateway/agent as a device
		go func(normalizedIP string, services []*proto.GatewayServiceStatus) {
			// Run in a separate goroutine to not block the main status report flow.
			// Create a detached context but preserve trace information
			detachedCtx := context.WithoutCancel(ctx)
			s.registerServiceOrCoreDevice(detachedCtx, req.GatewayId, req.Partition, normalizedIP, services, now)
		}(normSourceIP, req.Services)

		return apiStatus, nil
	}

	gatewayStatus.FirstSeen = now

	if err := s.DB.UpdateGatewayStatus(ctx, gatewayStatus); err != nil {
		s.logger.Error().
			Err(err).
			Str("gateway_id", req.GatewayId).
			Msg("Failed to create new gateway status")

		return nil, fmt.Errorf("failed to create gateway status: %w", err)
	}

	// Emit first seen event to NATS if event publisher is available
	if s.eventPublisher != nil {
		// TODO: Extract remote address from gRPC context if needed
		remoteAddr := ""

		if err := s.eventPublisher.PublishGatewayFirstSeenEvent(ctx, req.GatewayId, normSourceIP, req.Partition, remoteAddr, now); err != nil {
			s.logger.Error().
				Err(err).
				Str("gateway_id", req.GatewayId).
				Msg("Failed to publish gateway first seen event")
			s.handleEventPublishError(err, "gateway_first_seen")
		} else {
			s.logger.Info().
				Str("gateway_id", req.GatewayId).
				Msg("Published gateway first seen event")
		}
	}

	apiStatus := s.createGatewayStatus(req, now)
	s.processServices(ctx, req.GatewayId, req.Partition, normSourceIP, apiStatus, req.Services, now)

	// Register the gateway/agent as a device for new gateways too
	go func(normalizedIP string, services []*proto.GatewayServiceStatus) {
		// Run in a separate goroutine to not block the main status report flow.
		// Create a detached context but preserve trace information
		detachedCtx := context.WithoutCancel(ctx)
		s.registerServiceOrCoreDevice(detachedCtx, req.GatewayId, req.Partition, normalizedIP, services, now)
	}(normSourceIP, req.Services)

	return apiStatus, nil
}

func (*Server) createGatewayStatus(req *proto.GatewayStatusRequest, now time.Time) *api.GatewayStatus {
	return &api.GatewayStatus{
		GatewayID:  req.GatewayId,
		LastUpdate: now,
		IsHealthy:  true,
		Services:   make([]api.ServiceStatus, 0, len(req.Services)),
	}
}
func (s *Server) getGatewayHealthState(ctx context.Context, gatewayID string) (bool, error) {
	status, err := s.DB.GetGatewayStatus(ctx, gatewayID)
	if err != nil {
		return false, err
	}

	return status.IsHealthy, nil
}

func (s *Server) checkInitialStates(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	statuses, err := s.DB.ListGatewayStatuses(ctx, s.gatewayPatterns)
	if err != nil {
		s.logger.Error().
			Err(err).
			Msg("Error querying gateways")

		return
	}

	// Use a map to track which gateways we've already logged as offline
	reportedOffline := make(map[string]bool)

	for i := range statuses {
		duration := time.Since(statuses[i].LastSeen)

		// Only log each offline gateway once
		if duration > s.alertThreshold && !reportedOffline[statuses[i].GatewayID] {
			s.logger.Warn().
				Str("gateway_id", statuses[i].GatewayID).
				Dur("duration", duration.Round(time.Second)).
				Msg("Gateway found offline during initial check")

			reportedOffline[statuses[i].GatewayID] = true
		}
	}
}
func (s *Server) isKnownGateway(ctx context.Context, gatewayID string) bool {
	// Backwards compatibility: check static config first
	for _, known := range s.config.KnownGateways {
		if known == gatewayID {
			return true
		}
	}

	// Primary path: check service registry for registered gateways
	if s.ServiceRegistry != nil {
		known, err := s.ServiceRegistry.IsKnownGateway(ctx, gatewayID)
		if err != nil {
			s.logger.Warn().Err(err).Str("gateway_id", gatewayID).Msg("Failed to check service registry")
		}
		if known {
			return true
		}
	}

	// Legacy fallback: check edge onboarding allowed gateways
	if s.edgeOnboarding != nil {
		if s.edgeOnboarding.isGatewayAllowed(ctx, gatewayID) {
			return true
		}
	}

	return false
}

func (s *Server) cleanupUnknownGateways(ctx context.Context) error {
	if len(s.config.KnownGateways) == 0 {
		return nil
	}

	gatewayIDs, err := s.DB.ListGateways(ctx)
	if err != nil {
		return fmt.Errorf("failed to list gateways: %w", err)
	}

	var gatewaysToDelete []string

	for _, gatewayID := range gatewayIDs {
		isKnown := false

		for _, known := range s.config.KnownGateways {
			if known == gatewayID {
				isKnown = true

				break
			}
		}

		if !isKnown {
			gatewaysToDelete = append(gatewaysToDelete, gatewayID)
		}
	}

	for _, gatewayID := range gatewaysToDelete {
		if err := s.DB.DeleteGateway(ctx, gatewayID); err != nil {
			s.logger.Error().
				Err(err).
				Str("gateway_id", gatewayID).
				Msg("Error deleting unknown gateway")
		} else {
			s.logger.Info().
				Str("gateway_id", gatewayID).
				Msg("Deleted unknown gateway")
		}
	}

	s.logger.Info().
		Int("gateway_count", len(gatewaysToDelete)).
		Msg("Cleaned up unknown gateway(s) from database")

	return nil
}

func (s *Server) monitorGateways(ctx context.Context) {
	s.logger.Info().
		Msg("Starting gateway monitoring")

	time.Sleep(gatewayDiscoveryTimeout)

	s.checkInitialStates(ctx)

	time.Sleep(gatewayNeverReportedTimeout)

	s.CheckNeverReportedGatewaysStartup(ctx)

	s.MonitorGateways(ctx)
}

func (s *Server) queueGatewayStatusUpdate(gatewayID string, isHealthy bool, lastSeen, firstSeen time.Time) {
	// Validate timestamps
	if !isValidTimestamp(lastSeen) {
		lastSeen = time.Now()
	}

	if !isValidTimestamp(firstSeen) {
		firstSeen = lastSeen // Use lastSeen as a fallback
	}

	s.gatewayStatusUpdateMutex.Lock()
	defer s.gatewayStatusUpdateMutex.Unlock()

	s.gatewayStatusUpdates[gatewayID] = &models.GatewayStatus{
		GatewayID: gatewayID,
		IsHealthy: isHealthy,
		LastSeen:  lastSeen,
		FirstSeen: firstSeen,
	}
}

// findAgentID extracts the agent ID from the services if available
func (*Server) findAgentID(services []*proto.GatewayServiceStatus) string {
	for _, svc := range services {
		if svc.AgentId != "" {
			return svc.AgentId
		}
	}

	return ""
}

func (s *Server) PushStatus(ctx context.Context, req *proto.GatewayStatusRequest) (*proto.GatewayStatusResponse, error) {
	ctx, span := s.tracer.Start(ctx, "PushStatus")
	defer span.End()

	resolvedSourceIP := s.resolveServiceHostIP(ctx, req.GatewayId, req.AgentId, req.SourceIp)

	// Add span attributes for the request
	span.SetAttributes(
		attribute.String("gateway_id", req.GatewayId),
		attribute.String("partition", req.Partition),
		attribute.String("source_ip", resolvedSourceIP),
		attribute.String("source_ip_raw", req.SourceIp),
		attribute.Int("service_count", len(req.Services)),
	)

	// Get trace-aware logger from context (added by LoggingInterceptor)
	logger := grpc.GetLogger(ctx, s.logger)
	logger.Debug().
		Str("gateway_id", req.GatewayId).
		Int("service_count", len(req.Services)).
		Time("timestamp", time.Now()).
		Msg("Received status report")

	// Summarize services received to avoid log spam
	var totalBytes int
	var sweepCount int
	for _, svc := range req.Services {
		totalBytes += len(svc.Message)
		if svc.ServiceType == sweepService {
			sweepCount++
		}
	}
	s.logger.Info().
		Str("gateway_id", req.GatewayId).
		Int("services", len(req.Services)).
		Int("sweep_services", sweepCount).
		Int("payload_bytes", totalBytes).
		Msg("Status report summary")

	if req.GatewayId == "" {
		return nil, errEmptyGatewayID
	}

	// Validate required location fields - critical for device registration
	if req.Partition == "" || resolvedSourceIP == "" {
		s.logger.Warn().
			Str("gateway_id", req.GatewayId).
			Str("partition", req.Partition).
			Str("source_ip", resolvedSourceIP).
			Str("source_ip_raw", req.SourceIp).
			Msg("CRITICAL: Status report missing required location data, device registration will be skipped")
	}

	if !s.isKnownGateway(ctx, req.GatewayId) {
		s.logger.Warn().
			Str("gateway_id", req.GatewayId).
			Msg("Ignoring status report from unknown gateway")

		return &proto.GatewayStatusResponse{Received: true}, nil
	}

	// Auto-register gateway if not already in service registry
	if err := s.ensureGatewayRegistered(ctx, req.GatewayId, resolvedSourceIP); err != nil {
		s.logger.Warn().Err(err).
			Str("gateway_id", req.GatewayId).
			Msg("Failed to auto-register gateway in service registry")
	}

	now := time.Unix(req.Timestamp, 0)

	apiStatus, err := s.processStatusReport(ctx, req, now, resolvedSourceIP)
	if err != nil {
		return nil, fmt.Errorf("failed to process status report: %w", err)
	}

	s.updateAPIState(req.GatewayId, apiStatus)

	// Explicitly set span status to OK for successful operations
	if span := trace.SpanFromContext(ctx); span != nil {
		span.SetStatus(codes.Ok, "Status report processed successfully")
	}

	return &proto.GatewayStatusResponse{Received: true}, nil
}

// StreamStatus handles streaming status reports from gateways for large datasets
func (s *Server) StreamStatus(stream proto.AgentGatewayService_StreamStatusServer) error {
	ctx := stream.Context()
	ctx, span := s.tracer.Start(ctx, "StreamStatus")

	defer span.End()

	// Get trace-aware logger from context (added by gRPC interceptor)
	logger := grpc.GetLogger(ctx, s.logger)
	logger.Debug().Msg("Starting streaming status reception")

	// Receive and reassemble chunks
	allServices, metadata, err := s.receiveAndAssembleChunks(ctx, stream)
	if err != nil {
		span.RecordError(err)
		span.AddEvent("Failed to receive and assemble chunks", trace.WithAttributes(
			attribute.String("error", err.Error()),
		))

		return err
	}

	// Add span attributes for the received data
	span.SetAttributes(
		attribute.String("gateway_id", metadata.gatewayID),
		attribute.String("partition", metadata.partition),
		attribute.String("source_ip", metadata.sourceIP),
		attribute.Int("service_count", len(allServices)),
		attribute.String("agent_id", metadata.agentID),
	)

	s.logger.Debug().
		Str("gateway_id", metadata.gatewayID).
		Int("total_service_count", len(allServices)).
		Msg("Completed streaming reception")

	// Summarize services received via streaming
	var streamBytes int
	var streamSweepCount int
	for _, svc := range allServices {
		streamBytes += len(svc.Message)
		if svc.ServiceType == sweepService {
			streamSweepCount++
		}
	}
	s.logger.Info().
		Str("gateway_id", metadata.gatewayID).
		Int("services", len(allServices)).
		Int("sweep_services", streamSweepCount).
		Int("payload_bytes", streamBytes).
		Msg("StreamStatus summary")

	// Validate and process the assembled data
	return s.processStreamedStatus(ctx, stream, allServices, metadata)
}

// streamMetadata holds metadata extracted from streaming chunks
type streamMetadata struct {
	gatewayID string
	agentID   string
	partition string
	sourceIP  string
	timestamp int64
}

// receiveAndAssembleChunks receives all chunks and handles service messages
// For sync services, keeps chunks separate. For other services, reassembles them.
func (s *Server) receiveAndAssembleChunks(
	_ context.Context, stream proto.AgentGatewayService_StreamStatusServer) ([]*proto.GatewayServiceStatus, streamMetadata, error) {
	var metadata streamMetadata

	serviceMessages := make(map[string][]byte)

	serviceMetadata := make(map[string]*proto.GatewayServiceStatus)

	for {
		chunk, err := stream.Recv()
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}

			return nil, metadata, fmt.Errorf("error receiving stream chunk: %w", err)
		}

		// Extract metadata from first chunk
		if metadata.gatewayID == "" {
			metadata = streamMetadata{
				gatewayID: chunk.GatewayId,
				agentID:   chunk.AgentId,
				partition: chunk.Partition,
				sourceIP:  chunk.SourceIp,
				timestamp: chunk.Timestamp,
			}
		}

		s.logChunkReceipt(chunk)

		// Process all services with normal reassembly - but we'll handle sync services specially later
		s.collectServiceChunks(chunk.Services, serviceMessages, serviceMetadata)

		if chunk.IsFinal {
			break
		}
	}

	// Assemble all services (including sync services that need reassembly for processing)
	allServices := s.assembleServices(serviceMessages, serviceMetadata)

	s.logger.Info().
		Int("total_services", len(allServices)).
		Msg("Completed service message assembly")

	return allServices, metadata, nil
}

// logChunkReceipt logs the receipt of a chunk
func (s *Server) logChunkReceipt(chunk *proto.GatewayStatusChunk) {
	s.logger.Debug().
		Int32("chunk_index", chunk.ChunkIndex+1).
		Int32("total_chunks", chunk.TotalChunks).
		Str("gateway_id", chunk.GatewayId).
		Int("service_count", len(chunk.Services)).
		Msg("Received chunk")
}

// collectServiceChunks processes services from a chunk
func (s *Server) collectServiceChunks(
	services []*proto.GatewayServiceStatus,
	serviceMessages map[string][]byte,
	serviceMetadata map[string]*proto.GatewayServiceStatus) {
	for _, svc := range services {
		key := fmt.Sprintf("%s:%s", svc.ServiceName, svc.ServiceType)

		if existingData, exists := serviceMessages[key]; exists {
			// Handle sync services specially - they send JSON arrays that need proper merging
			if svc.ServiceType == syncServiceType {
				serviceMessages[key] = s.mergeSyncServiceChunks(existingData, svc.Message)
			} else {
				// For non-sync services, continue with byte concatenation
				serviceMessages[key] = append(existingData, svc.Message...)
			}

			s.logger.Debug().
				Str("service_name", svc.ServiceName).
				Int("chunk_size", len(svc.Message)).
				Int("total_size", len(serviceMessages[key])).
				Msg("Appending to chunked service message")
		} else {
			// First time seeing this service
			serviceMessages[key] = append([]byte{}, svc.Message...)
			serviceMetadata[key] = svc

			if len(svc.Message) > 0 {
				s.logger.Debug().
					Str("service_name", svc.ServiceName).
					Int("message_size", len(svc.Message)).
					Msg("Started collecting service message")
			}
		}
	}
}

// mergeSyncServiceChunks concatenates sync service streaming chunks
func (s *Server) mergeSyncServiceChunks(existingData, newChunk []byte) []byte {
	// Sync service sends streaming JSON chunks that need simple concatenation
	// The final reassembled payload will be parsed as a complete JSON structure later
	existingData = append(existingData, newChunk...)

	s.logger.Debug().
		Int("existing_size", len(existingData)-len(newChunk)).
		Int("new_chunk_size", len(newChunk)).
		Int("total_size", len(existingData)).
		Msg("Concatenated sync service chunks")

	return existingData
}

// assembleServices creates the final service list from reassembled messages
func (s *Server) assembleServices(
	serviceMessages map[string][]byte, serviceMetadata map[string]*proto.GatewayServiceStatus) []*proto.GatewayServiceStatus {
	var allServices []*proto.GatewayServiceStatus

	for key, message := range serviceMessages {
		if metadata, ok := serviceMetadata[key]; ok {
			service := &proto.GatewayServiceStatus{
				ServiceName:  metadata.ServiceName,
				ServiceType:  metadata.ServiceType,
				Message:      message,
				Available:    metadata.Available,
				ResponseTime: metadata.ResponseTime,
				AgentId:      metadata.AgentId,
				GatewayId:    metadata.GatewayId,
				Partition:    metadata.Partition,
				Source:       metadata.Source,
				KvStoreId:    metadata.KvStoreId,
				TenantId:     metadata.TenantId,
				TenantSlug:   metadata.TenantSlug,
			}

			allServices = append(allServices, service)

			if len(message) > 1024*1024 { // Log large reassembled messages
				s.logger.Info().
					Str("service_name", metadata.ServiceName).
					Int("message_size", len(message)).
					Msg("Reassembled large service message")
			}
		}
	}

	return allServices
}

// processStreamedStatus validates and processes the assembled streaming data
func (s *Server) processStreamedStatus(
	ctx context.Context, stream proto.AgentGatewayService_StreamStatusServer, allServices []*proto.GatewayServiceStatus, metadata streamMetadata) error {
	if metadata.gatewayID == "" {
		return errEmptyGatewayID
	}

	resolvedSourceIP := s.resolveServiceHostIP(ctx, metadata.gatewayID, metadata.agentID, metadata.sourceIP)
	metadata.sourceIP = resolvedSourceIP

	s.validateLocationData(metadata)

	// Auto-register gateway if not already in service registry
	if err := s.ensureGatewayRegistered(ctx, metadata.gatewayID, metadata.sourceIP); err != nil {
		s.logger.Warn().Err(err).
			Str("gateway_id", metadata.gatewayID).
			Msg("Failed to auto-register gateway in service registry")
	}

	if !s.isKnownGateway(ctx, metadata.gatewayID) {
		s.logger.Warn().
			Str("gateway_id", metadata.gatewayID).
			Msg("Ignoring streaming status report from unknown gateway")

		return stream.SendAndClose(&proto.GatewayStatusResponse{Received: true})
	}

	req := &proto.GatewayStatusRequest{
		Services:  allServices,
		GatewayId: metadata.gatewayID,
		AgentId:   metadata.agentID,
		Timestamp: metadata.timestamp,
		Partition: metadata.partition,
		SourceIp:  metadata.sourceIP,
	}

	now := time.Unix(metadata.timestamp, 0)

	apiStatus, err := s.processStatusReport(ctx, req, now, resolvedSourceIP)
	if err != nil {
		return fmt.Errorf("failed to process streaming status report: %w", err)
	}

	s.updateAPIState(metadata.gatewayID, apiStatus)

	// Set span status for successful operations
	if span := trace.SpanFromContext(ctx); span != nil {
		span.SetStatus(codes.Ok, "Streaming status report processed successfully")
	}

	return stream.SendAndClose(&proto.GatewayStatusResponse{Received: true})
}

// validateLocationData logs warnings for missing location data
func (s *Server) validateLocationData(metadata streamMetadata) {
	if metadata.partition == "" || metadata.sourceIP == "" {
		s.logger.Warn().
			Str("gateway_id", metadata.gatewayID).
			Str("partition", metadata.partition).
			Str("source_ip", metadata.sourceIP).
			Msg("CRITICAL: Streaming status report missing required location data, device registration will be skipped")
	}
}

func getHostname() string {
	hostname, err := os.Hostname()
	if err != nil {
		return statusUnknown
	}

	return hostname
}

func (s *Server) getGatewayStatuses(ctx context.Context, forceRefresh bool) (map[string]*models.GatewayStatus, error) {
	// Try to use cached data with read lock
	s.cacheMutex.RLock()

	if !forceRefresh && time.Since(s.cacheLastUpdated) < defaultTimeout {
		result := s.copyGatewayStatusCache()
		s.cacheMutex.RUnlock()

		return result, nil
	}

	s.cacheMutex.RUnlock()

	// Acquire write lock to refresh cache
	s.cacheMutex.Lock()
	defer s.cacheMutex.Unlock()

	// Double-check cache
	if !forceRefresh && time.Since(s.cacheLastUpdated) < defaultTimeout {
		return s.copyGatewayStatusCache(), nil
	}

	// Query the database
	statuses, err := s.DB.ListGatewayStatuses(ctx, s.gatewayPatterns)
	if err != nil {
		return nil, fmt.Errorf("failed to query gateways: %w", err)
	}

	// Update the cache
	newCache := make(map[string]*models.GatewayStatus, len(statuses))

	for i := range statuses {
		ps := &models.GatewayStatus{
			GatewayID: statuses[i].GatewayID,
			IsHealthy: statuses[i].IsHealthy,
			LastSeen:  statuses[i].LastSeen,
			FirstSeen: statuses[i].FirstSeen,
		}

		if existing, ok := s.gatewayStatusCache[statuses[i].GatewayID]; ok {
			ps.LastEvaluated = existing.LastEvaluated
			ps.AlertSent = existing.AlertSent
		}

		newCache[statuses[i].GatewayID] = ps
	}

	s.gatewayStatusCache = newCache
	s.cacheLastUpdated = time.Now()

	return s.copyGatewayStatusCache(), nil
}

// copyGatewayStatusCache creates a copy of the gateway status cache.
func (s *Server) copyGatewayStatusCache() map[string]*models.GatewayStatus {
	result := make(map[string]*models.GatewayStatus, len(s.gatewayStatusCache))

	for k, v := range s.gatewayStatusCache {
		result[k] = v
	}

	return result
}

func (s *Server) resolveServiceHostIP(ctx context.Context, gatewayID, agentID, hostIP string) string {
	resolvedIP := normalizeHostIP(hostIP)

	resolveFromMetadata := func(metadata map[string]string) string {
		if metadata == nil {
			return ""
		}

		if ip := normalizeHostIP(metadata["source_ip"]); ip != "" {
			return ip
		}

		if ip := normalizeHostIP(metadata["host_ip"]); ip != "" {
			return ip
		}

		return ""
	}

	if resolvedIP == "" && s.ServiceRegistry != nil {
		if agentID != "" {
			if agent, err := s.ServiceRegistry.GetAgent(ctx, agentID); err == nil && agent != nil {
				if ip := resolveFromMetadata(agent.Metadata); ip != "" {
					resolvedIP = ip
				}
			}
		}

		if resolvedIP == "" && gatewayID != "" {
			if gateway, err := s.ServiceRegistry.GetGateway(ctx, gatewayID); err == nil && gateway != nil {
				if ip := resolveFromMetadata(gateway.Metadata); ip != "" {
					resolvedIP = ip
				}
			}
		}
	}

	if resolvedIP == "" && gatewayID != "" && s.DB != nil {
		if status, err := s.DB.GetGatewayStatus(ctx, gatewayID); err == nil && status != nil {
			if ip := normalizeHostIP(status.HostIP); ip != "" {
				resolvedIP = ip
			}
		}
	}

	return resolvedIP
}

// registerAgentInOCSF registers an agent in the ocsf_agents table.
func (s *Server) registerAgentInOCSF(ctx context.Context, agentID, gatewayID, hostIP string, capabilities []string) error {
	if s.DB == nil {
		return nil // Database not available
	}

	resolvedIP := s.resolveServiceHostIP(ctx, gatewayID, agentID, hostIP)

	// Create OCSF agent record
	agent := models.CreateOCSFAgentFromRegistration(agentID, gatewayID, resolvedIP, "", capabilities, nil)

	// Upsert the agent record
	if err := s.DB.UpsertOCSFAgent(ctx, agent); err != nil {
		return err
	}

	return nil
}

// registerCheckerAsDevice registers a checker as a device in the inventory
func (s *Server) registerCheckerAsDevice(ctx context.Context, checkerID, checkerKind, agentID, gatewayID, hostIP, partition string) error {
	if s.DeviceRegistry == nil {
		return nil // Registry not available
	}

	resolvedIP := s.resolveServiceHostIP(ctx, gatewayID, agentID, hostIP)
	normalizedPartition := strings.TrimSpace(partition)
	if normalizedPartition == "" {
		normalizedPartition = defaultPartition
	}

	metadata := map[string]string{
		"last_heartbeat": time.Now().Format(time.RFC3339),
	}
	if resolvedIP != "" {
		metadata["host_ip"] = resolvedIP
	}

	deviceUpdate := models.CreateCheckerDeviceUpdate(checkerID, checkerKind, agentID, gatewayID, resolvedIP, normalizedPartition, metadata)

	if hostname := s.getServiceHostname(agentID, resolvedIP); hostname != "" {
		deviceUpdate.Hostname = &hostname
		deviceUpdate.Metadata["hostname"] = hostname
	}

	if err := s.DeviceRegistry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{deviceUpdate}); err != nil {
		return err
	}

	capabilities := make([]string, 0, 1)
	if trimmed := strings.ToLower(strings.TrimSpace(checkerKind)); trimmed != "" {
		capabilities = append(capabilities, trimmed)
	}
	if len(capabilities) == 0 {
		capabilities = append(capabilities, "checker")
	}

	s.upsertCollectorCapabilities(ctx, deviceUpdate.DeviceID, capabilities, agentID, gatewayID, checkerID, deviceUpdate.Timestamp)

	eventMetadata := map[string]any{
		"checker_id": checkerID,
		"agent_id":   agentID,
		"gateway_id": gatewayID,
	}
	if normalizedPartition != "" {
		eventMetadata["partition"] = normalizedPartition
	}
	if resolvedIP != "" {
		eventMetadata["host_ip"] = resolvedIP
	}

	for _, capability := range capabilities {
		s.recordCapabilityEvent(ctx, &capabilityEventInput{
			DeviceID:    deviceUpdate.DeviceID,
			Capability:  capability,
			ServiceID:   checkerID,
			ServiceType: checkerKind,
			RecordedBy:  gatewayID,
			Enabled:     true,
			Success:     true,
			CheckedAt:   deviceUpdate.Timestamp,
			Metadata:    eventMetadata,
		})
	}

	return nil
}

// ensureGatewayRegistered ensures a gateway is registered in the service registry.
// This is called on first heartbeat to auto-register gateways that are configured
// but not yet in the registry (e.g., k8s, docker-compose services).
func (s *Server) ensureGatewayRegistered(ctx context.Context, gatewayID, sourceIP string) error {
	if s.ServiceRegistry == nil {
		return nil // Service registry not enabled
	}

	// Check if already registered
	existing, err := s.ServiceRegistry.GetGateway(ctx, gatewayID)
	if err == nil && existing != nil {
		// Already registered, just record heartbeat
		return s.ServiceRegistry.RecordHeartbeat(ctx, &registry.ServiceHeartbeat{
			ServiceID:   gatewayID,
			ServiceType: "gateway",
			GatewayID:   gatewayID,
			Timestamp:   time.Now().UTC(),
			SourceIP:    sourceIP,
			Healthy:     true,
		})
	}

	// Not registered yet - auto-register with implicit source
	s.logger.Info().
		Str("gateway_id", gatewayID).
		Str("source_ip", sourceIP).
		Msg("Auto-registering gateway from heartbeat")

	return s.ServiceRegistry.RegisterGateway(ctx, &registry.GatewayRegistration{
		GatewayID:          gatewayID,
		ComponentID:        gatewayID,
		RegistrationSource: registry.RegistrationSourceImplicit,
		Metadata: map[string]string{
			"source_ip":         sourceIP,
			"auto_registered":   "true",
			"registration_time": time.Now().UTC().Format(time.RFC3339),
		},
		SPIFFEIdentity: "", // Will be filled in if SPIFFE is detected later
		CreatedBy:      "system",
	})
}

// ensureAgentRegistered ensures an agent is registered in the service registry.
func (s *Server) ensureAgentRegistered(ctx context.Context, agentID, gatewayID, sourceIP string) error {
	if s.ServiceRegistry == nil {
		return nil
	}

	// Check if already registered
	existing, err := s.ServiceRegistry.GetAgent(ctx, agentID)
	if err == nil && existing != nil {
		// Already registered, just record heartbeat
		return s.ServiceRegistry.RecordHeartbeat(ctx, &registry.ServiceHeartbeat{
			ServiceID:   agentID,
			ServiceType: "agent",
			GatewayID:   gatewayID,
			AgentID:     agentID,
			Timestamp:   time.Now().UTC(),
			SourceIP:    sourceIP,
			Healthy:     true,
		})
	}

	// Auto-register
	s.logger.Info().
		Str("agent_id", agentID).
		Str("gateway_id", gatewayID).
		Msg("Auto-registering agent from heartbeat")

	return s.ServiceRegistry.RegisterAgent(ctx, &registry.AgentRegistration{
		AgentID:            agentID,
		GatewayID:          gatewayID,
		ComponentID:        agentID,
		RegistrationSource: registry.RegistrationSourceImplicit,
		Metadata: map[string]string{
			"source_ip":         sourceIP,
			"auto_registered":   "true",
			"registration_time": time.Now().UTC().Format(time.RFC3339),
		},
		SPIFFEIdentity: "",
		CreatedBy:      "system",
	})
}

// ensureCheckerRegistered ensures a checker is registered in the service registry.
func (s *Server) ensureCheckerRegistered(ctx context.Context, checkerID, agentID, gatewayID, checkerKind, sourceIP string) error {
	if s.ServiceRegistry == nil {
		return nil
	}

	// Check if already registered
	existing, err := s.ServiceRegistry.GetChecker(ctx, checkerID)
	if err == nil && existing != nil {
		// Already registered, just record heartbeat
		return s.ServiceRegistry.RecordHeartbeat(ctx, &registry.ServiceHeartbeat{
			ServiceID:   checkerID,
			ServiceType: "checker",
			GatewayID:   gatewayID,
			AgentID:     agentID,
			CheckerID:   checkerID,
			Timestamp:   time.Now().UTC(),
			SourceIP:    sourceIP,
			Healthy:     true,
		})
	}

	// Auto-register
	s.logger.Info().
		Str("checker_id", checkerID).
		Str("agent_id", agentID).
		Str("gateway_id", gatewayID).
		Str("checker_kind", checkerKind).
		Msg("Auto-registering checker from heartbeat")

	return s.ServiceRegistry.RegisterChecker(ctx, &registry.CheckerRegistration{
		CheckerID:          checkerID,
		AgentID:            agentID,
		GatewayID:          gatewayID,
		CheckerKind:        checkerKind,
		ComponentID:        checkerID,
		RegistrationSource: registry.RegistrationSourceImplicit,
		Metadata: map[string]string{
			"source_ip":         sourceIP,
			"auto_registered":   "true",
			"registration_time": time.Now().UTC().Format(time.RFC3339),
		},
		SPIFFEIdentity: "",
		CreatedBy:      "system",
	})
}
