# Change: Budget JetStream storage so a new stream can always be placed

## Why

NATS reserves each stream's full `max_bytes` on every server that holds a
replica, and refuses to place a stream when no server has that much of
`max_file_store` left ("no suitable peers for placement, insufficient
storage", err 10005). ServiceRadar's reservations are split between Helm
values (datasvc KV and object store, `events`, flow-collector `flows`) and
hardcoded Elixir constants (every EventWriter stream), so nothing checks the
total, and the chart's own budget comment is wrong twice over:

- It treats `maxFileStore: 30G` as 30 GiB. NATS parses `G` as 10^9, so each
  server gets 27.94 GiB.
- It counts the R3 streams (KV 4 + objects 10 + events 2 + flows 10 = 26 GiB)
  and leaves out the R1 streams EventWriter creates (metrics, k8s_inventory,
  analytics_predictions, scan_results, mtr_results, notifications: 5.25 GiB).

With flow-collector enabled, which reconciles `flows` to R3, every server
reaches 26 GiB of R3 reservations plus its share of R1 streams, leaving
under 1 GiB free. v1.4.73 added the 1 GiB R1 `mtr_results` stream, which then
fit on no server. Because EventWriter treats any required consumer failure
as a connection failure, it tore down every consumer on that connection and
retried in a loop: metrics stopped being persisted and aged out of their
30-minute stream unprocessed, and every MTR result was dropped.

Two defects compound: the budget does not fit a default-shaped install, and
one unplaceable stream stops unrelated ingestion.

## What Changes

- **EventWriter isolates stream failures.** A consumer whose stream cannot
  be created, updated or placed SHALL be retried on its own with backoff,
  while every other consumer keeps running. Failure is reported through
  telemetry, a log naming the stream and NATS error, and a health event.
- **Every ServiceRadar-created stream and bucket has a finite `max_bytes`.**
  Unlimited streams (`trivy_reports`, `ARANCINI_CAUSAL`, plugin, fieldsurvey
  and threat-intel object stores) still consume placement headroom through
  stored bytes, which the budget cannot see.
- **EventWriter stream sizes become Helm values** under
  `core.eventWriter.streams.<name>.maxBytes`, rendered into the core
  environment, so the whole budget lives in one values tree.
- **The chart renders `max_file_store` as an exact byte count.**
  `nats.jetstream.maxFileStore` stays an explicit value with the `30G`
  default, parsed with NATS's `G` (10^9) and `Gi` (2^30) semantics, so the
  default renders `30000000000`. It is not derived from the PVC size: a
  reserve-based derivation raises the cap toward the disk and drifts from the
  real claim after out-of-band expansion.
- **Smaller defaults that fit with headroom.** datasvc KV 4 GiB -> 1 GiB and
  object store 10 GiB -> 4 GiB (both R3; the KV holds kilobytes, and the
  object store is capped at 2 GiB on the reference demo install).
- **A render-time budget check.** `helm template` / `helm upgrade` SHALL fail
  with an itemised message when the worst per-server reservation exceeds 85%
  of `max_file_store`, unless the operator sets
  `nats.jetstream.allowOvercommit: true`. Each stream's replica count comes
  from its own chart value and is bucketed against `nats.replicas`.
- **Docker Compose and packaged installs are in scope.** Both pin
  `max_file_store: 10G` on a single server and ship stream sizes that do not
  fit it. They get smaller stream sizes (design D8) and a Bazel test that
  evaluates the same budget formula with `nats.replicas = 1` against the
  shipped config files.
- **Shrinking is safe on upgrade.** An owner that reconciles `max_bytes`
  downward SHALL NOT shrink below the bytes already stored; it keeps the
  larger value and logs why.
- Fix `core.eventWriter.enabled: false` rendering `EVENT_WRITER_ENABLED="true"`
  (`default` treats `false` as empty).

## Impact

- Affected specs: new capability `jetstream-storage-budget`.
- Affected code: `helm/serviceradar` (values, `templates/nats.yaml`,
  `templates/core.yaml`, `_helpers.tpl`, helm-unittest suites);
  `elixir/serviceradar_core` EventWriter (`producer.ex`, `config.ex`) and
  `serviceradar_core_elx/config/runtime.exs`; Go datasvc stream reconcile
  (`go/pkg/datasvc/nats.go`); Rust otel log-collector reconcile
  (`rust/otel/src/nats/stream.rs`); trivy/bmp/plugin/fieldsurvey/threat-intel
  stream creators for finite caps; `docker/compose/` and
  `build/packaging/` NATS, datasvc, otel and core config files plus a new
  budget `go_test`.
- **Upgrade behaviour:** existing installs converge on the next upgrade with
  no manual step. The NATS PVC size is not changed (StatefulSet
  `volumeClaimTemplates` is immutable). An install whose explicit overrides
  exceed the budget fails `helm upgrade` with a message listing each
  reservation, and can opt out with `allowOvercommit`.
