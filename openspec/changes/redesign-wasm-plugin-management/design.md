# Design: Wasm plugin management redesign

## Context

The current page (`PluginPackageLive.Index`, about 6,000 lines) mixes four jobs
on one screen:
- package review: approve, deny, revoke, restage;
- fleet assignment: assign, upgrade and remove per assignment;
- catalog and repository management: sync, import, egress test;
- capacity reporting.

Its central list is keyed by package version (`PluginPackage` is unique on
`(plugin_id, version)`). Operators think in plugins.

Each assignment owner moves between versions differently today:

| Owner | How it is stored | Moves to a new version |
| --- | --- | --- |
| Manual assignment | `source: :manual`, concrete `plugin_package_id` | Never; per-row Upgrade only |
| Target policy | `source: :policy`, policy stores `plugin_package_id` | Only when the policy is edited |
| Credential rule | `source: :policy`, `policy_id: "network-credential-rule:<id>[:<purpose>]"` | Yes: the latest approved package on the next 60s reconcile |

First-party packages imported by the hourly sync always land as `staged`, so
even credential-rule owners do not move until someone approves.

Native add-ons solved the same problems in `add-native-addon-fleet-rollouts`,
whose Decisions 1, 2 and 7 this design reuses.

## Goals / Non-Goals

### Goals
- One row per logical plugin. Versions are history, and choosing one is
  deliberate.
- Routine first-party updates need no clicks: trusted, non-widening versions are
  auto-approved and tracking assignments roll forward on their own.
- Widened privileges always need an explicit review, with a diff.
- A fleet-wide "upgrade to latest" exists for pinned assignments.
- Every assignment shows its owner and update policy, with a link to the owner.
- No upgrade or reconcile silently disables a working assignment.
- The page is fast: no blocking network calls in the LiveView process and no
  silent row caps.

### Non-Goals
- Changing the Wasm runtime, host capabilities or the package format.
- Auto-approving uploads, GitHub imports or third-party repository packages.
- Merging Wasm plugin rollouts with agent-release rollouts.
- Redesigning credential rules or target-policy authoring forms beyond adding
  update-policy controls and status links.

## Decisions

### Decision 1: The logical plugin is the primary object

`plugin_id` becomes the unit the UI lists and links to
(`/settings/agents/plugins/:plugin_id`). A small read model,
`ServiceRadarWebNG.Plugins.PluginFleet`, which already exists read-only, is
extended to return one summary per `plugin_id`:
- the latest approved package;
- the newest staged package, if any;
- running versions with assignment counts;
- the owner breakdown;
- the update policy mix;
- the health rollup from the services read model.

Package-level views (manifest, provenance, tokens) move under the plugin
detail's Advanced section and the Versions list. The per-package route remains
as a redirect for old links.

### Decision 2: Update policy on every owner, defaulting by provenance

Add `update_policy` (`track_latest_approved | pinned`) to `PluginAssignment`
(manual rows) and to `PluginTargetPolicy`. Credential-rule owners are
documented as `track_latest_approved`, which is their existing behaviour, and
the UI shows them that way.

Alongside it, add a durable `update_policy_source`
(`migration_default | operator`), as add-on Decision 1 does, so the migration
can tell a default it assigned from an operator's choice:
- the schema migration marks only rows that exist at migration time as
  `migration_default`;
- any operator action on an owner (pin, track, version change) sets
  `operator`;
- the backfill (Migration Plan step 2) changes only rows that are still
  `migration_default`.

- **Defaults:**
  - signed, verified `first_party` packages default to `track_latest_approved`;
  - `upload`, `github` and third-party repository packages default to `pinned`;
  - selecting a specific version in the UI sets `pinned`.
- **Resolution:** the config generator and reconcilers resolve the package of a
  tracking owner as the latest approved package with the same `plugin_id`. This
  is the rule `PluginAssignmentMaterializer.approved_plugin_package/3` already
  uses: semver, then approval time. A concrete `plugin_package_id` is still
  stored as the *stable* package, which rollouts advance (Decision 4).
- **Eligibility:** a candidate must be approved, not revoked, and the same
  `plugin_id`. Prereleases are excluded unless selected.

### Decision 3: First-party auto-approval within a capability ceiling

When the first-party sync imports a signed, verified package, it compares the
new version's requested capabilities, permissions and resources with the
currently approved grant for that `plugin_id` (the latest approved version).
- **Subset or equal on all three:** approve it automatically, carrying the
  approved grant forward, and record an audit event marking the approval as
  automatic.
- **Any widening:** keep it `staged`. It appears in **Updates** with a
  per-field diff (added capabilities, new allowed domains, networks or ports,
  higher resource requests).
- **First version:** a plugin with no approved version is never auto-approved;
  the first approval is always manual.

This modifies the `wasm-plugin-system` requirement "Staged Import Review and
Capability Confirmation", which today requires an explicit approve/deny
decision for every import. The modified requirement keeps that rule and adds
this auto-approval as its only exception.

A deployment setting can turn auto-approval off. It defaults on for first-party
packages only, mirroring `autoApproveAddonIds` for native add-ons. Approval
never rewrites assignments in the approval transaction.

### Decision 4: Plugin rollouts reuse the add-on rollout coordinator

Moving tracking owners to a newly approved version is an asynchronous rollout:
- snapshotted target set (materialized agent/plugin pairs);
- batches;
- an inter-batch soak;
- a health gate from fresh plugin results (the service status for the
  assignment's service identity), not stale rows;
- pause, resume and cancel;
- rollback to the previous stable package.

The plan is to generalize `AddonRollout` / `AddonRolloutTarget` with an artifact
kind (`native_addon | wasm_plugin`), not to build a second coordinator. Task 3.3
is a spike that confirms the generalization; any blocker it finds is recorded
here for review.

**Target membership:**
- **Manual tracking rows:** each row is a target.
- **Target-policy owners:** the policy's materialized assignments, advanced by a
  per-target override and then promoted to the policy's stable package
  (add-on Decision 2).
- **Credential-rule owners:** already resolve the latest package on reconcile.
  They are switched to resolve through the rollout's stable/candidate overlay,
  so they move in batches like everyone else instead of all at once.

### Decision 4 addendum: findings from the rollout spike (task 3.3)

**Verdict: generalize, with adjustments; no hard blocker.**

The rollout state machine carries over unchanged, and so does the
coordinator's control flow. That covers the snapshot, canary/batches, soak,
per-target and whole-rollout rollback, supersede, retry, and one active
rollout per source. What is tied to add-ons is the coordinator's
collaborators, so the generalization is an engine/adapter split (a
`RolloutArtifact` behaviour with add-on and Wasm implementations) plus an
`artifact_kind` column.

**Adjustments:**
- **Version-bound health evidence.** Plugin results carry no package, version
  or content hash. The agent host stamps `{assignment_id, package_id,
  content_hash}` on each pushed result and reports the per-assignment loaded
  hash. The gate prefers that evidence. For older agents it falls back to time
  ordering: config ack after the override, then a fresh reported result.
- **A stable package for credential-rule owners.** Today they resolve the
  latest approved package and render params from its manifest on every
  reconcile. A `plugin_owner_package_states` row holds each rule-plus-purpose
  owner's stable package. The materializer resolves through it and renders
  params from the resolved package's manifest.
- **`tolerated_failures` is fixed at 0 for Wasm in v1.** The add-on pattern of
  converting a tolerated failure into a manual pin conflicts with policy
  reconcilers adopting and disabling manual duplicates.
- **"Converged" checks desired state for Wasm**, i.e. every in-scope stable
  package is at least the candidate, not observed versions.
- **Schema:**
  - nullable package FK pairs per artifact family on rollouts and targets,
    with a CHECK that the pair matches `artifact_kind`;
  - a `source_key` for the credential-rule purpose;
  - Wasm targets keyed by `plugin_assignment_id`, plus `partition_id`;
  - `rollout_plugin_package_id`, `rollout_id` and `rollout_started_at` on
    `plugin_assignments`;
  - add-on readers filter `artifact_kind = 'native_addon'`.
- **Override hook.** It lives in `AgentConfigGenerator.load_plugin_assignments`.
  The gateway calls core's generator, so this is the single hook point.
  Readers of the package (the northbound dispatcher, service-state
  placeholders) use the effective package,
  `COALESCE(rollout_plugin_package_id, plugin_package_id)`.
- **Reconcilers:**
  - they keep writing only the stable package, so overrides never churn;
  - a retraction that disables a held row clears its override in the same
    update, records the reason, and cancels the target as
    `assignment_retracted`;
  - revoking a candidate rolls back an active rollout.
- **Action-only plugins.** These are gated on the first successful invocation
  after the override, or on a loaded-candidate-hash report. Without either,
  a snapshotted `on_no_evidence` policy applies (default: pass after soak,
  recorded as `no_run_evidence`, never shown as verified healthy).

**Implementation steps:**
- **A.** Engine/adapter split, with no behaviour change. Guarded by the
  existing add-on rollout DB tests.
- **B.** Schema and Ash actions; kind filters on the add-on readers.
- **C.** Wasm adapter for manual and target-policy owners (task 3.4):
  generator hook, retraction handling, effective-package readers, health gate
  v1, revocation rollback.
- **D.** Agent-side result provenance and loaded-hash reporting (in parallel
  with C).
- **E.** Trigger from tracking owners (task 3.5; needs tasks 2.1-2.3).
- **F.** Credential-rule owners through owner state (task 3.6).
- **G.** Bulk "Upgrade to latest" preview and execution (task 3.7), reusing the
  kind-agnostic rollout UI.

A related, pre-existing inconsistency is tracked separately in #5835. Per-owner
coexistence in `AssignmentOwner` conflicts with the
`one_enabled_per_edge_plugin` unique index and with `uniq_by` in config
delivery.

### Decision 5: Bulk upgrade goes through rollouts too

"Upgrade to latest" (per plugin, and "upgrade all plugins") targets the pinned
owners the operator selects. It shows a preview grouped by owner:
- compatible;
- incompatible (the config fails the new schema, or a capability is outside the
  approved grant);
- unavailable agent;
- already current.

Executing the preview creates rollouts. It does not issue raw updates. The
per-row Upgrade / Change version controls are replaced by "Pin to version"
(Versions list) and "Track latest" toggles.

### Decision 6: No silent disables; owner status is first-class

The reconciler and rollout coordinator never disable an enabled assignment
without a recorded reason. Every owner (rule, policy, manual row) gets a status
with a stable reason code:
- `ok`
- `targets_unresolved` (from `fix-plugin-assignment-empty-target-retraction`)
- `incompatible_config`
- `awaiting_review`
- `health_gate_failed`
- `rolled_back`

These codes surface on the plugin row, in the plugin detail and on the owning
rule or policy page. Disables that are intended (an operator removes or disables
an owner, a package is revoked) record the actor and reason.

### Decision 7: Page decomposition and performance

The monolith splits into:
- `Plugins.InstalledLive`
- `Plugins.UpdatesLive`
- `Plugins.CatalogLive`
- `Plugins.ShowLive`

They share function components. Rules:
- No database or GitHub work in the disconnected mount.
- GitHub catalog fetches run in `start_async` / Oban, never synchronously in
  `handle_info`.
- Lists use streams with server-side pagination; the 100-row package cap goes
  away.
- Each tab registers as a Settings catalog view (`redesign-settings-catalog-nav`).

## Risks / Trade-offs

- **Auto-approval widens what reaches agents without a human.** This is
  mitigated by the strict subset rule, signature and provenance verification,
  first-party only, an audit trail, and a kill switch.
- **Moving credential-rule owners onto rollouts changes a behaviour some
  deployments may rely on (instant float).** This is mitigated by a default
  rollout policy with one batch and a short soak, so it behaves close to today
  while still gaining rollback.
- **Generalizing `AddonRollout` touches active add-on code**
  (`add-native-addon-fleet-rollouts` is in progress). Sequence this after that
  change's coordinator lands, or coordinate with its owner.

## Migration Plan

1. Schema: add `update_policy` (default `pinned`) and `update_policy_source`
   to assignments and target policies, plus the rollout artifact kind. Rows
   that exist at migration time are marked `migration_default`; new rows and
   every later operator action record `operator`. Migrations are catalog-only
   (constant defaults), per startup-safety rules.
2. One-shot Oban backfill: manual and target-policy owners whose package is
   signed, verified `first_party` and whose `update_policy_source` is still
   `migration_default` become `track_latest_approved`. Everything else stays
   as it is. It runs in bounded, skip-locked batches and re-checks
   `migration_default` inside each batch, so an operator pin made before or
   during the backfill is never overwritten. Expose a one-click "Pin" before
   enabling automatic rollouts, as add-on Decision 1 does.
3. Ship the new UI behind the Settings catalog with the old route redirecting.
   Remove the old LiveView once the new tabs cover every action.
4. Enable auto-approval and automatic rollouts. Before enabling, report
   "N assignments behind latest" so the first fleet movement is anticipated.

## Open Questions

- Should credential-rule owners keep instant float as an option
  (`rollout_policy: immediate`), or always roll out in batches?
- What health signal gates a plugin rollout? Plugin result freshness plus status
  per assignment is the proposal. Do action-only plugins (no service identity)
  get a "first successful run" gate instead?
