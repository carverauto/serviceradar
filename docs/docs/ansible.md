---
title: Ansible Integration
---

# Ansible Integration

ServiceRadar drives Ansible playbook execution against devices in its inventory by talking to a customer-side AWX/AAP controller, and surfaces every hardened launch as a canonical operation with lifecycle status plus immutable target, authority, controller, and dispatch evidence. It is the supported alternative to running ARA next to a stand-alone AWX deployment.

This guide covers:

- [Architecture](#architecture)
- [Deployment](#deployment)
- [Operator guide](#operator-guide) — registering controllers and repositories
- [User guide](#user-guide) — launching playbooks and inspecting operations
- [Configuration reference](#configuration-reference) — env vars + per-resource overrides
- [RBAC reference](#rbac-reference) — the ten `ansible.*` permission keys
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
| `run_check` | On-demand via `CommandRequest` | AWX health, catalog, launch, status, and cancellation verbs |
| `inventory_sync` | Scheduled assignment | Walks AWX inventories and emits a `DeviceDiscovery` aggregate via the same pipeline `proxmox-inventory` uses — DIRE merges the records and flips `Device.ansible_managed = true` |

**Two playbook sources**, both surfaced as `Playbook` rows with a `source_type` discriminator:

- `:git` — registered git repositories; cloned + parsed by `GitCatalogSyncWorker` for catalog discovery and review. Git-sourced rows are not selectable in the hardened launch UI.
- `:awx` — AWX Job Templates auto-mirrored by `AwxCatalogSyncWorker`. A parse-valid row is eligible for hardened launch only when its current template binding is approved and passes live preflight.

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

The result should include the Ansible controller, repository, catalog, operation,
execution, target, approval, and version-history tables.

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
| `AWX_CONTROLLER_HEALTH_INTERVAL_SECONDS` | `30` | `ControllerHealthWorker` cadence (one `awx.ping` per registered controller). |
| `ANSIBLE_CATALOG_BASE_DIR` | `/var/lib/serviceradar/ansible_catalog` (Helm and Compose) | Base directory for `GitCatalogSyncWorker` repo clones. The Helm chart mounts a writable `emptyDir` here; clones are recreated after pod replacement, while catalog metadata remains in CNPG. |

Core images include Git for catalog synchronization. The Helm chart also mounts
a writable `/tmp` for Git and other temporary files.

Set `ANSIBLE_CATALOG_BASE_DIR` to a non-empty path writable by core. It populates
the `:serviceradar_core` application setting `:ansible_catalog_base_dir`; a
configured cache bypasses system temporary-directory lookup during sync. Without
that setting, the worker uses `System.tmp_dir!()/serviceradar_ansible_catalog`
and still requires a writable system temporary directory. Runtime configuration
also resolves that fallback when the environment variable is absent, so set the
variable before startup in environments without writable temporary storage.

In Helm, these live under `core.ansible.*`:

```yaml
core:
  ansible:
    controllerHealthIntervalSeconds: 30
    catalogBaseDir: "/var/lib/serviceradar/ansible_catalog"
```

## Operator guide

> Permissions: this guide assumes `ansible.controllers.manage` + `ansible.repositories.manage`. Admins have these by default; see [RBAC reference](#rbac-reference) for the full set.

### 1. Store purpose-scoped AWX API tokens in the credential broker

The Ansible integration never passes a plaintext AWX token to a playbook. Each AWX REST command carries a short-lived credential-broker grant referencing the one stored secret selected for that command's purpose, and the selected edge agent resolves it only at the AWX HTTP boundary.

AWX is a **credential-only** provider: its descriptor sets `supports_rules: false`,
so an AWX token is a credential bound to an Ansible Controller record, not a
credential rule. AWX will not appear in the **New Rule** dropdown, and the AWX
bridge does not read one. See
[Credential Management](./credentials.md) for the general model.

In the ServiceRadar web UI, go to **Settings -> Networks -> Credential Rules**
(`/settings/networks/credentials`), click **New Credential**, pick
`AWX / AAP - API token`, and create:

1. A sync credential (for example `awx-prod-sync`) for an AWX principal with OAuth `read` and only the organization/inventory/project/template read roles needed for health, catalog, and inventory discovery.
2. An execution credential (for example `awx-prod-exec`) for a non-superuser AWX principal with only the exact AWX resource reads needed by live launch preflight (the reviewed template, survey, **project `Read`**, inventory, selected hosts, credentials, and execution environment), plus OAuth `write`, exact inventory `Use`, template `Execute`, machine-credential `Use`, and job lifecycle read/cancel roles. Template `Execute` alone does **not** grant `GET /api/v2/projects/<id>/`; without explicit project `Read`, live preflight fails closed on project revision drift checks. It does not need Project Admin, Inventory Admin, Job Template Admin, Ad Hoc, or organization-wide Credential Admin.
3. For callback-enabled playbooks, a callback credential. The currently supported least-privilege deployment deliberately reuses the execution credential and grants that principal Credential Admin only in a dedicated empty AWX organization such as `ServiceRadar Ephemeral`. Configure the reviewed callback credential organization ID to that empty organization. Never grant the principal Credential Admin in an organization that contains operator or machine credentials.

Save each credential. You will select it by name when registering the controller. ServiceRadar supports distinct execution and callback references, but a deployment using distinct AWX users must first prove that the execution principal has `Use` on each dynamically created callback credential; selecting a different secret does not add or bypass AWX permissions.

> The credential broker, not a playbook, handles AWX token plaintext. SSH keys, become passwords, and vault passwords stay in AWX's credential vault. Controller tokens are encrypted at rest and are never supplied as playbook inputs, inventory variables, or managed-host files.

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

Save. Within `AWX_CONTROLLER_HEALTH_INTERVAL_SECONDS` (default 30), `ControllerHealthWorker` dispatches `awx.ping` → plugin → AWX → `EventIngestor` writes `last_health_at` + flips status to `:ok`. Refresh the row.

When upgrading a controller created before the purpose split, the migration copies its previous single secret reference into all three purpose fields. This preserves exactly the access the controller already had; it does not grant any new AWX role. Rotate the three fields to the least-privilege principals above, verify two sync cycles plus one exact canary run and callback cleanup, wait for in-flight commands and the five-minute broker-grant TTL, then revoke the superseded AWX token. During the one-release rolling-upgrade window, a row written by an older ServiceRadar pod may use the deprecated field for sync only. Execution and callback never fall back to it.

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
   a complete secret-free reviewed launch snapshot. A digest-only binding from
   an earlier release is intentionally non-launchable. Do not patch a reviewed
   binding in place.
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
| Deploy token secret ID | Leave blank. See the supported repository constraints in the [provisioning API](./ansible-provisioning-api.md#configuration-lifecycle). |
| Sync interval (s) | `GitCatalogSyncWorker` cadence. Min 60s; default 600s. |

Save. `GitCatalogSyncWorker` clones the repo to `$ANSIBLE_CATALOG_BASE_DIR/<repository_id>/`, walks `.yml` / `.yaml` files, parses each as an Ansible playbook (the first play's metadata becomes the row), and upserts one `Playbook` row per file with `source_type: :git`.

Per-file YAML parse failures are surfaced inline rather than dropped — the row shows up with `parse_status: :error` and a diagnostic on the catalog page, so operators can spot broken playbooks instead of wondering why they're missing.

> Git-sourced rows are catalog metadata only in the current hardened workflow. An `awx_job_template_id` stored on an older git row does not make it launchable and does not confer execution authority. Launches use AWX-sourced rows backed by a current approved template binding.

### 4. Watch inventory flow in automatically

If the `inventory_sync` plugin assignment is wired up on the controller's agent, within `inventory_sync_interval_seconds` you should see devices in your inventory flipping to `ansible_managed: true` with `ansible_inventory_ref` populated. This is driven by:

1. Plugin runs on schedule.
2. Plugin calls AWX inventory API.
3. Plugin emits a `DeviceDiscovery` aggregate (`source: "awx"`) via `result.WithDeviceDiscovery(...)`.
4. Agent → gateway → DIRE merges the records with existing devices (matching on `ansible_host` IP, hostname, or AWX host `name` in priority order).
5. Matched devices get `ansible_managed = true`; AWX hosts that DIRE cannot match surface in **Settings → Ansible → Controllers** as a "needs review" list (v2 feature; currently they're emitted but not yet rendered).

No manual "mark Ansible-managed" toggle exists — the state is fully derived.

### 5. Scheduled execution is unavailable

ServiceRadar currently supports interactive, authorized launches only. A future
scheduled-execution capability must use an immutable, expiring delegation and
record every launch as a canonical operation.

## User guide

> Permissions: **Launch Playbook** and the device Ansible launch flow require `ansible.runs.launch`. Canonical operation history requires `ansible.runs.view`. The separate provider-neutral **Run Action** control requires `northbound.actions.launch`, and its non-Ansible Action History requires `northbound.actions.view`; those northbound permissions never grant Ansible launch or history.

### Browse the catalog

`/ansible/catalog` shows every Playbook ServiceRadar has discovered, both `:git`- and `:awx`-sourced. Filter by:

- Source (all / git / awx)
- Binding (all / launchable / unbound)
- Free-text on name + description

The binding filter reflects whether a catalog row carries an AWX job-template ID; it is not an authorization decision. Only parse-valid AWX-sourced rows appear in the hardened launch picker, and selection still requires a current approved binding plus exact target-membership resolution.

### Launch against multiple devices

1. Visit `/devices`.
2. Tick the checkbox on each device you want to target. Canonical launch revalidates AWX membership and rejects ineligible targets before persistence or dispatch.
3. Click **Launch Playbook** in the bulk-action toolbar. This control is governed only by `ansible.runs.launch`; **Run Action** is a separate non-Ansible workflow governed by `northbound.actions.launch`.
4. ServiceRadar navigates to `/ansible/launch?devices=...` pre-filled with your selection.

The Launch page validates the targets:

- All devices must be `ansible_managed`.
- All devices must point at the same AWX controller. Mixed-controller selections are rejected with a clear error.

**Run Action** lists provider-neutral, non-Ansible actions only. All Ansible
execution starts through **Launch Playbook** and its reviewed typed inputs.

### Launch against a single device

On a device detail page, the Ansible panel shows **Launch Playbook** when all of the following are true: you have `ansible.runs.launch`, the device is not soft-deleted, and the device is `ansible_managed`.

Clicking it opens the launch flow with that device pre-filled. With `ansible.runs.view`, the same panel also shows recent canonical operation history, with evidence links to `/ansible/operations/:id`; launch-only operators do not receive operation-history links or content.

### The launch form

1. **Targets**: read-only summary of selected canonical devices.
2. **AWX playbook**: the picker contains only parse-valid AWX-sourced catalog rows. Selecting one resolves its current approved binding and the exact durable AWX memberships for every target.
3. **Reviewed inputs**: the form renders only typed, non-secret fields declared by the approved binding. Supported fields are text, textarea, integer, float, single choice, and multiple choice. Password fields, raw JSON/YAML, undeclared names, transport variables, and callback-control fields are never accepted from the browser.
4. **Launch**: submit re-resolves the binding, memberships, current actor authority, and live AWX preflight before persisting or dispatching. On success, you're redirected to `/ansible/operations/:id`.

### Inspect an operation

`/ansible/operations/:id` is the canonical evidence page for a launch. It shows:

- **Immutable operation evidence**: action, initiating principal, request source, mode, target digest, timestamps, and sanitized diagnostics.
- **Controller executions**: current state, controller and inventory scope, job template, project revision, content digest, execution environment, literal host limit, dispatch ID, and controller-local AWX job ID.
- **Exact target tuples**: controller, inventory, AWX host ID, durable membership, canonical device UID, membership generation, host name, address, target state, snapshot digest, and any active safety hold.
- **Scope proof**: whether the returned AWX job, inventory, limit, revision, execution environment, credentials, dispatch markers, and host IDs matched the immutable launch snapshot.

Use **Refresh** to reload the latest persisted operation, execution, and target
evidence. This page is the complete operator-facing Ansible execution record.

### List operations

`/ansible/operations` is the cross-controller operation index. It is filterable by state (all / planned / dispatching / running / succeeded / failed / canceled / dispatch partial / dispatch ambiguous / cancel failed), capped at the 100 most recent matching operations. Each row links to `/ansible/operations/:id`; **Refresh** reloads the active filter.

### Scheduled operations

Scheduled execution is not currently exposed. When a separately approved
delegated-scheduling capability is implemented, its evidence will use
`/ansible/operations`; it will not introduce another history UI.

## Configuration reference

### Per-controller overrides

Stored on each `AnsibleController` row; override the deployment-wide cadence per controller:

| Column | Default | Override |
|---|---|---|
| `inventory_sync_interval_seconds` | 300 | Plugin's `inventory_sync` assignment cadence for this controller. |
| `catalog_sync_interval_seconds` | 600 | `AwxCatalogSyncWorker` cadence for this controller. |

Editable in the Controllers tab.

### Per-repository overrides

| Column | Default | Override |
|---|---|---|
| `sync_interval_seconds` | 600 | `GitCatalogSyncWorker` cadence for this repo. Min 60s. |

## RBAC reference

The ten Ansible permission keys, with the default role assignments:

| Key | Default roles | What it grants |
|---|---|---|
| `ansible.controllers.manage` | `admin` | Register / edit / delete `AnsibleController`. Required to reach the Controllers tab. |
| `ansible.repositories.manage` | `admin` | Register / edit / delete `PlaybookRepository`. Required to reach the Repositories tab. |
| `ansible.catalog.view` | `all` (viewer / helpdesk / operator / admin) | Browse `/ansible/catalog`. |
| `ansible.runs.view` | `all` | View `/ansible/operations` and `/ansible/operations/:id`. The deployed permission key is retained for RBAC compatibility. |
| `ansible.runs.launch` | `operator` / `admin` | Show **Launch Playbook** and authorize the canonical Ansible launch flow. It does not authorize provider-neutral **Run Action**. |
| `ansible.runs.cancel` | `operator` / `admin` | Authorize cancellation services. The canonical operation pages are currently read-only. |
| `ansible.schedules.view` | `all` | Reserved key for stored schedule records; no schedule UI is exposed. |
| `ansible.schedules.manage` | `operator` / `admin` | Reserved key. It does not enable or authorize scheduled execution. |
| `ansible.delegations.manage` | `admin` | Manage immutable execution delegations for schedules or operations. This does not make retained schedules executable. |
| `ansible.targets.holds.clear` | `admin` | Reconcile and clear a device-wide Ansible mutation hold using current approval, policy, and recovery evidence. |

These keys map to Ash resources through `ServiceRadarWebNGWeb.Authorization.Permissions`. The launch route uses create authorization on canonical operations. Ansible settings refresh the current user's authority before loading data and before every controller or repository action, then enforce the permission for that exact resource.

Provider-neutral device/interface actions use separate keys: `northbound.actions.launch` for **Run Action** and `northbound.actions.view` for non-Ansible Action History. Neither key substitutes for `ansible.runs.launch` or `ansible.runs.view`, and stale Ansible northbound rows are excluded from those operator surfaces.

## Troubleshooting

### Controller status stays `:unknown` past two health intervals

Probable causes, in order of likelihood:

1. **Plugin not assigned**. Confirm both `awx` plugin manifests are assigned to the controller's `agent_id` via `/settings/plugins` (or `iex` → `ServiceRadar.Plugins`). Without the `run_check` entrypoint assigned the agent can't even respond to `awx.ping`.
2. **Agent offline**. Check the agent's connection state. The hardened launch path fails closed when it cannot establish the selected edge principal and controller path; controller health calls fail silently. Look for `[error] AWX ControllerHealthWorker: dispatch failed` in the core-elx logs.
3. **Agent can't reach AWX**. From inside the agent's network namespace, test the exact controller origin with its trusted CA: `curl --cacert /path/to/awx-ca.pem https://<base_url>/api/v2/ping/`. Do not put an AWX bearer on a shell command line or use `-k`; use a credential-safe diagnostic or the ServiceRadar controller health action for authenticated checks.
4. **TLS verification**. The default is to verify. For an AWX certificate issued by a private CA, mount the public PEM bundle on the selected edge agent and add its absolute path to `plugin_http_trusted_ca_files` in `agent.json`. Helm deployments use `agent.pluginHTTPTrustedCAFiles` and trust the ServiceRadar runtime CA in addition to operating-system roots by default. The host-owned transport loads these roots before starting Wasm, never exposes them to the module, and disables outbound plug-in HTTP if a configured path is unreadable, oversized, or contains no certificate. Restart the agent after changing the trust bundle. Do not use `metadata.insecure_skip_verify` for credential-bearing production traffic.

### `AWX configuration invalid: api_token is required (resolved from credential broker grant)`

The AWX package is a command bridge: its token arrives per dispatch, inside that
dispatch's grant. Its assignment params hold no token by design. An assignment
without the `action-only:v1` capability also gets a 60-second periodic runner,
and that scheduled run invokes `run_check` with the assignment's own params,
which can never satisfy the check.

This is not a missing credential, and the repeated failure is cosmetic: dispatched
AWX commands carry their own grant and still work. Judge controller health from
`awx.ping` and from an actual dispatch, not from this result.

:::caution Not in 1.4.46
The fix is `action-only:v1` on the AWX manifest, which stops a periodic runner
being scheduled at all. It is merged but unreleased; once it ships, republish,
register, and re-materialise the package -- an existing assignment points at the
old package version and keeps its runner. First release containing it:
`<first-release>`. See
[Credential Management](./credentials.md#awx-configuration-invalid-api_token-is-required-resolved-from-credential-broker-grant).
:::

### Status flips to `:unauthorized`

The token is wrong, expired, or missing scope. Check `Controller.last_health_summary`; it surfaces the operator-safe 401 message from the plugin. Save a new value for that credential under **Settings -> Networks -> Credential Rules** and re-trigger health by editing any field on the controller (re-save trips the health check).

### No playbooks appear in `/ansible/catalog`

- **AWX-sourced**: `AwxCatalogSyncWorker` ticks every 600s by default. The first sync after registering a controller can take that long. Lower `catalog_sync_interval_seconds` on the controller if you want faster turnaround for setup.
- **Git-sourced**: `GitCatalogSyncWorker` ticks every 600s by default. Confirm core has the Git runtime and writable storage described in [Configure environment variables](#configure-environment-variables). Look for `[warning] AWX GitCatalogSyncWorker: git sync failed` in logs — the `PlaybookRepository.last_sync_summary` field surfaces the sanitized error.

### Devices don't flip to `ansible_managed: true`

- Confirm the `inventory_sync` plugin manifest is assigned (separate from the on-demand manifest).
- Confirm the agent can reach AWX (same constraint as health).
- Check `DiscoveryRecord` ingestion in DIRE — the AWX hosts may be matching but onto different devices (hostname collision). Look for `awx` in the device's `discovery_sources` set.
- Hosts AWX has that DIRE can't match are emitted but not yet surfaced; check the agent logs for `inventory_sync` discovery records.

### Operation stuck in `:planned` or `:dispatching`

Open `/ansible/operations/:id`, refresh it, and inspect the operation and child-execution diagnostics. Common causes are:

1. The agent disconnected during preflight or dispatch.
2. AWX rejected the immutable launch payload or its live resources drifted from the reviewed binding.
3. The `awx.launch_job` command result was lost or could not be correlated. Use the execution's dispatch ID and persisted diagnostics to locate the corresponding `platform.agent_commands` row and inspect its `status` and `failure_reason`.

### Operation remains `:running` after AWX is terminal

Refresh the operation evidence and inspect each child execution's AWX job ID, scope-verification state, and diagnostics. Then inspect the correlated secure fetch/status commands in `platform.agent_commands`. Do not infer success from AWX alone: ServiceRadar keeps an execution non-terminal when it cannot prove that the returned job and hosts match the immutable scope.

### "AWX rejected the request" 401 / 403 on launch

The plugin surfaces these as operator-safe typed errors with `"check controller token"` in the message. Either:

- The execution token expired — rotate its NetworkCredentialSecret.
- The execution principal lacks exact inventory `Use`, template `Execute`, machine-credential `Use`, or generated callback-credential `Use`. Add only the missing object role; do not replace it with an admin/superuser token.
- Callback credential creation/deletion failed because its principal lacks Credential Admin in the dedicated empty callback organization, or because the configured organization ID names another organization. Do not solve this by granting Credential Admin in the organization that holds production credentials.

### Operation RBAC questions

If a user has `ansible.runs.launch` but cannot use the launch workflow or its result page:

- `ansible.runs.launch` authorizes the launch resolver's narrow reads of launchable playbooks, the current approved binding, and current target memberships; it does not grant the general catalog or operation-history pages.
- `ansible.runs.view` is not required to prepare or submit a launch, but the post-launch redirect to `/ansible/operations/:id` requires it. Grant view authority when the launcher must inspect the resulting evidence.
- The launch route and its events authorize creation of a canonical `AutomationOperation`; Ansible settings additionally refresh and enforce the exact controller or repository permission for every action. Check `ServiceRadarWebNGWeb.Authorization.Permissions` when a deployed key does not produce the expected resource authority.

## v1 limitations

These are documented constraints, not bugs. Each is tracked for a future v2:

- **AWX-sourced execution only.** The hardened launch picker accepts only AWX-sourced catalog rows with a current approved binding. Git-sourced rows remain searchable catalog metadata, even when an older row carries an AWX template ID. Direct `ansible-playbook` execution by a ServiceRadar agent is reserved for a follow-up.
- **Public HTTPS git repos.** The `GitCatalogSyncWorker` supports HTTPS deploy tokens via the credential broker but not SSH keys yet.
- **Scheduled execution unavailable.** The current UI supports interactive launches only. A future delegated design will use canonical operations.
- **Multi-device UI launches require a single controller.** AWX uses `limit:` to scope to specific hosts; mixed-controller selections are rejected at submit time. Multi-controller fan-out is a v2 design question.
- **Manual UUID paste for credential secret references.** Both controller and repository forms expect operators to paste a credential UUID from **Settings -> Networks -> Credential Rules** (`/settings/networks/credentials`). A picker UX is a planned v2 improvement.
