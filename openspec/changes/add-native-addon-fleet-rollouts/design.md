# Design: Native add-on fleet rollout policies

## Context

The current native add-on lifecycle is:

1. When first-party sync is enabled, discover signed official release-index entries
   and import each verified package version as staged. The optional
   `autoApproveAddonIds` allowlist approves only named trusted add-ons after import;
   every other imported version remains staged for operator review.
2. Review and approve the package and its narrowed capability grant. Approval makes
   that concrete version eligible for assignment; it does not deploy it or change an
   existing assignment.
3. Select that concrete package from a direct assignment or an add-on profile.
   Both source types persist a concrete package ID; profile reconciliation
   materializes concrete per-agent assignments from that profile selection.
4. Automatically deliver enabled assignments for approved packages through agent
   config whenever desired state changes.
5. Let each agent automatically reconcile the delivered assignment by downloading,
   verifying, staging, activating, supervising, and reporting the selected package.

Steps 4 and 5 are automatic after desired state changes. Step 2 intentionally does not
perform step 3. The missing layer is a safe mechanism that advances desired state
across many agents without changing every profile-derived assignment in one reconcile
cycle. The current fleet read model can calculate and display a newer approved version,
but no update policy consumes that value: there is no native add-on rollout controller,
canary/batch state machine, or health-gated latest-version tracking. Wasm plugin
assignment and scheduling remain a separate lifecycle and are not part of this model.

This proposal turns the existing latest-approved selection into a durable update policy
for trusted first-party native add-ons. A new assignment or profile backed by a signed,
verified first-party package defaults to managed tracking. Existing first-party sources
are migrated to that policy unless an explicit operator pin is recorded. Sources backed
by uploads, GitHub imports, or another non-first-party origin remain pinned by default.
The fleet's existing "up to date" badge remains a comparison; the rollout controller,
not the read model, advances desired state.

The current fleet read model compounds the ambiguity. Its attention flags treat every
enabled assignment without a status as `assigned_not_running`, every inactive status
as `stopped_or_inactive`, and every status without an assignment as
`observed_unassigned`. Those tests do not consider agent availability, observation
age, supervision model, an active request for an ephemeral helper, or rollout grace.

## Goals / Non-Goals

### Goals

- Keep trusted first-party native add-ons current without requiring an operator to
  notice and manually promote each approved release.
- Preserve explicit manual pins and conservative defaults for non-first-party sources.
- Preserve package approval as an eligibility and security boundary.
- Roll native add-ons through canaries and bounded batches with evidence-based health
  gates and deterministic rollback.
- Update direct assignments and profile-derived assignments without profile
  reconciliation defeating batch boundaries.
- Make every fleet summary count explainable from mutually exclusive row categories
  and stable reason codes.
- Treat disconnected/stale evidence, built-in observed-only components, and dormant
  ephemeral helpers according to their actual operational meaning.

### Non-Goals

- Automatically approve packages outside the existing first-party auto-approval
  allowlist or broaden an approved capability grant.
- Override an explicit operator version pin or automatically track non-first-party
  sources without an operator selecting that policy.
- Merge native add-on rollouts with base-agent release rollouts.
- Change Wasm plugin assignment upgrade semantics.
- Delete stale agent or status records as a side effect of presentation logic.
- Make Helm values the source of truth for per-agent add-on desired state.

## Decisions

### Decision 1: Trusted first-party sources track by default; explicit pins win

Each authoritative desired-state source (a direct assignment or an add-on profile)
has an update policy:

- `manual_pin`: keep the selected package until an authorized operator starts an
  upgrade or rollback. This is the default for upload/GitHub/non-first-party sources
  and for any source an operator explicitly pins.
- `track_latest_approved`: when a newer eligible package is approved, automatically
  create and start a rollout using the source's stored rollout policy. This is the
  default for new signed, verified first-party sources and for existing first-party
  sources that do not carry an explicit operator pin.

Approval only makes a package eligible. It never updates assignment package IDs in
the approval transaction. A track-latest reconciler observes the new eligible package
and creates an auditable rollout asynchronously for managed sources. This preserves a
reviewable security boundary while removing package-by-package deployment work. The
existing `autoApproveAddonIds` setting remains the allowlist for packages that may cross
the approval boundary without manual review; it does not bypass rollout eligibility or
health gates.

Post-bootstrap migration convergence derives the initial policy from package provenance
and explicit source intent. The schema migration marks only rows that already exist,
then a one-shot Oban worker drains those rows in bounded, skip-locked batches so fleet
size cannot block application startup or overwrite choices made after the migration.
A source selecting a signed, verified `first_party` package becomes
`track_latest_approved` unless an explicit operator pin is already recorded. A source
using an upload, GitHub import, unverifiable provenance, or a non-first-party package
becomes `manual_pin`. Because older rows do not distinguish a historical concrete
selection from an intentional pin, the migration SHALL record current first-party
sources as managed and expose a one-click pin before the rollout controller is enabled.

An eligible track candidate must have the same logical add-on ID, be signed, verified,
approved, not revoked, newer according to semantic version ordering, compatible with
the target platform and agent contract, and within the capability ceiling recorded on
the update policy. Prereleases and alternate channels are excluded unless the policy
explicitly selects that channel. A candidate that requires capabilities outside the
ceiling is blocked for operator review instead of silently widening privilege.

### Decision 2: Rollout overlays preserve stable source state during canaries

An `AddonRollout` records the logical add-on, previous and candidate packages,
authoritative source IDs, target snapshot, policy, lifecycle state, creator/trigger,
and audit timestamps. An `AddonRolloutTarget` records each materialized agent target,
its source, batch, prior desired package and params, effective desired override,
observation evidence, state transitions, and errors.

The selected package on a direct assignment or profile is the stable package. Advancing
a target installs a higher-precedence rollout override for only that materialized
agent/add-on pair. The config generator resolves the override while profile
reconciliation continues to preserve the stable source and target membership. This
prevents a profile package edit from bypassing the canary and updating every matched
agent at once.

When every required target for a source succeeds, the coordinator promotes the
candidate to that source's stable package and removes its rollout overrides. New
agents that join a dynamic profile after promotion receive the promoted package on
the next reconcile. If the rollout is canceled or rolled back, removing the override
restores the previous stable package without reconstructing intent from status rows.

Direct overrides keep their existing precedence over profile-derived desired state.
Profile rollout previews exclude directly overridden agents and explain why.

### Decision 3: Target membership is snapshotted and advancement is serialized

Starting a rollout snapshots eligible, incompatible, overridden, unavailable, and
unresolved targets. Only eligible targets enter delivery batches. Unavailable eligible
targets may remain pending until their target deadline; they do not pass a gate merely
because their last status was healthy. The operator can exclude unavailable targets
in the preview or wait for them to reconnect.

Only one active rollout may own an effective (agent, add-on) target at a time. Only one
track candidate may be active for an authoritative source. A newer approval that
arrives during a rollout is queued for evaluation after the current rollout reaches a
terminal state.

The stored policy includes canary size, batch size/max parallelism, soak duration,
target health timeout, and tolerated failures. Conservative platform defaults are one
canary, batches of at most ten, a five-minute soak, a fifteen-minute target timeout,
and zero tolerated failures. Operators may change these values before a manual rollout
or on a track policy, but a rollout always snapshots the values it started with.

### Decision 4: Health gates use fresh, model-specific readiness evidence

A target can pass only on evidence received after that target's rollout override and
config revision became effective. Pre-rollout or stale status never passes a gate.
The observation must remain successful for the configured soak period.

Readiness depends on supervision model:

- Continuous services (`agent-sidecar`, `systemd-service`) must report the candidate
  version installed, active, and healthy.
- Scheduled services (`systemd-timer`) must report the candidate version installed,
  enabled, and ready; they are not failed merely because no timer process is active
  between runs.
- `ephemeral-helper` packages must report the candidate version verified, staged, and
  registered for invocation. They are not required to be continuously active.
- `config-toggle` assignments must acknowledge successful application of the target
  config section and report the capability ready.

Artifact verification failures, permanent config-apply failures, unsupported runtime
models, explicit unhealthy status, wrong running version after convergence, and target
timeouts are failures. Disconnected or stale targets remain pending until their
deadline and then fail as unavailable; they are never counted as healthy.

The default gate requires every attempted target in the batch to pass. If a target
fails, the coordinator restores its previous desired package and params, marks it
rolled back when fresh evidence confirms recovery, pauses before the next batch, and
surfaces the failure. The operator may then rollback the entire rollout, fix and retry,
or explicitly resume under an amended policy. Track-latest records the failed candidate
as blocked for that source so the same package cannot immediately retrigger a loop.

Failure tolerance applies only to profile rollouts with multiple snapshotted targets.
After recovery is verified and an operator resumes, a rolled-back target within the
stored tolerance is converted to an explicit manual pin on its prior package before
the profile is promoted. Profile reconciliation therefore cannot immediately reapply
the failed candidate to that agent. Direct-assignment rollouts remain all-or-nothing.

### Decision 5: Fleet health is a precedence-ordered classification

The read model stores observation freshness, agent availability, management origin,
supervision model, expected activity, rollout state, and a stable reason code. Each
(agent, add-on) row receives exactly one summary category using this precedence:

1. `action_required`: explicit unhealthy/delivery/config/verification failure,
   incompatible desired assignment, failed rollout, or fresh persistent desired state
   that remains unconverged beyond its grace/timeout.
2. `updating`: an active rollout or fresh desired-state change is still inside its
   convergence window and has not failed.
3. `unavailable`: the agent is disconnected, has never reported the desired add-on,
   or the latest observation is older than the configured freshness window, with no
   independently known desired-state validation error.
4. `expected_inactive`: an `ephemeral-helper` is staged/ready but has no active
   invocation, or another model-specific idle state is explicitly normal.
5. `observed_only`: a runtime is reported without a managed desired assignment, such
   as a healthy built-in component. Lack of an assignment alone is informational.
6. `healthy`: fresh observed state matches managed desired state and model-specific
   readiness.

An explicit unhealthy status remains `action_required` even for an observed-only
runtime. An incompatible desired assignment is also actionable even if the target is
offline, because the desired-state error is already known. Otherwise, an offline
agent with an assignment is `unavailable`, not falsely "assigned, not running."

The observation freshness window is derived from the agent heartbeat/status cadence
with a configurable floor, rather than a hard-coded wall-clock constant. Rows retain
their last evidence timestamp and explanatory reason.

### Decision 6: Summary counters describe different operational questions

The fleet surface keeps one row per (agent, add-on), but its summary no longer treats
all rows as equivalent deployments. It exposes:

- Managed deployments: enabled desired assignments.
- Healthy/running: managed targets with fresh model-specific ready state.
- Updating: rollout or convergence in progress.
- Needs attention: only `action_required` rows.
- Unavailable/stale: evidence cannot establish runtime health.
- Expected inactive: dormant on-demand helpers.
- Observed only: components without managed desired state.

Every counter is a filter and every filtered row exposes its reason and evidence age.
Catalog inventory and staged package counts remain separate from fleet runtime health.

### Decision 7: Bulk upgrade mutates authoritative sources through rollouts

The add-on detail and fleet surfaces expose an "Upgrade assignments/profiles" action
for an approved candidate. Preview groups targets by authoritative direct assignment
or profile and shows compatible, incompatible, overridden, unavailable, ephemeral,
and already-current counts. Starting the action creates a rollout; it does not issue a
bulk update against materialized assignment rows.

The same surface lets an authorized operator choose manual pin or track-latest and set
the rollout policy. Package approval shows how many opted-in sources may discover the
package as a candidate, but approval and rollout remain separately audited operations.

## Risks / Trade-offs

- Rollout overrides add precedence to config generation and profile reconciliation.
  Mitigation: store stable source state separately, enforce one active target owner,
  and test profile reconciliation throughout a paused rollout.
- Old agents may not report enough detail for model-specific readiness. Mitigation:
  classify them as `unavailable` or `updating/unknown`, never healthy by assumption;
  require the richer status contract before enabling automatic track-latest for them.
- Offline agents can hold a rollout open. Mitigation: preview them separately, use a
  target deadline, and require an explicit operator choice to exclude or retry them.
- Automatic updates of privileged native code increase blast radius. Mitigation:
  only signed, verified, approved candidates from the same trusted first-party lineage
  track by default; explicit pins always win; candidates must be compatible and within
  a capability ceiling; canary and health gates cannot be disabled for track-latest.
- A bad health classifier could stop or advance a rollout incorrectly. Mitigation:
  persist raw evidence beside the derived category and cover every delivery/supervision
  model with contract and state-machine tests.

## Migration Plan

1. Add rollout/update-policy schema. Mark pre-existing rows for asynchronous,
   post-bootstrap convergence; backfill signed, verified first-party sources to
   `track_latest_approved` in bounded batches, leave non-first-party sources on
   `manual_pin`, preserve every selected package, and expose an explicit pin control
   before enabling rollout.
2. Add the enriched fleet classification and counters in read-only mode, compare old
   and new summaries in telemetry, then switch the UI to categorized semantics.
3. Enable manual bulk rollouts with canary, batch, health gate, and rollback support.
4. Validate mixed agent versions and each supervision model in a demo cohort.
5. Enable automatic reconciliation for managed first-party sources only after manual
   rollout verification is complete; keep non-first-party sources and explicit pins
   out of automatic reconciliation.

Rollback of the feature pauses active rollouts, removes unpromoted target overrides,
restores stable pins, and disables track reconciliation. Stable source package IDs are
never discarded, so disabling the coordinator does not require reconstructing desired
state from observed status.

## Open Questions

- Should the first release expose a tenant-wide emergency switch that pauses creation
  of new automatic rollouts while preserving each source's stored update policy?
