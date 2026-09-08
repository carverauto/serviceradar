## ADDED Requirements

### Requirement: Attributed flows page supports investigation workflows

The web UI SHALL provide an attributed flows page that defaults to attributed
records, supports deterministic pagination, and avoids horizontal overflow by
rendering compact row summaries with details available through drill-down.

#### Scenario: Default attributed row view
- **GIVEN** an authenticated operator opens `/observability/flows/attributed`
- **WHEN** attributed and unmatched flow records both exist
- **THEN** the table shows attributed rows by default
- **AND** unmatched rows are available through an explicit filter
- **AND** the table fits common desktop widths without horizontal scrolling

#### Scenario: Paginated attributed rows
- **GIVEN** more attributed rows exist than fit on one page
- **WHEN** the operator navigates between pages
- **THEN** the page uses deterministic ordering so rows do not duplicate or vanish between adjacent pages unless new live data is intentionally applied

### Requirement: Attributed flows page supports controllable live updates

The attributed flows page SHALL provide a live update toggle comparable to the
observability logs live mode so operators can pause updates while investigating a
specific page or row.

#### Scenario: Live mode disabled
- **GIVEN** live mode is disabled
- **WHEN** new attributed flow records arrive
- **THEN** the current page, active filter, and selected row remain stable

#### Scenario: Live mode enabled
- **GIVEN** live mode is enabled
- **WHEN** new attributed flow records arrive
- **THEN** the page refreshes visible counts and rows without requiring a browser reload

### Requirement: Attributed flow controls are actionable

The attributed flows page SHALL make summary stat cards actionable filters and
SHALL allow row selection to open the underlying NetFlow flow details.

#### Scenario: Stat card filter
- **GIVEN** the page shows stat cards for attributed and unmatched records
- **WHEN** the operator clicks the attributed stat card
- **THEN** the table filters to attributed rows
- **AND** the active filter is visually indicated

#### Scenario: Row drill-down
- **GIVEN** an attributed flow row is visible
- **WHEN** the operator selects the row
- **THEN** the UI opens the corresponding NetFlow flow details without losing the current filter and page context

### Requirement: Attributed flow rows expose investigation context

Attributed flow rows SHALL include collecting agent provenance, endpoint labels
including reverse DNS when available, process/container summary, human-readable
bytes/packets, protocol, attribution status, and CTI/OTX indicator state.

#### Scenario: Enriched row display
- **GIVEN** an attributed flow has process context, agent identity, byte counts, and CTI hits
- **WHEN** the row is rendered
- **THEN** the row displays the agent, process/container summary, formatted bytes, protocol, attribution status, and CTI indicator
- **AND** reverse-DNS names are shown for endpoints when already available from the platform enrichment path

### Requirement: Attributed flows route title is contextual

The attributed flows page SHALL show "Attributed Flows" as the route title in the
topbar/shell context instead of generic ServiceRadar product text.

#### Scenario: Attributed flows topbar
- **GIVEN** the operator is viewing `/observability/flows/attributed`
- **WHEN** the app shell renders the route title
- **THEN** the title reads "Attributed Flows"
