# Design: collectors on a shared ingest pipeline

## Context

What exists on `staging` when this is written:

| Collector | Source | Receives | Publishes | Format |
| --- | --- | --- | --- | --- |
| Syslog | `rust/flowgger` in `rust/log-collector` | blocking UDP `recv_from`, TCP, TLS | `logs.normalized.syslog`, or `logs.syslog` without a ruleset | OTLP batches; JSON without a ruleset |
| OTLP | `rust/otel` in `rust/log-collector` | gRPC and HTTP | `logs.otel`, `otel.traces.raw`, `otel.metrics.raw` | OTLP protobuf chunks |
| SNMP traps | `rust/trapd` | tokio UDP | `logs.snmp` | one JSON message per trap |
| Flows | `rust/flow-collector` | tokio UDP, IPFIX over TCP/TLS | `flows.raw.*` | protobuf |
| BMP | `rust/bmp-collector` | TCP | `arancini.updates.*` | JSON |

Every collector is Rust. None reads NATS key-value directly: the only reader of
rule bundles is the log collector, through datasvc gRPC
(`rust/log-collector/src/rules.rs`), behind store-agnostic `Connector` and
`Session` traits. `rust/zen-normalize` already holds compile, apply, bundle
parsing and activation, with no transport dependency.

Core runs Zen in one place, `EventWriter.Processors.Logs`, on JSON arriving on
`logs.syslog`, `logs.snmp`, `logs.otel` and `logs.internal.*`. Protobuf on
`logs.otel` and everything on `logs.normalized.*` already skip it.

No edge collector bundle has a `[rules]` section, so every edge log collector
runs in JSON mode.

## Goals / Non-Goals

Goals:
- One way for any collector, in the cluster or at the edge, to get its rules.
- No Zen in core for data a collector produced.
- One implementation of receive, rules and publish, each used by every collector
  that needs it.
- No JSON encode in a collector followed by a JSON decode in core.

Non-goals:
- Changing what the rules do.
- Moving Falco or the agent-relayed OTLP path.
- Stream sharding; that stays in `partition-log-ingestion`.
- Removing Zen from core for `logs.internal.*`.

## Decisions

### 1. Rule bundles live in a dedicated NATS key-value bucket

Core writes each bundle to a bucket that holds nothing else, under the key it
uses today (`zen/rulesets/<stream>/<subject>.json`). The bundle format, its
schema marker and its digest do not change.

A dedicated bucket is required, not a convenience. The datasvc bucket also
holds agent configuration, and a NATS permission or a mirror applies to a whole
bucket's subject space. Collectors get read access to the rules bucket and
nothing else.

Core writes the bucket through its own NATS connection. Per-rule keys and the
index that `ZenRuleSync` also writes for other consumers stay where they are
until those consumers are identified and moved; this change moves only the
bundles collectors read.

Alternatives considered:
- *Proxy rule reads through the agent or agent gateway.* Works, but adds a
  request path and a failure mode to two services to deliver a file NATS can
  already replicate.
- *Keep datasvc and expose it to the edge.* Rejected: it widens the edge's
  reach into the control plane.

### 2. The collector reads the bucket over its existing NATS connection

A new implementation of the existing `Connector`/`Session` traits reads and
watches the bucket. `follow()` keeps its behaviour: fetch on every connect,
then watch; bounded request time; backoff between 1 and 30 seconds; the active
ruleset stays in use and is reported stale while the store is unreachable.

### 3. Edge leaves mirror the rules bucket

Each leaf's JetStream domain holds a read-only mirror of the hub's rules
bucket. The edge collector reads the mirror through its local leaf.

This is the part of the design that is **not yet verified**. The repository
defines no stream mirror or source between a leaf domain and the hub, and the
hub-side account a managed leaf binds to was not located. Before any edge work
starts, task 2.1 proves on a real leaf that a key-value mirror across the leaf
connection can be created with the permissions a managed leaf has, survives a
disconnect, and catches up afterwards. If it cannot, the fallback is for the
collector to read the hub bucket through the leaf connection using the hub's
JetStream domain, which loses offline operation but keeps the same code.

### 4. No ruleset means pass-through, not a JSON fallback

Today a collector without an active ruleset publishes JSON and core normalizes
it. That fallback is the reason core must keep rules for collector data.

Instead, the collector always publishes the binary batch format on the same
subject, `logs.normalized.<kind>`, with the schema header. With an active
ruleset it applies the rules and sets `Sr-Ruleset-Id` to the ruleset digest.
Without one it applies only the built-in field mapping and sends no
`Sr-Ruleset-Id` header, so a stored row shows which case it was.

A batch on `logs.normalized.<kind>` without `Sr-Ruleset-Id` is authorized
built-in-mapping pass-through. EventWriter stores it without rules, records that
no ruleset was applied, and neither runs Zen on it nor rejects it. The trust
comes from the NATS publish permission on `logs.normalized.`, which only
collector identities and the edge leaf that forwards an edge collector's
batches hold; a missing header is not a claim a sender on another subject can
make. This
amends the trust and binary-contract requirements of `accelerate-log-ingestion`.

Consequence: records that arrive before the first ruleset are stored without
rule effects (for syslog: severity mapping, the WAF and CEF rules, the
message-stripping rule). This is accepted. The alternative, holding records
until rules arrive, risks loss on a collector that never reaches its store.

### 5. Core runs no rules on collector data

`EventWriter.Processors.Logs` stops calling Zen for subjects a collector
produces. It keeps Zen for `logs.internal.*`, which core produces and which has
no collector to move the rules to.

JSON on `logs.syslog`, `logs.snmp` and `logs.otel` is then stored with the
built-in mapping and no rules. That keeps an older collector working during an
upgrade; it does not keep its rules working. The removal is therefore per
subject: Zen stops for a subject one release after that subject's replacement
publisher ships, and stays for subjects whose release has not arrived.

### 6. Shared crates

Three library crates, each usable without the others:

- **receive**: the receive backends from `add-zero-copy-log-receivers`
  (batched UDP and async TCP as the portable baseline; io_uring and AF_XDP as
  explicit, verified options) behind one interface that hands out leased
  buffers.
- **rules**: grows from `rust/zen-normalize`. Adds the NATS key-value
  `Connector`, and moves `follow()` out of `rust/log-collector` so any
  collector can follow a bundle.
- **publish**: the batch builder and NATS output now inside
  `rust/flowgger` (close by count, bytes or age; never mix rulesets in a batch;
  retry the same bytes with the same message ID).

A collector keeps its protocol parser and its record-to-column mapping.

### 7. Order of work

Each step ships on its own and is measured before and after.

1. Rules bucket, NATS reader, edge mirror. Syslog uses them. One release
   later, the collector's datasvc reader and role are removed. Core stops
   writing bundles to datasvc once no consumer reads bundles from datasvc, and
   not before one release after the NATS reader ships.
2. Pass-through without a ruleset. One release later, core drops Zen for
   syslog.
3. Extract the publish and rules crates from the log collector.
4. OTLP logs: rules applied in the collector, including for protobuf. This
   settles task 3.1a of `accelerate-log-ingestion`. One release later, core
   drops Zen for `logs.otel`.
5. Trap daemon: final fields emitted natively, binary batches through the
   publish crate, no rules. The rule editor stops offering the trap subject in
   that release. One release later, core drops Zen for `logs.snmp` and the
   seeded trap rules, including `snmp_severity`, are removed in the same
   release.
6. BMP collector: binary batches through the publish crate in place of JSON.
7. Receive crate, adopted first by syslog, then the trap daemon and the flow
   collector. The flow collector adopts only this crate; it already publishes
   protobuf.

Which crates each collector adopts:

| Collector | receive | rules | publish |
| --- | --- | --- | --- |
| Syslog | yes | yes | yes |
| OTLP logs | no (gRPC and HTTP) | yes | yes |
| SNMP traps | yes | no | yes |
| BMP | no | no | yes |
| Flows | yes | no | no |

### 8. Traps need no rules

The seeded trap rule (`snmp_severity`) sets severity, derived `source_ip`,
`source` and `service_name` set to `snmp`, the rule's `body` text, and
`attributes.snmp` source, version, community, varbinds, trap OID and detail.
That is field mapping. The daemon produces all of those fields when it builds
the record, except `attributes.snmp.community`, which is a credential and is no
longer stored. The exact expressions are those in
`elixir/serviceradar_core/priv/zen/rules/snmp_severity.json`; task 6.2's
comparison with today's stored row is the authority on what the daemon emits.

The trap daemon therefore does not use the rules crate. It does adopt the
receive crate, with the io_uring and AF_XDP backends available to it as for any
collector, and publishes binary batches through the publish crate as a
collector without a ruleset does (decision 4). Both are definite steps, not
gated on trap volume: a trap storm is the case where receive and encode cost
matter, so the move is measured by CPU and by traps lost during a synthetic
trap storm, before and after.

## Risks / Trade-offs

- **The edge mirror is unproven** (decision 3). Mitigation: it is the first
  task, with a stated fallback.
- **Records before the first ruleset lose rule effects** (decision 4).
  Mitigation: the collector exposes its ruleset status, and the stored row
  shows whether rules ran.
- **A custom rule on the trap subject stops working.** Mitigation: the upgrade
  note says so, and the rule editor stops offering that subject when the new
  trap publisher ships. The seeded trap rules stay until the release that stops
  Zen on `logs.snmp`, so the previous trap daemon's records are stored as today
  during the one-release window.
- **Zero-copy backends need kernel features and privileges.** They stay
  optional and off by default, as `add-zero-copy-log-receivers` requires.
- **Three crates is more surface than one collector.** Mitigation: each crate
  is extracted from code that already runs in production, not designed ahead
  of a second user.

## Migration Plan

1. Core writes bundles to both the datasvc bucket and the rules bucket.
2. Collectors that read the rules bucket ship. Old collectors keep reading
   datasvc.
3. One release later, the collector's datasvc role is removed. Core stops
   writing bundles to datasvc once no consumer reads bundles from datasvc, and
   not before one release after the NATS reader ships. Per-rule keys and the
   index are a separate write and are unaffected.
4. Core's Zen path for a subject is removed one release after the collector
   that makes it unnecessary.

Rollback at any step is the previous release: bundles are still in both places
until step 3.

## Open Questions

- Which hub account does a managed leaf bind to, and can it create a mirror in
  its own domain? (Task 2.1.)
- Who else reads the per-rule keys and index `ZenRuleSync` writes to datasvc?
- Should the BMP batches use an existing schema or a new protobuf message?
