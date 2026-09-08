# age-graph — deltas

## MODIFIED Requirements

### Requirement: Evidence-backed stale-edge lifecycle
The system SHALL expire inferred AGE edges when supporting evidence has aged beyond configured freshness windows. Stale-edge expiry SHALL distinguish topology change from evidence starvation: when the canonical rebuild produces zero (or near-zero) edges while mapper evidence exists, the prune SHALL be suspended and a starvation signal raised instead of deleting the canonical graph.

#### Scenario: Stale inferred edge is retracted
- **GIVEN** an inferred edge has no supporting observations within the freshness window
- **WHEN** topology reconciliation runs
- **THEN** the inferred edge SHALL be marked stale and removed from canonical AGE adjacency
- **AND** direct evidence-backed edges SHALL remain unless they are also stale

#### Scenario: Evidence starvation suspends pruning
- **GIVEN** mapper evidence edges exist in the graph
- **AND** the canonical rebuild upsert produced zero edges because all evidence is older than the stale cutoff
- **WHEN** the stale prune would run
- **THEN** the prune SHALL be skipped
- **AND** a `canonical_rebuild_starved` health event SHALL be emitted
- **AND** existing canonical edges SHALL be retained until fresh evidence arrives or an operator intervenes

#### Scenario: Mass-deletion guardrail
- **GIVEN** a single prune pass would remove more than the configured fraction (default 50%) of canonical edges
- **WHEN** no operator override is present
- **THEN** the prune SHALL be refused and an error-level health event emitted

### Requirement: Confidence-aware topology edge lifecycle
The system SHALL maintain topology edges in AGE with confidence-aware projection and observation freshness controls. Stale retirement is subject to the evidence-starvation exception defined in "Evidence-backed stale-edge lifecycle": when zero (or near-zero) edges were upserted while mapper evidence exists, retirement is suspended rather than applied unconditionally.

#### Scenario: Idempotent edge upsert with confidence metadata
- **GIVEN** a topology link candidate eligible for projection
- **WHEN** projection runs repeatedly for the same source/target/interface tuple
- **THEN** the AGE edge SHALL be upserted once
- **AND** edge confidence and last-observed timestamp SHALL be updated in place

#### Scenario: Stale projected edge is retired
- **GIVEN** a projected topology edge has not been observed for longer than the configured stale threshold
- **AND** the evidence-starvation exception does not apply
- **WHEN** topology reconciliation runs
- **THEN** the edge SHALL be removed or marked inactive based on configured retention policy

## ADDED Requirements

### Requirement: Canonical rebuild self-heal escalation
The system SHALL treat a canonical-topology recovery rebuild that completes with zero canonical edges, while mapper evidence exists, as a failure that escalates — not as a successful completion.

#### Scenario: Recovery rebuild produces zero edges
- **GIVEN** the canonical edge count is below the self-heal threshold
- **AND** mapper evidence edges exist
- **WHEN** the one-shot recovery rebuild completes with zero canonical edges
- **THEN** the system SHALL log at error level and emit a persistent unhealthy state for topology
- **AND** repeated identical failures SHALL deduplicate into a single ongoing health condition rather than hourly success logs

#### Scenario: Health condition clears on recovery
- **GIVEN** an active canonical-rebuild unhealthy condition
- **WHEN** a rebuild produces canonical edges above the threshold
- **THEN** the condition SHALL clear automatically and the recovery SHALL be logged
