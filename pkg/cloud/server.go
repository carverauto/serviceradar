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

type Server struct {
	proto.UnimplementedPollerServiceServer
	mu             sync.RWMutex
	lastSeen       map[string]time.Time
	alertThreshold time.Duration
	// alertFunc      AlertFunc
	webhooks  []*alerts.WebhookAlerter
	apiServer *api.APIServer
}

func (s *Server) SetAPIServer(api *api.APIServer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.apiServer = api
}

func NewServer(config *Config) (*Server, error) {
	server := &Server{
		lastSeen:       make(map[string]time.Time),
		alertThreshold: config.AlertThreshold,
		webhooks:       make([]*alerts.WebhookAlerter, 0),
	}

	// Initialize webhook alerters
	for _, whConfig := range config.Webhooks {
		if whConfig.Enabled {
			alerter := alerts.NewWebhookAlerter(whConfig)
			server.webhooks = append(server.webhooks, alerter)
		}
	}

	// Send startup notification if we have any webhooks configured
	if len(server.webhooks) > 0 {
		server.sendStartupNotification()
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

func (s *Server) ReportStatus(ctx context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
	s.mu.Lock()
	s.lastSeen[req.PollerId] = time.Unix(req.Timestamp, 0)
	s.mu.Unlock()

	// Create node status for API
	status := &api.NodeStatus{
		NodeID:     req.PollerId,
		IsHealthy:  true, // We'll determine this based on services
		LastUpdate: time.Unix(req.Timestamp, 0),
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

		// Determine service type and details
		// In ReportStatus method in pkg/cloud/server.go:

		if svc.ServiceName == "dusk" {
			serviceStatus.Type = "blockchain"

			// Try to parse the message as JSON first
			var blockDetails interface{}
			if err := json.Unmarshal([]byte(svc.Message), &blockDetails); err == nil {
				// If it's valid JSON, use it directly
				if jsonBytes, err := json.Marshal(blockDetails); err == nil {
					serviceStatus.Details = jsonBytes
				}
			} else {
				// Create a basic status if parsing failed
				basicStatus := map[string]interface{}{
					"status": svc.Message,
				}
				if jsonBytes, err := json.Marshal(basicStatus); err == nil {
					serviceStatus.Details = jsonBytes
				}
			}

			// Log the details for debugging
			log.Printf("Processed Dusk service details: %+v", string(serviceStatus.Details))
		}

		// Send alerts for unavailable services
		if !svc.Available {
			alert := alerts.WebhookAlert{
				Level:   alerts.Warning,
				Title:   fmt.Sprintf("Service Down: %s", svc.ServiceName),
				Message: fmt.Sprintf("Service %s is unavailable on node %s", svc.ServiceName, req.PollerId),
				NodeID:  req.PollerId,
				Details: map[string]any{
					"service": svc.ServiceName,
					"message": svc.Message,
					"type":    svc.Type,
				},
			}
			s.sendAlert(alert)
		}

		status.Services = append(status.Services, serviceStatus)

		// Update overall health status
		if !svc.Available {
			status.IsHealthy = false
		}
	}

	// If we have an API server, update it
	if s.apiServer != nil {
		s.apiServer.UpdateNodeStatus(req.PollerId, status)
	}

	// Log service issues
	for _, status := range req.Services {
		if !status.Available {
			log.Printf("Alert: Service %s is down: %s", status.ServiceName, status.Message)
		}
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
	s.mu.RLock()
	defer s.mu.RUnlock()

	for pollerID, lastSeen := range s.lastSeen {
		if duration := now.Sub(lastSeen); duration > s.alertThreshold {
			alert := alerts.WebhookAlert{
				Level:   alerts.Error,
				Title:   "Node Offline",
				Message: fmt.Sprintf("Node %s has not reported in %v", pollerID, duration.Round(time.Second)),
				NodeID:  pollerID,
				Details: map[string]any{
					"last_seen": lastSeen,
					"duration":  duration.String(),
				},
			}
			s.sendAlert(alert)
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
