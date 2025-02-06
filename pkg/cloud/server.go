package cloud

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/cloud/alerts"
	"github.com/mfreeman451/serviceradar/pkg/cloud/api"
	"github.com/mfreeman451/serviceradar/pkg/db"
	"github.com/mfreeman451/serviceradar/pkg/metrics"
	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/proto"
)

const (
	downtimeValue            = "unknown"
	shutdownTimeout          = 10 * time.Second
	oneDay                   = 24 * time.Hour
	oneWeek                  = 7 * oneDay
	serviceradarDirPerms     = 0700
	nodeHistoryLimit         = 1000
	nodeDiscoveryTimeout     = 30 * time.Second
	nodeNeverReportedTimeout = 30 * time.Second
	defaultDBPath            = "/var/lib/serviceradar/serviceradar.db"
	statusUnknown            = "unknown"
	sweepService             = "sweep"
	dailyCleanupInterval     = 24 * time.Hour
	monitorInterval          = 30 * time.Second
)

func NewServer(_ context.Context, config *Config) (*Server, error) {
	if config.Metrics.Retention == 0 {
		config.Metrics.Retention = 100
	}

	if config.Metrics.MaxNodes == 0 {
		config.Metrics.MaxNodes = 10000
	}

	// log the config.Metrics
	log.Printf("Metrics config: %+v", config.Metrics)

	metricsManager := metrics.NewManager(models.MetricsConfig{
		Enabled:   config.Metrics.Enabled,
		Retention: config.Metrics.Retention,
		MaxNodes:  config.Metrics.MaxNodes,
	})

	// Use default DB path if not specified
	dbPath := config.DBPath
	if dbPath == "" {
		dbPath = defaultDBPath
	}

	// Ensure the directory exists
	if err := os.MkdirAll("/var/lib/serviceradar", serviceradarDirPerms); err != nil {
		return nil, fmt.Errorf("failed to create data directory: %w", err)
	}

	// Initialize database
	database, err := db.New(dbPath)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errDatabaseError, err)
	}

	server := &Server{
		db:             database,
		alertThreshold: config.AlertThreshold,
		webhooks:       make([]alerts.AlertService, 0),
		ShutdownChan:   make(chan struct{}),
		pollerPatterns: config.PollerPatterns,
		metrics:        metricsManager,
		config:         config,
	}

	// Initialize webhooks
	server.initializeWebhooks(config.Webhooks)

	return server, nil
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
	log.Printf("Starting cloud service...")

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

	go s.monitorNodes(ctx)

	return nil
}

// monitorNodes runs the main node monitoring loop.
func (s *Server) monitorNodes(ctx context.Context) {
	log.Printf("Starting node monitoring...")

	time.Sleep(nodeDiscoveryTimeout)

	// Initial checks
	s.checkInitialStates(ctx)

	time.Sleep(nodeNeverReportedTimeout)
	s.checkNeverReportedPollers(ctx)

	// Start monitoring loop
	s.MonitorPollers(ctx)
}

func (s *Server) GetMetricsManager() metrics.MetricCollector {
	return s.metrics
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
				if manager, ok := s.metrics.(*metrics.Manager); ok {
					manager.CleanupStaleNodes(oneWeek)
				} else {
					log.Printf("Error: s.metrics is not of type *metrics.Manager")
				}
			}
		}
	}
}

// Stop implements the lifecycle.Service interface.
func (s *Server) Stop(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()

	// Send shutdown notification
	if err := s.sendShutdownNotification(ctx); err != nil {
		log.Printf("Failed to send shutdown notification: %v", err)
	}

	// Stop GRPC server if it exists
	if s.grpcServer != nil {
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

	// Delete all nodes not in known_pollers
	query := fmt.Sprintf("DELETE FROM nodes WHERE node_id NOT IN (%s)",
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
		Title:     "Cloud Service Started",
		Message:   fmt.Sprintf("ServiceRadar cloud service initialized at %s", time.Now().Format(time.RFC3339)),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		NodeID:    "cloud",
		Details: map[string]any{
			"version":  "1.0.15",
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
		Title:     "Cloud Service Stopping",
		Message:   fmt.Sprintf("ServiceRadar cloud service shutting down at %s", time.Now().Format(time.RFC3339)),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		NodeID:    "cloud",
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
			Title:     "Cloud Service Stopping",
			Message:   fmt.Sprintf("ServiceRadar cloud service shutting down at %s", time.Now().Format(time.RFC3339)),
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			NodeID:    "cloud",
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

	apiServer.SetNodeHistoryHandler(func(nodeID string) ([]api.NodeHistoryPoint, error) {
		points, err := s.db.GetNodeHistoryPoints(nodeID, nodeHistoryLimit)
		if err != nil {
			return nil, fmt.Errorf("failed to get node history: %w", err)
		}

		// debug points
		log.Printf("Fetched %d history points for node: %s", len(points), nodeID)
		// log first 20 points
		for i := 0; i < 20 && i < len(points); i++ {
			log.Printf("Point %d: %v", i, points[i])
		}

		apiPoints := make([]api.NodeHistoryPoint, len(points))
		for i, p := range points {
			apiPoints[i] = api.NodeHistoryPoint{
				Timestamp: p.Timestamp,
				IsHealthy: p.IsHealthy,
			}
		}

		return apiPoints, nil
	})
}

func (s *Server) checkInitialStates(ctx context.Context) {
	log.Printf("Checking initial states of all nodes")

	likeConditions := make([]string, 0, len(s.pollerPatterns))
	args := make([]interface{}, 0, len(s.pollerPatterns))

	// Construct the WHERE clause with multiple LIKE conditions
	for _, pattern := range s.pollerPatterns {
		likeConditions = append(likeConditions, "node_id LIKE ?")
		args = append(args, pattern)
	}

	// Base query without WHERE clause
	query := `
        SELECT node_id, is_healthy, last_seen 
        FROM nodes 
    `

	// Add WHERE clause only if there are conditions
	if len(likeConditions) > 0 {
		query += fmt.Sprintf("WHERE %s ", strings.Join(likeConditions, " OR "))
	}

	// Add ORDER BY clause
	query += "ORDER BY last_seen DESC"

	rows, err := s.db.Query(query, args...)
	if err != nil {
		log.Printf("Error querying nodes: %v", err)

		return
	}
	defer db.CloseRows(rows)

	for rows.Next() {
		var nodeID string

		var isHealthy bool

		var lastSeen time.Time

		if err := rows.Scan(&nodeID, &isHealthy, &lastSeen); err != nil {
			log.Printf("Error scanning node row: %v", err)

			continue
		}

		duration := time.Since(lastSeen)
		if duration > s.alertThreshold {
			log.Printf("Node %s found offline during initial check (last seen: %v ago)",
				nodeID, duration.Round(time.Second))

			if err := s.markNodeDown(ctx, nodeID, time.Now()); err != nil {
				log.Printf("Error marking node down: %v", err)
			}
		}
	}
}

// updateAPIState updates the API server with the latest node status.
func (s *Server) updateAPIState(pollerID string, apiStatus *api.NodeStatus) {
	if s.apiServer == nil {
		log.Printf("Warning: API server not initialized, state not updated")

		return
	}

	s.apiServer.UpdateNodeStatus(pollerID, apiStatus)

	log.Printf("Updated API server state for node: %s", pollerID)
}

// getNodeHealthState retrieves the current health state of a node.
func (s *Server) getNodeHealthState(pollerID string) (bool, error) {
	var currentState bool

	err := s.db.QueryRow("SELECT is_healthy FROM nodes WHERE node_id = ?", pollerID).Scan(&currentState)

	return currentState, err
}

func (s *Server) processStatusReport(
	ctx context.Context, req *proto.PollerStatusRequest, now time.Time) (*api.NodeStatus, error) {
	currentState, err := s.getNodeHealthState(req.PollerId)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		log.Printf("Error checking node state: %v", err)
	}

	apiStatus := s.createNodeStatus(req, now)

	s.processServices(req.PollerId, apiStatus, req.Services, now)

	if err := s.updateNodeState(ctx, req.PollerId, apiStatus, currentState, now); err != nil {
		return nil, err
	}

	return apiStatus, nil
}

func (*Server) createNodeStatus(req *proto.PollerStatusRequest, now time.Time) *api.NodeStatus {
	return &api.NodeStatus{
		NodeID:     req.PollerId,
		LastUpdate: now,
		IsHealthy:  true,
		Services:   make([]api.ServiceStatus, 0, len(req.Services)),
	}
}

func (s *Server) processServices(pollerID string, apiStatus *api.NodeStatus, services []*proto.ServiceStatus, now time.Time) {
	for _, svc := range services {
		apiService := api.ServiceStatus{
			Name:      svc.ServiceName,
			Type:      svc.ServiceType,
			Available: svc.Available,
			Message:   svc.Message,
		}

		if !svc.Available {
			apiStatus.IsHealthy = false
		}

		// Process JSON details if available
		if svc.Message != "" {
			var details json.RawMessage
			if err := json.Unmarshal([]byte(svc.Message), &details); err == nil {
				apiService.Details = details
			}
		}

		if err := s.handleService(pollerID, &apiService, now); err != nil {
			log.Printf("Error handling service %s: %v", svc.ServiceName, err)
		}

		apiStatus.Services = append(apiStatus.Services, apiService)
	}
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

	log.Printf("Received sweep data with timestamp: %v", time.Unix(sweepData.LastSweep, 0).Format(time.RFC3339))

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
		NodeID:      pollerID,
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

// storeNodeStatus updates the node status in the database.
func (s *Server) storeNodeStatus(pollerID string, isHealthy bool, now time.Time) error {
	nodeStatus := &db.NodeStatus{
		NodeID:    pollerID,
		IsHealthy: isHealthy,
		LastSeen:  now,
	}

	if err := s.db.UpdateNodeStatus(nodeStatus); err != nil {
		return fmt.Errorf("failed to store node status: %w", err)
	}

	return nil
}

func (s *Server) updateNodeState(ctx context.Context, pollerID string, apiStatus *api.NodeStatus, wasHealthy bool, now time.Time) error {
	if err := s.storeNodeStatus(pollerID, apiStatus.IsHealthy, now); err != nil {
		return err
	}

	// Check for recovery
	if !wasHealthy && apiStatus.IsHealthy {
		s.handleNodeRecovery(ctx, pollerID, apiStatus, now)
	}

	return nil
}

// sendNodeDownAlert sends an alert when a node goes down.
func (s *Server) sendNodeDownAlert(ctx context.Context, nodeID string, lastSeen time.Time) {
	alert := &alerts.WebhookAlert{
		Level:     alerts.Error,
		Title:     "Node Offline",
		Message:   fmt.Sprintf("Node '%s' is offline", nodeID),
		NodeID:    nodeID,
		Timestamp: lastSeen.UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname": getHostname(),
			"duration": time.Since(lastSeen).String(),
		},
	}

	err := s.sendAlert(ctx, alert)
	if err != nil {
		log.Printf("Error sending alert: %v", err)
		return
	}
}

// updateAPINodeStatus updates the node status in the API server.
func (s *Server) updateAPINodeStatus(nodeID string, isHealthy bool, timestamp time.Time) {
	if s.apiServer != nil {
		status := &api.NodeStatus{
			NodeID:     nodeID,
			IsHealthy:  isHealthy,
			LastUpdate: timestamp,
		}
		s.apiServer.UpdateNodeStatus(nodeID, status)
	}
}

// markNodeDown handles marking a node as down and sending alerts.
func (s *Server) markNodeDown(ctx context.Context, nodeID string, lastSeen time.Time) error {
	if err := s.updateNodeDownStatus(nodeID, lastSeen); err != nil {
		return err
	}

	s.sendNodeDownAlert(ctx, nodeID, lastSeen)
	s.updateAPINodeStatus(nodeID, false, lastSeen)

	return nil
}

func (s *Server) updateNodeDownStatus(nodeID string, lastSeen time.Time) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer func(tx db.Transaction) {
		err = tx.Rollback()
		if err != nil {
			log.Printf("Error rolling back transaction: %v", err)
		}
	}(tx)

	sqlTx, err := db.ToTx(tx)
	if err != nil {
		return fmt.Errorf("invalid transaction: %w", err)
	}

	if err := s.performNodeUpdate(sqlTx, nodeID, lastSeen); err != nil {
		return err
	}

	return tx.Commit()
}

// checkNodeExists verifies if a node exists in the database.
func (*Server) checkNodeExists(tx *sql.Tx, nodeID string) (bool, error) {
	var exists bool

	err := tx.QueryRow("SELECT EXISTS(SELECT 1 FROM nodes WHERE node_id = ?)", nodeID).Scan(&exists)
	if err != nil {
		return false, fmt.Errorf("failed to check node existence: %w", err)
	}

	return exists, nil
}

// insertNewNode adds a new node to the database.
func (*Server) insertNewNode(tx *sql.Tx, nodeID string, lastSeen time.Time) error {
	_, err := tx.Exec(`
        INSERT INTO nodes (node_id, last_seen, is_healthy)
        VALUES (?, ?, FALSE)`,
		nodeID, lastSeen)
	if err != nil {
		return fmt.Errorf("failed to insert new node: %w", err)
	}

	return nil
}

// updateExistingNode updates an existing node's status.
func (*Server) updateExistingNode(tx *sql.Tx, nodeID string, lastSeen time.Time) error {
	_, err := tx.Exec(`
        UPDATE nodes 
        SET is_healthy = FALSE, 
            last_seen = ? 
        WHERE node_id = ?`,
		lastSeen, nodeID)
	if err != nil {
		return fmt.Errorf("failed to update existing node: %w", err)
	}

	return nil
}

func (s *Server) performNodeUpdate(tx *sql.Tx, nodeID string, lastSeen time.Time) error {
	exists, err := s.checkNodeExists(tx, nodeID)
	if err != nil {
		return err
	}

	if !exists {
		return s.insertNewNode(tx, nodeID, lastSeen)
	}

	return s.updateExistingNode(tx, nodeID, lastSeen)
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

// checkNeverReportedNodes checks for and alerts on nodes that exist but have never reported.
func (s *Server) checkNeverReportedNodes(ctx context.Context) error {
	conditions := make([]string, 0, len(s.pollerPatterns))
	args := make([]interface{}, 0, len(s.pollerPatterns))

	// Build LIKE conditions for each pattern
	for _, pattern := range s.pollerPatterns {
		conditions = append(conditions, "node_id LIKE ?")
		args = append(args, pattern)
	}

	// Construct query with LIKE conditions
	query := `SELECT node_id FROM nodes WHERE last_seen = ''`
	if len(conditions) > 0 {
		query += " AND (" + strings.Join(conditions, " OR ") + ")"
	}

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return fmt.Errorf("error querying unreported nodes: %w", err)
	}
	defer db.CloseRows(rows)

	var unreportedNodes []string

	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			log.Printf("Error scanning node ID: %v", err)
			continue
		}

		unreportedNodes = append(unreportedNodes, id)
	}

	// Check for any errors encountered during iteration
	if err := rows.Err(); err != nil {
		return fmt.Errorf("error iterating rows: %w", err)
	}

	if len(unreportedNodes) > 0 {
		alert := &alerts.WebhookAlert{
			Level:     alerts.Warning,
			Title:     "Pollers Never Reported",
			Message:   fmt.Sprintf("%d poller(s) have not reported since startup", len(unreportedNodes)),
			NodeID:    "cloud",
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			Details: map[string]any{
				"hostname":     getHostname(),
				"poller_ids":   unreportedNodes,
				"poller_count": len(unreportedNodes),
			},
		}

		if err := s.sendAlert(ctx, alert); err != nil {
			log.Printf("Error sending unreported nodes alert: %v", err)
			return err
		}
	}

	return nil
}

func (s *Server) checkNeverReportedPollers(ctx context.Context) {
	log.Printf("Checking for unreported nodes matching patterns: %v", s.pollerPatterns)

	// Build SQL pattern for REGEXP
	combinedPattern := strings.Join(s.pollerPatterns, "|")
	if combinedPattern == "" {
		return
	}

	var unreportedNodes []string

	rows, err := s.db.Query(`
        SELECT node_id 
        FROM nodes 
        WHERE node_id REGEXP ? AND last_seen = ''`,
		combinedPattern)
	if err != nil {
		log.Printf("Error querying unreported nodes: %v", err)
		return
	}
	defer db.CloseRows(rows)

	for rows.Next() {
		var nodeID string
		if err := rows.Scan(&nodeID); err != nil {
			log.Printf("Error scanning node ID: %v", err)
			continue
		}

		unreportedNodes = append(unreportedNodes, nodeID)
	}

	if len(unreportedNodes) > 0 {
		s.sendUnreportedNodesAlert(ctx, unreportedNodes)
	}
}

func (s *Server) sendUnreportedNodesAlert(ctx context.Context, nodeIDs []string) {
	alert := &alerts.WebhookAlert{
		Level:     alerts.Warning,
		Title:     "Pollers Never Reported",
		Message:   fmt.Sprintf("%d poller(s) have not reported since startup", len(nodeIDs)),
		NodeID:    "cloud",
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname":     getHostname(),
			"poller_ids":   nodeIDs,
			"poller_count": len(nodeIDs),
		},
	}

	if err := s.sendAlert(ctx, alert); err != nil {
		log.Printf("Error sending unreported nodes alert: %v", err)
	}
}

func (c *Config) UnmarshalJSON(data []byte) error {
	type Alias Config

	aux := &struct {
		AlertThreshold string `json:"alert_threshold"`
		*Alias
	}{
		Alias: (*Alias)(c),
	}

	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}

	// Parse the alert threshold
	if aux.AlertThreshold != "" {
		duration, err := time.ParseDuration(aux.AlertThreshold)
		if err != nil {
			return fmt.Errorf("invalid alert threshold format: %w", err)
		}

		c.AlertThreshold = duration
	}

	return nil
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

	return config, nil
}

func (s *Server) MonitorPollers(ctx context.Context) {
	ticker := time.NewTicker(monitorInterval) // Check every 30 seconds
	defer ticker.Stop()

	cleanupTicker := time.NewTicker(dailyCleanupInterval)
	defer cleanupTicker.Stop()

	// Initial checks
	if err := s.checkNodeStates(ctx); err != nil {
		log.Printf("Initial state check failed: %v", err)
	}

	if err := s.checkNeverReportedNodes(ctx); err != nil {
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
	if err := s.checkNodeStates(ctx); err != nil {
		log.Printf("Node state check failed: %v", err)
	}

	if err := s.checkNeverReportedNodes(ctx); err != nil {
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

func (s *Server) checkNodeStates(ctx context.Context) error {
	// Pre-allocate slices
	conditions := make([]string, 0, len(s.pollerPatterns))
	args := make([]interface{}, 0, len(s.pollerPatterns))

	// Build LIKE conditions for each pattern
	for _, pattern := range s.pollerPatterns {
		conditions = append(conditions, "node_id LIKE ?")
		args = append(args, pattern)
	}

	// Construct query with LIKE conditions
	query := `SELECT node_id, last_seen, is_healthy FROM nodes`
	if len(conditions) > 0 {
		query += " WHERE " + strings.Join(conditions, " OR ")
	}

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return fmt.Errorf("failed to query nodes: %w", err)
	}
	defer db.CloseRows(rows)

	threshold := time.Now().Add(-s.alertThreshold)

	for rows.Next() {
		var nodeID string

		var lastSeen time.Time

		var isHealthy bool

		if err := rows.Scan(&nodeID, &lastSeen, &isHealthy); err != nil {
			log.Printf("Error scanning node row: %v", err)

			continue
		}

		if err := s.evaluateNodeHealth(ctx, nodeID, lastSeen, isHealthy, threshold); err != nil {
			log.Printf("Error evaluating node %s health: %v", nodeID, err)
		}
	}

	return rows.Err()
}

func (s *Server) evaluateNodeHealth(ctx context.Context, nodeID string, lastSeen time.Time, isHealthy bool, threshold time.Time) error {
	log.Printf("Evaluating node health: id=%s lastSeen=%v isHealthy=%v threshold=%v",
		nodeID, lastSeen.Format(time.RFC3339), isHealthy, threshold.Format(time.RFC3339))

	// Case 1: Node was healthy but hasn't been seen recently (went down)
	if isHealthy && lastSeen.Before(threshold) {
		duration := time.Since(lastSeen).Round(time.Second)
		log.Printf("Node %s appears to be offline (last seen: %v ago)", nodeID, duration)

		return s.handleNodeDown(ctx, nodeID, lastSeen)
	}

	// Case 2: Node is healthy and reporting within threshold
	if isHealthy && !lastSeen.Before(threshold) {
		return nil
	}

	// Case 3: Node is unhealthy (service failures) but still reporting
	if !isHealthy && !lastSeen.Before(threshold) {
		if err := s.checkServiceStatus(ctx, nodeID, lastSeen); err != nil {
			log.Printf("Error checking service status: %v", err)
		}

		return s.handlePotentialRecovery(ctx, nodeID, lastSeen) // Corrected call
	}

	return nil
}

// checkServiceStatus handles service status alerts with proper cooldown.
func (s *Server) checkServiceStatus(ctx context.Context, nodeID string, lastSeen time.Time) error {
	currentServices, err := s.db.GetNodeServices(nodeID)
	if err != nil {
		return fmt.Errorf("failed to get current services: %w", err)
	}

	previousServices, err := s.db.GetServiceHistory(nodeID, "", 1)
	if err != nil {
		log.Printf("Error getting previous service states: %v", err)
		//  treat an error getting history as if there's no history.
		previousServices = []db.ServiceStatus{}
	}

	changedService := s.findChangedService(currentServices, previousServices)

	if changedService != "" && s.shouldSendServiceAlert(currentServices) {
		if err := s.sendServiceFailureAlert(ctx, nodeID, lastSeen, currentServices, changedService); err != nil {
			// already logged inside sendServiceFailureAlert
			return err
		}
	}

	return nil
}

// findChangedService finds the first service that changed state from available to unavailable.
func (*Server) findChangedService(current, previous []db.ServiceStatus) string {
	previousStates := make(map[string]bool)
	for _, svc := range previous {
		previousStates[svc.ServiceName] = svc.Available
	}

	for _, svc := range current {
		if prevAvailable, ok := previousStates[svc.ServiceName]; ok {
			if prevAvailable && !svc.Available { // Changed from available to unavailable
				return svc.ServiceName
			}
		} else if !svc.Available { // New and unavailable service
			return svc.ServiceName
		}
	}

	return "" // No changed service found
}

// shouldSendServiceAlert determines if a service alert should be sent.
func (*Server) shouldSendServiceAlert(currentServices []db.ServiceStatus) bool {
	total := len(currentServices)
	available := 0

	for _, svc := range currentServices {
		if svc.Available {
			available++
		}
	}

	// Only send if state changed and SOME services are down.
	return available < total && available > 0
}

// sendServiceFailureAlert constructs and sends the service failure alert.
func (s *Server) sendServiceFailureAlert(
	ctx context.Context,
	nodeID string,
	lastSeen time.Time,
	currentServices []db.ServiceStatus,
	changedServiceName string) error {
	total := len(currentServices)
	available := 0

	for _, svc := range currentServices {
		if svc.Available {
			available++
		}
	}

	alert := &alerts.WebhookAlert{
		Level:       alerts.Warning,
		Title:       "Service Failure",
		Message:     fmt.Sprintf("Node '%s' has %d/%d services available", nodeID, available, total),
		NodeID:      nodeID,
		ServiceName: changedServiceName, // Set the service name here
		Timestamp:   time.Now().UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname":           getHostname(),
			"available_services": available,
			"total_services":     total,
			"last_seen":          lastSeen.Format(time.RFC3339),
		},
	}

	if err := s.sendAlert(ctx, alert); err != nil && !errors.Is(err, alerts.ErrWebhookCooldown) {
		log.Printf("Failed to send service failure alert: %v", err)

		return fmt.Errorf("failed to send service failure alert: %w", err) // now we return this
	}

	return nil
}

func (s *Server) handlePotentialRecovery(ctx context.Context, nodeID string, lastSeen time.Time) error {
	// Get the most up-to-date node status from the database
	status, err := s.db.GetNodeStatus(nodeID)
	if err != nil {
		return fmt.Errorf("failed to get node status: %w", err)
	}

	apiStatus := &api.NodeStatus{
		NodeID:     nodeID,
		IsHealthy:  status.IsHealthy, // Use the *actual* health status
		LastUpdate: lastSeen,
		Services:   make([]api.ServiceStatus, 0),
	}

	s.handleNodeRecovery(ctx, nodeID, apiStatus, lastSeen)

	return nil
}

func (s *Server) handleNodeDown(ctx context.Context, nodeID string, lastSeen time.Time) error {
	if err := s.updateNodeStatus(nodeID, false, lastSeen); err != nil {
		return fmt.Errorf("failed to update node status: %w", err)
	}

	// Send alert
	alert := &alerts.WebhookAlert{
		Level:     alerts.Error,
		Title:     "Node Offline",
		Message:   fmt.Sprintf("Node '%s' is offline", nodeID),
		NodeID:    nodeID,
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
		s.apiServer.UpdateNodeStatus(nodeID, &api.NodeStatus{
			NodeID:     nodeID,
			IsHealthy:  false,
			LastUpdate: lastSeen,
		})
	}

	return nil
}
func (s *Server) updateNodeStatus(nodeID string, isHealthy bool, timestamp time.Time) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer func(tx db.Transaction) {
		err = tx.Rollback()
		if err != nil {
			log.Printf("Error rolling back transaction: %v", err)
		}
	}(tx)

	sqlTx, err := db.ToTx(tx)
	if err != nil {
		return fmt.Errorf("invalid transaction: %w", err)
	}

	// Update node status
	if err := s.updateNodeInTx(sqlTx, nodeID, isHealthy, timestamp); err != nil {
		return err
	}

	// Add history entry
	if _, err := tx.Exec(`
        INSERT INTO node_history (node_id, timestamp, is_healthy)
        VALUES (?, ?, ?)
    `, nodeID, timestamp, isHealthy); err != nil {
		return fmt.Errorf("failed to insert history: %w", err)
	}

	return tx.Commit()
}

func (*Server) updateNodeInTx(tx *sql.Tx, nodeID string, isHealthy bool, timestamp time.Time) error {
	// Check if node exists
	var exists bool
	if err := tx.QueryRow("SELECT EXISTS(SELECT 1 FROM nodes WHERE node_id = ?)", nodeID).Scan(&exists); err != nil {
		return fmt.Errorf("failed to check node existence: %w", err)
	}

	if exists {
		_, err := tx.Exec(`
            UPDATE nodes 
            SET is_healthy = ?,
                last_seen = ?
            WHERE node_id = ?
        `, isHealthy, timestamp, nodeID)

		return err
	}

	// Insert new node
	_, err := tx.Exec(`
        INSERT INTO nodes (node_id, first_seen, last_seen, is_healthy)
        VALUES (?, ?, ?, ?)
    `, nodeID, timestamp, timestamp, isHealthy)

	return err
}

func (s *Server) handleNodeRecovery(ctx context.Context, nodeID string, apiStatus *api.NodeStatus, timestamp time.Time) {
	lastDownTime := s.getLastDowntime(nodeID)
	downtime := downtimeValue

	if !lastDownTime.IsZero() {
		downtime = timestamp.Sub(lastDownTime).String()
	}

	alert := &alerts.WebhookAlert{
		Level:       alerts.Info,
		Title:       "Node Recovered",
		Message:     fmt.Sprintf("Node '%s' is back online", nodeID),
		NodeID:      nodeID,
		Timestamp:   timestamp.UTC().Format(time.RFC3339),
		ServiceName: "", // Ensure ServiceName is empty for node-level alerts
		Details: map[string]any{
			"hostname":      getHostname(),
			"downtime":      downtime,
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

// ReportStatus implements the PollerServiceServer interface. It processes status reports from pollers.
func (s *Server) ReportStatus(ctx context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
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

func (s *Server) getLastDowntime(nodeID string) time.Time {
	var downtime time.Time
	err := s.db.QueryRow(`
        SELECT timestamp
        FROM node_history
        WHERE node_id = ? AND is_healthy = FALSE
        ORDER BY timestamp DESC
        LIMIT 1
    `, nodeID).Scan(&downtime)

	if err != nil {
		log.Printf("Error getting last downtime for node %s: %v", nodeID, err)
		return time.Time{} // Return zero time if error
	}

	return downtime
}

func getHostname() string {
	hostname, err := os.Hostname()
	if err != nil {
		return statusUnknown
	}

	return hostname
}
