## ADDED Requirements
### Requirement: Analytics critical events summary
The Analytics UI SHALL compute critical event severity totals using pre-aggregated event statistics when available.

#### Scenario: Aggregate-backed analytics card
- **GIVEN** the Analytics page is loaded
- **WHEN** pre-aggregated event stats are available
- **THEN** the critical events card SHALL use those aggregates
- **AND** it SHALL fall back to SRQL queries if aggregates are unavailable
