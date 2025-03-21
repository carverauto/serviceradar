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

package core

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

type Metrics struct {
	Enabled   bool `json:"enabled"`
	Retention int  `json:"retention"`
	MaxNodes  int  `json:"max_nodes"`
}

type Config struct {
	ListenAddr     string                 `json:"listen_addr"`
	GrpcAddr       string                 `json:"grpc_addr"`
	DBPath         string                 `json:"db_path"`
	AlertThreshold time.Duration          `json:"alert_threshold"`
	PollerPatterns []string               `json:"poller_patterns"`
	Webhooks       []alerts.WebhookConfig `json:"webhooks,omitempty"`
	KnownPollers   []string               `json:"known_pollers,omitempty"`
	Metrics        Metrics                `json:"metrics"`
	SNMP           snmp.Config            `json:"snmp"`
	Security       *models.SecurityConfig `json:"security"`
	Auth           *models.AuthConfig     `json:"auth,omitempty"`
	CORS           models.CORSConfig      `json:"cors,omitempty"`
}

func (c *Config) UnmarshalJSON(data []byte) error {
	type Alias Config

	aux := &struct {
		AlertThreshold string `json:"alert_threshold"`
		Auth           *struct {
			JWTSecret     string                      `json:"jwt_secret"`
			JWTExpiration string                      `json:"jwt_expiration"`
			LocalUsers    map[string]string           `json:"local_users"`
			CallbackURL   string                      `json:"callback_url,omitempty"`
			SSOProviders  map[string]models.SSOConfig `json:"sso_providers,omitempty"`
		} `json:"auth"`
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

	// Parse the auth section
	if aux.Auth != nil {
		c.Auth = &models.AuthConfig{
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

type Server struct {
	proto.UnimplementedPollerServiceServer
	mu             sync.RWMutex
	db             db.Service
	alertThreshold time.Duration
	webhooks       []alerts.AlertService
	apiServer      api.Service
	ShutdownChan   chan struct{}
	pollerPatterns []string
	grpcServer     *grpc.Server
	metrics        metrics.MetricCollector
	snmpManager    snmp.SNMPManager
	config         *Config
	authService    *auth.Auth
}

// OIDStatusData represents the structure of OID status data.
type OIDStatusData struct {
	LastValue  interface{} `json:"last_value"`
	LastUpdate string      `json:"last_update"`
	ErrorCount int         `json:"error_count"`
	LastError  string      `json:"last_error,omitempty"`
}

// ServiceStatus represents the status of a monitored service.
type ServiceStatus struct {
	NodeID      string
	ServiceName string
	ServiceType string
	Available   bool
	Details     string
	Timestamp   time.Time
}
