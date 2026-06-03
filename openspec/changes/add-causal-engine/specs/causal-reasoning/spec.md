# causal-reasoning Specification

## ADDED Requirements

### Requirement: Numeric Observation Model Over Canonical Entities

The reasoner SHALL model all incoming signals — device/host risk, package
inventory exposure, attributed network flow, topology structure, and health
state — as NUMERIC observations (contextoids) attached to the EXISTING canonical
Device, Interface, and Service nodes identified by their `sr:`-prefixed
canonical IDs (see capability `causal-engine`). The reasoner MUST NOT invent a
parallel node space, parallel identifiers, or shadow entities; every observation
MUST resolve to a node that already exists in the hydrated Context graph derived
from `age-graph` topology and CNPG state.

The observation model SHALL treat each signal as a scalar or vector measurement
(e.g., `risk_score` 0-100, `flow_bps`, `flow_pps`, `capacity_bps`, headroom
ratio, flap count, reachability boolean coerced to 0/1) keyed to a canonical
node, so that causaloids reason over comparable numeric inputs rather than
heterogeneous source payloads.

#### Scenario: Risk and inventory observations bind to an existing device node

- **WHEN** a per-device `risk_score` contribution (see capability
  `inventory-risk-feed`) and a package exposure scalar arrive for a device whose
  `sr:`-prefixed canonical ID already exists as a Device node in the Context
- **THEN** the reasoner SHALL attach them as numeric observations on that
  existing Device node
- **AND** the reasoner SHALL NOT create a new node, a parallel ID, or a duplicate
  entity for the same device

#### Scenario: Observation for an unknown canonical ID is rejected, not invented

- **WHEN** an observation arrives keyed to a canonical ID that has no
  corresponding node in the hydrated Context
- **THEN** the reasoner SHALL hold or drop the observation pending the node's
  appearance rather than fabricate a new node
- **AND** the reasoner SHALL NOT merge or guess identity from adjacency or
  attribute heuristics

#### Scenario: Flow and topology observations are numeric over canonical edges

- **WHEN** attributed-flow severity (see capability `service-flow-bridge`) and
  per-interface `capacity_bps`/`flow_bps` arrive for canonical Interface/edge
  identities sourced from `age-graph`
- **THEN** the reasoner SHALL represent them as numeric edge observations
- **AND** downstream causaloids SHALL read those numeric values rather than
  re-parsing source payloads

### Requirement: Containment Cascade Prediction

The reasoner SHALL predict failure cascades that propagate through containment
relationships. Causaloid C1 SHALL, when a virtualization host enters a failed or
failing state, predict impact to the guests it contains. Causaloid C2 SHALL,
when a backing datastore degrades or fails, predict disk-availability impact to
the guests whose virtual disks reside on that datastore. Both causaloids SHALL
emit predictions only against guest/host nodes that exist as canonical entities
in the Context.

#### Scenario: Virtualization host failure cascades to guests (C1)

- **WHEN** a virtualization host node transitions to a failed or failing
  observation
- **THEN** causaloid C1 SHALL emit a containment-cascade prediction naming the
  contained guest devices as affected
- **AND** each affected guest SHALL be referenced by its existing canonical ID

#### Scenario: Datastore degradation cascades to guest disks (C2)

- **WHEN** a datastore node degrades or fails
- **THEN** causaloid C2 SHALL emit a prediction that the guests with virtual
  disks on that datastore face disk-availability impact
- **AND** the prediction SHALL identify the affected guests by canonical ID

### Requirement: Gateway and Agent Root-Cause Classification

Causaloid C3 SHALL classify a gateway or agent node as a probable root cause when
its failure or unreachability would explain a cluster of downstream
observations. The classification SHALL distinguish an in-band gateway (whose
failure removes the management/observation path to the devices behind it) from an
out-of-band gateway (whose failure does not by itself imply downstream data-plane
loss), using the gateway network-class distinction defined in `age-graph` (Gap E:
`gateways.network_class` in-band|out-of-band|management).

#### Scenario: In-band gateway failure classified as cascade root cause (C3)

- **WHEN** an in-band gateway/agent node becomes unreachable and the devices
  reachable only through it show correlated loss
- **THEN** causaloid C3 SHALL classify that gateway as the probable root cause
- **AND** the downstream devices SHALL be classified as affected rather than as
  independent root causes

#### Scenario: Out-of-band gateway distinction suppresses false data-plane blame (C3, Gap E)

- **WHEN** a gateway whose `network_class` is out-of-band or management becomes
  unreachable while the data-plane devices behind it remain observable through
  another path
- **THEN** causaloid C3 SHALL NOT classify the out-of-band gateway failure as the
  root cause of a data-plane outage
- **AND** the reasoner SHALL treat the management-path loss and the data-plane
  health as distinct observations

### Requirement: Management-Unobservable Suppression

Causaloid C4 SHALL suppress false root-cause and false-down conclusions for
devices that have become structurally unobservable. Using `is_reachable` over the
`MANAGED_BY` relationship in `age-graph`, the reasoner SHALL determine whether a
device's apparent failure is instead loss of its management/observation path; if
so, the device's state SHALL be marked unknown/unobservable rather than failed.
This causaloid is GATED on the upstream ultragraph `is_reachable` capability (see
capability `causal-engine`).

#### Scenario: Device behind a lost management path marked unobservable (C4)

- **WHEN** a device is no longer reachable from any healthy manager via
  `MANAGED_BY` (per `is_reachable`)
- **THEN** causaloid C4 SHALL classify the device as unobservable/unknown rather
  than failed
- **AND** the reasoner SHALL attribute the loss to the management path, not to the
  device itself

#### Scenario: Causaloid C4 inactive until upstream reachability ships

- **WHEN** the upstream ultragraph `is_reachable` capability is not yet available
- **THEN** causaloid C4 SHALL be reported as gated/inactive
- **AND** the reasoner SHALL NOT emit C4 suppression verdicts derived from an
  unavailable algorithm

### Requirement: Standing Single-Point-of-Failure Warnings

The reasoner SHALL emit standing structural warnings for single points of
failure even in the absence of an active fault. Causaloid C5 SHALL flag
articulation-point devices whose loss would partition reachability. Causaloid C5b
SHALL flag bridge edges whose loss would partition reachability. Both SHALL run
over the `age-graph` topology and are GATED on the upstream ultragraph
`articulation_points` / `bridges` capability (see capability `causal-engine`,
Decision Gap G).

#### Scenario: Articulation-point device raises a standing SPOF warning (C5)

- **WHEN** topology analysis identifies a device as an articulation point
- **THEN** causaloid C5 SHALL emit a standing single-point-of-failure warning for
  that device
- **AND** the warning SHALL persist while the device remains an articulation point
  even with no active fault

#### Scenario: Bridge edge raises a standing SPOF warning (C5b)

- **WHEN** topology analysis identifies an edge as a bridge
- **THEN** causaloid C5b SHALL emit a standing single-point-of-failure warning for
  that edge

#### Scenario: C5/C5b gated on upstream graph algorithms (Gap G)

- **WHEN** the upstream ultragraph `articulation_points`/`bridges` algorithms are
  not yet available
- **THEN** causaloids C5 and C5b SHALL be reported as gated/inactive
- **AND** the reasoner SHALL NOT synthesize SPOF warnings from a substitute
  heuristic

### Requirement: Interface Saturation Projection

Causaloid C6 SHALL project interface/link saturation by comparing numeric
`flow_bps` against `capacity_bps` headroom on canonical edges. C6 SHALL evaluate
ONLY on capacity-eligible edges — edges that carry a populated, non-zero
`capacity_bps` per the capacity-eligibility rules in `age-graph` (Gap B coverage)
— and SHALL NOT project saturation on edges lacking a trustworthy capacity
denominator.

#### Scenario: Saturation projected on a capacity-eligible edge (C6)

- **WHEN** an edge is capacity-eligible (non-zero `capacity_bps`) and its
  `flow_bps` trend approaches that capacity
- **THEN** causaloid C6 SHALL emit a saturation projection with the projected
  headroom-exhaustion for that edge

#### Scenario: No saturation projection without a capacity denominator (C6)

- **WHEN** an edge has no populated/non-zero `capacity_bps`
- **THEN** causaloid C6 SHALL NOT emit a saturation projection for that edge
- **AND** the absence of capacity SHALL be treated as not-eligible, not as
  unlimited headroom

### Requirement: Service-Stack Collapse Prediction

Causaloid C7 SHALL predict collapse of a dependent service stack when an
underlying service, host, or resource it depends on degrades or fails. C7 SHALL
operate over service-dependency structure surfaced via capability
`service-flow-bridge` and SHALL identify the dependent services as affected by
canonical identity.

#### Scenario: Underlying dependency failure predicts stack collapse (C7)

- **WHEN** a service or host that other services depend on degrades or fails
- **THEN** causaloid C7 SHALL predict collapse/degradation of the dependent
  service stack
- **AND** the prediction SHALL name the dependent services by canonical ID

### Requirement: BGP Withdrawal Reachability Degradation

Causaloid C8 SHALL predict reachability degradation arising from BGP route
withdrawals, reasoning over withdrawn prefixes and the affected next-hop/border
structure in `age-graph`. C8 SHALL determine which downstream destinations lose
or degrade reachability and is GATED on the upstream ultragraph `is_reachable`
capability (see capability `causal-engine`).

#### Scenario: Route withdrawal degrades downstream reachability (C8)

- **WHEN** a BGP withdrawal removes the path to a set of prefixes/destinations
- **THEN** causaloid C8 SHALL predict reachability degradation for the affected
  downstream destinations
- **AND** destinations still reachable via an alternate path SHALL NOT be flagged
  as lost

### Requirement: Shared-Hop Bottleneck Detection

Causaloid C9 SHALL identify shared-hop bottlenecks using
`pathway_betweenness_centrality` over the `age-graph` topology, flagging nodes or
edges that carry a disproportionate share of paths and would therefore amplify a
fault's blast radius. C9 is GATED on the upstream ultragraph
`pathway_betweenness_centrality` capability (see capability `causal-engine`).

#### Scenario: High-betweenness shared hop flagged as bottleneck (C9)

- **WHEN** pathway betweenness centrality identifies a node/edge carrying a
  disproportionate fraction of paths
- **THEN** causaloid C9 SHALL flag it as a shared-hop bottleneck
- **AND** the flag SHALL indicate the amplified blast radius if that hop fails

#### Scenario: C9 gated on upstream centrality (Gap G)

- **WHEN** the upstream ultragraph `pathway_betweenness_centrality` is not yet
  available
- **THEN** causaloid C9 SHALL be reported as gated/inactive

### Requirement: Traffic-Source Blast Radius

Causaloid C10 SHALL compute the blast radius of a compromised, risky, or
saturating traffic source by consuming attributed-flow observations (see
capability `service-flow-bridge`, the `attributed_flow` rows). C10 SHALL weight
the predicted severity of the blast radius by the per-device/source `risk_score`
(see capability `inventory-risk-feed`), so that a high-risk source produces a
higher-severity prediction than a low-risk source with identical flow.

#### Scenario: Risk-weighted blast radius from an attributed flow source (C10)

- **WHEN** an `attributed_flow` observation identifies a source device sending
  traffic to a set of destinations and that source carries an elevated
  `risk_score`
- **THEN** causaloid C10 SHALL emit a blast-radius prediction over the reachable
  destinations
- **AND** the predicted severity SHALL be raised in proportion to the source's
  `risk_score`

#### Scenario: Identical flow with low risk yields lower severity (C10)

- **WHEN** two sources produce comparable attributed flows but differ in
  `risk_score`
- **THEN** causaloid C10 SHALL assign the higher-`risk_score` source the
  higher-severity blast-radius prediction

### Requirement: Flap-Rate Precursor Detection

Causaloid C11 SHALL treat an elevated flap rate (rapid repeated state
transitions) on a device, interface, or service as a precursor observation and
SHALL emit an early-warning prediction of impending instability before a hard
failure occurs.

#### Scenario: Rising flap rate emits an instability precursor (C11)

- **WHEN** a node's observed state-transition (flap) count rises above the
  configured precursor threshold within the evaluation window
- **THEN** causaloid C11 SHALL emit an instability-precursor prediction for that
  node
- **AND** the prediction SHALL precede any hard up/down conclusion

### Requirement: Operator-Rule Promotion

Causaloid C12 SHALL incorporate operator-authored stateful alert rules (from
`stateful_alert_rules`) as first-class causal inputs, promoting an operator rule
condition into a causaloid-evaluable observation so operator intent participates
in forward reasoning and the resulting verdicts re-enter the automation loop (see
capability `causal-engine` and capability `inventory-risk-feed` for emission).

#### Scenario: Operator rule promoted into causal reasoning (C12)

- **WHEN** an operator-authored stateful alert rule defines a condition over
  canonical entities
- **THEN** causaloid C12 SHALL evaluate that condition as a causal observation
  alongside engine-native causaloids
- **AND** a verdict satisfying the rule SHALL be emitted so it re-enters the
  automation loop rather than only painting an overlay

### Requirement: Discovery-Gap Disambiguation

Causaloid C13 SHALL disambiguate a true outage from a discovery/observation gap.
When expected observations for a node are absent, C13 SHALL distinguish "the node
failed" from "the node was never (or is no longer) being observed," classifying
the latter as a discovery gap rather than a failure, consistent with the
management-unobservable handling in causaloid C4.

#### Scenario: Missing observations classified as discovery gap, not failure (C13)

- **WHEN** expected observations for a node are absent but there is no positive
  evidence of failure
- **THEN** causaloid C13 SHALL classify the condition as a discovery/observation
  gap
- **AND** the node SHALL NOT be reported as failed solely due to missing data

### Requirement: Package-Risk Severity Composition

The reasoner SHALL compose per-device package/vulnerability risk into the
predicted severity of structural causaloids. Specifically, the per-device
`risk_score` and bounded `pkg_*` AGE scalars (see capability `inventory-risk-feed`
and `age-graph`) SHALL raise the predicted severity of causaloids C5
(single-point-of-failure), C7 (service-stack collapse), and C10 (blast radius)
for the affected nodes, without altering the structural conclusion itself.

#### Scenario: High package risk raises SPOF and collapse severity (C5/C7)

- **WHEN** a node flagged by C5 or C7 also carries an elevated per-device
  `risk_score` or `pkg_*` risk scalar
- **THEN** the reasoner SHALL raise the predicted severity of that C5/C7 prediction
- **AND** the underlying structural classification (articulation point /
  dependent stack) SHALL remain unchanged

#### Scenario: Package risk amplifies blast-radius severity (C10)

- **WHEN** a traffic source in a C10 blast-radius prediction carries elevated
  package risk
- **THEN** the reasoner SHALL raise the C10 predicted severity in addition to any
  flow-based weighting
