## ADDED Requirements

### Requirement: SRQL metric backend routing
SRQL SHALL select the execution backend for metric entities by query window:
recent and aggregate windows resolve against CNPG (raw window or rollups), and
long-range or raw-history windows resolve against DuckDB over the Delta lakehouse.
Non-metric entities SHALL continue to resolve against CNPG unchanged. The SRQL
language and result shape SHALL be identical regardless of which backend executes.

#### Scenario: Recent metric query routes to CNPG
- **WHEN** an SRQL metric query requests a recent or aggregate window
- **THEN** SRQL SHALL execute it against CNPG (raw window or rollups)

#### Scenario: Long-range raw query routes to DuckDB over Delta
- **WHEN** an SRQL metric query requests raw points beyond the CNPG recent window
- **THEN** SRQL SHALL execute it against DuckDB over the Delta lakehouse
- **AND** the result shape SHALL match the equivalent CNPG-backed query

#### Scenario: Non-metric entity is unaffected
- **WHEN** an SRQL query targets a non-metric entity
- **THEN** SRQL SHALL execute it against CNPG exactly as before this change

### Requirement: Federated long-range metric graphing
SRQL SHALL return one coherent result set for a metric query whose window spans
both the CNPG recent window and the Delta history, federating the recent CNPG
rows and the historical Delta data in the query engine so the full range is
covered without a gap or duplication at the tier boundary.

#### Scenario: Query spans recent and historical tiers
- **GIVEN** a metric query whose time range covers both the CNPG recent window and older Delta history
- **WHEN** SRQL executes it
- **THEN** the result SHALL be a single coherent series spanning the full range
- **AND** there SHALL be no gap or duplication at the tier boundary
