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

- Goals: a default install of every OSS shape (Helm, Docker Compose,
  packaged), with or without flow-collector, can always place every stream
  ServiceRadar creates plus headroom for streams future releases add; the rule is a pure function of values, so it is idempotent and holds
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

`templates/nats.yaml` renders `max_file_store: <integer>`.
`nats.jetstream.maxFileStore` stays an explicit value whose chart default
stays `30G`; a helper parses the `G` (10^9) and `Gi` (2^30) suffixes the way
NATS does, so the default renders `30000000000` (27.94 GiB), exactly what
NATS enforces today.

`max_file_store` is deliberately not derived from `nats.persistence.size`.
Deriving it as the PVC size minus a reserve raises the cap toward the disk:
on a 30Gi ext4 volume usable space is below 30 GiB, NATS writes index and
metadata files beyond stream `max_bytes`, and a 1 GiB reserve risks a full
disk, which is worse than an unplaceable stream. `persistence.size` also
diverges from the real claim after an out-of-band PVC expansion, because the
StatefulSet claim is immutable. The budget passes at 27.94 GiB, so no raise
is needed.

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

Each stream's replica count comes from its own chart value:
`datasvc.jetstreamReplicas` (KV and object store),
`logCollector.streamReplicas` (`events`),
`flowCollector.config.stream_replicas` (`flows`, only when flow-collector is
enabled), `webNg.pluginStorage.jetstreamReplicas` (plugins), and 1 for every
EventWriter-created stream. With `n = nats.replicas`, a stream is classified
by comparing its replicas `r` to `n`:

```
full   = streams with r >= n        (a replica lands on every server)
rest   = streams with r <  n        (spread over the servers)
need   = sum(max_bytes of full)
       + sum(max_bytes * r of rest) / n
       + max(max_bytes of rest)
```

`sum(max_bytes * r) / n` is the even-spread share of the partial streams, and
the largest partial stream added on top bounds the most loaded server under
most-available-first placement, so `need` is the space the worst server may
hold. An intermediate count (R2 or R3 streams on a 5-server NATS) is
therefore in `rest`, weighted by `r / n`, not dropped from the sum. A stream
with `r > n` cannot be placed at all and counts as `full`.

The chart `fail`s when `need > 0.85 * max_file_store`, listing every stream
with its `max_bytes`, replicas and bucket, plus `need` and the limit. The 15%
margin is room for streams a later release adds, which is exactly the
v1.4.73 failure. `nats.jetstream.allowOvercommit: true` skips the check.

Defaults after D3/D4 with three servers (`max_file_store` 30000000000 bytes =
27.94 GiB, limit 23.75 GiB):

| Shape | full | rest (R1) | need |
| --- | --- | --- | --- |
| flow-collector enabled (flows 10 GiB R3) | 19 | 9.25 | 19 + 9.25/3 + 1 = 23.08 |
| flow-collector disabled (flows 1 GiB R1) | 9 | 10.25 | 9 + 10.25/3 + 1 = 13.42 |

The enabled shape leaves 0.67 GiB of margin under the limit and 4.86 GiB
below `max_file_store`; the v1.4.73 shape (26 GiB full, 5.25 GiB R1) needs
26 + 5.25/3 + 1 = 28.75 GiB and fails the check, as it should.

### D6. Owners never shrink below stored bytes

datasvc (`reconcileStreamConfigLocked`), the otel log-collector and
EventWriter reconcile `max_bytes` on existing streams. When the configured
value is below the stream's current `Store`, the owner SHALL keep the larger
of the two and log both values. Lowering a default therefore converges
installs whose data fits and never evicts data from one that does not; the
next upgrade after the data ages out completes the shrink.

### D7. `core.eventWriter.enabled` honours `false`

Render with `ternary` / `hasKey` instead of `default true`.

### D8. Docker Compose and packaged installs meet the same budget

These installs run one NATS server (`nats.replicas = 1`), so every stream is
in `full` and `need` is the plain sum of every `max_bytes`. The limit is
`0.85 * max_file_store`; both `docker/compose/nats.docker.conf` and
`build/packaging/nats/config/nats-server.conf` pin `max_file_store: 10G`
(10^10 bytes = 9.31 GiB, limit 7.92 GiB).

The shared defaults do not fit: with the D3/D4 sizes and flow-collector and
bmp-collector present, `need` is 1 (KV) + 4 (objects) + 2 (`events`) + 1
(`flows`) + 0.125 (bmp) + 5.25 (EventWriter) + 4 (trivy, ARANCINI_CAUSAL,
fieldsurvey, threat-intel) + 2 (plugins) = 19.4 GiB. The sizes those configs
ship today (KV 2 or 5 GiB, `events` 2 GiB) already sum above 9.31 GiB, so
they have the v1.4.73 failure latent. `max_file_store` is not raised: it is a
reservation ceiling on a host disk the chart does not size. Instead both
config sets override the stream sizes:

| Stream | Size |
| --- | --- |
| `KV_serviceradar-datasvc` | 0.25 GiB |
| `OBJ_serviceradar-objects` | 1 GiB |
| `events` | 1 GiB |
| `flows` | 1 GiB (unchanged) |
| bmp-collector stream (Compose only) | 0.125 GiB (unchanged) |
| `metrics` | 0.5 GiB |
| `k8s_inventory`, `analytics_predictions`, `mtr_results`, `scan_results`, `NOTIFICATIONS` | 0.25 GiB each |
| `trivy_reports`, `ARANCINI_CAUSAL`, fieldsurvey, threat-intel | 0.25 GiB each |
| `OBJ_serviceradar_plugins` | 0.5 GiB |

`need` is 6.625 GiB against 7.92 GiB. The values are starting points that
implementation checks against observed per-stream peaks; a value that must
rise is paid for by lowering another or by raising `max_file_store` after
checking host disk, never by dropping the check. Compose sets them through
`docker/compose/datasvc.mtls.json` (`bucket_max_bytes`, `object_store_bytes`),
`otel.docker.toml` and the core service environment; packaged installs through
`datasvc.json`, `otel.toml` and `core-elx.env`.

A Bazel `go_test` enforces this. It loads `nats.docker.conf` and
`nats-server.conf` with the NATS server's own config parser (so `10G` means
what NATS means), decodes the datasvc JSON, otel TOML, flow-collector and
bmp-collector JSON and the core environment into typed structs, takes any
size a config leaves unset from the same default the component compiles in,
and evaluates the D5 formula with `n = 1`. The files are declared `data`
inputs. The formula is shared with the Helm check through one table of
vectors (the two default shapes above and the v1.4.73 shape) run by both this
test and helm-unittest, so the two implementations cannot drift, and the
vector for the v1.4.73 shape must fail the check.

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
renders the byte-exact `max_file_store` (`30000000000`, unchanged in effect).
Installs that override `maxFileStore` low or raise stream sizes get an
itemised render failure and adjust values. Compose and packaged installs
converge when their config files are replaced on upgrade; D6 keeps any stream
whose stored bytes exceed the new size at its current size.

## Resolved Questions

1. Over budget: the render fails by default, with
   `nats.jetstream.allowOvercommit: true` as the opt-out.
2. `OBJ_serviceradar_plugins` defaults to 2 GiB R3. Implementation checks
   this against the largest first-party Wasm and native add-on bundles.
3. The 15% margin is fixed, not a value; `allowOvercommit` covers operators
   who want to run hotter.
