## Context
ServiceRadar publishes a custom CNPG-compatible Postgres image with extension support required by platform workloads. The image is built via Bazel and consumed by Helm/Kubernetes and Docker Compose flows. PostGIS must be added without regressing existing TimescaleDB/AGE/pg_trgm behavior.

## Goals / Non-Goals
- Goals:
- Add PostGIS to the CNPG custom image built by Bazel.
- Ensure Helm and Docker Compose deployments consume the updated image and initialize PostGIS consistently.
- Define verification commands for extension availability after deployment.
- Non-Goals:
- Introduce new geospatial application features in this change.
- Replace existing TimescaleDB/AGE/pg_trgm initialization behavior.

## Decisions
- Decision: Keep a single CNPG custom image that bundles all required extensions (TimescaleDB, AGE, pg_trgm, PostGIS).
- Alternatives considered: Separate image variants per environment; rejected to avoid tag drift and operational inconsistency.
- Decision: Manage extension enablement through existing migration/bootstrap pathways rather than ad-hoc manual SQL.
- Alternatives considered: Manual post-deploy `psql` steps; rejected because they are error-prone and non-repeatable.

## Risks / Trade-offs
- Package compatibility risk between PostGIS and the base Postgres/CNPG version.
  - Mitigation: Pin package versions in Bazel image build inputs and validate with container smoke checks.
- Startup regression risk in Compose/Helm if bootstrap SQL ordering changes.
  - Mitigation: Keep existing extension init order stable and add explicit health/extension verification checks.

## Migration Plan
1. Add PostGIS packages/artifacts to CNPG Bazel image build and publish a new image tag.
2. Update Helm and Kubernetes manifests to reference the new tag and include PostGIS in extension bootstrap SQL where applicable.
3. Update Docker Compose bootstrap flow so clean startup enables PostGIS automatically.
4. Run smoke checks (`CREATE EXTENSION`, `SELECT postgis_full_version()`) in both Helm and Compose environments.

## Open Questions
- Should PostGIS be created in every application database by default, or only in databases used by geospatial features?
