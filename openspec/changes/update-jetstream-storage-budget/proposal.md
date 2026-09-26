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
- **Every stream size becomes a Helm value at its owner.** EventWriter
  streams under `core.eventWriter.streams.<name>.maxBytes`, rendered into the
  core environment; the plugin and fieldsurvey buckets under `webNg`, rendered
  into web-ng's own environment; the threat-intel bucket under `core`,
  rendered as `SERVICERADAR_OTX_RAW_MAX_BUCKET_BYTES`. The whole budget lives
  in one values tree, and no size is set in a process that does not create the
  bucket.
- **The chart renders `max_file_store` as an exact byte count**, parsed with
  NATS's `G` (10^9) and `Gi` (2^30) semantics. The value is
  `nats.jetstream.maxFileStore` when set, otherwise the selected profile's;
  the default `small` profile renders `30000000000`. It is not derived from
  the PVC size: a reserve-based derivation raises the cap toward the disk and
  drifts from the real claim after out-of-band expansion.
- **Sizing profiles.** `nats.jetstream.profile` (Helm) and
  `SERVICERADAR_NATS_PROFILE` (Compose) select `small` (default; 30Gi PVC,
  `max_file_store` 30G), `medium` (100Gi, 100G) or `large` (500Gi, 500G).
  There is no single right size, so sizing is an operator choice with safe
  defaults. A profile sets `max_file_store` and the default `max_bytes` of
  every stream, KV bucket and object store, including `flows` and
  `ARANCINI_CAUSAL`, and each is still individually overridable. Every
  profile is shown to pass the budget with flow-collector, bmp-collector and
  the trivy sidecar all enabled (design D8).
- **Smaller defaults that fit with headroom.** In `small`, datasvc KV 4 GiB ->
  1 GiB, object store 10 GiB -> 4 GiB and flow-collector `flows` 10 GiB ->
  8 GiB (all R3; the KV holds kilobytes, and the object store is capped at
  2 GiB on the reference demo install). The BMP stream is counted at its own
  `bmpCollector.config.streamMaxBytes` / `streamReplicas`, which the profile
  sets to 2 GiB R1 instead of the 10 GiB chart default; that default would
  otherwise push a default install with BMP enabled over the budget.
- **A render-time budget check.** `helm template` / `helm upgrade` SHALL fail
  with an itemised message when the worst per-server reservation exceeds 85%
  of `max_file_store`, unless the operator sets
  `nats.jetstream.allowOvercommit: true`. Each stream's size and replica
  count come from its own chart value, including the optional producers when
  enabled, and are bucketed against `nats.replicas`.
- **Profiles never resize the NATS PVC.** The check also fails when
  `max_file_store` exceeds 94% of `nats.persistence.size`, pointing at a
  runbook. `volumeClaimTemplates` is immutable, so an existing 30Gi install
  that selects `medium` follows the standard volume-expansion procedure
  (expand the PVCs, delete the StatefulSet with `--cascade=orphan`, `helm
  upgrade` with the raised size and profile), specified as a new runbook at
  `docs/nats-jetstream-profile-runbook.md`. A StorageClass without expansion
  needs a new install or migration. The chart does not automate this.
- **Docker Compose and packaged installs are in scope.** Both pin
  `max_file_store: 10G` on a single server and ship stream sizes that do not
  fit it. Compose ships one preset env file per profile
  (`docker/compose/profiles/{small,medium,large}.env`) that sets every size
  explicitly, and `nats.docker.conf` reads `max_file_store` from it;
  packaged installs ship the same explicit sizes as a file. A Bazel test
  parses the NATS config with the nats-server parser and the preset and sizes
  files, requires every size to be explicit, and evaluates the budget with
  `nats.replicas = 1`. It never reads component source. Helm is covered by
  helm-unittest cases per profile.
- **Control-plane contract.** The serviceradar-control SaaS control plane is
  out of scope; it consumes this change as a profile name plus optional
  per-stream overrides.
- **Caps converge on upgrade, by discard policy.** The plugin, fieldsurvey and
  threat-intel bucket owners, which today create their bucket once, SHALL
  reconcile `max_bytes` on startup, and the bmp-collector publisher SHALL
  create-or-update `ARANCINI_CAUSAL` so it truly owns that stream's size.
  Discard-new state buckets (datasvc KV and objects, plugins, fieldsurvey,
  threat-intel) never shrink below stored bytes: `max_bytes` is left unchanged
  and the values are logged, since setting it to the stored size would refuse
  every write, and an unlimited bucket holding more than the cap stays
  unlimited until the data ages out or the cap is raised. Discard-old buffers
  (`flows`, `events`, `ARANCINI_CAUSAL`, every EventWriter stream, including
  flow-collector's `flows` 10 to 8 GiB) reconcile to the configured value even
  when that evicts the oldest messages, so installs reach the budgeted
  reservation.
- **One owner per stream shape, claimed on the stream.** The otel log-collector,
  flow-collector and bmp-collector each claim `events`, `flows` and
  `ARANCINI_CAUSAL` through stream metadata (`serviceradar.owner`) and
  reconcile the shape. EventWriter claims only streams it creates: it creates
  them when absent with an `event-writer` claim and a finite fallback size,
  and merges subjects only when a collector holds the claim. A legacy stream
  with no metadata is claimed by a collector as soon as it starts; EventWriter
  claims it only after it has stayed unclaimed for a grace period (15 minutes
  by default), checked by a new periodic EventWriter ownership reconcile timer
  that only updates streams and never restarts a consumer, so on an upgrade restart the collector wins and nothing is
  evicted, while an install with no collector converges its existing 10 GiB
  `flows` after the grace period, on Helm, Compose and packaged installs, with
  no per-install ownership setting. The hardcoded 8 GiB
  `EVENTS` size is removed, so EventWriter can neither overwrite the budgeted
  2 GiB nor create the stream unlimited. `flows` and `ARANCINI_CAUSAL` are
  budgeted at the collector size whether or not the collector is enabled,
  because a collector that claimed a stream keeps its size after it is
  disabled; a runbook reclaim returns it to EventWriter. An ownership test
  asserts EventWriter never reconciles a collector-claimed stream.
- **Non-Helm services honour environment size overrides.** datasvc, the otel
  log-collector, flow-collector and bmp-collector read
  `SERVICERADAR_JS_<STREAM>_MAX_BYTES` / `_REPLICAS`, taking precedence over
  their JSON or TOML (env, then file, then compiled default), so a Compose
  preset or packaged sizes file actually sets the reservation.

## Impact

- Affected specs: new capability `jetstream-storage-budget`.
- Affected code: `helm/serviceradar` (values, `templates/nats.yaml`,
  `templates/core.yaml`, `_helpers.tpl`, helm-unittest suites);
  `elixir/serviceradar_core` EventWriter (`producer.ex`, `config.ex`) and
  `serviceradar_core_elx/config/runtime.exs`; Go datasvc stream reconcile
  (`go/pkg/datasvc/nats.go`); Rust otel log-collector reconcile
  (`rust/otel/src/nats/stream.rs`); the flow-collector and bmp-collector
  publishers (`rust/flow-collector/src/publisher.rs`,
  `rust/bmp-collector/src/publisher.rs`) and their config loading; the trivy/bmp stream creators and the
  web-ng plugin (`plugins/storage.ex`), web-ng fieldsurvey
  (`field_survey_artifact_store.ex`) and core threat-intel
  (`threat_intel_raw_payload_store.ex`) bucket owners, including web-ng
  `runtime.exs`; `docs/nats-jetstream-profile-runbook.md`; `docker/compose/` and
  `build/packaging/` NATS configs, profile presets and sizes files, the
  size-owning services' env handling (datasvc, otel log-collector,
  flow-collector, bmp-collector, core, web-ng), and a new budget `go_test`.
- **Upgrade behaviour:** existing installs converge on the next upgrade with
  no manual step. The NATS PVC size is not changed (StatefulSet
  `volumeClaimTemplates` is immutable). An install whose explicit overrides
  exceed the budget fails `helm upgrade` with a message listing each
  reservation, and can opt out with `allowOvercommit`. Selecting a larger
  profile follows the volume-expansion runbook first.
- The `core.eventWriter.enabled: false` rendering `EVENT_WRITER_ENABLED="true"`
  bug is independent of this change and is tracked as a separate bug fix.
