## ADDED Requirements

### Requirement: Docker Compose includes Dgraph
The Docker Compose stack SHALL start Dgraph with ACL enabled and apply the topology schema so local topology projection does not require a Kubernetes cluster.

#### Scenario: Dgraph becomes healthy on clean boot
- **WHEN** a user removes compose volumes and runs `docker compose up -d`
- **THEN** the Dgraph service becomes healthy within the expected startup window
- **AND** the schema-migration one-shot applies the topology schema
- **AND** no manual Dgraph steps are required

#### Scenario: ACL secret is generated once
- **GIVEN** a clean Docker Compose environment with no Dgraph ACL secret
- **WHEN** the stack performs bootstrap
- **THEN** it generates unique ACL material for Dgraph
- **AND** those values are persisted for reuse on restart
