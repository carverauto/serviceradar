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
}

func (s *Server) Shutdown() {
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

func NewServer(config Config) (*Server, error) {
	server := &Server{
		lastSeen:           make(map[string]time.Time),
		alertThreshold:     config.AlertThreshold,
		webhooks:           make([]*alerts.WebhookAlerter, 0),
		nodeAlertStates:    make(map[string]*alertState),
		serviceAlertStates: make(map[string]*alertState),
		shutdown:           make(chan struct{}),
	}

	// Initialize webhook alerters
	for _, whConfig := range config.Webhooks {
		if whConfig.Enabled {
			alerter := alerts.NewWebhookAlerter(whConfig)
			server.webhooks = append(server.webhooks, alerter)
		}
	}

	// Send startup notification after webhooks are initialized
	if len(server.webhooks) > 0 {
		alert := alerts.WebhookAlert{
			Level:     alerts.Info,
			Title:     "Cloud Service Started",
			Message:   fmt.Sprintf("HomeMon cloud service initialized at %s", time.Now().Format(time.RFC3339)),
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			NodeID:    "cloud",
			Details: map[string]any{
				"version":  "1.0.0", // Consider making this configurable
				"hostname": getHostname(),
				"pid":      os.Getpid(),
			},
		}
		server.sendAlert(alert)
	}

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
