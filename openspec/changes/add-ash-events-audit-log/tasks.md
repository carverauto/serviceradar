## 1. Dependency and event log resource

- [ ] 1.1 Add `{:ash_events, "~> 0.7.0"}` to
      `elixir/serviceradar_core/mix.exs`; `mix deps.get`.
- [ ] 1.2 Create `ServiceRadar.Observability.ApiEvent` using
      `AshEvents.EventLog`: `persist_actor_primary_key :user_id,
      ServiceRadar.Identity.User`, `primary_key_type Ash.Type.UUIDv7`,
      `record_id_type :uuid`.
- [ ] 1.3 Implement the `clear_records_for_replay` callback module.
- [ ] 1.4 Register `ApiEvent` in `ServiceRadar.Observability`'s
      `resources do end`.
- [ ] 1.5 `mix ash.codegen add_api_event_log`; `mix ash.migrate`; commit the
      generated migration.

## 2. Wire up StatefulAlertRule

- [ ] 2.1 Add `AshEvents.Events` to `stateful_alert_rule.ex`'s extensions
      (alongside `AshJsonApi.Resource` from `add-alert-rule-json-api`, if
      that change has landed first — otherwise just this one) and an
      `events do event_log ServiceRadar.Observability.ApiEvent end` block.
      Note: this requires the SAME macro-opt-in mechanism
      `add-alert-rule-json-api` adds to `preset_rule_resource.ex` (an
      `extensions:`-threading opt-in) — extend that opt-in to accept
      `AshEvents.Events` too rather than inventing a second mechanism.
- [ ] 2.2 Add an `Ash.Resource.Change` on create/update/destroy that reads a
      changeset-context transport flag and writes `metadata["source"]` as
      `"api"` or `"web"`.
- [ ] 2.3 Set that changeset-context flag from the JSON:API request path
      (present) — confirm the LiveView path leaves it absent, defaulting to
      `"web"`.

## 3. Verification

- [ ] 3.1 Test: creating a `StatefulAlertRule` via `Ash.Changeset.for_create`
      with an actor writes exactly one `ApiEvent` row with the correct
      `user_id`, `resource`, `action`, and `data`.
- [ ] 3.2 Test: `metadata["source"]` is `"api"` when created through the
      JSON:API route (once `add-alert-rule-json-api` lands) and `"web"`
      through the existing LiveView path.
- [ ] 3.3 Test: destroy and update actions each produce their own `ApiEvent`
      row (not just create).
- [ ] 3.4 Confirm no interaction/ordering issue with
      `PresetRuleResource`'s existing policy block — actions still require
      `operator`/`admin`/`system` to succeed; AshEvents only observes
      already-authorized actions.

## 4. Surface it

- [ ] 4.1 Ship a minimal Settings → Audit list view for `ApiEvent` rows
      (actor, resource, action, source, occurred_at), or — if
      `add-audit-history-page` has landed by this point — extend its
      History view to also merge `ApiEvent` alongside AshPaperTrail
      versions.
- [ ] 4.2 Document, in code and in `openspec/specs/ash-events-audit-log`,
      the boundary: AshEvents for new API-first resources going forward
      (starting with `StatefulAlertRule`), AshPaperTrail unchanged for the
      9 existing resources.

## 5. Close out

- [ ] 5.1 `openspec validate add-ash-events-audit-log --strict`.
