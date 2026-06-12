## ADDED Requirements

### Requirement: Shipped advisory feed producers for NVD, CISA KEV, and VulnCheck

The platform SHALL ship an installable producer package, or provider-specific
packages, for NVD, CISA KEV, and VulnCheck that declare the `advisory-feed:v1`
and `producer-schedule:v1` capabilities with a validated `producer_schedules`
manifest block. Each provider action SHALL download, validate, normalize, and
stage its feed, then submit an advisory-feed contract batch consumed by the
existing vulnerability advisory ingestor, registering a source and a schedule
that appear in the Vulnerability Intelligence settings UI.

#### Scenario: Installing a producer registers a source and schedule
- **WHEN** an advisory producer package is installed/imported
- **THEN** its schedule contract SHALL materialize producer schedule rows for
  the declared provider actions
- **AND** the Vulnerability Intelligence UI SHALL list the registered source
  (no longer the empty state) with its cadence and credential requirements

#### Scenario: CISA KEV catalog produces advisory records
- **WHEN** the CISA KEV producer runs
- **THEN** it SHALL emit advisory records flagged exploited/known-exploited
  with vendor/product coordinates, ingested for endpoint package matching

#### Scenario: Credentialed feeds declare credential requirements
- **GIVEN** NVD and VulnCheck require API keys/tokens
- **THEN** their packages SHALL declare credential_requirements the operator
  supplies before the schedule dispatches
