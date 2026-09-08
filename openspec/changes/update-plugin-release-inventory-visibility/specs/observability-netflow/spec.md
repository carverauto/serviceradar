## ADDED Requirements
### Requirement: NetFlow map paths degrade diagnostically
The dashboard NetFlow map SHALL distinguish between no recent flows, missing GeoIP enrichment, and missing private-network anchors. When recent conversations exist but paths cannot be mapped, the system SHALL expose diagnostic counts or messages that identify which enrichment or anchor join is missing.

#### Scenario: Recent flows lack enrichment
- **GIVEN** recent NetFlow conversations exist
- **AND** one or more endpoints lack GeoIP enrichment or private-network anchors
- **WHEN** the dashboard map renders
- **THEN** the UI reports that paths are blocked by enrichment or anchor gaps
- **AND** diagnostics expose counts for recent conversations, enriched endpoints, anchored private endpoints, and renderable paths

#### Scenario: Recent flows are renderable
- **GIVEN** recent NetFlow conversations have GeoIP enrichment or private-network anchors for each required endpoint
- **WHEN** the dashboard map renders
- **THEN** the map shows NetFlow paths
- **AND** it does not show the "No NetFlow Paths" empty state
