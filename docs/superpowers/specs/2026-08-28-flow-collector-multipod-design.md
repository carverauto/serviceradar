# Flow Collector Multi-Pod Ingest - Design

Issue: #4107. Follows #4103, which landed the shared NATS KV template store.

## Problem

The flow collector runs as a single-replica Deployment and cannot safely run
more than one pod. The SaaS target is a fleet of exporters whose size is not
known in advance -- the working figure is ~25,000 routers, but it could be half
or double that, so the design must absorb a range rather than hit a number.

Three independent limits bind before any of that is reachable.

### 1. Hard 10,000-exporter ceiling per pod

`netflow_parser` caps tracked sources per parser:

```rust
// scoped_parser.rs:24
pub const DEFAULT_MAX_SOURCES: usize = 10_000;
```

It is an LRU: sources past the cap are evicted, not rejected. The crate exposes
`AutoScopedParser::with_max_sources()` and `rust/flow-collector/` never calls
it. The existing `max_templates` knob is not this -- it maps to
`with_cache_size` (`netflow/mod.rs:117`), sizing the per-source *template*
cache. There is no source-count knob today.

### 2. The collector is a control-plane singleton

`Publisher::ensure_owned_stream` runs per pod at startup. It creates/updates
the `flows` JetStream stream and reconciles the owned subject list from durable
markers on a ReadWriteOnce PVC (`flow-collector-rehome.json`,
`flow-collector-ownership.json`, `flow-collector.ready`). There is no leader
election. N pods means N concurrent stream create/update calls racing on
divergent views, which is also why the chart pins `strategy: Recreate`.

That machinery exists for one purpose: making the one-time `events` -> `flows`
subject cutover crash-safe and rollback-able. It landed 2026-08-24. On farm01
and demo the cutover is complete -- the rehome marker is absent, `events`
carries no `flows.raw.*`, and the ownership inventory records exactly what
config already resolves to. But a customer upgrading from a pre-cutover release
still needs it to run, so it is kept, not deleted.

### 3. CPU quota silently caps parser throughput

Measured on farm01: the container has `cpu.max: 50000 100000` (0.5 CPU). Tokio's
`available_parallelism()` honours the cgroup quota, so despite `nproc: 8` the
process runs with exactly **one** `tokio-rt-worker`. Per-pod throughput is
therefore bounded by a single worker regardless of node size, and adding
replicas is the only way to add parsing parallelism until the CPU limit is
raised.

This also makes any synchronous, blocking bridge on that runtime dangerous --
see Prerequisite below.

## Prerequisite: template-store runtime isolation

The `TemplateStore` trait is synchronous. As merged in #4103, the bridge used
`block_in_place` + `Handle::block_on` on the collector runtime, with the
async-nats connection driver spawned on that same runtime. On a single-worker
runtime a synchronous parser call blocks the only worker waiting for a KV reply
that the blocked worker is itself responsible for driving.

The fix moves the entire async NATS lifecycle -- connection, driver, bucket
bootstrap, and operations -- onto a dedicated worker thread with its own
current-thread runtime, reached through a bounded queue. The parser keeps a
synchronous, fail-fast interface; each operation stays capped at 500ms, callers
cap the reply wait at 600ms, and saturation degrades to the local cache via
`TemplateStoreError::Backend`.

This work exists as two local commits (`8fd5912e5b`, `69da65b226`, preserved on
`preserve/template-worker-runtime`) and **must land before any replica work**.
It is a correctness fix to already-merged code, not part of the scaling effort,
and should ship as its own PR.

## What is already solved

* **Cold-pod template availability** -- the shared NATS KV template store
  (#4103). Any pod can decode any exporter's flows.
* **Source-IP preservation** -- `externalTrafficPolicy: Local`. The parser
  scopes templates per `(source_ip, source_id)` (RFC 3954) and
  `(source_ip, observation_domain_id)` (RFC 7011), so this is mandatory for any
  multi-pod shape and is already set.
* **Traffic distribution across nodes** -- farm01's LB IP comes from a MetalLB
  **BGP** pool, so ECMP can already spread UDP across nodes holding a pod.
  `sessionAffinity: ClientIP` then pins an exporter to a pod, keeping template
  locality high and the KV store a fallback rather than a hot path.
* **Per-pod observability** -- `/metrics` is real as of #4103.
  `flow_collector_sources` is the gauge that reports proximity to the cap.

## Design

### Phase 1: move stream bootstrap into a Helm hook Job

Add a `--bootstrap-stream` mode to the existing flow-collector binary. The
Helm chart gains a `pre-install`/`pre-upgrade` hook Job that runs the same
image in that mode; it performs the full `ensure_owned_stream` path -- rehome
marker recovery, cutover, rollback, ownership inventory -- and exits.

Reusing the binary rather than writing a separate tool is deliberate: the
cutover state machine is subtle and crash-safe, and a second implementation
would have to be kept in behavioural parity by hand.

The PVC is retained but its mount **moves from the Deployment to the Job**. The
Job is a singleton by construction, so ReadWriteOnce remains correct and the
audited crash-safety semantics are preserved exactly. Markers are deliberately
not moved into NATS KV, which would make the marker depend on the same
JetStream state it exists to protect.

### Phase 2: make collector pods stateless

Stream create/update is **not** a single startup call. `ensure_owned_stream` is
reached from eight sites: publisher startup plus seven runtime recovery paths
via `recover_owned_stream` (`reconnect`, `stream missing`, `shutdown drain`,
`ambiguous publish generation changed`, `forced reconnect after ambiguous
publish`, `shutdown quarantine generation changed`, `shutdown forced
reconnect`). Each clears readiness, re-ensures, and re-marks ready. That
create/update is the publisher's self-healing mechanism, so removing it would
trade unattended recovery for single-writer purity.

**Decision: keep the ensure, make its inputs identical across pods.** The race
this design feared comes from *divergent* views, and the only source of
divergence is the per-pod durable markers. Once those move to the bootstrap Job
(Phase 1) and the PVC leaves the pods, every pod derives its subject list from
config alone, so concurrent calls converge instead of conflicting.

Both halves of that were measured on farm01 against a throwaway stream:

* **8 concurrent identical** `stream add` calls -> all exit 0, no error output.
* **2 concurrent divergent** calls (differing subject lists) -> one exits 1.

So identical inputs are safe and divergent inputs genuinely conflict, which is
exactly why the markers must leave the pods.

Concretely:

* `load_ownership_inventory` and `load_rehome_marker` both return `Ok(None)`
  when their file is absent, so pods without the PVC derive subjects purely
  from `config.stream_subjects_resolved()` with no code change to the readers.
* The rollback/detach branch is gated on `stream_name == "events"` and so never
  runs in a pod configured for `flows`.
* `/var/lib/serviceradar` becomes an `emptyDir` rather than disappearing: the
  ready marker and the ownership inventory are still written, but per-pod and
  discarded on restart. The Job keeps the real PVC for cutover markers.
* Readiness becomes `httpGet /metrics`, replacing the ready-file exec probe.
  This is only possible because #4103 made the endpoint real; it also catches a
  deadlocked-but-running process, which the file check cannot.
* Drop the PVC and the `ready_state_path` / `rehome_state_path` writes from the
  Deployment.

After this phase the data pods hold no durable state and perform no
control-plane operations.

### Phase 3: expose the source ceiling

* Add `max_sources` to the netflow listener config, plumbed to
  `AutoScopedParser::with_max_sources()` (a consuming builder returning
  `Result`, chained after `try_with_builder`).
* Surface it in chart values and document it.
* Alert on `flow_collector_sources` approaching the configured cap.

The cap stays finite -- it exists to bound memory against spoofed source
addresses -- but becomes an operator decision instead of a library default.

### Phase 4: allow replicas

* `strategy: Recreate` -> `RollingUpdate`. The Recreate pin existed to avoid
  two live publishers during a subject rehome; after Phase 1 no pod performs a
  rehome.
* Permit `replicaCount > 1` with pod anti-affinity.
* Document the capacity model: exporters distribute by ECMP hash plus ClientIP
  affinity, which is uneven and uncontrollable, so replicas are sized for
  headroom against imbalance rather than for an exact per-pod source count. An
  evicted-and-readmitted source recovers templates from KV instead of losing
  data, which is what makes accepting imbalance tolerable.

Deliberately **not** a DaemonSet: that ties pod count to node count when the
axis that matters is ingest volume, and it cannot share the Job's PVC.

## Testing

* **Phase 1** -- unit coverage for the bootstrap mode's argument handling;
  chart render tests asserting the hook Job exists with the right
  annotations/weights and that the Deployment no longer mounts the PVC. Verify
  on a cluster that a fresh install and an upgrade both leave the `flows`
  stream with the correct subject list.
* **Phase 2** -- assert the publisher performs no stream create/update; verify
  the dup_window read path returns the same value the create path did. Confirm
  readiness flips correctly when `/metrics` is unreachable.
* **Phase 3** -- config deserialization tests; a test asserting the configured
  value reaches the parser.
* **Phase 4** -- with replicas > 1 on farm01, confirm every pod receives
  traffic, `flow_collector_sources` splits across pods, no pod logs stream
  create/update, and `flows` last_seq advances continuously across a rolling
  update.

Throughout, the regression signals are `flow_collector_flows_dropped_total`,
`flow_collector_template_store_backend_errors_total`, and the UDP receive queue
and drop counters in `/proc/net/udp` for ports 2055 and 6343.

## Rollout order

1. Land the runtime-isolation prerequisite (own PR).
2. Phase 1 + 2 together -- Phase 2 is unsafe without Phase 1, and Phase 1 alone
   leaves dead code in the pods.
3. Phase 3.
4. Phase 4, exercised on farm01 before any customer-facing release.

Phases 1 and 2 deliver no visible scaling on their own. Phase 4 is a small
chart change that is only *safe* because of them.

## Open question

Whether the eventual shape at fleet scale is one deployment with several
replicas or sharding by exporter pool (separate deployments, LB endpoints,
subject prefixes, and `template_store.kv_bucket` values). Phases 1-3 are
prerequisites either way, so this does not block.
