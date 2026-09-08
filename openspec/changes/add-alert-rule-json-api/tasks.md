## 1. Macro opt-ins (preset_rule_resource.ex)

- [ ] 1.1 Add `extensions:`, `extra_actions:`, `extra_code_interface:` opt-in
      parameters to `PresetRuleResource.__using__/1`, each defaulting to
      `[]`, using `eval_option/3` exactly as `ZenPresetResource` already does
      for `extra_actions`/`extra_code_interface`/`extra_operator_actions`.
- [ ] 1.2 Splice `extensions:` into the macro's `use Ash.Resource, ...,
      extensions: unquote(extensions)` call; splice `extra_actions`/
      `extra_code_interface` into the existing `actions do end`/
      `code_interface do end` blocks via `unquote_splicing`.
- [ ] 1.3 Confirm `log_promotion_rule.ex`, `stateful_alert_rule_template.ex`,
      and `log_promotion_rule_template.ex` pass none of the new options and
      their macro expansion is byte-identical to before (run their existing
      tests unchanged).
- [ ] 1.4 Add a regression test: `AshJsonApi.Resource.Info.routes/1` returns
      `[]` for `StatefulAlertRuleTemplate`, `LogPromotionRule`, and
      `LogPromotionRuleTemplate`.

## 2. StatefulAlertRule JSON:API

- [ ] 2.1 In `stateful_alert_rule.ex`, pass `extensions: [AshJsonApi.Resource]`
      and an `extra_actions`/`extra_code_interface` pair adding a `:by_id`
      read action (`argument :id, :uuid, allow_nil?: false; get? true;
      filter expr(id == ^arg(:id))`) plus its code-interface `define`.
- [ ] 2.2 Add the `json_api do end` block: `type "stateful-alert-rule"`,
      `base "/stateful-alert-rules"`, routes `get :by_id`, `index :read`,
      `index :active, route: "/active"`, `post :create`, `patch :update`,
      `delete :destroy`.
- [ ] 2.3 Confirm it compiles and `AshJsonApi.Resource.Info.routes/1` for
      `StatefulAlertRule` returns the expected 6 routes.

## 3. Audit the 19 dormant Observability resources

- [ ] 3.1 For each of: `Log`, `ServiceStatus`, `CapacityForecast`,
      `CpuClusterMetric`, `OtelMetric`, `OtelMetricPoint`, `OtelTrace`,
      `OtelTraceSummary`, and the `RawMetricResource`/`HourlyMetricResource`
      -macro resources (`CpuMetric`, `MemoryMetric`, `DiskMetric`,
      `ProcessMetric`, `TimeseriesMetric`, and their `*Hourly`/
      `TimeseriesMetricInterfaceHourly` counterparts) — read its
      `policy action_type(:read)` block and confirm it scopes by actor
      appropriately (not a bare `authorize_if always()` or equivalent).
      Record a one-line pass/fail per resource in this task's notes.
- [ ] 3.2 If any resource's read policy defaults open, fix it before
      proceeding — this blocks mounting the domain, it is not a footnote.

## 4. Mount and sync

- [ ] 4.1 Add `ServiceRadar.Observability` to `ash_json_api_router.ex`'s
      `domains:` list; update its moduledoc's endpoint listing to include
      `/api/v2/stateful-alert-rules` and all 19 newly-live read-only paths.
- [ ] 4.2 Add `ServiceRadar.Observability` to `OpenApiV2Controller`'s
      hardcoded `@domains` list.
- [ ] 4.3 File a separate GitHub issue for `OpenApiV2Controller`'s
      pre-existing missing-`Notifications` entry — do not fix it as a
      drive-by in this change.
- [ ] 4.4 Run `mix serviceradar.openapi.dump` (from `elixir/web-ng`); commit
      the resulting `priv/static/openapi.json` diff.
- [ ] 4.5 Extend the existing `GET /api/v2/open_api` test in
      `ash_json_api_test.exs` to assert `/api/v2/stateful-alert-rules`
      appears in `response["paths"]`.

## 5. Tests

- [ ] 5.1 Add `stateful_alert_rule_fixture/1` to
      `elixir/web-ng/test/support/ash_test_helpers.ex`, mirroring
      `service_check_fixture/1`'s shape (unique name, created via
      `Ash.Changeset.for_create(:create, attrs, actor: system_actor())`).
- [ ] 5.2 Register `StatefulAlertRule` in `policy_test_helpers.ex`'s
      `create_resource/1` dispatcher.
- [ ] 5.3 Extend `ash_json_api_test.exs` with `describe` blocks for
      `GET /api/v2/stateful-alert-rules` (list + unauthenticated-empty),
      `POST` (authed `[201, 403]` / unauth `[400, 403]`), `PATCH`, and
      `DELETE`, mirroring the existing ServiceCheck/Alert blocks exactly.
- [ ] 5.4 Add a policy/domain-level test file (check
      `elixir/serviceradar_core/test/serviceradar/observability/` for the
      right sibling convention first) mirroring `service_check_test.exs`:
      operator can create/update/destroy, viewer cannot update — using
      `operator_actor()`/`viewer_actor()`/`admin_actor()`/`system_actor()`
      from `AshTestHelpers`.
- [ ] 5.5 Write the operator-can-destroy test explicitly — do NOT reuse
      `assert_rbac_matrix/2`'s generic 3-tier assumption (it assumes
      operator cannot destroy, which is wrong for this resource).

## 6. File the flagged gap

- [ ] 6.1 File a GitHub issue describing the OAuth2 scope-enforcement gap
      on the `:ash_json_api` pipeline (`RequireOauthScope` not wired in;
      authorization is purely `actor.role`-based today) as a platform-wide
      follow-up, referencing this change as the reason it's now more
      urgent.

## 7. Close out

- [ ] 7.1 `openspec validate add-alert-rule-json-api --strict`.
