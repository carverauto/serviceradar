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
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/carverauto/serviceradar/pkg/models"
)

var errBootstrapperPackageNotInitialized = errors.New("bootstrapper package is not initialized")

// configureSPIRE sets up SPIRE credentials for the service.
// For pollers: Configures nested SPIRE server
// For agents/checkers: Configures SPIRE agent workload API access
func (b *Bootstrapper) configureSPIRE(ctx context.Context) error {
	b.logger.Info().
		Str("component_type", string(b.pkg.ComponentType)).
		Msg("Configuring SPIRE credentials")

	// Create SPIRE storage directories
	spireDir := filepath.Join(b.cfg.StoragePath, "spire")
	if err := os.MkdirAll(spireDir, 0755); err != nil {
		return fmt.Errorf("create spire directory: %w", err)
	}

	// Write trust bundle
	bundlePath := filepath.Join(spireDir, "upstream-bundle.pem")
	if err := os.WriteFile(bundlePath, b.downloadResult.BundlePEM, 0644); err != nil {
		return fmt.Errorf("write bundle PEM: %w", err)
	}

	b.logger.Debug().
		Str("bundle_path", bundlePath).
		Int("bundle_size", len(b.downloadResult.BundlePEM)).
		Msg("Wrote SPIRE trust bundle")

	// Component-specific configuration
	switch b.pkg.ComponentType {
	case models.EdgeOnboardingComponentTypePoller:
		return b.configurePollerSPIRE(ctx, spireDir)
	case models.EdgeOnboardingComponentTypeAgent:
		return b.configureAgentSPIRE(ctx, spireDir)
	case models.EdgeOnboardingComponentTypeChecker:
		return b.configureCheckerSPIRE(ctx, spireDir)
	case models.EdgeOnboardingComponentTypeNone:
		return fmt.Errorf("%w: %s", ErrUnsupportedComponentType, b.pkg.ComponentType)
	default:
		return fmt.Errorf("%w: %s", ErrUnsupportedComponentType, b.pkg.ComponentType)
	}
}

// configurePollerSPIRE configures nested SPIRE server for edge pollers.
// Pollers run their own SPIRE server that attests to the upstream (k8s) SPIRE server.
func (b *Bootstrapper) configurePollerSPIRE(ctx context.Context, spireDir string) error {
	_ = ctx

	b.logger.Debug().Msg("Configuring nested SPIRE server for poller")

	// Write join token (one-time use for initial attestation)
	tokenPath := filepath.Join(spireDir, "upstream-join-token")
	if err := os.WriteFile(tokenPath, []byte(b.downloadResult.JoinToken), 0600); err != nil {
		return fmt.Errorf("write join token: %w", err)
	}

	b.logger.Debug().
		Str("token_path", tokenPath).
		Msg("Wrote SPIRE join token")

	// Get SPIRE server address based on deployment type
	spireAddr, spirePort, err := b.getSPIREAddressesForDeployment()
	if err != nil {
		return fmt.Errorf("get SPIRE addresses: %w", err)
	}

	// Generate nested SPIRE server configuration
	serverConfig, err := b.generateNestedSPIREServerConfig(spireDir, spireAddr, spirePort)
	if err != nil {
		return fmt.Errorf("generate SPIRE server config: %w", err)
	}

	// Store config for later use
	b.generatedConfigs["spire-server.conf"] = serverConfig

	b.logger.Debug().
		Str("spire_address", spireAddr).
		Str("spire_port", spirePort).
		Msg("Generated nested SPIRE server configuration")

	// Generate nested SPIRE agent configuration (local agent for poller itself)
	agentConfig, err := b.generateNestedSPIREAgentConfig(spireDir)
	if err != nil {
		return fmt.Errorf("generate SPIRE agent config: %w", err)
	}

	b.generatedConfigs["spire-agent.conf"] = agentConfig

	b.logger.Debug().Msg("Generated nested SPIRE agent configuration")

	return nil
}

// configureAgentSPIRE configures SPIRE agent workload API access for agents.
// Agents connect to their parent poller's nested SPIRE server.
func (b *Bootstrapper) configureAgentSPIRE(ctx context.Context, spireDir string) error {
	_ = ctx

	b.logger.Debug().Msg("Configuring SPIRE agent workload API access")

	// For agents, we expect to be running in the same network namespace as the poller
	// So we access the poller's SPIRE agent socket directly

	// Store workload API socket path in config
	workloadAPIPath := filepath.Join(spireDir, "nested", "workload", "agent.sock")
	b.generatedConfigs["spire-workload-api-socket"] = []byte(workloadAPIPath)

	b.logger.Debug().
		Str("workload_api_socket", workloadAPIPath).
		Msg("Configured SPIRE workload API access")

	return nil
}

// configureCheckerSPIRE configures SPIRE access for checkers.
// Checkers also use the workload API, either from local agent or shared poller.
func (b *Bootstrapper) configureCheckerSPIRE(ctx context.Context, spireDir string) error {
	_ = ctx

	b.logger.Debug().Msg("Configuring SPIRE access for checker")

	// Similar to agents, checkers use workload API
	// TODO: Determine if checker has dedicated SPIRE agent or shares with agent/poller
	workloadAPIPath := filepath.Join(spireDir, "workload", "agent.sock")
	b.generatedConfigs["spire-workload-api-socket"] = []byte(workloadAPIPath)

	b.logger.Debug().
		Str("workload_api_socket", workloadAPIPath).
		Msg("Configured SPIRE workload API access for checker")

	return nil
}

// generateNestedSPIREServerConfig generates the SPIRE server configuration for nested server.
func (b *Bootstrapper) generateNestedSPIREServerConfig(spireDir, upstreamAddr, upstreamPort string) ([]byte, error) {
	if upstreamAddr == "" {
		return nil, ErrSPIREUpstreamAddressNotFound
	}
	if upstreamPort == "" {
		return nil, ErrSPIREUpstreamPortNotFound
	}
	// TODO: Generate actual SPIRE server config
	// This will be a HCL configuration file for SPIRE server
	// Key settings:
	// - Trust domain
	// - Upstream SPIRE server address
	// - Join token path
	// - Bundle path
	// - Data directory
	// - Socket path

	config := fmt.Sprintf(`# Generated SPIRE server configuration for nested server
# Component: %s
# SPIFFE ID: %s

server {
	bind_address = "0.0.0.0"
	bind_port = "8081"
	trust_domain = "%s"
	data_dir = "%s"
	socket_path = "%s"
	upstream_address = "%s"
	upstream_port = "%s"
}

# TODO: Add plugins configuration
# - DataStore (sqlite)
# - NodeAttestor (join_token)
# - KeyManager
# - UpstreamAuthority
`,
		b.pkg.ComponentID,
		b.pkg.DownstreamSPIFFEID,
		extractTrustDomain(b.pkg.DownstreamSPIFFEID),
		filepath.Join(spireDir, "server-data"),
		filepath.Join(spireDir, "server.sock"),
		upstreamAddr,
		upstreamPort,
	)

	return []byte(config), nil
}

// generateNestedSPIREAgentConfig generates the SPIRE agent configuration.
func (b *Bootstrapper) generateNestedSPIREAgentConfig(spireDir string) ([]byte, error) {
	if b.pkg == nil {
		return nil, errBootstrapperPackageNotInitialized
	}
	if b.pkg.DownstreamSPIFFEID == "" {
		return nil, ErrDownstreamSPIFFEIDEmpty
	}

	// TODO: Generate actual SPIRE agent config
	// This will be a HCL configuration file for SPIRE agent
	// Key settings:
	// - Trust domain
	// - Server address (local nested server)
	// - Data directory
	// - Socket path

	config := fmt.Sprintf(`# Generated SPIRE agent configuration
# Component: %s
# SPIFFE ID: %s

agent {
	data_dir = "%s"
	socket_path = "%s"
	trust_domain = "%s"
	server_address = "127.0.0.1"
	server_port = "8081"
}

# TODO: Add plugins configuration
# - NodeAttestor
# - KeyManager
# - WorkloadAttestor
`,
		b.pkg.ComponentID,
		b.pkg.DownstreamSPIFFEID,
		filepath.Join(spireDir, "agent-data"),
		"/run/spire/nested/workload/agent.sock",
		extractTrustDomain(b.pkg.DownstreamSPIFFEID),
	)

	return []byte(config), nil
}

// extractTrustDomain extracts the trust domain from a SPIFFE ID.
// Example: spiffe://carverauto.dev/ns/edge/poller-1 -> carverauto.dev
func extractTrustDomain(spiffeID string) string {
	// Remove spiffe:// prefix
	id := spiffeID
	if len(id) > 9 {
		id = id[9:] // Remove "spiffe://"
	}

	// Find first / and return everything before it
	if idx := len(id); idx > 0 {
		for i, c := range id {
			if c == '/' {
				return id[:i]
			}
		}
		return id
	}

	return "unknown"
}
