## ADDED Requirements
### Requirement: Camera analysis worker alert transitions generate observability signals
The platform SHALL route camera analysis worker alert activation and clear transitions into the existing observability event and alert pipeline.

#### Scenario: Worker alert activates
- **WHEN** a registered camera analysis worker enters an active derived alert state such as sustained unhealthy, flapping, or failover exhausted
- **THEN** the platform SHALL emit a normalized observability event for that transition
- **AND** the platform SHALL create or update the corresponding routed alert

#### Scenario: Worker alert clears
- **WHEN** a registered camera analysis worker leaves an active derived alert state
- **THEN** the platform SHALL emit a normalized observability recovery or clear signal
- **AND** the corresponding routed alert SHALL resolve or clear through the standard alert path

### Requirement: Camera analysis worker alert routing is duplicate-safe
The platform SHALL suppress duplicate routed alerts while the authoritative worker alert state remains unchanged.

#### Scenario: Repeated failures do not create duplicate routed alerts
- **GIVEN** a camera analysis worker remains in the same derived alert state across multiple repeated probe or dispatch failures
- **WHEN** additional failures occur without changing that derived alert state
- **THEN** the platform SHALL NOT emit a new routed alert transition for each repeated failure
