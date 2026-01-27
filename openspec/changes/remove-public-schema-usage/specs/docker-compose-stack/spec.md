## ADDED Requirements
### Requirement: Docker Compose migrations avoid public schema drift
A clean docker-compose boot SHALL complete without creating ServiceRadar tables in the `public` schema.

#### Scenario: Clean boot stays platform-only
- **WHEN** a user removes compose volumes and runs `docker compose up -d`
- **THEN** migrations create ServiceRadar tables in `platform`
- **AND** the `public` schema contains no ServiceRadar tables
