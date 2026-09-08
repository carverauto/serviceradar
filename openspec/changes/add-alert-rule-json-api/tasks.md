## 1. Macro opt-ins (preset_rule_resource.ex)

- [x] 1.1 Add `extensions:`, `extra_actions:`, `extra_code_interface:` opt-in
      parameters to `PresetRuleResource.__using__/1`, each defaulting to
      `[]`, using `eval_option/3` exactly as `ZenPresetResource` already does
      for `extra_actions`/`extra_code_interface`/`extra_operator_actions`.
- [x] 1.2 Splice `extensions:` into the macro's `use Ash.Resource, ...,
      extensions: unquote(extensions)` call; splice `extra_actions`/
      `extra_code_interface` into the existing `actions do end`/
      `code_interface do end` blocks via `unquote_splicing`.
- [x] 1.3 Confirm `log_promotion_rule.ex`, `stateful_alert_rule_template.ex`,
      and `log_promotion_rule_template.ex` pass none of the new options and
      their macro expansion is byte-identical to before (run their existing
      tests unchanged). Verified via the new regression test (1.4) plus
      direct `mix run -e` introspection: `Spark.extensions/1` and
      `AshJsonApi.Resource.Info.routes/1` for all three show no
      `AshJsonApi.Resource` extension and zero routes, identical to before
      this change. Could not additionally execute `rule_seeder_test.exs`/
      `template_seeder_test.exs` (existing DB-backed tests that construct
      these three resources) in this sandbox — see the implementation
      report's verification section for why (local Postgres port collision
      unrelated to this change); a human should re-run
      `mix test test/serviceradar/observability/rule_seeder_test.exs
      test/serviceradar/observability/template_seeder_test.exs
      test/serviceradar/observability/log_promotion_test.exs` in a clean
      environment/CI before merge to close this out.
- [x] 1.4 Add a regression test: `AshJsonApi.Resource.Info.routes/1` returns
      `[]` for `StatefulAlertRuleTemplate`, `LogPromotionRule`, and
      `LogPromotionRuleTemplate`. Added
      `elixir/serviceradar_core/test/serviceradar/observability/stateful_alert_rule_test.exs`.

## 2. StatefulAlertRule JSON:API

- [x] 2.1 In `stateful_alert_rule.ex`, pass `extensions: [AshJsonApi.Resource]`
      and an `extra_actions`/`extra_code_interface` pair adding a `:by_id`
      read action (`argument :id, :uuid, allow_nil?: false; get? true;
      filter expr(id == ^arg(:id))`) plus its code-interface `define`. Note:
      the `filter expr(id == ...)` needed a hygiene-free variable reference
      (`unquote(Macro.var(:id, nil))`) instead of a bare `id`, mirroring
      `PresetRuleResource`'s own `active_filter` technique — a bare `id`
      inside the nested `quote do ... end` fails to compile
      ("undefined variable \"id\"") because normal `quote` hygiene tags it
      with the caller's module context.
- [x] 2.2 Add the `json_api do end` block: `type "stateful-alert-rule"`,
      `base "/stateful-alert-rules"`, routes `get :by_id`, `index :read`,
      `index :active, route: "/active"`, `post :create`, `patch :update`,
      `delete :destroy`.
- [x] 2.3 Confirm it compiles and `AshJsonApi.Resource.Info.routes/1` for
      `StatefulAlertRule` returns the expected 6 routes. Confirmed via
      `mix run -e` introspection:
      `{:get, "/stateful-alert-rules/:id", :by_id}`,
      `{:get, "/stateful-alert-rules", :read}`,
      `{:get, "/stateful-alert-rules/active", :active}`,
      `{:post, "/stateful-alert-rules", :create}`,
      `{:patch, "/stateful-alert-rules/:id", :update}`,
      `{:delete, "/stateful-alert-rules/:id", :destroy}` — also asserted by
      the new regression test.

## 3. Audit the 19 dormant Observability resources

- [x] 3.1 For each of: `Log`, `ServiceStatus`, `CapacityForecast`,
      `CpuClusterMetric`, `OtelMetric`, `OtelMetricPoint`, `OtelTrace`,
      `OtelTraceSummary`, and the `RawMetricResource`/`HourlyMetricResource`
      -macro resources (`CpuMetric`, `MemoryMetric`, `DiskMetric`,
      `ProcessMetric`, `TimeseriesMetric`, and their `*Hourly`/
      `TimeseriesMetricInterfaceHourly` counterparts) — read its
      `policy action_type(:read)` block and confirm it scopes by actor
      appropriately (not a bare `authorize_if always()` or equivalent).
      Record a one-line pass/fail per resource in this task's notes.

      **Audit results (18 of 19 FAIL):**

      - `Log` — **PASS**. `policies do system_bypass(); read_viewer_plus();
        operator_action(:create) end` — `read_viewer_plus/0`
        (`ServiceRadar.Policies`) expands to
        `authorize_if is_viewer()`, i.e. `actor(:role) in
        [:viewer, :operator, :admin]`. Correctly scopes by actor role; a nil
        actor is denied.
      - `ServiceStatus` — **FAIL**. `policy action_type(:read) do
        authorize_if always() end` — bare `always()`, no actor check at all.
      - `CapacityForecast` — **FAIL**. `policy action_type(:read) do
        authorize_if always() end` — bare `always()` for read (write actions
        are correctly gated to `actor_attribute_equals(:role, :system)`, but
        read is not).
      - `CpuClusterMetric` — **FAIL**. `policy action_type(:read) do
        authorize_if always() end` — bare `always()`, no actor check
        (`create` is likewise bare `always()`).
      - `OtelMetric` — **FAIL**. `policy action_type(:read) do authorize_if
        always() end` — bare `always()`, no actor check (`create` likewise).
      - `OtelMetricPoint` — **FAIL**. `policy action_type(:read) do
        authorize_if always() end` — bare `always()`, no actor check (this
        one has no write actions at all, but read is still wide open).
      - `OtelTrace` — **FAIL**. `policy action_type(:read) do authorize_if
        always() end` — bare `always()`, no actor check (`create` likewise).
      - `OtelTraceSummary` — **FAIL**. `policy action_type(:read) do
        authorize_if always() end` — bare `always()`, no actor check.
      - `CpuMetric`, `MemoryMetric`, `DiskMetric`, `ProcessMetric`,
        `TimeseriesMetric` — **FAIL** (all five). None override policies;
        all inherit `RawMetricResource.__using__/1`'s
        `policy action_type(:read) do authorize_if always() end` (and its
        `policy action(:create) do authorize_if always() end`) verbatim —
        bare `always()`, no actor check, for both read and create.
      - `CpuMetricHourly`, `MemoryMetricHourly`, `DiskMetricHourly`,
        `ProcessMetricHourly`, `TimeseriesMetricHourly`,
        `TimeseriesMetricInterfaceHourly` — **FAIL** (all six). None
        override policies; all inherit `HourlyMetricResource.__using__/1`'s
        `policy action_type(:read) do authorize_if always() end` verbatim —
        bare `always()`, no actor check.

      **18 of the 19 dormant resources default open on read** (everything
      except `Log`). This is not one outlier — it is the shared macros
      (`RawMetricResource`, `HourlyMetricResource`) plus five of the eight
      standalone resources. Per the task's explicit stop condition, this
      blocks proceeding to section 4 (mount) — see the implementation
      report for the full writeup.
- [ ] 3.2 If any resource's read policy defaults open, fix it before
      proceeding — this blocks mounting the domain, it is not a footnote.
      **BLOCKED — STOPPED HERE, not attempted.** Per explicit instruction
      from the task that dispatched this implementation, finding an
      unsafe/defaults-open resource in 3.1 means stop entirely rather than
      fix it unilaterally and continue: sections 4-7 below were
      deliberately NOT executed. A human must decide how to handle the 18
      affected resources (fix each policy, narrow the mount, or accept the
      risk explicitly) before this change can proceed past this point.

## 4. Mount and sync

> **NOT EXECUTED.** Section 3's audit found 18 of 19 dormant resources
> default open on read (see above). Per the task's explicit stop condition,
> implementation halted here — sections 4 through 7 below were not
> attempted and their checkboxes remain unchecked, pending a human decision
> on how to handle the unsafe resources.

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
