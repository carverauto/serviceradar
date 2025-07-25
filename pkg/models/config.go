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

package models

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/logger"
)

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
	CheckersDir string          `json:"checkers_dir"` // e.g., /etc/serviceradar/checkers
	ListenAddr  string          `json:"listen_addr"`  // e.g., :50051
	ServiceName string          `json:"service_name"` // e.g., "agent"
	Security    *SecurityConfig `json:"security"`
	KVAddress   string          `json:"kv_address,omitempty"` // Optional KV store address
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

var (
	errInvalidDuration = fmt.Errorf("invalid duration")
)

// CoreServiceConfig represents the configuration for the core service.
// This was previously named DBConfig but contains much more than database configuration.
type CoreServiceConfig struct {
	ListenAddr     string                 `json:"listen_addr"`
	GrpcAddr       string                 `json:"grpc_addr"`
	DBPath         string                 `json:"db_path"` // Keep for compatibility, can be optional
	DBAddr         string                 `json:"db_addr"` // Proton host:port
	DBName         string                 `json:"db_name"` // Proton database name
	DBUser         string                 `json:"db_user"` // Proton username
	DBPass         string                 `json:"db_pass"` // Proton password
	AlertThreshold time.Duration          `json:"alert_threshold"`
	PollerPatterns []string               `json:"poller_patterns"`
	Webhooks       []alerts.WebhookConfig `json:"webhooks,omitempty"`
	KnownPollers   []string               `json:"known_pollers,omitempty"`
	Metrics        Metrics                `json:"metrics"`
	SNMP           SNMPConfig             `json:"snmp"`
	Security       *SecurityConfig        `json:"security"`
	Auth           *AuthConfig            `json:"auth,omitempty"`
	CORS           CORSConfig             `json:"cors,omitempty"`
	Database       ProtonDatabase         `json:"database"`
	WriteBuffer    WriteBufferConfig      `json:"write_buffer,omitempty"`
	NATS           *NATSConfig            `json:"nats,omitempty"`
	Events         *EventsConfig          `json:"events,omitempty"`
	Logging        *logger.Config         `json:"logging,omitempty"`
}

func (c *CoreServiceConfig) MarshalJSON() ([]byte, error) {
	type Alias CoreServiceConfig

	aux := &struct {
		AlertThreshold string `json:"alert_threshold"`
		Auth           *struct {
			JWTSecret     string               `json:"jwt_secret"`
			JWTExpiration string               `json:"jwt_expiration"`
			LocalUsers    map[string]string    `json:"local_users"`
			CallbackURL   string               `json:"callback_url,omitempty"`
			SSOProviders  map[string]SSOConfig `json:"sso_providers,omitempty"`
		} `json:"auth,omitempty"`
		*Alias
	}{
		Alias: (*Alias)(c),
	}

	if c.AlertThreshold != 0 {
		aux.AlertThreshold = c.AlertThreshold.String()
	}

	if c.Auth != nil {
		aux.Auth = &struct {
			JWTSecret     string               `json:"jwt_secret"`
			JWTExpiration string               `json:"jwt_expiration"`
			LocalUsers    map[string]string    `json:"local_users"`
			CallbackURL   string               `json:"callback_url,omitempty"`
			SSOProviders  map[string]SSOConfig `json:"sso_providers,omitempty"`
		}{
			JWTSecret:    c.Auth.JWTSecret,
			LocalUsers:   c.Auth.LocalUsers,
			CallbackURL:  c.Auth.CallbackURL,
			SSOProviders: c.Auth.SSOProviders,
		}

		if c.Auth.JWTExpiration != 0 {
			aux.Auth.JWTExpiration = c.Auth.JWTExpiration.String()
		}
	}

	return json.Marshal(aux)
}

func (c *CoreServiceConfig) UnmarshalJSON(data []byte) error {
	type Alias CoreServiceConfig

	aux := &struct {
		AlertThreshold string `json:"alert_threshold"`
		Auth           *struct {
			JWTSecret     string               `json:"jwt_secret"`
			JWTExpiration string               `json:"jwt_expiration"`
			LocalUsers    map[string]string    `json:"local_users"`
			CallbackURL   string               `json:"callback_url,omitempty"`
			SSOProviders  map[string]SSOConfig `json:"sso_providers,omitempty"`
		} `json:"auth"`
		*Alias
	}{
		Alias: (*Alias)(c),
	}

	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}

	if aux.AlertThreshold != "" {
		duration, err := time.ParseDuration(aux.AlertThreshold)
		if err != nil {
			return fmt.Errorf("invalid alert threshold format: %w", err)
		}

		c.AlertThreshold = duration
	}

	if aux.Auth != nil {
		c.Auth = &AuthConfig{
			JWTSecret:    aux.Auth.JWTSecret,
			LocalUsers:   aux.Auth.LocalUsers,
			CallbackURL:  aux.Auth.CallbackURL,
			SSOProviders: aux.Auth.SSOProviders,
		}

		if aux.Auth.JWTExpiration != "" {
			duration, err := time.ParseDuration(aux.Auth.JWTExpiration)
			if err != nil {
				return fmt.Errorf("invalid jwt_expiration format: %w", err)
			}

			c.Auth.JWTExpiration = duration
		}
	}

	return nil
}
