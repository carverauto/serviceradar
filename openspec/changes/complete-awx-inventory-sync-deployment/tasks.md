# Tasks — complete-awx-inventory-sync-deployment

## 1. Ansible domain migration (add-ansible-integration 1.10/1.11)
- [x] 1.1 Run/review `mix ash.codegen add_ansible_integration`; replace the oversized generated output with a scoped manual migration for the 10 Ansible domain tables plus AshPaperTrail `*_versions` tables
- [x] 1.2 Verify schema `platform`, identities/unique indexes (`:unique_name` on Controller, etc.), and `credential_secret_id` handling; migration applies cleanly through the full current migration chain on an `srql-fixtures` scratch DB
- [x] 1.3 Commit the scoped migration; resource snapshots intentionally omitted because the generated snapshot set included unrelated resources

## 2. AnsibleController → awx-inventory-sync assignment materialization (task 4.6)
- [x] 2.1 Resolve the config-shape decision: extend the Go plugin to support a `controllers` list while preserving the legacy single-controller config shape
- [x] 2.2 Add `AwxInventorySyncReconciler`: materializes one `awx-inventory-sync` assignment per agent with all reachable controllers in params
- [x] 2.3 Reuse AWX grant minting via `AwxClient.inventory_sync_grant_template/1`; assignment params keep stable grant templates while delivery mints short-lived grants
- [x] 2.4 Write assignments via `PolicyAssignmentReconciler`; shared reconciler adoption now matches the actual `(agent_uid, plugin_id)` uniqueness rule, so older manual/package-version rows are adopted instead of blocking policy materialization
- [x] 2.5 Ensure the `awx-inventory-sync` plugin package is approved before assignment via approved-package lookup; demo approval remains a rollout step

## 3. Lifecycle seeding
- [x] 3.1 On `AnsibleController` create/update/destroy: seed `ControllerHealthWorker.ensure_scheduled/1`, `AwxCatalogSyncWorker.ensure_scheduled/1`, `RunPulseWorker.ensure_scheduled/1`, global workers, and `AwxInventorySyncReconciler.reconcile_agent/1`; per-controller workers naturally stop rescheduling after delete when they observe the missing controller
- [x] 3.2 Add `LifecycleSeedWorker` + `LifecycleScheduler` to re-seed all controllers and inventory-sync assignments at boot/backstop cadence

## 4. Tests
- [x] 4.1 Migration test: full migration chain applied on `srql-fixtures` scratch DB; `20260705162000` created all Ansible tables/indexes
- [x] 4.2 Reconciler/unit/integration tests: controller → assignment with correct params + grant, empty controller set disables stale policy assignment, multi-controller-per-agent shape, nested controller grants resolve independently, and older manual package-version assignment is adopted by policy
- [x] 4.3 Contract test: reconciler-emitted runtime `config_json` carries `controller_id`/`base_url`/resolved `api_token`, and the real `awx-inventory-sync` Go decoder (`validateInventorySyncConfig`) accepts the resolved controller-list shape
- [x] 4.4 Seeding test: controller seed schedules health/catalog/pulse workers + assignment; boot/backstop seed schedules all controllers and reconciles all assignments

## 5. Rollout & verification (demo)
- [ ] 5.1 Hand-run the migration on demo via rpc (`Ecto.Migrator.run … prefix: "platform"`); verify tables exist
- [ ] 5.2 Approve the `awx-inventory-sync` package on demo
- [ ] 5.3 Register a controller in the UI (base_url `http://awx-service.awx.svc.cluster.local`, agent `k8s-agent`, AWX API token secret); confirm the assignment materializes, the plugin authenticates, and a `DeviceDiscovery("awx")` aggregate lands for AWX inventories 1 (Demo) / 34 (proxmox)
- [ ] 5.4 Confirm "AWX Inventory Sync" check goes from "controller_id is required" to OK
