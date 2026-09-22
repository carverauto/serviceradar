## Context

Topology lives in Apache AGE today. Mapper evidence is relational
(`mapper_topology_links`, `runtime_topology_links`);
`ServiceRadar.NetworkDiscovery.TopologyGraph` projects it into `platform_graph`
as Cypher `MERGE`s issued through `ServiceRadar.Graph` (Postgrex +
`ag_catalog.cypher` + `agtype_to_text`). Readers:

- God View snapshots (`god_view_nif`)
- SRQL `in:graph_cypher` (`rust/srql/src/query/graph_cypher.rs`)
- Causal hydrator (`rust/correlation-engine`, `TOPOLOGY_EDGES_QUERY`)
- MTR path overlay (`MTR_PATH` edges / `HopNode` vertices)

AGE vertex labels in use: `Device`, `Interface`, `Collector`, `Service`,
`HopNode`. Edges include `CONNECTS_TO`, `HAS_INTERFACE`, `CANONICAL_TOPOLOGY`,
`MANAGED_BY`, `MTR_PATH`, `LOGICAL_PEER`, `HOSTED_ON`, `INFERRED_TO`,
`ATTACHED_TO`, plus pending causal additions (`CONTAINS`, reverse `MANAGES`).
Canonical edges carry a large property set (confidence, evidence class,
directional flow, `capacity_bps`, `telemetry_eligible`).

A second evidence path is starting: OpenText Network Automation already
feeds device inventory through `opentext-nom-inventory` (`list device`).
Config pull, downparse, and change-window impact are not built. Mapper
topology and config-declared topology must land on the same graph or
change-impact has two worlds to reconcile. NCO (`add-nco-validation-runs`)
asks "did this ACL isolate the host"; this change asks "if we do A and B
in the same window, is B downstream of A".

Dgraph is already deployed:

| | `k8s/dgraph/ci` | `k8s/dgraph/demo` |
|---|---|---|
| Namespace | `dgraph-ci` | `dgraph` |
| Pattern | 1 Zero, 1 Alpha | 3 Zero, 3 Alpha, RF=3 |
| Image | `registry.carverauto.dev/mirror/dgraph/dgraph:v25.4.0` | same |
| TLS | private CA, `sslmode=require` in-cluster | public ACME, `sslmode=verify-ca` |
| ACL | on (required for namespace isolation) | on |

The client is [`marvin-hansen/dgraph-rs`](https://github.com/marvin-hansen/dgraph-rs)
(`dgraph-client`). Scrith (`~/src/scrith`) already builds a service registry on
it: schema with namespaced predicates, verify-first migration, JSON upserts,
acyclicity guards, and a one-shot importer. Those patterns are the template;
the SMDB schema itself is not.

Hex has no maintained Dgraph v25 client (`exdgraph` tracks 1.x). Elixir reaches
Dgraph through a Rustler NIF, matching SRQL and `god_view_nif`.

Constraints:

- Dgraph predicates are **global per namespace**, not per type. Unprefixed
  `name` / `id` collide. Scrith already uses `svc.*` / `endpoint.*`.
- Dgraph `[uid]` lists are **sets**; order is not preserved (measured in
  scrith against v25.4.0). Positional encodings are unsound.
- Conditional upserts whose `@if` is false still return `"Success"`. Callers
  must inspect named query blocks, not the status string.
- `drop_all` is cluster-wide. Schema removal must name the predicates it owns.
- The Dgraph client has no client-certificate path and no private-CA pin
  except the CA bundle it is given. Cluster TLS stays as `k8s/dgraph/README.md`
  already documents.
- Dgraph ACL credentials are ServiceRadar talking to itself: Kubernetes
  Secrets / process environment, **not** `network_credential_secrets`.
- No new shell scripts. The migrator is a Bazel `rust_binary`.
  `k8s/dgraph/deploy-dgraph.sh` already exists for the CI fixture; product
  installs go through Helm, not that script.
- AGE is a projection. Migrating "the AGE graph" is not the same as
  rebuilding from evidence; both are needed, with different jobs.

## Goals / Non-Goals

- Goals:
  - Dgraph is the authoritative topology graph after cutover.
  - One shared client (`dgraph-rs`) and one shared schema-migrator crate used
    by ServiceRadar and scrith.
  - Elixir writers use typed NIF operations, not interpolated DQL.
  - Dual-write, then cut over reads, then stop writing AGE.
  - A Bazel-built AGE-to-Dgraph migrator in the product bundle.
  - Compose and Helm can reach a Dgraph; CI keeps using `dgraph-ci`.
  - Predicate namespacing leaves room for later graphs.
  - Source-agnostic topology: mapper and config-declared evidence project
    into one graph; Prefix and Change types exist so impact queries do not
    require a later schema break.
  - Placement rule: blobs and parsed facts in CNPG; traversal (adjacency,
    prefix membership, change-affects, downstream) in Dgraph.
- Non-Goals:
  - Dropping AGE from the CNPG image (follow-up).
  - Shipping service-registry / identity / CTI graphs in this change.
  - A Hex/Elixir Dgraph driver.
  - Changing mapper evidence tables or arbitration rules.
  - Ratel, backups, or encryption-at-rest.
  - Replacing OpenText / NCO as the change-management system of record.
  - Parsing every NOS dialect. V1 downparser extracts interface name,
    IPv4/IPv6 prefix, description, VLAN, and shutdown from a documented
    synthetic fixture plus one invented IOS-like stanza set.
  - Implementing the scrith ChangeImpact RPC, change-window causaloids, or
    Ethos Teloids. The contract is frozen here; the implementation is a
    later scrith change.

## Decisions

### D1. Consume `dgraph-rs`; do not re-home the client

`openspec/changes/add-rust-dgraph-client` specified `rust/dgraph-client` in this
repo. Marvin then extracted that work to
`https://github.com/marvin-hansen/dgraph-rs.git`. This change depends on that
crate (`package = "dgraph-client"`) and does not recreate it.

ServiceRadar has no git crate dependencies today; every version lives in
`[workspace.dependencies]` and is mirrored through `//third_party/crate_mirror`.
Preferred resolution, in order:

1. Publish `dgraph-client` (and `dgraph-migrate`, D3) to crates.io, pin the
   version in the root `Cargo.toml`, run `bazel run //third_party/crate_mirror:sync`.
2. Until published, a `crate.spec` git source plus the same `crate.annotation`
   scrith already uses to hand `protoc` to `proto_dgraph`'s build script
   (`@@protobuf+//:protoc`). Record this as a temporary exception in
   `rust/README_RUST.md`.

*Alternative considered — vendor `rust/dgraph-client` again.* Rejected: two
copies of the client would drift, and scrith already depends on the extracted
repo.

### D2. Elixir reaches Dgraph only through a Rustler NIF

No Hex driver tracks v25. The NIF (`elixir/serviceradar_core/native/dgraph_nif`)
is a thin ABI over a rustler-free `rust/dgraph-topology` library, matching
`anomaly_disposition_nif`: typed `NifMap` / `NifTaggedEnum`, not JSON strings;
`catch_unwind` per call so a panic cannot kill a DirtyIo scheduler thread.

`dgraph-client` is async. The NIF owns a process-wide `tokio` runtime
(`OnceLock<Runtime>`) and `block_on`s from `schedule = "DirtyIo"`. It does not
run async work on a BEAM scheduler thread.

Public NIF surface:

- Typed writes: upsert device / interface / canonical edge / MTR path, prune
  stale edges, rebuild-canonical. Elixir MUST NOT concatenate DQL for writes.
- Typed reads: canonical directional edges (the God View shape), neighbourhood.
- Escape hatch: read-only DQL for SRQL. Mutations in that hatch are refused.

`ServiceRadar.Graph` stays as the AGE helper until AGE writes stop. A new
`ServiceRadar.Dgraph` module is the Elixir facade over the NIF.

*Alternative considered — HTTP DQL from Elixir.* Rejected: no connection
pooling/txn semantics, and it reintroduces stringly-typed writes.

### D3. Extract a generic `dgraph-migrate` crate from scrith

Scrith's migrator is the right shape and the wrong place:

- Library first, binary second. Nothing prints, nothing exits. `Outcome` /
  `MigrationError` carry everything a Job needs to log and set a process code.
- Verify first, apply only on a miss. `set_schema` is idempotent; checking
  first is how a deploy distinguishes "already current" from "just migrated".
- `remove` drops **named** predicates and types. Never `drop_all`.
- Deprovision of a shared cluster requires an explicit confirm value.
- Configuration is environmental (`DGRAPH_HOST`, `DGRAPH_PORT`,
  `DGRAPH_MIGRATION_MODE`, ACL userinfo in the connection string).

Lift the generic runner (apply / verify / scoped remove / connect /
env-resolution) into `dgraph-migrate` next to `dgraph-client`. The schema
**string** and the predicate/type **lists** are parameters supplied by the
product crate. Scrith's SMDB schema stays in `dgraph_smdb`; ServiceRadar's
topology schema lives in `rust/dgraph-topology`.

The ServiceRadar bundle ships a `dgraph-migrate` binary (Bazel `rust_binary`)
that applies the topology schema. Helm runs it as a Job; compose runs it as a
one-shot. This is schema migration, not data migration (D7).

### D4. Product Helm installs and manages Dgraph

Install and upgrade MUST be black-box. A new or existing user who runs
`helm upgrade --install` gets a Dgraph that ServiceRadar owns: Zero and
Alpha come up, ACL material is generated and stored as a Kubernetes
Secret, TLS is wired, the cluster is waited on until it can serve, then
the schema Job runs. The operator does not install Dgraph first, does
not paste a groot password into values, and does not run `dgraph live`
or Ratel.

`k8s/dgraph` already encodes the scaling rules (fewer fatter Alphas,
`shardReplicaCount` is Zero's `--replicas`, ACL on because namespaces
do not isolate without it, Harbor-mirrored `v25.4.0`). Those values
move into the product chart as profiles, not as a separate installer
the user has to run:

| Profile | When | Shape |
|---|---|---|
| `single` (chart default for small/dev) | compose-like, labs | 1 Zero, 1 Alpha, RF=1 |
| `ha` | production / demo | 3 Zero, 3 Alpha, RF=3 |

The official Dgraph chart (or in-tree templates that render the same
StatefulSets) is a Helm dependency of `helm/serviceradar`, enabled by
default. Images stay on `registry.carverauto.dev/mirror/dgraph/dgraph`.
Application pods get `dgraph://` from the release, not from a hand-edited
endpoint.

`dgraph.enabled=false` plus an external endpoint is an escape hatch for
the CI fixture (`dgraph-ci`) and for a one-time cutover from the current
standalone `k8s/dgraph` demo. It is not the documented install path.

Scrith still runs its own SaaS Dgraph. Embedding Dgraph in the NMS chart
does not join the two clusters.

Docker Compose starts a local Dgraph (ACL on, TLS off, `sslmode=disable`)
so `docker compose up -d` still boots without Kubernetes.

CI crate tests may keep using `dgraph-ci` with
`DGRAPH_TEST_STRATEGY=existing`, or `DgraphInstance::acquire()` locally.
That fixture is not how customers install.

### D5. Reify property-rich edges as nodes

Cypher relationships hold properties. Dgraph facets are second-class and too
small for `CANONICAL_TOPOLOGY` (directional flow, capacity, confidence,
evidence, telemetry eligibility). `[uid]` edges with no properties (scrith
`svc.dependencies`) are the wrong template here.

Each projected topology link is a `TopologyEdge` node:

- `topo.kind` (`CONNECTS_TO` | `CANONICAL_TOPOLOGY` | `HAS_INTERFACE` | ...)
- `topo.src` / `topo.dst` (`uid` edges, `@reverse` so both directions walk)
- `topo.link_key` (`string @index(exact) @upsert`) — the idempotency key
- property predicates (`topo.confidence_score`, `topo.capacity_bps`,
  `topo.flow_pps_ab`, ...)

Simple ownership (`Device HAS_INTERFACE Interface`) with no payload MAY be a
plain `[uid] @reverse` predicate (`device.interfaces`). If a property appears,
it becomes a reified node. Do not mix the two encodings for one kind.

Dgraph does not preserve `[uid]` order; `endpoint.index` in scrith exists only
because a list had to stay ordered. Topology edges are sets. No index-as-role.

### D6. Dual-write, then cut over reads, then stop AGE writes

AGE remains a projection during the transition so God View and SRQL do not
flip on a flag with an empty graph.

```
evidence tables  -->  TopologyGraph writers  -->  Dgraph (authoritative)
                                           \-->  AGE (shadow, until flag)
```

Flags (env / Helm, default shadow-on until the migrator checksums):

| Flag | Meaning |
|---|---|
| `GRAPH_BACKEND=age\|dual\|dgraph` | write target |
| `GRAPH_READ=age\|dgraph` | read target for God View, SRQL, causal |

Promotion to `GRAPH_READ=dgraph` requires the migrator report (D7) to pass.
`GRAPH_BACKEND=dgraph` (AGE writes off) is a later flip, still in this change's
rollout, not a second proposal. Removing AGE from the CNPG image is not.

Arbitration, confidence gating, stale-edge TTL, and canonical rebuild stay in
the existing Elixir/Rust logic. Only the persist/query adapter changes.

### D7. Rebuild-from-evidence is the data migration; AGE dump is the checksum

AGE is not the system of record. The migrator binary therefore has two modes:

1. **Rebuild** (default, operator-safe): run the existing canonical rebuild
   against Dgraph from current mapper evidence. This is the same function as
   `rebuild_canonical_links_from_current/0` with a Dgraph adapter. It is
   idempotent and is how a polluted graph is recovered after cutover too.
2. **Checksum**: walk AGE `platform_graph`, walk Dgraph, compare node/edge
   counts and a canonical-edge content hash. Fail the Job if they disagree
   beyond a documented tolerance (unresolved endpoints, stale inferred edges
   that the rebuild would drop anyway).

An AGE **dump-and-load** path exists as a bootstrap for lab graphs that have
no evidence tables, and as a debug aid. It is not the production cutover.
Dump output is synthetic-schema only in fixtures; live dumps never enter the
repository.

The binary lives at `rust/age-to-dgraph`, is built by Bazel, and is the image
the Helm Job runs. No script under `scripts/`.

### D8. SRQL grows a Dgraph entity; `graph_cypher` stays until AGE is gone

`in:graph_cypher` is a raw Cypher pass-through into AGE and is read-only
(mutations already rejected). During dual-read it keeps working.

Add `in:graph` (aliases: `graph_dql`) that runs read-only DQL through the
NIF/client. Same `{nodes, edges}` wrapper `graph_cypher` already emits so
God View and the causal hydrator do not grow a second parser.

The hydrator's `TOPOLOGY_EDGES_QUERY` switches from Cypher types
(`CONNECTS_TO`, `MANAGED_BY`, ...) to the equivalent DQL over `TopologyEdge`
nodes. That switch is gated on `GRAPH_READ`.

### D9. Dedicated Dgraph namespace, namespaced predicates

ACL is already on because **without it Dgraph namespaces do not isolate**
(verified on `dgraph-ci`: `create_namespace` succeeded, writes in the new id
were visible from namespace 0). ServiceRadar still uses a dedicated namespace
on **its own** cluster so CI runs do not collide. That is not a seam with
scrith.

Scrith and ServiceRadar SHALL NOT share a Dgraph instance. Scrith is expected
to run as cloud SaaS with its own cluster. Dgraph namespaces cannot be
queried across the way Postgres schemas can: there is no cross-namespace
join, and there is no cross-cluster one either. Hydration is an API, not a
shared tablet.

Predicate prefixes in this change: `device.`, `iface.`, `hop.`, `collector.`,
`topo.`, `prefix.`, `change.`. Do not use `svc.` / `endpoint.` (scrith). Do
not use unprefixed `name` / `id`.

Types: `Device`, `Interface`, `HopNode`, `Collector`, `Service`,
`TopologyEdge`, `Prefix`, `Change`. Device identity is the canonical
`sr:`-prefixed uid already used in AGE (`device.id string @index(exact)
@upsert`). Prefix identity is the CIDR string (`prefix.cidr`). Change
identity is the external change id (`change.id`).

### D10. Additional graphs are namespaced, not built

Later Dgraph use (service dependency, identity, CTI knowledge) gets its own
prefix and, if isolation demands it, its own namespace. This change does not
ship those schemas. The topology schema MUST NOT occupy generic predicates
that would block them. Prefix and Change **are** in this change; they are
topology, not a second product graph.

### D11. Postgres holds evidence; Dgraph holds traversal

The mapper pipeline already answers "where does this live":
`mapper_topology_links` / `discovered_interfaces` in CNPG, graph projection
for adjacency. Config and changes follow that split. Do not pick one store.

| Thing | Store | Why |
|---|---|---|
| Running/startup config body, hash, retrieved_at, source | CNPG Ash (`network_config_revisions`) | Blob + audit. Dgraph is a bad file store. |
| Parsed interface/prefix/VRF facts from a revision | CNPG Ash (`network_config_interface_facts`) | SRQL, source disagreement with SNMP, versioning. |
| Change record (window, kind, status, selector, source) | CNPG Ash (`network_changes`) | RBAC, history, overlapping-window SQL. |
| Device, Interface, TopologyEdge | Dgraph | Adjacency. Source is a predicate (`topo.ingestor`, `topo.evidence_class`), not a separate graph. |
| Prefix (CIDR) attached to interfaces/devices | Dgraph `Prefix` + CNPG fact row | "who is in this /24" is a graph question; the fact that the config declared it is inventory. |
| Change node with `change.affects` | Dgraph | Impact is a walk: affected nodes, then `@recurse` downstream. |
| "Should B wait for A?" | Query-time Dgraph, not a pre-materialized edge | Pairwise edges for every change pair explode; a window has a handful of changes. |
| Topology history / diffs | Dgraph snapshot namespaces + CNPG catalog | Same DQL against yesterday's namespace. Catalog maps `as_of` → namespace id. |

Raw configs MUST NOT be predicates on Device. Parsed JSON blobs MUST NOT be
predicates on Device. A Device may carry a `device.config_revision_id`
pointer (the CNPG key) so a UI can fetch the body without a second index.

*Alternative considered — put parsed interfaces only in Dgraph.* Rejected:
source disagreement with SNMP (canonical facts), SRQL listing, and "show me
yesterday's config" are relational problems. Losing CNPG means losing the
evidence rebuild path we just adopted for mapper topology.

*Alternative considered — put change impact only in SQL recursive CTEs.*
Rejected: that is what AGE was, and it is the thing we are leaving. Prefix
membership plus downstream of an upgrade set is Dgraph's job.

### D16. Graph versions are Dgraph namespaces

Dgraph has no row versioning. The way to keep two complete graphs you
can actually query is the same one Marvin is using in scrith: **one
namespace per version**. Namespaces cannot be joined (already measured:
without ACL they do not isolate; with ACL they isolate completely, and
there is no cross-namespace DQL). That is a feature here. Live queries
never filter `valid_from`. Yesterday is a different namespace with the
same schema and the same DQL.

| Namespace role | What it is |
|---|---|
| Live | The only namespace the projector writes on the hot path. God View, SRQL `in:graph`, hydrate snapshot. |
| Snapshot | Immutable copy of live at `as_of`. Same types, same predicates. Read-only. |
| Scratch | Dry-run / proposed graph for a change window. Dropped or retained until the window ends. |

**CNPG `topology_graph_snapshots`** is the catalog, not the graph:

- `as_of`, `reason` (`scheduled` | `change_window` | `manual` | `dry_run`)
- Dgraph `namespace_id`
- content fingerprint (node/edge counts + canonical-edge hash)
- optional `network_changes.id` / config revision that triggered it
- retention class

You do **not** mint a namespace on every projector tick. Snapshots are
taken on a schedule (daily is enough to answer yesterday vs today), on
an explicit change-window, and on demand. GC drops namespaces the
catalog has expired; scoped `remove` inside that namespace, never
`drop_all`.

Copying live → snapshot is a Dgraph-native export/import or a rebuild
from evidence as-of T into the new namespace. Either is valid; the
catalog does not care. Rebuild-from-evidence is the one we already
need for AGE cutover, so it is the default.

**Diff yesterday vs today.** Open both namespaces with the same DQL
neighbourhood / canonical-edge query, compare in the application (or
copy both into a scratch namespace if a later change wants a merged
view). Do not pretend Dgraph can JOIN them.

**Did this config change affect topology.** Either:

- diff the snapshot taken before the change against the one taken after,
  or
- a thin **mutation index** in CNPG (`topology_graph_mutations`:
  `as_of`, `op`, `link_key`, `payload_hash`, `evidence_refs`) so you
  can ask "which `link_key`s cite revision R" without cloning the
  whole graph. The index is not a substitute for a queryable
  graph-at-T; the namespace is.

**Will this proposed change affect topology.** Projector writes the
candidate graph into a **scratch namespace** (same schema, not live).
Query it with the same DQL as live. Diff scratch vs live. Drop the
scratch namespace unless the change window wants to keep it. Scoring
"this is a break" is later (scrith / DeepCausality).

Live edges still carry evidence refs (`topo.mutation_id` / config
revision / mapper key) so "why is this edge here" does not require a
snapshot.

*Alternative considered — only a CNPG mutation log, rebuild in memory.*
Kept as the delta index and as the rebuild source, but rejected as the
*only* versioning story. Operators will want to run the same God View /
`in:graph` query against yesterday. That is a namespace, not a SQL
replay.

*Alternative considered — valid_from / valid_to on live nodes.*
Rejected: every query grows a time filter, tombstones stay in the
hot graph, and it is not how Dgraph or scrith version worlds.

*Alternative considered — one namespace per projector run.* Rejected:
namespace explosion. Snapshots are gated (schedule, change window,
manual).

This matches scrith: DeepBrain revision tracking is "what changed and
why" in the catalog; the queryable world at T is its own Dgraph
namespace. ServiceRadar and scrith still do **not** share a cluster;
each versions *inside* its own.

Do not ship the time-travel UI in this change. Land: live vs snapshot
vs scratch roles, the catalog, snapshot/GC jobs, evidence refs, dry-run
into scratch.

### D12. Topology is source-agnostic; evidence class is not

Canonical rebuild already arbitrates competing mapper evidence
(`direct-physical` vs `inferred-segment` vs attachment). Config-declared
neighbors and prefixes enter that same rebuild as another class:

- `topo.ingestor` = `network_config_v1` (vs `mapper_topology_v1`)
- `topo.evidence_class` = `config-declared`
- `topo.protocol` = `config` (not LLDP/CDP/SNMP)

Physical backbone still prefers LLDP/CDP when both exist. Config fills
gaps LLDP never sees: interface prefixes, VRFs, declared L3 neighbors,
shutdown state. A config-only estate (no mapper job) still produces a
graph. A mapper-only estate is unchanged.

The config projector emits the same `projection_payload` maps
`TopologyGraph` already accepts. It does not invent a second writer.

### D13. Prefix and Change nodes

`Prefix` is a CIDR node, not a string on Device:

```
prefix.cidr: string @index(exact) @upsert .
prefix.family: string @index(exact) .
iface.prefixes: [uid] @reverse .   # Interface -> Prefix
```

Walking `~iface.prefixes` from a prefix is "every interface announcing this
CIDR". Devices in a change selector `192.0.2.0/24` resolve by prefix
membership, not by a SQL `<<` against `ocsf_devices.ip` alone (that misses
downstream networks sitting behind the upgraded box).

`Change` is a windowed work item, not a ticket dump:

```
change.id: string @index(exact) @upsert .
change.kind: string @index(exact) .          # upgrade | config | other
change.window_start: datetime @index(hour) .
change.window_end: datetime @index(hour) .
change.status: string @index(exact) .        # proposed | accepted | ...
change.source: string @index(exact) .        # opentext-na | manual | ...
change.affects: [uid] @reverse .             # Device | Prefix | Interface
```

Ticket comments, diffs, and approval history stay in CNPG. The graph node
is the selector plus the window.

Dgraph answers **facts**, not verdicts. A downstream walk
(`change.affects` expanded through Prefix membership, then `@recurse` along
canonical topology) is a Spaceoid: "B's targets sit downstream of A's".
ServiceRadar MAY expose that walk as a typed query so hydrators and tests
can pin it. It MUST NOT be the change-ordering product.

The verdict — postpone B, sequence B after A, or no constraint — is a
DeepCausality counterfactual: `intervene` on A's availability (or on the
config-declared state), propagate effects over the hydrated context, and
let `deep_causality_ethos` Teloids decide whether starting B in that
window is Impermissible, Obligatory-to-delay, or Optional. That reasoning
lives in scrith (D15), not in a ServiceRadar NIF.

Do not write `change.blocks` edges unless a later change proves the pair
set is large enough to need them.

### D14. Config ingest seam, narrow downparser

OpenText NOM inventory stays `list device`. Config pull is a **new plugin
action** on the same package (or a sibling package), not a field stuffed
into the inventory snapshot. It retrieves running (and optionally startup)
config for a device, submits it as an artifact result, and does not parse
in Wasm.

Core persists a `network_config_revisions` row (hash, source, kind,
retrieved_at, body). A downparser job reads the body, writes
`network_config_interface_facts`, and feeds `TopologyGraph` as D12.

V1 parser extracts, per interface stanza: name, IPv4/IPv6 prefix, description,
VLAN, shutdown. That is enough to populate Prefix nodes and to attach
devices to change selectors. BGP/OSPF/ACL stanza parsers are follow-ups;
the facts table is additive.

Fixtures are invented IOS-like text. Live OpenText dumps do not enter the
repository.

### D15. Scrith is the intelligence core; NMS systems plug in

Marvin's Archive writeups (Scrith Foundation, Dynamic Intelligence,
DeepBrain + Scrith) put the products in this order, which this change
follows:

1. **Knowledge sources** — operational databases, documents, cloud
   systems, internal tools. An NMS is one of those sources.
2. **Enterprise integration / extension layer** — connectors and
   adapters. This is where an NMS plugs into scrith. The DeepBrain +
   Scrith diagram names the northbound seam **Context Exchange Protocol
   (CXP)**.
3. **Scrith intelligence layer** — knowledge extraction, dynamic
   intelligence, action enablement (verdicts, Ethos, audit).
4. **DeepBrain** — content, ontology, and context hypergraphs on
   scrith's own store. DeepCausality reasons over that context
   (`intervene`, effect log, Teloids).

ServiceRadar is the **reference NMS plugin**, not the only NMS and not
the reasoner. Other NMS products implement the same extension contract.
Do not assume `add-causal-engine` lands in ServiceRadar.

| Layer | Owner | This change |
|---|---|---|
| Evidence (configs, mapper links, change rows, telemetry) | ServiceRadar | Build |
| NMS-local topology graph | ServiceRadar Dgraph | Build |
| NMS extension snapshot (assets, links, prefixes, changes, telemetry) | ServiceRadar implements the plugin contract | Build the SR side |
| Scrith extension host + CXP | Scrith SaaS | **Scope, do not build** |
| Scrith core + DeepBrain hypergraphs + DeepCausality | Scrith SaaS | **Scope, do not build** |

Integration contract to freeze now, implement later:

1. **Separate Dgraph instances.** The NMS cluster is not the scrith SaaS
   cluster. Namespaces isolate *inside* one cluster; they are not a join.
   There is no cross-namespace query.
2. The NMS is the only writer of its topology. Scrith never mounts that
   cluster.
3. The **extension contract** is a network snapshot (CXP-shaped):
   assets, links, prefixes, proposed changes, bounded telemetry. Scrith
   copies it into DeepBrain (its Dgraph / hypergraphs) or an in-process
   DC Context. ServiceRadar's snapshot API is the reference
   implementation of that contract, not a ServiceRadar-private RPC.
4. ChangeImpact is a scrith-core RPC. Any NMS plugin that can emit two
   change selectors against a topology snapshot can use it.
5. Ethos Teloid example: "IF change B starts in A's window AND B is
   downstream of an availability-impacting A THEN starting B is
   Impermissible (delay)".
6. Tracking actual vs projected is a later loop. Not in this change.

This ServiceRadar change delivers the SR graph and the reference plugin
snapshot. The extension host, CXP, causaloid catalog, Ethos, and
DeepBrain ingest are GitHub issues on `carverauto/scrith`.

## Risks / Trade-offs

- **Dual-write divergence** → Rebuild-from-evidence is the recovery; checksum
  Job fails the upgrade if hashes disagree; `GRAPH_READ` does not flip on a
  failed report.
- **NIF/runtime coupling** → Dedicated tokio runtime, DirtyIo, panic isolation.
  A Dgraph outage surfaces as `{:error, _}` to Elixir, not a BEAM crash.
- **Git crate vs crate_mirror** → Prefer crates.io publish (D1). Git spec is a
  documented exception, not a new default.
- **Shared cluster blast radius** → Dedicated namespace + scoped `remove`.
  Deprovision requires confirm. Never `drop_all`.
- **Edge-as-node query cost** → Extra hop versus a Cypher relationship. Paid
  for property fidelity and `@reverse`. Neighbourhood queries hydrate in two
  steps (skeleton then batch) the way scrith already does for endpoints.
- **Pending AGE deltas** (risk scalars, reverse `MANAGES`, `CONTAINS`) →
  Implement them on Dgraph `Device` / `TopologyEdge` predicates, not by
  adding AGE Cypher. Do not block on `add-causal-engine` remaining in
  ServiceRadar.
- **CNPG baseline / AGE catalogs** → Unchanged until AGE is dropped. The
  known non-round-trip of `create_graph()` is why we are leaving, not
  something this change fixes.
- **Config-vs-LLDP disagreement** → Same canonical-fact / arbitration path
  as mapper confidence. Config does not silently overwrite a
  `direct-physical` backbone edge.
- **Prefix walk cost** → Change windows are small. Expand prefixes to
  devices first, then recurse; do not recurse from every CIDR in the
  estate.
- **OpenText config API incompleteness** → The seam (revision row +
  projector) is testable with a fixture revision and does not block the
  Dgraph cutover if the plugin action lands later in the same change.
- **Namespace explosion** → Snapshot on schedule / change window /
  manual, not per heartbeat. Catalog-driven GC. Scratch namespaces are
  short-lived.

## Migration Plan

1. Publish or pin `dgraph-client` / `dgraph-migrate`. Land `rust/dgraph-topology`
   schema (including Prefix and Change) + NIF against `dgraph-ci` and compose.
2. Helm: embed Dgraph (default-on, `single`/`ha` profiles), ACL Secret,
   schema Job. Compose: Dgraph service.
3. Dual-write (`GRAPH_BACKEND=dual`, `GRAPH_READ=age`). Rebuild-from-evidence
   into Dgraph. Checksum against AGE.
4. Flip `GRAPH_READ=dgraph` in demo, then staging. God View, SRQL `in:graph`,
   causal hydrator read Dgraph.
5. Flip `GRAPH_BACKEND=dgraph`. AGE writes stop. Keep AGE readable for one
   release as a rollback hatch.
6. Follow-up change: drop `graph_cypher`, drop AGE from the CNPG image, drop
   `ServiceRadar.Graph`.

Rollback at step 4: `GRAPH_READ=age`. Rollback at step 5: re-enable dual-write
and rebuild AGE from evidence (the evidence tables never moved).

## Open Questions

- Crates.io publish of `dgraph-client` / `dgraph-migrate` versus a temporary
  git `crate.spec`. Default: publish; git only if the first pin would block
  the NIF landing.
- Exact Dgraph namespace id on the ServiceRadar cluster (CI isolation
  only). Default: dedicated namespace, not 0, topology predicates as D9.
  Not shared with scrith.
- Whether `in:graph` accepts raw DQL from operators or only canned projections
  plus a guarded escape. Default: raw **read-only** DQL, mutations refused,
  matching today's `graph_cypher` contract.
- OpenText config-retrieve command name and whether startup-config is in
  v1 or running-config only. Default: running-config only.
- Whether a change selector that is "this VRF" or "this device group" is
  v1. Default: v1 selectors are device uid, IP, and CIDR prefix only.
