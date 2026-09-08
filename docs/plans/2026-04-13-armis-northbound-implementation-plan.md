# Armis Northbound Availability Updates Implementation Plan

> For Hermes: Use subagent-driven-development skill to implement this plan task-by-task.

Goal: Restore Armis northbound updates using the current ServiceRadar architecture: DB-backed state, Ash/AshOban scheduling, explicit UI controls, per-run metrics/events, and demo-namespace verification.

Architecture: Keep Armis inbound discovery in the current agent/runtime path, but move northbound scheduling and execution into the Elixir control plane. Use `ServiceRadar.Integrations.IntegrationSource` plus a new Armis-specific schedule/run model in `serviceradar_core`, execute northbound work through Oban/AshOban, query canonical device state from CNPG (`ocsf_devices` + `device_identifiers`), and surface controls/history through the existing integrations/jobs UI in `web-ng`.

Tech Stack: Ash/AshPostgres/AshStateMachine/AshOban, Phoenix LiveView, Req, Oban, CNPG/Postgres, jj, fj, Bazel, Makefile, Kubernetes demo namespace.

---

## Task 0: Open tracking issue and create a jj change

Objective: Create the SCM scaffolding before code changes so the work has an issue, a named jj change, and a future PR target.

Files:
- Create: none
- Modify: none
- Output artifacts: Forgejo issue, jj change, later PR

Step 1: Sync local state
Run:
`jj status`
`jj git fetch --remote origin`
Expected: clean understanding of current working copy and latest remote state.

Step 2: Create the Forgejo issue
Run:
`fj issue create -R origin "Restore Armis northbound availability updates" --body-file /tmp/armis-northbound-issue.md`
Issue body should summarize:
- northbound Armis updates are missing
- DB must be source of truth, not NATS KV
- AshOban scheduling, user-configurable cadence, UI visibility, metrics/events
- demo namespace validation required

Step 3: Create a jj change for the implementation
Run:
`jj new -m "feat: armis northbound db-backed scheduling"`
Expected: new working change is created for the feature.

Step 4: Record issue link in the change description
Run:
`jj describe -m "feat: armis northbound db-backed scheduling

Refs: <forgejo-issue-url>"`
Expected: the jj change description links back to the issue.

---

## Task 1: Add first-class northbound config + status fields to IntegrationSource

Objective: Stop hiding northbound behavior in dead code or generic maps; give it explicit resource fields that the UI and jobs can use.

Files:
- Modify: `elixir/serviceradar_core/lib/serviceradar/integrations/integration_source.ex`
- Modify: `elixir/serviceradar_core/priv/repo/migrations/20260117090000_rebuild_schema.exs` only as reference for current schema shape
- Create: new migration under `elixir/serviceradar_core/priv/repo/migrations/`
- Test: `elixir/serviceradar_core/test/**` (new tests)

Step 1: Add new IntegrationSource attributes
Add explicit fields such as:
- `northbound_enabled :boolean`
- `northbound_interval_seconds :integer`
- `northbound_last_run_at :utc_datetime`
- `northbound_last_result :atom` (`:success | :partial | :failed | :timeout` or equivalent)
- `northbound_last_device_count :integer`
- `northbound_last_updated_count :integer`
- `northbound_last_skipped_count :integer`
- `northbound_last_error_message :string`
- `northbound_consecutive_failures :integer`
- `northbound_status :atom` (`:idle | :running | :success | :failed`)

Do not overload `settings` for these core operator-facing fields.

Step 2: Add dedicated northbound actions/state transitions
In `integration_source.ex`, add actions parallel to the existing inbound sync actions, for example:
- `northbound_start`
- `northbound_success`
- `northbound_failed`

Keep inbound sync fields intact. The whole point is to show discovery status and northbound status separately.

Step 3: Add migration
Create a migration that adds the new columns to `platform.integration_sources`.
Also add indexes if list/detail pages will sort/filter on northbound timestamps/status.

Step 4: Add resource tests
Cover:
- create/update with new northbound fields
- status transitions for northbound actions
- failure counters resetting on success

Step 5: Verify
Run:
`cd elixir/serviceradar_core && mix test`
Expected: resource tests pass.

---

## Task 2: Add a dedicated Armis northbound run-history resource

Objective: Persist source-specific northbound run history with counts/errors; Oban history alone is not enough for the integrations UI.

Files:
- Create: `elixir/serviceradar_core/lib/serviceradar/integrations/integration_update_run.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/integrations.ex`
- Create: new migration under `elixir/serviceradar_core/priv/repo/migrations/`
- Test: `elixir/serviceradar_core/test/**`

Step 1: Create the resource
Add a resource for per-run history with fields like:
- `id`
- `integration_source_id`
- `run_type` (`:armis_northbound`)
- `status` (`:running | :success | :partial | :failed | :timeout`)
- `started_at`, `finished_at`
- `device_count`, `updated_count`, `skipped_count`, `error_count`
- `error_message`
- `oban_job_id`
- `metadata`

Step 2: Add relationships and read actions
Expose:
- `by_source`
- `recent_by_source`
- optional `latest_by_source`

Step 3: Add migration
Create the table in `platform`, add foreign key/index on `integration_source_id`, and index timestamps.

Step 4: Add tests
Cover:
- creating a running record
- finishing it as success/failure
- reading recent runs by source

Step 5: Verify
Run:
`cd elixir/serviceradar_core && mix test`
Expected: new run-history resource passes tests.

---

## Task 3: Build the DB-backed Armis northbound runner

Objective: Query canonical device state from CNPG and build one outbound update per Armis device.

Files:
- Create: `elixir/serviceradar_core/lib/serviceradar/integrations/armis_northbound_runner.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/inventory/device.ex` only if a new read action helps
- Modify: `elixir/serviceradar_core/lib/serviceradar/inventory/device_identifier.ex` only if a new query helper helps
- Modify: `elixir/serviceradar_core/lib/serviceradar/integrations/integration_source.ex`
- Test: `elixir/serviceradar_core/test/**`

Step 1: Query canonical Armis devices from DB
Use persisted state, not KV.
Preferred source:
- `platform.device_identifiers` for `identifier_type = :armis_device_id`
- join to `platform.ocsf_devices` / `ServiceRadar.Inventory.Device`

Use the persisted device `is_available` field as the northbound source of truth.

Step 2: Filter to Armis-owned devices
Require at minimum:
- matching `armis_device_id`
- source/integration association that ties the device back to the IntegrationSource being updated

If a direct source-to-device link is missing today, add the minimal DB-backed linkage needed instead of reintroducing KV coupling.

Step 3: Collapse to one outbound row per Armis device
If multiple device observations or aliases still map to one `armis_device_id`, collapse before sending.
The outbound payload should contain exactly one write per Armis device.

Step 4: Implement Armis API calls with Req
Follow repo guidance and use `Req`, not HTTPoison/Tesla/httpc.
Port only the useful behavior from the historical Go updater:
- Armis auth
- bulk custom-properties endpoint
- batching
- clear error handling

Design this for scale from day one: expected northbound volume is roughly 50k devices, so one-at-a-time writes are explicitly out of scope. Add bounded batch sizing, retry semantics, and tests that prove the code paths are batch-oriented.

Step 5: Update source + run records
When a run starts:
- mark source northbound status `:running`
- create `IntegrationUpdateRun(status: :running)`

When a run finishes:
- update source northbound status/result/counts/errors
- finalize the run-history row

Step 6: Add focused tests
Cover:
- missing `custom_field` skips execution cleanly
- no `armis_device_id` => skipped row
- multi-row input collapses to one outbound device update
- Armis API error => source northbound failure + run-history failure

Step 7: Verify
Run:
`cd elixir/serviceradar_core && mix test`
Expected: runner tests pass.

---

## Task 4: Schedule northbound execution with AshOban/Oban

Objective: Make northbound updates recurring and manual, using the current jobs architecture rather than the deprecated `ng_job_schedules` path.

Files:
- Create: `elixir/serviceradar_core/lib/serviceradar/integrations/armis_northbound_schedule.ex` or equivalent schedule resource
- Modify: `elixir/serviceradar_core/lib/serviceradar/integrations.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/application.ex` only if startup wiring is needed
- Modify: `elixir/web-ng/lib/serviceradar_web_ng/jobs/job_catalog.ex`
- Test: `elixir/web-ng/test/app_domain/jobs_test.exs`
- Test: `elixir/web-ng/test/phoenix/live/admin/job_live_authorization_test.exs`

Step 1: Do not use `ng_job_schedules`
`elixir/web-ng/lib/serviceradar_web_ng/jobs/schedule.ex` exists, but `JobCatalog` explicitly says that table is deprecated.
Keep the implementation aligned with the current system:
- AshOban trigger if the schedule can be modeled as a resource/action
- otherwise a self-scheduling Oban worker that is still DB-backed and visible through JobCatalog

Because the user explicitly wants AshOban, prefer a resource-backed scheduling model if it can represent per-source cadence safely.

Step 2: Model per-source cadence
Create a resource or schedule record that belongs to an `IntegrationSource` and carries:
- enabled flag
- cadence/interval
- next run metadata if needed
- queue/uniqueness behavior

Step 3: Register the job in JobCatalog
Update `elixir/web-ng/lib/serviceradar_web_ng/jobs/job_catalog.ex` so the Armis northbound job appears in the jobs UI with:
- worker/resource/action
- next run
- recent runs
- manual trigger support

Step 4: Add uniqueness/overlap protection
Ensure a single source does not run overlapping northbound jobs.
If two scheduler ticks collide, one should win and the other should no-op or dedupe.

Step 5: Add manual run path
The integrations detail view and jobs UI both need a manual trigger.
Use the same code path as scheduled execution so the result handling is identical.

Step 6: Verify
Run:
`cd elixir/web-ng && mix test test/app_domain/jobs_test.exs test/phoenix/live/admin/job_live_authorization_test.exs`
Expected: job catalog/manual trigger behavior stays green.

---

## Task 5: Emit metrics and persisted events for each northbound run

Objective: Make every run observable from metrics and the Events UI.

Files:
- Create: `elixir/serviceradar_core/lib/serviceradar/integrations/armis_northbound_event_writer.ex` or equivalent helper
- Modify: `elixir/serviceradar_core/lib/serviceradar/integrations/armis_northbound_runner.ex`
- Modify: existing observability/event helper modules if a shared path already exists
- Test: `elixir/serviceradar_core/test/**`

Step 1: Emit Telemetry/metrics
Add metrics for:
- run count
- run duration
- updated device count
- skipped device count
- failure count
- optional batch count / batch size

Use the same telemetry conventions already used for jobs/Ash observability where possible.

Step 2: Emit persisted events
After every run:
- success => write a success event with integration source ID/name and counts
- failure => write a failure event with integration source ID/name and summarized error

Do not rely on NATS for these internal events. Use the existing DB-backed event path.

Step 3: Add tests
Cover:
- success event written
- failure event written
- metrics emitted once per run

Step 4: Verify
Run:
`cd elixir/serviceradar_core && mix test`
Expected: metrics/event tests pass.

---

## Task 6: Extend the Integrations UI for northbound controls and history

Objective: Bring the dead-pathed behavior back into a first-class operator workflow in the current UI.

Files:
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/integrations_live/index.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/components/settings_components.ex` if shared UI helpers are useful
- Create/Modify tests under `elixir/web-ng/test/phoenix/live/**`

Step 1: Extend create/edit forms
For Armis sources only, add fields for:
- northbound enabled
- northbound cadence/interval
- custom field target visibility/validation

Do not show these controls for non-Armis sources.

Step 2: Separate inbound and outbound status in list/detail views
The current list uses `source.last_sync_result` and `source.last_error_message` only.
Add a separate northbound status block/column/card showing:
- northbound status
- last northbound run time
- last northbound result
- last northbound error
- summary counts

Step 3: Add recent runs panel
On the source detail page/modal, show recent `IntegrationUpdateRun` rows for the source.

Step 4: Add Run now action
Hook the button to the same manual job trigger path used by the scheduler/jobs UI.

Step 5: Add LiveView tests
Cover:
- Armis-only controls render for Armis sources
- non-Armis source hides northbound controls
- discovery status and northbound status display separately
- Run now enqueues successfully

Step 6: Verify
Run:
`./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`
Expected: web-ng quality checks pass.

---

## Task 7: Add source-specific run/status visibility to Jobs UI where useful

Objective: Ensure operators can also inspect the northbound job from the central jobs surface.

Files:
- Modify: `elixir/web-ng/lib/serviceradar_web_ng/jobs/job_catalog.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/job_live/index.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/job_live/show.ex`
- Test: `elixir/web-ng/test/phoenix/live/**`

Step 1: Ensure the job appears in JobCatalog
If implemented as an AshOban resource, add the resource to the AshOban resource list.
If implemented as a self-scheduling worker, add it to the self-scheduling list.

Step 2: Make the job description meaningful
Use a name/description that clearly says this is the Armis northbound availability updater.

Step 3: Show recent execution context
Where practical, surface source-level context or link out to the integration detail page.

Step 4: Verify
Run:
`./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`
Expected: jobs UI continues to pass quality checks.

---

## Task 8: End-to-end verification in demo

Objective: Validate the feature on the real deployment path used by the team, preferring the existing `demo` namespace over standing up a separate Docker Compose test stack.

Files:
- Modify as needed in Helm/app config if scheduler wiring requires it
- Modify faker service if needed to emulate Armis northbound bulk updates and provide readback/debug visibility
- Verify in `demo` namespace

Step 1: OpenSpec validation
Run:
`openspec validate add-armis-northbound-availability-updates --strict`
Expected: change remains valid.

Step 2: Elixir quality checks
Run:
`./scripts/elixir_quality.sh --project elixir/serviceradar_core`
`./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`
Expected: both projects pass.

Step 3: Extend faker for northbound validation if required
Implement faker support for:
- `POST /api/v1/devices/custom-properties/_bulk/`
- in-memory storage of updated custom-property values keyed by Armis device ID
- a debug/readback endpoint or aggregate counters so we can confirm the bulk update actually happened in `demo`

This is preferred to introducing a separate compose-only validation harness if `demo` can exercise the full path.

Step 4: Build images
Because this change spans control-plane code/UI and may also touch faker, do not use the web-ng-only fast path.
Run:
`make build`
Expected: Bazel builds images successfully.

Step 5: Push images
Run:
`make push_all`
Expected: images are published to `registry.carverauto.dev`.

Step 6: Deploy to demo
Run:
`helm upgrade --install serviceradar ./helm/serviceradar -n demo -f helm/serviceradar/values-demo.yaml --set global.imageTag="sha-$(git rev-parse HEAD)" --rollback-on-failure`
Expected: rollout to demo namespace starts successfully.

Step 7: Watch rollout
Run:
`kubectl get pods -n demo`
`helm status serviceradar -n demo`
Expected: updated pods become healthy.

Step 8: Functional verification in demo
Verify all of the following:
- Armis source can be edited to enable northbound scheduling
- manual Run now works
- northbound run history appears in UI
- success/failure event appears in Events UI
- source detail shows distinct inbound sync and northbound status
- faker confirms receipt of bulk northbound updates through debug/readback state or counters
- validation demonstrates bulk behavior at meaningful scale rather than one-at-a-time writes

---

## Task 9: Push bookmark and create Forgejo PR

Objective: Land the work with the team’s jj + Forgejo workflow.

Files:
- Output artifacts: pushed bookmark/change, Forgejo PR

Step 1: Inspect final diff
Run:
`jj status`
`jj diff`
Expected: only intended files are changed.

Step 2: Update change description
Run:
`jj describe -m "feat: restore armis northbound availability updates

Refs: <forgejo-issue-url>"`
Expected: final change description is ready for PR autofill if desired.

Step 3: Push the change
Run one of:
`jj git push --change @`
or
`jj git push --remote origin --change @`
Expected: remote bookmark for the change is created.

Step 4: Open the PR in Forgejo
Run:
`fj pr create --base main --head <pushed-head> --body-file /tmp/armis-northbound-pr.md "feat: restore armis northbound availability updates"`
Expected: PR is created and linked to the issue.

---

## Notes for the implementer

- Prefer Elixir/core for northbound execution. Do not start by reviving the old Go/KV northbound path.
- Keep inbound discovery and outbound update state separate everywhere: schema, actions, UI, metrics, and events.
- Use `Req` for Armis HTTP work.
- Use `SystemActor.system/1` for background resource operations; do not use `authorize?: false`.
- Do not revive the deprecated `ng_job_schedules` table for this feature.
- The DB search_path model is authoritative; do not add deployment identifiers in app code.
