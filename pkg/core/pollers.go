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
	"os"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

func (s *Server) MonitorPollers(ctx context.Context) {
	ticker := time.NewTicker(monitorInterval)
	defer ticker.Stop()

	cleanupTicker := time.NewTicker(dailyCleanupInterval)
	defer cleanupTicker.Stop()

	if err := s.checkPollerStatus(ctx); err != nil {
		log.Printf("Initial state check failed: %v", err)
	}

	if err := s.checkNeverReportedPollers(ctx); err != nil {
		log.Printf("Initial never-reported check failed: %v", err)
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
		log.Printf("Poller state check failed: %v", err)
	}

	if err := s.checkNeverReportedPollers(ctx); err != nil {
		log.Printf("Never-reported check failed: %v", err)
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
			log.Printf("Error handling poller %s: %v", ps.PollerID, err)
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
			log.Printf("Poller %s appears to be offline (last seen: %v ago)", ps.PollerID, duration)

			if err := s.handlePollerDown(batchCtx, ps.PollerID, ps.LastSeen); err != nil {
				return err
			}

			ps.AlertSent = true
		}
	} else if !ps.IsHealthy && !ps.LastSeen.Before(threshold) && ps.AlertSent {
		log.Printf("Poller %s has recovered", ps.PollerID)

		apiStatus := &api.PollerStatus{
			PollerID:   ps.PollerID,
			LastUpdate: ps.LastSeen,
			Services:   make([]api.ServiceStatus, 0),
		}

		s.handlePollerRecovery(batchCtx, ps.PollerID, apiStatus, ps.LastSeen)
		ps.AlertSent = false
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

			log.Printf("Flushing %d poller status updates", len(updates))

			// Convert to a slice for batch processing
			statuses := make([]*models.PollerStatus, 0, len(updates))

			for _, status := range updates {
				statuses = append(statuses, status)
			}

			// Update in batches if your DB supports it
			// Otherwise, loop and update individually
			for _, status := range statuses {
				if err := s.DB.UpdatePollerStatus(ctx, status); err != nil {
					log.Printf("Error updating poller status for %s: %v", status.PollerID, err)
				}
			}
		}
	}
}

func (s *Server) evaluatePollerHealth(
	ctx context.Context, pollerID string, lastSeen time.Time, isHealthy bool, threshold time.Time) error {
	log.Printf("Evaluating poller health: id=%s lastSeen=%v isHealthy=%v threshold=%v",
		pollerID, lastSeen.Format(time.RFC3339), isHealthy, threshold.Format(time.RFC3339))

	if isHealthy && lastSeen.Before(threshold) {
		duration := time.Since(lastSeen).Round(time.Second)
		log.Printf("Poller %s appears to be offline (last seen: %v ago)", pollerID, duration)

		return s.handlePollerDown(ctx, pollerID, lastSeen)
	}

	if isHealthy && !lastSeen.Before(threshold) {
		return nil
	}

	if !lastSeen.Before(threshold) {
		currentHealth, err := s.getPollerHealthState(ctx, pollerID)
		if err != nil {
			log.Printf("Error getting current health state for poller %s: %v", pollerID, err)

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

	s.handlePollerRecovery(ctx, pollerID, apiStatus, lastSeen)

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
		log.Printf("Failed to send down alert: %v", err)
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

func (s *Server) handlePollerRecovery(ctx context.Context, pollerID string, apiStatus *api.PollerStatus, timestamp time.Time) {
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
			log.Printf("Skipping recovery alert for %s: poller was not marked as down", pollerID)
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
		log.Printf("Failed to send recovery alert: %v", err)
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
	ctx context.Context, pollerID string, apiStatus *api.PollerStatus, wasHealthy bool, now time.Time) error {
	if err := s.storePollerStatus(ctx, pollerID, apiStatus.IsHealthy, now); err != nil {
		return err
	}

	if !wasHealthy && apiStatus.IsHealthy {
		s.handlePollerRecovery(ctx, pollerID, apiStatus, now)
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
			log.Printf("Error sending unreported pollers alert: %v", err)
			return err
		}
	}

	return nil
}

func (s *Server) CheckNeverReportedPollersStartup(ctx context.Context) {
	log.Printf("Checking for unreported pollers matching patterns: %v", s.pollerPatterns)

	if len(s.pollerPatterns) == 0 {
		log.Println("No poller patterns configured, skipping unreported poller check")

		return
	}

	// Clear poller status cache
	s.cacheMutex.Lock()
	s.pollerStatusCache = make(map[string]*models.PollerStatus)
	s.cacheLastUpdated = time.Time{}
	s.cacheMutex.Unlock()

	log.Println("Cleared poller status cache for startup check")

	pollerIDs, err := s.DB.ListNeverReportedPollers(ctx, s.pollerPatterns)
	if err != nil {
		log.Printf("Error querying unreported pollers: %v", err)

		return
	}

	log.Printf("Found %d unreported pollers: %v", len(pollerIDs), pollerIDs)

	if len(pollerIDs) > 0 {
		s.sendUnreportedPollersAlert(ctx, pollerIDs)
	} else {
		log.Println("No unreported pollers found")
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
		log.Printf("Error sending unreported pollers alert: %v", err)
	} else {
		log.Printf("Sent alert for %d unreported pollers", len(pollerIDs))
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
			log.Printf("Failed to store poller status for %s: %v", req.PollerId, err)

			return nil, fmt.Errorf("failed to store poller status: %w", err)
		}

		apiStatus := s.createPollerStatus(req, now)
		s.processServices(ctx, req.PollerId, req.Partition, req.SourceIp, apiStatus, req.Services, now)

		if err := s.updatePollerState(ctx, req.PollerId, apiStatus, currentState, now); err != nil {
			log.Printf("Failed to update poller state for %s: %v", req.PollerId, err)

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
				log.Printf("Failed to register service device for poller %s: %v", req.PollerId, err)
			}
		}()

		return apiStatus, nil
	}

	pollerStatus.FirstSeen = now

	if err := s.DB.UpdatePollerStatus(ctx, pollerStatus); err != nil {
		log.Printf("Failed to create new poller status for %s: %v", req.PollerId, err)

		return nil, fmt.Errorf("failed to create poller status: %w", err)
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
			log.Printf("Failed to register service device for poller %s: %v", req.PollerId, err)
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
		log.Printf("Error querying pollers: %v", err)

		return
	}

	// Use a map to track which pollers we've already logged as offline
	reportedOffline := make(map[string]bool)

	for i := range statuses {
		duration := time.Since(statuses[i].LastSeen)

		// Only log each offline poller once
		if duration > s.alertThreshold && !reportedOffline[statuses[i].PollerID] {
			log.Printf("Poller %s found offline during initial check (last seen: %v ago)",
				statuses[i].PollerID, duration.Round(time.Second))

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
			log.Printf("Error deleting unknown poller %s: %v", pollerID, err)
		} else {
			log.Printf("Deleted unknown poller: %s", pollerID)
		}
	}

	log.Printf("Cleaned up %d unknown poller(s) from database", len(pollersToDelete))

	return nil
}

func (s *Server) monitorPollers(ctx context.Context) {
	log.Printf("Starting poller monitoring...")

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
	log.Printf("Received status report from %s with %d services at %s",
		req.PollerId, len(req.Services), time.Now().Format(time.RFC3339Nano))

	if req.PollerId == "" {
		return nil, errEmptyPollerID
	}

	// Validate required location fields - critical for device registration
	if req.Partition == "" || req.SourceIp == "" {
		log.Printf("CRITICAL: Status report from poller %s missing required "+
			"location data (partition=%q, source_ip=%q). Device registration will be skipped.",
			req.PollerId, req.Partition, req.SourceIp)
	}

	if !s.isKnownPoller(req.PollerId) {
		log.Printf("Ignoring status report from unknown poller: %s", req.PollerId)

		return &proto.PollerStatusResponse{Received: true}, nil
	}

	now := time.Unix(req.Timestamp, 0)

	apiStatus, err := s.processStatusReport(ctx, req, now)
	if err != nil {
		return nil, fmt.Errorf("failed to process status report: %w", err)
	}

	s.updateAPIState(req.PollerId, apiStatus)

	return &proto.PollerStatusResponse{Received: true}, nil
}

// StreamStatus handles streaming status reports from pollers for large datasets
func (s *Server) StreamStatus(stream proto.PollerService_StreamStatusServer) error {
	var allServices []*proto.ServiceStatus

	var pollerID, agentID, partition, sourceIP string

	var timestamp int64

	log.Printf("Starting streaming status reception")

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

		log.Printf("Received chunk %d/%d from poller %s with %d services",
			chunk.ChunkIndex+1, chunk.TotalChunks, chunk.PollerId, len(chunk.Services))

		// Collect services from this chunk
		allServices = append(allServices, chunk.Services...)

		// If this is the final chunk, break
		if chunk.IsFinal {
			break
		}
	}

	log.Printf("Completed streaming reception from %s with %d total services", pollerID, len(allServices))

	if pollerID == "" {
		return errEmptyPollerID
	}

	// Validate required location fields
	if partition == "" || sourceIP == "" {
		log.Printf("CRITICAL: Streaming status report from poller %s missing required "+
			"location data (partition=%q, source_ip=%q). Device registration will be skipped.",
			pollerID, partition, sourceIP)
	}

	if !s.isKnownPoller(pollerID) {
		log.Printf("Ignoring streaming status report from unknown poller: %s", pollerID)
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
