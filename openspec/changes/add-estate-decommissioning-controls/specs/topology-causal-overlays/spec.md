# topology-causal-overlays Specification

## ADDED Requirements

### Requirement: Horizon-Limited Causal Verdicts Are Labelled Honestly

The causal overlay SHALL NOT report an absence of causal linkage when its analysis did not
search far enough to establish one. Where a node is unreached because it lies beyond the
affected-cascade hop horizon, the reported reason SHALL say that the node was not reached
within the horizon, and SHALL state the horizon.

A node genuinely disconnected from the selected root SHALL remain distinguishable from one
merely beyond the horizon. The current BFS truncates at three hops, so both cases collapse
into one unreachable state and are reported identically.

The hop horizon SHALL be defined in one place shared by every implementation of the
cascade, rather than duplicated as a literal.

#### Scenario: A node beyond the horizon is not called unlinked
- **GIVEN** a selected root and an unhealthy node reachable in five hops
- **AND** the affected-cascade horizon is three hops
- **WHEN** the overlay reports that node's state
- **THEN** the reason states the node was not reached within three hops
- **AND** the reason does not assert that the node is not causally linked to the root

#### Scenario: A genuinely disconnected node is reported as disconnected
- **GIVEN** a selected root and an unhealthy node with no dependency path to it
- **WHEN** the overlay reports that node's state
- **THEN** the reason distinguishes it from a node beyond the horizon
