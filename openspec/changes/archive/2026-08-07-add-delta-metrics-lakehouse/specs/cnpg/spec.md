## ADDED Requirements

### Requirement: CNPG holds recent raw, rollups, and metadata, not long-term raw
Under tiered metric storage, CNPG SHALL retain a bounded recent window of raw
metric points plus the continuous-aggregate rollups, metadata, alerts, findings,
and capacity forecasts. CNPG SHALL NOT be the store of record for long-retention
raw metric history once the lakehouse path is in place and proven at parity.

#### Scenario: CNPG raw retention is bounded to the recent window
- **WHEN** tiered storage is enabled for a tenant
- **THEN** CNPG SHALL retain raw metric points only for the configured recent window
- **AND** rollups, metadata, alerts, findings, and capacity forecasts SHALL remain in CNPG

#### Scenario: Capacity forecasting still resolves from CNPG rollups
- **GIVEN** the CNPG raw window has been reduced
- **WHEN** capacity forecasting runs
- **THEN** it SHALL still resolve from the CNPG continuous-aggregate rollups
- **AND** it SHALL NOT depend on long-term raw points having stayed in CNPG
