## ADDED Requirements

### Requirement: SRQL resolves the storage target before SQL generation
SRQL SHALL accept compatible per-table storage configuration and resolve time ranges and cursor state before selecting postgres or duckdb SQL. Empty configuration SHALL preserve existing Timescale SQL. Hybrid recent queries SHALL retain the Timescale CAGG path; historical and cross-window queries SHALL aggregate over Parquet. Inventory and configuration entities SHALL always use the primary.

#### Scenario: Default translation
- **WHEN** no driver map is supplied
- **THEN** translation and execution retain their current postgres behavior

#### Scenario: Recent hybrid query
- **WHEN** the resolved lower bound is inside the configured hot window
- **THEN** the translation targets the primary
- **AND** eligible stats/downsample queries may use Timescale CAGGs

#### Scenario: Historical hybrid query
- **WHEN** any part of the requested range predates the hot window
- **THEN** the entire query targets the analytics head
- **AND** the SQL does not reference Timescale CAGGs

#### Scenario: Unsupported archive expression
- **WHEN** an archive query uses a construct that cannot be translated
- **THEN** it returns an explicit unsupported-query error without changing stores

### Requirement: Hybrid pagination pins the window and storage target
Hybrid listing cursors SHALL retain the absolute time window and selected store in signed cursor metadata. Continuations SHALL NOT silently change storage targets. A hot cursor whose window no longer fits the hot guarantee SHALL return an explicit expiration error. Existing non-hybrid cursor formats SHALL remain compatible.

#### Scenario: Relative-time pagination
- **WHEN** a relative-time hybrid query advances to the next page
- **THEN** the original absolute range and selected store are reused

#### Scenario: Hot cursor ages out
- **WHEN** a continuation's pinned hot range predates the current hot cutoff
- **THEN** the query reports cursor expiration rather than switching to the archive
