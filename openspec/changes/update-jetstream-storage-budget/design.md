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
| `trivy_reports` | EventWriter | unlimited | 1 |
| `ARANCINI_CAUSAL` | bmp-collector when enabled (`bmpCollector.config.streamMaxBytes`, `streamReplicas`) / EventWriter otherwise | 10 GiB / unlimited | 1 |
| fieldsurvey object store | web-ng (`field_survey_artifact_store.ex`) | unlimited | 1 |
| threat-intel object store | core (`threat_intel_raw_payload_store.ex`) | unlimited | 1 |

With flow-collector enabled: 26 GiB of R3 on every server, 1.94 GiB left,
5.25 GiB of R1 to spread. Fragmentation leaves no server with 1 GiB.

## Goals / Non-Goals

- Goals: a default install of every OSS shape (Helm, Docker Compose,
  packaged), with or without the optional producers (flow-collector,
  bmp-collector, trivy sidecar), can always place every stream ServiceRadar
  creates plus headroom for streams future releases add; sizing is an
  operator choice made by naming a profile, identically for Helm and Docker
  Compose, with individual sizes still overridable; the rule is a pure
  function of values, so it is idempotent and holds for any environment;
  existing installs converge on upgrade with no manual step; one unplaceable
  stream never stops unrelated ingestion.
- Non-Goals: changing the NATS PVC default (StatefulSet
  `volumeClaimTemplates` is immutable, so a new default breaks every existing
  upgrade) or resizing a PVC from a profile; making EventWriter streams R3;
  auto-sizing from live cluster state (`lookup` returns nothing under
  `helm template` and Argo CD); the serviceradar-control SaaS control plane,
  which is a separate repository. Its contract with this change is a profile
  name plus optional per-stream overrides.

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

`templates/nats.yaml` renders `max_file_store: <integer>`. The value is
`nats.jetstream.maxFileStore` when set, otherwise the selected profile's
value (D8); the `small` profile is `30G`, so the default still renders
`30000000000` (27.94 GiB), exactly what NATS enforces today. A helper parses
the `G` (10^9) and `Gi` (2^30) suffixes the way NATS does.

`max_file_store` is deliberately not derived from `nats.persistence.size`.
Deriving it as the PVC size minus a reserve raises the cap toward the disk:
on a 30Gi ext4 volume usable space is below 30 GiB, NATS writes index and
metadata files beyond stream `max_bytes`, and a 1 GiB reserve risks a full
disk, which is worse than an unplaceable stream. `persistence.size` also
diverges from the real claim after an out-of-band PVC expansion, because the
StatefulSet claim is immutable. The PVC only bounds the value from above
(D5).

### D3. Every created stream has a finite `max_bytes`

`trivy_reports`, `OBJ_serviceradar_plugins`, the fieldsurvey and threat-intel
object stores, and the EventWriter-created fallbacks of `flows` and
`ARANCINI_CAUSAL` (used only while flow-collector or bmp-collector is
disabled) get positive sizes in every profile (D8). When flow-collector or
bmp-collector is enabled it reconciles its stream to
`flowCollector.config.stream_max_bytes` or `bmpCollector.config.streamMaxBytes`,
which the profile now sets too.

Each size reaches the process that creates the bucket through that owner's own
setting, never through another component's environment:

| Stream | Owner | Helm value | Environment variable |
| --- | --- | --- | --- |
| `OBJ_serviceradar_plugins` | web-ng | `webNg.pluginStorage.jetstreamMaxBucketBytes` | `PLUGIN_STORAGE_JS_MAX_BUCKET_BYTES` (already read by web-ng `runtime.exs`) |
| fieldsurvey object store | web-ng | `webNg.fieldSurveyArtifactStore.jetstreamMaxBucketBytes` | a new web-ng variable read by `runtime.exs` into `:field_survey_artifact_store` |
| threat-intel object store | core | a new value under `core` | `SERVICERADAR_OTX_RAW_MAX_BUCKET_BYTES` (already read by core `runtime.exs`) |
| `trivy_reports`, `metrics`, `k8s_inventory`, `analytics_predictions`, `mtr_results`, `scan_results`, `flows` / `ARANCINI_CAUSAL` fallbacks | EventWriter (core) | `core.eventWriter.streams.<name>.maxBytes` | one variable per stream in the core environment |

`flows` and `ARANCINI_CAUSAL` have two possible creators, so exactly one of
them owns the stream shape (`max_bytes`, replicas, retention) and the other
creates it only when absent and otherwise merges subjects. The owner is the
collector when it is enabled and EventWriter when it is not:

- `flows`: EventWriter already runs its `flows` consumers with
  `reconcile_stream_shape: false`, so it never reconciles the shape;
  flow-collector owns it when enabled, and the EventWriter fallback size
  applies only when EventWriter has to create the stream.
- `ARANCINI_CAUSAL`: EventWriter's consumer defaults to reconciling the shape
  and sets no size today. When `bmpCollector.enabled` the chart renders the
  ownership flag into core so that consumer runs with
  `reconcile_stream_shape: false` (subjects only) and bmp-collector owns
  `max_bytes` and replicas. The 1 GiB EventWriter fallback applies only when
  bmp-collector is disabled and EventWriter creates the stream. Without this,
  EventWriter would cap a 12 GiB `medium` BMP stream at its own fallback.

### D4. Smaller datasvc defaults

In the default (`small`) profile, `datasvc.bucketMaxBytes` drops 4 GiB ->
1 GiB and `datasvc.objectStoreBytes` 10 GiB -> 4 GiB, both R3. The KV holds
kilobytes of configuration. The object store is `DiscardNew`, so a full
bucket rejects writes rather than evicting; 4 GiB is twice the cap the
reference demo install runs on. The size keys in `values.yaml` become unset
so a profile can supply them; an explicit value still wins.

### D5. Render-time budget check

Each stream's size and replica count come from its own chart value:
`datasvc.bucketMaxBytes` / `objectStoreBytes` / `jetstreamReplicas` (KV and
object store), `logCollector.streamReplicas` (`events`),
`flowCollector.config.stream_max_bytes` / `stream_replicas` (`flows`, when
flow-collector is enabled), `bmpCollector.config.streamMaxBytes` /
`streamReplicas` (`ARANCINI_CAUSAL`, when bmp-collector is enabled),
`webNg.pluginStorage.jetstreamMaxBucketBytes` / `jetstreamReplicas`
(plugins), `webNg.fieldSurveyArtifactStore.jetstreamMaxBucketBytes` (fieldsurvey,
1 replica), the core threat-intel value from D3 (threat-intel, 1 replica),
and `core.eventWriter.streams.<name>.maxBytes` with 1 replica for every
EventWriter-created stream, including `trivy_reports` and the `flows` /
`ARANCINI_CAUSAL` fallbacks while their collector is disabled. The trivy
sidecar only publishes to `trivy_reports`; the stream is counted whether or
not the sidecar runs.

With `n = nats.replicas`, a stream is classified by comparing its replicas
`r` to `n`:

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
v1.4.73 failure. `nats.jetstream.allowOvercommit: true` skips this check.

A second check bounds `max_file_store` by the disk: the chart also `fail`s
when `max_file_store > 0.94 * bytes(nats.persistence.size)`, with a message
pointing at the volume-expansion runbook (D8). `allowOvercommit` does not
skip it, because a full disk is worse than an unplaceable stream. The ceiling is 94%, not a
rounder number below the profile ratio: `30G` on a `30Gi` claim is 93.13%,
and so are `100G` on `100Gi` and `500G` on `500Gi`, so a 93% ceiling would
reject every shipped profile.

The v1.4.73 shape (26 GiB full, 5.25 GiB R1, three servers, `30G`) needs
26 + 5.25/3 + 1 = 28.75 GiB against a 23.75 GiB limit, and fails the check,
as it should.

### D6. One owner reconciles a stream, and never below stored bytes

Exactly one component owns the shape (`max_bytes`, replicas, retention) of
each stream and reconciles it; any secondary creator (EventWriter for `flows`
and `ARANCINI_CAUSAL`, D3) creates the stream only when absent and merges
subjects without touching the shape.

datasvc (`reconcileStreamConfigLocked`), the otel log-collector and
EventWriter reconcile `max_bytes` on existing streams. Three owners create
their bucket once and never update it, so on an existing install the bucket
stays unlimited while the budget counts it at its profile size: web-ng's
plugin bucket (`plugins/storage.ex`), web-ng's fieldsurvey bucket
(`field_survey_artifact_store.ex`, whose `ensure_bucket` returns `:exists`
without updating) and core's threat-intel bucket
(`threat_intel_raw_payload_store.ex`). Each SHALL reconcile `max_bytes` on
startup, creating the bucket when absent and updating it when it exists.

For every reconciling owner, when the configured value is below the stream's
current `Store`, the owner SHALL keep the larger of the two and log both
values. Lowering a default, or capping a previously unlimited bucket,
therefore converges installs whose data fits and never evicts data from one
that does not; the next upgrade after the data ages out completes the shrink.

### D7. Docker Compose and packaged installs

These installs run one NATS server (`nats.replicas = 1`), so every stream is
in `full` and `need` is the plain sum of every `max_bytes`; the limit is
`0.85 * max_file_store`. They select the same profiles as Helm and pay for
sharing one server with their own size tables (D8).

- Compose ships one preset per profile, `docker/compose/profiles/small.env`,
  `medium.env` and `large.env`, each setting `max_file_store` and **every**
  stream size explicitly. `SERVICERADAR_NATS_PROFILE` (default `small`)
  selects the file through the service `env_file` path.
  `docker/compose/nats.docker.conf` reads
  `max_file_store: $SERVICERADAR_NATS_MAX_FILE_STORE` through NATS environment
  substitution, and every size-owning service (datasvc, otel log-collector,
  flow-collector, bmp-collector, core, web-ng) reads its sizes from those
  variables.
  An operator overrides a single size in the environment of the service.
- Packaged installs ship the same explicit sizes as a file
  (`build/packaging/nats/config/jetstream-sizes.env`, `small` content) that
  the systemd units load with `EnvironmentFile=`;
  `build/packaging/nats/config/nats-server.conf` reads `max_file_store` from
  it the same way. Moving to `medium` or `large` replaces that file.
- The Compose and packaged presets carry one `ARANCINI_CAUSAL` key that both
  bmp-collector and EventWriter read, so the two agree on the size without
  the Helm ownership flag.
- Neither install has a PVC. A profile's `max_file_store` is a reservation
  ceiling, so the host needs at least that much free disk for JetStream. This
  raises the Compose and packaged ceiling from today's `10G` to `30G` for
  `small`, and the shipped stream sizes fit it (D8) where today's do not.

A Bazel `go_test` enforces this without reading any component source. It
parses the NATS configuration with the nats-server config parser, after
setting each preset's variables as the process environment, so `30G` means
what NATS means, and parses each preset and the packaged sizes file into typed
values. It fails when a key of the stream inventory is missing or unknown,
when a size is not a positive integer, or when `need` exceeds 85% of the
parsed `max_file_store`, and it names the streams and the limit. The
inventory is a typed list owned by the test, so adding a stream forces the
presets to be updated. A vector with the v1.4.73 single-server shape must
fail. Helm is covered separately by helm-unittest cases per profile.

### D8. Sizing profiles

`nats.jetstream.profile` (Helm) and `SERVICERADAR_NATS_PROFILE` (Compose)
select `small` (default), `medium` or `large`. A profile sets
`max_file_store` and the default `max_bytes` of every stream, KV bucket and
object store in the inventory, including `ARANCINI_CAUSAL` and `flows`, with
the replica sources named in D5. An explicit value for any single size or for
`maxFileStore` overrides the profile. There is no single right size (a site
with heavy BMP needs far more than one with little), so the profile is the
operator's choice; the defaults are safe rather than generous. The
serviceradar-control SaaS control plane picks a larger profile, plus optional
per-stream overrides, for enterprise deployments.

A profile never resizes the NATS PVC by itself. `small` targets the default
30Gi PVC, `medium` a 100Gi PVC and `large` a 500Gi PVC; D5 rejects a profile
whose `max_file_store` exceeds 94% of `nats.persistence.size`, so an existing
30Gi install that selects `medium` fails to render until its volumes have
been expanded.

`nats.persistence.size` feeds the StatefulSet `volumeClaimTemplates`, which
Kubernetes forbids changing on a live StatefulSet, so raising it with a plain
`helm upgrade` or Argo sync is rejected at apply time. The supported path to a
larger profile on a live install is the standard volume-expansion procedure,
written as a runbook at `docs/nats-jetstream-profile-runbook.md` (repo-root
`docs/`, not the published `docs/docs/` site):

1. Confirm the NATS StorageClass has `allowVolumeExpansion: true`.
2. Patch each `serviceradar-nats` PVC to the new size and wait for the resize
   to complete.
3. Delete the StatefulSet with `--cascade=orphan`, so the pods and PVCs keep
   running.
4. `helm upgrade` with the raised `nats.persistence.size` and the new
   profile. This recreates the StatefulSet with the new `volumeClaimTemplates`
   around the same PVCs and rolls the pods one at a time.

A StorageClass without volume expansion cannot move up a profile in place; it
needs a new install or a data migration. The chart does not automate any of
this. The `values.yaml` comment on `nats.jetstream.maxFileStore` and
`nats.persistence.size` (currently "do not raise persistence.size via Helm on
a live StatefulSet; expand PVCs out-of-band first") is updated to point at the
runbook.

Helm sizes, three servers (GiB; `medium` and `large` are starting points that
implementation checks against observed peaks, with most of the extra space
given to the high-volume streams: `flows`, `ARANCINI_CAUSAL`, `events`):

| Stream | Replicas | small | medium | large |
| --- | --- | --- | --- | --- |
| `max_file_store` (PVC) | | 30G (30Gi) | 100G (100Gi) | 500G (500Gi) |
| `KV_serviceradar-datasvc` | 3 | 1 | 1 | 2 |
| `OBJ_serviceradar-objects` | 3 | 4 | 8 | 32 |
| `events` | 3 | 2 | 8 | 32 |
| `flows` (flow-collector on) | 3 | 8 | 32 | 192 |
| `OBJ_serviceradar_plugins` | 3 | 2 | 4 | 8 |
| `ARANCINI_CAUSAL` (bmp-collector on) | 1 | 2 | 12 | 64 |
| `metrics`, `k8s_inventory`, `analytics_predictions`, `mtr_results` (each) | 1 | 1 | 2 | 8 |
| `scan_results` | 1 | 0.25 | 0.5 | 2 |
| `NOTIFICATIONS` | 1 | 1 | 1 | 2 |
| `trivy_reports`, fieldsurvey, threat-intel (each) | 1 | 1 | 2 | 8 |
| `flows`, `ARANCINI_CAUSAL` fallbacks (collector off) | 1 | 1 | 1 | 1 |

All optional producers enabled (flow-collector, bmp-collector, trivy
sidecar), limit `0.85 * max_file_store`:

| Profile | full | rest | need | limit | margin |
| --- | --- | --- | --- | --- | --- |
| small (27.94 GiB) | 17 | 10.25, largest 2 | 17 + 10.25/3 + 2 = 22.42 | 23.75 | 1.33 |
| medium (93.13 GiB) | 53 | 27.5, largest 12 | 53 + 27.5/3 + 12 = 74.17 | 79.16 | 4.99 |
| large (465.66 GiB) | 266 | 124, largest 64 | 266 + 124/3 + 64 = 371.33 | 395.81 | 24.48 |

With both collectors disabled the need is 13.42 (small), 28.83 (medium) and
102.67 (large) GiB, so every subset of producers passes. Each `max_file_store`
is 93.13% of its PVC, under the 94% ceiling.

Compose and packaged sizes, one server, so the flow stream is smaller and every
stream counts in full (GiB; replicas are irrelevant):

| Stream | small | medium | large |
| --- | --- | --- | --- |
| `max_file_store` | 30G | 100G | 500G |
| `KV_serviceradar-datasvc` | 1 | 1 | 2 |
| `OBJ_serviceradar-objects` | 4 | 8 | 32 |
| `events` | 2 | 8 | 32 |
| `flows` | 3 | 24 | 160 |
| `OBJ_serviceradar_plugins` | 2 | 4 | 8 |
| `ARANCINI_CAUSAL` | 2 | 12 | 64 |
| `metrics`, `k8s_inventory`, `analytics_predictions`, `mtr_results` (each) | 1 | 2 | 8 |
| `scan_results` | 0.25 | 0.5 | 2 |
| `NOTIFICATIONS` | 1 | 1 | 2 |
| `trivy_reports`, fieldsurvey, threat-intel (each) | 1 | 2 | 8 |
| **need** | **22.25** | **72.5** | **358** |
| limit (`0.85 * max_file_store`) | 23.75 | 79.16 | 395.81 |

## Risks / Trade-offs

- **Hard fail on upgrade.** An install whose explicit overrides exceed the
  budget stops upgrading until values change or `allowOvercommit` is set.
  This is deliberate: such an install is one new stream away from the
  v1.4.73 outage. The message names each reservation so the fix is a values
  edit. Alternative considered: warn in `NOTES.txt` only; rejected because
  nobody reads upgrade notes on an automated Argo sync.
- **Smaller object store.** An install already using more than 4 GiB keeps
  its current size (D6) and does not lose data, but new installs cap earlier.
- **A profile does not resize a disk.** Selecting `medium` on a 30Gi install
  fails render until the PVC is expanded and the StatefulSet recreated by the
  runbook (D8); this is intended, since the chart cannot expand an immutable
  claim and a reservation ceiling above the disk defeats the check. The
  runbook briefly orphans the StatefulSet, and the pod roll in its last step
  restarts each NATS server in turn.
- **Compose and packaged ceiling rises to 30G.** The reservation is not an
  allocation, but a host with less free disk than `max_file_store` can fill
  it before NATS refuses a write. The presets document the requirement.
- **EventWriter sizes move to values.** Two sources of truth for defaults
  (Elixir constants and Helm) must not drift; the Elixir constants become the
  fallback only when the env var is absent, and a helm-unittest asserts the
  chart renders every stream's env var.

## Migration

No manual step for installs on chart defaults: the next upgrade selects the
`small` profile, lowers KV and object-store caps (D6 permitting), has each
owner set a finite cap on its previously unlimited bucket at startup (D6), and
renders the byte-exact `max_file_store` (`30000000000`, unchanged in effect).
Installs that override sizes upward, or that enable BMP with a larger
`streamMaxBytes` than the profile, get an itemised render failure and adjust
values. Selecting `medium` or `large` follows the volume-expansion runbook
(D8) first; a StorageClass without expansion needs a new install or
migration. Compose and packaged installs converge when their config files are
replaced on upgrade; D6 keeps any stream whose stored bytes exceed the new
size at its current size.

## Resolved Questions

1. Over budget: the render fails by default, with
   `nats.jetstream.allowOvercommit: true` as the opt-out.
2. `OBJ_serviceradar_plugins` defaults to 2 GiB R3. Implementation checks
   this against the largest first-party Wasm and native add-on bundles.
3. The 15% margin is fixed, not a value; `allowOvercommit` covers operators
   who want to run hotter.
4. The PVC ceiling is 94% of `nats.persistence.size` and is not skipped by
   `allowOvercommit` (D5).
