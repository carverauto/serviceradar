# Change: Make AWX/AAP inventory sync deployable (migration + controller→assignment materialization + lifecycle seeding)

## Why

The Ansible/AWX integration is ~90% built but **cannot run end to end**. On the
live demo the "AWX / AAP Bridge" plugin works ("AWX 24.6.1 reachable"), but
"AWX Inventory Sync" fails every cycle with:

```
AWX inventory_sync configuration invalid: controller_id is required
```

Root cause is two missing pieces plus wiring — the deployable slice of
`add-ansible-integration` that was never implemented (its tasks 1.10/1.11 and
4.6 are unchecked and there is no committed migration or materializer):

1. **No database schema.** The entire `ServiceRadar.Automation.Ansible` domain
   (10 resources: `Controller`→`ansible_controllers`, `PlaybookRepository`,
   `Playbook`, `PlaybookRun`, `PlaybookRunTarget`, `PlaybookPlay`,
   `PlaybookTask`, `PlaybookTaskResult`, `PlaybookContent`, `PlaybookSchedule`,
   plus AshPaperTrail `*_versions` tables) is code-complete
   (`elixir/serviceradar_core/lib/serviceradar/automation/ansible/*.ex`,
   registered at `automation/ansible.ex:23-34`), but **`mix ash.codegen` was
   never run/committed** — no migration creates `platform.ansible_controllers`,
   and the table is absent on demo. The registration UI, workers, and
   `AwxClient` all fail at the DB layer.
2. **No inventory-sync assignment materialization.** Nothing turns a registered
   `AnsibleController` into an `awx-inventory-sync` plugin assignment. The
   `awx-inventory-sync` Go plugin requires `base_url`, `api_token`, and
   `controller_id` in its config (`go/cmd/wasm-plugins/awx/main.go:798-808`),
   delivered per-agent via a scheduled assignment. The existing
   `PluginAssignmentMaterializer` only handles proxmox + camera providers (keyed
   on `NetworkCredentialRule` + SRQL host queries), and `profile_for("awx")`
   returns `:error`. So the assignment is never created → `controller_id is
   required`.
3. **No lifecycle seeding.** Ansible workers are not auto-started
   (`oban_ensure_scheduled.ex` has no ansible entries), and controller
   create/update (`web-ng .../settings/ansible_live.ex:1258-1272`) does not seed
   the health/catalog workers or (re)materialize the inventory-sync assignment.
   Even the existing self-scheduling health/catalog workers never get their
   first tick.

Everything else this slice depends on already exists and is verified: the
controller registration UI + RBAC, the shared `NetworkCredentialSecret`
credential model with a `:ansible` broker consumer kind, the grant-minting logic
(`automation/ansible/awx_client.ex:174-208`), the `awx-inventory-sync` Go plugin
(built + published via `build/wasm_plugins/plugin_inventory.bzl:150-151`), its
`DeviceDiscovery("awx")` emission, and DIRE's discovery-source merge.

## What Changes

- **Ansible domain migration**: run `mix ash.codegen` for the `Automation.Ansible`
  domain and commit the generated migration(s) creating all 10 resource tables
  (schema `platform`) + AshPaperTrail version tables + identities. This is
  `add-ansible-integration` tasks 1.10/1.11.
- **AnsibleController → awx-inventory-sync assignment materializer**: a new
  controller-keyed reconciler that, for each enabled `AnsibleController`,
  materializes a scheduled `awx-inventory-sync` plugin assignment on the
  controller's `agent_id`, at cadence `inventory_sync_interval_seconds`, with
  params `{controller_id, controller_name, base_url, insecure_skip_verify,
  timeout_ms, credential_broker: <grant>}`. It re-materializes on controller
  add/update/disable/delete and de-duplicates per (agent, controller). This is
  `add-ansible-integration` task 4.6.
  - Reuse the grant spec from `awx_client.ex:174-208` (consumer_kind `:ansible`,
    `resolution_location :agent`, `inject` Authorization Bearer, `allowed_hosts`
    from base_url, `allowed_paths ["/api/v2/"]`), keyed to the assignment cadence
    rather than a per-verb dispatch. Reuse `PolicyAssignmentReconciler` (the same
    writer the proxmox/camera materializer uses) to persist the assignment.
- **Lifecycle seeding**: on `AnsibleController` create/update seed the
  `ControllerHealthWorker` + `AwxCatalogSyncWorker` and (re)materialize the
  inventory-sync assignment; on disable/delete tear them down. At boot, seed the
  same for all enabled controllers (extend `oban_ensure_scheduled.ex`).
- **Package approval gate**: ensure the `awx-inventory-sync` plugin package is
  approved in the target environment (same gate proxmox/cameras use via
  `approved_plugin_package/3`) so the assignment can bind an artifact; document
  the demo-approval step.
- **Multi-controller support**: one `awx-inventory-sync` assignment per agent
  serving all controllers reachable from that agent, each with its own grant
  (mirrors the "Multi-Controller Plugin Instance" requirement).
- **Verification**: register a controller in the UI against the live AWX
  (`awx-service.awx.svc.cluster.local`, controller reachable from `k8s-agent`),
  confirm the assignment materializes, the plugin authenticates, and a
  `DeviceDiscovery("awx")` aggregate lands (AWX inventories 1/34 on demo).

## Impact

- Affected specs: `ansible-integration` (ADDED deployment/materialization
  requirements; complements the umbrella's behavioral requirements — no name
  collisions).
- Affected code:
  - `elixir/serviceradar_core/priv/repo/migrations/` (new migration)
  - `elixir/serviceradar_core/lib/serviceradar/automation/ansible/`
    (new inventory-sync reconciler worker; controller create/update hooks)
  - `elixir/serviceradar_core/lib/serviceradar/credentials/plugin_assignment_materializer.ex`
    or a sibling AWX materializer; grant reuse from `awx_client.ex`
  - `elixir/serviceradar_core/lib/serviceradar/oban_ensure_scheduled.ex`
    (boot seeding)
  - `elixir/web-ng/.../live/settings/ansible_live.ex` (seed on controller create)
- Relationship: this **completes a deployable slice of `add-ansible-integration`**
  (its tasks 1.10, 1.11, 4.6 + seeding). It does NOT re-specify the umbrella's
  behavioral requirements (Controller Registration, Inventory-as-Discovery-
  Source, WASM Bridge, Run lifecycle) — those stay owned by the umbrella. The
  umbrella's stale 0/91 checkbox status should be reconciled separately.
  Independent of `add-northbound-action-integrations` /
  `add-long-running-northbound-actions` (those own the device "Run Task" launch
  path, not inventory sync).
- **BREAKING**: none. New tables, new assignment type; no API changes.
