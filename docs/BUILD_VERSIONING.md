# Build Versioning and Build ID System

## Overview

The ServiceRadar build system now supports flexible versioning and build ID tracking. This allows for consistent versioning across all components and unique build identification for debugging and tracking purposes.

## Version Management

Versions are managed through a single `VERSION` file in the repository root. The build system reads versions in this priority order:

1. **Command-line flag**: `--version=1.0.52`
2. **Environment variable**: `VERSION=1.0.52`
3. **VERSION file**: Automatically read from repository root

The version is centrally managed - no need to update `packaging/components.json` for each release.

## Build ID Management

Build IDs help track specific builds and are displayed in the web UI. They can be:

1. **Auto-generated**: Format `DDHHMM` + 2-char git hash (e.g., `102141f6`)
2. **Specified via flag**: `--build-id=ci-build-123`
3. **Specified via environment**: `BUILD_ID=ci-build-123`

## Usage Examples

### Individual Build (Development)
```bash
# Uses VERSION file, auto-generates unique build ID
./scripts/setup-package.sh --type=deb core

# Override version from command line
./scripts/setup-package.sh --type=deb --version=1.0.53 core

# With explicit build ID
./scripts/setup-package.sh --type=deb --build-id=dev-001 core
```

### CI/CD Build
```bash
# Version from VERSION file, build ID from CI
export BUILD_ID="ci-${CI_PIPELINE_ID}"
./scripts/setup-package.sh --type=deb --all

# Or let CI read version from file
VERSION=$(cat VERSION)
BUILD_ID="${CI_PIPELINE_ID}-${CI_PIPELINE_IID}"
./scripts/setup-package.sh --type=deb --all
```

### Version Bumping
```bash
# Bump patch version (1.0.52 -> 1.0.53)
./scripts/bump-version.sh patch

# Bump minor version (1.0.52 -> 1.1.0)
./scripts/bump-version.sh minor

# Set specific version
./scripts/bump-version.sh 1.2.0
```

## Web UI Display

The version and build ID are displayed at the bottom of the sidebar in the web UI:
- Version: 1.0.53
- Build: 102141f6

The web UI reads this information from:
1. `/build-info.json` (automatically created during web component build)
2. Environment variables `NEXT_PUBLIC_VERSION` and `NEXT_PUBLIC_BUILD_ID` (fallback)

## Build ID in Binaries

For Go binaries, the version and build ID are embedded via ldflags into the `pkg/version` package:
```go
import "github.com/carverauto/serviceradar/pkg/version"

fmt.Printf("Version: %s\n", version.GetFullVersion())
// Output: 1.0.53 (build: 102141f6)
```

## CI/CD Integration

For CI/CD pipelines, the VERSION file is the source of truth:

```yaml
steps:
  - name: Read version
    run: echo "VERSION=$(cat VERSION)" >> $GITHUB_ENV
    
  - name: Build all packages
    env:
      BUILD_ID: ${{ github.run_id }}-${{ github.run_number }}
    run: ./scripts/setup-package.sh --type=deb --all
```

Or for GitLab CI:
```yaml
build:
  script:
    - export VERSION=$(cat VERSION)
    - export BUILD_ID="${CI_PIPELINE_ID}-${CI_PIPELINE_IID}"
    - ./scripts/setup-package.sh --type=deb --all
```

## Benefits

1. **Centralized Version Management**: No need to update versions in multiple places
2. **Build Traceability**: Each build has a unique ID for debugging
3. **CI/CD Friendly**: Environment variables work seamlessly with CI/CD systems
4. **User Visibility**: Version and build info displayed in web UI