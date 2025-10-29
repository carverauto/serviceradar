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
	"encoding/base64"
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
	errInvalidDuration                  = fmt.Errorf("invalid duration")
	errLoggingConfigRequired            = fmt.Errorf("logging configuration is required")
	errDatabaseNameRequired             = fmt.Errorf("database name is required")
	errDatabaseAddressRequired          = fmt.Errorf("database address is required")
	errListenAddrRequired               = fmt.Errorf("listen address is required")
	errGRPCAddrRequired                 = fmt.Errorf("grpc address is required")
	errSpireAdminServerAddressRequired  = fmt.Errorf("spire_admin.server_address is required when enabled")
	errSpireAdminServerSPIFFEIDRequired = fmt.Errorf("spire_admin.server_spiffe_id is required when enabled")
	errSpireAdminJoinTokenTTLInvalid    = fmt.Errorf("spire_admin.join_token_ttl must be non-negative")
	errEdgeOnboardingKeyRequired        = fmt.Errorf("edge_onboarding.encryption_key is required when enabled")
	errEdgeOnboardingKeyLength          = fmt.Errorf("edge_onboarding.encryption_key must decode to 32 bytes")
	errEdgeOnboardingJoinTokenTTL       = fmt.Errorf("edge_onboarding.join_token_ttl must be non-negative")
	errEdgeOnboardingDownloadTokenTTL   = fmt.Errorf("edge_onboarding.download_token_ttl must be non-negative")
)

// MCPConfigRef represents MCP configuration to avoid circular imports
type MCPConfigRef struct {
	Enabled bool   `json:"enabled"`
	APIKey  string `json:"api_key"`
}

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
	MCP            *MCPConfigRef          `json:"mcp,omitempty"`
	// KV endpoints for admin config operations (hub/leaf mappings)
	KVEndpoints    []KVEndpoint          `json:"kv_endpoints,omitempty"`
	SpireAdmin     *SpireAdminConfig     `json:"spire_admin,omitempty"`
	EdgeOnboarding *EdgeOnboardingConfig `json:"edge_onboarding,omitempty"`
}

// KVEndpoint describes a reachable KV gRPC endpoint and its JetStream domain.
type KVEndpoint struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Address string `json:"address"`
	Domain  string `json:"domain"`
	Type    string `json:"type,omitempty"` // hub | leaf | other
	// Optional security for dialing KV from core (falls back to Core.Security if omitted)
}

// SpireAdminConfig captures SPIRE server access for administrative APIs.
type SpireAdminConfig struct {
	Enabled        bool     `json:"enabled"`
	ServerAddress  string   `json:"server_address"`
	ServerSPIFFEID string   `json:"server_spiffe_id"`
	WorkloadSocket string   `json:"workload_socket,omitempty"`
	BundlePath     string   `json:"bundle_path,omitempty"`
	JoinTokenTTL   Duration `json:"join_token_ttl,omitempty"`
}

// EdgeOnboardingConfig configures secure edge poller enrollment.
type EdgeOnboardingConfig struct {
	Enabled                bool     `json:"enabled"`
	EncryptionKey          string   `json:"encryption_key"`
	DefaultSelectors       []string `json:"default_selectors,omitempty"`
	DownstreamPathTemplate string   `json:"downstream_path_template,omitempty"`
	JoinTokenTTL           Duration `json:"join_token_ttl,omitempty"`
	DownloadTokenTTL       Duration `json:"download_token_ttl,omitempty"`
	PollerIDPrefix         string   `json:"poller_id_prefix,omitempty"`
}

func (c *CoreServiceConfig) MarshalJSON() ([]byte, error) {
	type Alias CoreServiceConfig

	aux := &struct {
		AlertThreshold string `json:"alert_threshold"`
		Auth           *struct {
			JWTSecret     string               `json:"jwt_secret"`
			JWTAlgorithm  string               `json:"jwt_algorithm,omitempty"`
			JWTPrivateKey string               `json:"jwt_private_key_pem,omitempty"`
			JWTPublicKey  string               `json:"jwt_public_key_pem,omitempty"`
			JWTKeyID      string               `json:"jwt_key_id,omitempty"`
			JWTExpiration string               `json:"jwt_expiration"`
			LocalUsers    map[string]string    `json:"local_users"`
			CallbackURL   string               `json:"callback_url,omitempty"`
			SSOProviders  map[string]SSOConfig `json:"sso_providers,omitempty"`
			RBAC          RBACConfig           `json:"rbac,omitempty"`
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
			JWTAlgorithm  string               `json:"jwt_algorithm,omitempty"`
			JWTPrivateKey string               `json:"jwt_private_key_pem,omitempty"`
			JWTPublicKey  string               `json:"jwt_public_key_pem,omitempty"`
			JWTKeyID      string               `json:"jwt_key_id,omitempty"`
			JWTExpiration string               `json:"jwt_expiration"`
			LocalUsers    map[string]string    `json:"local_users"`
			CallbackURL   string               `json:"callback_url,omitempty"`
			SSOProviders  map[string]SSOConfig `json:"sso_providers,omitempty"`
			RBAC          RBACConfig           `json:"rbac,omitempty"`
		}{
			JWTSecret:     c.Auth.JWTSecret,
			JWTAlgorithm:  c.Auth.JWTAlgorithm,
			JWTPrivateKey: c.Auth.JWTPrivateKeyPEM,
			JWTPublicKey:  c.Auth.JWTPublicKeyPEM,
			JWTKeyID:      c.Auth.JWTKeyID,
			LocalUsers:    c.Auth.LocalUsers,
			CallbackURL:   c.Auth.CallbackURL,
			SSOProviders:  c.Auth.SSOProviders,
			RBAC:          c.Auth.RBAC,
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
			JWTAlgorithm  string               `json:"jwt_algorithm,omitempty"`
			JWTPrivateKey string               `json:"jwt_private_key_pem,omitempty"`
			JWTPublicKey  string               `json:"jwt_public_key_pem,omitempty"`
			JWTKeyID      string               `json:"jwt_key_id,omitempty"`
			JWTExpiration string               `json:"jwt_expiration"`
			LocalUsers    map[string]string    `json:"local_users"`
			CallbackURL   string               `json:"callback_url,omitempty"`
			SSOProviders  map[string]SSOConfig `json:"sso_providers,omitempty"`
			RBAC          RBACConfig           `json:"rbac,omitempty"`
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
			JWTSecret:        aux.Auth.JWTSecret,
			JWTAlgorithm:     aux.Auth.JWTAlgorithm,
			JWTPrivateKeyPEM: aux.Auth.JWTPrivateKey,
			JWTPublicKeyPEM:  aux.Auth.JWTPublicKey,
			JWTKeyID:         aux.Auth.JWTKeyID,
			LocalUsers:       aux.Auth.LocalUsers,
			CallbackURL:      aux.Auth.CallbackURL,
			SSOProviders:     aux.Auth.SSOProviders,
			RBAC:             aux.Auth.RBAC,
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

func (c *CoreServiceConfig) Validate() error {
	if c.Logging == nil {
		return errLoggingConfigRequired
	}

	if c.Database.Name == "" && c.DBName == "" {
		return errDatabaseNameRequired
	}

	if len(c.Database.Addresses) == 0 && c.DBAddr == "" {
		return errDatabaseAddressRequired
	}

	if c.ListenAddr == "" {
		return errListenAddrRequired
	}

	if c.GrpcAddr == "" {
		return errGRPCAddrRequired
	}

	if c.SpireAdmin != nil && c.SpireAdmin.Enabled {
		if c.SpireAdmin.ServerAddress == "" {
			return errSpireAdminServerAddressRequired
		}
		if c.SpireAdmin.ServerSPIFFEID == "" {
			return errSpireAdminServerSPIFFEIDRequired
		}
		if c.SpireAdmin.JoinTokenTTL < 0 {
			return errSpireAdminJoinTokenTTLInvalid
		}
	}

	if c.EdgeOnboarding != nil && c.EdgeOnboarding.Enabled {
		if c.EdgeOnboarding.EncryptionKey == "" {
			return errEdgeOnboardingKeyRequired
		}
		keyBytes, err := base64.StdEncoding.DecodeString(c.EdgeOnboarding.EncryptionKey)
		if err != nil || len(keyBytes) != 32 {
			return errEdgeOnboardingKeyLength
		}
		if c.EdgeOnboarding.JoinTokenTTL < 0 {
			return errEdgeOnboardingJoinTokenTTL
		}
		if c.EdgeOnboarding.DownloadTokenTTL < 0 {
			return errEdgeOnboardingDownloadTokenTTL
		}
	}

	return nil
}
