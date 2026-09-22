# Change: Replace Apache AGE topology with Dgraph

## Why

Apache AGE is the topology graph today (`platform_graph` inside CNPG). It is a
projection over relational mapper evidence, not a primary store, and it has
become the bottleneck: Cypher is issued as interpolated SQL through Postgrex,
`agtype` has to be round-tripped to text, AGE graph catalogs do not round-trip
through the CNPG baseline, and the same Postgres instance is already doing
Timescale ingest. We have outgrown that arrangement.

The next graph workload is change impact, not another Cypher view. Operators
need to take two proposed changes in the same window — for example an upgrade
on devices in `192.0.2.0/24` and a config change in `198.51.100.0/24` — and
ask whether the second prefix sits downstream of the first, so B waits for A.
That question is reachability over topology plus prefix membership plus a
change window. AGE cannot carry it, and stuffing running-configs into
Postgres JSONB does not make it traversable.

Topology must be source-agnostic: SNMP/LLDP/CDP mapper evidence and
downparsed network configs (OpenText Network Automation is the first
collector; the inventory plugin already exists, config pull does not)
project into the **same** Device / Interface / Prefix graph. The graph
does not care who observed the link. The evidence tables do.

Dgraph is already running in this environment (`dgraph-ci` as the CI fixture,
`dgraph` as the HA demo cluster, both v25.4.0). The Rust client Marvin extracted
to [`marvin-hansen/dgraph-rs`](https://github.com/marvin-hansen/dgraph-rs) tracks
the v25 protocol. Scrith already has a schema migrator, a typed manager, JSON
upserts, and a one-shot importer on top of that client. There is no maintained
Elixir driver for Dgraph v25, so Elixir talks to Dgraph through a Rustler NIF
that wraps `dgraph-client`.

## What Changes

- Treat Dgraph as the authoritative topology graph. CNPG keeps the relational
  evidence tables (`mapper_topology_links`, `runtime_topology_links`, and friends);
  the graph projection moves off AGE.
- Consume `dgraph-client` from `marvin-hansen/dgraph-rs` rather than re-homing a
  client inside this repo. The pending `add-rust-dgraph-client` change that put
  the crate at `rust/dgraph-client` is superseded by that extraction.
- Extract the **generic** schema-migration runner from scrith
  (`dgraph_migration` + `dgraph_smdb::migration`: verify-first, apply-on-miss,
  scoped remove, never `drop_all`) into a shared `dgraph-migrate` crate next to
  the client, so both products use one migrator. Domain schemas stay in the
  products: SMDB stays in scrith, topology schema lives here.
- Add a Rustler NIF so `serviceradar_core` and web-ng issue typed topology
  operations (and read-only DQL for SRQL) without a Hex driver.
- Dual-write AGE and Dgraph behind a cutover flag, then make Dgraph the read
  source for God View, SRQL graph queries, and the causal hydrator.
- Ship an AGE-to-Dgraph migrator as a Bazel-built binary in the ServiceRadar
  bundle (Helm Job + compose one-shot). Rebuild-from-evidence is the primary
  path; an AGE dump is the checksum/bootstrap fallback.
- Ship Dgraph inside the product Helm chart so install and upgrade are
  black-box: the chart starts Zero/Alpha, generates ACL material, waits
  until the cluster can serve, then runs the schema Job. Operators do not
  install Dgraph first. `k8s/dgraph` remains the CI fixture and the
  source of the HA vs single-node values; it is not the user install
  path. Compose starts a local Dgraph the same way.
- Namespace every topology predicate (`device.*`, `iface.*`, `topo.*`,
  `hop.*`, `prefix.*`, `change.*`) and occupy a dedicated Dgraph namespace so
  additional graphs (service registry, identity, CTI) can land later without
  colliding with scrith's `svc.*` / `endpoint.*` predicates.
- Keep the existing evidence/projection split and extend it to configs and
  changes, rather than picking "Postgres or Dgraph":
  - **CNPG (Ash)** holds raw config revisions, parsed interface/prefix facts,
    and change records (window, kind, source, status). These are inventory
    and audit.
  - **Dgraph namespaces version the graph** (same idea as scrith). Live
    namespace is now. Snapshot namespaces are immutable copies at `as_of`
    (scheduled, change-window, manual). Scratch namespaces hold dry-run
    proposed graphs. There is no row versioning in Dgraph and no
    cross-namespace query; yesterday vs today is the same DQL against two
    namespaces, compared in the app.
  - **CNPG** catalogs those namespaces (`topology_graph_snapshots`) and
    keeps a thin mutation index (`evidence_refs`) so "did revision R
    touch the graph" does not require cloning the whole graph. The
    queryable graph-at-T is still a namespace.
- Project config-derived topology through the same canonical rebuild as
  mapper LLDP/CDP. A config-declared neighbor is another evidence class
  (`config-declared`), not a second graph. SNMP still wins physical
  backbone by the existing arbitration rules unless config is the only
  evidence.
- Model proposed changes as first-class graph nodes (`Change` +
  `change.affects` + Prefix membership) so DeepCausality can treat
  downstream-of as a Spaceoid. ServiceRadar hydrates; it does not own the
  postpone/sequence verdict.
- Diagrams (Archify): `diagrams/sr-scrith-architecture.html`,
  `diagrams/config-to-reason.dataflow.html`,
  `diagrams/change-impact.sequence.html`.
- Tracking: ServiceRadar #4486 (Dgraph cutover), #4487 (config facts),
  #4488 (plugin snapshot), #4489 (provenance log). Scrith #12 (NMS
  extension contract), #13 (ChangeImpact).
- Scope, and do not build in this change, the NMS→scrith extension.
  Scrith is a generalized ontology / causal-reasoning / knowledge-graph
  system, not an NMS. ServiceRadar is the **reference NMS plugin** into
  that core; other NMS products implement the same contract. The two
  products do **not** share a Dgraph instance — namespaces cannot be
  queried across, unlike Postgres schemas. The plugin emits a snapshot
  (assets, links, prefixes, changes, telemetry). Scrith copies that into
  its own Dgraph and runs DeepCausality. Do not assume
  `add-causal-engine` lands in ServiceRadar.

**BREAKING** after cutover: topology reads no longer go through AGE
`graph_cypher`. SRQL gains a Dgraph-backed graph entity; `in:graph_cypher`
remains during dual-read and is retired in a follow-up.

Deliberately **not** in this change:

- Removing Apache AGE from the CNPG image (a follow-up once dual-write is off).
- Building the extra graphs (service registry, identity, CTI) — only the
  namespacing that makes them possible.
- A native Elixir Dgraph client.
- A full multi-vendor config compiler or a change-management UI that
  replaces OpenText. The seam, the facts tables, the Prefix/Change schema,
  and a narrow interface-section downparser are in scope; every NOS dialect
  is not.
- Implementing the scrith ChangeImpact RPC, DeepCausality change-window
  causaloids, or Ethos Teloids. This change freezes the contract and the
  hydrate-able graph; those issues are filed, not tasked here.

## Impact

- Affected specs: `dgraph-cluster` (new), `dgraph-client-nif` (new),
  `dgraph-topology` (new), `age-to-dgraph-migration` (new),
  `network-config-facts` (new), `change-impact` (new),
  `topology-provenance` (new), `scrith-causal-integration` (new, scoped),
  `age-graph`,
  `network-discovery`, `mtr-diagnostics`, `topology-causal-overlays`,
  `docker-compose-stack`, `srql`.
- Affected code:
  - `rust/dgraph-topology/**` (new schema + typed mutations/queries)
  - `elixir/serviceradar_core/native/dgraph_nif/**` (new Rustler NIF)
  - `elixir/serviceradar_core/lib/serviceradar/graph.ex` and
    `network_discovery/topology_graph/**` (writers move off Cypher)
  - `rust/srql` (`graph_cypher` dual-read, new Dgraph entity)
  - `rust/correlation-engine` hydrator (today `in:graph_cypher`)
  - `elixir/web-ng/native/god_view_nif` snapshot fetch path
  - `rust/age-to-dgraph/**` (migrator binary)
  - `helm/serviceradar` (Dgraph subchart or in-tree templates, ACL secret,
    schema-migration Job; default-on)
  - Docker Compose (Dgraph service + ACL bootstrap)
  - `k8s/dgraph` remains the CI fixture and the values reference for
    single-node vs HA; product installs go through Helm
  - OpenText NOM plugin: new config-revision action beside the existing
    `list device` inventory snapshot (`go/cmd/wasm-plugins/opentext-nom`)
  - Ash resources + Elixir migrations for config revisions, parsed
    interface facts, change records, `topology_graph_snapshots`, and
    optional `topology_graph_mutations`
- External: `marvin-hansen/dgraph-rs` (client + extracted `dgraph-migrate`),
  scrith as the donor of migrator/manager patterns. OpenText Network
  Automation is the first config collector; NCO remains the change-window
  consumer (`add-nco-validation-runs` is isolation verification, not this).
- Coordinate with in-flight changes that still target AGE:
  `add-causal-engine`, `add-causal-security-detections`,
  `add-endpoint-sbom-inventory`, `fix-topology-evidence-pipeline-resilience`.
  New topology writes they add MUST land on Dgraph; do not extend AGE.
