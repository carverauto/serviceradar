# Tasks: NCO composite-check validation runs

## 1. Identity resolve (serviceradar_core)

- [x] 1.1 Add `ServiceRadar.Inventory.Identity.ResolveByAddress` (or
      equivalent) that takes `ip`, `partition` (default `"default"`),
      optional `mac` and implements design D2. Returns
      `{:ok, uid}` / `{:error, :not_found}` /
      `{:error, {:ambiguous, uids}}` /
      `{:error, {:mac_ip_conflict, ip_uid, mac_uid}}`.
- [x] 1.2 Tests: unique IP on `ocsf_devices`; unique IP identifier in
      partition; missing IP; two identifier hits; MAC matches; MAC
      missing ignored; MAC maps to a different UID → conflict. Do not
      mint devices.

## 2. Data model (serviceradar_core)

- [x] 2.1 Migration in `elixir/serviceradar_core/priv/repo/migrations/`
      (`prefix: "platform"`): `validation_runs` and
      `validation_run_devices`. No `public` schema objects.
- [x] 2.2 Ash resources `ServiceRadar.CompositeChecks.ValidationRun` and
      `ValidationRunDevice` (or a nested embed if a child table is
      overkill — prefer a child table so poll queries stay cheap).
      Status enum `pending | probing | evaluating | completed | failed | timed_out`.
      Code interface: `create`, `get_by_id`, `list_recent`.
- [x] 2.3 Policies: `validation_runs.execute` on create;
      `validation_runs.read` on read; `system_bypass` for the worker.
- [x] 2.4 Register resources on the CompositeChecks domain.

## 3. RBAC

- [x] 3.1 Add `validation_runs` section to
      `ServiceRadar.Identity.RBAC.Catalog`:
      `validation_runs.execute` (operator, admin),
      `validation_runs.read` (viewer+).
- [x] 3.2 Confirm catalog key-existence tests pass.

## 4. Orchestrator worker (serviceradar_core)

- [x] 4.1 Coverage resolver: given `(device_uid, ip, partition,
      vantage_agent_id)`, load `SweepGroup.for_agent_partition/2` and
      keep groups that cover the device (`static_targets` CIDR/IP hit,
      or `target_query` plus `uid:<uid>` returns a row). Reuse
      `SweepCompiler`'s profile+override merge for modes, ports,
      timeout. Zero groups → `:uncovered`. Multiple groups → union
      modes/ports, most restrictive timeout; record every
      `sweep_group_id` + `profile_id`.
- [x] 4.2 Oban worker `ValidationRunWorker` (`queue: :monitoring`).
      For each vantage agent, dispatch one
      `AgentCommandBus.dispatch_adhoc_scan/3` whose targets are the
      IPs that agent covers and whose modes/ports/timeout are the
      compiled settings from 4.1. MUST NOT invent ICMP. MUST NOT call
      `SweepGroup.run_now`.
- [x] 4.3 On scan completion (poll `ScanRun` / wait on results), upsert
      `device_agent_availability` for `{device_uid, agent_id}` from
      those results. Do not change the generic ad-hoc scan ingest path.
- [x] 4.4 Call `CompositeChecks.Evaluation.evaluate_devices/5` for the
      run's UIDs. Upsert `device_composite_check_results`. Copy
      verdict / status / inputs / evaluated_at onto
      `validation_run_devices`. Metadata (including `acl_enforced`) is
      read at evaluate time, not at POST time.
- [x] 4.5 Deadline (default 180s): mark unfinished devices timed_out /
      inconclusive on the run; do not invent a pass on the official
      result table.
- [x] 4.6 Tests: device matching `in:devices` inherits `farm-scan`
      modes/ports from both vantage groups; a host outside a group's
      SRQL is uncovered and not probed with ICMP; one agent offline →
      timed_out not healthy; fact written after POST is visible at
      evaluate; `run_now` is never invoked (assert on a stub);
      compiler merge is reused (group port override beats profile).

## 5. HTTP API (web-ng)

- [x] 5.1 `ValidationRunController` under `/api/v1` with
      `:api_key_auth` (same as scans):
      `POST /validation-runs`,
      `GET /validation-runs/:id`,
      `GET /validation-runs/:id/results`.
- [x] 5.2 POST accepts either `devices: [{ip, partition?, mac?}]` or
      the single-device shorthand `ip` + optional `mac` + optional
      `partition`. Requires `check`. Default partition `"default"`.
      Cap 128 devices. Identity resolve runs in-request; 202 includes
      `id`, `status`, and per-device `uid`.
- [x] 5.3 Error mapping: 400 / 401 / 403 / 404 / 409 per design.
- [x] 5.4 Controller tests covering shorthand, list, missing IP, bad
      MAC conflict, unknown check, unauthorized, poll completed
      payload.

## 6. Docs

- [x] 6.1 `docs/docs/nco-validation-runs.md` (ASCII): resolve rules,
      POST/GET examples, poll loop, freshness gate
      (`inputs.*.observed_at` and `evaluated_at` after POST time),
      verdict → report table. Point at the facts endpoint for
      `acl_enforced` / switch/port.
- [x] 6.2 Add a short pointer from `docs/docs/nco-device-facts.md`.
- [x] 6.3 Add the page to `docs/sidebars.ts` under Query & Analyze
      (next to API Reference).

## 7. Verify

- [x] 7.1 `mix test` for the new core + web-ng DataCase files (needs a
      test database URL; catalog unit tests passed without one).
- [x] 7.2 `openspec validate add-nco-validation-runs --strict`.
