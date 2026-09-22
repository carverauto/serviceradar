## 1. Configuration wiring

- [ ] 1.1 Add a new Helm values block (sibling to `observabilityRetention`)
      in `helm/serviceradar/values.yaml` with per-table retention-day
      settings for all 14 newly-configured tables (12 version tables +
      `api_events` + the `security_events` override), per the tiers in
      [design.md](design.md#decisions).
- [ ] 1.2 Template each value into an env var in
      `helm/serviceradar/templates/core.yaml`, following the
      `ANSIBLE_RETENTION_RUN_DETAIL_DAYS` pattern.
- [ ] 1.3 Read each env var in `elixir/serviceradar_core/config/runtime.exs`
      via the existing `parse_int_env.(NAME, default) |> max(floor)` helper;
      wire into `config :serviceradar_core, <Worker>, ...` blocks.
- [ ] 1.4 Add the new `SECURITY_EVENTS_RETENTION_DAYS` env var and wire it
      into `SecurityEventsRetentionWorker`'s existing config, defaulting to
      90 (today's hardcoded value) so this is a no-op at deploy time unless
      an operator sets it.
- [ ] 1.5 docker-compose: add the same new env vars (with their defaults) to
      whichever compose file(s) already carry the `ANSIBLE_RETENTION_*` /
      `SERVICERADAR_*_RETENTION_DAYS` vars, for parity with the non-Helm
      deployment path.

## 2. `api_events` retention worker

- [ ] 2.1 Add `ServiceRadar.Observability.ApiEventsRetentionWorker`
      (namespace to match sibling `ApiEvent`), mirroring
      `SecurityEventsRetentionWorker`'s shape: config-driven
      `retention_days`, a system actor, a resource-level delete-older-than
      action.
- [ ] 2.2 Add a `delete_older_than`-style action to `ApiEvent` if one
      doesn't already fit the resource's existing action set.
- [ ] 2.3 Register the worker's Oban cron entry in
      `elixir/serviceradar_core/config/config.exs`.

## 3. Version-table retention worker (the 12 currently-unpruned tables)

- [ ] 3.1 Add a new worker (e.g.
      `ServiceRadar.Security.AuditVersionRetentionWorker`) covering the 12
      version tables listed in [design.md](design.md#context), following
      `RemoteAccessVersionRetentionWorker`'s batched raw-SQL `DELETE`
      pattern (`@version_tables` list of `{table, retention_config_key}`,
      shared `batch_size` and `@query_timeout_ms`).
- [ ] 3.2 Register its Oban cron entry in
      `elixir/serviceradar_core/config/config.exs`.

## 4. Verification

- [ ] 4.1 Against a real database (per this repo's DB-test conventions):
      seed rows across the retention boundary for a sample of tables from
      each tier (at minimum one 90-day and one 180-day table, plus
      `api_events` and `security_events`), run each worker, and confirm
      only rows older than the configured window are deleted.
- [ ] 4.2 Confirm `SecurityEventsRetentionWorker` still prunes at 90 days
      by default with no env var set (no behavior regression).
- [ ] 4.3 Confirm each worker's batched delete respects `batch_size` (doesn't
      attempt to delete unbounded rows in one query) and completes within
      its query timeout against a realistically-sized seeded table.

## 5. Close out

- [ ] 5.1 `openspec validate add-audit-history-retention-compression --strict`.
