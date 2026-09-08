# identity-asset-flow-bridge Specification

## ADDED Requirements

### Requirement: Identity-to-Asset Reachability Graph

The system SHALL model which identity can reach which asset by projecting identity-privilege edges
and identity→asset reachability edges into the AGE `platform_graph`, composing the
`service_endpoints(entity, ip, port, proto)` mapping and the `attributed_flow` rows supplied by the
`add-causal-engine` `service-flow-bridge` (Gap A) together with the OTEL-derived service edges. The
bridge MUST NOT re-derive flow attribution or re-declare the `service_endpoints` binding — it
CONSUMES that substrate and adds only the identity layer. Every projected edge SHALL be keyed to
canonical `sr:`-prefixed entity identities (`RuntimeGraph.canonical_runtime_id/1`), and the graph
SHALL tag crown-jewel assets so that a privileged identity reaching a critical asset it does not
normally touch is surfaced as evidence to the reasoner. All DB changes SHALL be applied via
Elixir/Ash migrations in the `platform` schema; ingestion MUST NOT run DDL.

#### Scenario: Privileged identity reaching an unusual critical asset is surfaced

- **WHEN** a privileged identity establishes an attributed flow to a crown-jewel-tagged asset that
  the identity→asset reachability graph shows it does not normally reach
- **THEN** the bridge SHALL surface that reach as an evidence signal to the reasoner, referencing
  the identity and asset by their canonical `sr:`-prefixed identities
- **AND** the signal SHALL carry the crown-jewel tag of the reached asset

#### Scenario: Reachability composes existing substrate without re-deriving it

- **WHEN** the identity→asset reachability graph is built
- **THEN** it SHALL consume the `service-flow-bridge` `service_endpoints` mapping and the
  `attributed_flow` rows rather than re-implementing flow attribution or the service-endpoint binding
- **AND** it SHALL add only net-new identity-privilege and identity→asset reachability edges to the
  AGE `platform_graph`

#### Scenario: Schema changes land via platform-schema migrations

- **WHEN** the bridge needs a new column or attribute to resolve identity or reachability
- **THEN** the change SHALL be applied via an Elixir/Ash migration in the `platform` schema
- **AND** the ingestion path SHALL NOT execute any DDL

### Requirement: Asset Criticality Tagging

Assets SHALL carry a criticality/exposure attribute (crown-jewel tier) set via an Elixir/Ash
`platform`-schema migration and resource, projected as a bounded scalar onto the asset vertex and
consumed by the engine as a Context `Datoid`. The reasoner SHALL use that `Datoid` to ground
`SecVerdict` severity, RAISING (never lowering) predicted severity monotonically for incidents on
higher-criticality assets, so an incident on a high-criticality asset outranks an otherwise-identical
incident on a low-criticality asset.

#### Scenario: Domain-controller incident outranks print-server incident

- **WHEN** two otherwise-identical incidents occur, one on an asset tagged high criticality (e.g. a
  domain controller) and one on an asset tagged low criticality (e.g. a print server)
- **THEN** the engine SHALL assign the high-criticality incident a higher severity than the
  low-criticality incident
- **AND** the severity difference SHALL be attributable to the asset-criticality `Datoid`

#### Scenario: Criticality only raises severity, never lowers it

- **WHEN** the asset-criticality `Datoid` is composed into a verdict's severity
- **THEN** the composition SHALL be monotonic — it MAY raise the predicted severity but SHALL NOT
  lower the severity produced by the underlying detection
- **AND** the structural `SecVerdict::join` lattice laws SHALL remain intact
