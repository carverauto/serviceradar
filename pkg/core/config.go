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
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultMetricsRetention  = 100
	defaultMetricsMaxPollers = 10000
	jwtAlgorithmRS256        = "RS256"
)

func LoadConfig(path string) (models.CoreServiceConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return models.CoreServiceConfig{}, fmt.Errorf("failed to read coreServiceConfig: %w", err)
	}

	var coreServiceConfig models.CoreServiceConfig

	if err := json.Unmarshal(data, &coreServiceConfig); err != nil {
		return models.CoreServiceConfig{}, fmt.Errorf("failed to parse coreServiceConfig: %w", err)
	}

	// Overlay from KV if configured (no-op if KV env is not set or key missing)
	_ = overlayFromKV(path, &coreServiceConfig)

	if err := coreServiceConfig.Validate(); err != nil {
		return models.CoreServiceConfig{}, fmt.Errorf("invalid configuration: %w", err)
	}

	return coreServiceConfig, nil
}

// overlayFromKV uses the config package's KV manager to overlay configuration from KV store
func overlayFromKV(path string, cfg *models.CoreServiceConfig) error {
	ctx := context.Background()

	// Use the existing KVManager from pkg/config which handles env vars properly
	kvMgr := config.NewKVManagerFromEnv(ctx, models.RoleCore)
	if kvMgr == nil {
		return nil // No KV configured, which is fine
	}
	defer func() { _ = kvMgr.Close() }()

	cfgLoader := config.NewConfig(nil)
	kvMgr.SetupConfigLoader(cfgLoader)

	return cfgLoader.OverlayFromKV(ctx, path, cfg)
}

func normalizeConfig(config *models.CoreServiceConfig) *models.CoreServiceConfig {
	normalized := *config

	// Set the DB parameters from the Database struct
	if len(normalized.Database.Addresses) > 0 {
		// Set the first address as the primary DB address
		normalized.DBAddr = normalized.Database.Addresses[0]
	}

	normalized.DBName = normalized.Database.Name
	normalized.DBUser = normalized.Database.Username
	normalized.DBPass = normalized.Database.Password

	// Default settings if not specified
	if normalized.Metrics.Retention == 0 {
		normalized.Metrics.Retention = defaultMetricsRetention
	}

	if normalized.Metrics.MaxPollers == 0 {
		normalized.Metrics.MaxPollers = defaultMetricsMaxPollers
	}

	if normalized.SpireAdmin != nil && normalized.SpireAdmin.Enabled {
		if normalized.SpireAdmin.WorkloadSocket == "" {
			normalized.SpireAdmin.WorkloadSocket = "unix:/run/spire/sockets/agent.sock"
		}
	}

	if normalized.Features.UseLogDigest == nil {
		normalized.Features.UseLogDigest = boolPtr(true)
	}

	return &normalized
}

func getDBPath(configPath string) string {
	if configPath == "" {
		return defaultDBPath
	}

	return configPath
}

func ensureDataDirectory(dbPath string) error {
	dir := filepath.Dir(dbPath)

	return os.MkdirAll(dir, serviceradarDirPerms)
}

func initializeAuthConfig(config *models.CoreServiceConfig) (*models.AuthConfig, error) {
	authConfig := &models.AuthConfig{
		JWTSecret:     os.Getenv("JWT_SECRET"),
		JWTExpiration: 24 * time.Hour,
		CallbackURL:   os.Getenv("AUTH_CALLBACK_URL"),
		LocalUsers:    make(map[string]string),
	}

	if config.Auth != nil {
		applyAuthOverrides(authConfig, config.Auth)
	} else {
		applyDefaultAdminUser(authConfig)
	}

	// If RS256 is configured with a key, allow empty JWT_SECRET.
	if authConfig.JWTAlgorithm != jwtAlgorithmRS256 || (authConfig.JWTPrivateKeyPEM == "" && authConfig.JWTPublicKeyPEM == "") {
		if authConfig.JWTSecret == "" {
			return nil, errJWTSecretRequired
		}
	}

	return authConfig, nil
}

func applyAuthOverrides(authConfig, configAuth *models.AuthConfig) {
	if configAuth.JWTSecret != "" {
		authConfig.JWTSecret = configAuth.JWTSecret
	}

	if configAuth.JWTExpiration != 0 {
		authConfig.JWTExpiration = configAuth.JWTExpiration
	}

	if len(configAuth.LocalUsers) > 0 {
		authConfig.LocalUsers = configAuth.LocalUsers
	}

	// RS256/JWKS fields
	if configAuth.JWTAlgorithm != "" {
		authConfig.JWTAlgorithm = configAuth.JWTAlgorithm
	}
	if configAuth.JWTPrivateKeyPEM != "" {
		authConfig.JWTPrivateKeyPEM = configAuth.JWTPrivateKeyPEM
	}
	if configAuth.JWTPublicKeyPEM != "" {
		authConfig.JWTPublicKeyPEM = configAuth.JWTPublicKeyPEM
	}
	if configAuth.JWTKeyID != "" {
		authConfig.JWTKeyID = configAuth.JWTKeyID
	}

	// Always copy RBAC if any part of it is configured
	if configAuth.RBAC.UserRoles != nil || configAuth.RBAC.RolePermissions != nil || configAuth.RBAC.RouteProtection != nil {
		authConfig.RBAC = configAuth.RBAC
		fmt.Printf("DEBUG: Copied RBAC config. UserRoles: %+v\n", authConfig.RBAC.UserRoles)
	} else {
		// Even if the check fails, try to copy it anyway
		authConfig.RBAC = configAuth.RBAC
		fmt.Printf("DEBUG: Copied RBAC config anyway. UserRoles: %+v\n", authConfig.RBAC.UserRoles)
	}
}

func boolPtr(v bool) *bool {
	return &v
}

func applyDefaultAdminUser(authConfig *models.AuthConfig) {
	if adminHash := os.Getenv("ADMIN_PASSWORD_HASH"); adminHash != "" {
		authConfig.LocalUsers["admin"] = adminHash
	}
}

func (s *Server) initializeWebhooks(configs []alerts.WebhookConfig) {
	for i, webhookConfig := range configs {
		s.logger.Debug().
			Int("index", i).
			Bool("enabled", webhookConfig.Enabled).
			Msg("Processing webhook webhookConfig")

		if webhookConfig.Enabled {
			alerter := alerts.NewWebhookAlerter(webhookConfig)
			s.webhooks = append(s.webhooks, alerter)

			s.logger.Info().
				Str("url", webhookConfig.URL).
				Msg("Added webhook alerter")
		}
	}
}
