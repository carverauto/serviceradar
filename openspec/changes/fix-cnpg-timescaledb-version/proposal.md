# Change: Fix CNPG TimescaleDB Version Mismatch

## Why
The cnpg:16.6.0-sr2 image was built 10 months ago (February 2025) with old TimescaleDB code, but the BUILD.bazel forcibly overrides the version string to `2.24.0-dev`. This causes a bug in `retention_api.c:199` where the assertion `list_length(jobs) == 1` fails during `add_retention_policy()` calls, crashing postgres with SIGABRT. This prevents fresh docker-compose deployments from completing database migrations.

## What Changes
- Remove the version override hack in `docker/images/BUILD.bazel` that forces `version = 2.24.0-dev`
- Rebuild cnpg image using the actual TimescaleDB 2.24.0 stable release (already specified in MODULE.bazel)
- Publish new image tag `16.6.0-sr3` with proper TimescaleDB 2.24.0
- Update docker-compose.yml to use the new image tag

## Impact
- Affected specs: `cnpg`
- Affected code:
  - `docker/images/BUILD.bazel:1557-1561` - Remove version.config override
  - `docker-compose.yml:16` - Update image tag
  - `docker-compose.podman.yml:16` - Update image tag
  - `k8s/` manifests - Update cnpg image references

## Root Cause Analysis
1. MODULE.bazel downloads TimescaleDB 2.24.0 stable source
2. BUILD.bazel:1558-1561 overwrites `version.config` to say `2.24.0-dev`
3. The cnpg:16.6.0-sr2 image in GHCR was built February 2025 with OLD TimescaleDB code
4. The image has never been rebuilt with current source
5. The old code has a bug in retention policy creation that crashes postgres
6. K8s works because the database was initialized earlier; docker-compose fails on fresh init

## Evidence
- Error: `TRAP: failed Assert("list_length(jobs) == 1"), File: "retention_api.c", Line: 199`
- Image build date: `2025-02-10T00:17:10Z`
- TimescaleDB 2.24.0 release date: `2025-12-03`
- Both k8s and local show `extversion = 2.24.0-dev` but k8s has pre-existing retention policies
