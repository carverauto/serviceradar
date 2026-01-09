## ADDED Requirements

### Requirement: Per-Source Discovery Intervals

The sync service SHALL support per-source interval configuration for discovery, polling, and sweep operations. When a source specifies an interval, that interval SHALL override the global default for that source only.

#### Scenario: Source with explicit discovery interval

- **WHEN** an integration source has `discovery_interval` set to "30m"
- **AND** the global discovery interval is "6h"
- **THEN** discovery for that source SHALL run every 30 minutes
- **AND** other sources without explicit intervals SHALL continue using the 6h global default

#### Scenario: Source without explicit interval uses global default

- **WHEN** an integration source does not specify `discovery_interval`
- **AND** the global discovery interval is "6h"
- **THEN** discovery for that source SHALL run every 6 hours

#### Scenario: Mixed sources with different intervals

- **WHEN** source A has `discovery_interval` set to "15m"
- **AND** source B has `discovery_interval` set to "2h"
- **AND** source C has no `discovery_interval` set
- **THEN** source A SHALL run discovery every 15 minutes
- **AND** source B SHALL run discovery every 2 hours
- **AND** source C SHALL use the global default interval

#### Scenario: Config update changes discovery schedule

- **WHEN** a source's `discovery_interval` is updated from "1h" to "15m"
- **THEN** the new interval SHALL take effect on the next discovery cycle
- **AND** the source SHALL be scheduled according to the new 15m interval

### Requirement: Interval Resolution Helpers

The sync service SHALL provide helper functions to resolve effective intervals for each source, falling back to global defaults when per-source values are not specified.

#### Scenario: GetEffectiveDiscoveryInterval returns per-source value

- **WHEN** `GetEffectiveDiscoveryInterval` is called for a source with `discovery_interval` = "30m"
- **THEN** it SHALL return 30 minutes

#### Scenario: GetEffectiveDiscoveryInterval returns global default

- **WHEN** `GetEffectiveDiscoveryInterval` is called for a source without `discovery_interval`
- **AND** the global `discovery_interval` is "6h"
- **THEN** it SHALL return 6 hours
