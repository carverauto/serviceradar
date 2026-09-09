## Context

Confirmed via the library's docs (`ash-events.hexdocs.pm`, `~> 0.7.0`,
compatible with this repo's Ash `~> 3.31.3`):

- **Event log resource**: a plain Ash resource using the
  `AshEvents.EventLog` extension, configured via an `event_log do end`
  block: `clear_records_for_replay` (a module implementing the clear-before-
  replay callback), `primary_key_type`, `record_id_type`, and one or more
  `persist_actor_primary_key :field, ActorResource` entries (supports
  multiple actor types — useful here since actions may run as an
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
  single, queryable-by-actor-or-resource-or-time table — the "what did this
  actor do, across everything, in order" shape that motivated picking this
  over PaperTrail's per-resource versions tables.
- **Actor capture**: same mechanism this session already confirmed for
  `/api/v2/*` generally — an OAuth2 client-credentials bearer token resolves
  to the real `%ServiceRadar.Identity.User{}` via `Guardian.verify_token` →
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
  is recorded for whatever action actually ran, after policy checks passed —
  it observes, it doesn't gate. No conflict with `PresetRuleResource`'s
  existing `operator_action([:create, :update, :destroy])` policy.
- **Migration**: no hand-written Ecto migration — this repo's established
  `mix ash.codegen`/`mix ash.migrate` workflow (documented in
  `AGENTS.md`/`project.md`) generates it the same way every other Ash
  resource's schema is generated here.

## Goals / Non-Goals

**Goals**
- One centralized, actor-keyed, chronologically-queryable log of every
  mutation made to `StatefulAlertRule`, regardless of whether it came from
  the web UI or the new `/api/v2/stateful-alert-rules` route.
- Establish AshEvents as the pattern future JSON:API-exposed *mutable*
  resources adopt, without disturbing the 9 resources already on
  AshPaperTrail or the in-flight `add-audit-history-page` work.

**Non-Goals**
- Migrating the 9 existing AshPaperTrail resources to AshEvents. Two audit
  mechanisms coexisting, scoped to different resource populations
  (PaperTrail: the 9 existing; AshEvents: new API-first resources going
  forward, starting with `StatefulAlertRule`), is the accepted state — not
  a transitional step toward consolidating on one.
- Wiring AshEvents onto the 19 read-only Observability resources
  `add-alert-rule-json-api` also activates. They're `index :read`-only;
  nothing mutates through them, so there's nothing for an event log to
  record. Revisit only if any of them ever grow a write action.
- Building replay tooling or a point-in-time reconstruction UI. Confirmed
  the mechanism supports it; not part of this change's scope.
- A general-purpose "audit everything" mandate. This change is scoped to
  the resource `add-alert-rule-json-api` is putting behind a new API
  surface; broadening AshEvents adoption further is a separate decision for
  whoever owns that resource next.

## Decisions

- **AshEvents for new API-first resources, AshPaperTrail stays for the
  existing 9.** Two mechanisms, cleanly partitioned by which resources use
  which — not a redundant overlap, since no resource is on both.
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
  able to filter `ApiEvent` rows down to API-originated changes — not just
  "any change to this resource" — is the difference between this actually
  answering that question and merely being AshPaperTrail with extra steps.
  Implementation: a changeset context value set by the JSON:API controller
  path (present) vs. absent (LiveView path), read by an `Ash.Resource.Change`
  on `StatefulAlertRule`'s create/update/destroy actions that writes it into
  `metadata`.

## Risks / Trade-offs

- Two audit mechanisms in one codebase (PaperTrail + AshEvents) is real
  cognitive overhead for whoever next builds an audit-relevant feature —
  they now have to know which one a given resource uses. Mitigated by
  documenting the boundary explicitly (this file, plus a doc comment on
  `ApiEvent` itself) rather than leaving it implicit.
- `add-audit-history-page`'s in-flight UI (10/15 tasks) is built around
  AshPaperTrail's `versions_read` action shape. This change's audit surface
  either needs its own small view or a follow-up to that page to also query
  `ApiEvent` — decide based on which change lands first (tasks.md).

## Migration Plan

1. Add the `ash_events` dependency; run `mix deps.get`.
2. Create `ServiceRadar.Observability.ApiEvent` (the event log resource) and
   its `ClearForReplay` implementation; register it in the `Observability`
   domain.
3. `mix ash.codegen add_api_event_log`; `mix ash.migrate`.
4. Add `AshEvents.Events` + `events do end` to `stateful_alert_rule.ex`.
5. Confirm (via test) that creating/updating/destroying a `StatefulAlertRule`
   — through either the existing LiveView or the new JSON:API route from
   `add-alert-rule-json-api` — writes exactly one `ApiEvent` row with the
   correct actor.
6. Ship a minimal list view (Settings → Audit → API Events, or an addition
   to History if `add-audit-history-page` has landed by then).

## Open Questions

- Does `add-audit-history-page` land before or after this change? If
  before, extend its History view to also merge `ApiEvent`; if after, that
  page's own resource-discovery config (mentioned in its proposal) should
  probably learn about AshEvents-backed resources too, not just
  AshPaperTrail ones — flag to whoever picks up whichever lands second.
