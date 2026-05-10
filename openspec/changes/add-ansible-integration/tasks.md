## 1. Foundations: Ash resources, RBAC, settings

- [ ] 1.1 Add `ansible.*` permissions to `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex` (`controllers.manage`, `repositories.manage`, `catalog.view`, `runs.view`, `runs.launch`, `runs.cancel`, `schedules.view`, `schedules.manage`). **Do not** add `devices.ansible.mark` — derived, not toggled.
- [ ] 1.2 Create `Serviceradar.Automation.Ansible` Ash domain skeleton under `elixir/serviceradar_core/lib/serviceradar/automation/ansible/`
- [ ] 1.3 Define `AnsibleController` Ash resource (id, name, base_url, version, `credential_broker_ref` for the API token, agent_id (which agent reaches it), status, last_health_at, inventory_sync_interval, catalog_sync_interval) with policies wired to `ansible.controllers.manage`. Add `AshPaperTrail` extension.
- [ ] 1.4 Define `PlaybookRepository` Ash resource (id, name, git_url, ref, sync_interval, `credential_broker_ref` (optional, for private HTTPS deploy tokens), last_sync_at, last_sync_status, parse_diagnostics). Add `AshPaperTrail`.
- [ ] 1.5 Define `Playbook` Ash resource — polymorphic catalog entry. Attributes: id, source_type (enum: `git | awx`), repository_id (nullable, when source_type = git), controller_id (nullable, when source_type = awx), awx_job_template_id (nullable), path, name, description, declared_vars (jsonb), survey_spec (jsonb, AWX-sourced), tags, hosts_pattern, parse_status. Constraint: exactly one of (repository_id, controller_id) is set per source_type.
- [ ] 1.6 Define `PlaybookRun` Ash resource using **AshStateMachine** with states `pending → launching → running → succeeded | partial | failed | unreachable | canceled`; attributes include playbook_id, controller_id, awx_job_id, requested_extra_vars, started_at, ended_at, last_event_id, summary, requested_by_actor_id, schedule_id (nullable). Add `AshPaperTrail`.
- [ ] 1.7 Define `PlaybookRunTarget` Ash resource (run_id, device_uid, awx_host_id, awx_host_name, status enum, changed_count, failed_count, ok_count, skipped_count, unreachable_count, started_at, ended_at). Replaces the earlier `PlaybookHostStat` design.
- [ ] 1.8 Define `PlaybookPlay`, `PlaybookTask`, `PlaybookTaskResult` Ash resources. `PlaybookTaskResult` references both `PlaybookTask` and `PlaybookRunTarget` (so a result is attributable to its host). Add `PlaybookContent` blob table with sha256 dedup for stdout/stderr.
- [ ] 1.9 Define `PlaybookSchedule` Ash resource (name, enabled, playbook_id, target_device_uids[], extra_vars, cron, timezone, allow_concurrent (default false), last_evaluated_at, last_run_id, next_run_at, owner_id) with cron-string validator. Add `AshPaperTrail`.
- [ ] 1.10 Run `mix ash.codegen --dev` and verify generated migrations; iterate
- [ ] 1.11 Run `mix ash.codegen add_ansible_integration` for the named migration; commit
- [ ] 1.12 Add Ash policies enforcing the new RBAC permissions on every action
- [ ] 1.13 Add SRQL resource aliases for `ansible_runs`, `ansible_run_targets`, `ansible_playbooks`, `ansible_controllers`, `ansible_schedules` in the AshAdapter

## 2. WASM `awx` plugin (network bridge)

- [ ] 2.1 Scaffold `go/cmd/wasm-plugins/awx/` using `serviceradar-sdk-go` (TinyGo target); Makefile + CI build
- [ ] 2.2 Internal AWX HTTP helper inside the plugin: auth header injection, retry, 429 exponential backoff, typed errors marshaled into `CommandResult.payload_json`
- [ ] 2.3 `run_check` entrypoint: dispatches on `params.verb` to handle `awx.ping`, `awx.list_inventories`, `awx.list_hosts(inventory_id, page, page_size)`, `awx.list_projects`, `awx.list_templates`, `awx.fetch_template(id)`, `awx.launch_job(template_id, extra_vars, host_limit)`, `awx.fetch_job(id)`, `awx.cancel_job(id)`, `awx.fetch_events_for_jobs(pairs)`. One verb per `CommandRequest`, one `CommandResult` per call. List verbs handle pagination internally; `fetch_events_for_jobs` accepts an array of `{job_id, since_id}` and batches one HTTP call per job in the same agent invocation, returning aggregated events keyed by job_id
- [ ] 2.4 `inventory_sync` entrypoint (scheduled assignment mode): walks each configured controller's inventories and hosts, builds a `sdk.NewDeviceDiscovery("awx")` aggregate (mirroring `go/cmd/wasm-plugins/proxmox/main.go:343,433`), attaches via `result.WithDeviceDiscovery(...)`. Discovery records flow through the existing agent → gateway → DIRE pipeline. Plugin reads its controller list from assignment config (Elixir-pushed, not per-request grant)
- [ ] 2.5 Resolve credential broker grants from command payloads (run_check) and from assignment config (inventory_sync); never accept plaintext tokens from Elixir
- [ ] 2.6 `plugin.yaml` manifest: declare both entrypoints, `http_request` capability, `allowed_domains` (operator-templated to AWX hostnames). No streaming-mode declaration — both entrypoints are non-streaming.
- [ ] 2.7 Unit tests against a recorded AWX API fixture (golden files under `testdata/`); include a `fetch_events_for_jobs` test with multiple active jobs and partial event pages

## 3. Elixir AwxClient (CommandBus dispatcher) + AshOban workers

- [ ] 3.1 Create `Serviceradar.Automation.Ansible.AwxClient` Elixir module that issues `AgentCommandBus.dispatch/4` for each AWX verb; typed error structs derived from `CommandResult.payload_json`; never speaks HTTP itself
- [ ] 3.2 Helper to mint a short-lived credential broker grant for the controller's API token and embed it in the `CommandRequest`
- [ ] 3.3 `GitCatalogSyncWorker` (AshOban) — clones / pulls each `PlaybookRepository` on its sync_interval (Elixir-side: catalog repos generally live on github/gitlab.com, reachable from the SaaS plane), walks YAML files, parses metadata, upserts `Playbook` rows with `source_type = "git"`, records parse_diagnostics on errors
- [ ] 3.4 `AwxCatalogSyncWorker` (AshOban) — for each controller, calls `AwxClient.list_projects` + `AwxClient.list_templates` periodically and upserts catalog `Playbook` rows with `source_type = "awx"`, populating `survey_spec` from AWX
- [ ] 3.5 `ControllerHealthWorker` (AshOban) — calls `AwxClient.ping` periodically per controller; updates `last_health_at` / `status`
- [ ] 3.6 `RunPulseWorker` (AshOban, one job per controller) — ticks every `controller.run_pulse_interval_ms` (default 2000); reads non-terminal `PlaybookRun`s for this controller; if any exist, dispatches one `awx.fetch_events_for_jobs(pairs)` command via the bus; on response, persists Play/Task/Result rows attributed to the right `PlaybookRunTarget`, advances each run's `last_event_id`, drives state machine transitions (including `partial` vs `failed` decision based on per-target outcomes), emits NATS events, and emits OCSF-shaped events. Skips ticks when there are no active runs. Also dispatches `awx.fetch_job` for any run whose watermark hasn't moved in this tick to catch terminal status changes.
- [ ] 3.7 `ScheduleEvaluatorWorker` (AshOban) — evaluates `PlaybookSchedule` rows by their cron expressions. On a fire: if the schedule's previous `PlaybookRun` is still non-terminal AND `allow_concurrent = false`, record `skipped_overlap` and continue; otherwise create a new `PlaybookRun` + `PlaybookRunTarget`s, dispatch launch via AwxClient, link `PlaybookRun.schedule_id` to the schedule, update `last_evaluated_at` / `last_run_id` / `next_run_at`.
- [ ] 3.8 `RunWatchdog` (AshOban) — flags runs stuck in non-terminal states past 2× job-template timeout (or 1h fallback) and transitions them to `unreachable`
- [ ] 3.9 `RetentionWorker` (AshOban) — daily sweep that deletes detail rows past `ansible.retention.run_detail_days` and (if configured) run/target rows past `ansible.retention.run_summary_days`. Excludes runs accessed within the last hour.
- [ ] 3.10 Backoff/concurrency caps per-controller in oban queues; circuit-break the AwxClient verbs when the bus reports persistent agent unreachability
- [ ] 3.11 Telemetry: `:telemetry.span(["serviceradar","ansible","run","pulse"], ...)` around each pulse tick; metrics for active-run count per controller, command dispatch latency, events/sec persisted

## 3b. OCSF event projection

- [ ] 3b.1 Define OCSF mapping module `Serviceradar.Automation.Ansible.OcsfMapper` translating `PlaybookTaskResult` + `PlaybookRunTarget` + `PlaybookRun` context into the chosen OCSF class (Application Activity 6003 or Process Activity 1007 — pick during implementation)
- [ ] 3b.2 EventIngestor calls the mapper after each successful task-result write; emit via the existing observability events publisher (do not route through OTEL collector)
- [ ] 3b.3 Property-based test that every distinct task outcome produces an OCSF-valid event
- [ ] 3b.4 Verify events are searchable in the existing log viewer with a couple of sample queries

## 4. Inventory integration (plugin-emitted DeviceDiscovery → DIRE)

- [ ] 4.1 Add `ansible_managed :boolean, default: false` and `ansible_inventory_ref :map` (controller_id, inventory_id, host_id, host_name) to `Device` Ash resource — both attributes are *derived* from DIRE's reconciliation of plugin-emitted records, not directly settable through user actions
- [ ] 4.2 Extend `discovery_source` enum / handling to recognize `"awx"` as a known source
- [ ] 4.3 Update DIRE merge logic to consume AWX-source DeviceDiscovery records emitted by the `awx` plugin's `inventory_sync` entrypoint: match keys in priority order — `variables.ansible_host` IP exact, `variables.ansible_host` hostname exact, AWX host `name` against device hostname
- [ ] 4.4 On DIRE merge with a matching device: set `ansible_managed = true`, populate `ansible_inventory_ref` from the AWX host. On absence of any AWX source for a device: set `ansible_managed = false` and clear `ansible_inventory_ref`
- [ ] 4.5 Surface unmatched AWX hosts on `/settings/ansible` as a "needs review" list (sourced from DIRE's existing unmatched-record surface) with operator-confirmable manual link or "create new device" action that defers to DIRE
- [ ] 4.6 Configure plugin assignment for the `awx` plugin's `inventory_sync` entrypoint: per-agent assignment that lists the controllers reachable from that agent (controller IDs + grant references); `PluginAssignmentMaterializer` re-materializes the assignment whenever controllers are added/removed
- [ ] 4.7 Run codegen + migration

## 5. Catalog UI + settings

- [ ] 5.1 New LiveView `/settings/ansible` admin page with tabs: Controllers, Repositories, Unmatched AWX Hosts, Schedules, Retention. Gated by `ansible.controllers.manage` / `ansible.repositories.manage` / `ansible.schedules.manage`
- [ ] 5.2 Controller form: base_url, api_token (write-only — writes to credential broker), agent_id selector (which agent reaches it), inventory_sync_interval, catalog_sync_interval, run_pulse_interval_ms (default 2000), test-connection action
- [ ] 5.3 Repository form: git_url, ref, sync_interval, optional deploy token (credential broker)
- [ ] 5.4 Retention configuration display showing current values from Helm/docker-compose; read-only in UI (config is operator-managed at deploy time)
- [ ] 5.5 Catalog browser at `/ansible/catalog`: searchable, filter by tag / source (`git` / `awx`) / repository / controller; per-entry source badge; AWX-sourced entries always launchable, git-sourced entries show "AWX template binding required" if not bound
- [ ] 5.6 Empty / error states for unbound (git-sourced), broken-parse, stale-sync, and missing-AWX-template states

## 6. Device Actions modal + run UI

- [ ] 6.1 Build `DeviceActionsModal` LiveComponent under `elixir/web-ng/lib/serviceradar_web_ng_web/components/device_actions_modal.ex` with an action registry (action behaviour: `title/0`, `icon/0`, `required_permission/0`, `applicable?/1` (target list → bool), `render_form/2`, `on_confirm/3`)
- [ ] 6.2 Register `RunPlaybookAction` as the only v1 action; structure ensures additional actions register declaratively without modal changes
- [ ] 6.3 Inventory list LiveView: per-row checkbox, "Run Task" button enabled when ≥1 device selected, opens modal with the selected device list pre-populated
- [ ] 6.4 Device detail LiveView: "Run Task" button opens the modal with that single device pre-populated; replaces the earlier device-detail-specific Run Playbook button
- [ ] 6.5 RunPlaybookAction form: pick playbook from catalog (filtered to launchable: AWX-sourced, or git-sourced with valid AWX template binding); render `vars_prompt` (git) or `survey_spec` (AWX) inputs as typed fields; raw-YAML override toggle
- [ ] 6.6 Confirm screen showing target device list, AWX controller, AWX job template, project, branch, effective extra_vars; permission gate `ansible.runs.launch`
- [ ] 6.7 On confirm: create one `PlaybookRun` + N `PlaybookRunTarget` rows; call `AwxClient.launch_job` with `host_limit` = comma-joined AWX host names of the targets; transition `pending → launching → running` as the bus call returns and events arrive
- [ ] 6.8 New LiveView `/ansible/runs` index — list with filters by status / device / playbook / source, live-updating via PubSub
- [ ] 6.9 New LiveView `/ansible/runs/:id` detail — header with state pill (incl. `partial`), per-target table with per-device status pills, plays/tasks tree, live event tail, link back to AWX UI for the underlying job
- [ ] 6.10 Cancel action on a non-terminal run (gated by `ansible.runs.cancel`) calls `AwxClient.cancel_job`
- [ ] 6.11 `Recent Ansible Runs` panel on device detail page (filtered to runs whose `PlaybookRunTarget`s include this device)

## 6b. Schedule UI

- [ ] 6b.1 Schedules tab on `/settings/ansible` and standalone `/ansible/schedules` route, gated by `ansible.schedules.view`
- [ ] 6b.2 Schedule form: name, playbook picker (catalog), target devices picker (multi-select from inventory; same single-controller rule as ad-hoc launch), extra_vars, cron expression with picker + human-readable preview ("every weekday at 03:00 UTC"), timezone, allow_concurrent toggle (default off)
- [ ] 6b.3 "Schedule this playbook" affordance from the Device Actions modal — pre-fills the schedule form with the selected devices + chosen playbook
- [ ] 6b.4 Schedule detail page: shows schedule, next 5 fire times, recent runs (linked), enable/disable toggle, delete (with confirm)
- [ ] 6b.5 Skipped-overlap badge on the schedule detail when last fire was skipped due to a still-running previous run

## 7. Events, telemetry, NATS

- [ ] 7.1 Define NATS subjects: `serviceradar.ansible.run.started`, `serviceradar.ansible.run.task`, `serviceradar.ansible.run.completed`, `serviceradar.ansible.run.failed`, `serviceradar.ansible.run.canceled`
- [ ] 7.2 `EventBatcher.queue_event/2` calls on every state transition and on each task result
- [ ] 7.3 PubSub broadcasts so the runs LiveView updates without page refresh
- [ ] 7.4 Add observability events / spans schema docs to `openspec/specs/observability-signals` follow-up if reviewers request

## 8. Helm + docker-compose + ops

- [ ] 8.1 Helm `values.yaml`: `ansible.enabled` (bool, default false), `ansible.workers.concurrency`, `ansible.workers.replicas`, `ansible.retention.run_detail_days` (default 90), `ansible.retention.run_summary_days` (default null = forever)
- [ ] 8.2 `docker-compose.yml`: equivalent env vars (`ANSIBLE_ENABLED`, `ANSIBLE_RETENTION_RUN_DETAIL_DAYS`, `ANSIBLE_RETENTION_RUN_SUMMARY_DAYS`); wire through to Elixir config
- [ ] 8.3 Operator docs: AWX setup expectations, AWX RBAC roles required by ServiceRadar's API token (which inventories / templates it must be able to read and launch), where to register the credential broker entries, retention tuning guidance, troubleshooting
- [ ] 8.4 Confirm Helm chart deploys cleanly with feature disabled (default) and enabled

## 9. Tests

- [ ] 9.1 Ash resource tests: state machine transitions cannot go backward; `partial` is reached only when targets have mixed outcomes; RBAC enforcement on every action; AshPaperTrail captures expected events
- [ ] 9.2 WASM plugin unit tests against fixtures (per-verb dispatch including inventory list verbs; streaming event tail)
- [ ] 9.3 AwxClient tests with a stub command bus that asserts the right verbs are dispatched with the right grants
- [ ] 9.4 Git catalog sync integration test against an in-process bare git repo with sample playbooks
- [ ] 9.5 AWX catalog sync test: stub bus returns AWX templates with surveys; assert `Playbook` rows appear with `source_type = "awx"` and survey_spec populated
- [ ] 9.6 Inventory plugin DeviceDiscovery test: plugin emits AWX hosts overlapping with proxmox-discovered devices; assert DIRE merge, `discovery_sources` reflects both, `ansible_managed` flips correctly
- [ ] 9.7 Multi-device run test: launch one playbook against 3 devices, fake plugin returns events for all 3 hosts via `awx.fetch_events_for_jobs`; assert one PlaybookRun + 3 PlaybookRunTargets, mixed outcome → state = `partial`
- [ ] 9.8 RunPulseWorker test: tick with N active runs dispatches one bulk command, persists results, advances watermarks, skips ticks when no active runs; agent-offline tick fails cleanly and the next tick after reconnect resumes from the persisted watermark
- [ ] 9.9 Schedule evaluator tests: cron firing creates a run; firing while a previous run is non-terminal and `allow_concurrent = false` records `skipped_overlap`; `allow_concurrent = true` launches concurrently
- [ ] 9.10 Run launch integration tests covering: success, failure, cancel, watchdog timeout
- [ ] 9.11 OCSF emission test: every distinct task outcome produces an OCSF-valid event in the events stream
- [ ] 9.12 Retention worker test: detail rows past threshold are deleted; recently-accessed runs are excluded; summary rows persist when `run_summary_days = null`
- [ ] 9.13 LiveView tests for Device Actions modal (multi-select, single-select), launch dialog, runs index live updates, run detail tail with per-target table, schedule create/edit/disable
- [ ] 9.14 SRQL aliases query test (incl. `ansible_run_targets`, `ansible_schedules`)
- [ ] 9.15 End-to-end test in dev compose stack: real AWX (helm subchart or docker), real agent + WASM plugin, both a git repo and an AWX-sourced template, launch a hello-world playbook against multiple devices, also create a schedule that fires within the test window; assert run hierarchy + OCSF events + audit trail + schedule attribution all populated

## 10. Validation + archive

- [ ] 10.1 `openspec validate add-ansible-integration --strict` passes
- [ ] 10.2 PR review and approval
- [ ] 10.3 Deploy to staging, run the e2e test, soak for 48h
- [ ] 10.4 After deployment, archive the change (separate PR) per `openspec/AGENTS.md` Stage 3
