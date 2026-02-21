## 1. Implementation
- [x] 1.1 Update the Bazel CNPG image build to install/package PostGIS with the existing TimescaleDB/AGE/pg_trgm extension set.
- [ ] 1.2 Add or update CNPG image smoke checks to verify `CREATE EXTENSION postgis` and `SELECT postgis_full_version();` succeed.
- [x] 1.3 Update Helm chart values/templates and any Kubernetes CNPG manifests to use the new image and initialize PostGIS in extension bootstrap SQL.
- [x] 1.4 Update Docker Compose CNPG/bootstrap configuration so PostGIS is enabled during clean environment startup.
- [x] 1.5 Update deployment/runbook docs with PostGIS verification commands for Helm and Docker Compose.

## 2. Validation
- [x] 2.1 Run `openspec validate add-cnpg-postgis-extension --strict`.
- [x] 2.2 Run a CNPG image build and confirm the pushed image contains PostGIS extension files.
- [ ] 2.3 Perform one Helm-based smoke deploy and one Docker Compose smoke boot that confirm PostGIS is enabled.
