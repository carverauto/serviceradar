## 1. Read model and information architecture

- [x] 1.1 Extend `ServiceRadarWebNG.Plugins.PluginFleet` to return one summary per `plugin_id`:
  - the latest approved and the newest staged package;
  - running versions with assignment counts;
  - the owner breakdown (manual, target policy, credential rule) with links;
  - the update-policy mix;
  - "behind latest" counts;
  - a health rollup from the services read model.
- [x] 1.2 Split `PluginPackageLive.Index` into `Plugins.InstalledLive`, `Plugins.UpdatesLive`, `Plugins.CatalogLive` and `Plugins.ShowLive`, with shared function components. Register each as a Settings catalog view.
- [x] 1.3 Installed tab: one row per plugin, streamed and server-paginated. No 100-row cap.
- [ ] 1.4 Plugin detail at `/settings/agents/plugins/:plugin_id` with Overview, Assignments (grouped by owner, linking to the rule or policy), Versions (pin-to-version), Permissions (requested vs approved) and Advanced (manifest, schemas, provenance, artifact tokens).
- [ ] 1.5 Redirect the old per-package route to the plugin detail with that version selected.
- [ ] 1.6 Move the Capacity Snapshot to the agent detail page.
- [ ] 1.7 Move repositories, the release picker, Sync, Test egress, Import and the verification policy into the Catalog tab. Show the first-party sync worker's last run, next run and errors there, and add a "Sync now" that enqueues the worker.
- [x] 1.8 Remove the dead legacy-recovery candidate assigns, events and handlers.
- [x] 1.9 No database or GitHub work in the disconnected mount. Move catalog fetches to `start_async` or Oban.

## 2. Update policy

- [x] 2.1 Migration: add `update_policy` (`track_latest_approved | pinned`, default `pinned`) and `update_policy_source` (`migration_default | operator`) to `plugin_assignments` and `plugin_target_policies`. Mark rows that exist at migration time `migration_default`; new rows record `operator`. Catalog-only DDL, startup-safe.
- [x] 2.2 Ash: expose `update_policy` on the create and update actions. Any operator action (pin, track, version change) sets `update_policy_source` to `operator`. Selecting a concrete version from the UI sets `pinned`.
- [x] 2.3 Resolve tracking owners to the latest approved package with the same `plugin_id`, using one shared resolver also used by `PluginAssignmentMaterializer.approved_plugin_package/3`.
- [ ] 2.4 One-shot Oban backfill: manual and target-policy owners on signed, verified first-party packages whose `update_policy_source` is still `migration_default` become `track_latest_approved`; everything else is left unchanged. Run it in bounded, skip-locked batches that re-check `migration_default` inside each batch, so an operator pin made before or during the backfill is never overwritten. The one-click Pin is task 2.5 and is not a gate: automatic rollouts already ship on (design.md, "Step E as built").
- [ ] 2.5 UI: show the update policy per owner, with a "Track latest" / "Pin to version" control.
- [ ] 2.6 Remove the hidden upgrade-on-reassign path in the Assign form.

## 3. Auto-approval and rollouts

- [x] 3.1 First-party sync: auto-approve a signed, verified package whose capabilities, permissions and resources are a subset of the current approved grant for that `plugin_id`. Otherwise leave it `staged`. Never auto-approve a plugin's first version. Add a deployment kill switch, and an audit event marking the approval as automatic. This is the only exception to the modified "Staged Import Review and Capability Confirmation" requirement.
- [ ] 3.2 Updates tab: list staged packages with a per-field grant diff, and approve or deny each. Show auto-approvals and rollouts as history.
- [x] 3.3 Spike: confirm that `AddonRollout` / `AddonRolloutTarget` generalize with an artifact kind (`native_addon | wasm_plugin`). Record any blocker in design.md for review.
- [x] 3.4 Rollout coordinator for Wasm plugins:
  - snapshotted targets, batches and soak;
  - a health gate from fresh plugin results;
  - pause, resume and cancel;
  - rollback to the previous stable package.
- [x] 3.5 Trigger a rollout for tracking owners when a newer eligible package is approved, automatically or manually.
- [ ] 3.6 Credential-rule owners resolve through the rollout stable/candidate overlay instead of floating instantly.
- [ ] 3.7 Bulk "Upgrade to latest", per plugin and across all plugins, for selected pinned owners. It previews compatible, incompatible, unavailable and already-current targets, then executes through rollouts.

## 4. Safety and visibility

- [ ] 4.1 Owner status with reason codes: `ok`, `targets_unresolved`, `incompatible_config`, `awaiting_review`, `health_gate_failed`, `rolled_back`. Persist it on rules, policies and manual rows, and render it on the plugin row, the plugin detail and the owner pages.
- [ ] 4.2 Audit: every disable of an enabled assignment records an actor and a reason. No code path disables without one.
- [ ] 4.3 Revoke flow: show the affected assignments before revoking, and record the reason on each disabled row.

## 5. Tests and docs

- [ ] 5.1 Domain tests:
  - tracking resolution;
  - auto-approval: subset approves, widening stays staged, the first version stays staged;
  - backfill defaults, including an operator pin made before or during the backfill staying pinned;
  - the rollout state machine, including rollback.
- [ ] 5.2 LiveView tests for each tab and for the plugin detail (lane-tagged per `elixir/web-ng/AGENTS.md`):
  - one row per plugin;
  - "behind latest" counts;
  - owner links;
  - pin and track toggles;
  - the bulk upgrade preview.
- [ ] 5.3 Integration test: approving a non-widening first-party version moves tracking assignments through a rollout and leaves pinned ones behind.
- [ ] 5.4 Docs: rewrite the plugin management guide (docs site) for the new tabs, update policies, auto-approval and fleet upgrades.
