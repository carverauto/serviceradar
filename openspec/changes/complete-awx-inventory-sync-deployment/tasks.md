# Tasks — complete-awx-inventory-sync-deployment

## 1. Ansible domain migration (add-ansible-integration 1.10/1.11)
- [ ] 1.1 Run `mix ash.codegen add_ansible_integration` for the `Automation.Ansible` domain; review generated migration(s) for all 10 tables (`ansible_controllers`, `ansible_playbook_repositories`, `ansible_playbooks`, `ansible_playbook_runs`, `ansible_playbook_run_targets`, `ansible_playbook_plays`, `ansible_playbook_tasks`, `ansible_playbook_task_results`, `ansible_playbook_content`, `ansible_playbook_schedules`) + AshPaperTrail `*_versions` tables
- [ ] 1.2 Verify schema `platform`, identities/unique indexes (`:unique_name` on Controller, etc.), and the `credential_secret_id` handling; confirm migration version is unique (`ls migrations | grep -oE '^[0-9]+' | sort | uniq -d` empty) and applies cleanly over the current staging baseline (not just a fresh DB)
- [ ] 1.3 Commit the migration + resource snapshots

## 2. AnsibleController → awx-inventory-sync assignment materialization (task 4.6)
- [ ] 2.1 Resolve the config-shape decision (design Open Question): the plugin's `InventorySyncConfig` has a single `ControllerID` (`main.go:755-770`) but an agent can hold only one enabled `awx-inventory-sync` assignment (per-(agent,plugin) uniqueness). Either extend the plugin config to a controller LIST, or relax uniqueness for this plugin. Pick one and implement consistently across Go + Elixir.
- [ ] 2.2 Add `AwxInventorySyncReconciler` (controller-keyed; sibling of `ProxmoxCredentialRuleReconcileWorker`): for each enabled `AnsibleController`, materialize an `awx-inventory-sync` assignment on its `agent_id` with params `{controller_id(s), controller_name, base_url, insecure_skip_verify, timeout_ms, credential_broker: <grant>}` at cadence `inventory_sync_interval_seconds`
- [ ] 2.3 Reuse the grant-minting from `awx_client.ex:174-208` (shared helper or direct call) so the assignment grant matches the run_check grant (consumer `:ansible`, agent-resolved, Bearer inject, allowed_hosts/paths); keep the grant reference stable across reconciles when the controller is unchanged (avoid the proxmox grant-churn class)
- [ ] 2.4 Write the assignment via `PolicyAssignmentReconciler` (the proxmox/camera writer); disable any pre-existing manual `awx-inventory-sync` assignment on the agent first; de-dupe per (agent, controller-set)
- [ ] 2.5 Ensure the `awx-inventory-sync` plugin package is approved before assignment (reuse `approved_plugin_package/3`); document the demo-approval step

## 3. Lifecycle seeding
- [ ] 3.1 On `AnsibleController` create/update: seed `ControllerHealthWorker.ensure_scheduled/1` + `AwxCatalogSyncWorker` ensure_scheduled + `AwxInventorySyncReconciler.reconcile_agent/1`; on disable/delete: tear down workers + assignment. Wire into the UI create flow (`web-ng .../settings/ansible_live.ex:1258-1272`) and the resource actions
- [ ] 3.2 Extend `oban_ensure_scheduled.ex` to seed all enabled controllers' workers + inventory-sync reconcile at boot (restart-safety)

## 4. Tests
- [ ] 4.1 Migration test: domain migrates cleanly; `platform.ansible_controllers` and the rest exist with expected columns/indexes
- [ ] 4.2 Reconciler unit tests: enabled controller → assignment with correct params + grant; disable → assignment removed; multi-controller-per-agent shape; manual-assignment shadowing disabled; grant stable across reconciles
- [ ] 4.3 Contract test: reconciler-emitted `config_json` decodes with the real `awx-inventory-sync` Go decoder (`validateInventorySyncConfig`) — extends the addon/plugin contract-test suite so `controller_id`/`base_url`/`api_token` are always satisfied
- [ ] 4.4 Seeding test: controller create seeds health/catalog workers + assignment; boot seeds all enabled controllers

## 5. Rollout & verification (demo)
- [ ] 5.1 Hand-run the migration on demo via rpc (`Ecto.Migrator.run … prefix: "platform"`); verify tables exist
- [ ] 5.2 Approve the `awx-inventory-sync` package on demo
- [ ] 5.3 Register a controller in the UI (base_url `http://awx-service.awx.svc.cluster.local`, agent `k8s-agent`, AWX API token secret); confirm the assignment materializes, the plugin authenticates, and a `DeviceDiscovery("awx")` aggregate lands for AWX inventories 1 (Demo) / 34 (proxmox)
- [ ] 5.4 Confirm "AWX Inventory Sync" check goes from "controller_id is required" to OK
