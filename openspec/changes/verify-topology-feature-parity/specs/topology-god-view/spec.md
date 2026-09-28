## ADDED Requirements

### Requirement: Topology replacement has explicit feature-parity evidence
The topology workstream SHALL retain supported operator behavior from the previous
renderer and SHALL provide a behavior-by-behavior parity matrix before closing
#4774, including working bounded ELK detail layouts and SNMP-driven packet flow.

#### Scenario: Verify existing operator workflows
- **WHEN** the tile engine replaces the previous topology experience
- **THEN** the matrix SHALL cover visibility, labels, picking/details, search/filtering, expansion/paging, state colors, traffic controls, Fit/Home and navigation
- **AND** each loss SHALL be repaired or explicitly accepted rather than silently classified as a completed feature

#### Scenario: ELK detail and tile overview compose
- **WHEN** an operator enters, pages, fits, resizes and exits a bounded neighborhood
- **THEN** the detail SHALL use an actual ELK layout within its scene budgets
- **AND** exit SHALL restore compatible tile camera and selection state
- **AND** the overview SHALL keep server-authored coordinates without whole-world browser ELK

#### Scenario: Real browser evidence
- **WHEN** parity is reported complete
- **THEN** a hardware-WebGPU browser SHALL have exercised the actual product with traffic enabled
- **AND** the report SHALL identify the commit, workload, GPU and observed failures
- **AND** multicast and broadcast counters SHALL NOT be prerequisites for traffic animation
