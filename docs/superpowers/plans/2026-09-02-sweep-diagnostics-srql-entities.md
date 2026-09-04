# Sweep Diagnostics SRQL Entities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the sweep data collected by plan 1 as seven read-only SRQL entities, reachable through the existing generic MCP tools, with credentials structurally unreachable and the entity permission gate actually enforcing.

**Architecture:** Five entities read plain tables through the standard diesel query-module pattern. Two are view-backed and follow the `addon_fleet` precedent: a view created by raw `execute` in an Ecto migration, read through `diesel::sql_query` with a `to_jsonb` projection, deliberately absent from `schema.rs`. `sweep_compiled_config` projects named JSON paths out of `agent_config_versions` for sweep config instances only, so no compiled-config document is ever selected. Before any of that, the pre-existing token-order bypass in the entity permission gate is closed, because an admin-gated entity behind a bypassable gate is decorative.

**Tech Stack:** Rust (diesel, diesel-async), Elixir/Phoenix, Ecto/PostgreSQL, ExUnit, Bazel, OpenSpec.

**Spec:** `openspec/changes/add-sweep-diagnostics-srql-entities/`

**Depends on:** `docs/superpowers/plans/2026-09-02-sweep-diagnostics-write-path.md`. Tasks 6 and 7 read `sweep_host_results.scanned_ports`, `.agent_id`, `.sweep_group_id` and `platform.sweep_coverage_daily`, all created by plan 1. Tasks 1 through 5 do not depend on it and may land first.

## Global Constraints

These were established by reading the code, not by assumption. Several contradict what a reasonable person would guess.

- **Exactly three exhaustive matches over `Entity`** exist: `rust/srql/src/query/engine.rs`, `rust/srql/src/query/translate.rs`, and `rust/srql/src/query/viz/mod.rs`. None has a `_` arm, so the compiler names all three when you add a variant. Trust the compiler here.
- **`parser/entity.rs` is NOT exhaustive** — it ends in a fallthrough returning "unsupported entity". A missing alias is a runtime error, not a compile error.
- **No Bazel edit is needed for new `.rs` files.** `rust/srql/BUILD.bazel` uses `srcs = glob(["src/**/*.rs"])`, and the NIF and web-ng test targets glob the same way. Only a new crate dependency needs the root `Cargo.toml`. Still finish with `bazel build //rust/...`: a green `cargo check` does not prove the Bazel build.
- **Diesel table names are bare** (`sweep_host_results`, never `platform.sweep_host_results`). The schema comes from the connection role's `search_path`.
- **A view-backed entity must NOT be added to `schema.rs`.** All entries there are real tables. Views are read with `diesel::sql_query` plus a `QueryableByName` struct holding a single `Jsonb` payload column.
- **`time:` is parsed for every entity and applied by none.** If the entity module never reads `plan.time_range`, `time:last_24h` is silently ignored and returns unfiltered rows. `graph_cypher.rs` has this bug today.
- **An entity supporting `stats:` must write the time predicate TWICE** — once in the row builder, once in the aggregate builder. See `composite_results.rs` and `composite_results/stats.rs`. Omitting the second makes `stats:` silently ignore the window.
- **Non-CAGG entities are capped at a 90-day query window** by `max_time_range_days_for_ast` (`query/cagg.rs`). `sweep_coverage_daily` is retained 400 days, so the cap must admit it or the entity rejects the queries it exists to serve.
- **`bucket:` is rejected for non-metric entities** before the per-entity match runs. Do not try to support it.
- **There is no `date_trunc` anywhere in rust/srql.** Grouping by day requires a real `day` column, which `sweep_coverage_daily` has.
- **Mapping an entity in `EntityAccess` is mandatory.** `entity_access_test.exs` fails on any catalog entity with no permission mapping, and an unmapped entity is `:passthrough`, meaning allowed. That test is the only thing preventing a silently ungated entity.
- **Every catalog id must parse through the Rust NIF.** A second test asserts it, so the Elixir catalog and the Rust parser cannot drift.
- **MCP denials are JSON-RPC 200 with `isError: true` and body text "forbidden"**, not HTTP 403. Do not assert 403 in an MCP test.
- **`in:dashboards` is a hardcoded passthrough in two places.** Never model a sweep entity on it.
- Limit and offset binds are pushed LAST in the view-backed builder because they appear last in the format string. Any bind pushed after them binds the wrong value.
- Use strict TDD: write the failing test, run it, read the actual failure, then write the minimum production code.

---

## Task 1: Close the entity permission gate bypass

This is a live hole in shipped code affecting every gated entity, not something this change introduces. It is first because tasks 4 and 5 add an admin-gated entity, and a gate that falls to reordering two tokens protects nothing.

**Files:**

- Modify: `elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex` (`extract_entity/1`, around line 155)
- Modify: `elixir/web-ng/test/.../srql/entity_access_test.exs`

**Interfaces:**

- Consumes: nothing.
- Produces: `EntityAccess.extract_entity/1` resolving the entity from any token position, matching the Rust parser.

- [ ] **Step 1: Write the failing test**

Add to the existing `entity_access_test.exs`:

```elixir
  describe "extract_entity/1 token position" do
    test "resolves the entity when in: is not the first token" do
      assert EntityAccess.extract_entity("limit:1 in:devices") == "devices"
      assert EntityAccess.extract_entity("time:last_24h in:devices limit:5") == "devices"
      assert EntityAccess.extract_entity("sort:name:asc in:devices") == "devices"
    end

    test "gates a non-leading entity token the same as a leading one" do
      scope = scope_without_permission("devices.view")

      assert {:error, :forbidden} = EntityAccess.authorize("in:devices limit:1", scope)
      assert {:error, :forbidden} = EntityAccess.authorize("limit:1 in:devices", scope)
    end
  end
```

Match `authorize/2` and the scope helper to the module's real API; read `entity_access.ex` and the existing tests first and reuse their helpers rather than inventing new ones.

- [ ] **Step 2: Run the test and read the failure**

```bash
cd elixir/web-ng && mix test test/serviceradar_web_ng/srql/entity_access_test.exs
```

Expected: `"limit:1"` returned instead of `"devices"`, and the second assertion returning `:ok` where `{:error, :forbidden}` was expected. That `:ok` is the vulnerability — confirm you see it before fixing.

- [ ] **Step 3: Extract the entity the way the parser does**

Replace the anchored regex in `extract_entity/1`. The parser scans every whitespace-separated token for one beginning `in:`; do the same, taking the first match:

```elixir
  @spec extract_entity(String.t()) :: String.t()
  def extract_entity(query) when is_binary(query) do
    query
    |> String.split(~r/[\s|]+/, trim: true)
    |> Enum.find_value(fn token ->
      case token do
        "in:" <> entity when entity != "" -> normalize_entity(entity)
        _ -> nil
      end
    end)
    |> case do
      nil -> fallback_entity(query)
      entity -> entity
    end
  end

  defp normalize_entity(entity) do
    entity
    |> String.trim("\"")
    |> String.trim("'")
    |> String.downcase()
  end
```

Keep the existing no-`in:` fallback behavior intact as `fallback_entity/1` — moving it is refactoring, changing it is a separate decision.

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
cd elixir/web-ng && mix test test/serviceradar_web_ng/srql/entity_access_test.exs
```

Expected: PASS, including every pre-existing test. A pre-existing failure here means the fallback changed behavior — fix that before moving on.

- [ ] **Step 5: Mutation-check**

Restore the anchored regex temporarily. The non-leading tests MUST fail. Revert.

- [ ] **Step 6: Commit**

```bash
cd elixir/web-ng && mix format
git add lib/serviceradar_web_ng/srql/entity_access.ex test/serviceradar_web_ng/srql/entity_access_test.exs
git commit -m "fix(srql): resolve the gated entity from any token position"
```

---

## Task 2: First entity end-to-end (`sweep_groups`)

This is the template. Tasks 3 substitutes into it, so get it exactly right.

**Files (the ten-file pattern, in dependency order):**

- Modify: `rust/srql/src/schema.rs` — `diesel::table!` block
- Modify: `rust/srql/src/models/inventory.rs` — row struct + `into_json`
- Modify: `rust/srql/src/models/mod.rs` — re-export
- Modify: `rust/srql/src/parser/ast.rs` — `Entity` variant
- Modify: `rust/srql/src/parser/entity.rs` — alias arm
- Create: `rust/srql/src/query/sweep_groups.rs`
- Modify: `rust/srql/src/query/mod.rs` — `mod sweep_groups;`
- Modify: `rust/srql/src/query/translate.rs` — `use` list + match arm
- Modify: `rust/srql/src/query/engine.rs` — `use` list + match arm
- Modify: `rust/srql/src/query/viz/inventory.rs` + `viz/mod.rs` — column metadata + match arm
- Modify: `rust/srql/src/parser/tests.rs`, `rust/srql/src/query/tests/entity_examples.rs`

**Interfaces:**

- Produces: `Entity::SweepGroups`, `query::sweep_groups::{execute, to_sql_and_params}`, `models::SweepGroupRow`. Tasks 3 through 7 all mirror these names.

- [ ] **Step 1: Write the failing entity-example test**

Add to `rust/srql/src/query/tests/entity_examples.rs`. No import edit is needed: the file's `use super::*` chains to `query/tests.rs`, which globs every private module from `query/mod.rs`.

```rust
#[test]
fn sweep_groups_example_partition_and_enabled() {
    let query = "in:sweep_groups partition:default enabled:true sort:name:asc";
    let plan = plan_for(query);

    assert!(matches!(plan.entity, Entity::SweepGroups));
    let (sql, _) = sweep_groups::to_sql_and_params(&plan).expect("should build sweep_groups SQL");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("from \"sweep_groups\""),
        "expected query against sweep_groups, got: {sql}"
    );
    assert!(
        lower.contains("\"sweep_groups\".\"partition\" =")
            && lower.contains("\"sweep_groups\".\"enabled\" ="),
        "expected partition + enabled filters in SQL, got: {sql}"
    );
    assert!(
        lower.contains("order by \"sweep_groups\".\"name\" asc"),
        "expected name asc ordering, got: {sql}"
    );
}
```

- [ ] **Step 2: Run it and read the failure**

```bash
cd rust/srql && cargo test sweep_groups_example
```

Expected: compile error, `cannot find value sweep_groups` / no variant `SweepGroups`.

- [ ] **Step 3: Add the diesel table**

In `rust/srql/src/schema.rs`, add a `diesel::table!` block. Bare table name. Column list must match the migration exactly including nullability, or `check_for_backend(diesel::pg::Pg)` fails to compile:

```rust
diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    sweep_groups (id) {
        id -> Uuid,
        name -> Text,
        description -> Nullable<Text>,
        partition -> Text,
        agent_id -> Nullable<Text>,
        agent_ids -> Array<Text>,
        enabled -> Bool,
        interval -> Text,
        schedule_type -> Text,
        cron_expression -> Nullable<Text>,
        static_targets -> Array<Text>,
        ports -> Nullable<Array<Int8>>,
        sweep_modes -> Nullable<Array<Text>>,
        emit_availability_events -> Bool,
        last_run_at -> Nullable<Timestamptz>,
        profile_id -> Nullable<Uuid>,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}
```

Deliberately omitted: `target_criteria` and `overrides`. Both are operator-authored jsonb whose contents are not part of this contract; add them only if a diagnostic actually needs them.

- [ ] **Step 4: Add the row struct**

In `rust/srql/src/models/inventory.rs`, following the `AddonStatusRow` shape. `into_json` defines the wire contract — the keys here are what an operator sees:

```rust
#[derive(Debug, Queryable, Selectable, Serialize)]
#[diesel(table_name = crate::schema::sweep_groups, check_for_backend(diesel::pg::Pg))]
pub struct SweepGroupRow {
    pub id: uuid::Uuid,
    pub name: String,
    pub description: Option<String>,
    pub partition: String,
    pub agent_ids: Vec<String>,
    pub enabled: bool,
    pub interval: String,
    pub schedule_type: String,
    pub cron_expression: Option<String>,
    pub static_targets: Vec<String>,
    pub ports: Option<Vec<i64>>,
    pub sweep_modes: Option<Vec<String>>,
    pub emit_availability_events: bool,
    pub last_run_at: Option<chrono::DateTime<chrono::Utc>>,
    pub profile_id: Option<uuid::Uuid>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

impl SweepGroupRow {
    pub fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "sweep_group_id": self.id,
            "name": self.name,
            "description": self.description,
            "partition": self.partition,
            "agent_ids": self.agent_ids,
            "enabled": self.enabled,
            "interval": self.interval,
            "schedule_type": self.schedule_type,
            "cron_expression": self.cron_expression,
            "static_targets": self.static_targets,
            "ports": self.ports,
            "sweep_modes": self.sweep_modes,
            "emit_availability_events": self.emit_availability_events,
            "last_run_at": self.last_run_at,
            "profile_id": self.profile_id,
            "updated_at": self.updated_at,
        })
    }
}
```

The struct field order must match the `table!` column order for `Queryable`, or you get a confusing type error. Add `SweepGroupRow` to the `pub use inventory::{...}` list in `models/mod.rs`, alphabetically.

- [ ] **Step 5: Register the entity in the parser**

`rust/srql/src/parser/ast.rs`, in `pub enum Entity`:

```rust
    SweepGroups,
```

`rust/srql/src/parser/entity.rs`, in `parse_entity`'s match:

```rust
        "sweep_groups" | "sweep_group" | "sweeps" => Ok(Entity::SweepGroups),
```

- [ ] **Step 6: Write the query module**

Create `rust/srql/src/query/sweep_groups.rs` by copying `rust/srql/src/query/addon_statuses.rs` verbatim and substituting. That file is the canonical 292-line template and contains every function the pattern requires: `execute`, `to_sql_and_params`, `ensure_entity`, `build_query`, `apply_filter`, `collect_text_params`, `collect_filter_params`, `apply_ordering`, `apply_single_order`, `apply_secondary_order`, and a `#[cfg(test)] mod tests`.

Substitutions:

| In `addon_statuses.rs` | In `sweep_groups.rs` |
|---|---|
| `addon_statuses` (table, dsl, type aliases) | `sweep_groups` |
| `AddonStatusRow` | `SweepGroupRow` |
| `Entity::AddonStatuses` | `Entity::SweepGroups` |
| time column `reported_at` | `updated_at` |
| default order `reported_at desc` | `name asc` |
| filter fields `agent_uid`, `addon_id`, `state`, `version`, `arch` | `name`, `partition`, `enabled`, `schedule_type`, `profile_id` |

Two things to keep from the template rather than simplify away: `build_query` must read `plan.time_range` and emit the predicate (otherwise `time:` is silently ignored), and `to_sql_and_params` must keep the `#[cfg(any(test, debug_assertions))]` bind-count assertion, which is what catches a filter added to the SQL but not to the params.

For `agent_id`, filter against the `agent_ids` array with a containment predicate, not equality: a group can be assigned to several agents and equality on the legacy scalar would silently miss them.

- [ ] **Step 7: Wire the three exhaustive matches**

```bash
cd rust/srql && cargo check
```

The compiler names all three. Add `mod sweep_groups;` to `query/mod.rs` (alphabetically, after the `#[macro_use] mod filters_common;` line, which must stay first), then:

- `query/translate.rs`: add `sweep_groups` to the `use super::{...}` list and `Entity::SweepGroups => sweep_groups::to_sql_and_params(&plan)?,` to the match.
- `query/engine.rs`: same `use` addition and `Entity::SweepGroups => sweep_groups::execute(&mut conn, &plan).await?,`.
- `query/viz/mod.rs`: `Entity::SweepGroups => inventory::sweep_groups(),`.

- [ ] **Step 8: Add viz column metadata**

In `rust/srql/src/query/viz/inventory.rs`:

```rust
pub(super) fn sweep_groups() -> VizMeta {
    VizMeta {
        columns: vec![
            col("sweep_group_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("partition", ColumnType::Text, None),
            col("agent_ids", ColumnType::Text, None),
            col("enabled", ColumnType::Bool, None),
            col("interval", ColumnType::Text, None),
            col("schedule_type", ColumnType::Text, None),
            col("ports", ColumnType::Text, None),
            col("sweep_modes", ColumnType::Text, None),
            col(
                "last_run_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}
```

- [ ] **Step 9: Add the parser alias test**

In `rust/srql/src/parser/tests.rs`, following the `endpoint_inventory_scans` alias test:

```rust
#[test]
fn parses_sweep_groups_aliases() {
    for alias in ["sweep_groups", "sweep_group", "sweeps"] {
        let ast = parse(&format!("in:{alias} limit:1")).unwrap();
        assert!(matches!(ast.entity, Entity::SweepGroups), "alias {alias} failed");
    }
}
```

- [ ] **Step 10: Run and commit**

```bash
cd rust/srql && cargo fmt && cargo clippy && cargo test sweep_groups
```

Expected: PASS. Then:

```bash
git add rust/srql/src
git commit -m "feat(srql): add sweep_groups entity"
```

---

## Task 3: The four remaining table-backed entities

Apply Task 2's ten-file pattern once per entity, copying `addon_statuses.rs` as the module template each time. Do not shortcut by making one generic module: the pattern is per-entity by design, and every existing entity follows it.

Commit after each entity so a reviewer can reject one without rejecting four.

**Per-entity specification:**

| Entity | Aliases | Table | Row struct | Time column | Default sort | Filter + sort fields |
|---|---|---|---|---|---|---|
| `sweep_profiles` | `sweep_profile`, `scanner_profiles`, `scanner_profile` | `sweep_profiles` | `SweepProfileRow` | `updated_at` | `name asc` | `name`, `enabled`, `admin_only` |
| `sweep_executions` | `sweep_execution`, `sweep_group_executions` | `sweep_group_executions` | `SweepExecutionRow` | `started_at` | `started_at desc` | `status`, `agent_id`, `sweep_group_id`, `config_version` |
| `sweep_results` | `sweep_result`, `sweep_host_results` | `sweep_host_results` | `SweepResultRow` | `inserted_at` | `inserted_at desc` | `ip`, `hostname`, `status`, `device_id`, `agent_id`, `sweep_group_id`, `execution_id` |
| `sweep_coverage` | `sweep_coverage_daily` | `sweep_coverage_daily` | `SweepCoverageRow` | `day` | `day desc` | `device_uid`, `ip`, `sweep_group_id`, `agent_id` |

**Field-level requirements that are not mechanical:**

- [ ] **3.1 `sweep_profiles` exposes banner grab as two fields only.** Project `banner_grab_enabled` (bool) and `banner_grab_protocols` (text array) out of the embedded map. Do NOT expose the timeout, concurrency, rate-limit or queue-size knobs: writes are gated on `networks.sweeps.banner_grab`, reads through SRQL are not, and those knobs carry no diagnostic value for this issue. `icmp_settings` and `tcp_settings` are exposed as-is — they are scan tuning, audited as carrying no credential material.

- [ ] **3.2 `sweep_results` exposes coverage, not a derived closed set.** Project `scanned_ports` and `open_ports` as separate arrays and let the operator subtract. Do not add a computed `closed_ports` column: the subtraction is trivial in a query, and a stored derivation would go stale against the two arrays it derives from.

- [ ] **3.3 `sweep_results` and `sweep_coverage` project modes explicitly.** `sweep_modes_results` is the requested-versus-observed record; surface it as `modes_results` (jsonb) on results, and `modes_requested` / `modes_observed` (text arrays) on coverage. An operator must be able to answer "was TCP requested here" without parsing a blob in their head.

- [ ] **3.4 `sweep_coverage` uses `day` as its time column.** There is no `date_trunc` anywhere in rust/srql, so a day grouping must be a real column. It is one, by construction from plan 1.

- [ ] **3.5 Each entity gets its own entity-example test and parser-alias test**, following Task 2 steps 1 and 9 exactly. Assert the real table name in `FROM`, each filter's rendered predicate, and the default ORDER BY.

- [ ] **3.6 Run `cargo fmt && cargo clippy && cargo test` and commit after each entity.**

---

## Task 4: `device_sweep_overlap` (view-backed)

The diagnostic the issue is really asking for: which groups were *declared* to target a device versus which actually *produced results* for it. Declared-but-not-observed is the reported symptom.

Declared targeting is not stored anywhere as a relation — `SweepCompiler` resolves it by paging SRQL at compile time. But the resolved list survives in the compiled config's `targets` and `device_targets`, versioned per agent. That is where the declared side comes from.

**Files:**

- Create: `elixir/serviceradar_core/priv/repo/migrations/20260902140000_create_device_sweep_overlap_view.exs`
- Create: `rust/srql/src/query/device_sweep_overlap.rs`
- Modify: the parser, `query/mod.rs`, the three exhaustive matches, viz metadata, tests

**Interfaces:**

- Consumes: `platform.sweep_coverage_daily` (plan 1), `platform.device_agent_availability`, `platform.agent_config_instances`.
- Produces: `Entity::DeviceSweepOverlap`, `platform.device_sweep_overlap`.

- [ ] **Step 1: Write the view migration**

Follow the `addon_fleet` precedent (`20260720180000_add_addon_fleet_read_model.exs`): raw `execute` with a matching `DROP VIEW IF EXISTS` in `down`.

The view has one row per (device, sweep group, agent) with a `relationship` column taking `declared_and_observed`, `declared_not_observed`, or `observed_not_declared`, plus a boolean marking which row currently owns the `device_agent_availability` slot.

```elixir
defmodule ServiceRadar.Repo.Migrations.CreateDeviceSweepOverlapView do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    CREATE VIEW platform.device_sweep_overlap AS
    WITH declared AS (
      SELECT
        i.agent_id,
        (g.value ->> 'sweep_group_id')::uuid AS sweep_group_id,
        COALESCE(dt.value ->> 'network', t.value) AS target,
        i.last_delivered_at
      FROM platform.agent_config_instances i
      CROSS JOIN LATERAL jsonb_array_elements(i.compiled_config -> 'groups') AS g(value)
      LEFT JOIN LATERAL jsonb_array_elements(g.value -> 'device_targets') AS dt(value) ON TRUE
      LEFT JOIN LATERAL jsonb_array_elements_text(g.value -> 'targets') AS t(value) ON TRUE
      WHERE i.config_type = 'sweep'
    ),
    observed AS (
      SELECT device_uid, ip, sweep_group_id, agent_id,
             MAX(last_seen_at) AS last_seen_at,
             SUM(available_count) AS available_count,
             SUM(execution_count) AS execution_count
      FROM platform.sweep_coverage_daily
      GROUP BY device_uid, ip, sweep_group_id, agent_id
    )
    SELECT
      COALESCE(o.device_uid, d_dev.uid) AS device_uid,
      COALESCE(o.ip, dec.target) AS ip,
      COALESCE(o.sweep_group_id, dec.sweep_group_id) AS sweep_group_id,
      COALESCE(o.agent_id, dec.agent_id) AS agent_id,
      sg.name AS sweep_group_name,
      sg.profile_id,
      sp.name AS scanner_profile_name,
      sg.sweep_modes AS declared_modes,
      sg.ports AS declared_ports,
      (dec.sweep_group_id IS NOT NULL) AS declared,
      (o.sweep_group_id IS NOT NULL) AS observed,
      CASE
        WHEN dec.sweep_group_id IS NOT NULL AND o.sweep_group_id IS NOT NULL
          THEN 'declared_and_observed'
        WHEN dec.sweep_group_id IS NOT NULL THEN 'declared_not_observed'
        ELSE 'observed_not_declared'
      END AS relationship,
      o.last_seen_at,
      o.available_count,
      o.execution_count,
      dec.last_delivered_at AS config_delivered_at,
      (daa.sweep_group_id IS NOT DISTINCT FROM COALESCE(o.sweep_group_id, dec.sweep_group_id))
        AS owns_availability_row
    FROM observed o
    FULL OUTER JOIN declared dec
      ON dec.sweep_group_id = o.sweep_group_id
     AND dec.agent_id = o.agent_id
     AND dec.target = o.ip
    LEFT JOIN platform.ocsf_devices d_dev ON d_dev.ip = dec.target
    LEFT JOIN platform.sweep_groups sg
      ON sg.id = COALESCE(o.sweep_group_id, dec.sweep_group_id)
    LEFT JOIN platform.sweep_profiles sp ON sp.id = sg.profile_id
    LEFT JOIN platform.device_agent_availability daa
      ON daa.device_uid = COALESCE(o.device_uid, d_dev.uid)
     AND daa.agent_id = COALESCE(o.agent_id, dec.agent_id)
    """)
  end

  def down do
    execute("DROP VIEW IF EXISTS platform.device_sweep_overlap")
  end
end
```

- [ ] **Step 2: Verify the view against real data before writing any Rust**

Against a scratch database from the `srql-fixtures-db-tests` skill, apply the migration and run the view with seeded rows covering all three `relationship` values. A view whose SQL you have not executed is a guess. Fix it here, where the feedback loop is seconds, not after six Rust files exist on top of it.

Confirm specifically: a group declared for a device that produced no results yields exactly one `declared_not_observed` row, and the `FULL OUTER JOIN` does not fan out into duplicates when a group declares several targets.

- [ ] **Step 3: Write the query module on the sql_query pattern**

Copy `rust/srql/src/query/addon_fleet.rs`. This is the view pattern and it is NOT the `addon_statuses` pattern:

- No `schema.rs` entry. Views are absent from `table!` by convention, and adding one would be the first exception.
- A `QueryableByName` struct with a single `Jsonb` `payload` column, read via `SELECT to_jsonb(alias) AS payload FROM platform.device_sweep_overlap AS alias ...`.
- `to_sql_and_params` MUST call `rewrite_placeholders` to turn diesel's `?` into `$1..$n`. Skipping it yields SQL with literal `?` in the `/translate` preview while the runtime path still works — a divergence that will not show up in a smoke test.
- Push the limit and offset binds LAST, after all filter binds, because they appear last in the format string.
- `ensure_entity` in `addon_fleet.rs` rejects `plan.stats.is_some()`. Keep that rejection here: overlap is a per-row diagnostic and stats support is Task 6's decision, not free.

Filter fields: `device_uid`, `ip`, `sweep_group_id`, `agent_id`, `relationship`, `declared`, `observed`. Default sort: `last_seen_at desc nulls last`.

- [ ] **Step 4: Wire the parser, matches, viz and tests**

Same as Task 2 steps 5, 7, 8 and 9. Aliases: `device_sweep_overlap`, `sweep_overlap`.

- [ ] **Step 5: Run and commit**

```bash
cd rust/srql && cargo fmt && cargo clippy && cargo test device_sweep_overlap
git add rust/srql/src elixir/serviceradar_core/priv/repo/migrations
git commit -m "feat(srql): add device_sweep_overlap declared-vs-observed diagnostic"
```

---

## Task 5: `sweep_compiled_config` (view-backed, admin-gated)

The entity where the credential rule is enforced structurally.

**Files:**

- Create: `elixir/serviceradar_core/priv/repo/migrations/20260902150000_create_sweep_compiled_config_view.exs`
- Create: `rust/srql/src/query/sweep_compiled_config.rs`
- Modify: parser, `query/mod.rs`, three matches, viz, tests
- Modify: RBAC catalog and `EntityAccess` (see Task 7)

- [ ] **Step 1: Write the view as a named-path projection**

Two independent layers protect credentials. `config_type = 'sweep'` excludes the `snmp` and `mapper` instances that carry credential material. And every column is an explicit JSON path, so a field a future compiler adds cannot appear by default — the projection has no wildcard to widen.

```elixir
defmodule ServiceRadar.Repo.Migrations.CreateSweepCompiledConfigView do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    CREATE VIEW platform.sweep_compiled_config AS
    SELECT
      i.id AS config_instance_id,
      i.agent_id,
      i.partition,
      i.version,
      i.content_hash,
      i.last_delivered_at,
      i.delivery_count,
      (g.value ->> 'sweep_group_id')::uuid AS sweep_group_id,
      g.value ->> 'name' AS sweep_group_name,
      g.value -> 'schedule' ->> 'type' AS schedule_type,
      g.value -> 'schedule' ->> 'interval' AS schedule_interval,
      g.value -> 'schedule' ->> 'cron_expression' AS schedule_cron,
      ARRAY(SELECT jsonb_array_elements_text(g.value -> 'modes')) AS effective_modes,
      ARRAY(SELECT jsonb_array_elements_text(g.value -> 'ports')) AS effective_ports,
      ARRAY(SELECT jsonb_array_elements_text(g.value -> 'targets')) AS static_targets,
      COALESCE(jsonb_array_length(g.value -> 'device_targets'), 0) AS device_target_count,
      (g.value -> 'banner_grab' ->> 'enabled')::boolean AS banner_grab_enabled,
      g.value -> 'settings' ->> 'timeout' AS scan_timeout,
      (g.value -> 'settings' ->> 'concurrency')::bigint AS scan_concurrency
    FROM platform.agent_config_instances i
    CROSS JOIN LATERAL jsonb_array_elements(i.compiled_config -> 'groups') AS g(value)
    WHERE i.config_type = 'sweep'
    """)
  end

  def down do
    execute("DROP VIEW IF EXISTS platform.sweep_compiled_config")
  end
end
```

Note what is absent and must stay absent: `i.compiled_config` itself, `g.value` itself, and the banner-grab tuning map. `device_targets` is reduced to a count here; the per-device declared list is what `device_sweep_overlap` is for.

- [ ] **Step 2: Write the allowlist test that can fail**

This is the gate that keeps the projection honest. Create a database-backed test asserting the view's column set equals the allowlist exactly:

```elixir
  @allowlist ~w(
    config_instance_id agent_id partition version content_hash
    last_delivered_at delivery_count sweep_group_id sweep_group_name
    schedule_type schedule_interval schedule_cron
    effective_modes effective_ports static_targets device_target_count
    banner_grab_enabled scan_timeout scan_concurrency
  )

  test "the compiled config view exposes exactly the allowlisted columns" do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'platform' AND table_name = 'sweep_compiled_config'
        """,
        []
      )

    actual = rows |> List.flatten() |> Enum.sort()

    assert actual == Enum.sort(@allowlist),
           "compiled config projection drifted from the allowlist: " <>
             "added #{inspect(actual -- @allowlist)}, removed #{inspect(@allowlist -- actual)}"
  end

  test "no compiled config document is reachable through the view" do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, data_type FROM information_schema.columns
        WHERE table_schema = 'platform' AND table_name = 'sweep_compiled_config'
        """,
        []
      )

    refute Enum.any?(rows, fn [name, type] ->
             name == "compiled_config" or type == "jsonb"
           end),
           "the view must not expose a jsonb blob: #{inspect(rows)}"
  end
```

Run it and watch it fail before the view exists. Then mutation-check it: add a throwaway column to the view and confirm the first test goes red naming it.

- [ ] **Step 3: Write the query module**

Same `addon_fleet` sql_query pattern as Task 4 step 3, including the placeholder rewrite and limit/offset bind ordering. Filter fields: `agent_id`, `partition`, `sweep_group_id`, `sweep_group_name`, `version`. Default sort: `last_delivered_at desc nulls last`. Aliases: `sweep_compiled_config`, `compiled_sweep_config`.

- [ ] **Step 4: Wire, run and commit**

```bash
cd rust/srql && cargo fmt && cargo clippy && cargo test sweep_compiled_config
git add rust/srql/src elixir/serviceradar_core/priv/repo/migrations elixir/web-ng/test
git commit -m "feat(srql): expose compiled sweep config through a column allowlist"
```

---

## Task 6: Time windows and stats

**Files:**

- Modify: `rust/srql/src/query/cagg.rs` (`max_time_range_days_for_ast`)
- Create: `rust/srql/src/query/sweep_results/stats.rs`, `rust/srql/src/query/sweep_coverage/stats.rs`
- Modify: the two entity modules to dispatch to their stats builders

- [ ] **Step 1: Write the failing window test**

```rust
#[test]
fn sweep_coverage_allows_a_window_past_the_default_cap() {
    let ast = parse("in:sweep_coverage time:last_365d limit:10").unwrap();
    assert!(
        max_time_range_days_for_ast(&ast) >= 365,
        "sweep_coverage must permit its full rollup retention"
    );
}

#[test]
fn sweep_results_keeps_the_default_cap() {
    let ast = parse("in:sweep_results time:last_365d limit:10").unwrap();
    assert_eq!(max_time_range_days_for_ast(&ast), 90);
}
```

Run it. Expected: the first fails returning 90.

- [ ] **Step 2: Admit `sweep_coverage` to the longer window**

In `max_time_range_days_for_ast`, add `Entity::SweepCoverage` to the branch returning the long cap. Do NOT add it to `supports_hourly_cagg` — that function controls CAGG *routing*, and `sweep_coverage_daily` is a plain table with no hourly continuous aggregate behind it. Conflating the two would route queries at a view that does not exist.

Leave `sweep_results` on 90 days: its rows are purged at 7, so a longer window would only promise data that cannot exist.

- [ ] **Step 3: Add per-entity stats**

Nothing about `stats:` is automatic. Follow the `composite_results` two-module pattern: `composite_results.rs` for rows, `composite_results/stats.rs` for its own `count() as alias by <field>` parser, group-field allowlist and GROUP BY SQL.

Group-field allowlist for `sweep_results`: `agent_id`, `sweep_group_id`, `status`, `device_id`. For `sweep_coverage`: `agent_id`, `sweep_group_id`, `device_uid`, `day`.

This is what makes AC2 real — results grouped by vantage point and sweep group without one overwriting another.

- [ ] **Step 4: Write the time predicate in the stats path too**

The aggregate builder needs its own copy of the time predicate. `composite_results.rs` and `composite_results/stats.rs` each carry one. A stats query whose window is ignored returns numbers that look right and are not.

Test it explicitly:

```rust
#[test]
fn sweep_results_stats_applies_the_time_window() {
    let plan = plan_for("in:sweep_results time:last_24h stats:count() as n by agent_id");
    let (sql, _) = sweep_results::to_sql_and_params(&plan).expect("stats SQL");
    let lower = sql.to_lowercase();
    assert!(lower.contains("group by"), "expected GROUP BY, got: {sql}");
    assert!(
        lower.contains("inserted_at") && lower.contains("between"),
        "stats path dropped the time window, got: {sql}"
    );
}
```

- [ ] **Step 5: Confirm `bucket:` is rejected, not ignored**

```rust
#[test]
fn sweep_coverage_rejects_bucket() {
    let plan = plan_for("in:sweep_coverage time:last_30d bucket:1d");
    assert!(sweep_coverage::to_sql_and_params(&plan).is_err());
}
```

Downsample dispatch runs before the per-entity match and rejects non-metric entities. Confirm the error surfaces rather than the token being silently dropped.

- [ ] **Step 6: Run and commit**

```bash
cd rust/srql && cargo fmt && cargo clippy && cargo test
git add rust/srql/src
git commit -m "feat(srql): sweep coverage window and per-entity stats"
```

---

## Task 7: Catalog, permission mapping and MCP docs

Two Elixir tests make parts of this mandatory rather than optional. Adding entities to the catalog without the permission mapping turns the suite red, and every catalog id must parse through the Rust NIF.

**Files:**

- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex`
- Modify: the RBAC catalog (new admin-default permission)
- Modify: `elixir/web-ng/priv/mcp/srql-cookbook.md`

- [ ] **Step 1: Add the new admin-default RBAC permission**

`settings.networks.manage` is operator plus admin and cannot be reused for an admin-only entity. Add a new catalog permission for compiled sweep config with admin default roles, including the non-empty section and structural fields `catalog_test.exs` requires. No migration: `RoleProfileSeeder` re-syncs seeded profiles on boot.

- [ ] **Step 2: Map all seven entities and every alias in `EntityAccess`**

Add the canonical ids and every parser alias from Task 2 and 3 to `@permission_entities`. Six entities go under the sweep view permission; `sweep_compiled_config` and its alias go under the new admin key.

Aliases matter as much as ids: `EntityAccess` matches the raw token, so an unmapped alias is an ungated back door to a gated entity.

- [ ] **Step 3: Add the catalog entries**

Follow the existing entity map shape in `catalog.ex` — id, label, route, defaults, filter fields. State the 7-day retention in the `sweep_results` entry and point to `sweep_coverage` for older history, so an empty result is not misread as an absence of sweep activity.

- [ ] **Step 4: Run the two mandatory tests**

```bash
cd elixir/web-ng && mix test test/serviceradar_web_ng/srql/entity_access_test.exs test/phoenix/controllers/api/srql_catalog_controller_test.exs
```

Expected: PASS. A failure naming an unmapped entity means step 2 is incomplete. A failure in the parse assertion means the Rust alias and the catalog id disagree.

- [ ] **Step 5: Add MCP cookbook recipes**

Add recipes to `priv/mcp/srql-cookbook.md` for the questions this change exists to answer, so `lookup_srql_docs` finds them by task shape:

```
in:device_sweep_overlap device_uid:<uid> relationship:declared_not_observed
in:sweep_compiled_config sweep_group_name:%rids% sort:last_delivered_at:desc
in:sweep_results device_id:<uid> time:last_24h sort:inserted_at:desc
in:sweep_results time:last_7d stats:count() as n by agent_id
in:sweep_coverage device_uid:<uid> time:last_90d sort:day:desc
```

Each needs a one-line description naming the question it answers.

- [ ] **Step 6: Assert the MCP denial shape**

Add a test that an unauthorized MCP `execute_srql` on `sweep_compiled_config` returns JSON-RPC 200 with `isError: true` and body text "forbidden". Do NOT assert 403 — that is the HTTP path's shape, and asserting it here produces a test that fails for the wrong reason.

- [ ] **Step 7: Commit**

```bash
cd elixir/web-ng && mix format
git add lib priv test
git commit -m "feat(srql): catalog, permission mapping and MCP recipes for sweep entities"
```

---

## Task 8: Full verification

- [ ] **Step 1: Database-backed entity tests**

Run the new entities against CNPG through the `srql-fixtures-db-tests` skill lifecycle: sweep, prepare template, migrate, provision, test, teardown. One run id for the whole sequence, `--nocache_test_results`, and `teardown_db` even on a red shard.

- [ ] **Step 2: Prove the credential rule holds end to end**

Query `in:sweep_compiled_config` as an admin against a database seeded with an `snmp` config instance containing a community string. Assert the string appears nowhere in the response. This is the claim the whole design rests on; assert it against real data, not against the view definition.

- [ ] **Step 3: Prove the gate holds in both token orders**

As a caller lacking the admin permission, submit both `in:sweep_compiled_config limit:1` and `limit:1 in:sweep_compiled_config` through `POST /api/query` and through MCP `execute_srql`. All four must deny.

- [ ] **Step 4: Bazel build and full suite**

```bash
bazel build //rust/...
make test
```

`make test` is the only command covering the Elixir unit shards, which exist solely as Bazel targets.

- [ ] **Step 5: Answer the original question**

Query the `rids` devices:

```
in:device_sweep_overlap ip:<rids-ip> relationship:declared_not_observed
in:sweep_compiled_config sweep_group_name:%rids% sort:last_delivered_at:desc
in:sweep_results ip:<rids-ip> time:last_24h
```

Determine whether TCP was compiled into the delivered config, and whether the results show TCP requested. The standing hypothesis is that `SweepCompiler.enforce_tcp_ports` or `drop_unsupported_modes` drops TCP before delivery. Record the finding on GitHub issue #4167 — confirmed or refuted. A diagnostic that ships without being pointed at the symptom it was built for is unfinished.

- [ ] **Step 6: Update the OpenSpec checklist and open the PR**

Tick sections 3 through 6 in `openspec/changes/add-sweep-diagnostics-srql-entities/tasks.md`.

```bash
git push origin feat/4167-sweep-diagnostics-srql-mcp:refs/heads/feat/4167-sweep-diagnostics-srql-mcp
```

Verify the push line says `-> feat/4167-sweep-diagnostics-srql-mcp`, never `-> staging`.
