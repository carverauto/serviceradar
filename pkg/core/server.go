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

// Package core pkg/core/server.go
package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/metricstore"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultPollerStatusUpdateInterval = 5 * time.Second
	shutdownTimeout                   = 10 * time.Second
	oneDay                            = 24 * time.Hour
	oneWeek                           = 7 * oneDay
	serviceradarDirPerms              = 0700
	pollerHistoryLimit                = 1000
	pollerDiscoveryTimeout            = 30 * time.Second
	pollerNeverReportedTimeout        = 30 * time.Second
	defaultDBPath                     = "/var/lib/serviceradar/serviceradar.db"
	statusUnknown                     = "unknown"
	sweepService                      = "sweep"
	dailyCleanupInterval              = 24 * time.Hour
	monitorInterval                   = 30 * time.Second
	defaultSkipInterval               = 5 * time.Minute
	defaultTimeout                    = 30 * time.Second
	defaultFlushInterval              = 10 * time.Second

	snmpDiscoveryResultsServiceType = "snmp-discovery-results"
	mapperDiscoveryServiceType      = "mapper_discovery" // Add this new constant
)

func NewServer(ctx context.Context, config *models.DBConfig) (*Server, error) {
	normalizedConfig := normalizeConfig(config)

	database, err := db.New(ctx, normalizedConfig)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errDatabaseError, err)
	}

	authConfig, err := initializeAuthConfig(normalizedConfig)
	if err != nil {
		return nil, err
	}

	metricsConfig := models.MetricsConfig{
		Enabled:    normalizedConfig.Metrics.Enabled,
		Retention:  normalizedConfig.Metrics.Retention,
		MaxPollers: normalizedConfig.Metrics.MaxPollers,
	}
	metricsManager := metrics.NewManager(metricsConfig, database)

	server := &Server{
		DB:                  database,
		alertThreshold:      normalizedConfig.AlertThreshold,
		webhooks:            make([]alerts.AlertService, 0),
		ShutdownChan:        make(chan struct{}),
		pollerPatterns:      normalizedConfig.PollerPatterns,
		metrics:             metricsManager,
		snmpManager:         metricstore.NewSNMPManager(database),
		rperfManager:        metricstore.NewRperfManager(database),
		config:              normalizedConfig,
		authService:         auth.NewAuth(authConfig, database),
		metricBuffers:       make(map[string][]*models.TimeseriesMetric),
		serviceBuffers:      make(map[string][]*models.ServiceStatus),
		sysmonBuffers:       make(map[string][]*models.SysmonMetrics),
		bufferMu:            sync.RWMutex{},
		pollerStatusCache:   make(map[string]*models.PollerStatus),
		pollerStatusUpdates: make(map[string]*models.PollerStatus),
	}

	// Initialize the cache on startup
	if _, err := server.getPollerStatuses(ctx, true); err != nil {
		log.Printf("Warning: Failed to initialize poller status cache: %v", err)
	}

	go server.flushBuffers(ctx)
	go server.flushPollerStatusUpdates(ctx)

	server.initializeWebhooks(normalizedConfig.Webhooks)

	return server, nil
}

func isValidTimestamp(t time.Time) bool {
	// Check if the timestamp is within valid range for Proton
	minTime := time.Date(1925, 1, 1, 0, 0, 0, 0, time.UTC)
	maxTime := time.Date(2283, 11, 11, 0, 0, 0, 0, time.UTC)

	return t.After(minTime) && t.Before(maxTime)
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

// flushBuffers flushes buffered data to the database periodically.
func (s *Server) flushBuffers(ctx context.Context) {
	ticker := time.NewTicker(defaultFlushInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.flushAllBuffers(ctx)
		}
	}
}

// flushAllBuffers flushes all buffer types to the database.
func (s *Server) flushAllBuffers(ctx context.Context) {
	s.bufferMu.Lock()
	defer s.bufferMu.Unlock()

	s.flushMetrics(ctx)
	s.flushServiceStatuses(ctx)
	s.flushSysmonMetrics(ctx)
}

// flushMetrics flushes metric buffers to the database.
func (s *Server) flushMetrics(ctx context.Context) {
	for pollerID, timeseriesMetrics := range s.metricBuffers {
		if len(timeseriesMetrics) == 0 {
			continue
		}

		metricsToFlush := make([]*models.TimeseriesMetric, len(timeseriesMetrics))
		copy(metricsToFlush, timeseriesMetrics)
		// It's important to clear the original buffer slice for this poller ID
		// under the lock to prevent race conditions if new metrics come in
		// while StoreMetrics is running.
		s.metricBuffers[pollerID] = nil

		if err := s.DB.StoreMetrics(ctx, pollerID, metricsToFlush); err != nil {
			log.Printf("CRITICAL DB WRITE ERROR: Failed to flush/StoreMetrics for poller %s: %v. "+
				"Number of metrics attempted: %d", pollerID, err, len(metricsToFlush))
		} else {
			log.Printf("Successfully flushed %d timeseries metrics for poller %s",
				len(metricsToFlush), pollerID)
		}
	}
}

// flushServiceStatuses flushes service status buffers to the database.
func (s *Server) flushServiceStatuses(ctx context.Context) {
	for pollerID, statuses := range s.serviceBuffers {
		if len(statuses) == 0 {
			continue
		}

		if err := s.DB.UpdateServiceStatuses(ctx, statuses); err != nil {
			log.Printf("Failed to flush service statuses for poller %s: %v", pollerID, err)
		}

		s.serviceBuffers[pollerID] = nil
	}
}

// flushSysmonMetrics flushes system monitor metrics to the database.
func (s *Server) flushSysmonMetrics(ctx context.Context) {
	for pollerID, sysmonMetrics := range s.sysmonBuffers {
		if len(sysmonMetrics) == 0 {
			continue
		}

		for _, metric := range sysmonMetrics {
			if err := s.DB.StoreSysmonMetrics(ctx, pollerID, metric, metric.CPUs[0].Timestamp); err != nil {
				log.Printf("Failed to flush sysmon metrics for poller %s: %v", pollerID, err)
			}
		}

		s.sysmonBuffers[pollerID] = nil
	}
}

const (
	defaultMetricsRetention  = 100
	defaultMetricsMaxPollers = 10000
)

func normalizeConfig(config *models.DBConfig) *models.DBConfig {
	normalized := *config

	// Set the DB parameters from the Database struct
	if len(normalized.Database.Addresses) > 0 {
		// Set the first address as the primary DB address
		normalized.DBAddr = normalized.Database.Addresses[0]
	}

	normalized.DBName = normalized.Database.Name
	normalized.DBUser = normalized.Database.Username
	normalized.DBPass = normalized.Database.Password

	// Default settings if not specified
	if normalized.Metrics.Retention == 0 {
		normalized.Metrics.Retention = defaultMetricsRetention
	}

	if normalized.Metrics.MaxPollers == 0 {
		normalized.Metrics.MaxPollers = defaultMetricsMaxPollers
	}

	return &normalized
}

func getDBPath(configPath string) string {
	if configPath == "" {
		return defaultDBPath
	}

	return configPath
}

func ensureDataDirectory(dbPath string) error {
	dir := filepath.Dir(dbPath)

	return os.MkdirAll(dir, serviceradarDirPerms)
}

func initializeAuthConfig(config *models.DBConfig) (*models.AuthConfig, error) {
	authConfig := &models.AuthConfig{
		JWTSecret:     os.Getenv("JWT_SECRET"),
		JWTExpiration: 24 * time.Hour,
		CallbackURL:   os.Getenv("AUTH_CALLBACK_URL"),
		LocalUsers:    make(map[string]string),
	}

	if config.Auth != nil {
		applyAuthOverrides(authConfig, config.Auth)
	} else {
		applyDefaultAdminUser(authConfig)
	}

	if authConfig.JWTSecret == "" {
		return nil, errJWTSecretRequired
	}

	return authConfig, nil
}

func applyAuthOverrides(authConfig, configAuth *models.AuthConfig) {
	if configAuth.JWTSecret != "" {
		authConfig.JWTSecret = configAuth.JWTSecret
	}

	if configAuth.JWTExpiration != 0 {
		authConfig.JWTExpiration = configAuth.JWTExpiration
	}

	if len(configAuth.LocalUsers) > 0 {
		authConfig.LocalUsers = configAuth.LocalUsers
	}
}

func applyDefaultAdminUser(authConfig *models.AuthConfig) {
	if adminHash := os.Getenv("ADMIN_PASSWORD_HASH"); adminHash != "" {
		authConfig.LocalUsers["admin"] = adminHash
	}
}

func (s *Server) initializeWebhooks(configs []alerts.WebhookConfig) {
	for i, config := range configs {
		log.Printf("Processing webhook config %d: enabled=%v", i, config.Enabled)

		if config.Enabled {
			alerter := alerts.NewWebhookAlerter(config)
			s.webhooks = append(s.webhooks, alerter)

			log.Printf("Added webhook alerter: %+v", config.URL)
		}
	}
}

func (s *Server) Start(ctx context.Context) error {
	log.Printf("Starting core service...")

	if err := s.cleanupUnknownPollers(ctx); err != nil {
		log.Printf("Warning: Failed to clean up unknown pollers: %v", err)
	}

	if s.grpcServer != nil {
		errCh := make(chan error, 1)

		go func() {
			if err := s.grpcServer.Start(); err != nil {
				select {
				case errCh <- err:
				default:
					log.Printf("gRPC server error: %v", err)
				}
			}
		}()
	}

	if err := s.sendStartupNotification(ctx); err != nil {
		log.Printf("Failed to send startup notification: %v", err)
	}

	go s.runMetricsCleanup(ctx)
	go s.monitorPollers(ctx)

	return nil
}

func (s *Server) Stop(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()

	if err := s.sendShutdownNotification(ctx); err != nil {
		log.Printf("Failed to send shutdown notification: %v", err)
	}

	if s.grpcServer != nil {
		s.grpcServer.Stop(ctx)
	}

	if err := s.DB.Close(); err != nil {
		log.Printf("Error closing database: %v", err)
	}

	close(s.ShutdownChan)

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

func (s *Server) GetMetricsManager() metrics.MetricCollector {
	return s.metrics
}

func (s *Server) GetSNMPManager() metricstore.SNMPManager {
	return s.snmpManager
}

func (s *Server) runMetricsCleanup(ctx context.Context) {
	ticker := time.NewTicker(1 * time.Hour)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if s.metrics != nil {
				s.metrics.CleanupStalePollers(oneWeek)
			} else {
				log.Printf("Error: metrics manager is nil")
			}
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

func (s *Server) sendStartupNotification(ctx context.Context) error {
	if len(s.webhooks) == 0 {
		return nil
	}

	alert := &alerts.WebhookAlert{
		Level:     alerts.Info,
		Title:     "Core Service Started",
		Message:   fmt.Sprintf("ServiceRadar core service initialized at %s", time.Now().Format(time.RFC3339)),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		PollerID:  "core",
		Details: map[string]any{
			"version":  "1.0.36",
			"hostname": getHostname(),
		},
	}

	return s.sendAlert(ctx, alert)
}

func (s *Server) sendShutdownNotification(ctx context.Context) error {
	if len(s.webhooks) == 0 {
		return nil
	}

	alert := &alerts.WebhookAlert{
		Level: alerts.Warning,
		Title: "Core Service Stopping",
		Message: fmt.Sprintf("ServiceRadar core service shutting down at %s",
			time.Now().Format(time.RFC3339)),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		PollerID:  "core",
		Details: map[string]any{
			"hostname": getHostname(),
		},
	}

	return s.sendAlert(ctx, alert)
}

func (s *Server) Shutdown(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()

	if err := s.DB.Close(); err != nil {
		log.Printf("Error closing database: %v", err)
	}

	if len(s.webhooks) > 0 {
		alert := alerts.WebhookAlert{
			Level: alerts.Warning,
			Title: "Core Service Stopping",
			Message: fmt.Sprintf("ServiceRadar core service shutting down at %s",
				time.Now().Format(time.RFC3339)),
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			PollerID:  "core",
			Details: map[string]any{
				"hostname": getHostname(),
				"pid":      os.Getpid(),
			},
		}

		err := s.sendAlert(ctx, &alert)
		if err != nil {
			log.Printf("Error sending shutdown alert: %v", err)

			return
		}
	}

	close(s.ShutdownChan)
}

const (
	defaultShortTimeout = 10 * time.Second
)

func (s *Server) SetAPIServer(ctx context.Context, apiServer api.Service) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.apiServer = apiServer
	apiServer.SetKnownPollers(s.config.KnownPollers)

	apiServer.SetPollerHistoryHandler(ctx, func(pollerID string) ([]api.PollerHistoryPoint, error) {
		ctxWithTimeout, cancel := context.WithTimeout(ctx, defaultShortTimeout)
		defer cancel()

		points, err := s.DB.GetPollerHistoryPoints(ctxWithTimeout, pollerID, pollerHistoryLimit)
		if err != nil {
			return nil, fmt.Errorf("failed to get poller history: %w", err)
		}

		apiPoints := make([]api.PollerHistoryPoint, len(points))
		for i, p := range points {
			apiPoints[i] = api.PollerHistoryPoint{
				Timestamp: p.Timestamp,
				IsHealthy: p.IsHealthy,
			}
		}

		return apiPoints, nil
	})
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

func (s *Server) updateAPIState(pollerID string, apiStatus *api.PollerStatus) {
	if s.apiServer == nil {
		log.Printf("Warning: API server not initialized, state not updated")

		return
	}

	s.apiServer.UpdatePollerStatus(pollerID, apiStatus)

	log.Printf("Updated API server state for poller: %s", pollerID)
}

func (s *Server) getPollerHealthState(ctx context.Context, pollerID string) (bool, error) {
	status, err := s.DB.GetPollerStatus(ctx, pollerID)
	if err != nil {
		return false, err
	}

	return status.IsHealthy, nil
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
		s.processServices(ctx, req.PollerId, apiStatus, req.Services, now)

		if err := s.updatePollerState(ctx, req.PollerId, apiStatus, currentState, now); err != nil {
			log.Printf("Failed to update poller state for %s: %v", req.PollerId, err)

			return nil, err
		}

		return apiStatus, nil
	}

	pollerStatus.FirstSeen = now

	if err := s.DB.UpdatePollerStatus(ctx, pollerStatus); err != nil {
		log.Printf("Failed to create new poller status for %s: %v", req.PollerId, err)

		return nil, fmt.Errorf("failed to create poller status: %w", err)
	}

	apiStatus := s.createPollerStatus(req, now)
	s.processServices(ctx, req.PollerId, apiStatus, req.Services, now)

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

// processServices processes service statuses for a poller and updates the API status.
func (s *Server) processServices(
	ctx context.Context,
	pollerID string,
	apiStatus *api.PollerStatus,
	services []*proto.ServiceStatus,
	now time.Time) {
	allServicesAvailable := true
	serviceStatuses := make([]*models.ServiceStatus, 0, len(services))

	for _, svc := range services {
		apiService := s.createAPIService(svc)

		if !svc.Available {
			allServicesAvailable = false
		}

		if err := s.processServiceDetails(ctx, pollerID, &apiService, svc, now); err != nil {
			log.Printf("Error processing details for service %s on poller %s: %v",
				svc.ServiceName, pollerID, err)
		}

		serviceStatuses = append(serviceStatuses, &models.ServiceStatus{
			AgentID:     svc.AgentId,
			PollerID:    svc.PollerId,
			ServiceName: apiService.Name,
			ServiceType: apiService.Type,
			Available:   apiService.Available,
			Details:     apiService.Message,
			Timestamp:   now,
		})

		apiStatus.Services = append(apiStatus.Services, apiService)

		if svc.AgentId == "" {
			log.Printf("Warning: Service %s on poller %s has empty AgentID", svc.ServiceName, svc.PollerId)
		} else {
			log.Printf("Service %s on poller %s has AgentID: %s", svc.ServiceName, svc.PollerId, svc.AgentId)
		}

		if svc.PollerId == "" {
			log.Printf("Warning: Service %s has empty PollerID, using fallback %s", svc.ServiceName, pollerID)
		}
	}

	s.bufferMu.Lock()
	s.serviceBuffers[pollerID] = append(s.serviceBuffers[pollerID], serviceStatuses...)
	s.bufferMu.Unlock()

	apiStatus.IsHealthy = allServicesAvailable
}

// processServiceDetails handles parsing and processing of service details and metrics.
func (s *Server) processServiceDetails(
	ctx context.Context,
	pollerID string,
	apiService *api.ServiceStatus,
	svc *proto.ServiceStatus,
	now time.Time,
) error {
	// Check if svc.Message is nil or empty
	if len(svc.Message) == 0 {
		log.Printf("No message content for service %s on poller %s", svc.ServiceName, pollerID)
		return s.handleService(ctx, apiService, now)
	}

	details, err := s.parseServiceDetails(svc)
	if err != nil {
		log.Printf("Failed to parse details for service %s on poller %s, proceeding without details",
			svc.ServiceName, pollerID)

		if svc.ServiceType == snmpDiscoveryResultsServiceType {
			return fmt.Errorf("failed to parse snmp-discovery-results payload: %w", err)
		}

		return s.handleService(ctx, apiService, now)
	}

	apiService.Details = details

	if err := s.processMetrics(ctx, pollerID, svc, details, now); err != nil {
		log.Printf("Error processing metrics for service %s on poller %s: %v",
			svc.ServiceName, pollerID, err)
		return err
	}

	return s.handleService(ctx, apiService, now)
}

// processMetrics handles metrics processing for all service types.
func (s *Server) processMetrics(
	ctx context.Context,
	pollerID string,
	svc *proto.ServiceStatus,
	details json.RawMessage,
	now time.Time) error {
	switch svc.ServiceType {
	case snmpServiceType:
		return s.processSNMPMetrics(pollerID, details, now)
	case grpcServiceType:
		switch svc.ServiceName {
		case rperfServiceType:
			return s.processRperfMetrics(pollerID, details, now)
		case sysmonServiceType:
			return s.processSysmonMetrics(pollerID, details, now)
		}
	case icmpServiceType:
		return s.processICMPMetrics(pollerID, svc, details, now)
	case snmpDiscoveryResultsServiceType, mapperDiscoveryServiceType:
		return s.processSNMPDiscoveryResults(ctx, pollerID, svc, details, now)
	}

	return nil
}

func (*Server) createAPIService(svc *proto.ServiceStatus) api.ServiceStatus {
	return api.ServiceStatus{
		Name:      svc.ServiceName,
		Type:      svc.ServiceType,
		Available: svc.Available,
		Message:   svc.Message,
		AgentID:   svc.AgentId,
		PollerID:  svc.PollerId,
	}
}

func (*Server) parseServiceDetails(svc *proto.ServiceStatus) (json.RawMessage, error) {
	var details json.RawMessage

	if err := json.Unmarshal(svc.Message, &details); err != nil {
		log.Printf("Error unmarshaling service details for %s: %v", svc.ServiceName, err)
		return nil, err
	}

	return details, nil
}

const (
	grpcServiceType   = "grpc"
	icmpServiceType   = "icmp"
	snmpServiceType   = "snmp"
	rperfServiceType  = "rperf-checker"
	sysmonServiceType = "sysmon"
)

func (s *Server) processSysmonMetrics(pollerID string, details json.RawMessage, timestamp time.Time) error {
	log.Printf("Processing sysmon metrics for poller %s with details: %s", pollerID, string(details))

	// Define the full structure of the message payload
	var sysmonPayload struct {
		Available    bool  `json:"available"`
		ResponseTime int64 `json:"response_time"`
		Status       struct {
			Timestamp string              `json:"timestamp"`
			HostID    string              `json:"host_id"`
			CPUs      []models.CPUMetric  `json:"cpus"`
			Disks     []models.DiskMetric `json:"disks"`
			Memory    models.MemoryMetric `json:"memory"`
		} `json:"status"`
	}

	if err := json.Unmarshal(details, &sysmonPayload); err != nil {
		log.Printf("Error unmarshaling sysmon data for poller %s: %v", pollerID, err)
		return fmt.Errorf("failed to parse sysmon data: %w", err)
	}

	// Parse the poller's timestamp
	pollerTimestamp, err := time.Parse(time.RFC3339Nano, sysmonPayload.Status.Timestamp)
	if err != nil {
		log.Printf("Invalid timestamp in sysmon data for poller %s: %v, using server timestamp", pollerID, err)

		pollerTimestamp = timestamp
	}

	hasMemoryData := sysmonPayload.Status.Memory.TotalBytes > 0 || sysmonPayload.Status.Memory.UsedBytes > 0
	m := &models.SysmonMetrics{
		CPUs:   make([]models.CPUMetric, len(sysmonPayload.Status.CPUs)),
		Disks:  make([]models.DiskMetric, len(sysmonPayload.Status.Disks)),
		Memory: models.MemoryMetric{},
	}

	for i, cpu := range sysmonPayload.Status.CPUs {
		m.CPUs[i] = models.CPUMetric{
			CoreID:       cpu.CoreID,
			UsagePercent: cpu.UsagePercent,
			Timestamp:    pollerTimestamp,
		}
	}

	for i, disk := range sysmonPayload.Status.Disks {
		m.Disks[i] = models.DiskMetric{
			MountPoint: disk.MountPoint,
			UsedBytes:  disk.UsedBytes,
			TotalBytes: disk.TotalBytes,
			Timestamp:  pollerTimestamp,
		}
	}

	if hasMemoryData {
		m.Memory = models.MemoryMetric{
			UsedBytes:  sysmonPayload.Status.Memory.UsedBytes,
			TotalBytes: sysmonPayload.Status.Memory.TotalBytes,
			Timestamp:  pollerTimestamp,
		}
	}

	s.bufferMu.Lock()
	s.sysmonBuffers[pollerID] = append(s.sysmonBuffers[pollerID], m)
	s.bufferMu.Unlock()

	log.Printf("Parsed %d CPU metrics for poller %s with timestamp %s",
		len(sysmonPayload.Status.CPUs), pollerID, sysmonPayload.Status.Timestamp)

	return nil
}

// parseRperfPayload unmarshals the rperf payload and extracts the timestamp
func (*Server) parseRperfPayload(details json.RawMessage, timestamp time.Time) (struct {
	Available    bool  `json:"available"`
	ResponseTime int64 `json:"response_time"`
	Status       struct {
		Results []*struct {
			Target  string             `json:"target"`
			Success bool               `json:"success"`
			Error   *string            `json:"error"`
			Status  models.RperfMetric `json:"status"`
		} `json:"results"`
		Timestamp string `json:"timestamp"`
	} `json:"status"`
}, time.Time, error) {
	var rperfPayload struct {
		Available    bool  `json:"available"`
		ResponseTime int64 `json:"response_time"`
		Status       struct {
			Results []*struct {
				Target  string             `json:"target"`
				Success bool               `json:"success"`
				Error   *string            `json:"error"`
				Status  models.RperfMetric `json:"status"` // Updated to match "status" field
			} `json:"results"`
			Timestamp string `json:"timestamp"`
		} `json:"status"`
	}

	if err := json.Unmarshal(details, &rperfPayload); err != nil {
		return rperfPayload, timestamp, fmt.Errorf("failed to parse rperf data: %w", err)
	}

	// Parse the timestamp
	pollerTimestamp, err := time.Parse(time.RFC3339Nano, rperfPayload.Status.Timestamp)
	if err != nil {
		pollerTimestamp = timestamp
	}

	return rperfPayload, pollerTimestamp, nil
}

// processRperfResult processes a single rperf result and returns the corresponding metrics
func (*Server) processRperfResult(result *struct {
	Target  string             `json:"target"`
	Success bool               `json:"success"`
	Error   *string            `json:"error"`
	Status  models.RperfMetric `json:"status"`
}, pollerID string, responseTime int64, pollerTimestamp time.Time) ([]*models.TimeseriesMetric, error) {
	if !result.Success {
		return nil, fmt.Errorf("skipping failed rperf test (Target: %s). Error: %v", result.Target, result.Error)
	}

	// Create RperfMetric for metadata
	rperfMetric := models.RperfMetric{
		Target:          result.Target,
		Success:         result.Success,
		Error:           result.Error,
		BitsPerSec:      result.Status.BitsPerSec,
		BytesReceived:   result.Status.BytesReceived,
		BytesSent:       result.Status.BytesSent,
		Duration:        result.Status.Duration,
		JitterMs:        result.Status.JitterMs,
		LossPercent:     result.Status.LossPercent,
		PacketsLost:     result.Status.PacketsLost,
		PacketsReceived: result.Status.PacketsReceived,
		PacketsSent:     result.Status.PacketsSent,
		ResponseTime:    responseTime,
	}

	// Marshal the RperfMetric as metadata
	metadataBytes, err := json.Marshal(rperfMetric)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal rperf metadata for target %s: %w", result.Target, err)
	}

	metadataStr := string(metadataBytes)

	var timeseriesMetrics = make([]*models.TimeseriesMetric, 0, 4) // Pre-allocate for 4 metrics

	const (
		defaultFmt                  = "%.2f"
		defaultLossFmt              = "%.1f"
		defaultBitsPerSecondDivisor = 1e6
	)

	metricsToStore := []struct {
		Name  string
		Value string
	}{
		{
			Name:  fmt.Sprintf("rperf_%s_bandwidth_mbps", result.Target),
			Value: fmt.Sprintf(defaultFmt, result.Status.BitsPerSec/defaultBitsPerSecondDivisor),
		},
		{
			Name:  fmt.Sprintf("rperf_%s_jitter_ms", result.Target),
			Value: fmt.Sprintf(defaultFmt, result.Status.JitterMs),
		},
		{
			Name:  fmt.Sprintf("rperf_%s_loss_percent", result.Target),
			Value: fmt.Sprintf(defaultLossFmt, result.Status.LossPercent),
		},
		{
			Name:  fmt.Sprintf("rperf_%s_response_time_ns", result.Target),
			Value: fmt.Sprintf("%d", responseTime),
		},
	}

	for _, m := range metricsToStore {
		metric := &models.TimeseriesMetric{
			Name:      m.Name,
			Value:     m.Value,
			Type:      "rperf",
			Timestamp: pollerTimestamp,
			Metadata:  metadataStr,
			PollerID:  pollerID,
		}

		timeseriesMetrics = append(timeseriesMetrics, metric)
	}

	return timeseriesMetrics, nil
}

// bufferRperfMetrics adds the metrics to the buffer for the given poller
func (s *Server) bufferRperfMetrics(pollerID string, metrics []*models.TimeseriesMetric) {
	s.bufferMu.Lock()
	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], metrics...)
	s.bufferMu.Unlock()
}

func (s *Server) processRperfMetrics(pollerID string, details json.RawMessage, timestamp time.Time) error {
	log.Printf("Processing rperf metrics for poller %s with details: %s", pollerID, string(details))

	rperfPayload, pollerTimestamp, err := s.parseRperfPayload(details, timestamp)
	if err != nil {
		log.Printf("Error unmarshaling rperf data for poller %s: %v", pollerID, err)
		return err
	}

	var allMetrics []*models.TimeseriesMetric

	for i := range rperfPayload.Status.Results {
		rperfResult, err := s.processRperfResult(rperfPayload.Status.Results[i], pollerID, rperfPayload.ResponseTime, pollerTimestamp)
		if err != nil {
			log.Printf("%v", err)
			continue
		}

		allMetrics = append(allMetrics, rperfResult...)
	}

	// Buffer rperf timeseriesMetrics
	s.bufferRperfMetrics(pollerID, allMetrics)

	log.Printf("Parsed %d rperf metrics for poller %s with timestamp %s",
		len(allMetrics), pollerID, pollerTimestamp.Format(time.RFC3339))

	return nil
}

func (s *Server) processICMPMetrics(
	pollerID string, svc *proto.ServiceStatus, details json.RawMessage, now time.Time) error {
	var pingResult struct {
		Host         string  `json:"host"`
		ResponseTime int64   `json:"response_time"`
		PacketLoss   float64 `json:"packet_loss"`
		Available    bool    `json:"available"`
	}

	if err := json.Unmarshal(details, &pingResult); err != nil {
		log.Printf("Failed to parse ICMP response JSON for service %s: %v", svc.ServiceName, err)
		return fmt.Errorf("failed to parse ICMP data: %w", err)
	}

	// Create metadata map
	metadata := map[string]string{
		"host":          pingResult.Host,
		"response_time": fmt.Sprintf("%d", pingResult.ResponseTime),
		"packet_loss":   fmt.Sprintf("%f", pingResult.PacketLoss),
		"available":     fmt.Sprintf("%t", pingResult.Available),
	}

	// Marshal metadata to JSON string
	metadataBytes, err := json.Marshal(metadata)
	if err != nil {
		log.Printf("Failed to marshal ICMP metadata for service %s, poller %s: %v",
			svc.ServiceName, pollerID, err)
		return fmt.Errorf("failed to marshal ICMP metadata: %w", err)
	}

	metadataStr := string(metadataBytes)

	metric := &models.TimeseriesMetric{
		Name:           fmt.Sprintf("icmp_%s_response_time_ms", svc.ServiceName),
		Value:          fmt.Sprintf("%d", pingResult.ResponseTime),
		Type:           "icmp",
		Timestamp:      now,
		Metadata:       metadataStr, // Use JSON string
		TargetDeviceIP: pingResult.Host,
		IfIndex:        0,
		PollerID:       pollerID,
	}

	// Buffer ICMP metric
	s.bufferMu.Lock()
	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], metric)
	s.bufferMu.Unlock()

	// Add to in-memory ring buffer for dashboard display
	if s.metrics != nil {
		err := s.metrics.AddMetric(
			pollerID,
			now,
			pingResult.ResponseTime,
			svc.ServiceName,
		)
		if err != nil {
			log.Printf("Failed to add ICMP metric to in-memory buffer for %s: %v", svc.ServiceName, err)
		}
	} else {
		log.Printf("Metrics manager is nil in processICMPMetrics for poller %s", pollerID)
	}

	return nil
}

// parseOIDConfigName extracts the base metric name and interface index from an OID config name
func parseOIDConfigName(oidConfigName string) (baseMetricName string, parsedIfIndex int32) {
	baseMetricName = oidConfigName
	potentialIfIndexStr := ""

	if strings.Contains(oidConfigName, "_") {
		parts := strings.Split(oidConfigName, "_")
		if len(parts) > 1 {
			potentialIfIndexStr = parts[len(parts)-1]
			baseMetricName = strings.Join(parts[:len(parts)-1], "_")
		}
	} else if strings.Contains(oidConfigName, ".") { // Common for OID-like names or when index is suffix after dot
		parts := strings.Split(oidConfigName, ".")
		if len(parts) > 1 {
			// Check if the last part is purely numeric; if so, it's likely an index
			if _, err := strconv.Atoi(parts[len(parts)-1]); err == nil {
				potentialIfIndexStr = parts[len(parts)-1]
				baseMetricName = strings.Join(parts[:len(parts)-1], ".")
			}
		}
	}

	if potentialIfIndexStr != "" {
		parsed, err := strconv.ParseInt(potentialIfIndexStr, 10, 32)
		if err == nil {
			parsedIfIndex = int32(parsed)
		} else {
			// Not a parsable index, reset baseMetricName if it was changed
			baseMetricName = oidConfigName
		}
	}

	return baseMetricName, parsedIfIndex
}

// createSNMPMetric creates a new timeseries metric from SNMP data
func createSNMPMetric(
	pollerID string,
	targetName string,
	oidConfigName string,
	oidStatus snmp.OIDStatus,
	targetData snmp.TargetStatus,
	baseMetricName string,
	parsedIfIndex int32,
	timestamp time.Time,
) *models.TimeseriesMetric {
	valueStr := fmt.Sprintf("%v", oidStatus.LastValue)

	remainingMetadata := make(map[string]string)
	remainingMetadata["original_oid_config_name"] = oidConfigName
	remainingMetadata["target_last_poll_timestamp"] = targetData.LastPoll.Format(time.RFC3339Nano)
	remainingMetadata["oid_last_update_timestamp"] = oidStatus.LastUpdate.Format(time.RFC3339Nano)

	if oidStatus.ErrorCount > 0 {
		remainingMetadata["oid_error_count"] = fmt.Sprintf("%d", oidStatus.ErrorCount)
		remainingMetadata["oid_last_error"] = oidStatus.LastError
	}

	// Marshal metadata to JSON string
	metadataBytes, err := json.Marshal(remainingMetadata)
	if err != nil {
		log.Printf("Failed to marshal SNMP metadata for poller %s, OID %s: %v", pollerID, oidConfigName, err)

		// Return a metric with empty metadata to avoid skipping valid data
		remainingMetadata = map[string]string{}
		metadataBytes, _ = json.Marshal(remainingMetadata)
	}

	metadataStr := string(metadataBytes)

	// Use the timestamp from the OID status if available and valid, otherwise fallback
	metricTimestamp := timestamp
	if !oidStatus.LastUpdate.IsZero() {
		metricTimestamp = oidStatus.LastUpdate
	}

	return &models.TimeseriesMetric{
		PollerID:       pollerID,
		TargetDeviceIP: targetName,
		IfIndex:        parsedIfIndex,
		Name:           baseMetricName,
		Type:           "snmp",
		Value:          valueStr,
		Timestamp:      metricTimestamp,
		Metadata:       metadataStr, // Use JSON string
	}
}

// bufferMetrics adds metrics to the server's metric buffer for a specific poller
func (s *Server) bufferMetrics(pollerID string, metrics []*models.TimeseriesMetric) {
	if len(metrics) == 0 {
		return
	}

	s.bufferMu.Lock()
	defer s.bufferMu.Unlock()

	// Ensure the buffer for this pollerID exists
	if _, ok := s.metricBuffers[pollerID]; !ok {
		s.metricBuffers[pollerID] = []*models.TimeseriesMetric{}
	}

	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], metrics...)
}

func (s *Server) processSNMPMetrics(pollerID string, details json.RawMessage, timestamp time.Time) error {
	// 'details' is the JSON string from SNMPService.Check(), which is a map[string]snmp.TargetStatus
	var snmpReportData map[string]snmp.TargetStatus

	if err := json.Unmarshal(details, &snmpReportData); err != nil {
		log.Printf("Error unmarshaling SNMP report data for poller %s: %v. Details: %s",
			pollerID, err, string(details))
		return fmt.Errorf("failed to parse SNMP report data: %w", err)
	}

	var newTimeseriesMetrics []*models.TimeseriesMetric

	for targetName, targetData := range snmpReportData { // targetName here is your target_device_ip
		if !targetData.Available {
			continue
		}

		for oidConfigName, oidStatus := range targetData.OIDStatus { // oidConfigName is like "ifInOctets_4" or "sysUpTimeInstance"
			baseMetricName, parsedIfIndex := parseOIDConfigName(oidConfigName)

			metric := createSNMPMetric(
				pollerID,
				targetName,
				oidConfigName,
				oidStatus,
				targetData,
				baseMetricName,
				parsedIfIndex,
				timestamp,
			)

			newTimeseriesMetrics = append(newTimeseriesMetrics, metric)
		}
	}

	s.bufferMetrics(pollerID, newTimeseriesMetrics)

	return nil
}

func (s *Server) handleService(ctx context.Context, svc *api.ServiceStatus, now time.Time) error {
	if svc.Type == sweepService {
		if err := s.processSweepData(ctx, svc, now); err != nil {
			return fmt.Errorf("failed to process sweep data: %w", err)
		}
	}

	return nil
}

func (s *Server) processSweepData(ctx context.Context, svc *api.ServiceStatus, now time.Time) error {
	var sweepData struct {
		proto.SweepServiceStatus
		Hosts []struct {
			IP        string            `json:"host"`
			Available bool              `json:"available"`
			MAC       *string           `json:"mac"`
			Hostname  *string           `json:"hostname"`
			Metadata  map[string]string `json:"metadata"`
		} `json:"hosts"`
	}

	if err := json.Unmarshal(svc.Message, &sweepData); err != nil {
		return fmt.Errorf("%w: %w", errInvalidSweepData, err)
	}

	if sweepData.LastSweep > now.Add(oneDay).Unix() {
		log.Printf("Invalid or missing LastSweep timestamp (%d), using current time", sweepData.LastSweep)

		sweepData.LastSweep = now.Unix()

		updatedData := proto.SweepServiceStatus{
			Network:        sweepData.Network,
			TotalHosts:     sweepData.TotalHosts,
			AvailableHosts: sweepData.AvailableHosts,
			LastSweep:      now.Unix(),
		}

		updatedMessage, err := json.Marshal(&updatedData)
		if err != nil {
			return fmt.Errorf("failed to marshal updated sweep data: %w", err)
		}

		svc.Message = updatedMessage
	}

	sweepResults := make([]*models.SweepResult, 0, len(sweepData.Hosts))

	for _, host := range sweepData.Hosts {
		if host.IP == "" {
			log.Printf("Skipping host with empty IP for poller %s", svc.PollerID)

			continue
		}

		metadata := host.Metadata
		if metadata == nil {
			metadata = make(map[string]string)
		}

		sweepResult := &models.SweepResult{
			AgentID:         svc.AgentID,
			PollerID:        svc.PollerID,
			DiscoverySource: "sweep",
			IP:              host.IP,
			MAC:             host.MAC,
			Hostname:        host.Hostname,
			Timestamp:       now,
			Available:       host.Available,
			Metadata:        metadata,
		}

		sweepResults = append(sweepResults, sweepResult)
	}

	// if sweepResults is empty, we don't need to store anything
	if len(sweepResults) == 0 {
		log.Printf("No sweep results to store for poller %s", svc.PollerID)

		return nil
	}

	if err := s.DB.StoreSweepResults(ctx, sweepResults); err != nil {
		return fmt.Errorf("failed to store sweep results: %w", err)
	}

	return nil
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

func (s *Server) GetRperfManager() metricstore.RperfManager {
	return s.rperfManager
}

func (s *Server) GetAuth() *auth.Auth {
	return s.authService
}

func LoadConfig(path string) (models.DBConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return models.DBConfig{}, fmt.Errorf("failed to read config: %w", err)
	}

	var config models.DBConfig

	if err := json.Unmarshal(data, &config); err != nil {
		return models.DBConfig{}, fmt.Errorf("failed to parse config: %w", err)
	}

	if config.Security != nil {
		log.Printf("Security config: Mode=%s, CertDir=%s, Role=%s",
			config.Security.Mode, config.Security.CertDir, config.Security.Role)
	}

	return config, nil
}

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
		// Poller appears to have recovered
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

func (s *Server) sendAlert(ctx context.Context, alert *alerts.WebhookAlert) error {
	var errs []error

	log.Printf("Sending alert: %s", alert.Message)

	for _, webhook := range s.webhooks {
		if err := webhook.Alert(ctx, alert); err != nil {
			errs = append(errs, err)
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("%w: %v", errFailedToSendAlerts, errs)
	}

	return nil
}

func (s *Server) ReportStatus(ctx context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
	log.Printf("Received status report from %s with %d services at %s",
		req.PollerId, len(req.Services), time.Now().Format(time.RFC3339Nano))

	if req.PollerId == "" {
		return nil, errEmptyPollerID
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
