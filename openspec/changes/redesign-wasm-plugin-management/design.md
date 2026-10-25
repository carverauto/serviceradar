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
  content_hash}` on each pushed result, and that host-stamped provenance is
  the only evidence that a result came from the candidate. The gate passes a
  target as verified only on a fresh result whose provenance matches the
  candidate. Time ordering is not version evidence: results from the old
  package can still be flushed from `pendingPluginResults` after the agent
  acknowledges the candidate config. Targets on agents that do not send
  provenance can pass only through the snapshotted `on_no_evidence` policy
  (default: pass after soak), recorded with reason code `no_version_evidence`
  and never shown as verified healthy. An explicit failure still rolls the
  target back.
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
- **Action-only plugins.** These pass as verified only on a successful
  invocation whose dispatch record shows the candidate package and that was
  dispatched after the agent acknowledged the candidate config. An action
  invoked earlier can still run the old assignment. Without such an
  invocation, the same `on_no_evidence` policy applies, recorded as
  `no_version_evidence`. Step C did not build command-based verification;
  see "Step C as built" below.

**Implementation steps:**
- **A.** Engine/adapter split, with no behaviour change. Guarded by the
  existing add-on rollout DB tests.
- **B.** Schema and Ash actions; kind filters on the add-on readers.
- **C.** Wasm adapter for manual and target-policy owners (task 3.4):
  generator hook, retraction handling, effective-package readers, health gate
  v1, revocation rollback. Until D ships, every target passes only through
  `on_no_evidence` as `no_version_evidence`.
- **D.** Agent-side result provenance (in parallel with C).
- **E.** Trigger from tracking owners (task 3.5; needs tasks 2.1-2.3).
- **F.** Credential-rule owners through owner state (task 3.6).
- **G.** Bulk "Upgrade to latest" preview and execution (task 3.7), reusing the
  kind-agnostic rollout UI.

**Step C as built** (`WasmPluginRolloutArtifact`):
- The coordinator reads every package pair, member pointer and evidence key
  through the implementation, since each family keeps them in its own columns.
- A failed Wasm target rolls the whole rollout back. With
  `tolerated_failures` fixed at 0 a failure always ends the rollout, and a
  pause would leave the other targets on the candidate with no rollout to clear
  them. Add-on targets still pause.
- Health classification of a provenance-stamped result: `OK`, `WARNING` and
  `CRITICAL` mean the plugin ran (a critical target is not a failed plugin);
  `UNKNOWN`, failed downstream ingest or another module's hash is a failure.
  Results are classified per observation: a downstream-ingest row carries its
  observation's timestamp and payload digest, and the latest one decides that
  observation regardless of row order (a failure fails it, a later recovery
  restores it). Freshness and order use the reported row's server receipt time.
- The ingestor writes a downstream-ingest row only on failure or recovery; an
  ordinary success writes none. It runs the handlers synchronously right after
  the reported row commits, so a failure row lands within seconds. An
  observation without one counts as ingested only once its reported row was
  received at least 60 seconds before the evidence read; a younger one is
  pending. The newest failed or settled observation decides, passing over
  pending ones, so a plugin reporting faster than the settle period is judged
  by its settled results; a failure counts at once whatever its age, and a
  pending observation never counts as absent evidence.
- Action-only plugins that ingest their action results are verified through
  those stamped results. Action-only plugins without result ingest pass only
  through `on_no_evidence` as `no_version_evidence`. A completed
  `plugin.run_action` command is not evidence: a config acknowledgement time
  cannot prove which package ran the action, so binding an invocation to the
  candidate needs host provenance on command results (a follow-up).
- A failed evidence read is not an empty one. Targets it covers neither pass,
  fail, recover nor converge; they wait and eventually time out.
- An agent that stamps its results, but only for the previous package, gets no
  `on_no_evidence` pass: it has not loaded the candidate, and times out.
- A rollout that is rolling back ends as `rolled_back` even when no target was
  left to recover, instead of falling through to promotion.
- Revocation rolls back inside the revoke transaction. Disabling an assignment
  by any path (owner retraction, reconcile, operator) clears its override and
  cancels every target holding it.
- A rollout whose every target was canceled (member disabled, retracted or
  deleted) or excluded before any target ran the candidate ends `canceled`
  with `every_target_canceled`. It never promotes: nothing proved the
  candidate, and promoting would move a disabled owner's stable package to it.
  A source with no targets at all still promotes, as before.

**Step E as built** (task 3.5, `WasmPluginRolloutArtifact.managed_sources/1`):
- The trigger is level-based, not an approval hook. The rollout reconcile
  (`AddonRolloutWorker`, every 30 seconds) asks `managed_sources/1` for every
  enabled manual assignment and target policy whose `update_policy` is
  `track_latest_approved` and whose stable package is behind the newest
  eligible package, and starts a `:track_latest` rollout for each. That covers
  an operator approval, a first-party auto-approval, a sync re-run, a restart,
  and an owner switched to tracking after the approval, with no event to lose.
- Pinned owners are never returned. Credential-rule owners are `source:
  :policy` assignment rows, so they are not returned either; step F moves them.
- Eligibility: approved, same `plugin_id`, newer, a stable release, ordered by
  `LatestApprovedPluginPackage` (`AddonRolloutEligibility` now orders every
  artifact's candidates by it, which for add-ons changes only how
  semver-equal packages tie). Prereleases follow "excluded unless selected":
  automatic tracking skips them, and an explicit `start/3` (any trigger other
  than `:track_latest`) may select one
  (`RolloutArtifact.explicit_selection_ignores_channel?/0`, true for Wasm,
  false for add-ons, whose `release_channel` governs explicit upgrades). The
  credential-rule materializer still resolves through the unfiltered
  resolver, so it can float to an approved prerelease until step F.
- Idempotent by construction: one active rollout per source (the coordinator
  skips a source that has one, and `addon_rollouts_one_active_source_index`
  backs it), approving an approved package is refused by the state machine,
  and a completed rollout leaves the owner on the candidate, no longer behind.
- An owner with an in-flight rollout when a newer package is approved keeps
  the add-on supersede semantics: a running rollout finishes first and the
  owner moves on to the newer package on a later pass; a paused one is
  superseded (`newer_candidate_approved`) by a rollout to the newer package.
  A rolled-back candidate stays blocked for the owner; a newer one is not.
- Automatic rollouts are on by default. `SERVICERADAR_WASM_PLUGIN_AUTOMATIC_ROLLOUTS`
  (chart value `core.wasmPluginAutomaticRollouts`, rendered on core and
  web-ng, which both run the `integrations` queue that executes the reconcile)
  or `config :serviceradar_core, :wasm_plugin_automatic_rollouts, false`
  turns them off. The auto-approval kill switch (task 3.1) gates approval
  only, so it does not apply here. Rollouts an operator starts run either way.
  Step E first shipped them off, pending Migration Plan step 4. Nothing turned
  them on: the setting lived only in `serviceradar_core`'s own `config.exs`,
  which neither release loads, and the chart rendered no value. So every
  tracking owner, including the ones the update-policy backfill converted,
  stayed on its package after a newer one was approved, contrary to the
  "Tracking owner after a new approval" scenario. Owners that were already
  behind need no catch-up job: the level-triggered reconcile starts their
  rollouts on its first pass after the upgrade. The fleet summary (task 1.1)
  already shows how many owners are behind latest. Until the per-owner control
  (task 2.5) ships, pinning an owner means writing `update_policy: pinned`
  (task 2.2), and the setting above holds back every owner at once.
- Every rollout audit event carries `trigger` and `automatic` (true for
  `:track_latest`), for add-ons too.
- A source deleted during its rollout cancels the rollout on the next advance,
  whether it is running or paused, with `source_deleted`, instead of leaving it
  active for a source no reconcile revisits.
  Wasm does not refuse the delete the way add-ons do
  (`NotHeldByActiveRollout`): a disable already releases rollout holds rather
  than refusing (step C), a target policy's destroy retracts its members before
  the row goes, and only the coordinator sees every way a source disappears.

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
   during the backfill is never overwritten. The one-click Pin (task 2.5) is
   still unshipped. Automatic rollouts already ship on; until that control
   exists, see "Step E as built" for how an operator holds owners back.
3. Ship the new UI behind the Settings catalog with the old route redirecting.
   Remove the old LiveView once the new tabs cover every action.
4. Auto-approval and automatic rollouts ship enabled. The Installed tab
   reports how many assignments are behind latest, so the first fleet
   movement is anticipated. Each has a deployment kill switch (see "Step E
   as built").

## Open Questions

- Should credential-rule owners keep instant float as an option
  (`rollout_policy: immediate`), or always roll out in batches?
- What health signal gates a plugin rollout? Plugin result freshness plus status
  per assignment is the proposal. Do action-only plugins (no service identity)
  get a "first successful run" gate instead?
