package cloud

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/mfreeman451/homemon/pkg/cloud/alerts"
	"github.com/mfreeman451/homemon/pkg/cloud/api"
	"github.com/mfreeman451/homemon/pkg/db"
	"github.com/mfreeman451/homemon/pkg/grpc"
	"github.com/mfreeman451/homemon/proto"
)

const (
	shutdownTimeout          = 10 * time.Second
	oneDay                   = 24 * time.Hour
	oneWeek                  = 7 * oneDay
	homemonDirPerms          = 0700
	nodeHistoryLimit         = 1000
	nodeDiscoveryTimeout     = 30 * time.Second
	nodeNeverReportedTimeout = 30 * time.Second
	pollerTimeout            = 30 * time.Second
	defaultDBPath            = "/var/lib/homemon/homemon.db"
	KB                       = 1024
	MB                       = 1024 * KB
	maxMessageSize           = 4 * MB
)

var (
	errEmptyPollerID = errors.New("empty poller ID")
)

type Config struct {
	ListenAddr     string                 `json:"listen_addr"`
	GrpcAddr       string                 `json:"grpc_addr"`
	DBPath         string                 `json:"db_path"`
	AlertThreshold time.Duration          `json:"alert_threshold"`
	Webhooks       []alerts.WebhookConfig `json:"webhooks,omitempty"`
	KnownPollers   []string               `json:"known_pollers,omitempty"`
}

type Server struct {
	proto.UnimplementedPollerServiceServer
	mu             sync.RWMutex
	db             *db.DB
	alertThreshold time.Duration
	webhooks       []*alerts.WebhookAlerter
	apiServer      *api.APIServer
	ShutdownChan   chan struct{}
	knownPollers   []string
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
			Message:   fmt.Sprintf("HomeMon cloud service shutting down at %s", time.Now().Format(time.RFC3339)),
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			NodeID:    "cloud",
			Details: map[string]any{
				"hostname": getHostname(),
				"pid":      os.Getpid(),
			},
		}
		s.sendAlert(ctx, &alert)
	}

	close(s.ShutdownChan)
}

func (s *Server) SetAPIServer(apiServer *api.APIServer) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.apiServer = apiServer

	// Set up the history handler
	apiServer.SetNodeHistoryHandler(func(nodeID string) ([]api.NodeHistoryPoint, error) {
		points, err := s.db.GetNodeHistoryPoints(nodeID, nodeHistoryLimit)
		if err != nil {
			return nil, fmt.Errorf("failed to get node history: %w", err)
		}

		// Convert db.NodeHistoryPoint to api.NodeHistoryPoint
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

	// Query all nodes from database
	const querySQL = `
        SELECT node_id, is_healthy, last_seen 
        FROM nodes 
        ORDER BY last_seen DESC
    `

	rows, err := s.db.Query(querySQL) //nolint:rowserrcheck // rows.Close() is deferred
	if err != nil {
		log.Printf("Error querying nodes: %v", err)
		return
	}

	defer func(rows *sql.Rows) {
		err := rows.Close()
		if err != nil {
			log.Printf("Error closing rows: %v", err)
		}
	}(rows)

	checkedNodes := make(map[string]bool)

	for rows.Next() {
		var nodeID string

		var isHealthy bool

		var lastSeen time.Time

		if err := rows.Scan(&nodeID, &isHealthy, &lastSeen); err != nil {
			log.Printf("Error scanning node row: %v", err)
			continue
		}

		checkedNodes[nodeID] = true
		duration := time.Since(lastSeen)

		if duration > s.alertThreshold {
			log.Printf("Node %s found offline during initial check (last seen: %v ago)",
				nodeID, duration.Round(time.Second))

			s.markNodeDown(ctx, nodeID, time.Now())
		}
	}

	// Check for known pollers that have never reported
	for _, pollerID := range s.knownPollers {
		if !checkedNodes[pollerID] {
			s.markNodeDown(ctx, pollerID, time.Now())
		}
	}
}

func NewServer(ctx context.Context, config *Config) (*Server, error) {
	// Use default DB path if not specified
	dbPath := config.DBPath
	if dbPath == "" {
		dbPath = defaultDBPath
	}

	// Ensure the directory exists
	if err := os.MkdirAll("/var/lib/homemon", homemonDirPerms); err != nil {
		return nil, fmt.Errorf("failed to create data directory: %w", err)
	}

	// Initialize database
	database, err := db.New(dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize database: %w", err)
	}

	server := &Server{
		db:             database,
		alertThreshold: config.AlertThreshold,
		webhooks:       make([]*alerts.WebhookAlerter, 0),
		ShutdownChan:   make(chan struct{}),
		knownPollers:   config.KnownPollers,
	}

	server.initializeGRPCServer(config)
	server.initializeWebhooks(config.Webhooks)
	server.startBackgroundTasks(ctx)

	return server, nil
}

// ReportStatus handles incoming status reports from pollers.
func (s *Server) ReportStatus(_ context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
	if req.PollerId == "" {
		return nil, errEmptyPollerID
	}

	now := time.Unix(req.Timestamp, 0)
	log.Printf("Processing status report from %s at %s", req.PollerId, now.Format(time.RFC3339))

	// Build API node status while processing
	apiStatus := &api.NodeStatus{
		NodeID:     req.PollerId,
		LastUpdate: now,
		IsHealthy:  true,
		Services:   make([]api.ServiceStatus, 0, len(req.Services)),
	}

	// Process services
	for _, svc := range req.Services {
		log.Printf("Service report: node=%s name=%s type=%s available=%v",
			req.PollerId, svc.ServiceName, svc.ServiceType, svc.Available)

		if !svc.Available {
			apiStatus.IsHealthy = false
		}

		// Store in database
		svcStatus := &db.ServiceStatus{
			NodeID:      req.PollerId,
			ServiceName: svc.ServiceName,
			ServiceType: svc.ServiceType,
			Available:   svc.Available,
			Details:     svc.Message,
			Timestamp:   now,
		}

		if err := s.db.UpdateServiceStatus(svcStatus); err != nil {
			log.Printf("Error storing service status: %v", err)
		}

		// Add to API status
		apiService := api.ServiceStatus{
			Name:      svc.ServiceName,
			Available: svc.Available,
			Message:   svc.Message,
			Type:      svc.ServiceType,
		}

		// Parse detailed status if available
		if svc.Message != "" {
			var raw json.RawMessage
			if err := json.Unmarshal([]byte(svc.Message), &raw); err == nil {
				apiService.Details = raw
			}
		}

		apiStatus.Services = append(apiStatus.Services, apiService)
	}

	// Store node status in database
	nodeStatus := &db.NodeStatus{
		NodeID:    req.PollerId,
		IsHealthy: apiStatus.IsHealthy,
		LastSeen:  now,
	}

	if err := s.db.UpdateNodeStatus(nodeStatus); err != nil {
		log.Printf("Error storing node status: %v", err)
		return nil, fmt.Errorf("failed to store node status: %w", err)
	}

	// Verify storage
	storedNode, err := s.db.GetNodeStatus(nodeStatus.NodeID)
	if err != nil {
		log.Printf("Error reading back node status: %v", err)
	} else {
		log.Printf("Verified node storage: id=%s healthy=%v last_seen=%v",
			storedNode.NodeID, storedNode.IsHealthy, storedNode.LastSeen)
	}

	// Update API server state
	if s.apiServer != nil {
		s.apiServer.UpdateNodeStatus(req.PollerId, apiStatus)
		log.Printf("Updated API server state for node: %s", req.PollerId)
	} else {
		log.Printf("Warning: API server not initialized, state not updated")
	}

	return &proto.PollerStatusResponse{Received: true}, nil
}

func (s *Server) initializeGRPCServer(config *Config) {
	grpcServer := grpc.NewServer(config.GrpcAddr,
		grpc.WithMaxRecvSize(maxMessageSize),
		grpc.WithMaxSendSize(maxMessageSize),
	)

	proto.RegisterPollerServiceServer(grpcServer, s)

	go func() {
		if err := grpcServer.Start(); err != nil {
			log.Printf("gRPC server failed: %v", err)
		}
	}()
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

func (s *Server) startBackgroundTasks(ctx context.Context) {
	// Start periodic database cleanup
	go s.periodicCleanup(ctx)

	// Send startup notification
	if len(s.webhooks) > 0 {
		s.sendStartupNotification(ctx)
	}

	// Start node monitoring tasks
	go s.startNodeMonitoring(ctx)
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

func (s *Server) startNodeMonitoring(ctx context.Context) {
	// Initial delay to allow nodes to report in
	time.Sleep(nodeDiscoveryTimeout)

	// Check initial states from database
	s.checkInitialStates(ctx)

	// Check never-reported pollers
	time.Sleep(nodeNeverReportedTimeout)
	s.checkNeverReportedPollers(ctx, &Config{KnownPollers: s.knownPollers})

	// Start continuous monitoring
	go s.MonitorPollers(ctx)
}

func (s *Server) sendStartupNotification(ctx context.Context) {
	log.Printf("Sending startup notification to %d webhooks", len(s.webhooks))

	// Get total nodes from database
	var nodeCount int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM nodes").Scan(&nodeCount); err != nil {
		log.Printf("Error counting nodes: %v", err)
	}

	alert := alerts.WebhookAlert{
		Level:     alerts.Info,
		Title:     "Cloud Service Started",
		Message:   fmt.Sprintf("HomeMon cloud service initialized at %s", time.Now().Format(time.RFC3339)),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		NodeID:    "cloud",
		Details: map[string]any{
			"version":     "1.0.0",
			"hostname":    getHostname(),
			"pid":         os.Getpid(),
			"total_nodes": nodeCount,
		},
	}
	s.sendAlert(ctx, &alert)
}

func (s *Server) checkNeverReportedPollers(ctx context.Context, config *Config) {
	const querySQL = `
        SELECT node_id 
        FROM nodes 
        WHERE node_id = ?
    `

	for _, pollerID := range config.KnownPollers {
		var exists string

		err := s.db.QueryRow(querySQL, pollerID).Scan(&exists)
		if errors.Is(err, sql.ErrNoRows) {
			alert := alerts.WebhookAlert{
				Level:   alerts.Error,
				Title:   fmt.Sprintf("Poller Never Reported: %s", pollerID),
				Message: fmt.Sprintf("Expected poller %s has not reported after startup.", pollerID),
				NodeID:  pollerID,
				Details: map[string]any{
					"hostname": getHostname(),
				},
			}

			log.Printf("Sending 'never-reported' alert for poller %s", pollerID)
			s.sendAlert(ctx, &alert)
		}
	}
}

func (s *Server) markNodeDown(ctx context.Context, pollerID string, now time.Time) {
	// Update node status in database
	status := &db.NodeStatus{
		NodeID:    pollerID,
		IsHealthy: false,
		LastSeen:  now,
	}

	if err := s.db.UpdateNodeStatus(status); err != nil {
		log.Printf("Error updating node down status: %v", err)
	}

	// Query last known good status
	const querySQL = `
        SELECT last_seen 
        FROM node_history 
        WHERE node_id = ? AND is_healthy = TRUE 
        ORDER BY timestamp DESC 
        LIMIT 1
    `

	var lastSeen time.Time
	if err := s.db.QueryRow(querySQL, pollerID).Scan(&lastSeen); err != nil && !errors.Is(err, sql.ErrNoRows) {
		log.Printf("Error querying last seen time: %v", err)
	}

	alert := alerts.WebhookAlert{
		Level:     alerts.Error,
		Title:     "Node Offline",
		Message:   fmt.Sprintf("Node '%s' is offline", pollerID),
		NodeID:    pollerID,
		Timestamp: now.UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname":  getHostname(),
			"last_seen": lastSeen.Format(time.RFC3339),
			"duration":  time.Since(lastSeen).Round(time.Second).String(),
		},
	}

	log.Printf("Sending offline alert for node '%s'", pollerID)
	s.sendAlert(ctx, &alert)
}

func (s *Server) sendAlert(ctx context.Context, alert *alerts.WebhookAlert) {
	for _, webhook := range s.webhooks {
		if err := webhook.Alert(ctx, alert); err != nil {
			log.Printf("Error sending webhook alert: %v", err)
		}
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
	ticker := time.NewTicker(pollerTimeout)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.checkPollers(ctx)
		case <-time.After(oneDay):
			// Daily cleanup of old data
			if err := s.db.CleanOldData(oneWeek); err != nil {
				log.Printf("Error cleaning old data: %v", err)
			}
		}
	}
}

func (s *Server) checkPollers(ctx context.Context) {
	now := time.Now()
	alertThreshold := now.Add(-s.alertThreshold)

	const querySQL = `
        SELECT n.node_id, n.last_seen, n.is_healthy
        FROM nodes n
        WHERE n.last_seen < ?
        AND n.is_healthy = TRUE
    `

	rows, err := s.db.Query(querySQL, alertThreshold) //nolint:rowserrcheck // rows.Close() is deferred
	if err != nil {
		log.Printf("Error querying nodes for status check: %v", err)
		return
	}
	defer func(rows *sql.Rows) {
		err := rows.Close()
		if err != nil {
			log.Printf("Error closing rows: %v", err)
		}
	}(rows)

	for rows.Next() {
		var nodeID string

		var lastSeen time.Time

		var isHealthy bool

		if err := rows.Scan(&nodeID, &lastSeen, &isHealthy); err != nil {
			log.Printf("Error scanning node status: %v", err)
			continue
		}

		duration := now.Sub(lastSeen)
		log.Printf("Node %s last seen %v ago (threshold: %v)",
			nodeID, duration, s.alertThreshold)

		// If the node was healthy but hasn't been seen recently, mark it down
		if isHealthy && duration > s.alertThreshold {
			log.Printf("Node %s transitioning to DOWN state", nodeID)
			s.markNodeDown(ctx, nodeID, now)

			// Update API state if available
			if s.apiServer != nil {
				offlineStatus := &api.NodeStatus{
					NodeID:     nodeID,
					IsHealthy:  false,
					LastUpdate: now,
				}
				s.apiServer.UpdateNodeStatus(nodeID, offlineStatus)
			}
		}
	}
}

func getHostname() string {
	hostname, err := os.Hostname()
	if err != nil {
		return "unknown"
	}

	return hostname
}
