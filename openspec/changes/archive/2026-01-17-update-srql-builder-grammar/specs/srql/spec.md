## ADDED Requirements

### Requirement: SweepCompiler uses SRQL for target extraction
The SweepCompiler SHALL use SRQL queries to extract target IP addresses from device criteria, ensuring consistency between preview counts and compiled target lists.

#### Scenario: Criteria compiled to SRQL for target extraction
- **GIVEN** a SweepGroup with `target_criteria = %{"discovery_sources" => %{"contains" => "armis"}}`
- **WHEN** the SweepCompiler compiles the group
- **THEN** it executes `in:devices discovery_sources:armis select:ip` and returns matching IPs as targets.

#### Scenario: Multiple criteria combined with AND
- **GIVEN** a SweepGroup with `target_criteria` containing discovery_sources and partition rules
- **WHEN** the SweepCompiler compiles the group
- **THEN** it executes `in:devices discovery_sources:armis partition:datacenter-1 select:ip` (space-separated = AND).

### Requirement: Device criteria operators are exposed in the targeting rules UI
The sweep targeting rules UI SHALL expose device operators that map to TargetCriteria operators including list membership, numeric comparisons, IP CIDR/range matching, and tag matching.

#### Scenario: IP CIDR operator
- **GIVEN** a rule with field `ip` and operator `in_cidr`
- **WHEN** the builder generates SRQL
- **THEN** it emits `ip:<cidr>` with proper SRQL escaping.

#### Scenario: Discovery sources operator
- **GIVEN** a rule with field `discovery_sources` and operator `contains`
- **WHEN** the builder generates SRQL with value `armis`
- **THEN** it emits `discovery_sources:armis`.

### Requirement: Preview counts use SRQL queries
The sweep targeting rules UI SHALL show accurate device preview counts by executing SRQL queries against the device inventory.

#### Scenario: Preview count matches compiled targets
- **GIVEN** a targeting rule for `discovery_sources contains armis`
- **WHEN** the UI shows a preview count of 47 devices
- **THEN** the compiled target list from SweepCompiler contains exactly 47 IPs.

### Requirement: Config refresh on device inventory changes
The system SHALL periodically refresh sweep configs when the SRQL result set changes due to device inventory updates.

#### Scenario: New device matches criteria
- **GIVEN** a SweepGroup with criteria `discovery_sources contains armis`
- **AND** a new device is discovered with `discovery_sources = ["armis"]`
- **WHEN** the `SweepConfigRefreshWorker` runs
- **THEN** it detects the target hash changed and invalidates the config cache.

#### Scenario: Device attribute changes to match criteria
- **GIVEN** a SweepGroup with criteria `partition eq datacenter-1`
- **AND** a device's partition is updated from `datacenter-2` to `datacenter-1`
- **WHEN** the `SweepConfigRefreshWorker` runs
- **THEN** the device is now included in the compiled target list.
