## ADDED Requirements
### Requirement: Backbone topology regressions are detectable
The topology pipeline SHALL provide validation queries or counters that detect when expected backbone adjacency is split into unexpected islands. The diagnostics SHALL distinguish intentionally isolated endpoints/hypervisors from missing canonical backbone edges.

#### Scenario: Backbone splits into unexpected islands
- **GIVEN** a known backbone topology should form one connected component
- **WHEN** topology reconciliation or God View rendering produces multiple backbone islands
- **THEN** diagnostics identify missing or stale canonical edges, unresolved endpoints, or evidence arbitration decisions responsible for the split
- **AND** endpoint-only islands are reported separately from backbone regressions

#### Scenario: Backbone connectivity is preserved
- **GIVEN** fresh mapper evidence contains expected backbone links
- **WHEN** AGE projection and topology rendering complete
- **THEN** the backbone appears as a connected component
- **AND** validation queries report no unexpected backbone island split
