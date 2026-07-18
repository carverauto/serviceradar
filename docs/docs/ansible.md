---
title: Ansible Integration
---

# Ansible Integration

ServiceRadar drives Ansible playbook execution against devices in its inventory by talking to a customer-side AWX/AAP controller, and surfaces every run as a first-class resource with live status, per-host outcomes, full audit, and the same OCSF-based universal-log-viewer search as the rest of the platform. It is the supported alternative to running ARA next to a stand-alone AWX deployment.

This guide covers:

- [Architecture](#architecture)
- [Deployment](#deployment)
- [Operator guide](#operator-guide) — registering controllers, repositories, and schedules
- [User guide](#user-guide) — launching playbooks and watching runs
- [Configuration reference](#configuration-reference) — env vars + per-resource overrides
- [RBAC reference](#rbac-reference) — the eight `ansible.*` permission keys
- [Troubleshooting](#troubleshooting)
- [v1 limitations](#v1-limitations)

## Architecture

```
ServiceRadar core (SaaS / control plane)
        │
        │ AgentCommandBus.dispatch/4
        ▼
ServiceRadar agent-gateway
        │
        │ ControlStream (gRPC)
        ▼
ServiceRadar agent  (runs inside the customer's network)
        │
        │ invokes WASM plugin
        ▼
awx WASM plugin
        │
        │ HTTPS REST + per-call credential broker grant
        ▼
AWX / AAP controller  (in the customer's network)
```

AWX usually lives in the customer's private network. ServiceRadar core cannot reach it directly; the agent can. So every AWX REST call traverses the chain above — `core → agent-gateway → agent → awx WASM plugin → AWX`. The plugin is the network bridge; orchestration and persistence stay in Elixir.

**Two execution patterns** in the plugin:

| Entrypoint | Mode | Purpose |
|---|---|---|
| `run_check` | On-demand via `CommandRequest` | Every AWX REST verb: `awx.ping`, `awx.list_*`, `awx.fetch_template`, `awx.launch_job`, `awx.fetch_job`, `awx.cancel_job`, `awx.fetch_events_for_jobs` |
| `inventory_sync` | Scheduled assignment | Walks AWX inventories and emits a `DeviceDiscovery` aggregate via the same pipeline `proxmox-inventory` uses — DIRE merges the records and flips `Device.ansible_managed = true` |

**Pulse-based event ingestion.** ServiceRadar does not maintain a long-lived stream to AWX. Each registered controller has a `RunPulseWorker` Oban job that ticks every `run_pulse_interval_ms` (default 2000) and dispatches a single `awx.fetch_events_for_jobs` command covering every non-terminal `PlaybookRun`'s `(awx_job_id, last_event_id)` watermark. The plugin makes one HTTP call per active job and returns aggregated events; `EventIngestor` persists them, drives the run state machine, and projects each result into an OCSF Application Activity event for the universal log viewer.

**Two playbook sources**, both surfaced as `Playbook` rows with a `source_type` discriminator:

- `:git` — registered git repositories; cloned + parsed by `GitCatalogSyncWorker`. Operators bind each git-sourced playbook to an AWX job template before it becomes launchable.
- `:awx` — AWX Job Templates auto-mirrored by `AwxCatalogSyncWorker`. Launchable by definition.

A single playbook can appear via both sources; both source types coexist in the catalog UI.

## Deployment

### Prerequisites

- An AWX or AAP instance reachable from at least one ServiceRadar agent.
- Purpose-scoped AWX OAuth2 tokens: a read-only sync principal and an execution principal limited to the exact inventories, templates, and machine credentials ServiceRadar may use. Callback-enabled playbooks additionally need the reviewed callback credential lifecycle described below.
- A ServiceRadar agent registered to the gateway and reachable from the AWX network (typical: same Kubernetes cluster, same VPC, same VLAN).

### Apply the schema migration

The Ansible tables are added via a single named Ash migration. From a freshly checked out copy with the runtime running against your target database:

```bash
cd elixir/serviceradar_core
mix ash.codegen add_ansible_integration   # generates the migration
mix ash.migrate                           # applies it
```

Verify with:

```sql
SELECT table_name FROM information_schema.tables
 WHERE table_schema = 'platform' AND table_name LIKE 'ansible_%'
 ORDER BY table_name;
```

You should see 14 tables (resources + their AshPaperTrail `_versions` mirrors for the four audited resources): controllers, playbook_repositories, playbooks, playbook_runs (+ run_targets / plays / tasks / task_results / contents), and playbook_schedules.

### Deploy the `awx` WASM plugin

The AWX integration runs as a WASM plugin that exposes two manifests:

- An on-demand `run_check` entrypoint for AWX REST verbs.
- A scheduled `inventory_sync` entrypoint that emits `DeviceDiscovery` records.

ServiceRadar ships the `awx` plugin as a signed, ready-to-import package. Import
it through ServiceRadar's plugin staging flow — the platform requires Rekor /
cosign verification for plugin imports; see the [WASM Plugins](./wasm-plugins.md)
guide for the publishing flow. Then assign both plugin manifests to the agent(s)
that reach your AWX network. The `inventory_sync` assignment is what drives the
`Device.ansible_managed` flag — without it, no devices flip to ansible-managed.

If you are authoring or customizing WASM plugins, see the developer portal at
[developer.serviceradar.cloud](https://developer.serviceradar.cloud) for the
plugin SDK, build toolchain, and publishing workflow.

### Configure environment variables

ServiceRadar exposes the operator-tunable knobs as env vars surfaced in both `docker-compose.yml` and `helm/serviceradar/values.yaml`. The defaults are conservative; tune only when needed.

| Env var | Default | What it does |
|---|---|---|
| `ANSIBLE_RETENTION_RUN_DETAIL_DAYS` | `90` | Prune `PlaybookPlay` / `PlaybookTask` / `PlaybookTaskResult` past this age. `0` disables detail pruning. |
| `ANSIBLE_RETENTION_RUN_SUMMARY_DAYS` | _(empty)_ | When set, delete the entire `PlaybookRun` (cascades to targets / plays / tasks / results) past this age. Empty = keep forever. |
| `ANSIBLE_RETENTION_INTERVAL_SECONDS` | `86400` | How often `RetentionWorker` scans. |
| `AWX_CONTROLLER_HEALTH_INTERVAL_SECONDS` | `30` | `ControllerHealthWorker` cadence (one `awx.ping` per registered controller). |
| `AWX_RUN_WATCHDOG_INTERVAL_SECONDS` | `60` | `RunWatchdog` interval — flags stuck non-terminal runs (past 2× job_template timeout, or 1 h fallback). |
| `AWX_SCHEDULE_EVALUATOR_INTERVAL_SECONDS` | `60` | `ScheduleEvaluatorWorker` cron evaluation cadence. |
| `ANSIBLE_CATALOG_BASE_DIR` | `/var/lib/serviceradar/ansible_catalog` (helm) / `<tmp>` (compose) | Base directory for `GitCatalogSyncWorker` repo clones. Mount a PVC at this path in Kubernetes to keep the cache warm across pod restarts. |

In Helm, these live under `core.ansible.*`:

```yaml
core:
  ansible:
    runDetailDays: 90
    runSummaryDays: ""           # keep forever
    retentionIntervalSeconds: 86400
    controllerHealthIntervalSeconds: 30
    runWatchdogIntervalSeconds: 60
    scheduleEvaluatorIntervalSeconds: 60
    catalogBaseDir: "/var/lib/serviceradar/ansible_catalog"
```

The current effective values are surfaced at runtime in `Settings → Ansible → Retention`.

## Operator guide

> Permissions: this guide assumes `ansible.controllers.manage` + `ansible.repositories.manage` + `ansible.schedules.manage`. Admins have these by default; see [RBAC reference](#rbac-reference) for the full set.

### 1. Store purpose-scoped AWX API tokens in the credential broker

The Ansible integration never passes a plaintext AWX token to a playbook. Each AWX REST command carries a short-lived credential-broker grant referencing the one stored secret selected for that command's purpose, and the selected edge agent resolves it only at the AWX HTTP boundary.

In the ServiceRadar web UI, go to **Settings → Credentials** and create:

1. A sync credential (for example `awx-prod-sync`) for an AWX principal with OAuth `read` and only the organization/inventory/project/template read roles needed for health, catalog, and inventory discovery.
2. An execution credential (for example `awx-prod-exec`) for a non-superuser AWX principal with only the exact AWX resource reads needed by live launch preflight (the reviewed template, survey, **project `Read`**, inventory, selected hosts, credentials, and execution environment), plus OAuth `write`, exact inventory `Use`, template `Execute`, machine-credential `Use`, and job lifecycle read/cancel roles. Template `Execute` alone does **not** grant `GET /api/v2/projects/<id>/`; without explicit project `Read`, live preflight fails closed on project revision drift checks. It does not need Project Admin, Inventory Admin, Job Template Admin, Ad Hoc, or organization-wide Credential Admin.
3. For callback-enabled playbooks, a callback credential. The currently supported least-privilege deployment deliberately reuses the execution credential and grants that principal Credential Admin only in a dedicated empty AWX organization such as `ServiceRadar Ephemeral`. Configure the reviewed callback credential organization ID to that empty organization. Never grant the principal Credential Admin in an organization that contains operator or machine credentials.

Save each credential. You will select the references when registering the controller. ServiceRadar supports distinct execution and callback references, but a deployment using distinct AWX users must first prove that the execution principal has `Use` on each dynamically created callback credential; selecting a different secret does not add or bypass AWX permissions.

> The credential broker, not a playbook, handles AWX token plaintext. SSH keys, become passwords, and vault passwords stay in AWX's credential vault. Controller tokens are encrypted at rest and are never supplied as survey values, `extra_vars`, inventory variables, or managed-host files.

Each short-lived controller-token grant is also pinned to the normalized AWX origin's one host and effective port plus the exact method and endpoint(s) required by that verb. ServiceRadar has no catch-all `/api/v2/` grant. Invalid controller URLs or verb arguments fail before a grant is issued or a command is dispatched, and the edge HTTP boundary never follows a redirect while carrying an AWX bearer.

### 2. Register an AWX controller

Navigate to **Settings → Ansible → Controllers** and click **+ Add controller**. Fill in:

| Field | Notes |
|---|---|
| Name | Operator-facing label, unique. Used in run logs, OCSF events, audit trails. |
| Agent ID | The ServiceRadar agent that reaches this AWX. Must have both plugin assignments. |
| Description | Optional. |
| Base URL | `https://awx.internal.example.com` — must include scheme. |
| Sync credential | Required. Used only by `awx.ping`, catalog/list/fetch reads, and scheduled inventory discovery. A pasted token on this form creates a sync-only encrypted secret. |
| Execution credential | Required before launching or observing jobs. Used only for launch, job/event/host-summary reads, recent-job reconciliation, cancellation, and the strict review-time lookup that pins this execution principal's numeric AWX user ID. That lookup is limited to `GET /api/v2/me/`. There is no fallback to the sync credential. |
| Callback credential lifecycle | Required only for callback-enabled playbooks. Used only to create/fetch/delete the reviewed ephemeral custom credential. It may explicitly select the execution secret; there is no automatic fallback. |
| Inventory sync (s) | Plugin-side cadence for `inventory_sync`. Default 300. |
| Catalog sync (s) | `AwxCatalogSyncWorker` cadence (mirrors AWX templates as `:awx`-sourced playbooks). Default 600. |
| Run pulse (ms) | `RunPulseWorker` cadence — lower for snappier UI, higher for lower AWX API load. Default 2000. |

Save. Within `AWX_CONTROLLER_HEALTH_INTERVAL_SECONDS` (default 30), `ControllerHealthWorker` dispatches `awx.ping` → plugin → AWX → `EventIngestor` writes `last_health_at` + flips status to `:ok`. Refresh the row.

When upgrading a controller created before the purpose split, the migration copies its legacy secret reference into all three purpose fields. This preserves exactly the access the controller already had; it does not grant any new AWX role. Rotate the three fields to the least-privilege principals above, verify two sync cycles plus one exact canary run and callback cleanup, wait for in-flight commands and the five-minute broker-grant TTL, then revoke the legacy AWX token. During the one-release rolling-upgrade window, a row written by an old ServiceRadar pod may use the deprecated legacy field for sync only. Execution and callback never fall back to it.

If the status stays `:unknown` past two health intervals, see [Troubleshooting](#troubleshooting).

### 2a. Live AWX preflight and callback enablement runbook

ServiceRadar treats the reviewed AWX binding as a security boundary. A mutable
launch must first obtain a redacted live preflight through the controller's
assigned edge agent, compare it with the approved binding, then persist only
the resulting identifiers and digests before `awx.launch_job` is allowed.

Use this procedure for a new controller, an AWX change, or a callback rollout:

1. Keep `automationCallbacks.enabled: false`. Confirm the controller is healthy
   and the on-demand `awx` plugin (not only `awx-inventory-sync`) is assigned to
   its selected edge agent.
2. Give the ServiceRadar runner machine principal only the resource reads and
   `Use`/`Execute` roles listed above. Explicitly grant **project `Read`** on
   each reviewed project (demo canary: project `serviceradar-ansible-canary`).
   Verify with the runner principal: template/survey/inventory/host/credential
   GET succeed, project GET succeeds, template PATCH is denied. Prefer denying
   direct `POST .../launch/` outside ServiceRadar where AWX policy allows; if
   template Execute remains required for `awx.launch_job`, keep operator AWX
   UI access off that principal. If callbacks are required, grant Credential
   Admin only in a dedicated empty callback organization such as
   `ServiceRadar Ephemeral`; never in an organization that contains production
   credentials. Operators must launch through ServiceRadar so its RBAC,
   preflight evidence, and audit trail cannot be bypassed.
3. Create or renew the approved binding through the binding-review workflow with
   a complete secret-free reviewed launch snapshot. A legacy digest-only binding
   is intentionally non-launchable. Do not patch a reviewed binding in place.
4. If ServiceRadar reports template/project, credential, execution-environment,
   survey, prompt, or target-membership drift, leave the binding blocked. Review
   the AWX change, then create a new binding version with a fresh canonical
   snapshot and approval. Never accept the live values automatically.
5. Run one narrowly scoped, ServiceRadar-initiated canary against a reviewed
   non-production target. Confirm it creates one read-only preflight command,
   retains redacted preflight evidence and the immutable launch snapshot, and
   dispatches exactly one matching AWX job. Repeat the canary for the callback
   path only after the non-callback preflight canary succeeds.
6. Only then enable `automationCallbacks.enabled` in the intended Helm overlay
   and deploy it through the normal reviewed release path. To roll back, set it
   to `false` and redeploy/sync the overlay; this removes callback issuance
   without deleting the immutable evidence needed for investigation.

The brief interval between a live AWX read and AWX launch cannot be made
cross-system atomic. The runner's least-privilege role, immediate launch after
preflight, and the no-direct-launch restriction are therefore required parts of
the control, not optional hardening.

### 3. Register a git playbook repository (optional)

Navigate to **Settings → Ansible → Repositories** and click **+ Add repository**. Fill in:

| Field | Notes |
|---|---|
| Name | Unique. |
| Ref | Branch or tag. Default `main`. |
| Description | Optional. |
| Git URL | HTTPS only. SSH is a v2 feature. |
| Deploy token secret ID | Optional. Public repos: leave blank. Private repos: create a NetworkCredentialSecret with the HTTPS deploy token (same shape as the AWX API secret) and paste the UUID here. |
| Sync interval (s) | `GitCatalogSyncWorker` cadence. Min 60s; default 600s. |

Save. `GitCatalogSyncWorker` clones the repo to `$ANSIBLE_CATALOG_BASE_DIR/<repository_id>/`, walks `.yml` / `.yaml` files, parses each as an Ansible playbook (the first play's metadata becomes the row), and upserts one `Playbook` row per file with `source_type: :git`.

Per-file YAML parse failures are surfaced inline rather than dropped — the row shows up with `parse_status: :error` and a diagnostic on the catalog page, so operators can spot broken playbooks instead of wondering why they're missing.

> **Bind git-sourced playbooks to an AWX template before launching.** Git-sourced rows show up in `/ansible/catalog` with an `unbound` warning badge until an `awx_job_template_id` is set. Operators are expected to keep the AWX project + job_template configured to match; ServiceRadar does not auto-create AWX templates from git playbooks in v1.

### 4. Watch inventory flow in automatically

If the `inventory_sync` plugin assignment is wired up on the controller's agent, within `inventory_sync_interval_seconds` you should see devices in your inventory flipping to `ansible_managed: true` with `ansible_inventory_ref` populated. This is driven by:

1. Plugin runs on schedule.
2. Plugin calls AWX inventory API.
3. Plugin emits a `DeviceDiscovery` aggregate (`source: "awx"`) via `result.WithDeviceDiscovery(...)`.
4. Agent → gateway → DIRE merges the records with existing devices (matching on `ansible_host` IP, hostname, or AWX host `name` in priority order).
5. Matched devices get `ansible_managed = true`; AWX hosts that DIRE cannot match surface in **Settings → Ansible → Controllers** as a "needs review" list (v2 feature; currently they're emitted but not yet rendered).

No manual "mark Ansible-managed" toggle exists — the state is fully derived.

### 5. Create a scheduled run (optional)

Navigate to **Settings → Ansible → Schedules** and click **+ Add schedule**. Fill in:

| Field | Notes |
|---|---|
| Name | Unique. |
| Enabled | Default on. |
| Playbook | Dropdown filtered to launchable playbooks (anything with `awx_job_template_id`). |
| Target device UIDs | Comma-separated OCSF UIDs (e.g. `sr:abc,sr:def`). All must share one controller. (v2: proper multi-select picker.) |
| Cron | Standard 5-field expression — e.g. `0 3 * * *` for daily at 03:00. |
| Timezone | `UTC` / `Etc/UTC` only in v1. (`:tzdata` is not currently a dependency.) |
| Allow concurrent runs | Default off — when the previous run is still non-terminal, the next fire is recorded as `:skipped_overlap`. |
| extra_vars (JSON) | Passed to AWX on each fire. |

`ScheduleEvaluatorWorker` fires every minute by default (configurable via `AWX_SCHEDULE_EVALUATOR_INTERVAL_SECONDS`); each due schedule produces a `PlaybookRun` exactly as if a human had launched it from the UI.

### 6. Retention

Navigate to **Settings → Ansible → Retention** for a read-only view of the effective retention windows + worker cadences. Changes are env-var driven; redeploy after editing `values.yaml` / `docker-compose.yml`.

## User guide

> Permissions: this section requires `ansible.runs.launch`. The Run Task button is hidden for users without it. To view runs only, `ansible.runs.view` is enough.

### Browse the catalog

`/ansible/catalog` shows every Playbook ServiceRadar has discovered, both `:git`- and `:awx`-sourced. Filter by:

- Source (all / git / awx)
- Binding (all / launchable / unbound)
- Free-text on name + description

Bound rows show a green badge with the AWX job template id; unbound rows show a warning badge — those aren't launchable until an `awx_job_template_id` is set on the row.

### Launch against multiple devices

1. Visit `/devices`.
2. Tick the checkbox on each ansible-managed device you want to target. Non-managed devices have the checkbox available but the Run Task button validates them on submit.
3. Click **+ Run Task** in the bulk-action toolbar (top-right of the inventory table, next to Bulk Edit / Bulk Delete).
4. ServiceRadar navigates to `/ansible/launch?devices=...` pre-filled with your selection.

The Launch page validates the targets:

- All devices must be `ansible_managed`.
- All devices must point at the same AWX controller. Mixed-controller selections are rejected with a clear error.

### Launch against a single device

On a device detail page, the **Run Task** action button appears in the page header (next to Edit / Delete / Console) if all of: you have `ansible.runs.launch`, the device is not soft-deleted, AND the device is `ansible_managed`.

Clicking it goes to `/ansible/launch?devices=<uid>` with the single device pre-filled.

### The launch form

1. **Targets**: read-only summary of selected devices with an ansible-managed badge per row.
2. **Playbook**: dropdown of launchable playbooks; for each pick, the variable form below re-renders with typed inputs derived from the playbook's variable schema:
   - **AWX-sourced** playbooks use the survey_spec (`text` / `textarea` / `password` / `integer` / `float` / `multiplechoice` / `multiselect`).
   - **git-sourced** playbooks use `vars_prompt` (`text`, plus `password` when `private: true`).
   Defaults are pre-filled; required fields are marked.
3. **Override extra_vars as raw JSON** (checkbox). When toggled on, a textarea appears whose contents merge over the typed inputs at submit. Use this for variables not declared in the playbook's schema.
4. **Launch** — submits; on success, you're redirected to `/ansible/runs/:id`.

### Watch a run

`/ansible/runs/:id` subscribes to a per-run PubSub topic and live-updates as `RunPulseWorker` drains events from AWX. You'll see:

- **Header card**: state pill (pending / launching / running / succeeded / partial / failed / unreachable / canceled), AWX job id, scheduled-vs-ad-hoc badge, timestamps, duration.
- **Targets table**: per-host status with ok / changed / failed / skipped / unreachable counts.
- **Plays accordion**: per-play status + task count; click to expand and see individual tasks.

The state machine is enforced: a terminal run (`succeeded`, `partial`, `failed`, `unreachable`, `canceled`) never transitions further. Late events arriving from AWX after a terminal transition are still persisted to the task table for completeness but don't move the state.

### Listing runs

`/ansible/runs` is the cross-controller index, filterable by state (all / pending / launching / running / succeeded / partial / failed / unreachable / canceled). The "Refresh" button reloads with the current filter; PubSub also live-inserts rows that match the active filter as their state changes.

### Cron-driven runs

Schedules registered in **Settings → Ansible → Schedules** fire automatically. Each fire produces a regular `PlaybookRun` with `schedule_id` set — visible in both `/ansible/runs` (with a "scheduled" badge) and on the schedule's row in the settings tab (last fire + outcome badge).

### Universal log viewer

Every state transition + every task result also produces an OCSF Application Activity (class 6003) event in the universal log viewer. Each event carries an `unmapped.ansible` block with `run_id`, `playbook_id`, `controller_id`, `awx_job_id`, `task_name`, `awx_host_name`, `device_uid`, etc., so you can search:

- by run id to see one run's full event stream
- by device uid to see every ansible activity that touched a host
- by task name across all runs ever
- by status to filter for failures globally

This is the supported replacement for ARA's UI for cross-run search — ServiceRadar's structured per-run pages are richer than ARA for one run, and the universal log viewer is richer than ARA for cross-run aggregation.

## Configuration reference

### Per-controller overrides

Stored on each `AnsibleController` row; override the deployment-wide cadence per controller:

| Column | Default | Override |
|---|---|---|
| `inventory_sync_interval_seconds` | 300 | Plugin's `inventory_sync` assignment cadence for this controller. |
| `catalog_sync_interval_seconds` | 600 | `AwxCatalogSyncWorker` cadence for this controller. |
| `run_pulse_interval_ms` | 2000 | `RunPulseWorker` cadence — lower = snappier UI, higher = lower AWX API load. |

Editable in the Controllers tab.

### Per-repository overrides

| Column | Default | Override |
|---|---|---|
| `sync_interval_seconds` | 600 | `GitCatalogSyncWorker` cadence for this repo. Min 60s. |

### Per-schedule overrides

| Column | Default | Override |
|---|---|---|
| `cron` | required | Standard 5-field cron expression. |
| `timezone` | `UTC` | UTC / Etc/UTC only in v1. |
| `allow_concurrent` | `false` | When true, fire even if the previous run is still non-terminal. |

## RBAC reference

The eight ansible permission keys, with the default role assignments:

| Key | Default roles | What it grants |
|---|---|---|
| `ansible.controllers.manage` | `admin` | Register / edit / delete `AnsibleController`. Required to reach the Controllers tab. |
| `ansible.repositories.manage` | `admin` | Register / edit / delete `PlaybookRepository`. Required to reach the Repositories tab. |
| `ansible.catalog.view` | `all` (viewer / helpdesk / operator / admin) | Browse `/ansible/catalog`. |
| `ansible.runs.view` | `all` | View `/ansible/runs` and `/ansible/runs/:id`. |
| `ansible.runs.launch` | `operator` / `admin` | Launch playbooks; the Run Task button is hidden without this. |
| `ansible.runs.cancel` | `operator` / `admin` | Cancel an in-progress run. |
| `ansible.schedules.view` | `all` | View existing schedules. |
| `ansible.schedules.manage` | `operator` / `admin` | Register / edit / enable / disable / delete schedules. |

These map to Ash resources via `ServiceRadarWebNGWeb.Authorization.Permissions`. Per-event Permit gates in each LiveView enforce the right verb on the right resource.

## Troubleshooting

### Controller status stays `:unknown` past two health intervals

Probable causes, in order of likelihood:

1. **Plugin not assigned**. Confirm both `awx` plugin manifests are assigned to the controller's `agent_id` via `/settings/plugins` (or `iex` → `ServiceRadar.Plugins`). Without the `run_check` entrypoint assigned the agent can't even respond to `awx.ping`.
2. **Agent offline**. Check the agent's connection state. The launcher (`RunLauncher.launch/2`) explicitly fails launches with a typed error when the agent isn't connected; controller health calls fail silently. Look for `[error] AWX ControllerHealthWorker: dispatch failed` in the core-elx logs.
3. **Agent can't reach AWX**. From inside the agent's network namespace, test the exact controller origin with its trusted CA: `curl --cacert /path/to/awx-ca.pem https://<base_url>/api/v2/ping/`. Do not put an AWX bearer on a shell command line or use `-k`; use a credential-safe diagnostic or the ServiceRadar controller health action for authenticated checks.
4. **TLS verification**. The default is to verify. For an AWX certificate issued by a private CA, mount the public PEM bundle on the selected edge agent and add its absolute path to `plugin_http_trusted_ca_files` in `agent.json`. Helm deployments use `agent.pluginHTTPTrustedCAFiles` and trust the ServiceRadar runtime CA in addition to operating-system roots by default. The host-owned transport loads these roots before starting Wasm, never exposes them to the module, and disables outbound plug-in HTTP if a configured path is unreadable, oversized, or contains no certificate. Restart the agent after changing the trust bundle. Do not use `metadata.insecure_skip_verify` for credential-bearing production traffic.

### Status flips to `:unauthorized`

The token is wrong, expired, or missing scope. Check `Controller.last_health_summary` — it'll surface the operator-safe 401 message from the plugin. Update the NetworkCredentialSecret's `secret_payload` and re-trigger health by editing any field on the controller (re-save trips the health check).

### No playbooks appear in `/ansible/catalog`

- **AWX-sourced**: `AwxCatalogSyncWorker` ticks every 600s by default. The first sync after registering a controller can take that long. Lower `catalog_sync_interval_seconds` on the controller if you want faster turnaround for setup.
- **Git-sourced**: `GitCatalogSyncWorker` ticks every 600s by default. Confirm the agent / pod has filesystem write access to `ANSIBLE_CATALOG_BASE_DIR`. Look for `[warning] AWX GitCatalogSyncWorker: git sync failed` in logs — the `PlaybookRepository.last_sync_summary` field surfaces the sanitized error.

### Devices don't flip to `ansible_managed: true`

- Confirm the `inventory_sync` plugin manifest is assigned (separate from the on-demand manifest).
- Confirm the agent can reach AWX (same constraint as health).
- Check `DiscoveryRecord` ingestion in DIRE — the AWX hosts may be matching but onto different devices (hostname collision). Look for `awx` in the device's `discovery_sources` set.
- Hosts AWX has that DIRE can't match are emitted but not yet surfaced; check the agent logs for `inventory_sync` discovery records.

### Run stuck in `:pending`

The launch command never returned a result from AWX. Likely causes:

1. Agent disconnected after dispatch. `RunPulseWorker` doesn't auto-retry launches; the run will eventually be picked up by `RunWatchdog` (~hourly fallback) and transitioned to `:unreachable`.
2. AWX rejected the launch payload. Check `[info] Ansible launch failed` in logs and the user's flash message at launch time.
3. The launch's `awx.launch_job` command result was lost. Check `platform.agent_commands` for the command_id of the run's last dispatch — its `status` and `failure_reason` columns will tell you.

### Run stuck in `:running` past terminal

`RunWatchdog` transitions any non-terminal run past `2 × job_template.timeout` (or 1 h fallback) to `:unreachable` with a diagnostic recording the watchdog reason. If you want a tighter watchdog, set a `job_template_timeout_seconds` on the run's metadata at launch time (currently `iex`-only).

### "AWX rejected the request" 401 / 403 on launch

The plugin surfaces these as operator-safe typed errors with `"check controller token"` in the message. Either:

- The execution token expired — rotate its NetworkCredentialSecret.
- The execution principal lacks exact inventory `Use`, template `Execute`, machine-credential `Use`, or generated callback-credential `Use`. Add only the missing object role; do not replace it with an admin/superuser token.
- Callback credential creation/deletion failed because its principal lacks Credential Admin in the dedicated empty callback organization, or because the configured organization ID names another organization. Do not solve this by granting Credential Admin in the organization that holds production credentials.

### Schedule not firing

- Check the row in the Schedules tab — the `last_evaluation_outcome` badge tells you what happened on the last tick (`fired`, `skipped_overlap`, `skipped_disabled`, `skipped_ineligible_targets`, `error`).
- Confirm the schedule is enabled (toggle in the action column).
- Confirm `next_run_at` is populated and in the past. If it's `nil`, the cron expression failed to parse — the form validates client-side via `Oban.Cron.Expression.parse/1` but legacy rows might predate validation; edit and re-save.
- Non-UTC timezones return `:timezone_database_unavailable` and the schedule never fires. Stick to UTC / Etc/UTC until `:tzdata` is added.

### Per-run RBAC questions

If a user has `ansible.runs.launch` but launches fail with a 403:

- They may not have `ansible.runs.view`. The LaunchLive page itself only checks `runs.launch`, but the post-launch redirect to `/ansible/runs/:id` requires `runs.view`.
- The Permit per-event gates enforce verbs on specific resources; check `ServiceRadarWebNGWeb.Authorization.Permissions` for the mapping if a permission seems to not be honored.

## v1 limitations

These are documented constraints, not bugs. Each is tracked for a future v2:

- **AWX-sourced execution only.** Direct `ansible-playbook` execution by a ServiceRadar agent is reserved for a follow-up; v1 requires an AWX/AAP controller. Workflows that orbit AWX (its credential vault, its inventory plugins, its executor pool) are the supported path.
- **UTC schedules only.** Non-UTC timezones need the `:tzdata` Elixir dependency, which isn't currently bundled.
- **Public HTTPS git repos.** The `GitCatalogSyncWorker` supports HTTPS deploy tokens via the credential broker but not SSH keys yet.
- **Schedules require AWX-sourced playbooks.** Git-sourced playbooks can be launched ad-hoc once bound to an AWX template, but the schedule worker rejects them in v1 with `:git_sourced_not_supported_v1`.
- **Multi-device UI launches require a single controller.** AWX uses `limit:` to scope to specific hosts; mixed-controller selections are rejected at submit time. Multi-controller fan-out is a v2 design question.
- **Webhook ingestion is deferred.** An agent-side receiver that would augment pulse polling for lower-latency state-transition updates from very large AWX deployments is planned for a future release. Pulse polling is the only ingestion path in v1.
- **OCSF class selection.** Events project as Application Activity (6003). If operator search habits favor Process Activity (1007) instead, the mapping module can be swapped without touching the data model.
- **Run retention exclusion window.** Retention sweeps do not yet skip runs accessed within the last hour — the worker does not check `accessed_at` (the column hasn't been added). Set generous `ANSIBLE_RETENTION_RUN_DETAIL_DAYS` if you frequently revisit old runs.
- **Manual UUID paste for credential secret references.** Both controller and repository forms expect operators to paste a UUID from `Settings → Credentials`. A picker UX is a planned v2 improvement.
