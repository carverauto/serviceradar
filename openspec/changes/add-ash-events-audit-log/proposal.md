# Adopt AshEvents for a centralized API audit log

## Why

Closes [#276](https://github.com/carverauto/serviceradar/issues/276)
("chore: use AshEvents -- Evaluate AshEvents to improve auditing of operator
actions").

The separately scoped `add-alert-rule-json-api` proposal motivates an audit
trail for mutations to `StatefulAlertRule` over JSON:API. That proposal owns
the API route scope; confirm its final contract when integrating it.

The codebase already uses AshPaperTrail for per-resource version history.
See [design.md](design.md#context) for the existing audit surface and
[adoption decision](design.md#decisions) for how this proposal coexists with it.

This proposal chooses **AshEvents** -- a different model: a single centralized,
replayable event log across every opted-in resource and action, keyed by
actor, rather than a per-resource versions table. That fits "audit logs for
API usage" more directly: one place to query "what did this actor do,
across every resource, in what order" -- which is exactly the shape of
question an API audit trail needs to answer, and which PaperTrail's
per-resource tables don't answer without joining N tables.

## What Changes

- Add `{:ash_events, "~> 0.7.0"}` to `elixir/serviceradar_core/mix.exs`.
- Add a new centralized event-log resource,
  `ServiceRadar.Observability.ApiEvent`, using the `AshEvents.EventLog`
  extension:
  ```elixir
  event_log do
    clear_records_for_replay ServiceRadar.Observability.ApiEvent.ClearForReplay
    primary_key_type Ash.Type.UUIDv7
    record_id_type :uuid
    persist_actor_primary_key :user_id, ServiceRadar.Identity.User
  end
  ```
  registered in the `ServiceRadar.Observability` domain, with its own
  Ash-codegen migration (per this repo's established `mix ash.codegen`
  workflow -- no hand-written Ecto migration).
- Opt `StatefulAlertRule` into it via the `AshEvents.Events` extension and an
  `events do event_log ServiceRadar.Observability.ApiEvent end` block --
  the first (and, for this change, only) resource wired up, since it's the
  resource `add-alert-rule-json-api` is putting behind a new API surface.
- Extend the audit surface with an `ApiEvent` list, following the integration
  decision in [design.md](design.md#decisions).
- Apply the adoption boundary defined in [design.md](design.md#decisions).

## Impact

- Affected specs: `ash-events-audit-log` (new capability).
- Affected code:
  - `elixir/serviceradar_core/mix.exs` (new dependency)
  - `elixir/serviceradar_core/lib/serviceradar/observability/api_event.ex`
    (new event-log resource) and a `ClearForReplay` implementation
  - `elixir/serviceradar_core/lib/serviceradar/observability/stateful_alert_rule.ex`
    (`AshEvents.Events` extension + `events do end` block)
  - `elixir/serviceradar_core/lib/serviceradar/observability.ex` (register
    `ApiEvent` in the domain's `resources do end`)
  - A new Ash-codegen migration for the `api_events` table
  - An audit-log list view integrated with the existing audit surface
- Depends on `add-alert-rule-json-api` for `StatefulAlertRule` actually being
  reachable over `/api/v2/*` -- this change is about auditing that surface,
  not a prerequisite for it. Order doesn't strictly matter (AshEvents records
  actions regardless of transport, so it works before the JSON:API mount
  lands too), but the motivating use case is that API surface.
- Existing resource audit extensions remain governed by the adoption boundary
  in [design.md](design.md#decisions).
