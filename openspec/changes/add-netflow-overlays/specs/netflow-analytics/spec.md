## ADDED Requirements

### Requirement: NetFlow Visualize overlays

The system SHALL support SRQL-driven overlays on the NetFlow Visualize page to show bidirectional traffic and previous-period comparison.

#### Scenario: Enable bidirectional overlay on line chart
- **GIVEN** the user is on `/netflow` with a line chart selected
- **WHEN** the user enables `bidirectional`
- **THEN** the chart SHALL include a reverse-direction overlay derived from SRQL queries

#### Scenario: Enable previous-period overlay on line chart
- **GIVEN** the user is on `/netflow` with a line chart selected
- **WHEN** the user enables `previous_period`
- **THEN** the chart SHALL include a previous-window overlay aligned to the current time window

#### Scenario: Enable overlays on stacked area chart
- **GIVEN** the user is on `/netflow` with a stacked chart selected
- **WHEN** the user enables `bidirectional` and/or `previous_period`
- **THEN** the chart SHALL render dashed total overlays for the enabled overlay types

#### Scenario: Enable overlays on 100% stacked chart
- **GIVEN** the user is on `/netflow` with a 100% stacked chart selected
- **WHEN** the user enables `bidirectional` and/or `previous_period`
- **THEN** the chart SHALL render dashed composition boundaries for the enabled overlay types
