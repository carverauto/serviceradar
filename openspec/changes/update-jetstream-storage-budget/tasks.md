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

## 3. Chart budget and profiles (D2, D4, D5, D7, D9)

- [ ] 3.1 Byte-exact `max_file_store` helper with `G`/`Gi` parsing. Make
      `nats.jetstream.maxFileStore` and every stream size key unset by default
      in `values.yaml` and `values-demo.yaml` so the profile supplies them; an
      explicit value wins.
- [ ] 3.2 Add `nats.jetstream.profile` (`small` default, `medium`, `large`)
      with the D9 Helm table as chart data, covering `datasvc`, `events`,
      `flows`, plugins, `bmpCollector.config.streamMaxBytes` /
      `streamReplicas` and every `core.eventWriter.streams.<name>.maxBytes`;
      correct the budget comments in `values.yaml`.
- [ ] 3.3 Budget helper and `fail` with itemised message, bucketing each
      stream by its own size and replica value against `nats.replicas` (D5),
      including flow-collector and bmp-collector when enabled;
      `nats.jetstream.allowOvercommit` escape hatch for the reservation check.
- [ ] 3.4 PVC ceiling: `fail` when `max_file_store` exceeds 94% of
      `bytes(nats.persistence.size)` with the expand-the-PVC-first message;
      `allowOvercommit` does not skip it.
- [ ] 3.5 Fix `EVENT_WRITER_ENABLED` rendering of `false`.
- [ ] 3.6 helm-unittest per profile: with flow-collector, bmp-collector and the
      trivy sidecar all enabled and with them all disabled, `small`,
      `medium` and `large` render (`medium` and `large` with a matching
      `persistence.size`); the v1.4.73 shape fails; overrides fail with the
      itemised message; `allowOvercommit` passes; R2 and R3 streams on a
      5-server NATS land in the spread bucket; an existing 30Gi install that
      sets `medium` fails with the expand-the-PVC message and renders once
      `persistence.size` is `100Gi`; `values-demo.yaml` passes.

## 4. Safe shrink (D6)

- [ ] 4.1 datasvc `reconcileStreamConfigLocked`: never below stored bytes.
- [ ] 4.2 otel log-collector `events` reconcile: same rule.
- [ ] 4.3 EventWriter `reconcile_stream`: same rule.
- [ ] 4.4 Tests for each owner: shrink applies when data fits, is held when
      it does not.

## 5. Compose and packaged installs (D8)

- [ ] 5.1 Add `docker/compose/profiles/{small,medium,large}.env` with the D9
      Compose table and every stream size explicit; select the file with
      `SERVICERADAR_NATS_PROFILE` (default `small`) through `env_file`.
- [ ] 5.2 `docker/compose/nats.docker.conf` reads `max_file_store` from
      `$SERVICERADAR_NATS_MAX_FILE_STORE`; datasvc, otel log-collector,
      flow-collector, bmp-collector and core read their sizes from the preset
      variables instead of literals in their config files.
- [ ] 5.3 Ship `build/packaging/nats/config/jetstream-sizes.env` with the
      `small` content; load it with `EnvironmentFile=` in the NATS, datasvc,
      log-collector, flow-collector and core units, and read `max_file_store`
      from it in `nats-server.conf`.
- [ ] 5.4 Add a `go_test` that sets each preset's variables, parses the NATS
      configs with the nats-server config parser, parses the presets and sizes
      file into typed values, fails on a missing or unknown inventory key or a
      non-positive size, and evaluates the D5 formula with `nats.replicas = 1`;
      config files are declared `data` inputs and no component source is read.
      A vector with the v1.4.73 single-server shape must fail.
- [ ] 5.5 Bump `addons/<name>/addon.yaml` `version` for any native add-on whose
      config changes.

## 6. Verification

- [ ] 6.1 `make test` green.
- [ ] 6.2 Upgrade a v1.4.73 install with flow-collector enabled and default
      values on a scratch cluster: render passes, datasvc shrinks, every
      stream places, `nats server report jetstream` shows reserved below 85%.
