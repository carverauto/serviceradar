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

## 3. Chart budget (D2, D4, D5, D7)

- [ ] 3.1 Byte-exact `max_file_store` helper with `G`/`Gi` parsing and the
      persistence-derived default.
- [ ] 3.2 Lower `datasvc.bucketMaxBytes` to 1 GiB and
      `datasvc.objectStoreBytes` to 4 GiB; correct the budget comments.
- [ ] 3.3 Budget helper and `fail` with itemised message;
      `nats.jetstream.allowOvercommit` escape hatch.
- [ ] 3.4 Fix `EVENT_WRITER_ENABLED` rendering of `false`.
- [ ] 3.5 helm-unittest: defaults pass with flow-collector on and off;
      overrides fail with the itemised message; `allowOvercommit` passes;
      `values-demo.yaml` passes.

## 4. Safe shrink (D6)

- [ ] 4.1 datasvc `reconcileStreamConfigLocked`: never below stored bytes.
- [ ] 4.2 otel log-collector `events` reconcile: same rule.
- [ ] 4.3 EventWriter `reconcile_stream`: same rule.
- [ ] 4.4 Tests for each owner: shrink applies when data fits, is held when
      it does not.

## 5. Verification

- [ ] 5.1 `make test` green.
- [ ] 5.2 Upgrade a v1.4.73 install with flow-collector enabled and default
      values on a scratch cluster: render passes, datasvc shrinks, every
      stream places, `nats server report jetstream` shows reserved below 85%.
