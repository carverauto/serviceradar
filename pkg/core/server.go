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
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/rperf"
	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	shutdownTimeout            = 10 * time.Second
	oneDay                     = 24 * time.Hour
	oneWeek                    = 7 * oneDay
	serviceradarDirPerms       = 0700
	pollerHistoryLimit         = 1000
	pollerDiscoveryTimeout     = 30 * time.Second
	pollerNeverReportedTimeout = 30 * time.Second
	defaultDBPath              = "/var/lib/serviceradar/serviceradar.db"
	statusUnknown              = "unknown"
	sweepService               = "sweep"
	dailyCleanupInterval       = 24 * time.Hour
	monitorInterval            = 30 * time.Second
)

func NewServer(ctx context.Context, config *Config) (*Server, error) {
	normalizedConfig := normalizeConfig(config)

	database, err := db.New(ctx,
		normalizedConfig.DBAddr,
		normalizedConfig.DBName,
		normalizedConfig.DBUser,
		normalizedConfig.DBPass,
	)
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
		db:                  database,
		alertThreshold:      normalizedConfig.AlertThreshold,
		webhooks:            make([]alerts.AlertService, 0),
		ShutdownChan:        make(chan struct{}),
		pollerPatterns:      normalizedConfig.PollerPatterns,
		metrics:             metricsManager,
		snmpManager:         snmp.NewSNMPManager(database),
		rperfManager:        rperf.NewRperfManager(database),
		config:              normalizedConfig,
		authService:         auth.NewAuth(authConfig, database),
		metricBuffers:       make(map[string][]*db.TimeseriesMetric),
		serviceBuffers:      make(map[string][]*db.ServiceStatus),
		sysmonBuffers:       make(map[string][]*models.SysmonMetrics),
		bufferMu:            sync.RWMutex{},
		pollerStatusCache:   make(map[string]*pollerStatus),
		pollerStatusUpdates: make(map[string]*db.PollerStatus),
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

	s.pollerStatusUpdates[pollerID] = &db.PollerStatus{
		PollerID:  pollerID,
		IsHealthy: isHealthy,
		LastSeen:  lastSeen,
		FirstSeen: firstSeen,
	}
}

// flushBuffers flushes buffered data to the database periodically
func (s *Server) flushBuffers(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second) // Adjust interval as needed
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.bufferMu.Lock()
			for pollerID, m := range s.metricBuffers {
				if len(m) > 0 {
					if err := s.db.StoreMetrics(ctx, pollerID, m); err != nil {
						log.Printf("Failed to flush m for poller %s: %v", pollerID, err)
					}

					s.metricBuffers[pollerID] = nil
				}
			}

			for pollerID, statuses := range s.serviceBuffers {
				if len(statuses) > 0 {
					if err := s.db.UpdateServiceStatuses(ctx, statuses); err != nil {
						log.Printf("Failed to flush service statuses for poller %s: %v", pollerID, err)
					}

					s.serviceBuffers[pollerID] = nil
				}
			}

			for pollerID, sysmonMetrics := range s.sysmonBuffers {
				if len(sysmonMetrics) > 0 {
					for _, m := range sysmonMetrics {
						if err := s.db.StoreSysmonMetrics(ctx, pollerID, m, m.CPUs[0].Timestamp); err != nil {
							log.Printf("Failed to flush sysmon m for poller %s: %v", pollerID, err)
						}
					}

					s.sysmonBuffers[pollerID] = nil
				}
			}

			s.bufferMu.Unlock()
		}
	}
}

func normalizeConfig(config *Config) *Config {
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
		normalized.Metrics.Retention = 100
	}
	if normalized.Metrics.MaxPollers == 0 {
		normalized.Metrics.MaxPollers = 10000
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

func initializeAuthConfig(config *Config) (*models.AuthConfig, error) {
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

	if err := s.db.Close(); err != nil {
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

func (s *Server) GetSNMPManager() snmp.SNMPManager {
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

	pollerIDs, err := s.db.ListPollers(ctx)
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
		if err := s.db.DeletePoller(ctx, pollerID); err != nil {
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
			"version":  "1.0.34",
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
		Level:     alerts.Warning,
		Title:     "Core Service Stopping",
		Message:   fmt.Sprintf("ServiceRadar core service shutting down at %s", time.Now().Format(time.RFC3339)),
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

	if err := s.db.Close(); err != nil {
		log.Printf("Error closing database: %v", err)
	}

	if len(s.webhooks) > 0 {
		alert := alerts.WebhookAlert{
			Level:     alerts.Warning,
			Title:     "Core Service Stopping",
			Message:   fmt.Sprintf("ServiceRadar core service shutting down at %s", time.Now().Format(time.RFC3339)),
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

func (s *Server) SetAPIServer(ctx context.Context, apiServer api.Service) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.apiServer = apiServer
	apiServer.SetKnownPollers(s.config.KnownPollers)

	apiServer.SetPollerHistoryHandler(ctx, func(pollerID string) ([]api.PollerHistoryPoint, error) {
		ctxWithTimeout, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()

		points, err := s.db.GetPollerHistoryPoints(ctxWithTimeout, pollerID, pollerHistoryLimit)
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
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	statuses, err := s.db.ListPollerStatuses(ctx, s.pollerPatterns)
	if err != nil {
		log.Printf("Error querying pollers: %v", err)

		return
	}

	// Use a map to track which pollers we've already logged as offline
	reportedOffline := make(map[string]bool)

	for _, status := range statuses {
		duration := time.Since(status.LastSeen)

		// Only log each offline poller once
		if duration > s.alertThreshold && !reportedOffline[status.PollerID] {
			log.Printf("Poller %s found offline during initial check (last seen: %v ago)",
				status.PollerID, duration.Round(time.Second))

			reportedOffline[status.PollerID] = true
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
	status, err := s.db.GetPollerStatus(ctx, pollerID)
	if err != nil {
		return false, err
	}

	return status.IsHealthy, nil
}

func (s *Server) processStatusReport(
	ctx context.Context, req *proto.PollerStatusRequest, now time.Time) (*api.PollerStatus, error) {
	pollerStatus := &db.PollerStatus{
		PollerID:  req.PollerId,
		IsHealthy: true,
		LastSeen:  now,
	}

	existingStatus, err := s.db.GetPollerStatus(ctx, req.PollerId)
	if err != nil {
		pollerStatus.FirstSeen = now
	} else {
		pollerStatus.FirstSeen = existingStatus.FirstSeen
		currentState := existingStatus.IsHealthy

		if err := s.db.UpdatePollerStatus(ctx, pollerStatus); err != nil {
			log.Printf("Failed to store poller status for %s: %v", req.PollerId, err)

			return nil, fmt.Errorf("failed to store poller status: %w", err)
		}

		apiStatus := s.createPollerStatus(req, now)
		if err := s.processServices(ctx, req.PollerId, apiStatus, req.Services, now); err != nil {
			log.Printf("Failed to process services for %s: %v", req.PollerId, err)

			return nil, err
		}

		if err := s.updatePollerState(ctx, req.PollerId, apiStatus, currentState, now); err != nil {
			log.Printf("Failed to update poller state for %s: %v", req.PollerId, err)

			return nil, err
		}

		return apiStatus, nil
	}

	if err := s.db.UpdatePollerStatus(ctx, pollerStatus); err != nil {
		log.Printf("Failed to create new poller status for %s: %v", req.PollerId, err)

		return nil, fmt.Errorf("failed to create poller status: %w", err)
	}

	apiStatus := s.createPollerStatus(req, now)
	if err := s.processServices(ctx, req.PollerId, apiStatus, req.Services, now); err != nil {
		log.Printf("Failed to process services for new poller %s: %v", req.PollerId, err)

		return nil, err
	}

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
func (s *Server) processServices(ctx context.Context, pollerID string, apiStatus *api.PollerStatus, services []*proto.ServiceStatus, now time.Time) error {
	allServicesAvailable := true

	// Pre-allocate memory for service statuses
	serviceStatuses := make([]*db.ServiceStatus, 0, len(services))

	for _, svc := range services {
		apiService := s.createAPIService(svc)
		if !svc.Available {
			allServicesAvailable = false
		}

		// Process service details and metrics
		if err := s.processServiceDetails(ctx, pollerID, &apiService, svc, now); err != nil {
			log.Printf("Error processing details for service %s on poller %s: %v", svc.ServiceName, pollerID, err)
		}

		serviceStatuses = append(serviceStatuses, &db.ServiceStatus{
			PollerID:    pollerID,
			ServiceName: apiService.Name,
			ServiceType: apiService.Type,
			Available:   apiService.Available,
			Details:     apiService.Message,
			Timestamp:   now,
		})
		apiStatus.Services = append(apiStatus.Services, apiService)
	}

	// Buffer service statuses
	s.bufferMu.Lock()
	s.serviceBuffers[pollerID] = append(s.serviceBuffers[pollerID], serviceStatuses...)
	s.bufferMu.Unlock()

	apiStatus.IsHealthy = allServicesAvailable

	return nil
}

// processServiceDetails handles parsing and processing of service details and metrics.
func (s *Server) processServiceDetails(ctx context.Context, pollerID string, apiService *api.ServiceStatus, svc *proto.ServiceStatus, now time.Time) error {
	if svc.Message == "" {
		log.Printf("No message content for service %s on poller %s", svc.ServiceName, pollerID)
		return s.handleService(pollerID, apiService, now)
	}

	details, err := s.parseServiceDetails(svc)
	if err != nil {
		log.Printf("Failed to parse details for service %s on poller %s, proceeding without details", svc.ServiceName, pollerID)
		return s.handleService(pollerID, apiService, now)
	}

	apiService.Details = details
	if err := s.processMetrics(ctx, pollerID, svc, details, now); err != nil {
		log.Printf("Error processing metrics for service %s on poller %s: %v", svc.ServiceName, pollerID, err)
		return err
	}

	return s.handleService(pollerID, apiService, now)
}

// processMetrics handles metrics processing for all service types.
func (s *Server) processMetrics(ctx context.Context, pollerID string, svc *proto.ServiceStatus, details json.RawMessage, now time.Time) error {
	switch svc.ServiceType {
	case snmpServiceType:
		return s.processSNMPMetrics(ctx, pollerID, details, now)
	case grpcServiceType:
		switch svc.ServiceName {
		case rperfServiceType:
			return s.processRperfMetrics(ctx, pollerID, details, now)
		case sysmonServiceType:
			return s.processSysmonMetrics(ctx, pollerID, details, now)
		}
	case icmpServiceType:
		return s.processICMPMetrics(pollerID, svc, details, now)
	}

	return nil
}

func (*Server) createAPIService(svc *proto.ServiceStatus) api.ServiceStatus {
	return api.ServiceStatus{
		Name:      svc.ServiceName,
		Type:      svc.ServiceType,
		Available: svc.Available,
		Message:   svc.Message,
	}
}

func (*Server) parseServiceDetails(svc *proto.ServiceStatus) (json.RawMessage, error) {
	sanitized := strings.ReplaceAll(svc.Message, `""`, `"`)

	var details json.RawMessage

	if err := json.Unmarshal([]byte(sanitized), &details); err != nil {
		log.Printf("Error unmarshaling service details for %s: %v", svc.ServiceName, err)
		log.Printf("Raw message: %s", svc.Message)
		log.Printf("Sanitized message: %s", sanitized)
		log.Println("Invalid JSON format, skipping service details")

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

func (s *Server) processSpecializedMetrics(ctx context.Context, pollerID string, svc *proto.ServiceStatus, details json.RawMessage, now time.Time) error {
	switch {
	case svc.ServiceType == snmpServiceType:
		return s.processSNMPMetrics(ctx, pollerID, details, now)
	case svc.ServiceType == grpcServiceType && svc.ServiceName == rperfServiceType:
		return s.processRperfMetrics(ctx, pollerID, details, now)
	case svc.ServiceType == grpcServiceType && svc.ServiceName == sysmonServiceType:
		return s.processSysmonMetrics(ctx, pollerID, details, now)
	case svc.ServiceType == icmpServiceType && svc.ServiceName == rperfServiceType:
		return s.processICMPMetrics(pollerID, svc, details, now)
	}

	return nil
}

func (s *Server) processSysmonMetrics(ctx context.Context, pollerID string, details json.RawMessage, timestamp time.Time) error {
	var outerData struct {
		Status       string `json:"status"`
		ResponseTime int64  `json:"response_time"`
		Available    bool   `json:"available"`
	}

	if err := json.Unmarshal(details, &outerData); err != nil {
		log.Printf("Error unmarshaling outer sysmon data for poller %s: %v", pollerID, err)

		return fmt.Errorf("failed to parse outer sysmon data: %w", err)
	}

	if outerData.Status == "" {
		log.Printf("Empty status field in sysmon data for poller %s", pollerID)

		return errEmptyStatusField
	}

	var sysmonData models.SysmonMetricData

	if err := json.Unmarshal([]byte(outerData.Status), &sysmonData); err != nil {
		log.Printf("Error unmarshaling inner sysmon data for poller %s: %v", pollerID, err)

		return fmt.Errorf("failed to parse inner sysmon data: %w", err)
	}

	hasMemoryData := sysmonData.Memory.TotalBytes > 0 || sysmonData.Memory.UsedBytes > 0

	m := &models.SysmonMetrics{
		CPUs:   make([]models.CPUMetric, len(sysmonData.CPUs)),
		Disks:  make([]models.DiskMetric, len(sysmonData.Disks)),
		Memory: models.MemoryMetric{},
	}

	for i, cpu := range sysmonData.CPUs {
		m.CPUs[i] = models.CPUMetric{
			CoreID:       cpu.CoreID,
			UsagePercent: float64(cpu.UsagePercent),
			Timestamp:    timestamp,
		}
	}

	for i, disk := range sysmonData.Disks {
		m.Disks[i] = models.DiskMetric{
			MountPoint: disk.MountPoint,
			UsedBytes:  disk.UsedBytes,
			TotalBytes: disk.TotalBytes,
			Timestamp:  timestamp,
		}
	}

	if hasMemoryData {
		m.Memory = models.MemoryMetric{
			UsedBytes:  sysmonData.Memory.UsedBytes,
			TotalBytes: sysmonData.Memory.TotalBytes,
			Timestamp:  timestamp,
		}
	}

	// Buffer sysmon metrics
	s.bufferMu.Lock()
	s.sysmonBuffers[pollerID] = append(s.sysmonBuffers[pollerID], m)
	s.bufferMu.Unlock()

	return nil
}

func (s *Server) processRperfMetrics(ctx context.Context, pollerID string, details json.RawMessage, timestamp time.Time) error {
	var rperfData models.RperfMetricData

	if err := json.Unmarshal(details, &rperfData); err != nil {
		return fmt.Errorf("failed to parse rperf data: %w", err)
	}

	var timeseriesMetrics []*db.TimeseriesMetric

	for _, result := range rperfData.Results {
		if !result.Success {
			log.Printf("Skipping timeseriesMetrics storage for failed rperf test (Target: %s) on poller %s. Error: %v",
				result.Target, pollerID, result.Error)

			continue
		}

		metadata := map[string]interface{}{
			"target":           result.Target,
			"success":          result.Success,
			"error":            result.Error,
			"bits_per_second":  result.Summary.BitsPerSecond,
			"bytes_received":   result.Summary.BytesReceived,
			"bytes_sent":       result.Summary.BytesSent,
			"duration":         result.Summary.Duration,
			"jitter_ms":        result.Summary.JitterMs,
			"loss_percent":     result.Summary.LossPercent,
			"packets_lost":     result.Summary.PacketsLost,
			"packets_received": result.Summary.PacketsReceived,
			"packets_sent":     result.Summary.PacketsSent,
		}

		metricsToStore := []struct {
			Name  string
			Value string
		}{
			{
				Name:  fmt.Sprintf("rperf_%s_bandwidth_mbps", result.Target),
				Value: fmt.Sprintf("%.2f", result.Summary.BitsPerSecond/1e6),
			},
			{
				Name:  fmt.Sprintf("rperf_%s_jitter_ms", result.Target),
				Value: fmt.Sprintf("%.2f", result.Summary.JitterMs),
			},
			{
				Name:  fmt.Sprintf("rperf_%s_loss_percent", result.Target),
				Value: fmt.Sprintf("%.1f", result.Summary.LossPercent),
			},
		}

		for _, m := range metricsToStore {
			metric := &db.TimeseriesMetric{
				Name:      m.Name,
				Value:     m.Value,
				Type:      "rperf",
				Timestamp: timestamp,
				Metadata:  metadata,
			}

			timeseriesMetrics = append(timeseriesMetrics, metric)
		}
	}

	// Buffer rperf timeseriesMetrics
	s.bufferMu.Lock()
	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], timeseriesMetrics...)
	s.bufferMu.Unlock()

	return nil
}

func (s *Server) processICMPMetrics(pollerID string, svc *proto.ServiceStatus, details json.RawMessage, now time.Time) error {
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

	metric := &db.TimeseriesMetric{
		Name:      fmt.Sprintf("icmp_%s_response_time_ms", svc.ServiceName),
		Value:     fmt.Sprintf("%d", pingResult.ResponseTime),
		Type:      "icmp",
		Timestamp: now,
		Metadata: map[string]interface{}{
			"host":          pingResult.Host,
			"response_time": pingResult.ResponseTime,
			"packet_loss":   pingResult.PacketLoss,
			"available":     pingResult.Available,
		},
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

func (s *Server) processSNMPMetrics(ctx context.Context, pollerID string, details json.RawMessage, timestamp time.Time) error {
	var snmpData map[string]struct {
		Available bool                     `json:"available"`
		LastPoll  string                   `json:"last_poll"`
		OIDStatus map[string]OIDStatusData `json:"oid_status"`
	}

	if err := json.Unmarshal(details, &snmpData); err != nil {
		return fmt.Errorf("failed to parse SNMP data: %w", err)
	}

	var timeseriesMetrics []*db.TimeseriesMetric

	for targetName, targetData := range snmpData {
		for oidName, oidStatus := range targetData.OIDStatus {
			metadata := map[string]interface{}{
				"target_name": targetName,
				"last_poll":   targetData.LastPoll,
			}

			valueStr := fmt.Sprintf("%v", oidStatus.LastValue)
			metric := &db.TimeseriesMetric{
				Name:      oidName,
				Value:     valueStr,
				Type:      "snmp",
				Timestamp: timestamp,
				Metadata:  metadata,
			}

			timeseriesMetrics = append(timeseriesMetrics, metric)
		}
	}

	// Buffer SNMP timeseriesMetrics
	s.bufferMu.Lock()
	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], timeseriesMetrics...)
	s.bufferMu.Unlock()

	return nil
}

func (s *Server) handleService(pollerID string, svc *api.ServiceStatus, now time.Time) error {
	if svc.Type == sweepService {
		if err := s.processSweepData(svc, now); err != nil {
			return fmt.Errorf("failed to process sweep data: %w", err)
		}
	}

	return s.saveServiceStatus(pollerID, svc, now)
}

func (*Server) processSweepData(svc *api.ServiceStatus, now time.Time) error {
	var sweepData proto.SweepServiceStatus

	if err := json.Unmarshal([]byte(svc.Message), &sweepData); err != nil {
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

		svc.Message = string(updatedMessage)
	}

	return nil
}

func (s *Server) saveServiceStatus(pollerID string, svc *api.ServiceStatus, now time.Time) error {
	status := &db.ServiceStatus{
		PollerID:    pollerID,
		ServiceName: svc.Name,
		ServiceType: svc.Type,
		Available:   svc.Available,
		Details:     svc.Message,
		Timestamp:   now,
	}

	// Buffer service status
	s.bufferMu.Lock()
	s.serviceBuffers[pollerID] = append(s.serviceBuffers[pollerID], status)
	s.bufferMu.Unlock()

	return nil
}

func (s *Server) storePollerStatus(ctx context.Context, pollerID string, isHealthy bool, now time.Time) error {
	pollerStatus := &db.PollerStatus{
		PollerID:  pollerID,
		IsHealthy: isHealthy,
		LastSeen:  now,
	}

	if err := s.db.UpdatePollerStatus(ctx, pollerStatus); err != nil {
		return fmt.Errorf("failed to store poller status: %w", err)
	}

	return nil
}

func (s *Server) updatePollerStatus(ctx context.Context, pollerID string, isHealthy bool, timestamp time.Time) error {
	pollerStatus := &db.PollerStatus{
		PollerID:  pollerID,
		IsHealthy: isHealthy,
		LastSeen:  timestamp,
	}

	existingStatus, err := s.db.GetPollerStatus(ctx, pollerID)
	if err != nil {
		if errors.Is(err, db.ErrFailedToQuery) {
			pollerStatus.FirstSeen = timestamp
		} else {
			return fmt.Errorf("failed to check poller existence: %w", err)
		}
	} else {
		pollerStatus.FirstSeen = existingStatus.FirstSeen
	}

	if err := s.db.UpdatePollerStatus(ctx, pollerStatus); err != nil {
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
	pollerIDs, err := s.db.ListNeverReportedPollers(ctx, s.pollerPatterns)
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
	s.pollerStatusCache = make(map[string]*pollerStatus)
	s.cacheLastUpdated = time.Time{}
	s.cacheMutex.Unlock()

	log.Println("Cleared poller status cache for startup check")

	pollerIDs, err := s.db.ListNeverReportedPollers(ctx, s.pollerPatterns)
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

func (s *Server) GetRperfManager() rperf.RperfManager {
	return s.rperfManager
}

func (s *Server) GetAuth() *auth.Auth {
	return s.authService
}

func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("failed to read config: %w", err)
	}

	var config Config

	if err := json.Unmarshal(data, &config); err != nil {
		return Config{}, fmt.Errorf("failed to parse config: %w", err)
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
	// Get all poller statuses in one go
	pollerStatuses, err := s.getPollerStatuses(ctx, false)
	if err != nil {
		return fmt.Errorf("failed to get poller statuses: %w", err)
	}

	threshold := time.Now().Add(-s.alertThreshold)
	offlinePollers := make([]*pollerStatus, 0)
	recoveredPollers := make([]*pollerStatus, 0)

	// First pass: identify offline and recovered pollers
	for _, ps := range pollerStatuses {
		// Skip pollers we've evaluated recently (prevents log spam)
		if time.Since(ps.LastEvaluated) < 5*time.Minute {
			continue
		}

		// Mark this poller as evaluated
		ps.LastEvaluated = time.Now()

		if ps.IsHealthy && ps.LastSeen.Before(threshold) {
			// Poller appears to be offline
			offlinePollers = append(offlinePollers, ps)
		} else if !ps.IsHealthy && !ps.LastSeen.Before(threshold) {
			// Poller appears to have recovered
			recoveredPollers = append(recoveredPollers, ps)
		}
	}

	// Second pass: handle offline pollers
	if len(offlinePollers) > 0 {
		log.Printf("Found %d offline pollers", len(offlinePollers))

		batchCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()

		// Update the database in a single transaction if possible
		for _, ps := range offlinePollers {
			if ps.AlertSent {
				continue // Skip if we've already sent an alert
			}

			duration := time.Since(ps.LastSeen).Round(time.Second)
			log.Printf("Poller %s appears to be offline (last seen: %v ago)", ps.ID, duration)

			if err := s.handlePollerDown(batchCtx, ps.ID, ps.LastSeen); err != nil {
				log.Printf("Error handling offline poller %s: %v", ps.ID, err)

				continue
			}

			// Mark that we've sent an alert
			ps.AlertSent = true
		}
	}

	// Third pass: handle recovered pollers
	if len(recoveredPollers) > 0 {
		log.Printf("Found %d recovered pollers", len(recoveredPollers))

		batchCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()

		for _, ps := range recoveredPollers {
			if !ps.AlertSent {
				continue // Only handle recoveries for pollers we alerted about
			}

			apiStatus := &api.PollerStatus{
				PollerID:   ps.ID,
				LastUpdate: ps.LastSeen,
				Services:   make([]api.ServiceStatus, 0),
			}

			s.handlePollerRecovery(batchCtx, ps.ID, apiStatus, ps.LastSeen)

			// Reset the alert flag
			ps.AlertSent = false
		}
	}

	return nil
}

func (s *Server) flushPollerStatusUpdates(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.pollerStatusUpdateMutex.Lock()
			updates := s.pollerStatusUpdates

			s.pollerStatusUpdates = make(map[string]*db.PollerStatus)
			s.pollerStatusUpdateMutex.Unlock()

			if len(updates) == 0 {
				continue
			}

			log.Printf("Flushing %d poller status updates", len(updates))

			// Convert to a slice for batch processing
			statuses := make([]*db.PollerStatus, 0, len(updates))

			for _, status := range updates {
				statuses = append(statuses, status)
			}

			// Update in batches if your DB supports it
			// Otherwise, loop and update individually
			for _, status := range statuses {
				if err := s.db.UpdatePollerStatus(ctx, status); err != nil {
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
		if alerter, ok := webhook.(*alerts.WebhookAlerter); ok {
			alerter.MarkPollerAsRecovered(pollerID)
			alerter.MarkServiceAsRecovered(pollerID)
		}
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
	log.Printf("Received status report from %s with %d services", req.PollerId, len(req.Services))

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

func (s *Server) getPollerStatuses(ctx context.Context, forceRefresh bool) (map[string]*pollerStatus, error) {
	s.cacheMutex.RLock()
	if !forceRefresh && time.Since(s.cacheLastUpdated) < 30*time.Second {
		// Use cached data if it's recent enough
		result := make(map[string]*pollerStatus, len(s.pollerStatusCache))

		for k, v := range s.pollerStatusCache {
			result[k] = v
		}

		s.cacheMutex.RUnlock()

		return result, nil
	}

	s.cacheMutex.RUnlock()

	// Need to refresh the cache
	s.cacheMutex.Lock()
	defer s.cacheMutex.Unlock()

	// Double-check in case another goroutine refreshed while we were waiting for the lock
	if !forceRefresh && time.Since(s.cacheLastUpdated) < 30*time.Second {
		result := make(map[string]*pollerStatus, len(s.pollerStatusCache))

		for k, v := range s.pollerStatusCache {
			result[k] = v
		}

		return result, nil
	}

	// Query the database
	statuses, err := s.db.ListPollerStatuses(ctx, s.pollerPatterns)
	if err != nil {
		return nil, fmt.Errorf("failed to query pollers: %w", err)
	}

	// Update the cache
	newCache := make(map[string]*pollerStatus, len(statuses))

	for _, status := range statuses {
		// Copy existing evaluation data if available
		ps := &pollerStatus{
			ID:        status.PollerID,
			IsHealthy: status.IsHealthy,
			LastSeen:  status.LastSeen,
			FirstSeen: status.FirstSeen,
		}

		if existing, ok := s.pollerStatusCache[status.PollerID]; ok {
			ps.LastEvaluated = existing.LastEvaluated
			ps.AlertSent = existing.AlertSent
		}

		newCache[status.PollerID] = ps
	}

	s.pollerStatusCache = newCache
	s.cacheLastUpdated = time.Now()

	// Return a copy to avoid race conditions
	result := make(map[string]*pollerStatus, len(s.pollerStatusCache))
	for k, v := range s.pollerStatusCache {
		result[k] = v
	}

	return result, nil
}
