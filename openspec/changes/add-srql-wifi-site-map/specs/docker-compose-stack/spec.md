## ADDED Requirements

### Requirement: Local-only WiFi-map validation with proprietary seed data

The Docker Compose development workflow SHALL support validating WiFi-map ingestion and UI behavior locally without loading proprietary customer seed data into shared demo or staging Kubernetes environments.

#### Scenario: WiFi-map seed data is tested locally
- **GIVEN** proprietary customer WiFi-map seed CSV files are available only on the developer workstation
- **WHEN** an engineer validates WiFi-map ingestion, SRQL queries, or UI behavior
- **THEN** they SHALL use the local Docker Compose CNPG-backed stack or an equivalent local-only database
- **AND** they SHALL NOT push the proprietary seed data into the Kubernetes `demo` namespace

#### Scenario: Faker data is absent during WiFi-map validation
- **GIVEN** the default Docker Compose stack is used for WiFi-map validation
- **WHEN** the local stack starts
- **THEN** dev-only faker services SHALL remain absent unless explicitly enabled by a dev overlay/profile
- **AND** any active faker overlay/profile SHALL be disabled before validating WiFi-map map density or device inventory counts

#### Scenario: CSV seed task targets local Compose CNPG
- **GIVEN** proprietary WiFi-map CSV seed files exist on a developer workstation
- **WHEN** an engineer runs the ServiceRadar WiFi-map CSV seed validation task against Docker Compose CNPG
- **THEN** the task SHALL support a dry-run mode that reports source file hashes and row counts without writing rows
- **AND** the task SHALL support an ingest mode that writes through the same core WiFi-map batch ingestor used by plugin results
- **AND** the task SHALL keep device inventory sync enabled by default unless the engineer explicitly disables it for a table-only test
