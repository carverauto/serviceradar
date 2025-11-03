# Edge Onboarding Library

This package provides a common onboarding library for ServiceRadar edge services (pollers, agents, checkers) to automatically bootstrap themselves using an onboarding token.

## Overview

The edge onboarding library eliminates the need for manual shell scripts and configuration by providing a single, simple Bootstrap() call that handles the entire onboarding process.

### Design Philosophy

- **KV (datasvc) is the source of truth** - All dynamic configuration comes from KV, not ConfigMaps
- **Sticky bootstrap configs** - Only KV/Core addresses are in static config (chicken/egg problem)
- **Deployment-aware** - Automatically detects Docker, Kubernetes, or bare-metal and uses appropriate addresses
- **Component-specific** - Pollers get nested SPIRE server, agents/checkers use workload API
- **Self-contained** - Services only need an onboarding token to start

## Usage

### Basic Example

```go
package main

import (
	"context"
	"log"

	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/models"
)

func main() {
	// Create bootstrapper with minimal config
	b, err := edgeonboarding.NewBootstrapper(&edgeonboarding.Config{
		Token:      "your-onboarding-token-here",
		KVEndpoint: "23.138.124.23:50057", // Bootstrap config
		ServiceType: models.EdgeOnboardingComponentTypePoller,
	})
	if err != nil {
		log.Fatal(err)
	}

	// Run onboarding
	ctx := context.Background()
	if err := b.Bootstrap(ctx); err != nil {
		log.Fatal(err)
	}

	// Get generated configs
	pollerConfig, _ := b.GetConfig("poller.json")
	spireConfig, _ := b.GetConfig("spire-server.conf")

	log.Printf("SPIFFE ID: %s", b.GetSPIFFEID())
	log.Printf("Onboarding complete!")
}
```

### Docker Deployment Example

```bash
# Just set the onboarding token - everything else is automatic
docker run \
  -e ONBOARDING_TOKEN=abc123xyz456 \
  -e KV_ENDPOINT=23.138.124.23:50057 \
  ghcr.io/carverauto/serviceradar-poller:latest
```

## Architecture

### Onboarding Flow

1. **Deployment Detection**
   - Auto-detects: Docker, Kubernetes, or bare-metal
   - Determines appropriate addresses (LoadBalancer IPs for Docker, DNS for k8s)

2. **Package Download**
   - Downloads onboarding package from Core using token
   - Validates package contents and status
   - Extracts decrypted SPIRE credentials

3. **SPIRE Configuration**
   - **Pollers**: Set up nested SPIRE server with upstream attestation
   - **Agents**: Configure workload API access to poller's SPIRE
   - **Checkers**: Configure workload API access

4. **Service Configuration**
   - Generates component-specific config based on deployment type
   - Merges metadata from package (contains KV-sourced config)
   - Creates all required configuration files

5. **Registration**
   - Service automatically registers when it first connects
   - Core detects activation via SPIFFE ID in status reports

### Component Types

#### Poller
- Runs **nested SPIRE server** that attests to upstream (k8s) SPIRE
- Provides workload API for co-located agent
- Connects to Core and reports status
- Configuration includes: Core address, KV address, agent address, SPIRE config

#### Agent
- Uses **workload API** from parent poller's nested SPIRE
- Shares network namespace with poller (in Docker)
- Connects to KV to fetch checker configs
- Configuration includes: KV address, parent poller ID, workload API socket

#### Checker
- Uses **workload API** from parent agent
- Minimal configuration
- Configuration includes: Checker kind, parent agent ID, checker-specific config

### Deployment Types

#### Docker
- **Detection**: Checks for `/.dockerenv` or `docker` in cgroups
- **Addresses**: Uses LoadBalancer IPs (can't resolve k8s DNS)
- **SPIRE**: Nested server for pollers, shared workload API for agents
- **Network**: Agent shares network namespace with poller (`network_mode: "service:poller"`)

#### Kubernetes
- **Detection**: Checks for `KUBERNETES_SERVICE_HOST` or service account token
- **Addresses**: Uses service DNS names
- **SPIRE**: Uses k8s SPIRE controller and CRDs (automatic enrollment)
- **Note**: k8s deployments typically don't use this library - SPIFFE controller handles it

#### Bare Metal
- **Detection**: Default when not Docker or k8s
- **Addresses**: Uses configured addresses from package
- **SPIRE**: Same as Docker (nested server for pollers)
- **Network**: Standard networking

## Configuration

### Config Struct

```go
type Config struct {
	// Required
	Token      string                              // Onboarding token
	KVEndpoint string                              // KV (datasvc) address

	// Optional
	ServiceType     models.EdgeOnboardingComponentType // Auto-detected from package if not set
	ServiceID       string                              // Readable name override
	StoragePath     string                              // Default: /var/lib/serviceradar
	DeploymentType  DeploymentType                      // Auto-detected if not set
	CoreEndpoint    string                              // Auto-discovered from package
	Logger          logger.Logger                       // Default logger created if nil
}
```

### Sticky vs Dynamic Config

**Sticky (Bootstrap Config - Static File)**:
- KV endpoint address
- Core endpoint address (if not in package metadata)
- Storage path

**Dynamic (From KV - Fetched at Runtime)**:
- Checker configurations
- Known pollers list
- Service-specific settings
- Feature flags

### Environment Variables

Services can use these environment variables:

```bash
# Required
ONBOARDING_TOKEN=<token>      # From edge package
KV_ENDPOINT=<host:port>        # Bootstrap config

# Optional
STORAGE_PATH=/var/lib/serviceradar
DEPLOYMENT_TYPE=docker         # docker, kubernetes, bare-metal
SERVICE_ID=my-poller-1         # Override component ID
```

## Generated Configurations

The bootstrapper generates these configuration files/data:

### All Components
- `spire-workload-api-socket` - Path to workload API socket

### Pollers
- `poller.json` - Poller service configuration
- `spire-server.conf` - Nested SPIRE server config
- `spire-agent.conf` - Nested SPIRE agent config
- SPIRE trust bundle (`upstream-bundle.pem`)
- SPIRE join token (`upstream-join-token`)

### Agents
- `agent.json` - Agent service configuration
- Workload API socket path

### Checkers
- `checker.json` - Checker service configuration
- Checker-specific config from package

## API Reference

### NewBootstrapper

```go
func NewBootstrapper(cfg *Config) (*Bootstrapper, error)
```

Creates a new bootstrapper instance. Validates configuration and sets defaults.

### Bootstrap

```go
func (b *Bootstrapper) Bootstrap(ctx context.Context) error
```

Executes the complete onboarding process. Returns error if any step fails.

### GetConfig

```go
func (b *Bootstrapper) GetConfig(key string) ([]byte, bool)
```

Retrieves a specific generated configuration file by key.

### GetAllConfigs

```go
func (b *Bootstrapper) GetAllConfigs() map[string][]byte
```

Returns all generated configuration files.

### GetSPIFFEID

```go
func (b *Bootstrapper) GetSPIFFEID() string
```

Returns the assigned SPIFFE ID for this service.

### Rotate

```go
func Rotate(ctx context.Context, storagePath string, log logger.Logger) error
```

Handles SPIRE credential rotation. Should be called periodically (e.g., via cron).

## Implementation Status

### Completed ✅
- Package structure and interfaces
- Deployment type detection
- SPIRE configuration (structure)
- Service config generation
- Component-specific logic (poller, agent, checker)

### TODO 🔴
- Actual API calls to Core for package download
- Complete SPIRE HCL config generation
- Credential rotation implementation
- Integration tests
- Service integration (poller, agent, checker binaries)

## Example Integration

### In Poller Service

```go
package main

import (
	"context"
	"os"

	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/models"
)

func main() {
	token := os.Getenv("ONBOARDING_TOKEN")
	kvEndpoint := os.Getenv("KV_ENDPOINT")

	if token != "" {
		// Edge deployment - use onboarding
		b, err := edgeonboarding.NewBootstrapper(&edgeonboarding.Config{
			Token:       token,
			KVEndpoint:  kvEndpoint,
			ServiceType: models.EdgeOnboardingComponentTypePoller,
		})
		if err != nil {
			log.Fatal(err)
		}

		if err := b.Bootstrap(context.Background()); err != nil {
			log.Fatal(err)
		}

		// Use generated configs to start poller
		startPollerWithConfig(b.GetAllConfigs())
	} else {
		// k8s deployment - use traditional config
		startPollerWithStaticConfig()
	}
}
```

## Testing

### Unit Tests

```bash
go test ./pkg/edgeonboarding/...
```

### E2E Tests

```bash
# Create test package
./scripts/create-test-package.sh

# Run onboarding
go run ./cmd/test-onboarding/ --token <token>
```

## Related

- **Server-side**: `pkg/core/edge_onboarding.go` - Core service that creates packages
- **Models**: `pkg/models/edge_onboarding.go` - Shared data models
- **Database**: `pkg/db/edge_onboarding.go` - Database operations
- **Issues**: GitHub #1915, bd serviceradar-57

## Migration

For existing edge deployments using shell scripts:

1. Update to latest serviceradar version with onboarding library
2. Create onboarding package via UI or CLI
3. Set `ONBOARDING_TOKEN` and `KV_ENDPOINT` environment variables
4. Remove all shell scripts (`setup-edge-e2e.sh`, etc.)
5. Start service - onboarding happens automatically

## Support

For issues or questions:
- GitHub Issues: https://github.com/carverauto/serviceradar/issues
- Documentation: docs/edge-onboarding.md
