# Change: Bootstrap CLOAK_KEY for platform deployments

## Why
Issue #2511 shows Docker Compose setting `CLOAK_KEY` to a blank string, which causes core-elx to crash with `Invalid CLOAK_KEY` and prevents the platform from starting. Helm and Kubernetes manifest installs also need consistent CLOAK_KEY generation so core/web never start with empty or placeholder values.

## What Changes
- Ensure Docker Compose deployments never prefer an empty `CLOAK_KEY` over the generated file-based key.
- Ensure Helm installations validate `cloak-key` in `serviceradar-secrets`, generate it when missing, and fail fast on invalid values.
- Ensure Kubernetes manifest installs (demo/base) validate `cloak-key`, generate it when missing, and fail fast on invalid values.
- Document how to override and persist `CLOAK_KEY` across upgrades.

## Impact
- Affected specs: bootstrap-secrets (new)
- Affected code: docker-compose.yml, helm secret generator job, k8s demo manifests, core/web runtime config and docs
