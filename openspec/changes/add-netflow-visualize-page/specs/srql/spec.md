## ADDED Requirements

### Requirement: SRQL Is The Only Data Source For NetFlow Visualize Widgets
All NetFlow Visualize charts and tables SHALL be backed by SRQL queries. The UI SHALL NOT execute Ecto queries to generate chart datasets.

#### Scenario: Visualize page executes SRQL for flow time-series
- **WHEN** the Visualize page needs data for a chart or table
- **THEN** it executes SRQL queries (for example `in:flows ...`)
- **AND** it does not run Ecto queries to generate chart datasets

### Requirement: Visualize UI State Does Not Overwrite Unsupported SRQL Queries
When a user provides an SRQL query that cannot be fully represented by the Visualize builder/state model, the UI SHALL preserve the raw query string and avoid overwriting it unless the user explicitly requests replacement.

#### Scenario: Builder preserves unsupported query
- **GIVEN** a user enters an SRQL query containing tokens not yet supported by the builder
- **WHEN** the Visualize page parses URL state or builder selections change
- **THEN** the raw query string is preserved and not overwritten automatically
