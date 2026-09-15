## ADDED Requirements

### Requirement: Compose default stays Timescale; archive storage is opt-in
The Docker Compose stack SHALL keep the default `docker compose up` path on the Timescale analytics-store driver with no analytics-head container. An opt-in profile SHALL start the analytics head plus either MinIO (S3 backend) or a bind-mounted data directory (filesystem backend) so hybrid dual writes and historical pg_duckdb queries can run locally. Enabling a profile alone SHALL NOT switch the storage mode.

#### Scenario: Default compose
- **WHEN** a user runs `docker compose up -d` without extra profiles
- **THEN** no analytics-head container and no MinIO requirement are introduced
- **AND** EventWriter continues to write hypertables

#### Scenario: Opt-in S3 profile
- **WHEN** the documented compose profile for pg_duckdb + MinIO is enabled with complete credentials
- **THEN** the analytics head starts
- **AND** a synthetic EventWriter batch can be queried from Timescale for a recent window and pg_duckdb for a historical window when hybrid is explicitly configured
