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
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultMetricsRetention  = 100
	defaultMetricsMaxPollers = 10000
	jwtAlgorithmRS256        = "RS256"
)

var (
	errEmptyPrivateKey       = errors.New("empty private key")
	errDecodePrivateKeyPEM   = errors.New("failed to decode private key PEM")
	errUnsupportedPrivateKey = errors.New("unsupported private key type")
	errNotRSAPrivateKey      = errors.New("decoded key is not RSA private key")
)

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

	if normalized.Features.UseStatsCache == nil {
		normalized.Features.UseStatsCache = boolPtr(true)
	}

	if normalized.Features.UseDeviceSearchPlanner == nil {
		normalized.Features.UseDeviceSearchPlanner = boolPtr(true)
	}

	if normalized.Features.RequireDeviceRegistry == nil {
		normalized.Features.RequireDeviceRegistry = boolPtr(false)
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

	if err := hydrateJWTKeys(authConfig); err != nil {
		log.Printf("core: unable to hydrate JWT keys from disk: %v", err)
	}

	if strings.EqualFold(authConfig.JWTAlgorithm, jwtAlgorithmRS256) {
		priv := strings.TrimSpace(authConfig.JWTPrivateKeyPEM)
		if strings.HasPrefix(priv, `"`) && strings.HasSuffix(priv, `"`) {
			priv = strings.TrimPrefix(priv, `"`)
			priv = strings.TrimSuffix(priv, `"`)
		}
		if authConfig.JWTPublicKeyPEM == "" && priv != "" {
			if pub, err := derivePublicKeyPEM(priv); err == nil {
				authConfig.JWTPublicKeyPEM = pub
			} else {
				log.Printf("core: unable to derive JWKS public key from configured private key")
			}
		}
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

func hydrateJWTKeys(authConfig *models.AuthConfig) error {
	if authConfig == nil || !strings.EqualFold(authConfig.JWTAlgorithm, jwtAlgorithmRS256) {
		return nil
	}

	needsPriv := authConfig.JWTPrivateKeyPEM == ""
	needsPub := authConfig.JWTPublicKeyPEM == ""
	needsKID := authConfig.JWTKeyID == ""

	if !needsPriv && !needsPub && !needsKID {
		return nil
	}

	configPath := os.Getenv("CONFIG_PATH")
	if configPath == "" {
		return nil
	}

	payload, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}

	var wrapper struct {
		Auth json.RawMessage `json:"auth"`
	}
	if err := json.Unmarshal(payload, &wrapper); err != nil {
		return err
	}
	if len(wrapper.Auth) == 0 {
		return nil
	}

	var diskAuth models.AuthConfig
	if err := json.Unmarshal(wrapper.Auth, &diskAuth); err != nil {
		return nil
	}

	if needsPriv && diskAuth.JWTPrivateKeyPEM != "" {
		authConfig.JWTPrivateKeyPEM = diskAuth.JWTPrivateKeyPEM
	}
	if needsPub && diskAuth.JWTPublicKeyPEM != "" {
		authConfig.JWTPublicKeyPEM = diskAuth.JWTPublicKeyPEM
	}
	if needsKID && diskAuth.JWTKeyID != "" {
		authConfig.JWTKeyID = diskAuth.JWTKeyID
	}

	return nil
}

func derivePublicKeyPEM(privatePEM string) (string, error) {
	if privatePEM == "" {
		return "", errEmptyPrivateKey
	}

	block, _ := pem.Decode([]byte(privatePEM))
	if block == nil {
		return "", errDecodePrivateKeyPEM
	}

	var key any
	var err error
	switch block.Type {
	case "PRIVATE KEY":
		key, err = x509.ParsePKCS8PrivateKey(block.Bytes)
	case "RSA PRIVATE KEY":
		key, err = x509.ParsePKCS1PrivateKey(block.Bytes)
	default:
		return "", fmt.Errorf("%w %q", errUnsupportedPrivateKey, block.Type)
	}
	if err != nil {
		return "", err
	}

	priv, ok := key.(*rsa.PrivateKey)
	if !ok {
		return "", errNotRSAPrivateKey
	}

	pubDER, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		return "", err
	}

	return string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER})), nil
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
