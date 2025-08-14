# Local Docker Build and Push

This guide shows how to build and push ServiceRadar Docker images locally without using CI/CD.

## Quick Start

### 1. Setup Authentication

First, create a GitHub Personal Access Token with `write:packages` scope:
1. Go to https://github.com/settings/tokens/new
2. Select `write:packages` scope
3. Copy the generated token

Then authenticate:

```bash
# Option 1: Using environment variables (recommended)
export GITHUB_USERNAME="your-username"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
make -f Makefile.docker docker-login

# Option 2: Using the script directly
./scripts/docker-login.sh --username your-username --token ghp_xxxxxxxxxxxx
```

### 2. Build and Push Images

```bash
# Build and push all images (interactive - prompts for tag)
make -f Makefile.docker docker-push

# Or use the script directly with specific tag
./scripts/build-and-push-docker.sh --all --push --tag v1.2.3
```

## Available Commands

### Make Targets

```bash
# Authentication
make -f Makefile.docker docker-login

# Build locally (no push)
make -f Makefile.docker docker-build
make -f Makefile.docker docker-build-core
make -f Makefile.docker docker-build-proton
make -f Makefile.docker docker-build-cert-gen

# Build and push
make -f Makefile.docker docker-push
```

### Direct Script Usage

```bash
# Show help
./scripts/build-and-push-docker.sh --help

# Build all images locally
./scripts/build-and-push-docker.sh --all --tag local

# Build and push specific image
./scripts/build-and-push-docker.sh --core --push --tag v1.2.3

# Build for specific platform
./scripts/build-and-push-docker.sh --all --platform linux/amd64

# Build without cache
./scripts/build-and-push-docker.sh --all --no-cache
```

## Examples

### Development Workflow

```bash
# 1. Make changes to code
# 2. Build images locally for testing
make -f Makefile.docker docker-build

# 3. Test locally
docker-compose up

# 4. If everything works, push to registry
make -f Makefile.docker docker-push
```

### Release Workflow

```bash
# 1. Login to GHCR
make -f Makefile.docker docker-login

# 2. Build and push release
./scripts/build-and-push-docker.sh --all --push --tag v1.2.3

# 3. Also tag as latest if this is a stable release
./scripts/build-and-push-docker.sh --all --push --tag latest
```

### Platform-Specific Builds

```bash
# Build only for x86_64
./scripts/build-and-push-docker.sh --all --platform linux/amd64 --tag local-amd64

# Build only for ARM64 (Apple Silicon)
./scripts/build-and-push-docker.sh --all --platform linux/arm64 --tag local-arm64

# Multi-platform (requires --push)
./scripts/build-and-push-docker.sh --all --push --platform linux/amd64,linux/arm64 --tag multi-arch
```

## Authentication Details

### Environment Variables

Set these for seamless authentication:

```bash
export GITHUB_USERNAME="your-github-username"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"
```

### Token Requirements

Your GitHub Personal Access Token needs:
- `write:packages` scope for pushing images
- `read:packages` scope for pulling private images (if needed)

### Checking Authentication

```bash
# Check if already logged in
docker system info | grep ghcr.io

# Test authentication
docker pull ghcr.io/carverauto/serviceradar-core:latest
```

## Image Naming

Images follow this naming convention:

- `ghcr.io/carverauto/serviceradar-core:TAG`
- `ghcr.io/carverauto/serviceradar-proton:TAG`
- `ghcr.io/carverauto/serviceradar-cert-generator:TAG`

Where TAG can be:
- `latest` - Latest stable release
- `develop` - Development builds
- `v1.2.3` - Specific version tags
- `local` - Local development builds

## Troubleshooting

### Build Issues

```bash
# Clean Docker buildx cache
docker buildx prune

# Recreate builder
docker buildx rm serviceradar-builder
./scripts/build-and-push-docker.sh --all
```

### Authentication Issues

```bash
# Re-login
./scripts/docker-login.sh

# Check token permissions
curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user
```

### Platform Issues

```bash
# Check available platforms
docker buildx inspect

# Build for current platform only
./scripts/build-and-push-docker.sh --all --platform linux/$(uname -m)
```

### Common Error Messages

**"authentication required"**
- Run `make -f Makefile.docker docker-login` first

**"platform not supported"**
- Use `--platform linux/amd64` for compatibility

**"denied: access forbidden"**
- Check token has `write:packages` scope
- Verify repository permissions

**"buildx builder not found"**
- Script will automatically create one, or run:
  ```bash
  docker buildx create --name serviceradar-builder --use
  ```

## Integration with CI/CD

The local scripts use the same structure as GitHub Actions, so images built locally are compatible with CI/CD builds. The main differences:

- **Local**: Uses `--load` for single-platform builds
- **CI/CD**: Uses `--push` for multi-platform builds
- **Local**: Interactive tag selection with make targets
- **CI/CD**: Automatic versioning based on git tags/branches

This ensures consistency between local development and automated builds.