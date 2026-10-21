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
kind (`native_addon | wasm_plugin`), not to build a second coordinator. If the
generalization proves too invasive, a parallel `PluginRollout` with the same
state machine is the fallback; tasks 3.x decide this after a spike.

**Target membership:**
- **Manual tracking rows:** each row is a target.
- **Target-policy owners:** the policy's materialized assignments, advanced by a
  per-target override and then promoted to the policy's stable package
  (add-on Decision 2).
- **Credential-rule owners:** already resolve the latest package on reconcile.
  They are switched to resolve through the rollout's stable/candidate overlay,
  so they move in batches like everyone else instead of all at once.

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

1. Schema: add `update_policy` (default `pinned`) to assignments and target
   policies, plus the rollout artifact kind or new rollout tables. Migrations
   are catalog-only (constant defaults), per startup-safety rules.
2. One-shot Oban backfill: manual and target-policy owners whose package is
   signed, verified `first_party` become `track_latest_approved`. Everything
   else stays `pinned`. It runs in bounded, skip-locked batches. Expose a
   one-click "Pin" before enabling automatic rollouts, as add-on Decision 1
   does.
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
- Where should capacity live long-term: the agent detail page only, or also a
  fleet capacity view in Installed?
