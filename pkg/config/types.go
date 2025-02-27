package config

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

type Duration time.Duration

func (d *Duration) UnmarshalJSON(b []byte) error {
	var v interface{}
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}

	switch value := v.(type) {
	case float64:
		// parse numeric as nanoseconds
		*d = Duration(time.Duration(value))
		return nil
	case string:
		dur, err := time.ParseDuration(value)
		if err != nil {
			return fmt.Errorf("invalid duration: %w", err)
		}

		*d = Duration(dur)

		return nil
	default:
		return errInvalidDuration
	}
}

// AgentConfig represents the configuration for an agent instance.
type AgentConfig struct {
	CheckersDir string                 `json:"checkers_dir"` // e.g., /etc/serviceradar/checkers
	ListenAddr  string                 `json:"listen_addr"`  // e.g., :50051
	ServiceName string                 `json:"service_name"` // e.g., "agent"
	Security    *models.SecurityConfig `json:"security"`
}

// Check represents a generic service check configuration.
type Check struct {
	ServiceType string          `json:"service_type"` // e.g., "grpc", "process", "port"
	ServiceName string          `json:"service_name"`
	Details     string          `json:"details,omitempty"` // Service-specific details
	Port        int32           `json:"port,omitempty"`    // For port checkers
	Config      json.RawMessage `json:"config,omitempty"`  // Checker-specific configuration
}

// AgentDefinition represents a remote agent and its checks.
type AgentDefinition struct {
	Address string  `json:"address"` // gRPC address of the agent
	Checks  []Check `json:"checks"`  // List of checks to run on this agent
}

// PollerConfig represents the configuration for a poller instance.
type PollerConfig struct {
	Agents       map[string]AgentDefinition `json:"agents"`        // Map of agent ID to agent definition
	CloudAddress string                     `json:"cloud_address"` // Address of cloud service
	PollInterval Duration                   `json:"poll_interval"` // How often to poll agents
	PollerID     string                     `json:"poller_id"`     // Unique identifier for this poller
}

// WebhookConfig represents a webhook notification configuration.
type WebhookConfig struct {
	Enabled  bool     `json:"enabled"`
	URL      string   `json:"url"`
	Cooldown Duration `json:"cooldown"`
	Template string   `json:"template"`
	Headers  []Header `json:"headers,omitempty"` // Optional custom headers
}

// Header represents a custom HTTP header.
type Header struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

// CloudConfig represents the configuration for the cloud service.
type CloudConfig struct {
	ListenAddr     string          `json:"listen_addr"`
	GrpcAddr       string          `json:"grpc_addr,omitempty"`
	DBPath         string          `json:"db_path"`
	AlertThreshold Duration        `json:"alert_threshold"`
	KnownPollers   []string        `json:"known_pollers"`
	Webhooks       []WebhookConfig `json:"webhooks,omitempty"`
}
