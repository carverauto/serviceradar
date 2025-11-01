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
	"fmt"
	"path/filepath"

	"github.com/carverauto/serviceradar/pkg/models"
)

// generateServiceConfig generates configuration files for the service based on:
// - Component type (poller, agent, checker)
// - Deployment type (docker, kubernetes, bare-metal)
// - Package metadata (contains service-specific config from KV)
func (b *Bootstrapper) generateServiceConfig(ctx context.Context) error {
	b.logger.Info().
		Str("component_type", string(b.pkg.ComponentType)).
		Str("deployment_type", string(b.deploymentType)).
		Msg("Generating service configuration")

	// Parse metadata from package
	metadata, err := b.parseMetadata()
	if err != nil {
		return fmt.Errorf("parse metadata: %w", err)
	}

	// Component-specific configuration
	switch b.pkg.ComponentType {
	case models.EdgeOnboardingComponentTypePoller:
		return b.generatePollerConfig(ctx, metadata)
	case models.EdgeOnboardingComponentTypeAgent:
		return b.generateAgentConfig(ctx, metadata)
	case models.EdgeOnboardingComponentTypeChecker:
		return b.generateCheckerConfig(ctx, metadata)
	default:
		return fmt.Errorf("unsupported component type: %s", b.pkg.ComponentType)
	}
}

// parseMetadata extracts and parses the metadata JSON from the package.
func (b *Bootstrapper) parseMetadata() (map[string]interface{}, error) {
	if b.pkg.MetadataJSON == "" {
		return make(map[string]interface{}), nil
	}

	var metadata map[string]interface{}
	if err := json.Unmarshal([]byte(b.pkg.MetadataJSON), &metadata); err != nil {
		return nil, fmt.Errorf("unmarshal metadata: %w", err)
	}

	return metadata, nil
}

// generatePollerConfig generates configuration for a poller service.
func (b *Bootstrapper) generatePollerConfig(ctx context.Context, metadata map[string]interface{}) error {
	b.logger.Debug().Msg("Generating poller configuration")

	// Extract required metadata fields
	coreAddress, ok := metadata["core_address"].(string)
	if !ok || coreAddress == "" {
		return fmt.Errorf("core_address not found in metadata")
	}

	coreSPIFFEID, ok := metadata["core_spiffe_id"].(string)
	if !ok || coreSPIFFEID == "" {
		return fmt.Errorf("core_spiffe_id not found in metadata")
	}

	spireUpstreamAddr, ok := metadata["spire_upstream_address"].(string)
	if !ok || spireUpstreamAddr == "" {
		return fmt.Errorf("spire_upstream_address not found in metadata")
	}

	spireParentID, ok := metadata["spire_parent_id"].(string)
	if !ok || spireParentID == "" {
		return fmt.Errorf("spire_parent_id not found in metadata")
	}

	agentSPIFFEID, ok := metadata["agent_spiffe_id"].(string)
	if !ok || agentSPIFFEID == "" {
		return fmt.Errorf("agent_spiffe_id not found in metadata")
	}

	// Get deployment-specific addresses
	coreAddr := b.getAddressForDeployment("core", coreAddress)
	kvAddr := b.getAddressForDeployment("kv", b.cfg.KVEndpoint)

	// Generate poller config JSON
	config := map[string]interface{}{
		"poller_id":   b.pkg.ComponentID,
		"label":       b.pkg.Label,
		"component_id": b.pkg.ComponentID,

		// Service endpoints
		"core_address": coreAddr,
		"kv_address":   kvAddr,

		// Agent configuration
		"agent_address": "localhost:50051", // Agent shares network namespace with poller

		// SPIFFE configuration
		"poller_spiffe_id": b.pkg.DownstreamSPIFFEID,
		"core_spiffe_id":   coreSPIFFEID,
		"agent_spiffe_id":  agentSPIFFEID,

		// SPIRE nested server configuration
		"spire_upstream_address": spireUpstreamAddr,
		"spire_parent_id":        spireParentID,

		// Storage paths
		"data_dir":   filepath.Join(b.cfg.StoragePath, "poller"),
		"spire_dir":  filepath.Join(b.cfg.StoragePath, "spire"),
		"config_dir": filepath.Join(b.cfg.StoragePath, "config"),

		// Deployment info
		"deployment_type": string(b.deploymentType),
		"site":            b.pkg.Site,
	}

	// Merge any additional metadata
	for k, v := range metadata {
		if _, exists := config[k]; !exists {
			config[k] = v
		}
	}

	// Serialize to JSON
	configJSON, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal poller config: %w", err)
	}

	b.generatedConfigs["poller.json"] = configJSON

	b.logger.Debug().
		Str("poller_id", b.pkg.ComponentID).
		Str("core_address", coreAddr).
		Str("kv_address", kvAddr).
		Msg("Generated poller configuration")

	return nil
}

// generateAgentConfig generates configuration for an agent service.
func (b *Bootstrapper) generateAgentConfig(ctx context.Context, metadata map[string]interface{}) error {
	b.logger.Debug().Msg("Generating agent configuration")

	// Get KV address for fetching checker configs
	kvAddr := b.getAddressForDeployment("kv", b.cfg.KVEndpoint)

	// Generate agent config JSON
	config := map[string]interface{}{
		"agent_id":     b.pkg.ComponentID,
		"label":        b.pkg.Label,
		"component_id": b.pkg.ComponentID,
		"parent_id":    b.pkg.ParentID, // Parent poller ID

		// Service endpoints
		"kv_address": kvAddr,

		// SPIFFE configuration
		"agent_spiffe_id": b.pkg.DownstreamSPIFFEID,

		// SPIRE workload API (from parent poller)
		"spire_workload_api_socket": "/run/spire/nested/workload/agent.sock",

		// Storage paths
		"data_dir":   filepath.Join(b.cfg.StoragePath, "agent"),
		"config_dir": filepath.Join(b.cfg.StoragePath, "config"),

		// Deployment info
		"deployment_type": string(b.deploymentType),
		"site":            b.pkg.Site,
	}

	// Merge any additional metadata
	for k, v := range metadata {
		if _, exists := config[k]; !exists {
			config[k] = v
		}
	}

	// Serialize to JSON
	configJSON, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal agent config: %w", err)
	}

	b.generatedConfigs["agent.json"] = configJSON

	b.logger.Debug().
		Str("agent_id", b.pkg.ComponentID).
		Str("parent_id", b.pkg.ParentID).
		Str("kv_address", kvAddr).
		Msg("Generated agent configuration")

	return nil
}

// generateCheckerConfig generates configuration for a checker service.
func (b *Bootstrapper) generateCheckerConfig(ctx context.Context, metadata map[string]interface{}) error {
	b.logger.Debug().Msg("Generating checker configuration")

	// Parse checker-specific config from package
	var checkerConfig map[string]interface{}
	if b.pkg.CheckerConfigJSON != "" {
		if err := json.Unmarshal([]byte(b.pkg.CheckerConfigJSON), &checkerConfig); err != nil {
			return fmt.Errorf("unmarshal checker config: %w", err)
		}
	} else {
		checkerConfig = make(map[string]interface{})
	}

	// Generate checker config JSON
	config := map[string]interface{}{
		"checker_id":   b.pkg.ComponentID,
		"checker_kind": b.pkg.CheckerKind,
		"label":        b.pkg.Label,
		"component_id": b.pkg.ComponentID,
		"parent_id":    b.pkg.ParentID, // Parent agent ID

		// SPIFFE configuration
		"checker_spiffe_id": b.pkg.DownstreamSPIFFEID,

		// SPIRE workload API
		"spire_workload_api_socket": "/run/spire/workload/agent.sock",

		// Checker-specific configuration
		"checker_config": checkerConfig,

		// Storage paths
		"data_dir": filepath.Join(b.cfg.StoragePath, "checker"),

		// Deployment info
		"deployment_type": string(b.deploymentType),
		"site":            b.pkg.Site,
	}

	// Merge any additional metadata
	for k, v := range metadata {
		if _, exists := config[k]; !exists {
			config[k] = v
		}
	}

	// Serialize to JSON
	configJSON, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal checker config: %w", err)
	}

	b.generatedConfigs["checker.json"] = configJSON

	b.logger.Debug().
		Str("checker_id", b.pkg.ComponentID).
		Str("checker_kind", b.pkg.CheckerKind).
		Str("parent_id", b.pkg.ParentID).
		Msg("Generated checker configuration")

	return nil
}
