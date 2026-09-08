# causal-security-context Specification (delta for add-causal-security-detections)

This delta adds the Layer-2 DeepCausality Security Context world model that a cross-domain
`Observation` is judged against (see `causal-security-detections`). It EXTENDS the `add-causal-engine`
chassis and DEPENDS ON `add-causal-security-foundation` for the `Observation`/`ObservationSource`
model. Context is hydrated from Layer 1 and owns its own freeze/unfreeze lifecycle.

## ADDED Requirements

### Requirement: Security Context Hypergraph

The Security Context SHALL be a DeepCausality `Context` hypergraph that maps asset criticality, CVE
exposure, and identity privilege onto `Datoid` contextoids; `platform_graph` (AGE) topology position and
reachability onto `Spaceoid` contextoids; time-of-day baselines, dwell windows, and beacon periodicity
onto `Tempoid` contextoids; and IOC / threat-intel indicators onto `Symboid` contextoids. All context
entities MUST be keyed by canonical `sr:`-prefixed identifiers (`RuntimeGraph.canonical_runtime_id/1`)
and MUST NOT invent a parallel ID space. The reachability `Spaceoid` layer SHALL be refrozen on
topology change so that a causaloid reading Context internally judges an `Observation` against the
current world model.

#### Scenario: Threat-flagged flow to an unpatched crown jewel is judged an incident

- **GIVEN** a `Datoid` marking a host as a crown-jewel asset with an unpatched CVE, a `Spaceoid` showing
  the source can reach that host in `platform_graph`, and a `Symboid`/L1 IOC observation flagging the
  source as a known threat indicator
- **WHEN** a flow `Observation` from the threat-flagged source to the crown-jewel host is evaluated
  against the Security Context
- **THEN** the Context SHALL judge the observation as an incident (not benign) by fusing the criticality,
  reachability, and IOC context

#### Scenario: Reachability refrozen on topology change

- **WHEN** the AGE `platform_graph` topology changes
- **THEN** the Context SHALL unfreeze and refreeze the reachability `Spaceoid` layer before the next
  reasoning tick evaluates observations against it

### Requirement: Bounded IOC Hydration

The Security Context MUST NOT hydrate `threat_intel_*` / `otx_retrohunt_*` wholesale as `Symboid`
contextoids. IOC / CIDR matching SHALL be computed in-DB using the existing GIST containment index over
`threat_intel_*` and `ip_threat_intel_cache`, and surfaced to the reasoner as an L1 `Observation`. Any
`Symboid` indicators hydrated into Context SHALL be bounded by the indicator's active `expires_at`
window and SHALL be kept under a Context memory ceiling. Fast-changing Datoid/Symboid state (CVE feeds,
IOC feeds) SHALL be refreshed on a cadence separate from the topology freeze.

#### Scenario: IOC match is computed in-DB, not by materializing all indicators

- **WHEN** the engine determines whether a source IP matches a known IOC or CIDR range
- **THEN** the match SHALL be computed in-DB via the GIST containment index + `ip_threat_intel_cache` and
  surfaced as an L1 `Observation`
- **AND** the Context SHALL NOT materialize the full `threat_intel_*` / `otx_retrohunt_*` indicator set as
  Symboids in memory

#### Scenario: Context stays under the memory ceiling with a separate refresh cadence

- **GIVEN** a configured Context memory ceiling and a Datoid/Symboid refresh cadence distinct from the
  topology freeze
- **WHEN** IOC and CVE feeds change more frequently than the topology
- **THEN** the Context SHALL refresh the affected Datoid/Symboid state on its own cadence without
  triggering a topology freeze
- **AND** the total hydrated indicator footprint SHALL remain under the configured memory ceiling
