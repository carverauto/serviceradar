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
- [x] 3.2 Fixed all 18 defaults-open resources. Human direction (this task):
      for every bare `policy action_type(:read) do authorize_if always() end`,
      replace with `system_bypass(); read_viewer_plus()` — Log's exact,
      already-passing pattern (`import ServiceRadar.Policies` inside the
      `policies do` block, same as Log). For every bare
      `policy action(:create) do authorize_if always() end` (and
      `ServiceStatus`'s `policy action([:create, :insert_once])`, same shape),
      replace with `authorize_if actor_attribute_equals(:role, :system)`
      (system-actor-only, matching `CapacityForecast`'s pre-existing write
      gating and the architectural rule that only the event_writer pipeline's
      system actor writes these resources).

      Files touched: `raw_metric_resource.ex` and `hourly_metric_resource.ex`
      (shared macros, 11 resources between them), `service_status.ex`,
      `capacity_forecast.ex` (read only — its `[:upsert, :destroy]` write
      policy was already correctly `actor_attribute_equals(:role, :system)`
      and was left untouched, its redundant standalone `bypass always()` was
      folded into the equivalent `system_bypass()` macro call),
      `cpu_cluster_metric.ex`, `otel_metric.ex`, `otel_metric_point.ex`
      (read-only, no create action), `otel_trace.ex`, `otel_trace_summary.ex`
      (read-only, no create action).

      **Pre-fix safety verification done independently (not just taking the
      dispatching task's word for it):**
      - Grepped every one of the 18 module names repo-wide: zero internal
        callers outside each resource's own file and `observability.ex`'s
        domain registration, confirming no code path depends on the old
        open policy, with one exception below.
      - `ServiceStatus`'s `:insert_once` action (bundled with `:create` in one
        policy) *does* have a real caller —
        `plugin_result_ingestor.ex:198` — traced to
        `actor = SystemActor.system(:plugin_result_ingestor)`
        (`plugin_result_ingestor.ex:63`), confirmed a `role: :system` map via
        `SystemActor.system/1`. Restricting to system-actor-only does not
        break it. (The dispatching task's own safety note listed
        `CpuClusterMetric`/`OtelMetric`/`OtelTrace`/the 5
        `RawMetricResource` resources for the create-side check but did not
        mention `ServiceStatus`; verified this one myself before applying the
        same fix to it.)
      - `CapacityForecast`'s only internal read caller
        (`capacity_forecasting/worker.ex`) defaults its actor to
        `SystemActor.system(:capacity_forecasting)`; confirmed no call site
        overrides it with a non-system actor.
      - The three web-ng LiveViews named in the dispatching task
        (`anomaly_detection_live.ex`, `show_template.ex`,
        `process_metrics_components.ex`) were re-checked directly: none of
        them reference these 18 resource modules by name.
        `process_metrics_components.ex`'s metrics panel goes through
        `SRQLRunner`, which executes raw SQL directly against `Repo`
        (`Ecto.Adapters.SQL.query`), bypassing Ash and its policies
        entirely — a pre-existing, separate access path unaffected either
        way by this change (tightening these Ash policies does not touch
        it, and it was already effectively a bypass before this change too).
        Noted for a reviewer; out of scope to fix here.
      - Confirmed via `grep -rl "json_api do"` across
        `elixir/serviceradar_core/lib/serviceradar/observability/` that
        exactly 11 files declare a `json_api` block (the 8 standalone
        resources + the 2 shared macros, covering 19 resources total once
        macro expansion is counted) plus the new `stateful_alert_rule.ex` —
        i.e. no 20th dormant resource was missed and no other
        already-declared resource in this domain (`mtr_*`, `netflow_*`,
        `threat_intel_*`, `service_state.ex`, `otx_retrohunt_*` — several of
        which *also* have bare `authorize_if always()` reads) will be
        activated by this mount, since none of them have a `json_api` block.
        Those other resources' open-read policies are real but pre-existing
        and entirely out of scope for this change (not reachable via this
        domain mount) — worth a separate follow-up, not fixed here.

      **Post-fix empirical verification:**
      `mix compile --warnings-as-errors` in `serviceradar_core` — clean
      (only the known pre-existing `refresh_trace_summaries_worker.ex`
      warning, confirmed present since the repo's initial commit).
      `mix format --check-formatted` and `mix credo --strict` — clean
      (`36897 mods/funs, found no issues`).

      Could **not** get a live, DB-backed empirical run against the real
      Postgres/TimescaleDB-backed resources in this sandbox: `mix ecto.migrate`
      fails at the `CREATE EXTENSION timescaledb` step
      (`ERROR 58P01 undefined_file ... timescaledb.control: No such file or
      directory` — the local Homebrew Postgres 14 has no TimescaleDB
      extension installed, and none is available via `brew search
      timescaledb`), and the app's dev database (`serviceradar_dev`) does not
      exist either. This matches the pre-existing environment limitation
      flagged in this task's own instructions.

      To still get genuine empirical proof rather than relying on static
      code reading alone, built an isolated Ash-resource proof using the
      ETS data layer (`Ash.DataLayer.Ets`, no Postgres/TimescaleDB
      involved) with **byte-identical policy blocks** to the real fix
      (`system_bypass(); read_viewer_plus()` for read;
      `authorize_if actor_attribute_equals(:role, :system)` for create,
      including a `policy action([:create, :insert_once])` variant matching
      `ServiceStatus`'s exact shape) and ran real query/changeset execution
      (`Ash.read`/`Ash.create` with `authorize?: true`, not just the
      optimistic `Ash.can?/2` shortcut — confirmed `Ash.can?` for filter-based
      read policies defaults to `maybe_is: true`, i.e. it answers `true` for
      *every* actor including `nil` when it can't prove infeasibility without
      running a query, per Ash's own moduledoc example; not a reliable check
      on its own). Results, one seeded row, `authorize?: true` explicit:

      | actor            | READ (rows returned) | CREATE            |
      |------------------|-----------------------|--------------------|
      | nil (unauth)     | 0 (denied)            | Forbidden          |
      | viewer           | 1 (allowed)           | Forbidden          |
      | operator         | 1 (allowed)           | Forbidden          |
      | admin            | 1 (allowed)           | Forbidden          |
      | system           | 1 (allowed, bypass)   | OK                 |
      | bogus role       | 0 (denied)            | Forbidden          |

      Also ran the `[:create, :insert_once]`-shaped variant
      (`ServiceStatus`'s exact policy shape): identical pass/fail pattern for
      both actions.

      This is a faithful proxy for the authorization logic itself (Ash's
      `Ash.Policy.Authorizer` behavior is data-layer-agnostic — the same
      policy DSL and check functions run regardless of ETS vs. Postgres
      backing), but it does **not** exercise the real
      `AshPostgres.DataLayer`-backed resources end-to-end. A human should
      re-run this against a real environment with TimescaleDB available
      (e.g. `mix test` for a policy test targeting each of these 19
      resources, or a manual `Ash.can?`/`Ash.read` smoke test against a
      properly migrated `serviceradar_dev`/`serviceradar_test` database) to
      close this out completely.

      **Final state — all 19 resources now correctly scope by actor:**
      `Log` (already passing, untouched), `ServiceStatus`,
      `CapacityForecast`, `CpuClusterMetric`, `OtelMetric`, `OtelMetricPoint`,
      `OtelTrace`, `OtelTraceSummary`, `CpuMetric`, `MemoryMetric`,
      `DiskMetric`, `ProcessMetric`, `TimeseriesMetric`, `CpuMetricHourly`,
      `MemoryMetricHourly`, `DiskMetricHourly`, `ProcessMetricHourly`,
      `TimeseriesMetricHourly`, `TimeseriesMetricInterfaceHourly` — 19 of 19
      PASS.

## 4. Mount and sync

> Section 3.2's fix + re-audit cleared the blocking finding (all 19
> resources now correctly scope by actor); proceeding with the mount below.

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
