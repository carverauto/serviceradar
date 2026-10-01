## ADDED Requirements

### Requirement: Cold archival reports its telemetry backend scope
The cold tier SHALL archive CNPG chunks only and report warehouse archival as
unavailable for each cold-tier registry dataset when StarRocks is enabled and
cold archival is intended. A successful historical CNPG export MUST NOT report
warehouse telemetry as archived.

#### Scenario: Cold archival configured in the shipped core release
- **WHEN** an operator supplies the documented cold-tier settings to core-elx
- **THEN** its runtime configuration activates the existing CNPG archival contract
- **AND** its maintenance scheduler registers the exporter and pruner
- **AND** incomplete intended settings still produce per-dataset backend reporting
- **AND** absent settings leave archive work disabled by default

#### Scenario: Warehouse telemetry with historical CNPG data
- **WHEN** StarRocks is enabled and the cold tier is fully configured
- **THEN** cold-tier mode is `cnpg_backfill`, exporting historical CNPG chunks
- **AND** the backend health check reports warehouse archival unavailable per dataset
- **AND** verified export and acknowledged boundary checks still gate CNPG drops

#### Scenario: Backend switch with undrained cold history
- **WHEN** StarRocks is enabled and CNPG cold backfill is disabled with boundary residue
- **THEN** the residue retention fence remains active
- **AND** the operator must complete the existing two-phase disable explicitly
