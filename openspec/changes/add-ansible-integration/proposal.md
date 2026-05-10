# Change: Ansible Playbook Integration with AWX-Backed Execution and Native Observability

## Why

Operators want to run Ansible playbooks against devices already known to ServiceRadar's inventory and see the run unfold inside ServiceRadar — without standing up ARA (which duplicates a UI, schema, and Python service that we already have better answers for in Ash/LiveView) and without forcing operators to context-switch to AWX to launch a job. We currently have zero Ansible awareness in the platform: a device cannot be marked as Ansible-managed, there is no playbook catalog, and there is no UI for launching or observing a run.

This change introduces a first-class `ansible-integration` capability that:

1. Lets operators register one or more **AWX/AAP controllers** as the execution backend (no ServiceRadar-side `ansible-playbook` execution).
2. Lets operators register **git repositories** as the canonical playbook catalog source, with metadata sync handled by AshOban workers.
3. Marks devices in the inventory as **Ansible-managed**, with linkage to AWX inventory hosts.
4. Adds a **Run Playbook** action to the device detail LiveView, gated by RBAC.
5. Persists a **run / play / task / host-result** hierarchy in Ash resources so operators can drill into a run after the fact — replacing ARA's role.
6. Streams **events into ServiceRadar's observability plane** (NATS JetStream → EventBatcher) so the UI updates live and the data is queryable via SRQL.

Credentials (SSH keys, become passwords, sudo passwords) are explicitly **not** stored by ServiceRadar; they remain in AWX's credential vault. ServiceRadar only stores the AWX API token used to authenticate to the controller, encrypted via AshCloak.

## What Changes

### Inventory

- **ADD** `ansible_managed` boolean and `ansible_inventory_ref` map fields on `Device` (records AWX controller id + inventory id + host id + host name). These fields are **derived automatically** by the AWX inventory sync; there is no manual toggle.
- **ADD** AWX as a recognized `discovery_source` value (alongside proxmox, armis, sweep, etc.) so DIRE merges AWX-discovered hosts with records from other discovery tools transparently. This is essential because operators commonly point both ServiceRadar and AWX at the same upstream (e.g. the proxmox community Ansible inventory plugin), so the same host arrives via two paths.

### Ansible Integration (new capability)

- **ADD** `AnsibleController` Ash resource (AWX/AAP base_url, version, **credential broker reference** for the API token, agent_id that reaches it, health status, sync intervals). Token is held by the existing credential broker, not on the resource — same pattern as proxmox / unifi today. Tracked by AshPaperTrail.
- **ADD** `PlaybookRepository` Ash resource (git URL, branch/ref, sync schedule, last-sync state) with AshOban sync workers. Tracked by AshPaperTrail.
- **ADD** `Playbook` Ash resource — **polymorphic catalog entry**. `source_type ∈ {git, awx}`. For git-sourced playbooks: `repository_id` + `path` + parsed metadata (name, description, declared vars, `vars_prompt`, tags, hosts pattern). For AWX-sourced playbooks: `controller_id` + `awx_job_template_id` + AWX `survey_spec`-derived variable prompts. A single playbook can be reachable through both sources (operators choose one or both).
- **ADD** `PlaybookRun` Ash resource using **Ash State Machine** (`pending → launching → running → succeeded | failed | partial | unreachable | canceled`), with launch-time snapshot of vars, AWX job id, `last_event_id` watermark, `requested_by_actor_id`, optional `schedule_id` (when launched by a schedule). Tracked by AshPaperTrail.
- **ADD** `PlaybookRunTarget` Ash resource — one row per device targeted by a run, with per-device status (`ok | failed | unreachable | skipped`) and stats (changed, failed, ok, skipped, unreachable counts). Replaces single-device coupling: a run with N selected devices has N `PlaybookRunTarget` rows.
- **ADD** `PlaybookSchedule` Ash resource — `name`, `enabled`, `playbook_id`, `target_device_uids[]`, `extra_vars`, `cron`, `timezone`, `allow_concurrent`, `last_evaluated_at`, `last_run_id`, `next_run_at`, `owner_id`. Tracked by AshPaperTrail. RBAC: `ansible.schedules.view`, `ansible.schedules.manage`.
- **ADD** `PlaybookPlay`, `PlaybookTask`, `PlaybookTaskResult` Ash resources mirroring the run hierarchy (replaces ARA's data model). `PlaybookTaskResult` references `PlaybookRunTarget` for per-host attribution.
- **ADD** **`awx` WASM plugin** (`cmd/wasm-plugins/awx/`, built with `serviceradar-sdk-go`) — the network bridge into the customer network. **Controller-agnostic**: one plugin instance per agent serves N controllers; per-call credential broker grants carry the base_url + token for the target controller. Two entrypoints:
  - `run_check` (on-demand via CommandBus): all AWX REST verbs — `awx.ping`, `awx.list_inventories`, `awx.list_hosts`, `awx.list_projects`, `awx.list_templates`, `awx.fetch_template`, `awx.launch_job`, `awx.fetch_job`, `awx.cancel_job`, and the bulk `awx.fetch_events_for_jobs([(job_id, since_id), …])` that drives the run-event tail. One `CommandRequest` → one `CommandResult`. **No long-lived streams.**
  - `inventory_sync` (scheduled assignment): mirrors the proxmox-inventory plugin pattern (`go/cmd/wasm-plugins/proxmox/main.go:343,433`). Lists every inventory + host across configured controllers and emits a `sdk.NewDeviceDiscovery("awx")` aggregate via `result.WithDeviceDiscovery(...)`. Records flow through the existing agent → gateway → DIRE pipeline. **No new ingestion plumbing on Elixir.**
- **ADD** `Serviceradar.Automation.Ansible.AwxClient` (Elixir) — issues `AgentCommandBus.dispatch` for each AWX REST verb; never speaks HTTP itself; returns typed errors.
- **ADD** `Serviceradar.Automation.Ansible.RunPulseWorker` (AshOban, one job per controller) — ticks every `run_pulse_interval_ms` (default 2000), batches active-run watermarks, dispatches `awx.fetch_events_for_jobs`, persists results, drives state machine, projects OCSF events. Skips ticks when there are no active runs.
- **ADD** `Serviceradar.Automation.Ansible.AwxCatalogSyncWorker` (AshOban) — for each `AnsibleController`, periodically syncs Job Templates (and their `survey_spec`) via `awx.list_templates` and upserts them as `Playbook` rows with `source_type = "awx"`.
- **ADD** `Serviceradar.Automation.Ansible.GitCatalogSyncWorker` (AshOban) — for each `PlaybookRepository`, syncs the git repo and upserts playbooks with `source_type = "git"`.
- **ADD** `Serviceradar.Automation.Ansible.ScheduleEvaluatorWorker` (AshOban) — evaluates `PlaybookSchedule` rows against their cron expressions and creates `PlaybookRun`s when they fire; respects per-schedule `allow_concurrent` policy.
- **ADD** `Serviceradar.Automation.Ansible.RetentionWorker` (AshOban) — applies the configured retention policy.
- **ADD** **LiveView**:
  - **Device Actions modal** (new, multi-device): launched from the inventory list when one or more devices are selected, or from the device detail page (with the current device pre-selected). Displays a list of available actions; in v1 only `Run Playbook` is wired up. Action registry is structured so future actions (Run MTR, Perform Network Scan, etc.) can register declaratively in later changes without touching the modal.
  - `Recent Ansible Runs` panel on the device detail page (filtered to runs targeting that device).
  - New `/ansible/runs` index and `/ansible/runs/:id` detail with live event streams; the detail page shows the per-device target table with per-host status pills, plus the play/task tree.
  - `/settings/ansible` admin page for controllers, git repositories, and retention configuration display.
- **ADD** RBAC permissions: `ansible.controllers.manage`, `ansible.repositories.manage`, `ansible.catalog.view`, `ansible.runs.view`, `ansible.runs.launch`, `ansible.runs.cancel`, `ansible.schedules.view`, `ansible.schedules.manage`. **No** `devices.ansible.mark` — derived, not toggled.
- **ADD** SRQL aliases for `ansible_runs`, `ansible_run_targets`, `ansible_playbooks`, `ansible_controllers`, `ansible_schedules`.
- **ADD** OCSF event emission: each task result and run state transition is also written as an OCSF-shaped event into the existing observability events stream — giving operators ansible visibility in the universal log viewer with no extra collector hop.
- **ADD** AshPaperTrail-backed audit trail on `PlaybookRun`, `AnsibleController`, `PlaybookRepository`.

### Observability

- **ADD** NATS subjects under `serviceradar.ansible.*` and Ash observability events for run/task lifecycle.

### Out of Scope (v1)

- Pushing or creating hosts in AWX inventory from ServiceRadar (operators manage AWX inventory themselves; ServiceRadar only mirrors and links).
- Direct `ansible-playbook` execution by a ServiceRadar agent (AWX-only in v1; the Go-side execution path is reserved for a follow-up).
- Storing SSH keys, become passwords, or vault passwords in ServiceRadar (AWX vault only).
- Webhook ingestion from AWX (deferred to v2 — see design.md "Deferred to v2: Webhook Augmentation" for the agent-side receiver sketch).
- Advanced schedule features: timezones-per-target, blackout windows, holiday calendars. v1 ships standard 5-field cron + timezone-per-schedule; the rest can come later.
- Wiring up Run MTR, Perform Network Scan, or other non-ansible actions in the new Device Actions modal — the modal architecture supports them, but only Run Playbook is implemented in this change. Other actions land in their own changes.
- Replacing ARA for non-ServiceRadar contexts.

## Impact

- **Affected specs:**
  - `ansible-integration` (NEW capability)
  - `device-inventory` (MODIFIED — ansible-managed marking)
- **Affected code:**
  - `elixir/serviceradar_core/lib/serviceradar/automation/ansible/` (new — Ash resources, AshOban workers including InventorySync / AwxCatalogSync / GitCatalogSync / Retention, AwxClient that dispatches via AgentCommandBus, EventIngestor that consumes streamed chunks and projects OCSF events)
  - `elixir/serviceradar_core/lib/serviceradar/inventory/device.ex` (modified — new attributes derived by sync; no manual mark/unmark actions)
  - `elixir/serviceradar_core/lib/serviceradar/inventory/dire/` (modified — accept `discovery_source = "awx"` records; merge with proxmox/armis/etc.)
  - `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex` (modified — new permissions)
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_command_bus.ex` (extended — new typed verbs `awx.*`)
  - `elixir/serviceradar_core/lib/serviceradar/observability/` (extended — OCSF event mapping for ansible task results)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/inventory_live/` (modified — multi-select + Run Task button)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/device_actions_modal.ex` (new — extensible action registry, only Run Playbook enabled in v1)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/show.ex` (modified — Run Task action shortcut, runs panel)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/ansible_live/` (new — runs index, run detail with per-device-target table, settings pages)
  - `go/cmd/wasm-plugins/awx/` (new — WASM plugin with `run_check` for per-call REST and `stream_awx_events` for the job event tail; built with `serviceradar-sdk-go`)
  - `go/pkg/agent/` (extended — register the `awx_events` chunk source so streamed chunks route to Elixir)
  - `elixir/serviceradar_core/lib/serviceradar/srql/` (modified — new resource aliases)
  - `helm/serviceradar/values.yaml` and `docker-compose.yml` (modified — retention knobs and feature gate)
- **Affected infra:**
  - New NATS subjects: `serviceradar.ansible.run.{started,task,completed,failed}`
  - New DB tables (Ash codegen): `ansible_controllers`, `playbook_repositories`, `playbooks`, `playbook_runs`, `playbook_plays`, `playbook_tasks`, `playbook_task_results`, `playbook_host_stats`
  - New Helm values: `ansible.enabled`, `ansible.workers.replicas`
- **Operator impact:**
  - Operators must run AWX/AAP somewhere reachable by ServiceRadar (k8s, Docker, or VM — operator's choice).
  - Operators must pre-create AWX projects + job templates that ServiceRadar will reference. ServiceRadar does not manage AWX configuration in v1.
