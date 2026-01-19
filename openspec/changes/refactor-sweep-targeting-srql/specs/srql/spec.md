## MODIFIED Requirements
### Requirement: SweepCompiler uses SRQL for target extraction
The SweepCompiler SHALL use SRQL queries stored on sweep groups to extract target IP addresses, ensuring consistency between preview counts and compiled target lists.

#### Scenario: SRQL target_query used for target extraction
- **GIVEN** a SweepGroup with `target_query = "in:devices discovery_sources:armis"`
- **WHEN** the SweepCompiler compiles the group
- **THEN** it executes the SRQL query and returns matching IPs as targets.

#### Scenario: Multiple SRQL clauses combined with AND
- **GIVEN** a SweepGroup with `target_query = "in:devices discovery_sources:armis partition:datacenter-1"`
- **WHEN** the SweepCompiler compiles the group
- **THEN** it executes the SRQL query with space-separated clauses (implicit AND).

---

### Requirement: SRQL operators are exposed in the targeting rules UI
The sweep targeting UI SHALL expose SRQL operators and a query builder that map to SRQL device filters including list membership, numeric comparisons, IP CIDR/range matching, and tag matching.

#### Scenario: IP CIDR operator
- **GIVEN** a user building a sweep target query for field `ip`
- **WHEN** they select the CIDR operator and enter a CIDR
- **THEN** the UI emits `ip:<cidr>` with proper SRQL escaping.

#### Scenario: Discovery sources operator
- **GIVEN** a user building a sweep target query for `discovery_sources`
- **WHEN** they enter value `armis`
- **THEN** the UI emits `discovery_sources:armis` in the SRQL query.

---

### Requirement: Preview counts use SRQL queries
The sweep targeting UI SHALL show accurate device preview counts by executing the stored SRQL query against the device inventory.

#### Scenario: Preview count matches compiled targets
- **GIVEN** a sweep target query `in:devices discovery_sources:armis`
- **WHEN** the UI shows a preview count of 47 devices
- **THEN** the compiled target list from SweepCompiler contains exactly 47 IPs.
