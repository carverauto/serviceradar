# Retire superseded agent identities

## Why

A host that re-enrolls under a different agent uid resolves to the same device, but its
previous `ocsf_agents` row stays behind forever: rows are never deleted, and the previous
identity stays a first-class agent. `in:agents` returns it, every add-on profile that targets
`in:agents` assigns it, and a rollout that waits for it to report never finishes. One such
phantom froze managed add-on updates across a fleet for 19 days (#4456).

Re-enrollment already had a retirement path, but it marked the old identity `unavailable`, a
status that `in:agents` and rollout targeting still include. It also skipped identities that
were already `unavailable` (the stale-agent pruner had usually got there first), and it
matched identities by address as well as by device, which retires a different host behind the
same NAT address.

## What Changes

- New agent status `superseded`, with `superseded_by` (the replacing uid) and `superseded_at`.
  Only `:supersede` enters it and only `:revive_superseded` leaves it; the
  `:register_connected` upsert refuses to write over a superseded row.
- When an agent checks in, every other identity linked to the same `device_uid` is
  superseded, unless it is still live (connected and heartbeating within the StateMonitor
  agent timeout). Address and hostname matches no longer retire an identity.
- An hourly sweep (run by `PruneStaleAgentsWorker`) supersedes the identities that the
  most recently seen identity on each device replaced and that are no longer live. It is the
  backfill for existing phantoms and catches replacements that enrolled while the old
  identity still looked live. It is idempotent.
- A superseded identity that reports in again is revived explicitly.
- Every supersession, every live identity kept and every revival is recorded in
  `platform.identity_decisions` under the new `agent_supersession` kind.
- SRQL `in:agents` excludes superseded identities by default. `include_deleted:true` or a
  `status` / `superseded_by` filter returns them. The agent detail page still loads a
  superseded identity.
- Add-on rollouts do not target superseded agents; the profile reconciler skips them with
  `superseded_agent`.

## Impact

- Affected specs: `agent-registry`.
- Affected code: `Infrastructure.Agent`, new `Infrastructure.AgentSupersession`,
  `Edge.AgentGatewaySync`, `Jobs.PruneStaleAgentsWorker`, `Plugins.AddonRolloutCoordinator`,
  `Plugins.AddonProfileReconciler`, `Inventory.IdentityDecision`, `rust/srql` agents query,
  web-ng SRQL catalog and agent detail page.
- Migration: `ocsf_agents.superseded_by`, `ocsf_agents.superseded_at`, and a partial index
  on `device_uid` for identities that are not superseded. No data rewrite in the migration.
