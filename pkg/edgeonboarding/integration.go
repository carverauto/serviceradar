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

package edgeonboarding

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	// ErrGeneratedConfigNotFound is returned when a requested generated config is not found.
	ErrGeneratedConfigNotFound = errors.New("generated config not found")
	// ErrIntegrationResultNil is returned when integration result is nil.
	ErrIntegrationResultNil = errors.New("integration result is nil")
)

const defaultServiceConfigFile = "service.json"

// IntegrationResult contains the results of onboarding that services need to start.
type IntegrationResult struct {
	// ConfigPath is the path to the generated configuration file
	ConfigPath string

	// Config is the raw configuration data (for in-memory use)
	ConfigData []byte

	// SPIFFEIDis the assigned SPIFFE ID
	SPIFFEID string

	// Package contains the full package details
	Package *models.EdgeOnboardingPackage

	// Bootstrapper is the bootstrapper instance (for accessing other generated configs)
	Bootstrapper *Bootstrapper
}

// TryOnboard checks if onboarding is requested (via flags/env) and performs it if needed.
// Returns:
// - IntegrationResult if onboarding was performed
// - nil if traditional config should be used
// - error if onboarding was attempted but failed
func TryOnboard(ctx context.Context, componentType models.EdgeOnboardingComponentType, log logger.Logger) (*IntegrationResult, error) {
	// Check for onboarding token from environment or flags
	token := os.Getenv("ONBOARDING_TOKEN")
	kvEndpoint := os.Getenv("KV_ENDPOINT")
	packageID := os.Getenv("EDGE_PACKAGE_ID")
	coreAPIURL := os.Getenv("CORE_API_URL")
	packagePath := firstNonEmpty(os.Getenv("ONBOARDING_PACKAGE"), os.Getenv("SR_ONBOARDING_PACKAGE"))

	// If no onboarding token, use traditional config
	if token == "" && packagePath == "" {
		return nil, nil
	}

	if log == nil {
		log = logger.NewTestLogger()
	}

	log.Info().
		Str("component_type", string(componentType)).
		Bool("offline_package", packagePath != "").
		Msg("Onboarding token detected - starting edge onboarding")

	// Validate required bootstrap config
	if kvEndpoint == "" {
		return nil, ErrKVEndpointRequired
	}

	// Create bootstrapper
	b, err := NewBootstrapper(&Config{
		Token:       token,
		PackagePath: packagePath,
		KVEndpoint:  kvEndpoint,
		ServiceType: componentType,
		PackageID:   packageID,
		CoreAPIURL:  coreAPIURL,
		Logger:      log,
		// StoragePath will use default
	})
	if err != nil {
		return nil, fmt.Errorf("create bootstrapper: %w", err)
	}

	// Run onboarding
	if err := b.Bootstrap(ctx); err != nil {
		return nil, fmt.Errorf("bootstrap failed: %w", err)
	}

	log.Info().
		Str("spiffe_id", b.GetSPIFFEID()).
		Str("component_id", b.pkg.ComponentID).
		Msg("Edge onboarding completed successfully")

	// Get the generated config for this component type
	configKey := getConfigKeyForComponent(componentType)
	configData, ok := b.GetConfig(configKey)
	if !ok {
		return nil, fmt.Errorf("%w: %q", ErrGeneratedConfigNotFound, configKey)
	}

	// Write config to a temporary file (services expect file paths)
	configPath, err := writeGeneratedConfig(componentType, configData, b.cfg.StoragePath)
	if err != nil {
		return nil, fmt.Errorf("write generated config: %w", err)
	}

	log.Info().
		Str("config_path", configPath).
		Str("config_key", configKey).
		Int("config_size", len(configData)).
		Msg("Wrote generated configuration")

	return &IntegrationResult{
		ConfigPath:   configPath,
		ConfigData:   configData,
		SPIFFEID:     b.GetSPIFFEID(),
		Package:      b.GetPackage(),
		Bootstrapper: b,
	}, nil
}

// getConfigKeyForComponent returns the config key for each component type.
func getConfigKeyForComponent(componentType models.EdgeOnboardingComponentType) string {
	switch componentType {
	case models.EdgeOnboardingComponentTypePoller:
		return "poller.json"
	case models.EdgeOnboardingComponentTypeAgent:
		return "agent.json"
	case models.EdgeOnboardingComponentTypeChecker:
		return "checker.json"
	case models.EdgeOnboardingComponentTypeNone:
		return defaultServiceConfigFile
	default:
		return defaultServiceConfigFile
	}
}

// writeGeneratedConfig writes the generated config to a file in the storage path.
func writeGeneratedConfig(componentType models.EdgeOnboardingComponentType, data []byte, storagePath string) (string, error) {
	// Create config directory
	configDir := filepath.Join(storagePath, "config")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return "", fmt.Errorf("create config directory: %w", err)
	}

	// Determine filename
	var filename string
	switch componentType {
	case models.EdgeOnboardingComponentTypePoller:
		filename = "poller.json"
	case models.EdgeOnboardingComponentTypeAgent:
		filename = "agent.json"
	case models.EdgeOnboardingComponentTypeChecker:
		filename = "checker.json"
	case models.EdgeOnboardingComponentTypeNone:
		filename = defaultServiceConfigFile
	default:
		filename = defaultServiceConfigFile
	}

	configPath := filepath.Join(configDir, filename)

	// Write config file
	if err := os.WriteFile(configPath, data, 0644); err != nil {
		return "", fmt.Errorf("write config file: %w", err)
	}

	return configPath, nil
}

// LoadConfigFromOnboarding loads the generated configuration into a target struct.
// This is a helper for services that need to unmarshal the config.
func LoadConfigFromOnboarding(result *IntegrationResult, target interface{}) error {
	if result == nil {
		return ErrIntegrationResultNil
	}

	if err := json.Unmarshal(result.ConfigData, target); err != nil {
		return fmt.Errorf("unmarshal config: %w", err)
	}

	return nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

// GetSPIREWorkloadAPISocket returns the path to the SPIRE workload API socket.
// This is useful for services that need to configure SPIRE client.
func GetSPIREWorkloadAPISocket(result *IntegrationResult) string {
	if result == nil || result.Bootstrapper == nil {
		return ""
	}

	socketData, ok := result.Bootstrapper.GetConfig("spire-workload-api-socket")
	if !ok {
		return ""
	}

	return string(socketData)
}
