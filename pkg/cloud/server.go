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
	"github.com/mfreeman451/homemon/proto"
)

type Config struct {
	ListenAddr     string                 `json:"listen_addr"`
	AlertThreshold time.Duration          `json:"alert_threshold"`
	Webhooks       []alerts.WebhookConfig `json:"webhooks,omitempty"`
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

	if err := os.WriteFile(s.stateFile, data, 0644); err != nil {
		return fmt.Errorf("error writing state file: %w", err)
	}

	return nil
}

func (s *Server) loadState() error {
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
			s.sendAlert(alert)
		}
	}

	log.Printf("Loaded state with %d nodes, %d node alerts, %d service alerts",
		len(state.LastSeen), len(state.NodeAlertStates), len(state.ServiceStates))
	return nil
}

func (s *Server) Shutdown() {
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
		s.sendAlert(alert)
	}
	close(s.shutdown)
}

func (s *Server) SetAPIServer(api *api.APIServer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.apiServer = api
}

// pkg/cloud/server.go

func (s *Server) checkInitialStates() {
	log.Printf("Checking initial states of all nodes")
	s.mu.RLock()
	for pollerID, lastSeen := range s.lastSeen {
		duration := time.Since(lastSeen)
		if duration > s.alertThreshold {
			log.Printf("Node %s found offline during initial check (last seen: %v ago)", pollerID, duration)
			alert := alerts.WebhookAlert{
				Level:   alerts.Error,
				Title:   "Node Offline",
				Message: fmt.Sprintf("Node %s was found offline during startup (last seen: %v ago)", pollerID, duration.Round(time.Second)),
				NodeID:  pollerID,
				Details: map[string]any{
					"hostname":  getHostname(),
					"last_seen": lastSeen.Format(time.RFC3339),
					"duration":  duration.String(),
					"type":      "initial_check",
				},
			}
			s.nodeAlertStates[pollerID] = &alertState{
				isDown:    true,
				timestamp: time.Now(),
			}
			s.sendAlert(alert)
		}
	}
	s.mu.RUnlock()
}

func NewServer(config Config) (*Server, error) {
	log.Printf("Initializing cloud server with config: %+v", config)

	server := &Server{
		lastSeen:           make(map[string]time.Time),
		alertThreshold:     config.AlertThreshold,
		webhooks:           make([]*alerts.WebhookAlerter, 0),
		nodeAlertStates:    make(map[string]*alertState),
		serviceAlertStates: make(map[string]*alertState),
		shutdown:           make(chan struct{}),
		stateFile:          "/var/lib/homemon/cloud-state.json", // TODO: add to config to make configurable
	}

	// Ensure directory exists
	if err := os.MkdirAll("/var/lib/homemon", 0755); err != nil {
		return nil, fmt.Errorf("error creating state directory: %w", err)
	}

	// Load existing state
	if err := server.loadState(); err != nil {
		log.Printf("Warning: Failed to load state: %v", err)
	}

	// Initialize webhook alerters
	for i, whConfig := range config.Webhooks {
		log.Printf("Processing webhook config %d: enabled=%v", i, whConfig.Enabled)
		if whConfig.Enabled {
			alerter := alerts.NewWebhookAlerter(whConfig)
			server.webhooks = append(server.webhooks, alerter)
			log.Printf("Added webhook alerter: %+v", whConfig.URL)
		}
	}

	// Start state saving goroutine
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()

		for {
			select {
			case <-server.shutdown:
				return
			case <-ticker.C:
				if err := server.saveState(); err != nil {
					log.Printf("Error saving state: %v", err)
				}
			}
		}
	}()

	// Send startup notification
	if len(server.webhooks) > 0 {
		log.Printf("Sending startup notification to %d webhooks", len(server.webhooks))
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
		server.sendAlert(alert)
	}

	// Check initial states after a brief delay to allow for node discovery
	go func() {
		time.Sleep(30 * time.Second) // Give nodes a chance to report in
		server.checkInitialStates()
	}()

	return server, nil
}

func (s *Server) sendAlert(alert alerts.WebhookAlert) {
	for _, webhook := range s.webhooks {
		if err := webhook.Alert(alert); err != nil {
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

func getServiceStateKey(nodeID, serviceName string) string {
	return fmt.Sprintf("%s-%s", nodeID, serviceName)
}

func (s *Server) ReportStatus(ctx context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Unix(req.Timestamp, 0)
	pollerID := req.PollerId

	// Check if this is a recovery
	if state, exists := s.nodeAlertStates[pollerID]; exists && state.isDown {
		alert := alerts.WebhookAlert{
			Level:   alerts.Info,
			Title:   "Node Recovery",
			Message: fmt.Sprintf("Node %s is back online after %v", pollerID, time.Since(state.timestamp).Round(time.Second)),
			NodeID:  pollerID,
			Details: map[string]any{
				"hostname":     getHostname(),
				"downtime":     time.Since(state.timestamp).String(),
				"recovered_at": now.Format(time.RFC3339),
			},
		}
		log.Printf("Sending recovery alert for node %s", pollerID)
		s.sendAlert(alert)
		delete(s.nodeAlertStates, pollerID)
	}

	// Update last seen time for the poller
	s.lastSeen[pollerID] = now

	// Create node status for API
	status := &api.NodeStatus{
		NodeID:     pollerID,
		IsHealthy:  true,
		LastUpdate: now,
		Services:   make([]api.ServiceStatus, 0, len(req.Services)),
	}

	// Process each service
	for _, svc := range req.Services {
		serviceStatus := api.ServiceStatus{
			Name:      svc.ServiceName,
			Available: svc.Available,
			Message:   svc.Message,
			Type:      svc.Type,
		}

		// Handle service state and alerts
		stateKey := getServiceStateKey(pollerID, svc.ServiceName)
		state, exists := s.serviceAlertStates[stateKey]

		if !svc.Available {
			status.IsHealthy = false
			if !exists || !state.isDown {
				// Service just went down
				alert := alerts.WebhookAlert{
					Level:   alerts.Warning,
					Title:   fmt.Sprintf("Service Down: %s", svc.ServiceName),
					Message: fmt.Sprintf("Service %s is unavailable on node %s", svc.ServiceName, pollerID),
					NodeID:  pollerID,
					Details: map[string]any{
						"hostname": getHostname(),
						"service":  svc.ServiceName,
						"message":  svc.Message,
						"type":     svc.Type,
					},
				}
				log.Printf("Sending service down alert for %s on node %s", svc.ServiceName, pollerID)
				s.sendAlert(alert)
				s.serviceAlertStates[stateKey] = &alertState{isDown: true, timestamp: time.Now()}
			}
		} else if exists && state.isDown {
			// Service recovered
			alert := alerts.WebhookAlert{
				Level:   alerts.Info,
				Title:   fmt.Sprintf("Service Recovery: %s", svc.ServiceName),
				Message: fmt.Sprintf("Service %s is back online on node %s", svc.ServiceName, pollerID),
				NodeID:  pollerID,
				Details: map[string]any{
					"hostname":     getHostname(),
					"service":      svc.ServiceName,
					"downtime":     time.Since(state.timestamp).String(),
					"recovered_at": now.Format(time.RFC3339),
				},
			}
			log.Printf("Sending service recovery alert for %s on node %s", svc.ServiceName, pollerID)
			s.sendAlert(alert)
			delete(s.serviceAlertStates, stateKey)
		}

		// Parse details if they exist in the message
		if svc.Message != "" {
			if err := json.Unmarshal([]byte(svc.Message), &serviceStatus.Details); err != nil {
				// If message isn't JSON, store as basic details
				basicDetails := map[string]interface{}{
					"message": svc.Message,
				}
				if detailsJson, err := json.Marshal(basicDetails); err == nil {
					serviceStatus.Details = detailsJson
				}
			}
		}

		status.Services = append(status.Services, serviceStatus)
	}

	// Update API server with new status
	if s.apiServer != nil {
		s.apiServer.UpdateNodeStatus(pollerID, status)
	}

	return &proto.PollerStatusResponse{Received: true}, nil
}

func (s *Server) MonitorPollers(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.checkPollers()
		}
	}
}

func (s *Server) checkPollers() {
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
				s.sendAlert(alert)
				s.nodeAlertStates[pollerID] = &alertState{
					isDown:    true,
					timestamp: now,
				}
			}
		}
	}
}

func (s *Server) sendStartupNotification() {
	alert := alerts.WebhookAlert{
		Level:     alerts.Info,
		Title:     "Cloud Service Started",
		Message:   fmt.Sprintf("HomeMon cloud service initialized at %s", time.Now().Format(time.RFC3339)),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		NodeID:    "cloud",
		Details: map[string]any{
			"version":  "1.0.0", // TODO: make this configurable
			"hostname": getHostname(),
			"pid":      os.Getpid(),
		},
	}

	s.sendAlert(alert)
}

func getHostname() string {
	hostname, err := os.Hostname()
	if err != nil {
		return "unknown"
	}
	return hostname
}
