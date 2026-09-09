## 1. Dependency and event log resource

- [x] 1.1 Add `{:ash_events, "~> 0.7.0"}` to
      `elixir/serviceradar_core/mix.exs`; `mix deps.get`.
- [x] 1.2 Create `ServiceRadar.Observability.ApiEvent` using
      `AshEvents.EventLog`: `persist_actor_primary_key :user_id,
      ServiceRadar.Identity.User`, `primary_key_type Ash.Type.UUIDv7`,
      `record_id_type :uuid`.
- [x] 1.3 Implement the `clear_records_for_replay` callback module.
- [x] 1.4 Register `ApiEvent` in `ServiceRadar.Observability`'s
      `resources do end`.
- [x] 1.5 `mix ash.codegen add_api_event_log`; apply it using the root
      `AGENTS.md` database migration guidance; commit the generated migration.
      Deviation: `mix ash.codegen` is currently unusable in this repo
      (`priv/resource_snapshots/` is gitignored -- see
      `20260512040000_add_security_resources.exs`'s moduledoc and
      `docs/PLATFORM_SECURITY_HARDENING.md#known-follow-ups`, a
      pre-existing, already-documented repo issue, not introduced by this
      change). Followed that same file's established precedent: a
      hand-written `use Ecto.Migration` matching the standard pattern.
      Applied and verified against a real srql-fixtures scratch database.

## 2. Wire up StatefulAlertRule

- [x] 2.1 Add `AshEvents.Events` to `stateful_alert_rule.ex`'s extensions
      (alongside `AshJsonApi.Resource` from `add-alert-rule-json-api`, if
      that change has landed first -- otherwise just this one) and an
      `events do event_log ServiceRadar.Observability.ApiEvent end` block.
      Note: this requires the SAME macro-opt-in mechanism
      `add-alert-rule-json-api` adds to `preset_rule_resource.ex` (an
      `extensions:`-threading opt-in) -- extend that opt-in to accept
      `AshEvents.Events` too rather than inventing a second mechanism.
- [x] 2.2 Add an `Ash.Resource.Change` on create/update/destroy that reads a
      changeset-context transport flag and writes `metadata["source"]` as
      `"api"` or `"web"`.
- [x] 2.3 Set that changeset-context flag from the JSON:API request path
      (present) -- confirm the LiveView path leaves it absent, defaulting to
      `"web"`.

## 3. Verification

- [x] 3.1 Test: creating a `StatefulAlertRule` via `Ash.Changeset.for_create`
      with an actor writes exactly one `ApiEvent` row with the correct
      `user_id`, `resource`, `action`, and `data`.
- [x] 3.2 Test: `metadata["source"]` is `"api"` when created through the
      JSON:API route (once `add-alert-rule-json-api` lands) and `"web"`
      through the existing LiveView path.
- [x] 3.3 Test: destroy and update actions each produce their own `ApiEvent`
      row (not just create).
- [x] 3.4 Confirm no interaction/ordering issue with
      `PresetRuleResource`'s existing policy block -- actions still require
      `operator`/`admin`/`system` to succeed; AshEvents only observes
      already-authorized actions.
      Verified against a real srql-fixtures scratch database (all 9 tests
      in stateful_alert_rule_events_test.exs pass, plus the existing
      stateful_alert_rule_policy_test.exs's 11 tests still pass unchanged).

## 4. Surface it

- [x] 4.1 Implement the audit UI integration in
      [design.md](design.md#decisions), preserving the existing History view.
      Adapter: `ApiEvent` rows are wrapped in an `AuditHistory.ApiEventVersion`
      struct exposing PaperTrail's field names, unioned into `list_recent/2`.
      Added a new `@ash_events_resources` allow-list (distinct from
      `@default_resources`) and `all_resources/0`; the LiveView's
      `resource_options/0`/`resolve_resource/1` use `all_resources/0`. Added
      a new "Origin" table column (`api`/`web`/`—`) rather than repurposing
      "Source row" -- named "Origin" (not literally "Source") to avoid
      clashing with the existing PaperTrail "Source row" column.
- [x] 4.2 Preserve the adoption boundary in [design.md](design.md#decisions)
      when archiving into `openspec/specs/ash-events-audit-log`; point code
      documentation to that owner rather than copying its resource inventory.
      `ApiEvent`, `ApiEventVersion`, and `ClearForReplay`'s moduledocs all
      reference `design.md#decisions` by path rather than restating the
      resource inventory inline. Archiving itself (moving this change's
      spec delta into `openspec/specs/`) is a separate, later step this
      task does not perform.

## 5. Close out

- [x] 5.1 `openspec validate add-ash-events-audit-log --strict`.
