## ADDED Requirements

### Requirement: Compose default stays Timescale; pg_duckdb is an opt-in profile
The Docker Compose stack SHALL keep the default `docker compose up` path on the Timescale analytics-store driver with no analytics-head container. An opt-in profile SHALL start the analytics head plus either MinIO (S3 backend) or a bind-mounted data directory (filesystem backend) so the pg_duckdb write/query loop can run locally.

#### Scenario: Default compose
- **WHEN** a user runs `docker compose up -d` without extra profiles
- **THEN** no analytics-head container and no MinIO requirement are introduced
- **AND** EventWriter continues to write hypertables

#### Scenario: Opt-in S3 profile
- **WHEN** the documented compose profile for pg_duckdb + MinIO is enabled with complete credentials
- **THEN** the analytics head starts
- **AND** a synthetic EventWriter batch can be queried back via SRQL on the pg_duckdb driver
