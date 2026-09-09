## Context

The existing audit UI is `Settings.AuditLive.History`, registered at
`/settings/audit/history` in `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`.
`ServiceRadar.Security.AuditHistory.resources/0` owns its configurable
PaperTrail resource allow-list; it is not an inventory of every resource
using `AshPaperTrail.Resource`. See `add-audit-history-page/tasks.md` for
that change's remaining work.

Confirmed via the library's docs (`ash-events.hexdocs.pm`, `~> 0.7.0`,
compatible with this repo's Ash `~> 3.31.3`):

- **Event log resource**: a plain Ash resource using the
  `AshEvents.EventLog` extension, configured via an `event_log do end`
  block: `clear_records_for_replay` (a module implementing the clear-before-
  replay callback), `primary_key_type`, `record_id_type`, and one or more
  `persist_actor_primary_key :field, ActorResource` entries (supports
  multiple actor types -- useful here since actions may run as an
  interactive user, an API-token-authenticated user, or `system_actor()` in
  tests/background jobs).
- **Per-resource opt-in**: the target resource (`StatefulAlertRule`) adds
  `AshEvents.Events` to its `extensions:` list and an
  `events do event_log ServiceRadar.Observability.ApiEvent end` block,
  optionally `ignore_actions [...]` and `current_action_versions
  create: N, ...` for schema evolution over time.
- **Event shape**: `resource`, `record_id`, `action`, `action_type`,
  the actor's persisted key (e.g. `user_id`), `data` (raw action input),
  `changed_attributes`, `metadata`, `version`, `occurred_at`. This is a
  single, queryable-by-actor-or-resource-or-time table -- the "what did this
  actor do, across everything, in order" shape that motivated picking this
  over PaperTrail's per-resource versions tables.
- **Actor capture**: the existing authentication mechanism for
  `/api/v2/*` generally -- an OAuth2 client-credentials bearer token resolves
  to the real `%ServiceRadar.Identity.User{}` via `Guardian.verify_token` ->
  `set_ash_actor`, and that's the `actor:` Ash sees on the changeset. AshEvents
  persists whatever `persist_actor_primary_key` names, so `user_id` is
  populated correctly for both interactive-session and API-token-driven
  requests with zero special-casing needed for the new API surface.
- **Replay**: `Ash.ActionInput.for_action(:replay, %{})` on the event log
  resource, filterable by `last_event_id`/`point_in_time`; lifecycle hooks
  are skipped during replay to avoid side effects. Not a goal of this
  change (see Non-Goals) but confirms the mechanism is sound if ever wanted
  for `StatefulAlertRule` (e.g. reconstructing rule state at a point in
  time for an incident review).
- **Authorization interaction**: AshEvents wraps action execution as an
  extension; it does not replace or bypass `Ash.Policy.Authorizer`. An event
  is recorded for whatever action actually ran, after policy checks passed --
  it observes, it doesn't gate. No conflict with `PresetRuleResource`'s
  existing `operator_action([:create, :update, :destroy])` policy.
- **Migration**: no hand-written Ecto migration -- this repo's established
  `mix ash.codegen` generates the schema migration. Apply it using the
  database migration command owned by the root `AGENTS.md` Build & Test
  Commands section.

## Goals / Non-Goals

**Goals**
- One centralized, actor-keyed, chronologically-queryable log of every
  mutation made to `StatefulAlertRule`, regardless of whether it came from
  the web UI or the new `/api/v2/stateful-alert-rules` route.
- Establish AshEvents as the pattern future JSON:API-exposed *mutable*
  resources adopt, under the adoption boundary in Decisions below.

**Non-Goals**
- Migrating existing PaperTrail resources; see the adoption boundary below.
- Wiring other Observability resources into AshEvents. The sibling API
  proposal owns their route scope; this change opts in only `StatefulAlertRule`.
- Building replay tooling or a point-in-time reconstruction UI. Confirmed
  the mechanism supports it; not part of this change's scope.
- A general-purpose "audit everything" mandate. This change is scoped to
  the resource `add-alert-rule-json-api` is putting behind a new API
  surface; broadening AshEvents adoption further is a separate decision for
  whoever owns that resource next.

## Decisions

- **Extend the existing History view.** Merge `ApiEvent` rows alongside
  PaperTrail versions under Settings Audit. Display actor, resource, action,
  source, `occurred_at`, and the `data`/`changed_attributes` maps, preserving
  existing history and access controls.

- **AshEvents for new API-first resources, AshPaperTrail stays for the
  existing resources.** Keep both mechanisms for their respective resource
  populations; this is not a migration toward replacing PaperTrail.
- **A single shared `ApiEvent` event log**, not one event-log resource per
  API-exposed resource. AshEvents' own model is centralized-by-design (one
  event log can record events from multiple source resources); splitting it
  per-resource would defeat the "one place to query everything" property
  that motivated choosing this over PaperTrail.
- **`StatefulAlertRule` is the only resource wired up in this change.** It's
  the resource the motivating API surface (`add-alert-rule-json-api`)
  exposes; wiring up unrelated resources speculatively is scope creep.
- **Stamp `metadata["source"]` with the request transport** (`"api"` vs.
  `"web"`), following AshEvents' own documented `metadata` example
  (`%{"source" => "api", "request_id" => "req-abc123"}`). Since the stated
  motivation is specifically "audit logs when people are using APIs," being
  able to filter `ApiEvent` rows down to API-originated changes -- not just
  "any change to this resource" -- is the difference between this actually
  answering that question and merely being AshPaperTrail with extra steps.
  Implementation: a changeset context value set by the JSON:API controller
  path (present) vs. absent (LiveView path), read by an `Ash.Resource.Change`
  on `StatefulAlertRule`'s create/update/destroy actions that writes it into
  `metadata`.

## Risks / Trade-offs

- Two audit mechanisms in one codebase (PaperTrail + AshEvents) is real
  cognitive overhead for whoever next builds an audit-relevant feature --
  they now have to know which one a given resource uses. Mitigated by
  keeping the adoption decision here until it becomes an archived spec;
  implementation documentation should point to that owner.
- The existing History view uses PaperTrail's `versions_read` action shape.
  Integrating `ApiEvent` requires a separate query path; extending the list
  must preserve existing PaperTrail history and access controls.

## Migration Plan

1. Add the `ash_events` dependency; run `mix deps.get`.
2. Create `ServiceRadar.Observability.ApiEvent` (the event log resource) and
   its `ClearForReplay` implementation; register it in the `Observability`
   domain.
3. `mix ash.codegen add_api_event_log`; apply the generated migration using
   the root `AGENTS.md` database migration guidance.
4. Add `AshEvents.Events` + `events do end` to `stateful_alert_rule.ex`.
5. Confirm (via test) that creating/updating/destroying a `StatefulAlertRule`
   -- through either the existing LiveView or the new JSON:API route from
   `add-alert-rule-json-api` -- writes exactly one `ApiEvent` row with the
   correct actor.
6. Ship the audit list integration described in Decisions.
