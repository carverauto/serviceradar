# Change: Redesign Wasm plugin management around logical plugins, update policies and fleet upgrades

## Why

`/settings/agents/plugins` is the only place an operator manages Wasm plugins.
It has grown into one 6,000-line LiveView with four unrelated panels on one
page: Imported packages, Plugin catalog, Capacity Snapshot and Verification
Policy. The way it models versions makes routine work slow and, in one case,
unsafe.

### Too many versions, not enough plugins

- **Imported packages lists one row per `(plugin_id, version)`.**
  - A plugin that shipped in twelve releases shows twelve rows.
  - Staged, approved, uploaded and first-party copies are interleaved.
  - The table is silently capped at 100 rows.
  - The operator cannot answer "which plugins do I run, and are they current?"
    without paging through history.
- **The plugin catalog repeats the same packages** with its own status and
  pagination, plus repository management, a release picker, **Sync** (lists
  only), **Test egress** and **Import All**.
- There are three different "refresh" controls. None of them runs the hourly
  first-party sync, whose state is visible only as one "Last sync" line.

### Upgrades are manual, per assignment

- **Every first-party release lands as `staged`.** Each new plugin version must
  be approved by hand, even when its requested capabilities, permissions and
  resources are identical to the version already approved.
- **Manual assignments never move.** Each one must be upgraded from the package
  modal with **Upgrade** or **Change version, then Apply**, one row at a time.
  Re-submitting the Assign form is a second, silent upgrade path.
- **Target-policy assignments never move.** The policy pins a package ID until
  someone edits it.
- **Credential-rule assignments do move**, but only once someone has approved
  the new version. The UI does not say which rows behave which way.
- **There is no bulk or fleet upgrade.** An operator with many plugins (or
  many agents) has to remember, after every release, to visit each plugin and
  click through each assignment. In practice this is forgotten, and the fleet
  runs months-old plugin versions.

The native add-on system already solved this in
`add-native-addon-fleet-rollouts`:
- `track_latest_approved` is the default for trusted first-party sources;
- explicit pins win;
- approval is separate from desired state;
- rollouts are staged and health-gated;
- there is a bulk upgrade workflow.

That design explicitly left Wasm plugins out of scope ("Change Wasm plugin
assignment upgrade semantics" is a non-goal). This change brings Wasm plugins
onto the same model.

### Assignments disappear without a trace

The package modal shows every `source: :policy` row the same way ("managed by
policy"), whether a credential rule owns it (it follows the latest approved
version) or a target policy owns it (it is pinned). Neither links to its owner.

When an owner's target query resolves no devices, the reconciler disables the
owner's enabled assignments as stale and records nothing an operator can see.
On a live deployment this stopped a working camera integration after a
device's primary address changed; the plugin simply vanished from
`/services`. The empty-resolution retraction itself is fixed by
`fix-plugin-assignment-empty-target-retraction`. This change makes the outcome
visible and adds the general invariant that no upgrade or reconcile silently
disables a working assignment.

## What Changes

### Information architecture

The single page is replaced by a **Plugins** area with three tabs and a
per-plugin detail view:

- **Installed** (default): one row per logical plugin (`plugin_id`), not per
  version. Each row shows:
  - name;
  - running versions;
  - the latest approved version and whether an update is available or awaiting
    review;
  - update policy;
  - assignment counts (enabled, behind latest);
  - service health from `/services`;
  - an ownership summary.

  Fleet actions such as "Upgrade all to latest" and "N plugins have updates"
  live here.
- **Updates**: packages awaiting review. Each shows its capability, permission
  and resource diff against the currently approved grant, with approve and
  deny. Auto-approved and auto-rolled-out updates appear here as history.
- **Catalog**: repositories (including the verification policy), releases, and
  import of plugins that are not installed yet. Sync, Test egress and Import
  belong here, together with the first-party sync status, the last run and its
  errors.
- **Plugin detail** at `/settings/agents/plugins/:plugin_id`, replacing the
  per-package modal. It has five sections:
  - Overview: latest approved version, update policy, health.
  - Assignments: grouped by owner (manual, target policy, credential rule),
    each linking to its owning rule or policy, with per-assignment version and
    state.
  - Versions: history, with a deliberate pin-to-version action.
  - Permissions: requested vs approved.
  - Advanced: manifest, schemas, provenance, artifact tokens.
- The **Capacity Snapshot** moves to the agent detail page (per agent). It no
  longer occupies the main page.

### Versions and update policy

- Every assignment owner has an update policy: `track_latest_approved` or
  `pinned`. This covers manual assignments, target policies and credential
  rules. Credential rules keep their current behaviour, which is
  `track_latest_approved`.
  - Assignments to signed, verified first-party packages default to
    `track_latest_approved`.
  - Uploads, GitHub imports and third-party repositories default to `pinned`.
  - Choosing a specific version is a deliberate pin.
- **First-party auto-approval with a capability ceiling.** A signed, verified
  first-party package whose requested capabilities, permissions and resources
  stay within the currently approved grant for that plugin is approved
  automatically. A version that widens any of them stays `staged` and appears in
  **Updates** with the diff. The first approved version of any plugin always
  needs an explicit decision. Approval never rewrites assignments by itself.
  This modifies the existing `wasm-plugin-system` requirement "Staged Import
  Review and Capability Confirmation", which today requires an explicit decision
  for every import.
- **Fleet upgrades.** When a newer eligible version is approved, a plugin
  rollout moves tracking assignments in batches. It generalizes the native
  add-on rollout coordinator (snapshotted targets, batches, a health
  gate from plugin results and `/services`, pause/resume/cancel, rollback to the
  previous package). Pinned assignments are reported as "behind" but not moved.
- **Bulk "Upgrade to latest"** per plugin and across all plugins. It upgrades
  pinned assignments the operator selects, through the same rollout path, with
  a preview of compatible, incompatible, unavailable and already-current
  targets.

### Safety and clarity

- **No silent disables.** No upgrade, rollout or reconcile disables an enabled
  assignment without a recorded, visible reason. Unresolved targets, an
  incompatible configuration and a failed health gate surface as
  `needs_attention` on the plugin and the owning rule or policy.
- **One upgrade path.** The Assign form only creates assignments. The hidden
  upgrade-on-reassign path is removed.
- **Performance:**
  - no synchronous GitHub calls in the LiveView process;
  - the 100-row cap is removed;
  - streams are used for collections;
  - no database work in the disconnected mount (web-ng Iron Law).
- The dead legacy-recovery candidate code is removed.

## Impact

- **Affected specs:**
  - `plugin-configuration-ui`: added requirements.
  - `wasm-plugin-system`: added requirements, and a modified "Staged Import
    Review and Capability Confirmation" that permits first-party auto-approval
    within the approved grant.
- **Related changes:**
  - `add-native-addon-fleet-rollouts`: its rollout coordinator, update-policy
    vocabulary and fleet health classification are reused.
  - `fix-plugin-assignment-empty-target-retraction`: the reconciler semantics
    this change surfaces in the UI.
  - `fix-plugin-assignment-upgrades`: replaces its per-row upgrade controls.
  - `redesign-settings-catalog-nav`: the Plugins area registers its tabs as
    catalog views.
  - `add-third-party-plugin-repositories`: Catalog tab.
- **Affected code:**
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/plugin_package_live/`
    is split into per-tab LiveViews and components.
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/` (`packages.ex`,
    `assignments.ex`, `first_party_sync_worker.ex`, `plugin_fleet.ex`).
  - `elixir/serviceradar_core/lib/serviceradar/plugins/`: the assignment and
    target-policy update policy, plugin rollouts, and first-party auto-approval.
  - `credentials/plugin_assignment_materializer.ex`: the reported owner status.
  - LiveView, domain and integration tests for the above.
- **Data:**
  - new `update_policy` and `update_policy_source`
    (`migration_default | operator`) columns on assignments and target
    policies;
  - an artifact kind on `AddonRollout` / `AddonRolloutTarget` so they also
    carry Wasm plugin rollouts;
  - a one-shot backfill that sets existing first-party manual assignments and
    target policies to `track_latest_approved` only while their policy is still
    the `migration_default`, so an operator pin is never overwritten (see
    design Migration).
