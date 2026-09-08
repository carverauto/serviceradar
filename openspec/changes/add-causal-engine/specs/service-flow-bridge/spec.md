# service-flow-bridge Specification

## ADDED Requirements

### Requirement: Service Dependency Graph from OTEL Spans

The system SHALL derive a directed service-dependency graph from OTEL trace
spans (Gap A). The engine SHALL construct caller→callee service edges by
self-joining `otel_traces` on `parent_span_id` within the same `trace_id`: for a
child span and its parent span sharing a `trace_id` where the child's
`parent_span_id` equals the parent's `span_id`, a directed edge SHALL be created
from the parent span's `service_name` (caller) to the child span's `service_name`
(callee). The derivation MUST use only fields that are already present —
`service_name`, `trace_id`, `span_id`, and `parent_span_id` — and SHALL exclude
self-edges where caller equals callee. These derived service edges SHALL be keyed
to canonical Service identities so the reasoner consumes them as numeric/topology
observations (see capability `causal-reasoning`).

#### Scenario: Parent/child span pair yields a directed service edge

- **WHEN** two spans share a `trace_id` and the child span's `parent_span_id`
  equals the parent span's `span_id`, and their `service_name` values differ
- **THEN** the bridge SHALL emit a directed service-dependency edge from the
  parent's `service_name` (caller) to the child's `service_name` (callee)
- **AND** the edge SHALL be keyed to the canonical Service identities for those
  services

#### Scenario: Same-service spans do not create a self-edge

- **WHEN** a parent/child span pair within a `trace_id` resolves to the same
  `service_name` for both caller and callee
- **THEN** the bridge SHALL NOT emit a service-dependency edge for that pair
- **AND** no self-loop SHALL be introduced into the service-dependency graph

#### Scenario: Derivation uses only present OTEL fields

- **WHEN** the service-dependency graph is built from `otel_traces`
- **THEN** the self-join SHALL rely solely on `service_name`, `trace_id`,
  `span_id`, and `parent_span_id`
- **AND** the derivation SHALL NOT require any OTEL field that is not already
  populated in `otel_traces`

### Requirement: Service-to-Endpoint Binding

The system SHALL introduce a `service_endpoints` mapping
(`service_id`, `listen_ip`, `listen_port`, `protocol`) that binds a canonical
service identity to the network endpoint(s) it listens on. The binding SHALL
prefer agent self-reported listen endpoints when available and SHALL fall back to
operator-declared endpoints otherwise. Using this mapping, the bridge SHALL bind
`service_status` to the `netflow_metrics` 5-tuple so that observed flow traffic
on a `(listen_ip, listen_port, protocol)` endpoint is attributable to the owning
service. The mapping SHALL key `service_id` to the canonical Service identity and
MUST NOT invent a parallel service identifier space. Service identity itself is
supplied by capability `add-service-oriented-plugin-monitoring`; this bridge
consumes that identity rather than minting it.

#### Scenario: Agent self-reported listen endpoint preferred over operator declaration

- **WHEN** a service has both an agent self-reported listen endpoint and an
  operator-declared endpoint for the same `(service_id, protocol)`
- **THEN** the `service_endpoints` mapping SHALL record the agent self-reported
  `listen_ip`/`listen_port` as the authoritative binding
- **AND** the operator-declared endpoint SHALL serve only as a fallback when no
  agent self-report exists

#### Scenario: Flow on a bound endpoint attributed to its service

- **WHEN** a `netflow_metrics` 5-tuple matches a `(listen_ip, listen_port,
  protocol)` entry in `service_endpoints`
- **THEN** the bridge SHALL bind that flow's `service_status` context to the
  owning `service_id`
- **AND** the binding SHALL resolve `service_id` to its canonical Service
  identity without creating a new identifier

#### Scenario: Operator declaration used when no agent self-report exists

- **WHEN** a service has no agent self-reported listen endpoint
- **THEN** the bridge SHALL use the operator-declared endpoint as the
  `service_endpoints` binding
- **AND** the binding SHALL be marked as operator-declared rather than
  agent-observed

### Requirement: Observed Service Edges from Attributed Flows

The bridge SHALL derive observed service edges by CONSUMING the
`ocsf_network_activity` rows whose `ocsf_payload.event_type` equals
`attributed_flow`. Each such row already carries the process attribution
(`attribution.pid`, `attribution.comm`, `attribution.redacted_cmdline`,
`attribution.uid`, `attribution.container_id`) plus `agent_id`, established by the
in-flight attributed-flow work. The bridge SHALL resolve the chain
flow → pid/comm → agent → device → service so an attributed flow becomes an
observed edge between canonical Service identities. The umbrella MUST NOT
re-implement flow attribution: it DEPENDS ON the in-flight attributed-flow
correlation (which writes the `attributed_flow` rows) and only reads those rows.

#### Scenario: Attributed flow resolves to an observed service edge

- **WHEN** an `ocsf_network_activity` row has `ocsf_payload.event_type =
  'attributed_flow'` with populated `attribution` (pid/comm) and `agent_id`
- **THEN** the bridge SHALL resolve flow → pid/comm → agent → device → service
  and record an observed edge between the resolved canonical Service identities
- **AND** the observed edge SHALL be attributed to the owning device's canonical
  identity

#### Scenario: Bridge does not re-derive attribution

- **WHEN** the bridge needs process-to-flow attribution
- **THEN** it SHALL read the existing `attributed_flow` rows produced by the
  in-flight attributed-flow correlation
- **AND** it SHALL NOT re-implement 5-tuple correlation, process attribution, or
  cmdline redaction

#### Scenario: Non-attributed flow rows are ignored for service edges

- **WHEN** an `ocsf_network_activity` row's `ocsf_payload.event_type` is not
  `attributed_flow`
- **THEN** the bridge SHALL NOT derive an observed service edge from that row
- **AND** the absence of attribution SHALL NOT be treated as a service
  relationship

### Requirement: Service-Granularity Blast Radius

The system SHALL upgrade causaloid C10 (Gap A, Phase 2) from IP granularity to
service granularity once service edges exist (derived from OTEL spans,
service-to-endpoint binding, and observed attributed flows). Where C10 previously
computed blast radius over reachable IP destinations, it SHALL be able to compute
blast radius over dependent services along the service-dependency graph. The
upgraded C10 behavior SHALL remain consistent with the Traffic-Source Blast
Radius requirement in capability `causal-reasoning`, including risk-weighting of
predicted severity; this bridge provides the service-granularity substrate and
does not redefine C10's reasoning semantics.

#### Scenario: C10 blast radius computed over dependent services

- **WHEN** service edges are available and a traffic source participating in a C10
  blast-radius prediction maps to a canonical service
- **THEN** C10 SHALL compute the blast radius over the dependent services along
  the service-dependency graph rather than only over IP destinations
- **AND** the affected services SHALL be referenced by canonical Service identity

#### Scenario: C10 falls back to IP granularity when service edges are absent

- **WHEN** no service edges are available for a traffic source
- **THEN** C10 SHALL retain its IP-granularity blast-radius behavior as defined in
  capability `causal-reasoning`
- **AND** the absence of service edges SHALL NOT block C10 from emitting a
  prediction
