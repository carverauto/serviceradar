## ADDED Requirements
### Requirement: Helm migration hook for tenant schemas
The Helm chart SHALL run public and tenant schema migrations via a hook job during install and upgrade, and fail the release if migrations fail.

#### Scenario: Helm upgrade runs migrations
- **GIVEN** a Helm upgrade is initiated
- **WHEN** the migration hook job runs
- **THEN** public and tenant migrations SHALL be applied before the new release completes
- **AND** the release SHALL fail if the job exits non-zero

#### Scenario: Migration hook can be disabled
- **GIVEN** migration hooks are disabled in Helm values
- **WHEN** a Helm upgrade is initiated
- **THEN** the migration job SHALL NOT be rendered
- **AND** operators MAY run migrations manually if needed
