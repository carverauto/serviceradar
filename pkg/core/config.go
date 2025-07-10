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
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultMetricsRetention  = 100
	defaultMetricsMaxPollers = 10000
)

func LoadConfig(path string) (models.DBConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return models.DBConfig{}, fmt.Errorf("failed to read config: %w", err)
	}

	var config models.DBConfig

	if err := json.Unmarshal(data, &config); err != nil {
		return models.DBConfig{}, fmt.Errorf("failed to parse config: %w", err)
	}

	if config.Security != nil {
		log.Printf("Security config: Mode=%s, CertDir=%s, Role=%s",
			config.Security.Mode, config.Security.CertDir, config.Security.Role)
	}

	return config, nil
}

func normalizeConfig(config *models.DBConfig) *models.DBConfig {
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

func initializeAuthConfig(config *models.DBConfig) (*models.AuthConfig, error) {
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

	if authConfig.JWTSecret == "" {
		return nil, errJWTSecretRequired
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
}

func applyDefaultAdminUser(authConfig *models.AuthConfig) {
	if adminHash := os.Getenv("ADMIN_PASSWORD_HASH"); adminHash != "" {
		authConfig.LocalUsers["admin"] = adminHash
	}
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
