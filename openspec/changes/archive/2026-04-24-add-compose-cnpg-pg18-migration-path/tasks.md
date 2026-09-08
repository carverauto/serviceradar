## 1. Implementation

- [x] 1.1 Add Docker Compose CNPG major-version preflight and actionable error messaging.
- [x] 1.2 Add a supported Compose PG16-to-PG18 migration workflow for existing local CNPG volumes.
- [x] 1.3 Ensure the migration workflow preserves effective superuser/app credentials, including legacy installs without a persisted credential volume.
- [x] 1.4 Update Docker Compose docs and runbooks to point operators to the migration workflow.
- [x] 1.5 Validate the workflow against a seeded PG16 Docker volume and a successful PG18 post-migration startup.
