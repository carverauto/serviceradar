## ADDED Requirements

### Requirement: Large Integration Sync Validation
The system SHALL provide a repeatable validation path for large integration syncs that exercises configured queries, pagination, authentication refresh, agent streaming, gateway routing, and core ingestion.

#### Scenario: Armis faker syncs multiple configured queries
- **GIVEN** the Armis faker is configured with multiple AQL query result sets totaling at least 50k devices
- **WHEN** an agent runs the Armis source sync
- **THEN** the agent SHALL execute each configured query
- **AND** it SHALL page through all results without substituting an unbounded default query
- **AND** it SHALL stream all result chunks through the production gRPC sync endpoint.

#### Scenario: Access token expires during paged sync
- **GIVEN** an Armis paged sync has already streamed at least one page
- **WHEN** the Armis API returns `401 Unauthorized` for a later page because the access token expired
- **THEN** the agent SHALL refresh authentication and retry that page once
- **AND** it SHALL continue streaming without duplicating already acknowledged pages.

#### Scenario: Large sync completes
- **WHEN** the faker-backed large sync completes
- **THEN** validation SHALL assert query count, page count, streamed device count, ingested inventory count, source metadata, and final run status.

### Requirement: Integration Run Progress Diagnostics
The system SHALL expose integration run progress fields that allow operators to determine whether a source is running, stalled, partially synced, or completed.

#### Scenario: Operator inspects an Armis run
- **WHEN** an operator inspects the latest Armis source run
- **THEN** the system SHALL report configured query count, current query, current page offset, streamed device count, ingested device count when available, token refresh count, last error, and final status.
