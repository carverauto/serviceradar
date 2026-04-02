# Local Docker Build and Push

This guide shows how to build and publish ServiceRadar Docker images locally for
the Docker Compose stack now that images are hosted in Harbor at
`registry.carverauto.dev`.

## Quick Start

### 1. Authenticate to Harbor

Use a Harbor robot account or a Harbor user with push access:

```bash
export HARBOR_ROBOT_USERNAME='robot$serviceradar-ci'
export HARBOR_ROBOT_SECRET='<harbor-secret>'
./scripts/docker-login.sh
```

You can also pass credentials directly:

```bash
./scripts/docker-login.sh \
  --username 'robot$serviceradar-ci' \
  --token '<harbor-secret>'
```

### 2. Build Images Locally

Build all supported compose images for your current platform:

```bash
./scripts/build-images.sh --local --tag local
```

Build a subset:

```bash
./scripts/build-images.sh --local --tag local core web agent-gateway agent
```

### 3. Push Images to Harbor

Push a tagged build:

```bash
./scripts/build-images.sh --push --tag sha-$(git rev-parse HEAD)
```

### 4. Run the Compose Stack Against That Tag

```bash
export APP_TAG=sha-$(git rev-parse HEAD)
export ARANCINI_TAG=latest
docker compose pull
docker compose up -d --force-recreate
```

## Common Commands

Show script help:

```bash
./scripts/build-images.sh --help
```

Build all images for amd64:

```bash
./scripts/build-images.sh --platform-amd64 --push --tag sha-$(git rev-parse HEAD)
```

Build all images for arm64:

```bash
./scripts/build-images.sh --platform-arm64 --push --tag sha-$(git rev-parse HEAD)
```

Build a named group:

```bash
./scripts/build-images.sh --group core --local --tag local
```

Build without cache:

```bash
./scripts/build-images.sh --local --no-cache --tag local
```

## Image Naming

Compose pulls ServiceRadar images from:

- `registry.carverauto.dev/serviceradar/serviceradar-core-elx:<tag>`
- `registry.carverauto.dev/serviceradar/serviceradar-web-ng:<tag>`
- `registry.carverauto.dev/serviceradar/serviceradar-agent-gateway:<tag>`
- `registry.carverauto.dev/serviceradar/arancini:<tag>`

Typical tags are:

- `latest`
- `sha-<git-sha>`
- release tags published by the release workflow

## Verification

Verify Harbor authentication:

```bash
docker login registry.carverauto.dev
docker manifest inspect registry.carverauto.dev/serviceradar/serviceradar-core-elx:latest
```

Verify your compose tag resolves:

```bash
docker manifest inspect registry.carverauto.dev/serviceradar/serviceradar-core-elx:${APP_TAG:-latest}
docker manifest inspect registry.carverauto.dev/serviceradar/arancini:${ARANCINI_TAG:-latest}
```

## Troubleshooting

If login fails:

```bash
echo "$HARBOR_ROBOT_SECRET" | \
  docker login registry.carverauto.dev -u "$HARBOR_ROBOT_USERNAME" --password-stdin
```

If a push fails, confirm the target tag and repository:

```bash
./scripts/build-images.sh --help
```

If Compose still uses an older image:

```bash
docker compose pull
docker compose up -d --force-recreate
docker compose ps
```

## Bazel Alternative

If you want to publish the official OCI images the same way CI does, use Bazel:

```bash
bazel run --config=remote_push //docker/images:push_all
```

That publishes the Harbor-hosted images used by the default Compose stack.
