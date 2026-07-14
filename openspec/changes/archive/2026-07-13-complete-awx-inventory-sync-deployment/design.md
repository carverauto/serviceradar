# Design — complete-awx-inventory-sync-deployment

## Context

Verified state (from source in the worktree + live demo 2026-07-05):

- The `Automation.Ansible` domain and all 10 resources are code-complete but
  **unmigrated** — `grep 'create table(:ansible_controllers'` over
  `priv/repo/migrations/` returns nothing, and there are no resource snapshots
  for the domain. `platform.ansible_controllers` does not exist on demo.
- `AwxClient.credential_broker_grant/3` (`awx_client.ex:174-208`) already mints
  a `CredentialBrokerGrant` (`grant_type "awx_oauth2_token"`, `consumer_kind
  :ansible`, `resolution_location :agent`, Authorization-Bearer inject,
  `allowed_hosts` from base_url, `allowed_paths ["/api/v2/"]`) for the
  on-demand `run_check` path. The same grant shape is what the scheduled
  assignment must embed.
- `PluginAssignmentMaterializer` (`credentials/plugin_assignment_materializer.ex`)
  is **rule-keyed** (NetworkCredentialRule + SRQL `target_query`, per-host) and
  provider-limited to `[ProxmoxProfile, UnifiProtectProfile, AxisProfile]`
  (`credential_provider_profile.ex:74-95`). AWX inventory sync is
  **controller-keyed** (per-controller, no host query), so it does not fit the
  rule/profile shape and needs its own reconciler.
- The `awx-inventory-sync` plugin requires `{base_url, api_token, controller_id}`
  (`main.go:798-808`) and emits `sdk.NewDeviceDiscovery("awx")`
  (`main.go:835-895`, host id `awx:{controller_id}:host:{host_id}`). It is built
  and published; only unconfigured.
- Health/catalog workers are plain `Oban.Worker`s that self-reschedule but are
  never seeded (`oban_ensure_scheduled.ex` has no ansible refs; the UI
  create-flow doesn't seed them).

## Goals / Non-Goals

- Goals:
  - `platform.ansible_controllers` (and the rest of the domain) exist via a
    committed migration.
  - Registering an `AnsibleController` produces a working `awx-inventory-sync`
    assignment that authenticates and emits AWX host discovery.
  - Controllers, health/catalog workers, and the inventory-sync assignment stay
    consistent across create/update/disable/delete and process restarts.
- Non-Goals:
  - The device "Run Playbook" launch path, run/play/task hierarchy, event
    pulse/watchdog, OCSF projection (owned by `add-ansible-integration`).
  - Northbound action-provider generalization (owned by
    `add-northbound-action-integrations`).
  - Storing SSH/become credentials (they stay in AWX; ServiceRadar holds only
    the API token, AshCloak-encrypted, via `NetworkCredentialSecret`).

## Decisions

- **Decision: controller-keyed reconciler, not a credential provider profile.**
  AWX inventory sync has no per-host SRQL query (it enumerates AWX inventories),
  so bolting it onto the rule-based `PluginAssignmentMaterializer` is a poor
  fit. Add a dedicated `AwxInventorySyncReconciler` (sibling of
  `ProxmoxCredentialRuleReconcileWorker`) that iterates enabled
  `AnsibleController`s and writes one assignment per (agent, controller-set)
  through `PolicyAssignmentReconciler`. Alternative — force an AWX provider
  profile into the rule model — rejected: it would require a synthetic
  target_query and misrepresent the per-controller semantics.
- **Decision: one assignment per agent, N controllers.** Matches the
  "Multi-Controller Plugin Instance" requirement — the assignment params carry a
  list of `{controller_id, controller_name, base_url, insecure_skip_verify,
  timeout_ms, credential_broker}` for every enabled controller whose `agent_id`
  is that agent. The plugin already loops controllers.
- **Decision: reuse the existing grant-minting.** Lift
  `AwxClient.credential_broker_grant/3` into a shared helper (or call it) so the
  assignment path and the run_check path mint identical grants; only the
  consumer/purpose label differs. Keeps one credential story.
- **Decision: migration via `mix ash.codegen`, reviewed.** Generate with
  `mix ash.codegen add_ansible_integration`, review the DDL (10 tables +
  paper-trail version tables + identities + the `credential_secret_id` FK
  behavior), ensure schema `platform` and unique/identity indexes, and commit.
  Verify migration version uniqueness (the release checklist bit us before) and
  that it runs cleanly against a prior baseline (not just a fresh DB).
- **Decision: seed on create + at boot.** Controller create/update hooks call
  `ControllerHealthWorker.ensure_scheduled/1` + the catalog worker's
  `ensure_scheduled` + `AwxInventorySyncReconciler.reconcile_agent/1`;
  disable/delete tears them down. `oban_ensure_scheduled.ex` seeds all enabled
  controllers at boot for restart-safety.

## Risks / Trade-offs

- Migration touches 10 new tables + version tables → review DDL carefully;
  guard against duplicate migration versions; confirm it applies over the demo
  baseline (RUN_MIGRATIONS=false → hand-run via rpc `Ecto.Migrator.run … prefix:
  "platform"`).
- The inventory-sync assignment shares the per-(agent, plugin) uniqueness
  constraint; if an agent already has a manual `awx-inventory-sync` assignment,
  the reconciler must disable it first (same pattern used for proxmox/cameras).
- Large AWX inventories → the plugin enumerates all hosts; ensure the assignment
  `timeout_seconds`/response bounds are sane (learn from the proxmox
  large-response WASM OOM, fj #4418 — bound response reads).
- Grant TTL vs assignment cadence: re-mint grants must not churn the assignment
  config every cycle (learned from proxmox grant-churn); make the grant
  reference stable across reconciles when the controller is unchanged.

## Migration / Rollout

1. Land migration; hand-run on demo via rpc (`prefix: "platform"`); verify
   `platform.ansible_controllers` exists.
2. Land reconciler + seeding; ensure the `awx-inventory-sync` package is approved.
3. Register the demo controller in the UI (base_url
   `http://awx-service.awx.svc.cluster.local`, agent `k8s-agent`, AWX API
   token secret); confirm the assignment materializes, authenticates, and emits
   discovery for AWX inventories 1 (Demo, 2 hosts) / 34 (proxmox, 11 hosts).
Rollback: disable the controller → reconciler tears down the assignment; the
migration is additive (new tables), safe to leave in place.

## Open Questions

- Should the inventory-sync cadence be per-controller (`inventory_sync_interval_
  seconds`) or clamped to a floor to avoid hammering large AWX instances?
- Does the assignment carry ALL controllers for an agent in one params blob, or
  one assignment per controller? (Design assumes one-per-agent with a controller
  list, matching the plugin's multi-controller loop; confirm the plugin's config
  shape supports the list vs single controller_id — `main.go:755-770` shows a
  single `ControllerID`, so the first cut may be one assignment per controller,
  which conflicts with the per-(agent,plugin) uniqueness → resolve by either
  extending the plugin config to a controller list, or relaxing uniqueness for
  awx-inventory-sync.)
