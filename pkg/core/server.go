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
		serviceListBuffers:  make(map[string][]*models.Service),
		sysmonBuffers:       make(map[string][]*sysmonMetricBuffer),
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
	s.flushServices(ctx)
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

// flushServices flushes service inventory data to the database.
func (s *Server) flushServices(ctx context.Context) {
	for pollerID, services := range s.serviceListBuffers {
		if len(services) == 0 {
			continue
		}

		if err := s.DB.StoreServices(ctx, services); err != nil {
			log.Printf("Failed to flush services for poller %s: %v", pollerID, err)
		}

		s.serviceListBuffers[pollerID] = nil
	}
}

// flushSysmonMetrics flushes system monitor metrics to the database.
func (s *Server) flushSysmonMetrics(ctx context.Context) {
	for pollerID, sysmonMetrics := range s.sysmonBuffers {
		if len(sysmonMetrics) == 0 {
			continue
		}

		for _, metricBuffer := range sysmonMetrics {
			metric := metricBuffer.Metrics
			partition := metricBuffer.Partition

			var ts time.Time

			var agentID, hostID, hostIP string

			// Extract information from the first available metric type
			switch {
			case len(metric.CPUs) > 0:
				ts = metric.CPUs[0].Timestamp
				agentID = metric.CPUs[0].AgentID
				hostID = metric.CPUs[0].HostID
				hostIP = metric.CPUs[0].HostIP
			case len(metric.Disks) > 0:
				ts = metric.Disks[0].Timestamp
				agentID = metric.Disks[0].AgentID
				hostID = metric.Disks[0].HostID
				hostIP = metric.Disks[0].HostIP
			default:
				ts = metric.Memory.Timestamp
				agentID = metric.Memory.AgentID
				hostID = metric.Memory.HostID
				hostIP = metric.Memory.HostIP
			}

			if err := s.DB.StoreSysmonMetrics(ctx, pollerID, agentID, hostID, partition, hostIP, metric, ts); err != nil {
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

// findAgentID extracts the agent ID from the services if available
func (*Server) findAgentID(services []*proto.ServiceStatus) string {
	for _, svc := range services {
		if svc.AgentId != "" {
			return svc.AgentId
		}
	}

	return ""
}

// registerServiceDevice creates or updates a device entry for a poller and/or agent
// This treats the agent/poller as a service running on a real host device within a specific partition
//
// Source of Truth Principle:
// The agent/poller is the ONLY reliable source of truth for its location (partition and host IP).
// This information MUST be provided by the client in the status report, not inferred by the server.
//
// Requirements:
// - partition: MUST be provided in the PollerStatusRequest
// - sourceIP: MUST be provided in the PollerStatusRequest
// - If either is missing, the device registration is rejected to prevent orphaned records
//
// This approach ensures:
// - No duplicate devices with placeholder IPs (e.g., 127.0.0.1)
// - Stable device IDs from the first check-in
// - Correct handling of NAT, proxies, and load balancers
// - Simple, reliable logic with no "magic" convergence
func (s *Server) registerServiceDevice(ctx context.Context, pollerID, agentID, partition, sourceIP string, timestamp time.Time) error {
	// Validate required fields - the client MUST provide its location
	if partition == "" || sourceIP == "" {
		return fmt.Errorf("CRITICAL: Cannot register device for poller %s - missing required location data (partition=%q, source_ip=%q)",
			pollerID, partition, sourceIP)
	}

	// Generate device ID following the partition:ip schema using the reported location
	deviceID := fmt.Sprintf("%s:%s", partition, sourceIP)

	// Determine service types based on the relationship between poller and agent
	var serviceTypes []string

	var primaryServiceID string

	if agentID == "" {
		// Pure poller
		serviceTypes = []string{"poller"}
		primaryServiceID = pollerID
	} else if agentID == pollerID {
		// Combined poller/agent
		serviceTypes = []string{"poller", "agent"}
		primaryServiceID = pollerID
	} else {
		// Separate agent
		serviceTypes = []string{"agent"}
		primaryServiceID = agentID
	}

	// Check if device already exists to determine FirstSeen timestamp
	firstSeen := timestamp

	existingDevice, err := s.DB.GetDeviceByID(ctx, deviceID)
	if err == nil && !existingDevice.FirstSeen.IsZero() {
		firstSeen = existingDevice.FirstSeen
	}

	// Create the device metadata including service information
	// Note: metadata must be map[string]string per database schema
	metadata := map[string]interface{}{
		"device_type":     "host",
		"service_types":   strings.Join(serviceTypes, ","), // Convert array to comma-separated string
		"service_status":  "online",
		"last_heartbeat":  timestamp.Format(time.RFC3339),
		"primary_service": primaryServiceID,
	}

	// Add poller-specific metadata if this host runs a poller
	if pollerID != "" {
		metadata["poller_id"] = pollerID
		metadata["poller_status"] = "active"
	}

	// Add agent-specific metadata if this host runs an agent
	if agentID != "" && agentID != pollerID {
		metadata["agent_id"] = agentID
		metadata["agent_status"] = "active"
	}

	// Try to get hostname from the service ID or use IP as fallback
	hostname := s.getServiceHostname(primaryServiceID, sourceIP)

	// Construct the Device object representing the host device
	device := &models.Device{
		DeviceID:         deviceID,
		PollerID:         pollerID, // The poller managing this device (may be itself)
		AgentID:          agentID,  // The agent running on this device (may be empty)
		IP:               sourceIP, // Host IP as reported by the service
		Hostname:         hostname, // Real or derived hostname
		DiscoverySources: []string{"self-reported"},
		IsAvailable:      true,
		LastSeen:         timestamp,
		FirstSeen:        firstSeen,
		Metadata:         metadata,
	}

	// Store the device using the existing StoreDevices function
	if err := s.DB.StoreDevices(ctx, []*models.Device{device}); err != nil {
		return fmt.Errorf("failed to store service device: %w", err)
	}

	log.Printf("Successfully registered host device %s (services: %v) for poller %s",
		deviceID, serviceTypes, pollerID)

	return nil
}

// getServiceHostname attempts to determine the hostname for a service
func (*Server) getServiceHostname(serviceID, hostIP string) string {
	// TODO: In a real implementation, this could:
	// 1. Perform reverse DNS lookup on the IP
	// 2. Query a hostname registry
	// 3. Use the service ID as hostname if it's already a hostname
	// For now, use the service ID as hostname if it looks like one,
	// otherwise use the IP
	if serviceID != "" && (len(serviceID) > 7) { // Simple heuristic
		return serviceID
	}

	return hostIP
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

			if err := s.registerServiceDevice(timeoutCtx, req.PollerId, s.findAgentID(req.Services), req.Partition, req.SourceIp, now); err != nil {
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

		if err := s.registerServiceDevice(timeoutCtx, req.PollerId, s.findAgentID(req.Services), req.Partition, req.SourceIp, now); err != nil {
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

// extractDeviceContext extracts device context for service correlation.
// For services like ping/icmp, this correlates them to the source device (agent).
// Returns the device_id and partition for the device that performed the service check.
func (s *Server) extractDeviceContext(agentID, defaultPartition, enhancedPayload string) (deviceID, partition string) {
	// Parse the enhanced service payload to extract device context
	var payload struct {
		PollerID  string `json:"poller_id"`
		AgentID   string `json:"agent_id"`
		Partition string `json:"partition"`
		Data      struct {
			HostIP string `json:"host_ip,omitempty"`
		} `json:"data,omitempty"`
	}
	
	if err := json.Unmarshal([]byte(enhancedPayload), &payload); err != nil {
		// If we can't parse the enhanced payload, use defaults
		log.Printf("Warning: Failed to parse enhanced payload for device context: %v", err)
		return "", defaultPartition
	}
	
	// Use partition from enhanced payload if available, otherwise use default
	partition = payload.Partition
	if partition == "" {
		partition = defaultPartition
	}
	
	// For service correlation, we need to determine the source device
	// This is typically the agent that performed the service check
	
	// First, try to get host_ip from the service data (if available)
	if payload.Data.HostIP != "" {
		deviceID = fmt.Sprintf("%s:%s", partition, payload.Data.HostIP)
		return deviceID, partition
	}
	
	// If no host_ip in service data, try to look up the agent's device record
	// This handles cases where the agent doesn't include host_ip in service responses
	agentDeviceID := s.findAgentDeviceID(agentID, partition)
	if agentDeviceID != "" {
		return agentDeviceID, partition
	}
	
	// Fallback: return empty deviceID but valid partition
	return "", partition
}

// findAgentDeviceID attempts to find the device_id associated with an agent.
// This looks up device records that have the specified agent_id.
func (s *Server) findAgentDeviceID(agentID, partition string) string {
	// Query unified_devices to find device with this agent_id
	// This is a best-effort lookup and may not always succeed
	query := `
		SELECT device_id 
		FROM table(unified_devices) 
		WHERE agent_id = $1 AND device_id LIKE $2 
		LIMIT 1`
	
	results, err := s.DB.ExecuteQuery(context.Background(), query, agentID, partition+":%")
	if err != nil {
		// This is expected when no device record exists yet
		log.Printf("Debug: No device record found for agent_id=%s, partition=%s: %v", agentID, partition, err)
		return ""
	}
	
	if len(results) == 0 {
		log.Printf("Debug: No device record found for agent_id=%s, partition=%s", agentID, partition)
		return ""
	}
	
	if deviceID, ok := results[0]["device_id"].(string); ok {
		return deviceID
	}
	
	return ""
}

// processServices processes service statuses for a poller and updates the API status.
func (s *Server) processServices(
	ctx context.Context,
	pollerID string,
	partition string,
	sourceIP string,
	apiStatus *api.PollerStatus,
	services []*proto.ServiceStatus,
	now time.Time) {
	allServicesAvailable := true
	serviceStatuses := make([]*models.ServiceStatus, 0, len(services))
	serviceList := make([]*models.Service, 0, len(services))

	for _, svc := range services {
		apiService := s.createAPIService(svc)

		if !svc.Available {
			allServicesAvailable = false
		}

		if err := s.processServiceDetails(ctx, pollerID, partition, sourceIP, &apiService, svc, now); err != nil {
			log.Printf("Error processing details for service %s on poller %s: %v",
				svc.ServiceName, pollerID, err)
		}

		// Extract device context from enhanced payload for device correlation
		deviceID, devicePartition := s.extractDeviceContext(svc.AgentId, partition, string(apiService.Message))
		
		serviceStatuses = append(serviceStatuses, &models.ServiceStatus{
			AgentID:     svc.AgentId,
			PollerID:    svc.PollerId,
			ServiceName: apiService.Name,
			ServiceType: apiService.Type,
			Available:   apiService.Available,
			Details:     apiService.Message,
			DeviceID:    deviceID,
			Partition:   devicePartition,
			Timestamp:   now,
		})

		serviceList = append(serviceList, &models.Service{
			PollerID:    pollerID,
			ServiceName: svc.ServiceName,
			ServiceType: svc.ServiceType,
			AgentID:     svc.AgentId,
			DeviceID:    deviceID,
			Partition:   devicePartition,
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
	s.serviceListBuffers[pollerID] = append(s.serviceListBuffers[pollerID], serviceList...)
	s.bufferMu.Unlock()

	apiStatus.IsHealthy = allServicesAvailable
}

// processServiceDetails handles parsing and processing of service details and metrics.
func (s *Server) processServiceDetails(
	ctx context.Context,
	pollerID string,
	partition string,
	sourceIP string,
	apiService *api.ServiceStatus,
	svc *proto.ServiceStatus,
	now time.Time,
) error {
	// Check if svc.Message is nil or empty
	if len(svc.Message) == 0 {
		log.Printf("No message content for service %s on poller %s", svc.ServiceName, pollerID)
		return s.handleService(ctx, apiService, partition, now)
	}

	details, err := s.parseServiceDetails(svc)
	if err != nil {
		log.Printf("Failed to parse details for service %s on poller %s, proceeding without details",
			svc.ServiceName, pollerID)

		if svc.ServiceType == snmpDiscoveryResultsServiceType {
			return fmt.Errorf("failed to parse snmp-discovery-results payload: %w", err)
		}

		return s.handleService(ctx, apiService, partition, now)
	}

	apiService.Details = details

	if err := s.processMetrics(ctx, pollerID, partition, sourceIP, svc, details, now); err != nil {
		log.Printf("Error processing metrics for service %s on poller %s: %v",
			svc.ServiceName, pollerID, err)
		return err
	}

	return s.handleService(ctx, apiService, partition, now)
}

// extractServicePayload extracts the enhanced service payload or returns original details.
// All service messages now include infrastructure context from the poller.
func (s *Server) extractServicePayload(details json.RawMessage) (*models.ServiceMetricsPayload, json.RawMessage, error) {
	// Try to parse as enhanced payload first
	var enhancedPayload models.ServiceMetricsPayload
	if err := json.Unmarshal(details, &enhancedPayload); err == nil {
		// Validate it's actually an enhanced payload by checking required fields
		if enhancedPayload.PollerID != "" && enhancedPayload.AgentID != "" {
			return &enhancedPayload, enhancedPayload.Data, nil
		}
	}
	
	// Fallback: treat as original non-enhanced payload
	// This handles backwards compatibility during transition
	return nil, details, nil
}

// processMetrics handles metrics processing for all service types.
func (s *Server) processMetrics(
	ctx context.Context,
	pollerID string,
	partition string,
	sourceIP string,
	svc *proto.ServiceStatus,
	details json.RawMessage,
	now time.Time) error {
	
	// Extract enhanced payload if present, or use original data
	enhancedPayload, serviceData, err := s.extractServicePayload(details)
	if err != nil {
		log.Printf("Warning: Failed to extract service payload for %s: %v", svc.ServiceType, err)
		serviceData = details // fallback to original
	}
	
	// Use enhanced context if available, otherwise fall back to gRPC parameters
	contextPollerID := pollerID
	contextPartition := partition
	contextAgentID := svc.AgentId
	
	if enhancedPayload != nil {
		contextPollerID = enhancedPayload.PollerID
		contextPartition = enhancedPayload.Partition
		contextAgentID = enhancedPayload.AgentID
		log.Printf("Using enhanced payload context: PollerID=%s, Partition=%s, AgentID=%s", 
			contextPollerID, contextPartition, contextAgentID)
	}
	switch svc.ServiceType {
	case snmpServiceType:
		return s.processSNMPMetrics(contextPollerID, contextPartition, sourceIP, contextAgentID, serviceData, now)
	case grpcServiceType:
		switch svc.ServiceName {
		case rperfServiceType:
			return s.processRperfMetrics(contextPollerID, contextPartition, serviceData, now)
		case sysmonServiceType:
			return s.processSysmonMetrics(contextPollerID, contextPartition, contextAgentID, serviceData, now)
		}
	case icmpServiceType:
		return s.processICMPMetrics(contextPollerID, contextPartition, sourceIP, svc, serviceData, now)
	case snmpDiscoveryResultsServiceType, mapperDiscoveryServiceType:
		return s.processSNMPDiscoveryResults(ctx, contextPollerID, contextPartition, svc, serviceData, now)
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

func (s *Server) processSysmonMetrics(pollerID, partition, agentID string, details json.RawMessage, timestamp time.Time) error {
	log.Printf("Processing sysmon metrics for poller %s, agent %s with details: %s", pollerID, agentID, string(details))

	sysmonPayload, pollerTimestamp, err := s.parseSysmonPayload(details, pollerID, timestamp)
	if err != nil {
		return err
	}

	m := s.buildSysmonMetrics(sysmonPayload, pollerTimestamp, agentID)

	// Create device_id for logging and device registration
	deviceID := fmt.Sprintf("%s:%s", partition, sysmonPayload.Status.HostIP)

	s.bufferSysmonMetrics(pollerID, partition, m)

	log.Printf("Parsed %d CPU metrics for poller %s (device_id: %s, host_ip: %s, partition: %s) with timestamp %s",
		len(sysmonPayload.Status.CPUs), pollerID, deviceID, sysmonPayload.Status.HostIP, partition, sysmonPayload.Status.Timestamp)

	s.createSysmonDeviceRecord(agentID, pollerID, partition, deviceID, sysmonPayload, pollerTimestamp)

	return nil
}

type sysmonPayload struct {
	Available    bool  `json:"available"`
	ResponseTime int64 `json:"response_time"`
	Status       struct {
		Timestamp string              `json:"timestamp"`
		HostID    string              `json:"host_id"`
		HostIP    string              `json:"host_ip"`
		CPUs      []models.CPUMetric  `json:"cpus"`
		Disks     []models.DiskMetric `json:"disks"`
		Memory    models.MemoryMetric `json:"memory"`
	} `json:"status"`
}

func (*Server) parseSysmonPayload(details json.RawMessage, pollerID string, timestamp time.Time) (*sysmonPayload, time.Time, error) {
	var payload sysmonPayload

	if err := json.Unmarshal(details, &payload); err != nil {
		log.Printf("Error unmarshaling sysmon data for poller %s: %v", pollerID, err)
		return nil, time.Time{}, fmt.Errorf("failed to parse sysmon data: %w", err)
	}

	pollerTimestamp, err := time.Parse(time.RFC3339Nano, payload.Status.Timestamp)
	if err != nil {
		log.Printf("Invalid timestamp in sysmon data for poller %s: %v, using server timestamp", pollerID, err)

		pollerTimestamp = timestamp
	}

	return &payload, pollerTimestamp, nil
}

func (*Server) buildSysmonMetrics(payload *sysmonPayload, pollerTimestamp time.Time, agentID string) *models.SysmonMetrics {
	hasMemoryData := payload.Status.Memory.TotalBytes > 0 || payload.Status.Memory.UsedBytes > 0

	m := &models.SysmonMetrics{
		CPUs:   make([]models.CPUMetric, len(payload.Status.CPUs)),
		Disks:  make([]models.DiskMetric, len(payload.Status.Disks)),
		Memory: &models.MemoryMetric{},
	}

	for i, cpu := range payload.Status.CPUs {
		m.CPUs[i] = models.CPUMetric{
			CoreID:       cpu.CoreID,
			UsagePercent: cpu.UsagePercent,
			Timestamp:    pollerTimestamp,
			HostID:       payload.Status.HostID,
			HostIP:       payload.Status.HostIP,
			AgentID:      agentID,
		}
	}

	for i, disk := range payload.Status.Disks {
		m.Disks[i] = models.DiskMetric{
			MountPoint: disk.MountPoint,
			UsedBytes:  disk.UsedBytes,
			TotalBytes: disk.TotalBytes,
			Timestamp:  pollerTimestamp,
			HostID:     payload.Status.HostID,
			HostIP:     payload.Status.HostIP,
			AgentID:    agentID,
		}
	}

	if hasMemoryData {
		m.Memory = &models.MemoryMetric{
			UsedBytes:  payload.Status.Memory.UsedBytes,
			TotalBytes: payload.Status.Memory.TotalBytes,
			Timestamp:  pollerTimestamp,
			HostID:     payload.Status.HostID,
			HostIP:     payload.Status.HostIP,
			AgentID:    agentID,
		}
	}

	return m
}

func (s *Server) bufferSysmonMetrics(pollerID, partition string, metrics *models.SysmonMetrics) {
	s.bufferMu.Lock()
	s.sysmonBuffers[pollerID] = append(s.sysmonBuffers[pollerID], &sysmonMetricBuffer{
		Metrics:   metrics,
		Partition: partition,
	})
	s.bufferMu.Unlock()
}

func (s *Server) createSysmonDeviceRecord(
	agentID, pollerID, partition, deviceID string, payload *sysmonPayload, pollerTimestamp time.Time) {
	if payload.Status.HostIP == "" || payload.Status.HostIP == "unknown" {
		return
	}

	sweepResult := &models.SweepResult{
		AgentID:         agentID,
		PollerID:        pollerID,
		Partition:       partition,
		DiscoverySource: "sysmon",
		IP:              payload.Status.HostIP,
		Hostname:        &payload.Status.HostID,
		Timestamp:       pollerTimestamp,
		Available:       true,
		Metadata: map[string]string{
			"source":      "sysmon",
			"last_update": pollerTimestamp.Format(time.RFC3339),
		},
	}

	if err := s.DB.StoreSweepResults(context.Background(), []*models.SweepResult{sweepResult}); err != nil {
		log.Printf("Warning: Failed to create device record for sysmon device %s: %v", deviceID, err)
	} else {
		log.Printf("Created/updated device record for sysmon device %s (hostname: %s, ip: %s)",
			deviceID, payload.Status.HostID, payload.Status.HostIP)
	}
}

// createSnmpTargetDeviceRecord creates a device record for an SNMP target device.
// This ensures SNMP targets appear in the unified devices view and can be merged with other discovery sources.
func (s *Server) createSnmpTargetDeviceRecord(
	agentID, pollerID, partition, targetIP, hostname string, timestamp time.Time, available bool) {
	
	if targetIP == "" {
		log.Printf("Warning: Cannot create SNMP target device record; target IP is missing.")
		return
	}

	sweepResult := &models.SweepResult{
		AgentID:         agentID,
		PollerID:        pollerID,
		Partition:       partition,
		DiscoverySource: "snmp", // Will merge with other discovery sources in unified_devices
		IP:              targetIP,
		Hostname:        &hostname,
		Timestamp:       timestamp,
		Available:       available,
		Metadata: map[string]string{
			"source":           "snmp-target",
			"snmp_monitoring":  "active",
			"last_poll":        timestamp.Format(time.RFC3339),
		},
	}

	if err := s.DB.StoreSweepResults(context.Background(), []*models.SweepResult{sweepResult}); err != nil {
		log.Printf("Warning: Failed to create device record for SNMP target %s: %v", targetIP, err)
	} else {
		deviceID := fmt.Sprintf("%s:%s", partition, targetIP)
		log.Printf("Created/updated device record for SNMP target %s (hostname: %s, ip: %s)",
			deviceID, hostname, targetIP)
	}
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
}, pollerID string, partition string, responseTime int64, pollerTimestamp time.Time) ([]*models.TimeseriesMetric, error) {
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
			Name:           m.Name,
			Value:          m.Value,
			Type:           "rperf",
			Timestamp:      pollerTimestamp,
			Metadata:       metadataStr,
			PollerID:       pollerID,
			TargetDeviceIP: result.Target,
			DeviceID:       fmt.Sprintf("%s:%s", partition, result.Target),
			Partition:      partition,
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

func (s *Server) processRperfMetrics(pollerID, partition string, details json.RawMessage, timestamp time.Time) error {
	log.Printf("Processing rperf metrics for poller %s with details: %s", pollerID, string(details))

	rperfPayload, pollerTimestamp, err := s.parseRperfPayload(details, timestamp)
	if err != nil {
		log.Printf("Error unmarshaling rperf data for poller %s: %v", pollerID, err)
		return err
	}

	var allMetrics []*models.TimeseriesMetric

	for i := range rperfPayload.Status.Results {
		rperfResult, err := s.processRperfResult(rperfPayload.Status.Results[i], pollerID, partition, rperfPayload.ResponseTime, pollerTimestamp)
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
	pollerID string, partition string, sourceIP string, svc *proto.ServiceStatus, details json.RawMessage, now time.Time) error {
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
		DeviceID:       fmt.Sprintf("%s:%s", partition, sourceIP),
		Partition:      partition,
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
	partition string,
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
		DeviceID:       fmt.Sprintf("%s:%s", partition, targetName),
		Partition:      partition,
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

func (s *Server) processSNMPMetrics(pollerID, partition, sourceIP, agentID string, details json.RawMessage, timestamp time.Time) error {
	// 'details' may be either enhanced ServiceMetricsPayload data or raw SNMP data
	// Parse directly as SNMP target status map (works for both enhanced and legacy)
	var targetStatusMap map[string]snmp.TargetStatus
	if err := json.Unmarshal(details, &targetStatusMap); err != nil {
		log.Printf("Error unmarshaling SNMP targets for poller %s: %v. Details: %s",
			pollerID, err, string(details))
		
		// Check if it's an error message wrapped in JSON
		var errorWrapper map[string]string
		if errParseErr := json.Unmarshal(details, &errorWrapper); errParseErr == nil {
			if msg, exists := errorWrapper["message"]; exists {
				log.Printf("SNMP service returned error for poller %s: %s", pollerID, msg)
				return nil // Don't fail processing for service errors
			}
			if errMsg, exists := errorWrapper["error"]; exists {
				log.Printf("SNMP service returned error for poller %s: %s", pollerID, errMsg)
				return nil // Don't fail processing for service errors
			}
		}
		
		return fmt.Errorf("failed to parse SNMP targets: %w", err)
	}
	
	// Skip processing if no targets (empty map)
	if len(targetStatusMap) == 0 {
		log.Printf("SNMP service for poller %s returned no targets", pollerID)
		return nil
	}

	// Register each SNMP target as a device (for unified devices view integration)
	for targetName, targetData := range targetStatusMap {
		// Use HostIP for device registration, fall back to target name if not available
		deviceIP := targetData.HostIP
		if deviceIP == "" {
			log.Printf("Warning: HostIP missing for target %s, using target name as fallback", targetName)
			deviceIP = targetName
		}
		
		// Use HostName for display, fall back to target name if not available
		deviceHostname := targetData.HostName
		if deviceHostname == "" {
			deviceHostname = targetName
		}
		
		s.createSnmpTargetDeviceRecord(
			agentID,        // Use context agentID (enhanced or fallback)
			pollerID,       // Use context pollerID (enhanced or fallback)  
			partition,      // Use context partition (enhanced or fallback)
			deviceIP,       // Actual IP address (e.g., "192.168.2.1")
			deviceHostname, // Display name (e.g., "farm01")
			timestamp,
			targetData.Available,
		)
	}

	var newTimeseriesMetrics []*models.TimeseriesMetric

	for targetName, targetData := range targetStatusMap { // targetName is target config name
		if !targetData.Available {
			continue
		}

		// Use HostIP for device ID consistency, fall back to target name if not available
		deviceIP := targetData.HostIP
		if deviceIP == "" {
			deviceIP = targetName
		}

		for oidConfigName, oidStatus := range targetData.OIDStatus { // oidConfigName is like "ifInOctets_4" or "sysUpTimeInstance"
			baseMetricName, parsedIfIndex := parseOIDConfigName(oidConfigName)

			metric := createSNMPMetric(
				pollerID,   // Use context pollerID
				partition,  // Use context partition
				deviceIP,   // Use actual IP address for device ID consistency
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

func (s *Server) handleService(ctx context.Context, svc *api.ServiceStatus, partition string, now time.Time) error {
	if svc.Type == sweepService {
		if err := s.processSweepData(ctx, svc, partition, now); err != nil {
			return fmt.Errorf("failed to process sweep data: %w", err)
		}
	}

	return nil
}

func (s *Server) processSweepData(ctx context.Context, svc *api.ServiceStatus, partition string, now time.Time) error {
	// Extract enhanced payload if present, or use original data
	enhancedPayload, sweepMessage, err := s.extractServicePayload(svc.Message)
	if err != nil {
		// Even if unwrapping fails, we can try to process the original message for backward compatibility
		log.Printf("Warning: could not extract enhanced sweep payload, falling back to original message: %v", err)
		sweepMessage = svc.Message
	}
	
	// Update context from enhanced payload if available
	contextPollerID := svc.PollerID
	contextPartition := partition
	contextAgentID := svc.AgentID
	
	if enhancedPayload != nil {
		contextPollerID = enhancedPayload.PollerID
		contextPartition = enhancedPayload.Partition
		contextAgentID = enhancedPayload.AgentID
		log.Printf("Using enhanced payload context for sweep: PollerID=%s, Partition=%s, AgentID=%s", 
			contextPollerID, contextPartition, contextAgentID)
	}

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

	if err := json.Unmarshal(sweepMessage, &sweepData); err != nil {
		return fmt.Errorf("%w: failed to unmarshal sweep data: %w", errInvalidSweepData, err)
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

	resultsToStore := make([]*models.SweepResult, 0, len(sweepData.Hosts))

	for _, host := range sweepData.Hosts {
		if host.IP == "" {
			log.Printf("Skipping host with empty IP for poller %s", contextPollerID)
			continue
		}

		result := &models.SweepResult{
			AgentID:         contextAgentID,
			PollerID:        contextPollerID,
			Partition:       contextPartition,
			DiscoverySource: "sweep",
			IP:              host.IP,
			MAC:             host.MAC,
			Hostname:        host.Hostname,
			Timestamp:       now,
			Available:       host.Available,
			Metadata:        host.Metadata,
		}
		resultsToStore = append(resultsToStore, result)
	}

	if len(resultsToStore) == 0 {
		log.Printf("No sweep results to store for poller %s", contextPollerID)

		return nil
	}

	if err := s.DB.StoreSweepResults(ctx, resultsToStore); err != nil {
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
