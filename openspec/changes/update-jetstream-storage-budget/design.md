# Design: JetStream storage budget

## Context

How NATS places a stream (nats-server 2.14, `server/jetstream.go` and
`server/jetstream_cluster.go`):

- A stream with `max_bytes > 0` adds `max_bytes` to `ReservedStore` on every
  server holding a replica. A stream with `max_bytes <= 0` reserves nothing.
- A server's available space is
  `max_file_store - max(ReservedStore, Store)`. A replica is placed only on a
  server with `available >= max_bytes`; candidates are tried most-available
  first.

So the budget is per server, R3 streams cost their size on every server, and
unlimited streams are invisible to reservation accounting but still consume
headroom through `Store`.

Default reservations on v1.4.73 (three NATS servers, `maxFileStore: 30G` =
27.94 GiB):

| Stream / bucket | Owner | max_bytes | Replicas |
| --- | --- | --- | --- |
| `KV_serviceradar-datasvc` | datasvc | 4 GiB | 3 |
| `OBJ_serviceradar-objects` | datasvc | 10 GiB | 3 |
| `events` | otel log-collector | 2 GiB | 3 |
| `flows` | flow-collector when enabled / EventWriter otherwise | 10 GiB | 3 / 1 |
| `OBJ_serviceradar_plugins` | web-ng | unlimited | 3 |
| `metrics`, `k8s_inventory`, `analytics_predictions`, `mtr_results` | EventWriter | 1 GiB each | 1 |
| `scan_results` | EventWriter | 0.25 GiB | 1 |
| `NOTIFICATIONS` | core notifications | 1 GiB | 1 |
| `trivy_reports`, `ARANCINI_CAUSAL` | EventWriter | unlimited | 1 |
| fieldsurvey, threat-intel object stores | web-ng / core | unlimited | 1 |

With flow-collector enabled: 26 GiB of R3 on every server, 1.94 GiB left,
5.25 GiB of R1 to spread. Fragmentation leaves no server with 1 GiB.

## Goals / Non-Goals

- Goals: a default install, with or without flow-collector, can always place
  every stream ServiceRadar creates plus headroom for streams future releases
  add; the rule is a pure function of values, so it is idempotent and holds
  for any environment; existing installs converge on upgrade with no manual
  step; one unplaceable stream never stops unrelated ingestion.
- Non-Goals: changing the NATS PVC default (StatefulSet
  `volumeClaimTemplates` is immutable, so a new default breaks every existing
  upgrade); making EventWriter streams R3; auto-sizing from live cluster state
  (`lookup` returns nothing under `helm template` and Argo CD).

## Decisions

### D1. EventWriter isolates per-stream setup failures

`Producer.finalize_consumer_setup/3` currently closes the connection when any
required consumer fails and retries all of them. It SHALL instead keep the
successful consumers and schedule a retry, with exponential backoff capped at
60 s, for each failed stream alone. A failed stream emits
`[:serviceradar, :event_writer, :consumer_setup, :failed]` with the stream
and NATS error code, logs once per backoff step, and raises a health event
naming the stream. This is the guard that protects every environment
regardless of sizing, including operator-created streams the budget cannot
know about.

The existing `best_effort` split stays for drain consumers.

### D2. `max_file_store` is rendered in bytes

`templates/nats.yaml` renders `max_file_store: <integer>`. When
`nats.jetstream.maxFileStore` is unset, the value is
`bytes(nats.persistence.size) - nats.jetstream.filesystemReserve` (default
1 GiB), which is 29 GiB for the 30Gi default. An explicit `maxFileStore`
keeps working and accepts `Gi`/`G` suffixes, parsed by a helper so that
`30G` and `30Gi` mean what NATS means (10^9 vs 2^30).

### D3. Every created stream has a finite `max_bytes`

New defaults: `trivy_reports` 1 GiB, `ARANCINI_CAUSAL` (EventWriter-created)
1 GiB, `OBJ_serviceradar_plugins` 2 GiB R3, fieldsurvey and threat-intel
object stores 1 GiB each. The EventWriter-created `flows` stream (used only
when flow-collector is disabled) drops to 1 GiB; flow-collector continues to
reconcile it to `flowCollector.config.stream_max_bytes` when enabled.

### D4. Smaller datasvc defaults

`datasvc.bucketMaxBytes` 4 GiB -> 1 GiB and `datasvc.objectStoreBytes`
10 GiB -> 4 GiB, both R3. The KV holds kilobytes of configuration. The object
store is `DiscardNew`, so a full bucket rejects writes rather than evicting;
4 GiB is twice the cap the reference demo install runs on.

### D5. Render-time budget check

A helper sums, per server:

```
R3  = sum(max_bytes of streams with replicas == nats.replicas)
R1  = sum(max_bytes of single-replica streams)
max = largest single-replica max_bytes
need = R3 + R1 / nats.replicas + max
```

`R1 / replicas + max` bounds the most loaded server under most-available-first
placement, so `need` is the space the worst server may hold. The chart
`fail`s when `need > 0.85 * max_file_store`, listing every term. The 15%
margin is room for streams a later release adds, which is exactly the
v1.4.73 failure. `nats.jetstream.allowOvercommit: true` skips the check.

Defaults after D3/D4 (max_file_store 29 GiB, limit 24.65 GiB):

| Shape | R3 | R1 | need |
| --- | --- | --- | --- |
| flow-collector enabled (flows 10 GiB R3) | 19 | 9.25 | 23.08 |
| flow-collector disabled (flows 1 GiB R1) | 9 | 10.25 | 13.42 |

### D6. Owners never shrink below stored bytes

datasvc (`reconcileStreamConfigLocked`), the otel log-collector and
EventWriter reconcile `max_bytes` on existing streams. When the configured
value is below the stream's current `Store`, the owner SHALL keep the larger
of the two and log both values. Lowering a default therefore converges
installs whose data fits and never evicts data from one that does not; the
next upgrade after the data ages out completes the shrink.

### D7. `core.eventWriter.enabled` honours `false`

Render with `ternary` / `hasKey` instead of `default true`.

## Risks / Trade-offs

- **Hard fail on upgrade.** An install whose explicit overrides exceed the
  budget stops upgrading until values change or `allowOvercommit` is set.
  This is deliberate: such an install is one new stream away from the
  v1.4.73 outage. The message names each reservation so the fix is a values
  edit. Alternative considered: warn in `NOTES.txt` only; rejected because
  nobody reads upgrade notes on an automated Argo sync.
- **Smaller object store.** An install already using more than 4 GiB keeps
  its current size (D6) and does not lose data, but new installs cap earlier.
- **EventWriter sizes move to values.** Two sources of truth for defaults
  (Elixir constants and Helm) must not drift; the Elixir constants become the
  fallback only when the env var is absent, and a helm-unittest asserts the
  chart renders every stream's env var.

## Migration

No manual step for installs on chart defaults: the next upgrade lowers KV and
object-store caps (D6 permitting), sets finite caps on unlimited streams, and
renders the byte-exact `max_file_store`. Installs that override
`maxFileStore` below the derived value, or raise datasvc sizes, get an
itemised render failure and adjust values.

## Resolved Questions

1. Over budget: the render fails by default, with
   `nats.jetstream.allowOvercommit: true` as the opt-out.
2. `OBJ_serviceradar_plugins` defaults to 2 GiB R3. Implementation checks
   this against the largest first-party Wasm and native add-on bundles.
3. The 15% margin is fixed, not a value; `allowOvercommit` covers operators
   who want to run hotter.
