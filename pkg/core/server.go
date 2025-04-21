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
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
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

func NewServer(_ context.Context, config *Config) (*Server, error) {
	normalizedConfig := normalizeConfig(config)

	database, err := db.New(getDBPath(normalizedConfig.DBPath))
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errDatabaseError, err)
	}

	authConfig, err := initializeAuthConfig(normalizedConfig)
	if err != nil {
		return nil, err
	}

	metricsManager := metrics.NewManager(models.MetricsConfig(normalizedConfig.Metrics), database)

	server := &Server{
		db:             database,
		alertThreshold: normalizedConfig.AlertThreshold,
		webhooks:       make([]alerts.AlertService, 0),
		ShutdownChan:   make(chan struct{}),
		pollerPatterns: normalizedConfig.PollerPatterns,
		metrics:        metricsManager,
		snmpManager:    snmp.NewSNMPManager(database),
		rperfManager:   rperf.NewRperfManager(database),
		config:         normalizedConfig,
		authService:    auth.NewAuth(authConfig, database),
	}

	server.initializeWebhooks(normalizedConfig.Webhooks)

	return server, nil
}

func normalizeConfig(config *Config) *Config {
	normalized := *config // Shallow copy
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

	// Apply config overrides
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

// Start implements the lifecycle.Service interface.
func (s *Server) Start(ctx context.Context) error {
	log.Printf("Starting core service...")

	// Clean up any unknown pollers first
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

	go s.periodicCleanup(ctx)

	go s.runMetricsCleanup(ctx)

	go s.monitorPollers(ctx)

	return nil
}

// Stop gracefully shuts down the server.
func (s *Server) Stop(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()

	// Send shutdown notification
	if err := s.sendShutdownNotification(ctx); err != nil {
		log.Printf("Failed to send shutdown notification: %v", err)
	}

	// Stop GRPC server if it exists
	if s.grpcServer != nil {
		// Stop no longer returns an error, just call it
		s.grpcServer.Stop(ctx)
	}

	// Close database
	if err := s.db.Close(); err != nil {
		log.Printf("Error closing database: %v", err)
	}

	// Signal all background tasks to stop
	close(s.ShutdownChan)

	return nil
}

// monitorPollers runs the main poller monitoring loop.
func (s *Server) monitorPollers(ctx context.Context) {
	log.Printf("Starting poller monitoring...")

	time.Sleep(pollerDiscoveryTimeout)

	// Initial checks
	s.checkInitialStates()

	time.Sleep(pollerNeverReportedTimeout)
	s.CheckNeverReportedPollersStartup(ctx)

	// Start monitoring loop
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
	// Use the config values directly where needed
	for _, known := range s.config.KnownPollers {
		if known == pollerID {
			return true
		}
	}

	return false
}

func (s *Server) cleanupUnknownPollers(ctx context.Context) error {
	if len(s.config.KnownPollers) == 0 {
		return nil // No filtering if no known pollers specified
	}

	// set a timer on the context to ensure we don't run indefinitely
	_, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()

	// Build a query with placeholders for known pollers
	placeholders := make([]string, len(s.config.KnownPollers))

	args := make([]interface{}, len(s.config.KnownPollers))

	for i, poller := range s.config.KnownPollers {
		placeholders[i] = "?"
		args[i] = poller
	}

	// Delete all pollers not in known_pollers
	query := fmt.Sprintf("DELETE FROM pollers WHERE poller_id NOT IN (%s)",
		strings.Join(placeholders, ","))

	result, err := s.db.Exec(query, args...)
	if err != nil {
		return fmt.Errorf("failed to cleanup unknown pollers: %w", err)
	}

	if rows, err := result.RowsAffected(); err == nil && rows > 0 {
		log.Printf("Cleaned up %d unknown poller(s) from database", rows)
	}

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
			"version":  "1.0.33",
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

func (s *Server) SetAPIServer(apiServer api.Service) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.apiServer = apiServer
	apiServer.SetKnownPollers(s.config.KnownPollers)

	apiServer.SetPollerHistoryHandler(func(pollerID string) ([]api.PollerHistoryPoint, error) {
		points, err := s.db.GetPollerHistoryPoints(pollerID, pollerHistoryLimit)
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

func (s *Server) checkInitialStates() {
	likeConditions := make([]string, 0, len(s.pollerPatterns))
	args := make([]interface{}, 0, len(s.pollerPatterns))

	// Construct the WHERE clause with multiple LIKE conditions
	for _, pattern := range s.pollerPatterns {
		likeConditions = append(likeConditions, "poller_id LIKE ?")
		args = append(args, pattern)
	}

	// Base query without WHERE clause
	query := `
        SELECT poller_id, is_healthy, last_seen 
        FROM pollers
    `

	// Add WHERE clause only if there are conditions
	if len(likeConditions) > 0 {
		query += fmt.Sprintf("WHERE %s ", strings.Join(likeConditions, " OR "))
	}

	// Add ORDER BY clause
	query += "ORDER BY last_seen DESC"

	rows, err := s.db.Query(query, args...)
	if err != nil {
		log.Printf("Error querying pollers: %v", err)

		return
	}
	defer db.CloseRows(rows)

	for rows.Next() {
		var pollerID string

		var isHealthy bool

		var lastSeen time.Time

		if err := rows.Scan(&pollerID, &isHealthy, &lastSeen); err != nil {
			log.Printf("Error scanning poller row: %v", err)
			continue
		}

		duration := time.Since(lastSeen)
		if duration > s.alertThreshold {
			log.Printf("Poller %s found offline during initial check (last seen: %v ago)",
				pollerID, duration.Round(time.Second))
		}
	}
}

// updateAPIState updates the API server with the latest poller status.
func (s *Server) updateAPIState(pollerID string, apiStatus *api.PollerStatus) {
	if s.apiServer == nil {
		log.Printf("Warning: API server not initialized, state not updated")

		return
	}

	s.apiServer.UpdatePollerStatus(pollerID, apiStatus)

	log.Printf("Updated API server state for poller: %s", pollerID)
}

// getPollerHealthState retrieves the current health state of a poller.
func (s *Server) getPollerHealthState(pollerID string) (bool, error) {
	var currentState bool

	err := s.db.QueryRow("SELECT is_healthy FROM pollers WHERE poller_id = ?", pollerID).Scan(&currentState)

	return currentState, err
}

func (s *Server) processStatusReport(
	ctx context.Context, req *proto.PollerStatusRequest, now time.Time) (*api.PollerStatus, error) {
	currentState, err := s.getPollerHealthState(req.PollerId)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		log.Printf("Error checking poller state: %v", err)
	}

	apiStatus := s.createPollerStatus(req, now)

	s.processServices(req.PollerId, apiStatus, req.Services, now)

	if err := s.updatePollerState(ctx, req.PollerId, apiStatus, currentState, now); err != nil {
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

func (s *Server) processServices(pollerID string, apiStatus *api.PollerStatus, services []*proto.ServiceStatus, now time.Time) {
	allServicesAvailable := true

	for _, svc := range services {
		s.logServiceProcessing(pollerID, svc)

		apiService := s.createAPIService(svc)

		if !svc.Available {
			allServicesAvailable = false
		}

		if err := s.processServiceDetails(pollerID, &apiService, svc, now); err != nil {
			log.Printf("Error processing service %s: %v", svc.ServiceName, err)
		}

		apiStatus.Services = append(apiStatus.Services, apiService)
	}

	apiStatus.IsHealthy = allServicesAvailable
}

func (*Server) logServiceProcessing(pollerID string, svc *proto.ServiceStatus) {
	log.Printf("Processing service %s for poller %s", svc.ServiceName, pollerID)
	log.Printf("Service type/name: %s/%s, Message length: %d",
		svc.ServiceType,
		svc.ServiceName,
		len(svc.Message))
}

func (*Server) createAPIService(svc *proto.ServiceStatus) api.ServiceStatus {
	return api.ServiceStatus{
		Name:      svc.ServiceName,
		Type:      svc.ServiceType,
		Available: svc.Available,
		Message:   svc.Message,
	}
}

func (s *Server) processServiceDetails(pollerID string, apiService *api.ServiceStatus, svc *proto.ServiceStatus, now time.Time) error {
	if svc.Message == "" {
		log.Printf("No message content for service %s", svc.ServiceName)

		return s.handleService(pollerID, apiService, now)
	}

	details, err := s.parseServiceDetails(svc)
	if err != nil {
		return s.handleService(pollerID, apiService, now)
	}

	apiService.Details = details

	if err := s.processSpecializedMetrics(pollerID, svc, details, now); err != nil {
		return err
	}

	return s.handleService(pollerID, apiService, now)
}

func (*Server) parseServiceDetails(svc *proto.ServiceStatus) (json.RawMessage, error) {
	var details json.RawMessage
	if err := json.Unmarshal([]byte(svc.Message), &details); err != nil {
		log.Printf("Error unmarshaling service details for %s: %v", svc.ServiceName, err)
		log.Printf("Raw message: %s", svc.Message)
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

func (s *Server) processSpecializedMetrics(pollerID string, svc *proto.ServiceStatus, details json.RawMessage, now time.Time) error {
	switch {
	case svc.ServiceType == snmpServiceType:
		return s.processSNMPMetrics(pollerID, details, now)
	case svc.ServiceType == grpcServiceType && svc.ServiceName == rperfServiceType:
		return s.processRperfMetrics(pollerID, details, now)
	case svc.ServiceType == grpcServiceType && svc.ServiceName == sysmonServiceType:
		return s.processSysmonMetrics(pollerID, details, now)
	case svc.ServiceType == icmpServiceType && svc.ServiceName == rperfServiceType:
		return s.processICMPMetrics(pollerID, svc, details, now)
	}

	return nil
}

func (s *Server) processSysmonMetrics(pollerID string, details json.RawMessage, timestamp time.Time) error {
	log.Printf("Processing sysmon for poller %s", pollerID)

	// Print raw JSON for debugging
	log.Printf("Raw sysmon data: %s", string(details))

	// First, parse the outer JSON structure to extract the nested JSON string
	var outerData struct {
		Status       string `json:"status"`        // This contains the nested JSON
		ResponseTime int64  `json:"response_time"` // Optional fields
		Available    bool   `json:"available"`     // Optional fields
	}

	if err := json.Unmarshal(details, &outerData); err != nil {
		log.Printf("Error unmarshaling outer sysmon data: %v", err)
		return fmt.Errorf("failed to parse outer sysmon data: %w", err)
	}

	// Now parse the nested JSON in the "status" field
	if outerData.Status == "" {
		log.Printf("Empty status field in sysmon data")
		return errEmptyStatusField
	}

	// Parse the inner JSON data
	var sysmonData models.SysmonMetricData
	if err := json.Unmarshal([]byte(outerData.Status), &sysmonData); err != nil {
		log.Printf("Error unmarshaling inner sysmon data: %v", err)
		return fmt.Errorf("failed to parse inner sysmon data: %w", err)
	}

	// Safely check if the memory field has data by checking for zero values
	hasMemoryData := sysmonData.Memory.TotalBytes > 0 || sysmonData.Memory.UsedBytes > 0

	log.Printf("Parsed sysmon data: CPUs=%d, Disks=%d, HasMemoryData=%v",
		len(sysmonData.CPUs), len(sysmonData.Disks), hasMemoryData)

	// Now process the correctly parsed data
	m := &models.SysmonMetrics{
		CPUs:   make([]models.CPUMetric, len(sysmonData.CPUs)),
		Disks:  make([]models.DiskMetric, len(sysmonData.Disks)),
		Memory: models.MemoryMetric{},
	}

	// Process CPU metrics
	for i, cpu := range sysmonData.CPUs {
		m.CPUs[i] = models.CPUMetric{
			CoreID:       int(cpu.CoreID),
			UsagePercent: float64(cpu.UsagePercent),
			Timestamp:    timestamp,
		}
	}

	// Process disk metrics
	log.Printf("Processing %d disk metrics", len(sysmonData.Disks))

	for i, disk := range sysmonData.Disks {
		log.Printf("Disk %d: mount_point=%s, used=%d, total=%d",
			i, disk.MountPoint, disk.UsedBytes, disk.TotalBytes)

		m.Disks[i] = models.DiskMetric{
			MountPoint: disk.MountPoint,
			UsedBytes:  disk.UsedBytes,
			TotalBytes: disk.TotalBytes,
			Timestamp:  timestamp,
		}
	}

	// Process memory metrics (Memory is a struct, not a pointer, so we can't check for nil)
	// Instead, we check if it has meaningful data
	if hasMemoryData {
		m.Memory = models.MemoryMetric{
			UsedBytes:  sysmonData.Memory.UsedBytes,
			TotalBytes: sysmonData.Memory.TotalBytes,
			Timestamp:  timestamp,
		}
	}

	// Store metrics in database
	if err := s.metrics.StoreSysmonMetrics(pollerID, m, timestamp); err != nil {
		return fmt.Errorf("failed to store sysmon metrics: %w", err)
	}

	log.Printf("Successfully stored sysmon metrics for poller %s: %d CPUs, %d disks, memory data present: %v",
		pollerID, len(m.CPUs), len(m.Disks), hasMemoryData)

	return nil
}

func (s *Server) processRperfMetrics(pollerID string, details json.RawMessage, timestamp time.Time) error {
	log.Printf("Processing rperf m for poller %s", pollerID)

	var rperfData models.RperfMetricData

	if err := json.Unmarshal(details, &rperfData); err != nil {
		return fmt.Errorf("failed to parse rperf data: %w", err)
	}

	m := &models.RperfMetrics{
		Results: make([]models.RperfMetric, len(rperfData.Results)),
	}

	for i, result := range rperfData.Results {
		m.Results[i] = models.RperfMetric{
			Target:          result.Target,
			Success:         result.Success,
			Error:           result.Error,
			BitsPerSecond:   result.Summary.BitsPerSecond,
			BytesReceived:   result.Summary.BytesReceived,
			BytesSent:       result.Summary.BytesSent,
			Duration:        result.Summary.Duration,
			JitterMs:        result.Summary.JitterMs,
			LossPercent:     result.Summary.LossPercent,
			PacketsLost:     result.Summary.PacketsLost,
			PacketsReceived: result.Summary.PacketsReceived,
			PacketsSent:     result.Summary.PacketsSent,
			Timestamp:       timestamp,
		}
	}

	if err := s.metrics.StoreRperfMetrics(pollerID, m, timestamp); err != nil {
		return fmt.Errorf("failed to store rperf m: %w", err)
	}

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
		log.Printf("Failed to parse ICMP response for service %s: %v", svc.ServiceName, err)

		return fmt.Errorf("failed to parse ICMP data: %w", err)
	}

	if err := s.metrics.AddMetric(
		pollerID,
		now,
		pingResult.ResponseTime,
		svc.ServiceName,
	); err != nil {
		log.Printf("Failed to add ICMP metric for %s: %v", svc.ServiceName, err)

		return fmt.Errorf("failed to store ICMP metric: %w", err)
	}

	log.Printf("Stored ICMP metric for %s: response_time=%.2fms",
		svc.ServiceName, float64(pingResult.ResponseTime)/float64(time.Millisecond))

	return nil
}

// processSNMPMetrics extracts and stores SNMP metrics from service details.
func (s *Server) processSNMPMetrics(pollerID string, details json.RawMessage, timestamp time.Time) error {
	log.Printf("Processing SNMP metrics for poller %s", pollerID)

	// Parse the outer structure which contains target-specific data
	var snmpData map[string]struct {
		Available bool                     `json:"available"`
		LastPoll  string                   `json:"last_poll"`
		OIDStatus map[string]OIDStatusData `json:"oid_status"`
	}

	if err := json.Unmarshal(details, &snmpData); err != nil {
		return fmt.Errorf("failed to parse SNMP data: %w", err)
	}

	// Process each target's data
	for targetName, targetData := range snmpData {
		log.Printf("Processing target %s with %d OIDs", targetName, len(targetData.OIDStatus))

		// Process each OID's data
		for oidName, oidStatus := range targetData.OIDStatus {
			// Create metadata
			metadata := map[string]interface{}{
				"target_name": targetName,
				"last_poll":   targetData.LastPoll,
			}

			// Convert the value to string for storage
			valueStr := fmt.Sprintf("%v", oidStatus.LastValue)

			// Create metric
			metric := &db.TimeseriesMetric{
				Name:      oidName,
				Value:     valueStr,
				Type:      "snmp",
				Timestamp: timestamp,
				Metadata:  metadata,
			}

			// Store in database
			if err := s.db.StoreMetric(pollerID, metric); err != nil {
				log.Printf("Error storing SNMP metric %s for poller %s: %v", oidName, pollerID, err)

				continue
			}
		}
	}

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

	// If LastSweep is not set or is invalid (0 or negative), use current time
	if sweepData.LastSweep > now.Add(oneDay).Unix() {
		log.Printf("Invalid or missing LastSweep timestamp (%d), using current time", sweepData.LastSweep)
		sweepData.LastSweep = now.Unix()

		// Update the message with corrected timestamp
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

		log.Printf("Updated sweep data with current timestamp: %v", now.Format(time.RFC3339))
	} else {
		// Log the existing timestamp for debugging
		log.Printf("Processing sweep data with timestamp: %v",
			time.Unix(sweepData.LastSweep, 0).Format(time.RFC3339))
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

	if err := s.db.UpdateServiceStatus(status); err != nil {
		return fmt.Errorf("%w: failed to update service status", errDatabaseError)
	}

	return nil
}

// storePollerStatus updates the poller status in the database.
func (s *Server) storePollerStatus(pollerID string, isHealthy bool, now time.Time) error {
	pollerStatus := &db.PollerStatus{
		PollerID:  pollerID,
		IsHealthy: isHealthy,
		LastSeen:  now,
	}

	if err := s.db.UpdatePollerStatus(pollerStatus); err != nil {
		return fmt.Errorf("failed to store poller status: %w", err)
	}

	return nil
}

func (s *Server) updatePollerState(
	ctx context.Context, pollerID string, apiStatus *api.PollerStatus, wasHealthy bool, now time.Time) error {
	if err := s.storePollerStatus(pollerID, apiStatus.IsHealthy, now); err != nil {
		return err
	}

	// Check for recovery
	if !wasHealthy && apiStatus.IsHealthy {
		s.handlePollerRecovery(ctx, pollerID, apiStatus, now)
	}

	return nil
}

// periodicCleanup runs regular maintenance tasks on the database.
func (s *Server) periodicCleanup(_ context.Context) {
	ticker := time.NewTicker(1 * time.Hour)
	defer ticker.Stop()

	for {
		select {
		case <-s.ShutdownChan:
			return
		case <-ticker.C:
			// Clean up old data (keep 7 days by default)
			if err := s.db.CleanOldData(7 * 24 * time.Hour); err != nil {
				log.Printf("Error during periodic cleanup: %v", err)
			}

			// Vacuum the database every 24 hours to reclaim space
			if time.Now().Hour() == 0 { // Run at midnight
				if _, err := s.db.Exec("VACUUM"); err != nil {
					log.Printf("Error vacuuming database: %v", err)
				}
			}
		}
	}
}

// checkNeverReportedPollers checks for and alerts on pollers that exist but have never reported.
func (s *Server) checkNeverReportedPollers(ctx context.Context) error {
	conditions := make([]string, 0, len(s.pollerPatterns))
	args := make([]interface{}, 0, len(s.pollerPatterns))

	// Build LIKE conditions for each pattern
	for _, pattern := range s.pollerPatterns {
		conditions = append(conditions, "poller_id LIKE ?")
		args = append(args, pattern)
	}

	// Construct query with LIKE conditions
	query := `SELECT poller_id FROM pollers WHERE last_seen = ''`
	if len(conditions) > 0 {
		query += " AND (" + strings.Join(conditions, " OR ") + ")"
	}

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return fmt.Errorf("error querying unreported pollers: %w", err)
	}
	defer db.CloseRows(rows)

	var unreportedPollers []string

	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			log.Printf("Error scanning poller ID: %v", err)
			continue
		}

		unreportedPollers = append(unreportedPollers, id)
	}

	// Check for any errors encountered during iteration
	if err := rows.Err(); err != nil {
		return fmt.Errorf("error iterating rows: %w", err)
	}

	if len(unreportedPollers) > 0 {
		alert := &alerts.WebhookAlert{
			Level:     alerts.Warning,
			Title:     "Pollers Never Reported",
			Message:   fmt.Sprintf("%d poller(s) have not reported since startup", len(unreportedPollers)),
			PollerID:  "core",
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			Details: map[string]any{
				"hostname":     getHostname(),
				"poller_ids":   unreportedPollers,
				"poller_count": len(unreportedPollers),
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

	// Build SQL pattern for REGEXP
	combinedPattern := strings.Join(s.pollerPatterns, "|")
	if combinedPattern == "" {
		return
	}

	var unreportedPollers []string

	rows, err := s.db.Query(`
        SELECT poller_id 
        FROM pollers
        WHERE poller_id REGEXP ? AND last_seen = ''`,
		combinedPattern)
	if err != nil {
		log.Printf("Error querying unreported pollers: %v", err)
		return
	}
	defer db.CloseRows(rows)

	for rows.Next() {
		var pollerID string
		if err := rows.Scan(&pollerID); err != nil {
			log.Printf("Error scanning poller ID: %v", err)

			continue
		}

		unreportedPollers = append(unreportedPollers, pollerID)
	}

	if len(unreportedPollers) > 0 {
		s.sendUnreportedPollersAlert(ctx, unreportedPollers)
	}
}

func (s *Server) sendUnreportedPollersAlert(ctx context.Context, pollerIDs []string) {
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
	}
}

// GetRperfManager returns the RperfManager instance.
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
	ticker := time.NewTicker(monitorInterval) // Check every 30 seconds
	defer ticker.Stop()

	cleanupTicker := time.NewTicker(dailyCleanupInterval)
	defer cleanupTicker.Stop()

	// Initial checks
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
		case <-cleanupTicker.C:
			s.handleCleanupTick()
		}
	}
}

// handleMonitorTick handles the logic for the monitor ticker.
func (s *Server) handleMonitorTick(ctx context.Context) {
	if err := s.checkPollerStatus(ctx); err != nil {
		log.Printf("Poller state check failed: %v", err)
	}

	if err := s.checkNeverReportedPollers(ctx); err != nil {
		log.Printf("Never-reported check failed: %v", err)
	}
}

// handleCleanupTick handles the logic for the cleanup ticker.
func (s *Server) handleCleanupTick() {
	if err := s.performDailyCleanup(); err != nil {
		log.Printf("Daily cleanup failed: %v", err)
	}
}

// performDailyCleanup performs the daily cleanup task.
func (s *Server) performDailyCleanup() error {
	log.Println("Performing daily cleanup...")

	if err := s.db.CleanOldData(oneWeek); err != nil {
		log.Printf("Error cleaning old data: %v", err)

		return err
	}

	return nil
}

func (s *Server) checkPollerStatus(ctx context.Context) error {
	// Pre-allocate slices
	conditions := make([]string, 0, len(s.pollerPatterns))
	args := make([]interface{}, 0, len(s.pollerPatterns))

	// Build LIKE conditions for each pattern
	for _, pattern := range s.pollerPatterns {
		conditions = append(conditions, "poller_id LIKE ?")
		args = append(args, pattern)
	}

	// Construct query with LIKE conditions
	query := `SELECT poller_id, last_seen, is_healthy FROM pollers`
	if len(conditions) > 0 {
		query += " WHERE " + strings.Join(conditions, " OR ")
	}

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return fmt.Errorf("failed to query pollers: %w", err)
	}
	defer db.CloseRows(rows)

	threshold := time.Now().Add(-s.alertThreshold)

	for rows.Next() {
		var pollerID string

		var lastSeen time.Time

		var isHealthy bool

		if err := rows.Scan(&pollerID, &lastSeen, &isHealthy); err != nil {
			log.Printf("Error scanning poller row: %v", err)

			continue
		}

		err := s.evaluatePollerHealth(ctx, pollerID, lastSeen, isHealthy, threshold)
		if err != nil {
			// Only log errors, don't propagate service-related issues
			log.Printf("Error evaluating poller %s health: %v", pollerID, err)
		}
	}

	return rows.Err()
}

func (s *Server) evaluatePollerHealth(
	ctx context.Context, pollerID string, lastSeen time.Time, isHealthy bool, threshold time.Time) error {
	log.Printf("Evaluating poller health: id=%s lastSeen=%v isHealthy=%v threshold=%v",
		pollerID, lastSeen.Format(time.RFC3339), isHealthy, threshold.Format(time.RFC3339))

	// Case 1: Poller was healthy but hasn't been seen recently (went down)
	if isHealthy && lastSeen.Before(threshold) {
		duration := time.Since(lastSeen).Round(time.Second)
		log.Printf("Poller %s appears to be offline (last seen: %v ago)", pollerID, duration)

		return s.handlePollerDown(ctx, pollerID, lastSeen)
	}

	// Case 2: Poller is healthy and reporting within threshold - DO NOTHING
	if isHealthy && !lastSeen.Before(threshold) {
		return nil
	}

	// Case 3: Poller is reporting but its status might have changed
	if !lastSeen.Before(threshold) {
		// Get the current health status
		currentHealth, err := s.getPollerHealthState(pollerID)
		if err != nil {
			log.Printf("Error getting current health state for poller %s: %v", pollerID, err)

			return fmt.Errorf("failed to get current health state: %w", err)
		}

		// ONLY handle potential recovery - do not send service alerts here
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
	if err := s.updatePollerStatus(pollerID, false, lastSeen); err != nil {
		return fmt.Errorf("failed to update poller status: %w", err)
	}

	// Send alert
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

	// Update API state
	if s.apiServer != nil {
		s.apiServer.UpdatePollerStatus(pollerID, &api.PollerStatus{
			PollerID:   pollerID,
			IsHealthy:  false,
			LastUpdate: lastSeen,
		})
	}

	return nil
}

func (s *Server) updatePollerStatus(pollerID string, isHealthy bool, timestamp time.Time) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}

	defer func() {
		if err != nil {
			if rbErr := tx.Rollback(); rbErr != nil {
				log.Printf("Error rolling back transaction: %v", rbErr)
			}
		}
	}()

	// Use Transaction interface directly instead of converting to *sql.Tx
	if err := s.updatePollerInTx(tx, pollerID, isHealthy, timestamp); err != nil {
		return err
	}

	if _, err := tx.Exec(`
        INSERT INTO poller_history (poller_id, timestamp, is_healthy)
        VALUES (?, ?, ?)
    `, pollerID, timestamp, isHealthy); err != nil {
		return fmt.Errorf("failed to insert history: %w", err)
	}

	return tx.Commit()
}

func (*Server) updatePollerInTx(tx db.Transaction, pollerID string, isHealthy bool, timestamp time.Time) error {
	// Check if poller exists
	var exists bool
	if err := tx.QueryRow("SELECT EXISTS(SELECT 1 FROM pollers WHERE poller_id = ?)", pollerID).Scan(&exists); err != nil {
		return fmt.Errorf("failed to check poller existence: %w", err)
	}

	if exists {
		_, err := tx.Exec(`
            UPDATE pollers 
            SET is_healthy = ?,
                last_seen = ?
            WHERE poller_id = ?
        `, isHealthy, timestamp, pollerID)

		return err
	}

	// Insert new poller
	_, err := tx.Exec(`
        INSERT INTO pollers (poller_id, first_seen, last_seen, is_healthy)
        VALUES (?, ?, ?, ?)
    `, pollerID, timestamp, timestamp, isHealthy)

	return err
}

func (s *Server) handlePollerRecovery(ctx context.Context, pollerID string, apiStatus *api.PollerStatus, timestamp time.Time) {
	// Reset the "down" state in the alerter *before* sending the alert.
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
		ServiceName: "", // Ensure ServiceName is empty for poller-level alerts
		Details: map[string]any{
			"hostname":      getHostname(),
			"recovery_time": timestamp.Format(time.RFC3339),
			"services":      len(apiStatus.Services), //  This might be 0, which is fine.
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

// ReportStatus implements the PollerServiceServer interface. It processes status reports from pollers.
func (s *Server) ReportStatus(ctx context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
	log.Printf("Received status report from %s with %d services", req.PollerId, len(req.Services))

	if req.PollerId == "" {
		return nil, errEmptyPollerID
	}

	// Add check for known pollers
	if !s.isKnownPoller(req.PollerId) {
		log.Printf("Ignoring status report from unknown poller: %s", req.PollerId)

		return &proto.PollerStatusResponse{Received: true}, nil
	}

	now := time.Unix(req.Timestamp, 0)
	timestamp := time.Now()
	responseTime := timestamp.Sub(now).Nanoseconds()

	log.Printf("Response time for %s: %d ns (%.2f ms)",
		req.PollerId,
		responseTime,
		float64(responseTime)/float64(time.Millisecond))

	apiStatus, err := s.processStatusReport(ctx, req, now)
	if err != nil {
		return nil, fmt.Errorf("failed to process status report: %w", err)
	}

	if s.metrics != nil {
		for _, service := range req.Services {
			if service.ServiceType != "icmp" {
				continue
			}

			// Parse the ping response
			var pingResult struct {
				Host         string  `json:"host"`
				ResponseTime int64   `json:"response_time"`
				PacketLoss   float64 `json:"packet_loss"`
				Available    bool    `json:"available"`
			}

			if err := json.Unmarshal([]byte(service.Message), &pingResult); err != nil {
				log.Printf("Failed to parse ICMP response for service %s: %v", service.ServiceName, err)

				continue
			}

			// Add metric with the actual response time
			if err := s.metrics.AddMetric(
				req.PollerId,
				time.Now(),
				pingResult.ResponseTime,
				service.ServiceName,
			); err != nil {
				log.Printf("Failed to add ICMP metric for %s: %v", service.ServiceName, err)

				continue
			}

			log.Printf("Added ICMP metric for %s: time=%v response_time=%.2fms",
				service.ServiceName,
				time.Now().Format(time.RFC3339),
				float64(pingResult.ResponseTime)/float64(time.Millisecond))
		}
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
