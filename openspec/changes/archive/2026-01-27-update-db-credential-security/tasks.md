## 1. Implementation
- [x] 1.1 Inventory current Postgres credentials and exposure defaults across Helm, Kustomize, and Docker Compose.
- [x] 1.2 Update Helm CNPG bootstrap to generate and persist random passwords for `postgres`, `serviceradar`, and `spire` when not supplied.
- [x] 1.3 Add Docker Compose credential bootstrap (volume-backed) and wire CNPG + app services to read passwords from files.
- [x] 1.4 Default CNPG Docker Compose binding to loopback and document explicit opt-in for public access.
- [x] 1.5 Update docs/runbooks to describe credential storage, rotation boundaries, and recovery steps.
- [x] 1.6 Add smoke checks for Compose and Helm rendering to confirm secrets and bindings are correct.
