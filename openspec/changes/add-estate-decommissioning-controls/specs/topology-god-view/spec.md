# topology-god-view Specification

## ADDED Requirements

### Requirement: Blocked Topology Prunes Are Observable

When the canonical prune guard refuses a stale-prune pass, the system SHALL log the
refusal with the number of edges it would have removed, the total, the fraction, and the
setting that permits the pass to proceed.

A guard that fails closed without saying so is indistinguishable from a mechanism that was
never built. On `demo` after a topology cutover the guard would refuse indefinitely at
82.6% -- above the 50% default -- while the surface kept drawing a network the deployment
no longer polls, and nothing in the logs explained why.

#### Scenario: A cutover leaves more than half the topology stale
- **GIVEN** 147 of 190 canonical edges reference devices that have been removed
- **WHEN** the hourly cleanup pass runs with the guard at its 50% default
- **THEN** the prune is refused
- **AND** a warning names the counts, the fraction, and the override that would allow it
- **AND** the warning repeats on subsequent passes while the condition persists

### Requirement: Pipeline Stats Report Pipeline Decisions

The god-view pipeline stats SHALL report the classification the pipeline actually applied.
A counter that reports a producer's claimed evidence class rather than the resolved one
SHALL be named so that difference is explicit.

Stage counters SHALL be derived from distinct stages. `pair_*` and `final_*` SHALL NOT be
computed from the same collection, because identical counters cannot localise a loss
between the stages they claim to measure.

#### Scenario: An attachment misreported as inferred
- **GIVEN** links whose `relation_type` is `ATTACHED_TO` and whose declared evidence class
  is `inferred-segment`
- **WHEN** pipeline stats are emitted
- **THEN** the attachment counter reflects the resolved classification the pipeline used
- **AND** a counter reporting the producer's declared class is named to say so

#### Scenario: Stage counters can localise a loss
- **GIVEN** edges are lost between the pair stage and the final stage
- **WHEN** pipeline stats are emitted
- **THEN** `pair_*` and `final_*` differ, identifying the stage where the loss occurred
