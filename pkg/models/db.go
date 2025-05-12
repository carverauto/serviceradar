package models

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
)

type ProtonSettings struct {
	MaxExecutionTime                    int `json:"max_execution_time"`
	OutputFormatJSONQuote64bitInt       int `json:"output_format_json_quote_64bit_int"`
	AllowExperimentalLiveViews          int `json:"allow_experimental_live_views"`
	IdleConnectionTimeout               int `json:"idle_connection_timeout"`
	JoinUseNulls                        int `json:"join_use_nulls"`
	InputFormatDefaultsForOmittedFields int `json:"input_format_defaults_for_omitted_fields"`
}

type ProtonDatabase struct {
	Addresses []string       `json:"addresses"`
	Name      string         `json:"name"`
	Username  string         `json:"username"`
	Password  string         `json:"password"`
	MaxConns  int            `json:"max_conns"`
	IdleConns int            `json:"idle_conns"`
	Settings  ProtonSettings `json:"settings"`
}

type Metrics struct {
	Enabled    bool  `json:"enabled"`
	Retention  int32 `json:"retention"`
	MaxPollers int32 `json:"max_pollers"`
}

type DBConfig struct {
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
}

func (c *DBConfig) MarshalJSON() ([]byte, error) {
	type Alias DBConfig

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

func (c *DBConfig) UnmarshalJSON(data []byte) error {
	type Alias DBConfig

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
