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
	"os"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

func (s *Server) MonitorPollers(ctx context.Context) {
	ticker := time.NewTicker(monitorInterval)
	defer ticker.Stop()

	cleanupTicker := time.NewTicker(dailyCleanupInterval)
	defer cleanupTicker.Stop()

	if err := s.checkPollerStatus(ctx); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Initial state check failed")
	}

	if err := s.checkNeverReportedPollers(ctx); err != nil {
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
		}
	}
}

func (s *Server) handleMonitorTick(ctx context.Context) {
	if err := s.checkPollerStatus(ctx); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Poller state check failed")
	}

	if err := s.checkNeverReportedPollers(ctx); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Never-reported check failed")
	}
}

func (s *Server) checkPollerStatus(ctx context.Context) error {
	// Get all poller statuses
	pollerStatuses, err := s.getPollerStatuses(ctx, false)
	if err != nil {
		return fmt.Errorf("failed to get poller statuses: %w", err)
	}

	threshold := time.Now().Add(-s.alertThreshold)

	batchCtx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	// Process all pollers in a single pass
	for _, ps := range pollerStatuses {
		// Skip pollers evaluated recently
		if time.Since(ps.LastEvaluated) < defaultSkipInterval {
			continue
		}

		// Mark as evaluated
		ps.LastEvaluated = time.Now()

		// Handle poller status
		if err := s.handlePoller(batchCtx, ps, threshold); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", ps.PollerID).
				Msg("Error handling poller")
		}
	}

	return nil
}

// handlePoller processes an individual poller's status (offline or recovered).
func (s *Server) handlePoller(batchCtx context.Context, ps *models.PollerStatus, threshold time.Time) error {
	if ps.IsHealthy && ps.LastSeen.Before(threshold) {
		// Poller appears to be offline
		if !ps.AlertSent {
			duration := time.Since(ps.LastSeen).Round(time.Second)
			s.logger.Warn().
				Str("poller_id", ps.PollerID).
				Dur("duration", duration).
				Msg("Poller appears to be offline")

			if err := s.handlePollerDown(batchCtx, ps.PollerID, ps.LastSeen); err != nil {
				return err
			}

			ps.AlertSent = true
		}
	} else if !ps.IsHealthy && !ps.LastSeen.Before(threshold) && ps.AlertSent {
		// Backup recovery mechanism: poller is marked unhealthy but has reported recently
		// Primary recovery now happens in ReportStatus, but this serves as a safety net
		s.logger.Info().
			Str("poller_id", ps.PollerID).
			Msg("Poller detected as recovered via periodic check (backup mechanism)")

		// Simply clear the alert flag and mark as healthy - ReportStatus handles proper recovery events
		ps.AlertSent = false
		ps.IsHealthy = true
	}

	return nil
}

func (s *Server) flushPollerStatusUpdates(ctx context.Context) {
	ticker := time.NewTicker(defaultPollerStatusUpdateInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.pollerStatusUpdateMutex.Lock()
			updates := s.pollerStatusUpdates

			s.pollerStatusUpdates = make(map[string]*models.PollerStatus)
			s.pollerStatusUpdateMutex.Unlock()

			if len(updates) == 0 {
				continue
			}

			s.logger.Debug().
				Int("update_count", len(updates)).
				Msg("Flushing poller status updates")

			// Convert to a slice for batch processing
			statuses := make([]*models.PollerStatus, 0, len(updates))

			for _, status := range updates {
				statuses = append(statuses, status)
			}

			// Update in batches if your DB supports it
			// Otherwise, loop and update individually
			for _, status := range statuses {
				if err := s.DB.UpdatePollerStatus(ctx, status); err != nil {
					s.logger.Error().
						Err(err).
						Str("poller_id", status.PollerID).
						Msg("Error updating poller status")
				}
			}
		}
	}
}

func (s *Server) evaluatePollerHealth(
	ctx context.Context, pollerID string, lastSeen time.Time, isHealthy bool, threshold time.Time) error {
	s.logger.Debug().
		Str("poller_id", pollerID).
		Time("last_seen", lastSeen).
		Bool("is_healthy", isHealthy).
		Time("threshold", threshold).
		Msg("Evaluating poller health")

	if isHealthy && lastSeen.Before(threshold) {
		duration := time.Since(lastSeen).Round(time.Second)
		s.logger.Warn().
			Str("poller_id", pollerID).
			Dur("duration", duration).
			Msg("Poller appears to be offline")

		return s.handlePollerDown(ctx, pollerID, lastSeen)
	}

	if isHealthy && !lastSeen.Before(threshold) {
		return nil
	}

	if !lastSeen.Before(threshold) {
		currentHealth, err := s.getPollerHealthState(ctx, pollerID)
		if err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", pollerID).
				Msg("Error getting current health state for poller")

			return fmt.Errorf("failed to get current health state: %w", err)
		}

		if !isHealthy && currentHealth {
			return s.handlePotentialRecovery(ctx, pollerID, lastSeen)
		}
	}

	return nil
}

func (s *Server) handlePotentialRecovery(ctx context.Context, pollerID string, lastSeen time.Time) error {
	apiStatus := &api.PollerStatus{
		PollerID:   pollerID,
		LastUpdate: lastSeen,
		Services:   make([]api.ServiceStatus, 0),
	}

	s.handlePollerRecovery(ctx, pollerID, apiStatus, lastSeen, nil)

	return nil
}

func (s *Server) handlePollerDown(ctx context.Context, pollerID string, lastSeen time.Time) error {
	// Get the existing firstSeen value
	firstSeen := lastSeen

	s.cacheMutex.RLock()
	if ps, ok := s.pollerStatusCache[pollerID]; ok {
		firstSeen = ps.FirstSeen
	}

	s.cacheMutex.RUnlock()

	s.queuePollerStatusUpdate(pollerID, false, lastSeen, firstSeen)

	// Emit offline event to NATS if event publisher is available
	if s.eventPublisher != nil {
		// TODO: Extract source IP and partition from poller cache if available
		sourceIP := ""
		partition := ""

		if err := s.eventPublisher.PublishPollerOfflineEvent(ctx, pollerID, sourceIP, partition, lastSeen); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", pollerID).
				Msg("Failed to publish poller offline event")
		} else {
			s.logger.Info().
				Str("poller_id", pollerID).
				Msg("Published poller offline event")
		}
	}

	alert := &alerts.WebhookAlert{
		Level:     alerts.Error,
		Title:     "Poller Offline",
		Message:   fmt.Sprintf("Poller '%s' is offline", pollerID),
		PollerID:  pollerID,
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
		s.apiServer.UpdatePollerStatus(pollerID, &api.PollerStatus{
			PollerID:   pollerID,
			IsHealthy:  false,
			LastUpdate: lastSeen,
		})
	}

	return nil
}

func (s *Server) handlePollerRecovery(
	ctx context.Context,
	pollerID string,
	apiStatus *api.PollerStatus,
	timestamp time.Time,
	req *proto.PollerStatusRequest) {
	// Emit recovery event to NATS if event publisher is available
	if s.eventPublisher != nil {
		sourceIP := ""
		partition := ""

		if req != nil {
			sourceIP = req.SourceIp
			partition = req.Partition
		}

		// TODO: Extract remote address from gRPC context if needed
		remoteAddr := ""

		if err := s.eventPublisher.PublishPollerRecoveryEvent(
			ctx, pollerID, sourceIP, partition, remoteAddr, timestamp); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", pollerID).
				Msg("Failed to publish poller recovery event")
		} else {
			s.logger.Info().
				Str("poller_id", pollerID).
				Msg("Published poller recovery event")
		}
	}

	for _, webhook := range s.webhooks {
		alerter, ok := webhook.(*alerts.WebhookAlerter)
		if !ok {
			continue
		}

		// Check if the poller was previously marked as down
		alerter.Mu.RLock()
		wasDown := alerter.NodeDownStates[pollerID]
		alerter.Mu.RUnlock()

		if !wasDown {
			s.logger.Debug().
				Str("poller_id", pollerID).
				Msg("Skipping recovery alert: poller was not marked as down")

			continue
		}

		alerter.MarkPollerAsRecovered(pollerID)
		alerter.MarkServiceAsRecovered(pollerID)
	}

	alert := &alerts.WebhookAlert{
		Level:       alerts.Info,
		Title:       "Poller Recovered",
		Message:     fmt.Sprintf("Poller '%s' is back online", pollerID),
		PollerID:    pollerID,
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

func (s *Server) storePollerStatus(ctx context.Context, pollerID string, isHealthy bool, now time.Time) error {
	pollerStatus := &models.PollerStatus{
		PollerID:  pollerID,
		IsHealthy: isHealthy,
		LastSeen:  now,
	}

	if err := s.DB.UpdatePollerStatus(ctx, pollerStatus); err != nil {
		return fmt.Errorf("failed to store poller status: %w", err)
	}

	return nil
}

func (s *Server) updatePollerStatus(ctx context.Context, pollerID string, isHealthy bool, timestamp time.Time) error {
	pollerStatus := &models.PollerStatus{
		PollerID:  pollerID,
		IsHealthy: isHealthy,
		LastSeen:  timestamp,
	}

	existingStatus, err := s.DB.GetPollerStatus(ctx, pollerID)
	if err != nil && !errors.Is(err, db.ErrFailedToQuery) {
		return fmt.Errorf("failed to check poller existence: %w", err)
	}

	if err != nil {
		pollerStatus.FirstSeen = timestamp
	} else {
		pollerStatus.FirstSeen = existingStatus.FirstSeen
	}

	if err := s.DB.UpdatePollerStatus(ctx, pollerStatus); err != nil {
		return fmt.Errorf("failed to update poller status: %w", err)
	}

	return nil
}

func (s *Server) updatePollerState(
	ctx context.Context,
	pollerID string,
	apiStatus *api.PollerStatus,
	wasHealthy bool,
	now time.Time,
	req *proto.PollerStatusRequest) error {
	if err := s.storePollerStatus(ctx, pollerID, apiStatus.IsHealthy, now); err != nil {
		return err
	}

	if !wasHealthy && apiStatus.IsHealthy {
		s.handlePollerRecovery(ctx, pollerID, apiStatus, now, req)
	}

	return nil
}

func (s *Server) checkNeverReportedPollers(ctx context.Context) error {
	pollerIDs, err := s.DB.ListNeverReportedPollers(ctx, s.pollerPatterns)
	if err != nil {
		return fmt.Errorf("error querying unreported pollers: %w", err)
	}

	if len(pollerIDs) > 0 {
		alert := &alerts.WebhookAlert{
			Level:     alerts.Warning,
			Title:     "Pollers Never Reported",
			Message:   fmt.Sprintf("%d poller(s) have not reported since startup", len(pollerIDs)),
			PollerID:  "core",
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			Details: map[string]any{
				"hostname":     getHostname(),
				"poller_ids":   pollerIDs,
				"poller_count": len(pollerIDs),
			},
		}

		if err := s.sendAlert(ctx, alert); err != nil {
			s.logger.Error().
				Err(err).
				Msg("Error sending unreported pollers alert")

			return err
		}
	}

	return nil
}

func (s *Server) CheckNeverReportedPollersStartup(ctx context.Context) {
	s.logger.Debug().
		Interface("poller_patterns", s.pollerPatterns).
		Msg("Checking for unreported pollers matching patterns")

	if len(s.pollerPatterns) == 0 {
		s.logger.Debug().Msg("No poller patterns configured, skipping unreported poller check")

		return
	}

	// Clear poller status cache
	s.cacheMutex.Lock()
	s.pollerStatusCache = make(map[string]*models.PollerStatus)
	s.cacheLastUpdated = time.Time{}
	s.cacheMutex.Unlock()

	s.logger.Debug().Msg("Cleared poller status cache for startup check")

	pollerIDs, err := s.DB.ListNeverReportedPollers(ctx, s.pollerPatterns)
	if err != nil {
		s.logger.Error().
			Err(err).
			Msg("Error querying unreported pollers")

		return
	}

	s.logger.Info().
		Int("poller_count", len(pollerIDs)).
		Interface("poller_ids", pollerIDs).
		Msg("Found unreported pollers")

	if len(pollerIDs) > 0 {
		s.sendUnreportedPollersAlert(ctx, pollerIDs)
	} else {
		s.logger.Debug().Msg("No unreported pollers found")
	}
}

func (s *Server) sendUnreportedPollersAlert(ctx context.Context, pollerIDs []string) {
	alert := &alerts.WebhookAlert{
		Level:     alerts.Warning,
		Title:     "Pollers Never Reported",
		Message:   fmt.Sprintf("%d poller(s) have not reported since startup: %v", len(pollerIDs), pollerIDs),
		PollerID:  "core",
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname":     getHostname(),
			"poller_ids":   pollerIDs,
			"poller_count": len(pollerIDs),
		},
	}

	if err := s.sendAlert(ctx, alert); err != nil {
		s.logger.Error().
			Err(err).
			Msg("Error sending unreported pollers alert")
	} else {
		s.logger.Info().
			Int("poller_count", len(pollerIDs)).
			Msg("Sent alert for unreported pollers")
	}
}

func (s *Server) processStatusReport(
	ctx context.Context, req *proto.PollerStatusRequest, now time.Time) (*api.PollerStatus, error) {
	pollerStatus := &models.PollerStatus{
		PollerID:  req.PollerId,
		IsHealthy: true,
		LastSeen:  now,
	}

	existingStatus, err := s.DB.GetPollerStatus(ctx, req.PollerId)
	if err == nil {
		pollerStatus.FirstSeen = existingStatus.FirstSeen
		currentState := existingStatus.IsHealthy

		if err := s.DB.UpdatePollerStatus(ctx, pollerStatus); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", req.PollerId).
				Msg("Failed to store poller status")

			return nil, fmt.Errorf("failed to store poller status: %w", err)
		}

		apiStatus := s.createPollerStatus(req, now)
		s.processServices(ctx, req.PollerId, req.Partition, req.SourceIp, apiStatus, req.Services, now)

		if err := s.updatePollerState(ctx, req.PollerId, apiStatus, currentState, now, req); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", req.PollerId).
				Msg("Failed to update poller state")

			return nil, err
		}

		// Register the poller/agent as a device
		go func() {
			// Run in a separate goroutine to not block the main status report flow.
			// Skip registration if location data is missing. A warning is already logged in ReportStatus.
			if req.Partition == "" || req.SourceIp == "" {
				return
			}

			timeoutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			if err := s.registerServiceDevice(timeoutCtx, req.PollerId, s.findAgentID(req.Services),
				req.Partition, req.SourceIp, now); err != nil {
				s.logger.Warn().
					Err(err).
					Str("poller_id", req.PollerId).
					Msg("Failed to register service device for poller")
			}
		}()

		return apiStatus, nil
	}

	pollerStatus.FirstSeen = now

	if err := s.DB.UpdatePollerStatus(ctx, pollerStatus); err != nil {
		s.logger.Error().
			Err(err).
			Str("poller_id", req.PollerId).
			Msg("Failed to create new poller status")

		return nil, fmt.Errorf("failed to create poller status: %w", err)
	}

	// Emit first seen event to NATS if event publisher is available
	if s.eventPublisher != nil {
		// TODO: Extract remote address from gRPC context if needed
		remoteAddr := ""

		if err := s.eventPublisher.PublishPollerFirstSeenEvent(ctx, req.PollerId, req.SourceIp, req.Partition, remoteAddr, now); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", req.PollerId).
				Msg("Failed to publish poller first seen event")
		} else {
			s.logger.Info().
				Str("poller_id", req.PollerId).
				Msg("Published poller first seen event")
		}
	}

	apiStatus := s.createPollerStatus(req, now)
	s.processServices(ctx, req.PollerId, req.Partition, req.SourceIp, apiStatus, req.Services, now)

	// Register the poller/agent as a device for new pollers too
	go func() {
		// Run in a separate goroutine to not block the main status report flow.
		// Skip registration if location data is missing. A warning is already logged in ReportStatus.
		if req.Partition == "" || req.SourceIp == "" {
			return
		}

		timeoutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		if err := s.registerServiceDevice(timeoutCtx, req.PollerId, s.findAgentID(req.Services),
			req.Partition, req.SourceIp, now); err != nil {
			s.logger.Warn().
				Err(err).
				Str("poller_id", req.PollerId).
				Msg("Failed to register service device for poller")
		}
	}()

	return apiStatus, nil
}

func (*Server) createPollerStatus(req *proto.PollerStatusRequest, now time.Time) *api.PollerStatus {
	return &api.PollerStatus{
		PollerID:   req.PollerId,
		LastUpdate: now,
		IsHealthy:  true,
		Services:   make([]api.ServiceStatus, 0, len(req.Services)),
	}
}
func (s *Server) getPollerHealthState(ctx context.Context, pollerID string) (bool, error) {
	status, err := s.DB.GetPollerStatus(ctx, pollerID)
	if err != nil {
		return false, err
	}

	return status.IsHealthy, nil
}

func (s *Server) checkInitialStates(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	statuses, err := s.DB.ListPollerStatuses(ctx, s.pollerPatterns)
	if err != nil {
		s.logger.Error().
			Err(err).
			Msg("Error querying pollers")

		return
	}

	// Use a map to track which pollers we've already logged as offline
	reportedOffline := make(map[string]bool)

	for i := range statuses {
		duration := time.Since(statuses[i].LastSeen)

		// Only log each offline poller once
		if duration > s.alertThreshold && !reportedOffline[statuses[i].PollerID] {
			s.logger.Warn().
				Str("poller_id", statuses[i].PollerID).
				Dur("duration", duration.Round(time.Second)).
				Msg("Poller found offline during initial check")

			reportedOffline[statuses[i].PollerID] = true
		}
	}
}
func (s *Server) isKnownPoller(pollerID string) bool {
	for _, known := range s.config.KnownPollers {
		if known == pollerID {
			return true
		}
	}

	return false
}

func (s *Server) cleanupUnknownPollers(ctx context.Context) error {
	if len(s.config.KnownPollers) == 0 {
		return nil
	}

	pollerIDs, err := s.DB.ListPollers(ctx)
	if err != nil {
		return fmt.Errorf("failed to list pollers: %w", err)
	}

	var pollersToDelete []string

	for _, pollerID := range pollerIDs {
		isKnown := false

		for _, known := range s.config.KnownPollers {
			if known == pollerID {
				isKnown = true

				break
			}
		}

		if !isKnown {
			pollersToDelete = append(pollersToDelete, pollerID)
		}
	}

	for _, pollerID := range pollersToDelete {
		if err := s.DB.DeletePoller(ctx, pollerID); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", pollerID).
				Msg("Error deleting unknown poller")
		} else {
			s.logger.Info().
				Str("poller_id", pollerID).
				Msg("Deleted unknown poller")
		}
	}

	s.logger.Info().
		Int("poller_count", len(pollersToDelete)).
		Msg("Cleaned up unknown poller(s) from database")

	return nil
}

func (s *Server) monitorPollers(ctx context.Context) {
	s.logger.Info().
		Msg("Starting poller monitoring")

	time.Sleep(pollerDiscoveryTimeout)

	s.checkInitialStates(ctx)

	time.Sleep(pollerNeverReportedTimeout)

	s.CheckNeverReportedPollersStartup(ctx)

	s.MonitorPollers(ctx)
}

func (s *Server) queuePollerStatusUpdate(pollerID string, isHealthy bool, lastSeen, firstSeen time.Time) {
	// Validate timestamps
	if !isValidTimestamp(lastSeen) {
		lastSeen = time.Now()
	}

	if !isValidTimestamp(firstSeen) {
		firstSeen = lastSeen // Use lastSeen as a fallback
	}

	s.pollerStatusUpdateMutex.Lock()
	defer s.pollerStatusUpdateMutex.Unlock()

	s.pollerStatusUpdates[pollerID] = &models.PollerStatus{
		PollerID:  pollerID,
		IsHealthy: isHealthy,
		LastSeen:  lastSeen,
		FirstSeen: firstSeen,
	}
}

// findAgentID extracts the agent ID from the services if available
func (*Server) findAgentID(services []*proto.ServiceStatus) string {
	for _, svc := range services {
		if svc.AgentId != "" {
			return svc.AgentId
		}
	}

	return ""
}

func (s *Server) ReportStatus(ctx context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
	s.logger.Debug().
		Str("poller_id", req.PollerId).
		Int("service_count", len(req.Services)).
		Time("timestamp", time.Now()).
		Msg("Received status report")

	if req.PollerId == "" {
		return nil, errEmptyPollerID
	}

	// Validate required location fields - critical for device registration
	if req.Partition == "" || req.SourceIp == "" {
		s.logger.Warn().
			Str("poller_id", req.PollerId).
			Str("partition", req.Partition).
			Str("source_ip", req.SourceIp).
			Msg("CRITICAL: Status report missing required location data, device registration will be skipped")
	}

	if !s.isKnownPoller(req.PollerId) {
		s.logger.Warn().
			Str("poller_id", req.PollerId).
			Msg("Ignoring status report from unknown poller")

		return &proto.PollerStatusResponse{Received: true}, nil
	}

	now := time.Unix(req.Timestamp, 0)

	apiStatus, err := s.processStatusReport(ctx, req, now)
	if err != nil {
		return nil, fmt.Errorf("failed to process status report: %w", err)
	}

	s.updateAPIState(req.PollerId, apiStatus)

	// Explicitly set span status to OK for successful operations
	if span := trace.SpanFromContext(ctx); span != nil {
		span.SetStatus(codes.Ok, "Status report processed successfully")
	}

	return &proto.PollerStatusResponse{Received: true}, nil
}

// StreamStatus handles streaming status reports from pollers for large datasets
func (s *Server) StreamStatus(stream proto.PollerService_StreamStatusServer) error {
	var allServices []*proto.ServiceStatus

	var pollerID, agentID, partition, sourceIP string

	var timestamp int64

	s.logger.Debug().
		Msg("Starting streaming status reception")

	// Receive all chunks from the stream
	for {
		chunk, err := stream.Recv()
		if err != nil {
			if err.Error() == "EOF" {
				break
			}

			return fmt.Errorf("error receiving stream chunk: %w", err)
		}

		// Extract metadata from first chunk
		if pollerID == "" {
			pollerID = chunk.PollerId
			agentID = chunk.AgentId
			partition = chunk.Partition
			sourceIP = chunk.SourceIp
			timestamp = chunk.Timestamp
		}

		s.logger.Debug().
			Int32("chunk_index", chunk.ChunkIndex+1).
			Int32("total_chunks", chunk.TotalChunks).
			Str("poller_id", chunk.PollerId).
			Int("service_count", len(chunk.Services)).
			Msg("Received chunk")

		// Collect services from this chunk
		allServices = append(allServices, chunk.Services...)

		// If this is the final chunk, break
		if chunk.IsFinal {
			break
		}
	}

	s.logger.Debug().
		Str("poller_id", pollerID).
		Int("total_service_count", len(allServices)).
		Msg("Completed streaming reception")

	if pollerID == "" {
		return errEmptyPollerID
	}

	// Validate required location fields
	if partition == "" || sourceIP == "" {
		s.logger.Warn().
			Str("poller_id", pollerID).
			Str("partition", partition).
			Str("source_ip", sourceIP).
			Msg("CRITICAL: Streaming status report missing required location data, device registration will be skipped")
	}

	if !s.isKnownPoller(pollerID) {
		s.logger.Warn().
			Str("poller_id", pollerID).
			Msg("Ignoring streaming status report from unknown poller")

		return stream.SendAndClose(&proto.PollerStatusResponse{Received: true})
	}

	// Convert to regular PollerStatusRequest for processing
	req := &proto.PollerStatusRequest{
		Services:  allServices,
		PollerId:  pollerID,
		AgentId:   agentID,
		Timestamp: timestamp,
		Partition: partition,
		SourceIp:  sourceIP,
	}

	ctx := stream.Context()

	now := time.Unix(timestamp, 0)

	apiStatus, err := s.processStatusReport(ctx, req, now)
	if err != nil {
		return fmt.Errorf("failed to process streaming status report: %w", err)
	}

	s.updateAPIState(pollerID, apiStatus)

	// Explicitly set span status to OK for successful operations
	if span := trace.SpanFromContext(ctx); span != nil {
		span.SetStatus(codes.Ok, "Streaming status report processed successfully")
	}

	return stream.SendAndClose(&proto.PollerStatusResponse{Received: true})
}

func getHostname() string {
	hostname, err := os.Hostname()
	if err != nil {
		return statusUnknown
	}

	return hostname
}

func (s *Server) getPollerStatuses(ctx context.Context, forceRefresh bool) (map[string]*models.PollerStatus, error) {
	// Try to use cached data with read lock
	s.cacheMutex.RLock()

	if !forceRefresh && time.Since(s.cacheLastUpdated) < defaultTimeout {
		result := s.copyPollerStatusCache()
		s.cacheMutex.RUnlock()

		return result, nil
	}

	s.cacheMutex.RUnlock()

	// Acquire write lock to refresh cache
	s.cacheMutex.Lock()
	defer s.cacheMutex.Unlock()

	// Double-check cache
	if !forceRefresh && time.Since(s.cacheLastUpdated) < defaultTimeout {
		return s.copyPollerStatusCache(), nil
	}

	// Query the database
	statuses, err := s.DB.ListPollerStatuses(ctx, s.pollerPatterns)
	if err != nil {
		return nil, fmt.Errorf("failed to query pollers: %w", err)
	}

	// Update the cache
	newCache := make(map[string]*models.PollerStatus, len(statuses))

	for i := range statuses {
		ps := &models.PollerStatus{
			PollerID:  statuses[i].PollerID,
			IsHealthy: statuses[i].IsHealthy,
			LastSeen:  statuses[i].LastSeen,
			FirstSeen: statuses[i].FirstSeen,
		}

		if existing, ok := s.pollerStatusCache[statuses[i].PollerID]; ok {
			ps.LastEvaluated = existing.LastEvaluated
			ps.AlertSent = existing.AlertSent
		}

		newCache[statuses[i].PollerID] = ps
	}

	s.pollerStatusCache = newCache
	s.cacheLastUpdated = time.Now()

	return s.copyPollerStatusCache(), nil
}

// copyPollerStatusCache creates a copy of the poller status cache.
func (s *Server) copyPollerStatusCache() map[string]*models.PollerStatus {
	result := make(map[string]*models.PollerStatus, len(s.pollerStatusCache))

	for k, v := range s.pollerStatusCache {
		result[k] = v
	}

	return result
}
