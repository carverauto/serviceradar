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
- **Actor capture**: the actor shape, metadata fallback, and requirement to
  supply the actor at changeset construction are owned by
  [StampEventSource's module documentation](../../../elixir/serviceradar_core/lib/serviceradar/observability/changes/stamp_event_source.ex).
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
- **Migration**: this change uses the hand-written
  `20260909100000_add_api_event_log.exs` migration. The codegen limitation
  is tracked in [Platform Security Hardening](../../../docs/PLATFORM_SECURITY_HARDENING.md#6-known-follow-ups).
  Apply it using the root `AGENTS.md` database migration guidance.

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
- **Distinguish API-originated mutations.** The source metadata contract
  is owned by
  [StampEventSource](../../../elixir/serviceradar_core/lib/serviceradar/observability/changes/stamp_event_source.ex).

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
3. Apply the committed migration as described in Context above.
4. Add `AshEvents.Events` + `events do end` to `stateful_alert_rule.ex`.
5. Confirm (via test) that creating/updating/destroying a `StatefulAlertRule`
   -- through either the existing LiveView or the new JSON:API route from
   `add-alert-rule-json-api` -- writes exactly one `ApiEvent` row with the
   correct actor.
6. Ship the audit list integration described in Decisions.
