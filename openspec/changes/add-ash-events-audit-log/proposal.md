# Adopt AshEvents for a centralized API audit log

## Why

Closes [#276](https://github.com/carverauto/serviceradar/issues/276)
("chore: use AshEvents — Evaluate AshEvents to improve auditing of operator
actions").

`add-alert-rule-json-api` (same session) exposes `StatefulAlertRule` — and,
as a forced side effect of how Ash's JSON:API router mounts, 19 other
Observability resources — over `/api/v2/*` for the first time. Immediately
after scoping that, the question came up: how do we get an audit trail of
who used these APIs and what they did?

The codebase already has an audit mechanism, **AshPaperTrail**
(`ash_paper_trail ~> 0.6.0`), adopted on 9 resources today
(`NetworkCredentialSecret`, `NetworkCredentialRule`,
`ProxmoxConsoleSession`, the four Ansible automation resources,
`AuthLockout`), with a UI in flight to surface it
(`add-audit-history-page`, 10/15 tasks) — each PaperTrail-enabled resource
writes a `<table>_versions` row per create/update/destroy with a
before/after diff.

Offered PaperTrail-extension as the default recommendation, but the choice
was **AshEvents** instead — a different model: a single centralized,
replayable event log across every opted-in resource and action, keyed by
actor, rather than a per-resource versions table. That fits "audit logs for
API usage" more directly: one place to query "what did this actor do,
across every resource, in what order" — which is exactly the shape of
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
  workflow — no hand-written Ecto migration).
- Opt `StatefulAlertRule` into it via the `AshEvents.Events` extension and an
  `events do event_log ServiceRadar.Observability.ApiEvent end` block —
  the first (and, for this change, only) resource wired up, since it's the
  resource `add-alert-rule-json-api` is putting behind a new API surface.
- Add a minimal Settings → Audit surface (or extend the existing
  `add-audit-history-page` History view, if that change has landed by the
  time this one is implemented) to list `ApiEvent` rows: actor, resource,
  action, `occurred_at`, and the `data`/`changed_attributes` maps.
- Document the adoption boundary explicitly (see Decisions): AshEvents is
  for resources newly exposed over JSON:API going forward; it does not
  replace PaperTrail on the 9 resources already using it.

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
  - A minimal audit-log list view (new or folded into
    `add-audit-history-page` if that's landed)
- Depends on `add-alert-rule-json-api` for `StatefulAlertRule` actually being
  reachable over `/api/v2/*` — this change is about auditing that surface,
  not a prerequisite for it. Order doesn't strictly matter (AshEvents records
  actions regardless of transport, so it works before the JSON:API mount
  lands too), but the motivating use case is that API surface.
- Does not touch the 9 existing AshPaperTrail resources or
  `add-audit-history-page`'s in-flight work.
