## 1. Foundations: Ash resources, RBAC, settings

- [ ] 1.1 Add `ansible.*` permissions to `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex` (`controllers.manage`, `repositories.manage`, `catalog.view`, `runs.view`, `runs.launch`, `runs.cancel`, `schedules.view`, `schedules.manage`). **Do not** add `devices.ansible.mark` — derived, not toggled.
- [ ] 1.2 Create `Serviceradar.Automation.Ansible` Ash domain skeleton under `elixir/serviceradar_core/lib/serviceradar/automation/ansible/`
- [ ] 1.3 Define `AnsibleController` Ash resource (id, name, base_url, version, `credential_broker_ref` for the API token, agent_id (which agent reaches it), status, last_health_at, inventory_sync_interval, catalog_sync_interval) with policies wired to `ansible.controllers.manage`. Add `AshPaperTrail` extension.
- [ ] 1.4 Define `PlaybookRepository` Ash resource (id, name, git_url, ref, sync_interval, `credential_broker_ref` (optional, for private HTTPS deploy tokens), last_sync_at, last_sync_status, parse_diagnostics). Add `AshPaperTrail`.
- [ ] 1.5 Define `Playbook` Ash resource — polymorphic catalog entry. Attributes: id, source_type (enum: `git | awx`), repository_id (nullable, when source_type = git), controller_id (nullable, when source_type = awx), awx_job_template_id (nullable), path, name, description, declared_vars (jsonb), survey_spec (jsonb, AWX-sourced), tags, hosts_pattern, parse_status. Constraint: exactly one of (repository_id, controller_id) is set per source_type.
- [ ] 1.6 Retain the internal `PlaybookRun` AshStateMachine and its ingestion/audit fields, but remove raw requested variables from create/update inputs and keep hardened interactive launches on `AutomationOperation` / `AutomationExecution` / exact targets. Add `AshPaperTrail` only for the retained internal lifecycle.
- [ ] 1.7 Define `PlaybookRunTarget` Ash resource (run_id, device_uid, awx_host_id, awx_host_name, status enum, changed_count, failed_count, ok_count, skipped_count, unreachable_count, started_at, ended_at). Replaces the earlier `PlaybookHostStat` design.
- [ ] 1.8 Define `PlaybookPlay`, `PlaybookTask`, `PlaybookTaskResult` Ash resources. `PlaybookTaskResult` references both `PlaybookTask` and `PlaybookRunTarget` (so a result is attributable to its host). Add `PlaybookContent` blob table with sha256 dedup for stdout/stderr.
- [ ] 1.9 Retain `PlaybookSchedule` for migration/audit compatibility, force new rows disabled, reject enablement and raw requested variables, and keep its PaperTrail history until a separate approved backend-retirement or immutable-delegation change.
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
- [ ] 3.7 Keep `ScheduleEvaluatorWorker` fail-closed for retained disabled rows; prove it cannot create a `PlaybookRun`, canonical operation, or AWX launch command through the retired launcher.
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

- [ ] 5.1 New LiveView `/settings/ansible` admin page with Controllers, Repositories, and Unmatched AWX Hosts surfaces. Do not expose retained schedule, ingestion, watchdog, retention, or history controls.
- [ ] 5.2 Controller form: base_url, api_token (write-only — writes to credential broker), agent_id selector (which agent reaches it), inventory_sync_interval, catalog_sync_interval, and test-connection action
- [ ] 5.3 Repository form: git_url, ref, sync_interval, optional deploy token (credential broker)
- [ ] 5.4 Keep retained lifecycle and evidence-retention configuration out of the operator UI; deployment configuration remains internal until the backend is migrated or retired.
- [ ] 5.5 Catalog browser at `/ansible/catalog`: searchable, filter by tag / source (`git` / `awx`) / repository / controller; per-entry source badge; treat binding metadata as informational. Only parse-valid AWX-sourced entries are eligible for hardened selection, and launch readiness still requires a current approved binding plus live preflight.
- [ ] 5.6 Empty / error states for unbound (git-sourced), broken-parse, stale-sync, and missing-AWX-template states

## 6. Hardened launch + canonical operation UI

- [ ] 6.1 Inventory list LiveView: per-row selection and **Launch Playbook** navigation to `/ansible/launch?devices=...` using canonical device UIDs; keep provider-neutral **Run Action** separate under `northbound.actions.launch`.
- [ ] 6.2 Device detail LiveView: **Launch Playbook** opens the in-panel hardened launch modal for the current canonical device.
- [ ] 6.3 Route both surfaces through `SecureLaunchService`, which re-resolves the current human, approved binding, durable memberships, target holds, and live AWX preflight on submit.
- [ ] 6.4 Filter the launch picker to parse-valid AWX-sourced rows and keep launch unavailable until the current approved binding and exact memberships resolve.
- [ ] 6.5 Render only typed non-secret inputs declared by the approved immutable binding; reject raw JSON/YAML, password fields, undeclared names, transport variables, callback controls, and git `vars_prompt` as browser launch inputs.
- [ ] 6.6 Show exact target and binding readiness without exposing mutable host limits, credentials, or arbitrary `extra_vars`; permission gate `ansible.runs.launch`.
- [ ] 6.7 On confirm: use the hardened launch service to persist one canonical `AutomationOperation`, its inventory-bound child execution, and exact immutable target evidence before dispatch; call `AwxClient.launch_job` only through the reviewed plan and navigate success to `/ansible/operations/:id`
- [ ] 6.8 Canonical LiveView `/ansible/operations` index — list operations with state filters, initiator, request source, mode, timestamps, and evidence links; do not expose a separate `PlaybookRun` index
- [ ] 6.9 Canonical LiveView `/ansible/operations/:id` detail — show operation state and authority evidence, inventory-bound child executions, exact target tuples, immutable revision/digests, dispatch/AWX correlation, diagnostics, and active holds
- [ ] 6.10 Keep canonical operation history read-only until the complete hardened cancellation path is explicitly exposed; retain `ansible.runs.cancel` for authorized service compatibility.
- [ ] 6.11 `Recent Ansible operations` panel on device detail, sourced only from canonical execution targets and linked only to `/ansible/operations/:id`; retained `PlaybookRunTarget` rows do not affect history or the empty state

## 6b. Retained schedule boundary

- [ ] 6b.1 Remove schedule tabs, forms, routes, enable/disable controls, and "Schedule this playbook" affordances from the supported UI.
- [ ] 6b.2 Preserve retained schedule rows and compatibility permissions without accepting raw variables or authorizing execution.
- [ ] 6b.3 Defer scheduled execution to a separate approved change that defines immutable delegation, fire-time reauthorization, typed non-secret inputs, and canonical operation evidence.

## 7. Events, telemetry, NATS

- [ ] 7.1 Define NATS subjects: `serviceradar.ansible.run.started`, `serviceradar.ansible.run.task`, `serviceradar.ansible.run.completed`, `serviceradar.ansible.run.failed`, `serviceradar.ansible.run.canceled`
- [ ] 7.2 `EventBatcher.queue_event/2` calls on every state transition and on each task result
- [ ] 7.3 Canonical operation pages read persisted operation evidence and support explicit refresh; they do not subscribe to the retained `PlaybookRun` PubSub stream or expose a separate run-history LiveView.
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
- [ ] 9.7 Retained ingestion test: seed one internal PlaybookRun with 3 PlaybookRunTargets, have the fake plugin return events for all 3 hosts via `awx.fetch_events_for_jobs`, and assert host attribution plus mixed outcome → state = `partial`; do not launch it through the hardened UI.
- [ ] 9.8 RunPulseWorker test: tick with N active runs dispatches one bulk command, persists results, advances watermarks, skips ticks when no active runs; agent-offline tick fails cleanly and the next tick after reconnect resumes from the persisted watermark
- [ ] 9.9 Schedule retirement tests: new rows are disabled, enablement fails, raw requested variables are not accepted, the evaluator cannot launch, and no schedule controls render in Ansible settings.
- [ ] 9.10 Hardened operation launch integration tests covering success, preflight or authorization refusal before persistence or dispatch, canonical operation/execution/target evidence, and the operation-detail redirect.
- [ ] 9.11 OCSF emission test: every distinct task outcome produces an OCSF-valid event in the events stream
- [ ] 9.12 Retention worker test: detail rows past threshold are deleted; recently-accessed runs are excluded; summary rows persist when `run_summary_days = null`
- [ ] 9.13 LiveView tests for inventory multi-select launch navigation, device in-panel launch, reviewed non-secret input enforcement, canonical operation index/detail evidence, canonical device operation history, retired execution-history routes returning not found, and absence of schedule controls.
- [ ] 9.14 SRQL aliases query test (incl. `ansible_run_targets`, `ansible_schedules`)
- [ ] 9.15 End-to-end test in dev compose stack: real AWX, real agent + WASM plugin, an AWX-sourced template with a current approved binding, and multiple exact devices; assert hardened launch creates canonical operation/execution/target evidence and that no git/raw-input or schedule path can dispatch.

## 10. Validation + archive

- [ ] 10.1 `openspec validate add-ansible-integration --strict` passes
- [ ] 10.2 PR review and approval
- [ ] 10.3 Deploy to staging, run the e2e test, soak for 48h
- [ ] 10.4 After deployment, archive the change (separate PR) per `openspec/AGENTS.md` Stage 3
