package cloud

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/mfreeman451/homemon/pkg/cloud/alerts"
	"github.com/mfreeman451/homemon/pkg/cloud/api"
	"github.com/mfreeman451/homemon/pkg/grpc"
	"github.com/mfreeman451/homemon/proto"
)

const (
	stateFilePerm            = 0600
	shutdownTimeout          = 10 * time.Second
	homemonDirPerms          = 0700
	nodeDiscoveryTimeout     = 30 * time.Second
	nodeNeverReportedTimeout = 30 * time.Second
	pollerTimeout            = 30 * time.Second

	KB             = 1024
	MB             = 1024 * KB
	maxMessageSize = 4 * MB

	defaultStateFile = "/var/lib/homemon/cloud-state.json"
)

var (
	ErrEmptyPollerID = fmt.Errorf("received empty poller ID")
)

type Config struct {
	ListenAddr     string                 `json:"listen_addr"`
	AlertThreshold time.Duration          `json:"alert_threshold"`
	Webhooks       []alerts.WebhookConfig `json:"webhooks,omitempty"`
	KnownPollers   []string               `json:"known_pollers,omitempty"`
}

type alertState struct {
	isDown    bool
	timestamp time.Time
}

type PersistedState struct {
	LastSeen        map[string]time.Time   `json:"last_seen"`
	NodeAlertStates map[string]*alertState `json:"node_alert_states"`
	ServiceStates   map[string]*alertState `json:"service_states"`
	LastUpdate      time.Time              `json:"last_update"`
}

type Server struct {
	proto.UnimplementedPollerServiceServer
	mu                 sync.RWMutex
	lastSeen           map[string]time.Time
	alertThreshold     time.Duration
	webhooks           []*alerts.WebhookAlerter
	apiServer          *api.APIServer
	nodeAlertStates    map[string]*alertState
	serviceAlertStates map[string]*alertState
	shutdown           chan struct{}
	stateFile          string
	knownPollers       []string
}

func (s *Server) saveState() error {
	s.mu.RLock()
	defer s.mu.RUnlock()

	state := PersistedState{
		LastSeen:        s.lastSeen,
		NodeAlertStates: s.nodeAlertStates,
		ServiceStates:   s.serviceAlertStates,
		LastUpdate:      time.Now(),
	}

	data, err := json.Marshal(state)
	if err != nil {
		return fmt.Errorf("error marshaling state: %w", err)
	}

	if err := os.WriteFile(s.stateFile, data, stateFilePerm); err != nil {
		return fmt.Errorf("error writing state file: %w", err)
	}

	return nil
}

func (s *Server) loadState(ctx context.Context) error {
	data, err := os.ReadFile(s.stateFile)
	if err != nil {
		if os.IsNotExist(err) {
			log.Printf("No state file found, starting fresh")
			return nil
		}

		return fmt.Errorf("error reading state file: %w", err)
	}

	var state PersistedState
	if err := json.Unmarshal(data, &state); err != nil {
		return fmt.Errorf("error unmarshaling state: %w", err)
	}

	s.mu.Lock()
	s.lastSeen = state.LastSeen
	s.nodeAlertStates = state.NodeAlertStates
	s.serviceAlertStates = state.ServiceStates
	s.mu.Unlock()

	// Check for stale nodes during startup
	for nodeID, lastSeen := range state.LastSeen {
		if time.Since(lastSeen) > s.alertThreshold {
			alert := alerts.WebhookAlert{
				Level: alerts.Warning,
				Title: "Node Still Offline",
				Message: fmt.Sprintf("Node %s has not reported since %s (before restart)",
					nodeID, lastSeen.Format(time.RFC3339)),
				NodeID: nodeID,
				Details: map[string]any{
					"hostname":        getHostname(),
					"last_seen":       lastSeen.Format(time.RFC3339),
					"duration":        time.Since(lastSeen).String(),
					"cloud_restarted": true,
				},
			}
			s.sendAlert(ctx, &alert)
		}
	}

	log.Printf("Loaded state with %d nodes, %d node alerts, %d service alerts",
		len(state.LastSeen), len(state.NodeAlertStates), len(state.ServiceStates))

	return nil
}

func (s *Server) Shutdown(ctx context.Context) {
	// set a ctx with a timeout to allow for graceful shutdown
	ctx, cancel := context.WithTimeout(ctx, shutdownTimeout)
	defer cancel()

	if err := s.saveState(); err != nil {
		log.Printf("Error saving state during shutdown: %v", err)
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

	close(s.shutdown)
}

func (s *Server) SetAPIServer(a *api.APIServer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.apiServer = a
}

func (s *Server) checkInitialStates(ctx context.Context) {
	log.Printf("Checking initial states of all nodes")

	// Use a map to track which nodes we've checked to avoid duplicates
	checkedNodes := make(map[string]bool)

	s.mu.RLock()
	for pollerID, lastSeen := range s.lastSeen {
		checkedNodes[pollerID] = true

		duration := time.Since(lastSeen)
		if duration > s.alertThreshold {
			log.Printf("Node %s found offline during initial check (last seen: %v ago)",
				pollerID, duration.Round(time.Second))

			// Only send alert if not already tracked as down
			if _, exists := s.nodeAlertStates[pollerID]; !exists {
				s.mu.RUnlock()
				s.markNodeDown(ctx, pollerID, time.Now())
				s.mu.RLock()
			}
		}
	}
	s.mu.RUnlock()

	// Check for known pollers that have never reported
	for _, pollerID := range s.knownPollers {
		if !checkedNodes[pollerID] {
			if _, exists := s.nodeAlertStates[pollerID]; !exists {
				log.Printf("Known poller %s has never reported", pollerID)
				s.markNodeDown(ctx, pollerID, time.Now())
			}
		}
	}
}

func NewServer(ctx context.Context, config Config) (*Server, error) {
	server := &Server{
		lastSeen:           make(map[string]time.Time),
		alertThreshold:     config.AlertThreshold,
		webhooks:           make([]*alerts.WebhookAlerter, 0),
		nodeAlertStates:    make(map[string]*alertState),
		serviceAlertStates: make(map[string]*alertState),
		shutdown:           make(chan struct{}),
		stateFile:          defaultStateFile,
		knownPollers:       config.KnownPollers,
	}

	// TODO: this should be done with a context..
	server.initializeGRPCServer()

	if err := server.initializeStorage(); err != nil {
		return nil, fmt.Errorf("failed to initialize storage: %w", err)
	}

	server.initializeWebhooks(config.Webhooks)

	server.startBackgroundTasks(ctx)

	return server, nil
}

func (s *Server) initializeGRPCServer() {
	grpcServer := grpc.NewServer(":50052",
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

func (s *Server) initializeStorage() error {
	if err := os.MkdirAll("/var/lib/homemon", homemonDirPerms); err != nil {
		return fmt.Errorf("error creating state directory: %w", err)
	}

	if err := s.loadState(context.Background()); err != nil {
		log.Printf("Warning: Failed to load state: %v", err)
	}

	return nil
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
	// Start state saving goroutine
	go s.stateSavingTask()

	// Send startup notification
	if len(s.webhooks) > 0 {
		s.sendStartupNotification(ctx)
	}

	// Start node monitoring tasks
	go s.startNodeMonitoring(ctx)
}

func (s *Server) stateSavingTask() {
	ticker := time.NewTicker(1 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-s.shutdown:
			return
		case <-ticker.C:
			if err := s.saveState(); err != nil {
				log.Printf("Error saving state: %v", err)
			}
		}
	}
}

func (s *Server) startNodeMonitoring(ctx context.Context) {
	// Check initial states after a delay
	time.Sleep(nodeDiscoveryTimeout)
	s.checkInitialStates(ctx)

	// Check never-reported pollers
	time.Sleep(nodeNeverReportedTimeout)
	s.checkNeverReportedPollers(ctx, Config{KnownPollers: s.knownPollers})
}

func (s *Server) sendStartupNotification(ctx context.Context) {
	log.Printf("Sending startup notification to %d webhooks", len(s.webhooks))
	alert := alerts.WebhookAlert{
		Level:     alerts.Info,
		Title:     "Cloud Service Started",
		Message:   fmt.Sprintf("HomeMon cloud service initialized at %s", time.Now().Format(time.RFC3339)),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		NodeID:    "cloud",
		Details: map[string]any{
			"version":  "1.0.0",
			"hostname": getHostname(),
			"pid":      os.Getpid(),
		},
	}
	s.sendAlert(ctx, &alert)
}

func (s *Server) checkNeverReportedPollers(ctx context.Context, config Config) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// If your config is stored somewhere accessible, or you store it on the server.
	// For example, maybe you have s.knownPollers from the config:
	s.knownPollers = config.KnownPollers

	// We only want to alert if they're *truly* never reported
	// i.e. not in s.lastSeen at all:
	for _, pollerID := range s.knownPollers {
		_, exists := s.lastSeen[pollerID]
		if !exists {
			// Trigger an immediate alert that poller never checked in
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

			// Optionally keep track of it in nodeAlertStates:
			s.nodeAlertStates[pollerID] = &alertState{
				isDown:    true,
				timestamp: time.Now(),
			}
		}
	}
}

func (s *Server) ReportStatus(ctx context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	pollerID := req.PollerId
	if pollerID == "" {
		return &proto.PollerStatusResponse{Received: false},
			ErrEmptyPollerID
	}

	now := time.Unix(req.Timestamp, 0)
	isHealthy := true

	// Build node status for API
	nodeStatus := &api.NodeStatus{
		NodeID:     pollerID,
		LastUpdate: now,
		Services:   make([]api.ServiceStatus, 0, len(req.Services)),
	}

	// Process services
	for _, svc := range req.Services {
		svcStatus := api.ServiceStatus{
			Name:      svc.ServiceName,
			Available: svc.Available,
			Message:   svc.Message,
			Type:      svc.Type,
		}

		// Try to parse service details if present
		if svc.Message != "" {
			var raw json.RawMessage
			if err := json.Unmarshal([]byte(svc.Message), &raw); err == nil {
				svcStatus.Details = raw
			}
		}

		nodeStatus.Services = append(nodeStatus.Services, svcStatus)

		if !svc.Available {
			isHealthy = false
		}
	}

	nodeStatus.IsHealthy = isHealthy

	// Handle recovery if node was previously down
	if state, exists := s.nodeAlertStates[pollerID]; exists && state.isDown {
		downtime := time.Since(state.timestamp).Round(time.Second)
		alert := alerts.WebhookAlert{
			Level:     alerts.Info,
			Title:     "Node Recovery",
			Message:   fmt.Sprintf("Node '%s' is back online after %v", pollerID, downtime),
			NodeID:    pollerID,
			Timestamp: now.UTC().Format(time.RFC3339),
			Details: map[string]any{
				"hostname":     getHostname(),
				"downtime":     downtime.String(),
				"recovered_at": now.Format(time.RFC3339),
			},
		}

		log.Printf("Sending recovery alert for node '%s'", pollerID)
		s.sendAlert(ctx, &alert)
		delete(s.nodeAlertStates, pollerID)
	}

	// Update last seen time
	s.lastSeen[pollerID] = now

	// Update API state
	if s.apiServer != nil {
		log.Printf("Updating API state for node %s: healthy=%v, services=%d",
			pollerID, nodeStatus.IsHealthy, len(nodeStatus.Services))
		s.apiServer.UpdateNodeStatus(pollerID, nodeStatus)
	}

	return &proto.PollerStatusResponse{Received: true}, nil
}

func (s *Server) markNodeDown(ctx context.Context, pollerID string, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Check if already marked down
	if state, exists := s.nodeAlertStates[pollerID]; exists && state.isDown {
		return
	}

	s.nodeAlertStates[pollerID] = &alertState{
		isDown:    true,
		timestamp: now,
	}

	alert := alerts.WebhookAlert{
		Level:     alerts.Error,
		Title:     "Node Offline",
		Message:   fmt.Sprintf("Node '%s' is offline", pollerID),
		NodeID:    pollerID,
		Timestamp: now.UTC().Format(time.RFC3339),
		Details: map[string]any{
			"hostname":  getHostname(),
			"last_seen": s.lastSeen[pollerID].Format(time.RFC3339),
			"duration":  time.Since(s.lastSeen[pollerID]).Round(time.Second).String(),
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
		}
	}
}

func (s *Server) checkPollers(ctx context.Context) {
	now := time.Now()

	s.mu.Lock()
	defer s.mu.Unlock()

	log.Printf("Checking poller states. Current states: %+v", s.nodeAlertStates)

	for pollerID, lastSeen := range s.lastSeen {
		duration := now.Sub(lastSeen)
		log.Printf("Poller %s last seen %v ago (threshold: %v)", pollerID, duration, s.alertThreshold)

		if duration > s.alertThreshold {
			if state, exists := s.nodeAlertStates[pollerID]; !exists || !state.isDown {
				log.Printf("Node %s transitioning to DOWN state", pollerID)

				alert := alerts.WebhookAlert{
					Level:   alerts.Error,
					Title:   "Node Offline",
					Message: fmt.Sprintf("Node %s has not reported in %v", pollerID, duration.Round(time.Second)),
					NodeID:  pollerID,
					Details: map[string]any{
						"hostname":  getHostname(),
						"last_seen": lastSeen.Format(time.RFC3339),
						"duration":  duration.String(),
					},
				}

				s.sendAlert(ctx, &alert)

				s.nodeAlertStates[pollerID] = &alertState{
					isDown:    true,
					timestamp: now,
				}

				// Build a NodeStatus with IsHealthy=false
				offlineStatus := &api.NodeStatus{
					NodeID:     pollerID,
					IsHealthy:  false,
					LastUpdate: now,
					Services:   nil, // or empty slice
				}

				if s.apiServer != nil {
					s.apiServer.UpdateNodeStatus(pollerID, offlineStatus)
				}
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
