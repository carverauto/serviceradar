## ADDED Requirements
### Requirement: Per-metric threshold configuration modal
The interface metrics UI SHALL provide a concise per-metric status summary in each metric card and open a modal to configure per-metric event/alert settings.

#### Scenario: Per-metric summary shown
- **GIVEN** a device interface with available metrics
- **WHEN** a user opens the interface details view
- **THEN** each metric card SHALL display a concise summary of event and alert configuration status
- **AND** include an explicit affordance to open the per-metric configuration modal

#### Scenario: Modal config uses shared controls
- **GIVEN** a user opens the per-metric configuration modal
- **WHEN** configuring event creation or alert promotion settings
- **THEN** the UI SHALL reuse the same shared controls used for event and alert rule configuration

#### Scenario: Card click opens modal without toggling
- **GIVEN** a metric card is visible
- **WHEN** the user clicks the card to configure thresholds
- **THEN** the configuration modal SHALL open
- **AND** the metric enable/disable state SHALL NOT change unless explicitly toggled

### Requirement: Unified event rules visible in settings
The Events settings tab SHALL list unified event rules from all sources (logs and metrics) with source context.

#### Scenario: Metric event rules listed
- **GIVEN** metric event rules are configured
- **WHEN** a user visits the Events settings tab
- **THEN** the rules list SHALL include metric-derived event rules with a source label

#### Scenario: Log event rules listed
- **GIVEN** log event rules are configured
- **WHEN** a user visits the Events settings tab
- **THEN** the rules list SHALL include log-derived event rules

### Requirement: Metric alert rules visible in settings
The Alerts settings tab SHALL list metric-derived alert rules created from per-metric configurations.

#### Scenario: Metric alert rule listed
- **GIVEN** per-metric alert settings are enabled
- **WHEN** a user visits the Alerts settings tab
- **THEN** the list SHALL include the corresponding metric-derived alert rule
