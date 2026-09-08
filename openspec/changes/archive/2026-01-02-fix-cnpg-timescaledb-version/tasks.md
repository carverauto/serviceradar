# Tasks: Fix CNPG TimescaleDB Version

## 1. Remove Version Override
- [x] 1.1 Remove `version.config` override in `docker/images/BUILD.bazel:1557-1561`
- [x] 1.2 Let TimescaleDB build use its native version from source (2.24.0)
- [x] 1.3 Verify bazel build still works: `bazel build //docker/images:cnpg_image_amd64`

## 2. Rebuild CNPG Image
- [x] 2.1 Build new cnpg image: `bazel build //docker/images:cnpg_image_amd64`
- [x] 2.2 Tag image as `16.6.0-sr3`
- [x] 2.3 Test image locally with docker-compose
- [x] 2.4 Verify TimescaleDB reports version `2.24.0` (not `2.24.0-dev`)
- [x] 2.5 Push to ghcr.io: `ghcr.io/carverauto/serviceradar-cnpg:16.6.0-sr3@sha256:882fdd3f4905342a6ffa347ee988840eafa4f8e8b234a26e6e8cb72ec71b8eb8`

## 3. Update References
- [x] 3.1 Update `docker-compose.yml` image tag to `16.6.0-sr3`
- [x] 3.2 Update Compose image tag to `16.6.0-sr3`
- [x] 3.3 Update k8s manifests (`k8s/demo/base/spire/cnpg-cluster.yaml`, `k8s/srql-fixtures/cnpg-cluster.yaml`)
- [x] 3.4 Update helm chart (`helm/serviceradar/values.yaml`)
- [x] 3.5 Update Dockerfiles (`docker/Dockerfile.rbe`, `docker/Dockerfile.rbe-ora9`)
- [x] 3.6 Update bazel push targets (`docker/images/push_targets.bzl`)
- [x] 3.7 Update local container startup scripts
- [x] 3.8 Update documentation (`docs/docs/agents.md`, `k8s/srql-fixtures/README.md`)

## 4. Validation
- [x] 4.1 Fresh `docker compose down -v && docker compose up -d` succeeds
- [x] 4.2 Core migrations complete without crashes
- [x] 4.3 All 22 retention policies are created successfully
- [x] 4.4 `SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'policy_retention'` shows all policies
- [x] 4.5 Stack healthchecks pass for all services

## Completion Summary
- **Image SHA**: `sha256:882fdd3f4905342a6ffa347ee988840eafa4f8e8b234a26e6e8cb72ec71b8eb8`
- **TimescaleDB Version**: 2.24.0 (stable, released Dec 3, 2025)
- **Retention Policies**: 22 created successfully
- **All services healthy**: Verified via `docker compose ps`
