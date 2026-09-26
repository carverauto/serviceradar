## 1. EventWriter isolation (D1)

- [ ] 1.1 Change `Producer.finalize_consumer_setup/3` to keep successful
      consumers and schedule per-stream retries with backoff capped at 60 s.
- [ ] 1.2 Emit `[:serviceradar, :event_writer, :consumer_setup, :failed]`
      telemetry and a health event naming the stream and NATS error code.
- [ ] 1.3 Regression test: a stream rejected with err 10005 leaves the other
      consumers subscribed; the test fails on the current tear-down code.

## 2. Finite reservations (D3)

- [ ] 2.1 Give `trivy_reports`, EventWriter-created `ARANCINI_CAUSAL`,
      `OBJ_serviceradar_plugins`, fieldsurvey and threat-intel object stores
      a positive default `max_bytes`.
- [ ] 2.2 Lower the EventWriter-created `flows` default to 1 GiB.
- [ ] 2.3 Expose every EventWriter stream size as
      `core.eventWriter.streams.<name>.maxBytes`, rendered into the core
      environment and read in `serviceradar_core_elx/config/runtime.exs`.
- [ ] 2.4 Expose `webNg.pluginStorage.jetstreamMaxBucketBytes`
      (`PLUGIN_STORAGE_JS_MAX_BUCKET_BYTES`) and
      `webNg.fieldSurveyArtifactStore.jetstreamMaxBucketBytes`, rendered into
      the web-ng environment; read the fieldsurvey value in web-ng
      `runtime.exs` into `:field_survey_artifact_store`.
- [ ] 2.5 Expose a `core` value for the threat-intel bucket, rendered as
      `SERVICERADAR_OTX_RAW_MAX_BUCKET_BYTES`.
- [ ] 2.6 EventWriter `ARANCINI_CAUSAL` consumer: honour a
      `reconcile_stream_shape` setting from the core environment, and have the
      chart render it `false` whenever `bmpCollector.enabled`; the 1 GiB
      fallback size applies only when EventWriter creates the stream.

## 3. Chart budget and profiles (D2, D4, D5, D8)

- [ ] 3.1 Byte-exact `max_file_store` helper with `G`/`Gi` parsing. Make
      `nats.jetstream.maxFileStore` and every stream size key unset by default
      in `values.yaml` and `values-demo.yaml` so the profile supplies them; an
      explicit value wins.
- [ ] 3.2 Add `nats.jetstream.profile` (`small` default, `medium`, `large`)
      with the D8 Helm table as chart data, covering `datasvc`, `events`,
      `flows`, plugins, `bmpCollector.config.streamMaxBytes` /
      `streamReplicas` and every `core.eventWriter.streams.<name>.maxBytes`;
      correct the budget comments in `values.yaml`, including the
      `nats.jetstream.maxFileStore` / `nats.persistence.size` guidance (lines
      216-219), which points at the runbook instead of "expand PVCs
      out-of-band first".
- [ ] 3.3 Budget helper and `fail` with itemised message, bucketing each
      stream by its own size and replica value against `nats.replicas` (D5),
      including flow-collector and bmp-collector when enabled;
      `nats.jetstream.allowOvercommit` escape hatch for the reservation check.
- [ ] 3.4 PVC ceiling: `fail` when `max_file_store` exceeds 94% of
      `bytes(nats.persistence.size)` with a message that points at the
      runbook; `allowOvercommit` does not skip it.
- [ ] 3.5 helm-unittest per profile: with flow-collector, bmp-collector and the
      trivy sidecar all enabled and with them all disabled, `small`,
      `medium` and `large` render (`medium` and `large` with a matching
      `persistence.size`); the v1.4.73 shape fails; overrides fail with the
      itemised message; `allowOvercommit` passes; R2 and R3 streams on a
      5-server NATS land in the spread bucket; an existing 30Gi install that
      sets `medium` fails with the runbook message and renders with
      `persistence.size` of `100Gi`; `values-demo.yaml` passes.

## 4. Reconcile and safe shrink (D6)

- [ ] 4.1 datasvc `reconcileStreamConfigLocked` (KV and object store,
      discard-new): when configured is below stored, leave `max_bytes`
      unchanged and log configured, stored and current values; never set it to
      the stored size.
- [ ] 4.2 otel log-collector `events` reconcile (discard-old): reconcile to the
      configured value even when it evicts the oldest messages; log before and
      after.
- [ ] 4.3 EventWriter `reconcile_stream` (discard-old): same rule for every
      EventWriter-created stream.
- [ ] 4.4 web-ng plugin bucket (`plugins/storage.ex`): reconcile `max_bytes`
      on startup, create-or-update, discard-new rule; an unlimited bucket
      holding more than the cap stays unlimited and is logged.
- [ ] 4.5 web-ng fieldsurvey bucket (`field_survey_artifact_store.ex`
      `ensure_bucket`): same rule instead of returning `:exists` untouched.
- [ ] 4.6 core threat-intel bucket (`threat_intel_raw_payload_store.ex`): same
      rule.
- [ ] 4.7 Tests per owner: for discard-new buckets an existing unlimited bucket
      gets the cap when its data fits, and when it does not `max_bytes` is left
      unchanged, the values are logged and a later write still succeeds; for
      discard-old streams a full stream shrinks, evicts the oldest messages
      and logs before and after; an absent bucket is created with the cap.
- [ ] 4.8 Ownership test: with bmp-collector enabled and `ARANCINI_CAUSAL`
      sized above the fallback, EventWriter startup leaves `max_bytes` and
      replicas unchanged (fails on the current default-true behaviour once the
      fallback size is set); with it disabled EventWriter creates the stream
      at the fallback size.
- [ ] 4.9 `rust/bmp-collector` publisher: create-or-update `ARANCINI_CAUSAL`,
      reconciling `max_bytes` and `num_replicas` on an existing stream under the
      discard-old rule, with a test for an existing 10 GiB stream reconciled to
      2 GiB.
- [ ] 4.10 `rust/flow-collector` publisher: reconcile `flows` `max_bytes` and
      replicas under the discard-old rule, with a test for `flows` at 10 GiB
      full reconciled to 8 GiB.
- [ ] 4.11 Classify `NOTIFICATIONS` (created by core notifications) by its
      discard policy and apply the matching D6 rule.
- [ ] 4.12 EventWriter `events` consumers (`EVENTS`, `PDNS_OCSF`, `FALCO`,
      `OTEL_*`, `LOGS`, `BMP_CAUSAL`, `SIEM_CAUSAL`, `ATTRIBUTED_FLOW`):
      `reconcile_stream_shape: false` (never update an existing stream) and
      `stream_max_bytes` / replicas read from `SERVICERADAR_JS_EVENTS_MAX_BYTES`
      / `_REPLICAS` (create-only, used when `events` is absent), in
      `Config.default_streams/0` (`serviceradar_core` `config.ex`),
      `serviceradar_core/config/runtime.exs` and
      `serviceradar_core_elx/config/runtime.exs`; remove the hardcoded 8 GiB
      `EVENTS` `stream_max_bytes`. Render the two variables into the core
      environment from `logCollector.streamMaxBytes` / `streamReplicas`. Tests:
      an EventWriter start leaves an existing `events` stream's `max_bytes`
      unchanged, and starting first creates it at the profile size, not
      unlimited.
- [ ] 4.13 Ownership test (ExUnit, in `serviceradar_core`): call
      `Config.default_streams/0` and the runtime configuration loaders, join
      them with a typed inventory of streams and declared owners (D6 table), and
      assert that no EventWriter consumer reconciles the shape of a stream it
      does not own. It derives the answer from the loaded configuration, not
      from source text, and fails on the current `EVENTS` default. Go and Rust
      owner behaviour is covered by each owner's unit tests (4.1, 4.2, 4.9,
      4.10).

## 5. Compose and packaged installs (D7)

- [ ] 5.1 Add `docker/compose/profiles/{small,medium,large}.env` with the D8
      Compose table and every stream size explicit; select the file with
      `SERVICERADAR_NATS_PROFILE` (default `small`) through `env_file`.
- [ ] 5.2 `docker/compose/nats.docker.conf` reads `max_file_store` from
      `$SERVICERADAR_NATS_MAX_FILE_STORE`. The presets set every stream size
      through the `SERVICERADAR_JS_<STREAM>_MAX_BYTES` / `_REPLICAS` variables
      of D7 (core and web-ng through their own variables, task 2.3-2.5).
- [ ] 5.3 Ship `build/packaging/nats/config/jetstream-sizes.env` with the
      `small` content; load it with `EnvironmentFile=` in the NATS, datasvc,
      log-collector, flow-collector, bmp-collector, core and web-ng units, and
      read `max_file_store` from it in `nats-server.conf`.
- [ ] 5.4 Add a `go_test` that sets each preset's variables, parses the NATS
      configs with the nats-server config parser, parses the presets and sizes
      file into typed values, fails on a missing or unknown inventory key or a
      non-positive size, and evaluates the D5 formula with `nats.replicas = 1`;
      config files are declared `data` inputs and no component source is read.
      It also parses `docker-compose.yml` and the packaged systemd units into
      typed models and fails when a size-owning service does not load the
      selected preset (`env_file`) or the sizes file (`EnvironmentFile`).
      A vector with the v1.4.73 single-server shape must fail.
- [ ] 5.5 Bump `addons/<name>/addon.yaml` `version` for any native add-on whose
      config changes.
- [ ] 5.6 Go datasvc: read `SERVICERADAR_JS_KV_SERVICERADAR_DATASVC_MAX_BYTES`,
      `SERVICERADAR_JS_OBJ_SERVICERADAR_OBJECTS_MAX_BYTES` and the matching
      `_REPLICAS`, taking precedence over JSON (env > JSON > compiled default);
      unit test for the precedence and for an invalid value failing startup.
- [ ] 5.7 Rust flow-collector: `SERVICERADAR_JS_FLOWS_MAX_BYTES` and
      `SERVICERADAR_JS_FLOWS_REPLICAS` override `stream_max_bytes` and
      `stream_replicas`; unit test for the precedence.
- [ ] 5.8 Rust bmp-collector: `SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES` and
      `_REPLICAS` override the JSON stream size and replicas; unit test for the
      precedence.
- [ ] 5.9 Rust otel log-collector: `SERVICERADAR_JS_EVENTS_MAX_BYTES` and
      `_REPLICAS` override `max_bytes` and `stream_replicas`; unit test for the
      precedence.

## 6. Runbook (D8)

- [ ] 6.1 Write `docs/nats-jetstream-profile-runbook.md` (repo-root `docs/`,
      ASCII Markdown): confirm `allowVolumeExpansion`, patch each
      `serviceradar-nats` PVC and wait for the resize, delete the StatefulSet
      with `--cascade=orphan`, `helm upgrade` with the raised
      `nats.persistence.size` and the new profile, and verify. State that a
      StorageClass without expansion needs a new install or migration and that
      the chart does not automate this.
- [ ] 6.2 Link the runbook from `docs/agent-runbooks.md` and from the
      `values.yaml` comment.

## 7. Verification

- [ ] 7.1 `make test` green.
- [ ] 7.2 Upgrade a v1.4.73 install with flow-collector enabled and default
      values on a scratch cluster: render passes, datasvc shrinks, every
      stream places, `nats server report jetstream` shows reserved below 85%.
- [ ] 7.3 On a scratch cluster with expandable storage, follow the runbook
      from `small` to `medium` and confirm the StatefulSet is recreated, the
      PVCs are the same objects and larger, and every NATS pod is ready.
