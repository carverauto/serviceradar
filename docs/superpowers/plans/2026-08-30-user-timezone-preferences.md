# User Timezone Preferences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist one IANA timezone per user and localize every human-visible absolute timestamp in the authenticated web UI without changing any canonical UTC storage, query, payload, export, notification, or schedule value.

**Architecture:** PostgreSQL remains the sole server-side timezone catalog: a neutral core module normalizes and validates infrequent preference writes, while a dedicated self-only Ash action persists the normalized identifier. Phoenix renders semantic `<time>` elements with deterministic UTC fallback and explicit saved-zone metadata; one browser `Intl.DateTimeFormat` utility formats both LiveView text and chart labels at the last presentation boundary. A checked-in call-site inventory and Bazel-backed source audit keep localized display paths separate from canonical machine, relative-duration, and documented fixed-UTC paths.

**Tech Stack:** Elixir, Ash/AshPostgres, Ecto migrations, Phoenix LiveView/HEEx, AshPhoenix.Form, vanilla JavaScript hooks, browser `Intl.DateTimeFormat`, Vitest, ExUnit/LazyHTML, Bazel.

**Spec:** `openspec/changes/add-user-timezone-preferences/design.md` plus the delta specs under `openspec/changes/add-user-timezone-preferences/specs/`

## Global Constraints

- Work only in `/private/tmp/serviceradar-issue-3555` on `codex/add-user-timezone-preferences`; never push directly to `staging`, and use an explicit refspec if a later user request authorizes a push.
- Follow strict red-green-refactor: add a focused test, run it and observe the expected failure, add the minimum production behavior, then rerun and observe the test passing before committing.
- The product boundary is the authenticated interactive web UI. Database values, telemetry payloads, SRQL/filter/pivot bounds, URL and LiveView event bounds, chart scale/selection values, REST/JSON, CSV/downloads, cold-tier data, notifications, reports, and schedule evaluation remain canonical UTC.
- Persist exactly one public, non-null `ServiceRadar.Identity.User.timezone` string with database and resource default `Etc/UTC`; accepted UTC aliases normalize to that exact value.
- PostgreSQL `pg_timezone_names` is the only server-side IANA database. Add no `tzdata` or other timezone dependency, no process, and no long-lived cache.
- The profile catalog contains sorted IANA area/location identifiers plus `Etc/UTC`; exclude blank values, abbreviations, `posix/` entries, and `Etc/GMT+<n>` / `Etc/GMT-<n>` fixed-offset names.
- The timezone update action accepts only `timezone` and authorizes only `id == actor.id`; do not add it to `@self_service_actions`, because that list also permits `settings.auth.manage` actors.
- A profile save must preserve `current_scope.permissions` and `current_scope.identity_claims`: replace only `%{scope | user: updated_user}` rather than rebuilding the scope.
- Every browser formatter call supplies the saved zone through the `timeZone` option. Never infer or silently fall back to the browser's local timezone.
- The server-rendered fallback is visible UTC. Invalid input, missing/unsupported `Intl`, or an unsupported zone leaves that fallback unchanged.
- Full timestamp styles and tooltips include an unambiguous numeric offset. Compact chart axes may omit it only when the associated tooltip or accessible value includes it.
- Every localized HTML value retains a canonical UTC ISO-8601 `<time datetime>` value plus accessible original-UTC and selected-zone context.
- The shared hook mutates text/metadata only and reruns after LiveView updates; do not add `phx-update="ignore"` because the server still owns the element.
- Every `phx-hook="UserTime"` and `phx-hook="TimezoneSelect"` element has a caller-supplied, stable, unique DOM id.
- The profile LiveView must not query PostgreSQL during disconnected mount. Render `Etc/UTC` plus the saved value while disconnected, and load the full catalog once during connected mount.
- Preserve the current selected effective log instant, OTel correlation pivots, NetFlow bucket boundaries, `toISOString()` range payloads, and attributed-flow query semantics from active OpenSpec work.
- New database-free ExUnit tests are async where safe and carry `@moduletag :db_free`. Database-backed profile/action tests must run against a disposable scratch database with `SERVICERADAR_REQUIRE_DB_TESTS=1`; a skipped or zero-test run is a failure.
- Do not add a shell script. The timestamp inventory guard is a normal Bazel-backed ExUnit/JavaScript test target.

## File Map

### Core catalog and persistence

- Create `elixir/serviceradar_core/lib/serviceradar/time_zone.ex`: neutral PostgreSQL catalog, UTC normalization, profile validation, and existing local-wall-clock conversion.
- Modify `elixir/serviceradar_core/lib/serviceradar/notifications/time_zone.ex`: compatibility delegates only; notification callers keep their current contract.
- Create `elixir/serviceradar_core/lib/serviceradar/identity/changes/normalize_timezone_preference.ex`: pure Ash change that trims and normalizes the pending field.
- Create `elixir/serviceradar_core/lib/serviceradar/identity/validations/profile_timezone.ex`: catalog-backed field validation for both ordinary and atomic Ash update paths; the catalog lookup runs before the single-row update is issued.
- Modify `elixir/serviceradar_core/lib/serviceradar/identity/user.ex`: public attribute, code interface, dedicated action, and self-only policy.
- Generate `elixir/serviceradar_core/priv/repo/migrations/*_add_user_timezone_preference.exs`: `platform.ng_users.timezone`, constant `Etc/UTC` default/backfill, non-null constraint.
- Modify `elixir/serviceradar_core/test/serviceradar/notifications/time_zone_test.exs`: compatibility delegation coverage.
- Create `elixir/serviceradar_core/test/serviceradar/time_zone_test.exs`: pure normalization/catalog tests with injected query functions.
- Create `elixir/serviceradar_core/test/serviceradar/identity/validations/profile_timezone_test.exs`: validation failure and no-mutation unit coverage with injected catalog results.
- Create `elixir/web-ng/test/serviceradar/identity/timezone_preference_test.exs`: DB-backed default, persistence, normalization, invalid input, and authorization coverage using existing web-ng identity fixtures.

### Shared renderer and selector JavaScript

- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/components/core_components.ex`: constrained `user_time/1` semantic component and UTC fallback helpers.
- Create `elixir/web-ng/test/phoenix/components/user_time_test.exs`: rendered semantic/accessibility/fallback contract.
- Create `elixir/web-ng/assets/js/utils/user_time.js`: pure named-style `Intl.DateTimeFormat` utility.
- Create `elixir/web-ng/assets/js/utils/user_time.test.js`: UTC fallback, DST, offsets, style, invalid-value, and missing-Intl tests.
- Create `elixir/web-ng/assets/js/hooks/UserTime.js`: LiveView lifecycle wrapper around the pure utility.
- Create `elixir/web-ng/assets/js/hooks/UserTime.test.js`: mounted/updated/fallback behavior.
- Delete `elixir/web-ng/assets/js/hooks/LocalTime.js` after all consumers move to `UserTime`.
- Modify `elixir/web-ng/assets/js/hooks/index.js`: register `UserTime`, remove `LocalTime`.
- Create `elixir/web-ng/assets/js/utils/timezone_options.js`: browser capability filter for the profile selector.
- Create `elixir/web-ng/assets/js/utils/timezone_options.test.js`: `supportedValuesOf` and constructor-probe fallback coverage.
- Create `elixir/web-ng/assets/js/hooks/TimezoneSelect.js`: filters an existing server-rendered `<datalist>` for a searchable timezone input without inventing values.
- Create `elixir/web-ng/assets/js/hooks/TimezoneSelect.test.js`: lifecycle and retained-current/UTC coverage.

### Profile UI

- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/user_live/settings.ex`: load catalog once per connected mount, render a searchable selector and fixed-instant timezone preview, submit the dedicated scoped Ash form, and refresh only `current_scope.user`.
- Modify `elixir/web-ng/test/phoenix/live/user_live/settings_test.exs`: DB-backed render, validation, immediate scope update, and fresh-mount persistence.

### Observability display migration

- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex`: log/syslog/SNMP/GELF/OTel row, trace, metric, event, and alert display boundaries; remove its colocated local-time hook while preserving effective timestamp selection and canonical pivots.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/show.ex`: semantic detail timestamp while preserving canonical correlation values.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/metric_live/show.ex`: semantic metric detail timestamp.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/components/srql_components.ex`: semantic SRQL-result timestamp cells while leaving query values canonical.
- Modify `elixir/web-ng/test/phoenix/live/log_live/index_test.exs`, `elixir/web-ng/test/phoenix/live/log_live/show_test.exs`, and `elixir/web-ng/test/phoenix/components/srql_components_test.exs`; create `elixir/web-ng/test/phoenix/live/metric_live/timestamp_rendering_test.exs`: assert saved-zone metadata and unchanged canonical pivot/query values.

### NetFlow display migration

- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/view.ex`: derive `timezone = current_scope.user.timezone || "Etc/UTC"` and pass it to presentation children.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/view/flows_table.ex`: semantic row timestamps.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/view/flow_modal.ex`: semantic detail timestamps.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/view/flows_panel.ex`: semantic absolute-window endpoints.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/view/chart_panel.ex`: explicit saved-zone metadata on chart roots.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/time_window.ex`: return canonical boundary data rather than a preformatted UTC sentence; keep parsing/query behavior unchanged.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/format.ex`: remove display-only timestamp formatting after callers use `user_time/1`.
- Modify `elixir/web-ng/assets/js/netflow_charts/util.js`: shared-zone tooltip formatter.
- Modify `elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.js`, `NetflowLineSeriesChart.js`, `NetflowStacked100Chart.js`, and `NetflowGridChart.js`: explicit-zone axes/tooltips only.
- Modify `elixir/web-ng/test/phoenix/live/log_live/netflow_chart_range_components_test.exs`, `elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.test.js`, `NetflowGridChart.test.js`, `NetflowStacked100Chart.test.js`, and `js/netflow_charts/util.test.js`; create `NetflowLineSeriesChart.test.js` and `elixir/web-ng/test/phoenix/live/netflow_live/timestamp_rendering_test.exs`: localized labels plus byte-for-byte canonical selection payload regression.

### Inventory, remaining surfaces, and build graph

- Create `elixir/web-ng/test/fixtures/timestamp_formatter_inventory.json`: one record per direct timestamp formatter with `path`, stable `matcher`, `classification`, and non-empty `reason` for fixed UTC.
- Create `elixir/web-ng/test/phoenix/timestamp_formatter_inventory_test.exs`: anti-vacuous source audit that compares repository matches with the checked inventory.
- Modify remaining human-display call sites identified by the inventory across `live/dashboard_live/**`, `live/device_live/**`, `live/service_live/**`, `live/gateway_live/**`, `live/infrastructure_live/**`, `live/scan_live.ex`, `live/admin/**`, `live/analytics_live/**`, `live/observability_health_live/**`, `live/user_live/**`, `components/northbound_action_components.ex`, and `components/promotion_rule_builder.ex`.
- Modify JavaScript dashboard/chart human-display call sites under `assets/js/dashboards/**` and `assets/js/hooks/charts/**`; retain number-only `toLocaleString` calls outside the timestamp inventory.
- Create `elixir/web-ng/assets/timestamp_formatter_test_runner.mjs`: run the declared formatter Vitest files from Bazel runfiles and propagate the Vitest result.
- Modify `elixir/web-ng/assets/BUILD.bazel`: `timestamp_formatter_test_srcs` filegroup and `timestamp_formatter_tests` `js_test` target.
- Modify `elixir/web-ng/BUILD.bazel`: declare the JSON inventory and audited JS source filegroup as database-free unit-test data.
- Create `elixir/web-ng/test/phoenix/user_timezone_surface_contract_test.exs` for dashboard, device/inventory, gateway/service, admin/audit, and settings component fixtures. Create `elixir/web-ng/test/phoenix/user_timezone_machine_boundary_test.exs` for REST/JSON, exports, SRQL, URL/event bounds, notifications, reports, and schedules.

---

### Task 1: PostgreSQL Timezone Catalog and Self-Only User Preference

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/time_zone.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/notifications/time_zone.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/identity/changes/normalize_timezone_preference.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/identity/validations/profile_timezone.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/user.ex`
- Generate: `elixir/serviceradar_core/priv/repo/migrations/*_add_user_timezone_preference.exs`
- Test: `elixir/serviceradar_core/test/serviceradar/time_zone_test.exs`
- Test: `elixir/serviceradar_core/test/serviceradar/notifications/time_zone_test.exs`
- Test: `elixir/serviceradar_core/test/serviceradar/identity/validations/profile_timezone_test.exs`
- Test: `elixir/web-ng/test/serviceradar/identity/timezone_preference_test.exs`

**Interfaces:**
- Consumes: `ServiceRadar.Repo.query/2`, pending Ash `:timezone` input, and existing `ServiceRadar.Identity.User` actors/policies.
- Produces: `ServiceRadar.TimeZone.supported?/2 :: boolean`, `local_datetime/3 :: {:ok, NaiveDateTime.t()} | {:error, {:unsupported_timezone, term()}}`, `profile_timezones/0` and injectable `profile_timezones/1 :: {:ok, [String.t()]} | {:error, :catalog_unavailable}`, `normalize_preference/1 :: {:ok, String.t()} | {:error, :invalid_timezone}`, and `validate_preference/1` plus injectable `validate_preference/2 :: {:ok, String.t()} | {:error, :invalid_timezone | :catalog_unavailable}`.
- Produces: `ServiceRadar.Identity.User.update_timezone_preference(user, attrs, opts)` with a scoped Ash action accepting only `%{timezone: binary}` and returning `{:ok, User.t()} | {:error, Ash.Error.t()}`. A private changeset-context key `:time_zone_query` may inject the existing two-argument query seam for deterministic catalog-failure tests; normal callers omit it.

- [ ] **Step 1: Write failing pure catalog and compatibility tests**

Add table-driven assertions for trimming and UTC aliases:

```elixir
for alias_name <- ["UTC", " utc ", "GMT", "Etc/GMT", "Z", "Zulu", "Etc/Zulu"] do
  assert TimeZone.normalize_preference(alias_name) == {:ok, "Etc/UTC"}
end

for invalid <- [nil, "", "   ", "CST", "+05:00", "Etc/GMT+5", "posix/America/Chicago"] do
  assert TimeZone.normalize_preference(invalid) == {:error, :invalid_timezone}
end
```

Use this injected query to assert the catalog query is parameter-free, sorted, includes `Etc/UTC`, filters fixed offsets/POSIX/abbreviations defensively even if a fake row returns them, and reports `{:error, :catalog_unavailable}` on query error:

```elixir
catalog_query = fn sql, params ->
  assert sql =~ "pg_timezone_names"
  assert params == []

  {:ok,
   %{rows: [["America/Chicago"], ["CST"], ["Etc/GMT+5"], ["posix/Europe/London"]]}}
end
```

Retain the existing `supported?/2` and `local_datetime/3` notification tests, but make them prove the compatibility module delegates to the neutral implementation.

- [ ] **Step 2: Run the pure tests and observe RED**

Run:

```bash
bazel test --test_output=errors //elixir/serviceradar_core:unit_tests_serviceradar_other //elixir/serviceradar_core:unit_tests_serviceradar_notifications
```

Expected: FAIL because `ServiceRadar.TimeZone` and the new test shard do not exist yet.

- [ ] **Step 3: Implement the neutral catalog and notification delegates**

Use one injected-query seam and keep exact UTC normalization separate from catalog membership:

```elixir
def normalize_preference(value) when is_binary(value) do
  zone = String.trim(value)

  cond do
    zone == "" -> {:error, :invalid_timezone}
    String.upcase(zone) in @utc_aliases -> {:ok, "Etc/UTC"}
    profile_shape?(zone) -> {:ok, zone}
    true -> {:error, :invalid_timezone}
  end
end

defp profile_shape?(zone) do
  String.contains?(zone, "/") and
    not Regex.match?(~r/\Aposix\//i, zone) and
    not Regex.match?(~r/\AEtc\/GMT[+-]\d+\z/i, zone)
end

def validate_preference(value, opts \\ []) do
  with {:ok, zone} <- normalize_preference(value),
       {:ok, zones} <- profile_timezones(opts),
       true <- zone in zones do
    {:ok, zone}
  else
    {:error, :catalog_unavailable} = error -> error
    _ -> {:error, :invalid_timezone}
  end
end
```

`profile_timezones/1` must accept only row lists shaped as `[[name]]` with binary `name`, reapply the finite-profile predicate in Elixir, prepend/deduplicate `Etc/UTC`, and sort. `ServiceRadar.Notifications.TimeZone` becomes `defdelegate` wrappers so notification schedule semantics do not move.

- [ ] **Step 4: Write failing Ash change/validation tests**

Build an update changeset over `%User{timezone: "America/New_York"}`. Assert the change normalizes `" GMT "` to `Etc/UTC`, the validation attaches a `:timezone` field error for `Etc/GMT+5`, and a query function supplied through `context.source_context[:private][:time_zone_query]` makes catalog failure leave `changeset.data.timezone` unchanged. Exercise both change and validation callbacks through their atomic paths, and assert the resource action retains Ash's default `require_atomic? true` contract.

- [ ] **Step 5: Run the validation tests and observe RED**

Run:

```bash
bazel test --test_output=errors //elixir/serviceradar_core:unit_tests_serviceradar_other
```

Expected: FAIL because the Ash change and validation modules do not exist.

- [ ] **Step 6: Implement the dedicated action, attribute, and policy**

Add the action outside `@self_service_actions`:

```elixir
update :update_timezone_preference do
  description "Update only the acting user's display timezone preference"
  accept [:timezone]
  change ServiceRadar.Identity.Changes.NormalizeTimezonePreference
  validate ServiceRadar.Identity.Validations.ProfileTimezone
end
```

Add `define :update_timezone_preference, action: :update_timezone_preference`, a public non-null string attribute with default `"Etc/UTC"`, and the exact policy:

```elixir
policy action(:update_timezone_preference) do
  authorize_if expr(id == ^actor(:id))
end
```

The normalization change uses `Ash.Changeset.fetch_change/2`, changes only the pending `:timezone` value, and adds a field error for invalid syntax. Its `atomic/3` callback applies the same pure normalization to the pending atomic changeset. The catalog validation reads the normalized pending value from atomics, ordinary changes, or existing data in that order; forwards a private `time_zone_query` from `context.source_context` as `query: query` when present; and returns a field-level message for both missing catalog membership and catalog unavailability. Its atomic callback performs the catalog lookup before the database update, preserving the resource's default atomic-update requirement instead of opting the action out.

- [ ] **Step 7: Generate and review the AshPostgres migration**

From `elixir/serviceradar_core`, first confirm the task contract with `/usr/bin/script -q /dev/null mix help ash_postgres.generate_migrations`, then run:

```bash
/usr/bin/script -q /dev/null mix ash_postgres.generate_migrations --name add_user_timezone_preference
```

Do not hand-create a migration in place of the generator and do not commit ignored Ash snapshots.

Review the generated migration and require the effective SQL shape to be equivalent to:

```elixir
alter table(:ng_users, prefix: "platform") do
  add :timezone, :text, null: false, default: "Etc/UTC"
end
```

The constant default supplies both existing-row backfill and new-row default on PostgreSQL; no credential, role, or authorization column may be touched. Add a database-free migration-contract assertion that reads the generated source and requires `add :timezone, :text, null: false, default: "Etc/UTC"`; this pins the PostgreSQL existing-row backfill mechanism without destructively migrating the shared test table down and up.

- [ ] **Step 8: Write and run DB-backed action/migration tests**

Use `ServiceRadarWebNG.DataCase, async: false` and existing system/actor fixtures. Assert:

```elixir
assert created.timezone == "Etc/UTC"
assert {:ok, updated} = User.update_timezone_preference(user, %{timezone: " America/Chicago "}, scope: own_scope)
assert updated.timezone == "America/Chicago"
assert {:ok, utc} = User.update_timezone_preference(updated, %{timezone: "Z"}, scope: own_scope)
assert utc.timezone == "Etc/UTC"
assert {:error, %Ash.Error.Invalid{}} = User.update_timezone_preference(utc, %{timezone: "Etc/GMT+5"}, scope: own_scope)
assert fresh_user(utc.id).timezone == "Etc/UTC"
catalog_down = fn _sql, _params -> {:error, :catalog_unavailable} end
assert {:error, %Ash.Error.Invalid{}} =
         User.update_timezone_preference(utc, %{timezone: "America/Chicago"},
           scope: own_scope,
           context: %{private: %{time_zone_query: catalog_down}}
         )
assert fresh_user(utc.id).timezone == "Etc/UTC"
assert {:error, %Ash.Error.Forbidden{}} = User.update_timezone_preference(other_user, %{timezone: "America/Chicago"}, scope: admin_scope)
```

Run this focused file against a disposable `srql-fixtures` scratch database using `.agents/skills/srql-fixtures-db-tests/SKILL.md` and:

```bash
SERVICERADAR_REQUIRE_DB_TESTS=1 /usr/bin/script -q /dev/null mix test test/serviceradar/identity/timezone_preference_test.exs --trace
```

Expected: all listed tests execute and pass; do not accept an excluded/skipped/zero-test result.

- [ ] **Step 9: Run focused regression tests and commit**

Run the pure shards again, the notification schedule-timezone validation shard, `mix format --check-formatted` for changed Elixir files, and the focused DB test. Then commit:

```bash
git add elixir/serviceradar_core/lib/serviceradar/time_zone.ex elixir/serviceradar_core/lib/serviceradar/notifications/time_zone.ex elixir/serviceradar_core/lib/serviceradar/identity/changes/normalize_timezone_preference.ex elixir/serviceradar_core/lib/serviceradar/identity/validations/profile_timezone.ex elixir/serviceradar_core/lib/serviceradar/identity/user.ex elixir/serviceradar_core/priv/repo/migrations elixir/serviceradar_core/test/serviceradar/time_zone_test.exs elixir/serviceradar_core/test/serviceradar/notifications/time_zone_test.exs elixir/serviceradar_core/test/serviceradar/identity/validations/profile_timezone_test.exs elixir/web-ng/test/serviceradar/identity/timezone_preference_test.exs
git commit -m "feat(identity): add user timezone preference"
```

### Task 2: Semantic User-Time Component and Explicit-Zone Browser Formatter

**Files:**
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/components/core_components.ex`
- Create: `elixir/web-ng/test/phoenix/components/user_time_test.exs`
- Create: `elixir/web-ng/assets/js/utils/user_time.js`
- Create: `elixir/web-ng/assets/js/utils/user_time.test.js`
- Create: `elixir/web-ng/assets/js/hooks/UserTime.js`
- Create: `elixir/web-ng/assets/js/hooks/UserTime.test.js`
- Modify: `elixir/web-ng/assets/js/hooks/index.js`

**Interfaces:**
- Consumes: `DateTime.t() | NaiveDateTime.t() | canonical ISO-8601 binary | nil`, explicit IANA `timezone`, and `style` in `[:full, :compact, :date, :time, :axis]`.
- Produces: `CoreComponents.user_time/1`, semantic `<time phx-hook="UserTime" data-user-time-iso data-user-time-zone data-user-time-style>` markup, and JavaScript `formatUserTime(iso, {timeZone, style, locale, intl}) :: {text, offset, canonical} | null`.
- Produces: `axisUserTimeFormatter({timeZone, locale, intl}) :: (Date | number | string -> string)` for chart consumers without changing their input values.

- [ ] **Step 1: Write failing component tests**

Use `render_component(&CoreComponents.user_time/1, assigns)` and LazyHTML selectors. For `~U[2026-08-30 18:00:00Z]`, `timezone: "America/Chicago"`, `style: :full`, assert one `<time>` with:

```text
datetime="2026-08-30T18:00:00Z"
data-user-time-iso="2026-08-30T18:00:00Z"
data-user-time-zone="America/Chicago"
data-user-time-style="full"
phx-hook="UserTime"
```

Assert its initial visible text is deterministic UTC and its `title`/`aria-label` identifies both the canonical value and selected zone. Add a fractional fixture `~U[2026-08-30 18:00:00.123456Z]` and assert `datetime`, `data-user-time-iso`, accessibility metadata, and fallback text retain `.123456Z` exactly. Add nil/invalid input assertions that render the caller's fallback (default `—`) without a hook. Add an `Etc/UTC` assertion proving the disconnected render is correct without JavaScript.

- [ ] **Step 2: Run the component test and observe RED**

Run:

```bash
bazel test --test_output=errors //elixir/web-ng:unit_tests_phoenix_components
```

Expected: FAIL because `CoreComponents.user_time/1` does not exist.

- [ ] **Step 3: Implement the minimal semantic component**

Define constrained attrs and canonicalization helpers; do not accept arbitrary `Intl` option maps:

```elixir
attr :value, :any, required: true
attr :timezone, :string, default: "Etc/UTC"
attr :style, :atom, default: :full, values: [:full, :compact, :date, :time, :axis]
attr :fallback, :string, default: "—"
attr :id, :string, required: true
attr :class, :string, default: nil

def user_time(assigns) do
  case canonical_user_time(assigns.value) do
    {:ok, iso, utc_text} ->
      assigns = assign(assigns, iso: iso, utc_text: utc_text, zone: assigns.timezone || "Etc/UTC")
      ~H"""
      <time id={@id} class={@class} datetime={@iso} phx-hook="UserTime"
        data-user-time-iso={@iso} data-user-time-zone={@zone}
        data-user-time-style={@style}
        title={"#{@iso} (UTC); display zone #{@zone}"}
        aria-label={"#{@iso} UTC; display zone #{@zone}"}>{@utc_text}</time>
      """
    :error ->
      assigns = assign(assigns, :fallback_text, assigns.fallback)
      ~H"""<span class={@class}>{@fallback_text}</span>"""
  end
end
```

Convert naive values only as already-canonical UTC (`DateTime.from_naive!(value, "Etc/UTC")`), never truncate precision, and normalize the zone designator to a `Z` suffix while retaining all supplied fractional digits.

- [ ] **Step 4: Write failing pure formatter tests**

Use injected fake `intl` constructors for unsupported/missing behavior and real `Intl` for DST. Assert named styles only; no input path may omit `timeZone`. Required real cases:

```javascript
expect(formatUserTime("2026-11-01T06:30:00Z", {timeZone: "America/Chicago", style: "full", locale: "en-US"}).text).toContain("GMT-5")
expect(formatUserTime("2026-11-01T07:30:00Z", {timeZone: "America/Chicago", style: "full", locale: "en-US"}).text).toContain("GMT-6")
expect(formatUserTime("2026-03-08T07:30:00Z", {timeZone: "America/Chicago", style: "full", locale: "en-US"}).text).toContain("GMT-6")
expect(formatUserTime("2026-03-08T08:30:00Z", {timeZone: "America/Chicago", style: "full", locale: "en-US"}).text).toContain("GMT-5")
```

Assert invalid ISO, unsupported zone, absent `Intl.DateTimeFormat`, constructor failure, and format failure return `null`, allowing callers to retain UTC. For `2026-08-30T18:00:00.123456Z`, assert the formatter result and hook accessibility metadata retain that exact canonical string rather than JavaScript's millisecond-only `Date#toISOString()` result. Assert `axis` omits the offset while `full` and chart-tooltip style include it. Use `timeZoneName: "shortOffset"` with a tested fallback that derives a numeric offset from formatted parts; never fall back to implicit local time.

- [ ] **Step 5: Run the JavaScript tests and observe RED**

Run:

```bash
cd elixir/web-ng/assets
sfw bunx vitest run js/utils/user_time.test.js js/hooks/UserTime.test.js
```

Expected: FAIL because both production modules are absent.

- [ ] **Step 6: Implement the pure formatter and lifecycle hook**

Export a frozen named-style map and require explicit zone:

```javascript
export function formatUserTime(iso, {timeZone, style = "full", locale, intl = globalThis.Intl} = {}) {
  if (!timeZone || !STYLE_OPTIONS[style] || !intl?.DateTimeFormat) return null
  const instant = new Date(iso)
  if (Number.isNaN(instant.getTime())) return null

  try {
    const formatter = new intl.DateTimeFormat(locale, {...STYLE_OPTIONS[style], timeZone})
    const text = formatter.format(instant)
    return text ? {text, canonical: iso, offset: numericOffset(formatter, instant)} : null
  } catch (_error) {
    return null
  }
}
```

The hook calls the utility from both `mounted()` and `updated()`. It changes text only on success; on failure it restores/caches the server fallback rather than blanking or formatting with another zone. It updates `aria-label` to include localized text, numeric offset, selected zone, and canonical UTC.

- [ ] **Step 7: Register the hook and run GREEN checks**

Register `UserTime` in `assets/js/hooks/index.js`; leave `LocalTime` registered until Tasks 4 and 5 move its remaining consumers. Run the Task 2 ExUnit and Vitest commands and verify that deliberately removing `timeZone` makes at least one test fail.

- [ ] **Step 8: Commit the shared renderer**

```bash
git add elixir/web-ng/lib/serviceradar_web_ng_web/components/core_components.ex elixir/web-ng/test/phoenix/components/user_time_test.exs elixir/web-ng/assets/js/utils/user_time.js elixir/web-ng/assets/js/utils/user_time.test.js elixir/web-ng/assets/js/hooks/UserTime.js elixir/web-ng/assets/js/hooks/UserTime.test.js elixir/web-ng/assets/js/hooks/index.js
git commit -m "feat(web-ng): add explicit-zone timestamp renderer"
```

### Task 3: Profile Timezone Selector and Immediate Scope Refresh

**Files:**
- Create: `elixir/web-ng/assets/js/utils/timezone_options.js`
- Create: `elixir/web-ng/assets/js/utils/timezone_options.test.js`
- Create: `elixir/web-ng/assets/js/hooks/TimezoneSelect.js`
- Create: `elixir/web-ng/assets/js/hooks/TimezoneSelect.test.js`
- Modify: `elixir/web-ng/assets/js/hooks/index.js`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/user_live/settings.ex`
- Modify: `elixir/web-ng/test/phoenix/live/user_live/settings_test.exs`

**Interfaces:**
- Consumes: Task 1 `TimeZone.profile_timezones/1`, `User.update_timezone_preference/3`; Task 2 `UserTime` metadata through the updated `current_scope.user.timezone`.
- Produces: `filterTimezoneOptions(serverZones, currentZone, {intl}) :: [String]`, registered `TimezoneSelect` hook, LiveView assigns `timezone_catalog`, `timezone_ash_form`, `timezone_form`, and events `validate_timezone` / `update_timezone`.

- [ ] **Step 1: Write failing capability-filter tests**

Assert the exact selector rules:

```javascript
expect(filterTimezoneOptions(["America/Chicago", "Mars/Olympus"], "America/Chicago", {intl: noSupportedValuesOfIntl}))
  .toEqual(["Etc/UTC", "America/Chicago"])

expect(filterTimezoneOptions(["America/Chicago", "Europe/London"], "America/Chicago", {intl: undefined}))
  .toEqual(["Etc/UTC", "America/Chicago"])
```

When `supportedValuesOf("timeZone")` exists, intersect its values but still constructor-probe every survivor; always dedupe/sort while placing `Etc/UTC` first and retain the saved current value even when unsupported. The hook must filter unsupported server-rendered datalist options and preserve the input value across `updated()`.

- [ ] **Step 2: Run selector tests and observe RED**

Run:

```bash
cd elixir/web-ng/assets
sfw bunx vitest run js/utils/timezone_options.test.js js/hooks/TimezoneSelect.test.js
```

Expected: FAIL because the selector utility/hook are absent.

- [ ] **Step 3: Implement and register the selector hook**

The utility may call only `intl.supportedValuesOf` and `new intl.DateTimeFormat(undefined, {timeZone: zone})`; it never invents a server-unapproved zone. The hook reads the `<option value>` children of the `<datalist>` named by its `data-options-id`, applies the filtered set, and keeps `Etc/UTC` plus `data-current-timezone`. Register it as `TimezoneSelect`.

- [ ] **Step 4: Write failing LiveView profile tests**

Extend the DB-backed settings test with these observables:

- authenticated render contains `#timezone_form`, searchable `#user_timezone[list="timezone_catalog"]`, `#timezone_catalog`, `phx-hook="TimezoneSelect"`, `Etc/UTC`, `America/Chicago`, and a `data-current-timezone` matching the persisted user;
- the same render contains the current catalog shell's desktop navigation and mobile drawer (`#settings-nav-drawer`) while keeping `#timezone_form` inside the page-content slot;
- invalid direct submit `Etc/GMT+5` renders a field-level error and a fresh read retains the old value;
- valid submit renders `Timezone updated successfully.`, updates the persisted value, and `:sys.get_state(lv.pid).socket.assigns.current_scope` retains the previous `permissions` and `identity_claims` while its user has the new timezone;
- a fresh authenticated `live(~p"/settings/profile")` shows the saved zone;
- a fixed-instant `#timezone-preview` rendered after the submit carries `data-user-time-zone="America/Chicago"` without remounting.

- [ ] **Step 5: Run the focused profile tests and observe RED**

Against the Task 1 disposable scratch database, run:

```bash
SERVICERADAR_REQUIRE_DB_TESTS=1 /usr/bin/script -q /dev/null mix test test/phoenix/live/user_live/settings_test.exs --trace
```

Expected: the new tests execute and FAIL because the form and handlers are absent.

- [ ] **Step 6: Implement catalog loading, form, and handlers**

Set the disconnected-mount catalog to `Enum.uniq(["Etc/UTC", user.timezone])`. Only when `connected?(socket)` is true, call `TimeZone.profile_timezones/0` exactly once for that mount. On query failure, render only `Etc/UTC` plus the saved value and a non-destructive inline warning; do not change the preference. Build a separate form:

```elixir
defp build_timezone_form(user, scope) do
  AshPhoenix.Form.for_update(user, :update_timezone_preference,
    domain: ServiceRadar.Identity,
    as: "timezone_preference",
    scope: scope
  )
end
```

Render it in its own `ui_panel`, independent of email sudo mode and password permission. Use a text input named from `@timezone_form[:timezone]`, with `id="user_timezone"`, `list="timezone_catalog"`, `phx-hook="TimezoneSelect"`, `data-options-id="timezone_catalog"`, and `data-current-timezone={@current_scope.user.timezone}`. Render the approved server catalog as `<datalist id="timezone_catalog"><option :for={zone <- @timezone_catalog} value={zone} /></datalist>`. Free-form input is acceptable because the Ash action remains authoritative. Assign `timezone_preview_at = DateTime.utc_now()` once per mount and render `<.user_time id="timezone-preview" value={@timezone_preview_at} timezone={@current_scope.user.timezone} style={:full} />`; the instant stays unchanged when only the preference changes.

On success, preserve scope metadata and rebuild the form from the returned user:

```elixir
updated_scope = %{socket.assigns.current_scope | user: updated_user}
timezone_ash_form = build_timezone_form(updated_user, updated_scope)

socket
|> assign(:current_scope, updated_scope)
|> assign(:timezone_ash_form, timezone_ash_form)
|> assign(:timezone_form, to_form(timezone_ash_form))
|> put_flash(:info, "Timezone updated successfully.")
```

On error, retain the returned Ash form so the field error renders. Do not use `Scope.for_user/1` and do not add timezone to JWT/session claims.

- [ ] **Step 7: Run selector, component, and DB profile tests GREEN**

Run the Task 2 component test, selector Vitest files, focused settings file, and `bazel test --test_output=errors //elixir/web-ng:unit_tests_phoenix_other` for the catalog-shell contract. Reload through a second connection in the test to prove persistence rather than relying only on the current socket. The base branch has one catalog-driven `Shell.settings_chrome/1` and no `settings_ui` toggle; do not invent a retired original shell. The desktop navigation and mobile drawer assertions exercise both responsive chrome paths that actually exist on this branch.

- [ ] **Step 8: Commit the profile control**

```bash
git add elixir/web-ng/assets/js/utils/timezone_options.js elixir/web-ng/assets/js/utils/timezone_options.test.js elixir/web-ng/assets/js/hooks/TimezoneSelect.js elixir/web-ng/assets/js/hooks/TimezoneSelect.test.js elixir/web-ng/assets/js/hooks/index.js elixir/web-ng/lib/serviceradar_web_ng_web/live/user_live/settings.ex elixir/web-ng/test/phoenix/live/user_live/settings_test.exs
git commit -m "feat(web-ng): add profile timezone selector"
```

### Task 4: Observability Timestamp Presentation

**Files:**
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/show.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/metric_live/show.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/components/srql_components.ex`
- Modify: `elixir/web-ng/test/phoenix/live/log_live/index_test.exs`
- Modify: `elixir/web-ng/test/phoenix/live/log_live/show_test.exs`
- Modify: `elixir/web-ng/test/phoenix/components/srql_components_test.exs`
- Create: `elixir/web-ng/test/phoenix/live/metric_live/timestamp_rendering_test.exs`

**Interfaces:**
- Consumes: Task 2 `<.user_time id={stable_unique_id} value={canonical} timezone={@current_scope.user.timezone} style={:full}>`.
- Produces: localized human display for logs, syslog, SNMP traps, GELF/OTel logs, events, alerts, metrics, traces, correlated records, and SRQL time cells; canonical correlation/query values remain the existing ISO/DateTime values.

- [ ] **Step 1: Write failing rendering and canonical-pivot tests**

For a fixed `2026-08-30T18:00:00Z` fixture and a scope timezone `America/Chicago`, assert list/detail HTML contains a semantic `<time datetime="2026-08-30T18:00:00Z" data-user-time-zone="America/Chicago">`. Cover at least syslog, SNMP trap, OTel log, trace, and metric row/detail variants that share the LiveView. Render two rows and assert all `time[phx-hook="UserTime"]` ids are non-empty and unique.

In the same tests, trigger or call the existing correlation/pivot builder and assert its exact query bounds still contain canonical UTC strings. Add a syslog fixture with an unzoned source value plus a selected observed/effective canonical instant and assert the renderer receives the effective instant, not a reparsed source wall clock.

- [ ] **Step 2: Run focused observability tests and observe RED**

Run `bazel test --test_output=errors //elixir/web-ng:unit_tests_phoenix_components` for the component contract. Against the scratch database, run:

```bash
SERVICERADAR_REQUIRE_DB_TESTS=1 /usr/bin/script -q /dev/null mix test test/phoenix/live/log_live/index_test.exs test/phoenix/live/log_live/show_test.exs test/phoenix/live/metric_live/timestamp_rendering_test.exs --trace
```

Expected: the new semantic selectors fail while current canonical pivot assertions pass.

- [ ] **Step 3: Replace display strings with semantic values**

In `log_live/index.ex`, make `timestamp_meta/1` return canonical data (`%{iso: iso, value: dt}`) rather than preformatted display text, and render it through `<.user_time>`. Use stable ids derived from the existing row identity and signal kind: `log-time-<row-id>`, `trace-time-<row-id>`, `metric-time-<row-id>`, `event-time-<row-id>`, and `alert-time-<row-id>`; where a backend row has no id, use the existing stable stream/table DOM key rather than the wall-clock label. Replace the colocated `LocalTime` hook with the external `UserTime` contract. Apply the same boundary to trace/metric/event/alert rows and detail cards.

In `log_live/show.ex`, pass the canonical parsed instant into the semantic component with id `log-detail-time`. Use `metric-detail-time` in `metric_live/show.ex`. In `srql_components.ex`, derive ids as `srql-time-<row-index>-<column-index>` while enumerating rendered rows/cells. Do not change `format_time_short/1` where it is a relative/compact non-absolute visualization unless the inventory classifies it as a wall-clock absolute value.

In `metric_live/show.ex` and `srql_components.ex`, split parsing from rendering: parsers return `{:ok, DateTime.t(), iso}`; HEEx renders the `DateTime`/ISO with the scope timezone. Keep all href/query/pivot construction on `iso`.

- [ ] **Step 4: Prove machine-facing behavior is unchanged**

Add negative regressions that compare exact pre/post canonical values for:

```elixir
assert correlation_query =~ "time:[2026-08-30T17:00:00Z,2026-08-30T19:00:00Z]"
assert url_params["from"] == "2026-08-30T17:00:00Z"
assert api_payload["time"] == "2026-08-30T18:00:00Z"
```

Do not route controller serializers, CSV builders, or `ObservabilityPaths` through `user_time/1` or the JavaScript formatter.

- [ ] **Step 5: Run focused observability tests GREEN and commit**

Run every changed test shard, the Task 2 component/JS formatter tests, and `mix format --check-formatted` on changed Elixir. Then commit:

```bash
git add elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/show.ex elixir/web-ng/lib/serviceradar_web_ng_web/live/metric_live/show.ex elixir/web-ng/lib/serviceradar_web_ng_web/components/srql_components.ex elixir/web-ng/test
git commit -m "feat(web-ng): localize observability timestamps"
```

### Task 5: NetFlow Rows, Details, Windows, Axes, and Tooltips

**Files:**
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/view.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/view/flows_table.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/view/flow_modal.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/view/flows_panel.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/view/chart_panel.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/time_window.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize/format.ex`
- Modify: `elixir/web-ng/assets/js/netflow_charts/util.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowLineSeriesChart.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowStacked100Chart.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowGridChart.js`
- Modify: `elixir/web-ng/test/phoenix/live/log_live/netflow_chart_range_components_test.exs`
- Create: `elixir/web-ng/test/phoenix/live/netflow_live/timestamp_rendering_test.exs`
- Modify: `elixir/web-ng/assets/js/netflow_charts/util.test.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.test.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowGridChart.test.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowStacked100Chart.test.js`
- Create: `elixir/web-ng/assets/js/hooks/charts/NetflowLineSeriesChart.test.js`

**Interfaces:**
- Consumes: Task 2 `user_time/1`, `formatUserTime/2`, and `axisUserTimeFormatter/1`; canonical flow `time`, bucket `start/end`, and existing chart `Date`/epoch values.
- Produces: explicit `data-timezone` on chart roots, localized labels/tooltips, and unchanged `onZoom({start: start.toISOString(), end: end.toISOString()})` plus unchanged SRQL absolute windows.

- [ ] **Step 1: Write failing row/detail/window component tests**

Render each component with a fixed canonical flow timestamp and `timezone: "America/Chicago"`. Assert semantic `datetime` and zone metadata in the explorer row and modal. Render two flow rows and assert unique ids `netflow-row-time-0` and `netflow-row-time-1`; use `netflow-flow-detail-time` for the single modal instant. For an absolute window, assert two semantic endpoints with ids `netflow-window-start` and `netflow-window-end` rather than a preformatted ISO sentence; for a relative window, retain its duration label and do not apply a timezone.

- [ ] **Step 2: Write failing chart formatter and payload tests**

For every time-axis chart hook, assert its tick formatter receives the root's explicit `data-timezone`. Assert tooltips include a numeric GMT offset. Preserve and strengthen the existing selection test:

```javascript
expect(onZoom).toHaveBeenCalledWith({
  start: new Date(intervals[0].start).toISOString(),
  end: new Date(intervals[2].start).toISOString(),
})
```

Change the test browser/process timezone and assert the payload remains byte-for-byte identical while the visible label changes only according to the supplied saved zone.

- [ ] **Step 3: Run NetFlow tests and observe RED**

Run:

```bash
cd elixir/web-ng/assets
sfw bunx vitest run js/netflow_charts/util.test.js js/hooks/charts/NetflowStackedAreaChart.test.js js/hooks/charts/NetflowGridChart.test.js js/hooks/charts/NetflowLineSeriesChart.test.js js/hooks/charts/NetflowStacked100Chart.test.js
```

Also run:

```bash
bazel test --test_output=errors //elixir/web-ng:unit_tests_phoenix_live
```

Expected: label/metadata assertions fail; the existing canonical payload test remains green. The new NetFlow rendering test carries `@moduletag :db_free`, so this target must execute it rather than exclude it.

- [ ] **Step 4: Thread timezone only through presentation components**

At `Visualize.View`, derive a display-only zone from the current scope and pass it to `ChartPanel`, `FlowsPanel`, `FlowsTable`, and `FlowModal`. Do not pass it into `FlowList.load_flows_list/3`, `netflow_visualize/query.ex`, `RangeSelection`, or any SRQL builder.

Change `TimeWindow` to return a tagged result such as:

```elixir
{:absolute, %{start: start_dt, end: end_dt}}
{:relative, "Last 15 minutes"}
```

and let HEEx render absolute endpoints via `<.user_time id="netflow-window-start">` and `<.user_time id="netflow-window-end">` while preserving the original canonical DateTimes for requests. The explorer table retains its existing index-derived `nf-time-<idx>` identity renamed to `netflow-row-time-<idx>`; the detail modal uses `netflow-flow-detail-time`.

- [ ] **Step 5: Reuse the shared JS formatter for charts**

Read `this.el.dataset.timezone || "Etc/UTC"` only as explicit metadata. Pass it into shared axis/tooltip helpers. `attachTimeTooltip/2` formats `row.t` for display but never replaces or reparses `row.t`. Keep the exact `toISOString()` selection line and all scale domains untouched.

- [ ] **Step 6: Run NetFlow regressions GREEN and commit**

Run the exact Vitest command from Step 3, `bazel test --test_output=errors //elixir/web-ng:unit_tests_phoenix_live`, and the Task 2 formatter tests. Deliberately replace one selection payload with a formatted label and confirm the canonical-payload test fails, then restore it. Commit:

```bash
git add elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live elixir/web-ng/assets/js/netflow_charts/util.js elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.js elixir/web-ng/assets/js/hooks/charts/NetflowLineSeriesChart.js elixir/web-ng/assets/js/hooks/charts/NetflowStacked100Chart.js elixir/web-ng/assets/js/hooks/charts/NetflowGridChart.js elixir/web-ng/test elixir/web-ng/assets/js
git commit -m "feat(web-ng): localize NetFlow timestamp labels"
```

### Task 6: Complete UI Inventory, Remaining Surface Migration, and Build Guard

**Files:**
- Create: `elixir/web-ng/test/fixtures/timestamp_formatter_inventory.json`
- Create: `elixir/web-ng/test/phoenix/timestamp_formatter_inventory_test.exs`
- Modify: all remaining human-display files enumerated in the File Map.
- Delete: `elixir/web-ng/assets/js/hooks/LocalTime.js`
- Modify: `elixir/web-ng/assets/js/hooks/index.js`
- Create: `elixir/web-ng/assets/timestamp_formatter_test_runner.mjs`
- Modify: `elixir/web-ng/assets/BUILD.bazel`
- Modify: `elixir/web-ng/BUILD.bazel`
- Create: `elixir/web-ng/test/phoenix/user_timezone_surface_contract_test.exs`
- Create: `elixir/web-ng/test/phoenix/user_timezone_machine_boundary_test.exs`

**Interfaces:**
- Consumes: Tasks 1-5 shared renderer and already-migrated surfaces.
- Produces: inventory entries `%{"path" => binary, "matcher" => binary, "occurrence" => positive_integer, "classification" => "localized_display" | "canonical_machine" | "relative" | "fixed_utc" | "infrastructure", "reason" => binary | nil}`, and a test that fails on every unclassified direct timestamp formatter or retained `localized_display` direct formatter.

- [ ] **Step 1: Write the failing anti-vacuous inventory test**

Scan tracked `elixir/web-ng/lib/**/*.ex` and `elixir/web-ng/assets/js/**/*.js` sources (excluding tests, vendored/generated/static files) for direct time-formatting patterns:

```elixir
~r/Calendar\.strftime\(/
~r/DateTime\.to_iso8601\(/
~r/NaiveDateTime\.to_iso8601\(/
~r/\.toISOString\(\)/
~r/\.toLocale(?:String|DateString|TimeString)\(/
~r/Intl\.DateTimeFormat\(/
```

Name the matcher families `calendar_strftime`, `datetime_iso8601`, `naive_datetime_iso8601`, `js_to_iso_string`, `js_to_locale_time`, and `intl_date_time_format`. Number each match within its file and matcher family from one in source order. The test must assert at least one match for every pattern family present in production, reject duplicate inventory keys, reject missing files/matchers, require a positive `occurrence`, require a non-empty reason for `fixed_utc` and `infrastructure`, and compare the exact set of discovered `{path, matcher, occurrence}` keys to the JSON inventory. It must additionally fail while any entry has classification `localized_display`; those entries are the migration worklist, not allowed final exceptions. Classify the shared formatter implementation itself as `infrastructure` with reason `shared explicit-zone presentation contract`; do not use a broad directory exclusion.

- [ ] **Step 2: Create the initial complete inventory and observe RED for human displays**

Populate one entry for every current match. Use these rules:

- `localized_display`: the result becomes human-visible interactive HTML/chart text and must use the shared renderer;
- `canonical_machine`: query construction, scale/domain input, API/controller JSON, URL/event payload, CSV/download/export, generated bundle metadata, or persisted telemetry;
- `relative`: elapsed-duration labels such as “5 minutes ago” that do not represent wall time;
- `fixed_utc`: a truly human-visible UTC exception required by product behavior, with a visible UTC label and a specific reason.

Run:

```bash
bazel test --test_output=errors //elixir/web-ng:unit_tests_phoenix_other
```

Expected: FAIL with a bounded list of `localized_display` call sites still using direct formatters. After Step 4, remove inventory entries whose direct formatter disappeared and require the final inventory to contain zero `localized_display` entries; every remaining direct call is machine, relative, visibly fixed UTC, or shared infrastructure.

- [ ] **Step 3: Write failing remaining-surface tests**

Add at least one semantic timestamp assertion for each required family:

- dashboard/observability health;
- device/inventory/topology;
- gateway/infrastructure/service/scan;
- admin/audit/settings;
- JavaScript-authored dashboard/chart tooltip.

Each test uses a canonical fixture and non-UTC saved zone, asserts `<time datetime>`/explicit JS zone, and retains an exact canonical value assertion for any paired link/event/export. Every repeated-row fixture renders at least two records and asserts the `UserTime` ids are stable, non-empty, and unique.

- [ ] **Step 4: Migrate every `localized_display` inventory entry**

Replace server display helpers that return formatted strings with parsing helpers that return `DateTime`/canonical ISO, then render through `<.user_time id={"#{surface}-#{record_id}-#{field}"}>`. Derive each id from the resource primary key plus the timestamp field; for a list without record ids, use its existing stable row DOM key plus the field, never the formatted timestamp. Thread `timezone` only through function-component assigns where `current_scope` is not already available. For JS dashboards and chart hooks, use `formatUserTime` with a root `data-timezone` supplied by Phoenix.

Do not convert controller/API serializers, export builders, query modules, event payloads, notification HTML/delivery, report generation, or schedule evaluation. Keep relative duration helpers unchanged. Every retained fixed-UTC human display must visibly include `UTC` and explain why in the inventory.

After the last consumer moves, delete `LocalTime.js` and remove its registration. A repository search for `phx-hook="LocalTime"` and colocated `LocalTime` hook definitions must return no matches.

- [ ] **Step 5: Add exact machine-boundary regressions**

Exercise the concrete boundary fixtures in `user_timezone_machine_boundary_test.exs` and assert exact canonical values:

- SRQL/URL absolute bounds remain canonical values such as `2026-08-30T18:00:00Z` and do not contain localized labels;
- chart range event payloads equal server bucket strings;
- REST/JSON timestamp serializers return canonical ISO;
- CSV/download fixtures retain canonical UTC;
- notification schedule validation and `local_datetime/3` behavior remain unchanged;
- reports and schedule evaluation do not read `user.timezone`;
- relative labels remain durations.

These are negative boundary tests: they should fail if the shared presentation formatter is imported or called from the machine-facing module under test.

- [ ] **Step 6: Wire Bazel source and JavaScript tests**

In `assets/BUILD.bazel`, add a narrow `timestamp_formatter_test_srcs` filegroup containing `js/utils/user_time.js`, `js/utils/timezone_options.js`, `js/hooks/UserTime.js`, `js/hooks/TimezoneSelect.js`, NetFlow formatter/chart sources, and their tests. Add this target using the repository's JavaScript test runner entry point resolved from the existing `god_view_scene_tests` pattern:

```starlark
js_test(
    name = "timestamp_formatter_tests",
    size = "small",
    args = [
        "$(rootpath %s)" % test
        for test in glob([
            "js/utils/user_time.test.js",
            "js/utils/timezone_options.test.js",
            "js/hooks/UserTime.test.js",
            "js/hooks/TimezoneSelect.test.js",
            "js/netflow_charts/util.test.js",
            "js/hooks/charts/Netflow*Chart.test.js",
        ])
    ],
    chdir = package_name(),
    data = [":timestamp_formatter_test_srcs", ":node_modules"],
    entry_point = "timestamp_formatter_test_runner.mjs",
    tags = ["unit_test"],
)
```

Create `elixir/web-ng/assets/timestamp_formatter_test_runner.mjs` with the runfiles-aware contract:

```javascript
import {startVitest} from "vitest/node"
import {resolve} from "node:path"

const runfilesRoot = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE)
const filters = process.argv.slice(2).map((filter) => resolve(runfilesRoot, filter))
const context = await startVitest("test", filters, {
  root: process.cwd(),
  run: true,
  watch: false,
})

await context.exit()
```

Add an audit-source filegroup covering production JS and declare it plus `test/fixtures/timestamp_formatter_inventory.json` in `//elixir/web-ng:unit_tests` data. Do not use an undeclared workspace path and do not add a script.

- [ ] **Step 7: Run the inventory and surface-contract tests GREEN**

Run:

```bash
bazel test --test_output=errors //elixir/web-ng/assets:timestamp_formatter_tests
bazel test --test_output=errors //elixir/web-ng:unit_tests
```

Inspect output and confirm the new inventory test and JavaScript files actually execute. Add one temporary unclassified formatter in a test fixture/source, observe the guard fail with `path:line`, then remove it and rerun green.

- [ ] **Step 8: Reconcile active changes and commit**

Fetch/rebase only if explicitly required by the current branch state. Compare the final diff against active OpenSpec deltas `redesign-settings-catalog-nav`, `refactor-otel-signal-correlation`, `improve-syslog-ingestion-fidelity`, `add-netflow-chart-range-selection`, and `improve-attributed-flow-investigation`. Preserve their full requirements and do not replace canonical pivot/range logic with display strings.

Commit:

```bash
git add elixir/web-ng/test/fixtures/timestamp_formatter_inventory.json elixir/web-ng/test/phoenix/timestamp_formatter_inventory_test.exs elixir/web-ng/lib elixir/web-ng/assets/js elixir/web-ng/assets/BUILD.bazel elixir/web-ng/BUILD.bazel elixir/web-ng/test
git commit -m "feat(web-ng): complete user-timezone UI coverage"
```

### Task 7: Final Verification and OpenSpec Closure

**Files:**
- Modify: `openspec/changes/add-user-timezone-preferences/tasks.md`
- Modify only for corrections found during verification: files from Tasks 1-6.

**Interfaces:**
- Consumes: all previous task outputs.
- Produces: a verified branch whose checked OpenSpec tasks accurately reflect implementation and whose full repository test contract passes.

- [ ] **Step 1: Run formatting and focused contracts**

Run these exact targets and focused DB files, then read every summary and verify non-zero test counts:

```bash
bazel test --test_output=errors //elixir/serviceradar_core:unit_tests_serviceradar_other //elixir/serviceradar_core:unit_tests_serviceradar_notifications
bazel test --test_output=errors //elixir/web-ng/assets:timestamp_formatter_tests
bazel test --test_output=errors //elixir/web-ng:unit_tests_phoenix_components //elixir/web-ng:unit_tests_phoenix_live //elixir/web-ng:unit_tests_phoenix_other
bazel test --test_output=errors //elixir/web-ng:unit_tests
cd elixir/web-ng
SERVICERADAR_REQUIRE_DB_TESTS=1 /usr/bin/script -q /dev/null mix test test/serviceradar/identity/timezone_preference_test.exs test/phoenix/live/user_live/settings_test.exs test/phoenix/live/log_live/index_test.exs test/phoenix/live/log_live/show_test.exs test/phoenix/live/metric_live/timestamp_rendering_test.exs --trace
```

Run `mix format --check-formatted` in `elixir/serviceradar_core` and `elixir/web-ng` before these tests.

- [ ] **Step 2: Run web-ng precommit and repository-wide tests**

Run:

```bash
cd elixir/web-ng && /usr/bin/script -q /dev/null mix precommit
cd /private/tmp/serviceradar-issue-3555 && make test
```

The worktree already contains valid `.bazelrc.remote` and `.bazelrc.local` symlinks. If sandbox permissions block Bazel cache access, rerun with the normal approved escalation rather than changing the cache configuration. Expected: full pass with no failing targets.

- [ ] **Step 3: Perform manual invariant searches**

Require all of these checks to have an explicit success/failure branch:

```bash
if rg -n 'phx-hook="LocalTime"|LocalTime\s*[:=]' elixir/web-ng; then
  echo "unexpected LocalTime consumer remains" >&2
  exit 1
else
  status=$?
  test "$status" -eq 1 || exit "$status"
fi

rg -n 'toLocale(?:String|DateString|TimeString)\(' elixir/web-ng/assets/js
rg -n 'Calendar\.strftime\(|DateTime\.to_iso8601\(|toISOString\(\)' elixir/web-ng/lib elixir/web-ng/assets/js
```

For the latter two, reconcile every result to the inventory; do not treat an empty grep or a job exit code alone as evidence.

- [ ] **Step 4: Verify OpenSpec and check off only proven work**

Run:

```bash
openspec validate add-user-timezone-preferences --strict
```

Update `tasks.md` checkboxes only for requirements proven by code/tests. Leave any unverified item unchecked and report it instead of claiming completion.

- [ ] **Step 5: Request task and whole-branch review**

Run the subagent-driven-development task reviewer after each implementation task, then a fresh whole-branch reviewer over `origin/staging...HEAD`. Resolve every Blocker/Important finding through a new red-green cycle and rerun the affected tests.

- [ ] **Step 6: Commit verification metadata**

```bash
git add openspec/changes/add-user-timezone-preferences/tasks.md
git commit -m "docs(openspec): record timezone verification"
```

Do not push or open a pull request unless the user explicitly asks for that external action.
