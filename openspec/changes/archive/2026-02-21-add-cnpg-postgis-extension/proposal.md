# Change: Add PostGIS to custom CNPG image and deployment configs

## Why
ServiceRadar now needs geospatial SQL capabilities from PostGIS, but the current custom CNPG image only bundles TimescaleDB, Apache AGE, and pg_trgm. PostGIS must be added in a repeatable way across Bazel image builds and all deployment paths.

## What Changes
- Update the Bazel-built custom CNPG image to include PostGIS binaries and extension control/sql files alongside TimescaleDB, Apache AGE, and pg_trgm.
- Update Helm and Kubernetes CNPG configuration to use the new image tag and bootstrap PostGIS where extensions are initialized.
- Update Docker Compose CNPG/bootstrap configuration to ensure PostGIS is enabled on clean stack startup.
- Add validation steps and documentation updates for extension availability checks.

## Impact
- Affected specs: `cnpg`, `docker-compose-stack`
- Affected code: `docker/images/*` CNPG image build targets, Helm chart values/templates, Docker Compose CNPG/bootstrap configs, deployment/runbook docs
