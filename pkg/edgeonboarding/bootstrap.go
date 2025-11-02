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
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	// ErrConfigRequired is returned when no config is provided.
	ErrConfigRequired = errors.New("config is required")
	// ErrTokenRequired is returned when no onboarding token is provided.
	ErrTokenRequired = errors.New("onboarding token is required")
	// ErrKVEndpointRequired is returned when no KV endpoint is provided (bootstrap config or integration).
	ErrKVEndpointRequired = errors.New("KV endpoint is required")
	// ErrCredentialRotationNotImplemented is returned when credential rotation is attempted.
	ErrCredentialRotationNotImplemented = errors.New("not implemented: credential rotation")
	// ErrRotationInfoNotImplemented is returned when rotation info is requested.
	ErrRotationInfoNotImplemented = errors.New("not implemented: rotation info")
)

// Config contains all parameters needed for edge service onboarding.
// This is the client-side configuration for edge services (poller, agent, checker)
// to bootstrap themselves from an onboarding token.
type Config struct {
	// Token is the onboarding/download token from the package
	Token string

	// CoreEndpoint is the Core service gRPC endpoint (optional: auto-discovered from package)
	// Format: "host:port" e.g., "23.138.124.18:50052"
	CoreEndpoint string

	// KVEndpoint is the KV service (datasvc) gRPC endpoint
	// This is a sticky/bootstrap config - must be provided as we need it to fetch dynamic config
	// Format: "host:port" e.g., "23.138.124.23:50057"
	KVEndpoint string

	// ServiceType identifies what type of service is being onboarded
	ServiceType models.EdgeOnboardingComponentType

	// ServiceID is an optional readable name override for the service
	// If not provided, will use the component_id from the package
	ServiceID string

	// StoragePath is where to persist configuration and credentials
	// Default: "/var/lib/serviceradar" or "./data" for non-root
	StoragePath string

	// DeploymentType specifies the deployment environment
	// Values: "docker", "kubernetes", "bare-metal"
	// If empty, will auto-detect
	DeploymentType DeploymentType

	// Logger is optional; if nil, a default logger will be created
	Logger logger.Logger
}

// DeploymentType represents the environment where the service is running.
type DeploymentType string

const (
	DeploymentTypeDocker     DeploymentType = "docker"
	DeploymentTypeKubernetes DeploymentType = "kubernetes"
	DeploymentTypeBareMetal  DeploymentType = "bare-metal"
)

// Bootstrapper handles the complete onboarding flow for edge services.
type Bootstrapper struct {
	cfg    *Config
	logger logger.Logger

	// State from onboarding process
	pkg              *models.EdgeOnboardingPackage
	downloadResult   *models.EdgeOnboardingDeliverResult
	deploymentType   DeploymentType
	generatedConfigs map[string][]byte
}

// NewBootstrapper creates a new bootstrapper instance.
func NewBootstrapper(cfg *Config) (*Bootstrapper, error) {
	if cfg == nil {
		return nil, ErrConfigRequired
	}

	if cfg.Token == "" {
		return nil, ErrTokenRequired
	}

	if cfg.KVEndpoint == "" {
		return nil, ErrKVEndpointRequired
	}

	log := cfg.Logger
	if log == nil {
		log = logger.NewTestLogger()
	}

	// Set defaults
	if cfg.StoragePath == "" {
		cfg.StoragePath = detectDefaultStoragePath()
	}

	b := &Bootstrapper{
		cfg:              cfg,
		logger:           log,
		generatedConfigs: make(map[string][]byte),
	}

	return b, nil
}

// Bootstrap executes the complete onboarding process.
// Steps:
// 1. Download package from Core using token
// 2. Validate and extract package contents
// 3. Configure SPIRE (nested server for poller, workload API for others)
// 4. Auto-register with Core via database (update edge_packages table)
// 5. Generate service config based on deployment type
// 6. Set up credential rotation
// 7. Return ready-to-use config
func (b *Bootstrapper) Bootstrap(ctx context.Context) error {
	b.logger.Info().Msg("Starting edge service onboarding")

	// Step 1: Detect deployment type
	if err := b.detectDeploymentType(ctx); err != nil {
		return fmt.Errorf("detect deployment type: %w", err)
	}

	b.logger.Info().
		Str("deployment_type", string(b.deploymentType)).
		Str("storage_path", b.cfg.StoragePath).
		Msg("Detected deployment environment")

	// Step 2: Download package from Core
	if err := b.downloadPackage(ctx); err != nil {
		return fmt.Errorf("download package: %w", err)
	}

	b.logger.Info().
		Str("package_id", b.pkg.PackageID).
		Str("component_id", b.pkg.ComponentID).
		Str("component_type", string(b.pkg.ComponentType)).
		Msg("Successfully downloaded onboarding package")

	// Step 3: Validate package
	if err := b.validatePackage(ctx); err != nil {
		return fmt.Errorf("validate package: %w", err)
	}

	// Step 4: Configure SPIRE credentials
	if err := b.configureSPIRE(ctx); err != nil {
		return fmt.Errorf("configure SPIRE: %w", err)
	}

	b.logger.Info().
		Str("spiffe_id", b.pkg.DownstreamSPIFFEID).
		Msg("Successfully configured SPIRE credentials")

	// Step 5: Generate service configuration
	if err := b.generateServiceConfig(ctx); err != nil {
		return fmt.Errorf("generate service config: %w", err)
	}

	// Step 6: Mark package as activated (Core will update status)
	if err := b.markActivated(ctx); err != nil {
		b.logger.Warn().Err(err).Msg("Failed to mark package as activated (non-fatal)")
	}

	b.logger.Info().Msg("Edge service onboarding completed successfully")

	return nil
}

// GetConfig returns the generated configuration for a specific file/key.
func (b *Bootstrapper) GetConfig(key string) ([]byte, bool) {
	data, ok := b.generatedConfigs[key]
	return data, ok
}

// GetPackage returns the downloaded package information.
func (b *Bootstrapper) GetPackage() *models.EdgeOnboardingPackage {
	return b.pkg
}

// GetSPIFFEID returns the assigned SPIFFE ID for this service.
func (b *Bootstrapper) GetSPIFFEID() string {
	if b.pkg == nil {
		return ""
	}
	return b.pkg.DownstreamSPIFFEID
}

// GetJoinToken returns the SPIRE join token (only available before SPIRE is configured).
func (b *Bootstrapper) GetJoinToken() string {
	if b.downloadResult == nil {
		return ""
	}
	return b.downloadResult.JoinToken
}

// Rotate handles SPIRE credential rotation.
// This should be called periodically (e.g., via cron or goroutine).
func Rotate(ctx context.Context, storagePath string, log logger.Logger) error {
	if log == nil {
		log = logger.NewTestLogger()
	}

	log.Info().
		Str("storage_path", storagePath).
		Msg("Starting SPIRE credential rotation")

	// TODO: Implement rotation logic
	// This will involve:
	// 1. Reading current SPIRE state
	// 2. Checking if rotation is needed (TTL expiration)
	// 3. Requesting new credentials from upstream SPIRE
	// 4. Updating local SPIRE configuration
	// 5. Restarting/reloading SPIRE agent/server

	return ErrCredentialRotationNotImplemented
}

// detectDefaultStoragePath determines the best storage path based on permissions.
func detectDefaultStoragePath() string {
	// Try /var/lib/serviceradar first (requires root)
	// Fall back to ./data for non-root
	// TODO: Implement proper detection logic
	return "/var/lib/serviceradar"
}

// GetAllConfigs returns all generated configuration files.
func (b *Bootstrapper) GetAllConfigs() map[string][]byte {
	result := make(map[string][]byte, len(b.generatedConfigs))
	for k, v := range b.generatedConfigs {
		result[k] = v
	}
	return result
}

// GetCoreEndpoint returns the Core service endpoint.
func (b *Bootstrapper) GetCoreEndpoint() string {
	if b.cfg.CoreEndpoint != "" {
		return b.cfg.CoreEndpoint
	}
	// TODO: Extract from package metadata
	return ""
}

// GetKVEndpoint returns the KV service endpoint.
func (b *Bootstrapper) GetKVEndpoint() string {
	return b.cfg.KVEndpoint
}

// RotationInfo contains information about credential rotation status.
type RotationInfo struct {
	LastRotation  time.Time
	NextRotation  time.Time
	RotationCount int64
	Healthy       bool
	Error         string
}

// GetRotationInfo returns the current rotation status.
func GetRotationInfo(storagePath string) (*RotationInfo, error) {
	// TODO: Implement rotation info retrieval
	// This will read rotation state from storage
	return nil, ErrRotationInfoNotImplemented
}
