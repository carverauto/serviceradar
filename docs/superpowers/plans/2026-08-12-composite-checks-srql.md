# Composite Checks SRQL Exposure Implementation Plan (Plan 2 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make composite check verdicts queryable — filter devices by verdict (`in:devices composite.pci-isolation:not_isolated`), roll up verdict counts per check (`in:composite_results check:pci-isolation`), and offer both to the visual query builder.

**Architecture:** Two additions to the Rust SRQL translator. A dynamic device *filter* field `composite.<slug>` compiled to a correlated `EXISTS` subquery against `device_composite_check_results` joined to `composite_checks` on slug — structurally identical to the existing `available_from_agent` filter from `add-per-agent-availability`. And a new `composite_results` *entity* for rollups, which is the full nine-file entity registration. Slug existence is validated in Elixir, not in the translator, because the translator has no database access (see D1).

**Tech Stack:** Rust (Diesel, `diesel_async`), the `rust/srql` crate; Elixir for catalog and validation.

**Depends on:** Plan 1 (branch `feat/composite-service-checks`, PR #4962). This plan is stacked on it and cannot merge first — it queries tables Plan 1 creates.

**Spec:** `openspec/changes/add-composite-service-checks/specs/srql/spec.md`.

## Global Constraints

- **`apply_filter` and `collect_filter_params` are parallel matches on the same field names** (`query/devices/filters.rs` and `query/devices/filters/params.rs`). A field added to one and not the other binds the wrong parameters or none at all — and it fails at runtime with a placeholder mismatch, not at compile time. Every task touching a filter touches both.
- **Placeholder accounting is load-bearing.** See the `AWX_MANAGED_PREDICATE` doc comment at `query/devices/filters.rs:48-53`: it documents *"binds no user input — every literal is hard-coded — so it contributes zero placeholders"*. Any fragment that binds must contribute exactly the params `collect_filter_params` pushes, in order.
- **Do not add a JOIN to the device query.** `DeviceQuery<'a>` is a `BoxedSelectStatement` whose `FromClause` is `ocsf_devices` alone (`query/devices.rs:32-35`); joining changes the type across the whole module. Cross-table predicates use a correlated `EXISTS` via `diesel::dsl::sql`, which is what `filters/availability.rs` already does.
- **Table names in raw SQL fragments carry no schema prefix.** `filters/availability.rs:27` writes `FROM device_agent_availability`, relying on the connection `search_path` (`platform, public, ag_catalog`). Match that; do not hardcode `platform.`.
- **`cargo fmt` and `cargo clippy` on touched crates**, per AGENTS.md.
- **A green `cargo check` does not prove the Bazel build.** Finish with `bazel build //rust/...`. New crate imports need `BUILD.bazel` updates; `go test`/`cargo test` passing is not evidence Bazel passes.
- **SRQL is consumed two ways** — the Rust NIF (`ServiceRadarSRQL.Native.translate/5`, used by `ServiceRadar.Observability.SRQLRunner`) and the web-ng catalog (`elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`, `@entities` at line 70). The catalog is what the visual builder reads; a field the translator accepts but the catalog omits is invisible in the builder, and vice versa produces a query error.

## Decisions

### D1 — Unknown-slug validation lives in Elixir, not the translator

**The spec as written is not implementable in the translator, and this plan changes it.**

`specs/srql/spec.md` currently says an unknown composite slug "SHALL fail with an error naming the unknown check". The Rust translator is a pure query compiler with no database connection — `translate/5` returns SQL and params. It cannot know which slugs exist.

What the natural implementation *does* give for free is the second half of that requirement. Because the predicate is `EXISTS (… JOIN composite_checks c ON c.slug = $1 …)`, an unknown slug matches nothing, so the query returns **zero devices** rather than every device. The dangerous failure mode — a filter silently degrading to "match everything" — cannot occur.

So: keep the "SHALL NOT silently return every device" guarantee in the translator, and move the "error naming the unknown check" guarantee to the Elixir layer, which does have database access. Task 6 implements it and updates the spec delta to match.

*Alternative considered:* passing a known-slug allowlist into `translate/5`. Rejected — it changes the NIF signature for every caller and puts a cache-coherency problem (slugs change at runtime) inside a pure function.

### D2 — `composite.<slug>` is a filter field, not a selectable column

Devices remain `SELECT ocsf_devices.*`. The verdict is a predicate, not a projected value, so `in:devices composite.x:y` filters but does not add a column to the row. Projecting per-check verdicts onto a device row would mean either a lateral join per referenced check or a JSON aggregate, and no consumer in Plan 3 needs it — the device detail page loads verdicts through Ash, not SRQL.

### D3 — Two filter fields, one predicate builder

`composite.<slug>` matches on `verdict`; `composite.<slug>.status` matches on `status`. Both compile through one function taking a column name, because the only difference is which column the inner query compares.

## File Structure

**Rust — device filter (Task 1–3)**
- Modify `rust/srql/src/query/devices/filters.rs` — dispatch `composite.` prefixed fields.
- Create `rust/srql/src/query/devices/filters/composite.rs` — the predicate builder and slug validation.
- Modify `rust/srql/src/query/devices/filters/params.rs` — the parallel param arm.
- Modify `rust/srql/src/query/tests/device_queries.rs` — translator tests.

**Rust — rollup entity (Task 4–5)**
- Modify `rust/srql/src/parser/ast.rs` — `Entity::CompositeResults`.
- Modify `rust/srql/src/parser/entity.rs` — `"composite_results"` → the variant.
- Modify `rust/srql/src/schema.rs` — Diesel tables for `device_composite_check_results` and `composite_checks`.
- Create `rust/srql/src/models/composite_checks.rs` + register in `models/mod.rs` — the row struct.
- Create `rust/srql/src/query/composite_results.rs` — the entity query builder.
- Modify `rust/srql/src/query/engine.rs`, `query/translate.rs`, `query/viz/mod.rs` — dispatch.

**Elixir (Task 6–7)**
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex` — entity + device fields for the builder.
- Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/srql_validation.ex` — unknown-slug validation.
- Modify `openspec/changes/add-composite-service-checks/specs/srql/spec.md` — reflect D1.

---

### Task 1: The `composite.<slug>` device filter

**Files:**
- Create: `rust/srql/src/query/devices/filters/composite.rs`
- Modify: `rust/srql/src/query/devices/filters.rs`
- Modify: `rust/srql/src/query/devices/filters/params.rs`
- Test: `rust/srql/src/query/devices/filters/composite.rs` (inline `#[cfg(test)]`) and `rust/srql/src/query/tests/device_queries.rs`

**Interfaces:**
- Produces `pub(super) fn apply_composite_verdict_filter<'a>(query: DeviceQuery<'a>, filter: &Filter, column: CompositeColumn) -> Result<DeviceQuery<'a>>` and `pub(in crate::query::devices) fn parse_composite_field(field: &str) -> Option<(String, CompositeColumn)>`, where `CompositeColumn` is `Verdict | Status`.
- Consumes `DeviceQuery<'a>` (`query/devices.rs:34`), `Filter`/`FilterOp` from `crate::parser`.

- [ ] **Step 1: Read the template this mirrors**

Run: `sed -n '14,35p' rust/srql/src/query/devices/filters/availability.rs`

That is `apply_agent_availability_filter` — a correlated `EXISTS` over a second table built with `sql::<Bool>(…).bind::<Text,_>(…).sql(…)`. The composite filter is the same shape with a two-table inner query. Note it does **not** schema-qualify `device_agent_availability`; match that.

- [ ] **Step 2: Write the failing test**

Create `rust/srql/src/query/devices/filters/composite.rs` with only the test module and the type, so it compiles and fails:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::query::devices) enum CompositeColumn {
    Verdict,
    Status,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_verdict_field() {
        assert_eq!(
            parse_composite_field("composite.pci-isolation"),
            Some(("pci-isolation".to_string(), CompositeColumn::Verdict))
        );
    }

    #[test]
    fn parses_a_status_field() {
        assert_eq!(
            parse_composite_field("composite.pci-isolation.status"),
            Some(("pci-isolation".to_string(), CompositeColumn::Status))
        );
    }

    #[test]
    fn rejects_a_bare_prefix() {
        assert_eq!(parse_composite_field("composite."), None);
        assert_eq!(parse_composite_field("composite"), None);
    }

    #[test]
    fn rejects_an_unknown_suffix() {
        // Only `.status` is a recognised suffix; anything else would otherwise
        // be silently treated as part of the slug.
        assert_eq!(parse_composite_field("composite.pci-isolation.verdict"), None);
        assert_eq!(parse_composite_field("composite.a.b.c"), None);
    }

    #[test]
    fn rejects_a_slug_that_is_not_slug_shaped() {
        // Guards the raw-SQL boundary: the slug is bound as a parameter, but a
        // hostile value should never get that far.
        assert_eq!(parse_composite_field("composite.Bad Slug"), None);
        assert_eq!(parse_composite_field("composite.a';DROP TABLE x;--"), None);
        assert_eq!(parse_composite_field("composite.-leading"), None);
        assert_eq!(parse_composite_field("composite.trailing-"), None);
    }

    #[test]
    fn accepts_a_maximal_slug() {
        let slug = "a".repeat(64);
        assert_eq!(
            parse_composite_field(&format!("composite.{slug}")),
            Some((slug, CompositeColumn::Verdict))
        );
    }

    #[test]
    fn rejects_an_overlong_slug() {
        let slug = "a".repeat(65);
        assert_eq!(parse_composite_field(&format!("composite.{slug}")), None);
    }
}
```

- [ ] **Step 3: Run it and watch it fail**

Run: `cd rust/srql && cargo test --lib composite`
Expected: FAIL — `cannot find function parse_composite_field in this scope`.

- [ ] **Step 4: Implement the parser and predicate**

Add above the test module in `composite.rs`:

```rust
use super::super::DeviceQuery;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp, FilterValue},
};
use diesel::{
    dsl::{not, sql},
    prelude::*,
    sql_types::{Array, Bool, Text},
};

/// Which column of a composite result the filter compares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::query::devices) enum CompositeColumn {
    Verdict,
    Status,
}

impl CompositeColumn {
    fn column(self) -> &'static str {
        match self {
            CompositeColumn::Verdict => "r.verdict",
            CompositeColumn::Status => "r.status",
        }
    }
}

/// Splits `composite.<slug>` / `composite.<slug>.status` into its parts.
///
/// Returns `None` for anything that is not a well-formed composite field, which
/// the caller turns into "unsupported filter field". Slug shape is enforced
/// here rather than at the SQL boundary: the value is bound as a parameter, but
/// a field name that is not slug-shaped is a caller mistake worth naming.
pub(in crate::query::devices) fn parse_composite_field(
    field: &str,
) -> Option<(String, CompositeColumn)> {
    let rest = field.strip_prefix("composite.")?;

    let (slug, column) = match rest.rsplit_once('.') {
        Some((slug, "status")) => (slug, CompositeColumn::Status),
        Some(_) => return None,
        None => (rest, CompositeColumn::Verdict),
    };

    if is_valid_slug(slug) {
        Some((slug.to_string(), column))
    } else {
        None
    }
}

fn is_valid_slug(slug: &str) -> bool {
    !slug.is_empty()
        && slug.len() <= 64
        && !slug.starts_with('-')
        && !slug.ends_with('-')
        && slug
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// Compiles a composite verdict filter to a correlated EXISTS.
///
/// No JOIN: `DeviceQuery` is boxed over `ocsf_devices` alone, so a join would
/// change its type across the module. Table names are unqualified because the
/// connection `search_path` supplies the schema, matching
/// `apply_agent_availability_filter`.
///
/// An unknown slug matches no rows, so the filter returns zero devices rather
/// than degrading to "match everything". Naming the unknown check as an error
/// happens in Elixir, which has database access; the translator does not.
pub(in crate::query::devices) fn apply_composite_verdict_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
    slug: &str,
    column: CompositeColumn,
) -> Result<DeviceQuery<'a>> {
    let values = match &filter.value {
        FilterValue::Scalar(v) => vec![v.to_string()],
        FilterValue::List(list) => list.clone(),
    };

    if values.is_empty() {
        return Ok(query);
    }

    let negated = match filter.op {
        FilterOp::Eq | FilterOp::In => false,
        FilterOp::NotEq | FilterOp::NotIn => true,
        _ => {
            return Err(ServiceError::InvalidRequest(
                "composite verdict filters only support equality and list membership".into(),
            ));
        }
    };

    let expr = sql::<Bool>(
        "EXISTS (SELECT 1 FROM device_composite_check_results r \
         JOIN composite_checks c ON c.id = r.check_id \
         WHERE r.device_uid = ocsf_devices.uid AND c.slug = ",
    )
    .bind::<Text, _>(slug.to_string())
    .sql(&format!(" AND {} = ANY(", column.column()))
    .bind::<Array<Text>, _>(values)
    .sql("))");

    Ok(if negated {
        query.filter(not(expr))
    } else {
        query.filter(expr)
    })
}
```

Note on the negated case: `NOT EXISTS(...)` also matches devices with **no** result row for that check. That is the correct reading of `composite.x != not_isolated` — "this device does not currently hold that verdict" — and Task 3 pins it with a test so a later refactor cannot flip it silently.

- [ ] **Step 5: Run the unit tests**

Run: `cd rust/srql && cargo test --lib composite`
Expected: PASS, 7 tests.

- [ ] **Step 6: Wire the dispatch**

In `rust/srql/src/query/devices/filters.rs`, add to the `use self::{…}` block:

```rust
    composite::{apply_composite_verdict_filter, parse_composite_field},
```

and declare the module alongside the other `filters/` submodules (find the `mod availability;` line and add `mod composite;` in alphabetical order).

Then add this arm to `apply_filter`, immediately **before** the `field if field.starts_with("metadata.")` arm so the more specific prefix wins:

```rust
        // Derived from composite check results; not backed by a device column.
        // Compiled to a correlated EXISTS in filters/composite.rs.
        field if field.starts_with("composite.") => {
            let (slug, column) = parse_composite_field(field).ok_or_else(|| {
                ServiceError::InvalidRequest(format!("invalid composite check field '{field}'"))
            })?;
            query = apply_composite_verdict_filter(query, filter, &slug, column)?;
        }
```

- [ ] **Step 7: Add the parallel param arm**

This is the step that is easy to forget and fails at runtime rather than compile time.

In `rust/srql/src/query/devices/filters/params.rs`, add to the `collect_filter_params` match, before the fallthrough:

```rust
        // Must mirror the composite arm in apply_filter: one Text bind for the
        // slug, then one Array<Text> bind for the values. A mismatch here does
        // not fail to compile -- it produces a placeholder/parameter mismatch at
        // query time.
        field if field.starts_with("composite.") => {
            let (slug, _column) = parse_composite_field(field).ok_or_else(|| {
                ServiceError::InvalidRequest(format!("invalid composite check field '{field}'"))
            })?;

            params.push(BindParam::Text(slug));
            collect_list_params(params, filter)
        }
```

Run `rg -n "BindParam::" rust/srql/src/query/devices/filters/params.rs | head` and `rg -n "fn collect_list_params" -A15 rust/srql/src/query/devices/filters/params.rs` first, and use the real variant and helper names — substitute if they differ.

- [ ] **Step 8: Verify the parallel matches agree**

Run:
```bash
cd rust/srql
rg -n 'starts_with\("composite\."' src/query/devices/filters.rs src/query/devices/filters/params.rs
```
Expected: exactly one hit in each file. This pair is the invariant; if a later task adds a composite field variant, it lands in both or neither.

- [ ] **Step 9: Format, lint, build**

```bash
cd rust/srql
cargo fmt
cargo clippy --all-targets -- -D warnings
cargo check --workspace --lib --bins --tests
```

- [ ] **Step 10: Commit**

```bash
git add rust/srql/src/query/devices/filters.rs \
        rust/srql/src/query/devices/filters/composite.rs \
        rust/srql/src/query/devices/filters/params.rs
git commit -m "feat(srql): filter devices by composite check verdict"
```

---

### Task 2: Translator tests for the generated SQL

**Files:**
- Modify: `rust/srql/src/query/tests/device_queries.rs`

**Interfaces:** consumes the filter from Task 1. Produces no new API.

**Why separate from Task 1:** Task 1's tests cover field parsing in isolation. These assert the *compiled SQL and parameter order*, which is where the `apply_filter`/`collect_filter_params` pairing actually breaks. A reviewer could reasonably accept Task 1 and reject these.

- [ ] **Step 1: Read how existing translator tests assert SQL**

Run: `rg -n "available_from_agent" -B5 -A20 rust/srql/src/query/tests/device_queries.rs | head -40`

Use whatever assertion helper that test uses (it will be a `translate`-and-inspect pattern). Match it rather than inventing one.

- [ ] **Step 2: Write the failing tests**

Add to `rust/srql/src/query/tests/device_queries.rs`, adapting the helper names to what Step 1 found:

```rust
#[test]
fn composite_verdict_filter_compiles_to_a_correlated_exists() {
    let plan = translate_ok("in:devices composite.pci-isolation:not_isolated");

    assert!(plan.sql.contains("EXISTS"));
    assert!(plan.sql.contains("device_composite_check_results"));
    assert!(plan.sql.contains("composite_checks"));
    assert!(plan.sql.contains("r.device_uid = ocsf_devices.uid"));
    // No JOIN on the outer query -- DeviceQuery is boxed over ocsf_devices alone.
    assert!(!plan.sql.contains("JOIN device_composite_check_results"));
}

#[test]
fn composite_verdict_filter_binds_slug_then_values() {
    let plan = translate_ok("in:devices composite.pci-isolation:not_isolated");

    // Order matters: apply_filter binds the slug first, then the value array.
    // collect_filter_params must push them in the same order.
    assert_eq!(plan.params.len(), 2);
}

#[test]
fn composite_status_filter_targets_the_status_column() {
    let plan = translate_ok("in:devices composite.pci-isolation.status:degraded");
    assert!(plan.sql.contains("r.status"));
    assert!(!plan.sql.contains("r.verdict"));
}

#[test]
fn composite_verdict_filter_supports_lists() {
    let plan = translate_ok("in:devices composite.pci-isolation:[not_isolated,inverted_reachability]");
    assert!(plan.sql.contains("ANY("));
}

#[test]
fn a_malformed_composite_field_is_a_query_error() {
    assert!(translate("in:devices composite.:x").is_err());
    assert!(translate("in:devices composite.Bad Slug:x").is_err());
}
```

- [ ] **Step 3: Run and iterate**

Run: `cd rust/srql && cargo test --lib device_queries`
Expected: PASS. If the SQL substring assertions fail, print the generated SQL and adjust the assertions to the real output rather than reshaping the SQL to fit the test.

- [ ] **Step 4: Commit**

```bash
git add rust/srql/src/query/tests/device_queries.rs
git commit -m "test(srql): assert composite filter SQL shape and bind order"
```

---

### Task 3: Negation and absent-result semantics

**Files:**
- Modify: `rust/srql/src/query/tests/device_queries.rs`
- Create: `rust/srql/tests/` integration coverage only if the crate already has DB-backed tests; otherwise assert at the SQL level.

**Interfaces:** none new.

**The semantic being pinned:** `composite.x != not_isolated` compiles to `NOT EXISTS(...)`, which matches devices with **no result row** for that check as well as devices holding a different verdict. That is the correct reading of "does not currently hold that verdict", but it is a decision a refactor could silently flip, and the difference only shows up on devices outside the check's scope.

- [ ] **Step 1: Check whether the crate has DB-backed query tests**

Run: `ls rust/srql/tests/ 2>/dev/null; rg -n "async fn.*conn|AsyncPgConnection" rust/srql/src/query/tests/*.rs | head -5`

If there are DB-backed tests, add the behavioural test there. If not, assert at the SQL level only and note in the test's comment that the semantics are asserted structurally because the crate has no query-execution harness.

- [ ] **Step 2: Write the test**

```rust
#[test]
fn a_negated_composite_filter_compiles_to_not_exists() {
    let plan = translate_ok("in:devices composite.pci-isolation!=not_isolated");

    assert!(plan.sql.contains("NOT"));
    assert!(plan.sql.contains("EXISTS"));
    // NOT EXISTS also matches devices with no result row for this check --
    // "does not currently hold that verdict" includes "has no verdict". If this
    // is ever changed to require a row, that is a behaviour change, not a
    // refactor.
}
```

Use the real negation token the parser accepts — run `rg -n "NotEq|!=" rust/srql/src/parser/filters.rs | head` to confirm the syntax before writing the query string.

- [ ] **Step 3: Run**

Run: `cd rust/srql && cargo test --lib device_queries`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add rust/srql/src/query/tests/device_queries.rs
git commit -m "test(srql): pin negated composite filter semantics"
```

---

### Task 4: Diesel schema and row model for the rollup entity

**Files:**
- Modify: `rust/srql/src/schema.rs`
- Create: `rust/srql/src/models/composite_checks.rs`
- Modify: `rust/srql/src/models/mod.rs`

**Interfaces:**
- Produces Diesel tables `device_composite_check_results` and `composite_checks`, and `pub struct CompositeResultRow` with a `to_json` (or equivalent) matching how `CapacityForecastRow` is shaped — read `rust/srql/src/models/observability.rs:14-60` and mirror it.

- [ ] **Step 1: Read an existing table declaration and row model**

```bash
sed -n '530,545p' rust/srql/src/schema.rs
sed -n '14,60p' rust/srql/src/models/observability.rs
```

Note the schema.rs convention: `table_name (composite, primary, key) { … }` with no schema prefix.

- [ ] **Step 2: Add the tables**

In `rust/srql/src/schema.rs`, following the file's existing ordering convention:

```rust
diesel::table! {
    composite_checks (id) {
        id -> Uuid,
        name -> Text,
        slug -> Text,
        description -> Nullable<Text>,
        scope_query -> Text,
        evaluation_interval_seconds -> Int8,
        state -> Text,
        last_evaluated_at -> Nullable<Timestamptz>,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}

diesel::table! {
    device_composite_check_results (id) {
        id -> Uuid,
        device_uid -> Text,
        check_id -> Uuid,
        verdict -> Text,
        status -> Text,
        matched_rule_id -> Nullable<Uuid>,
        inputs -> Jsonb,
        evaluated_at -> Timestamptz,
        changed_at -> Timestamptz,
        inserted_at -> Timestamptz,
        updated_at -> Timestamptz,
    }
}
```

Verify each column against the real migrations before committing:
```bash
sed -n '/create table(:device_composite_check_results/,/^    end/p' \
  elixir/serviceradar_core/priv/repo/migrations/20260812154900_add_device_composite_check_results.exs
```
The Elixir migration is the source of truth. A drifted Diesel schema compiles fine and fails at query time.

- [ ] **Step 3: Add the row model**

Create `rust/srql/src/models/composite_checks.rs` mirroring `CapacityForecastRow`'s structure (`Queryable`, `Selectable` or `QueryableByName` as that file uses), with fields `device_uid`, `check_slug`, `check_name`, `verdict`, `status`, `evaluated_at`, `changed_at`. Register it in `models/mod.rs` alongside the other `pub use` lines.

- [ ] **Step 4: Build**

Run: `cd rust/srql && cargo check --workspace --lib --bins --tests`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add rust/srql/src/schema.rs rust/srql/src/models/
git commit -m "feat(srql): add composite check tables to the Diesel schema"
```

---

### Task 5: The `composite_results` entity

**Files:**
- Modify: `rust/srql/src/parser/ast.rs`, `rust/srql/src/parser/entity.rs`
- Create: `rust/srql/src/query/composite_results.rs`
- Modify: `rust/srql/src/query/engine.rs`, `rust/srql/src/query/translate.rs`, `rust/srql/src/query/viz/mod.rs`
- Modify: `rust/srql/src/parser/tests.rs`

**Interfaces:**
- Produces `Entity::CompositeResults`, parsed from `in:composite_results`, supporting filters `check:<slug>`, `verdict:<slug>`, `status:<enum>`, `device_uid:<uid>`.

**Registration is nine files.** Run this first to see the full set for a comparable entity, and use it as the checklist:
```bash
rg -n "CapacityForecasts" rust/srql/src | sed 's/:.*//' | sort -u
```

- [ ] **Step 1: Write the failing parser test**

In `rust/srql/src/parser/tests.rs`, next to the existing entity tests:

```rust
#[test]
fn parses_the_composite_results_entity() {
    let ast = parse("in:composite_results check:pci-isolation").expect("parses");
    assert_eq!(ast.entity, Entity::CompositeResults);
}
```

Run: `cd rust/srql && cargo test --lib parser`
Expected: FAIL — no such variant.

- [ ] **Step 2: Register the entity**

Add `CompositeResults,` to the `Entity` enum in `parser/ast.rs`, and the `"composite_results" => Entity::CompositeResults` arm in `parser/entity.rs`. Match the surrounding style exactly — check whether `entity.rs` also needs a reverse `as_str`/`Display` arm (`rg -n "CapacityForecasts" rust/srql/src/parser/entity.rs`).

The compiler will now fail on every non-exhaustive match over `Entity` — `query/engine.rs`, `query/translate.rs`, `query/viz/mod.rs`. That exhaustiveness is the registration checklist; work through each error rather than adding a catch-all arm.

- [ ] **Step 3: Implement the query builder**

Create `rust/srql/src/query/composite_results.rs`, modelled on `rust/srql/src/query/capacity_forecasts.rs`. It selects from `device_composite_check_results` joined to `composite_checks`, and supports:

- `check:<slug>` → `composite_checks.slug =`
- `verdict:<slug>` → `device_composite_check_results.verdict =`
- `status:<enum>` → `device_composite_check_results.status =`
- `device_uid:<uid>` → `device_composite_check_results.device_uid =`

Unlike the device filter, this entity **may** join, because its `FromClause` is being defined fresh here.

- [ ] **Step 4: Run the tests**

Run: `cd rust/srql && cargo test --lib`
Expected: PASS.

- [ ] **Step 5: Verify the rollup shape a UI needs**

Plan 3's index page needs counts per verdict for a check. Confirm whether `stats:count group:verdict` already works through the generic stats path for a new entity (`rg -n "parse_stats_spec" rust/srql/src/query/ | head`). If it does not, add a test documenting that rollups are computed by the caller rather than by SRQL, so Plan 3 does not assume a facility that is not there.

- [ ] **Step 6: Format, lint, build, commit**

```bash
cd rust/srql
cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test --lib
cd ../..
git add rust/srql/src
git commit -m "feat(srql): add the composite_results rollup entity"
```

---

### Task 6: Elixir unknown-slug validation

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/srql_validation.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/srql_validation_test.exs`
- Modify: `openspec/changes/add-composite-service-checks/specs/srql/spec.md`

**Interfaces:**
- Produces `SRQLValidation.validate_composite_slugs(query, opts) :: :ok | {:error, {:unknown_composite_check, slug}}`, extracting `composite.<slug>` tokens from a raw SRQL string and checking each against `CompositeCheck.get_by_slug/2`.

**Why here and not in Rust:** see D1. The translator has no database connection, so it cannot know which slugs exist. This is the half of the spec requirement that needs one.

- [ ] **Step 1: Update the spec delta first**

In `openspec/changes/add-composite-service-checks/specs/srql/spec.md`, replace the "Unknown slug is a query error" scenario with two scenarios that match what is actually implementable:

```markdown
#### Scenario: Unknown slug never widens the result set

- **WHEN** a query filters on a composite slug that does not exist
- **THEN** the compiled predicate SHALL match no devices
- **AND** SHALL NOT silently return every device

#### Scenario: Unknown slug is reported to the caller

- **GIVEN** a caller that validates a query before running it
- **WHEN** the query references a composite slug with no matching check
- **THEN** validation SHALL fail with an error naming the unknown slug
```

Add a note under the requirement recording that slug existence is validated in the Elixir layer because the translator has no database access.

Run: `openspec validate add-composite-service-checks --strict`

- [ ] **Step 2: Write the failing test**

```elixir
defmodule ServiceRadar.CompositeChecks.SRQLValidationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.SRQLValidation

  defp actor, do: SystemActor.system(:composite_check_test)

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Known Check", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    %{check: check}
  end

  test "accepts a query with no composite reference" do
    assert :ok = SRQLValidation.validate_composite_slugs("in:devices tag:managed", actor: actor())
  end

  test "accepts a known slug", %{check: check} do
    assert :ok =
             SRQLValidation.validate_composite_slugs(
               "in:devices composite.#{check.slug}:isolated_verified",
               actor: actor()
             )
  end

  test "rejects an unknown slug and names it" do
    assert {:error, {:unknown_composite_check, "no-such-check"}} =
             SRQLValidation.validate_composite_slugs(
               "in:devices composite.no-such-check:x",
               actor: actor()
             )
  end

  test "accepts the status suffix on a known slug", %{check: check} do
    assert :ok =
             SRQLValidation.validate_composite_slugs(
               "in:devices composite.#{check.slug}.status:degraded",
               actor: actor()
             )
  end

  test "checks every referenced slug, not just the first", %{check: check} do
    assert {:error, {:unknown_composite_check, "missing"}} =
             SRQLValidation.validate_composite_slugs(
               "in:devices composite.#{check.slug}:a composite.missing:b",
               actor: actor()
             )
  end
end
```

- [ ] **Step 3: Implement**

The extraction regex must strip the `.status` suffix before lookup, and must not match a bare `composite.` prefix. Keep it a pure string scan plus one lookup per distinct slug — do not parse SRQL in Elixir.

- [ ] **Step 4: Run**

Run: `bash <scratchpad>/run.sh srql-validation test test/serviceradar/composite_checks/srql_validation_test.exs`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add elixir/serviceradar_core/lib/serviceradar/composite_checks/srql_validation.ex \
        elixir/serviceradar_core/test/serviceradar/composite_checks/srql_validation_test.exs \
        openspec/changes/add-composite-service-checks/specs/srql/spec.md
git commit -m "feat(composite-checks): validate composite slugs in SRQL queries"
```

---

### Task 7: Catalog exposure for the visual builder

**Files:**
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
- Modify: `elixir/web-ng/test/` — the catalog's existing test file (find with `rg -l "SRQL.Catalog" elixir/web-ng/test`)

**Interfaces:** adds a `composite_results` entry to `@entities` (line 70) and composite fields to the devices entity's filter field list.

**The coupling that bites:** the catalog is a static list, but composite slugs are runtime data. A hardcoded `composite.pci-isolation` field would be wrong on every other deployment.

- [ ] **Step 1: Read the entity and field shape**

```bash
sed -n '70,120p' elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex
sed -n '280,300p' elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex
```

- [ ] **Step 2: Add the `composite_results` entity**

Static, so it goes straight into `@entities` with filter fields `check`, `verdict`, `status`, `device_uid`.

- [ ] **Step 3: Decide how dynamic slugs reach the builder**

Two options — pick one and record it in the module doc:

(a) The catalog stays static and the builder offers a generic `composite.<slug>` field the user types a slug into.
(b) `srql_catalog_controller.ex` enriches the served catalog at request time by listing enabled checks and appending one field per slug, with that check's authored verdicts as the selectable values.

(b) is what the spec's "Composite Fields In The SRQL Catalog" requirement describes, and it is what makes the builder usable. It requires the controller to read `CompositeCheck.list_enabled/1` and `CompositeCheckRule.list_by_check/2`. Confirm the controller has an actor/scope available before committing to it — `rg -n "def show" -A15 elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/srql_catalog_controller.ex`.

- [ ] **Step 4: Implement and test**

Add a catalog test asserting the `composite_results` entity is present with its filter fields, and — if (b) — a controller test asserting an enabled check's slug appears as a device field with its authored verdicts as values, and that a draft check's does not.

- [ ] **Step 5: Run**

```bash
bash <scratchpad>/run-webng.sh catalog test <the catalog and controller test files>
```

- [ ] **Step 6: Commit**

```bash
git add elixir/web-ng/lib/serviceradar_web_ng_web/srql/ elixir/web-ng/test/
git commit -m "feat(srql): offer composite fields to the visual query builder"
```

---

### Task 8: Verification

- [ ] **Step 1: Rust gates**

```bash
cd rust/srql
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

- [ ] **Step 2: Bazel**

Run: `bazel build //rust/...`

A green `cargo check` does not prove this. If new crate imports were added, `BUILD.bazel` needs them — `all_crate_deps(...)` infers, an explicit `crate_deps([...])` list does not.

- [ ] **Step 3: Elixir gates**

```bash
./scripts/elixir_quality.sh --project elixir/serviceradar_core --skip-dialyzer
./scripts/elixir_quality.sh --project elixir/web-ng --phoenix --skip-dialyzer
```

- [ ] **Step 4: End-to-end against a real database**

Using the `srql-fixtures-db-tests` skill, author a composite check, evaluate it, then run the filter through `ServiceRadar.Observability.SRQLRunner` and confirm it returns exactly the devices holding that verdict. This is the only step that proves the Diesel schema matches the Elixir migrations — a drifted column compiles fine and fails at query time.

- [ ] **Step 5: Spec**

Run: `openspec validate add-composite-service-checks --strict`

- [ ] **Step 6: Commit any fixes**

## Plan Self-Review

**Spec coverage** against `specs/srql/spec.md`:

| Requirement | Task |
|---|---|
| Composite Verdict Device Fields | 1, 2, 3 |
| Composite Results Entity | 4, 5 |
| Composite Fields In The SRQL Catalog | 7 |
| Unknown-slug behaviour | 6 (spec amended per D1) |

**Placeholder scan:** Tasks 5 and 7 deliberately defer two decisions to a documented read-then-choose step rather than guessing — the exact `Entity` registration surface (which the compiler enumerates via exhaustiveness) and whether the catalog is enriched statically or per-request. Both name the command that resolves them and the criterion for choosing. Every other step carries its code.

**Type consistency:** `CompositeColumn` is defined in Task 1 and consumed in Tasks 1 and 2. `parse_composite_field/1` is defined in Task 1 Step 4 and used in Step 7's params arm. `CompositeResultRow` is defined in Task 4 and used in Task 5.

**Known risk:** Task 4's Diesel schema is hand-transcribed from the Elixir migrations and can drift silently. Task 8 Step 4 is the only check that catches it, which is why it runs against a real database rather than asserting on generated SQL.
