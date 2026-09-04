//! Query execution for the sweep scan profile entity (issue 4167).

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::SweepProfileRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::sweep_profiles::dsl::{
        admin_only as col_admin_only, enabled as col_enabled, name as col_name, sweep_profiles,
        updated_at as col_updated_at,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::dsl::sql;
use diesel::expression::SqlLiteral;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{BoxedSelectStatement, FromClause};
use diesel::sql_types::{Bool, Jsonb};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type SweepProfilesTable = crate::schema::sweep_profiles::table;
type SweepProfilesFromClause = FromClause<SweepProfilesTable>;

/// Column order must match `SweepProfileRow`'s field order. The last two
/// entries are SQL expressions, not bare columns: `banner_grab` is
/// deliberately absent from `schema::sweep_profiles` (see that table!'s doc
/// comment), so this is the only place that narrows it down to
/// `banner_grab_enabled`/`banner_grab_protocols`. Both `execute` and
/// `to_sql_and_params` build on this same `select_tuple()` via `build_query`,
/// so the narrowing happens once, in SQL, and is visible on every consumer
/// path (issue 4167 review finding 2) — the same reasoning `composite_results`
/// documents for its own joined+aliased columns.
type SelectTuple = (
    crate::schema::sweep_profiles::id,
    crate::schema::sweep_profiles::name,
    crate::schema::sweep_profiles::description,
    crate::schema::sweep_profiles::ports,
    crate::schema::sweep_profiles::sweep_modes,
    crate::schema::sweep_profiles::concurrency,
    crate::schema::sweep_profiles::timeout,
    crate::schema::sweep_profiles::icmp_settings,
    crate::schema::sweep_profiles::tcp_settings,
    crate::schema::sweep_profiles::admin_only,
    crate::schema::sweep_profiles::enabled,
    crate::schema::sweep_profiles::inserted_at,
    crate::schema::sweep_profiles::updated_at,
    SqlLiteral<Bool>,
    SqlLiteral<Jsonb>,
);
type SweepProfilesQuery<'a> =
    BoxedSelectStatement<'a, diesel::dsl::SqlTypeOf<SelectTuple>, SweepProfilesFromClause, Pg>;

fn select_tuple() -> SelectTuple {
    (
        crate::schema::sweep_profiles::id,
        crate::schema::sweep_profiles::name,
        crate::schema::sweep_profiles::description,
        crate::schema::sweep_profiles::ports,
        crate::schema::sweep_profiles::sweep_modes,
        crate::schema::sweep_profiles::concurrency,
        crate::schema::sweep_profiles::timeout,
        crate::schema::sweep_profiles::icmp_settings,
        crate::schema::sweep_profiles::tcp_settings,
        crate::schema::sweep_profiles::admin_only,
        crate::schema::sweep_profiles::enabled,
        crate::schema::sweep_profiles::inserted_at,
        crate::schema::sweep_profiles::updated_at,
        sql::<Bool>("coalesce((banner_grab->>'enabled')::bool, false) AS banner_grab_enabled"),
        sql::<Jsonb>("coalesce(banner_grab->'protocols', '[]'::jsonb) AS banner_grab_protocols"),
    )
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let rows: Vec<SweepProfileRow> = build_query(plan)?
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<SweepProfileRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(SweepProfileRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let query = build_query(plan)?.limit(plan.limit).offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

    let mut params = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params(&mut params, filter)?;
    }

    super::reconcile_limit_offset_binds(&sql, &mut params, plan.limit, plan.offset)?;

    #[cfg(any(test, debug_assertions))]
    {
        let bind_count = super::diesel_bind_count(&query)?;
        if bind_count != params.len() {
            return Err(ServiceError::Internal(anyhow::anyhow!(
                "bind count mismatch (diesel {bind_count} vs params {})",
                params.len()
            )));
        }
    }

    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::SweepProfiles => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by sweep_profiles query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<SweepProfilesQuery<'static>> {
    let mut query = sweep_profiles.select(select_tuple()).into_boxed::<Pg>();

    // Row-level authorization, enforced unconditionally: the Ash read policy
    // in `sweep_profile.ex` restricts non-admins to `admin_only == false`,
    // but SRQL's raw-SQL path has no actor/scope context to replicate that
    // per caller. Filtering every query to non-admin-only profiles makes
    // this entity a strict subset of what every caller may already read
    // through Ash, so it can never leak an admin-only scanner profile
    // regardless of who queries it. Do not thread scope into this layer —
    // `admin_only` also cannot be re-accepted as a caller filter (see
    // `apply_filter`/`collect_filter_params` below), or a caller could
    // filter back onto the restricted rows.
    query = query.filter(sql::<Bool>("\"sweep_profiles\".\"admin_only\" = false"));

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_updated_at.ge(*start).and(col_updated_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: SweepProfilesQuery<'a>,
    filter: &Filter,
) -> Result<SweepProfilesQuery<'a>> {
    match filter.field.as_str() {
        "name" => {
            query = apply_text_filter!(query, filter, col_name)?;
        }
        "enabled" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => query = query.filter(col_enabled.eq(value)),
                FilterOp::NotEq => query = query.filter(col_enabled.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "enabled filter only supports equality".into(),
                    ));
                }
            }
        }
        // `admin_only` is intentionally NOT an accepted filter field: every
        // query is already unconditionally restricted to `admin_only =
        // false` in `build_query`, and accepting it as a caller filter would
        // let `admin_only:true` re-select the restricted rows. It stays
        // available as a projected output column.
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for sweep_profiles: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "name" => collect_text_params(params, filter),
        "enabled" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{raw}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: SweepProfilesQuery<'a>,
    order: &[OrderClause],
) -> SweepProfilesQuery<'a> {
    let mut applied = false;
    for clause in order {
        let (next_query, matched) = if !applied {
            apply_single_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
        query = next_query;
        applied = applied || matched;
    }

    // An unrecognized sort field must not disable ordering entirely: fall
    // back to the default so `sort:bogus` still yields deterministic,
    // pagination-safe results instead of unspecified row order.
    if !applied {
        query = query.order(col_name.asc());
    }

    query
}

fn apply_single_order<'a>(
    query: SweepProfilesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> (SweepProfilesQuery<'a>, bool) {
    match field {
        "name" => (
            match direction {
                OrderDirection::Asc => query.order(col_name.asc()),
                OrderDirection::Desc => query.order(col_name.desc()),
            },
            true,
        ),
        "updated_at" => (
            match direction {
                OrderDirection::Asc => query.order(col_updated_at.asc()),
                OrderDirection::Desc => query.order(col_updated_at.desc()),
            },
            true,
        ),
        "enabled" => (
            match direction {
                OrderDirection::Asc => query.order(col_enabled.asc()),
                OrderDirection::Desc => query.order(col_enabled.desc()),
            },
            true,
        ),
        "admin_only" => (
            match direction {
                OrderDirection::Asc => query.order(col_admin_only.asc()),
                OrderDirection::Desc => query.order(col_admin_only.desc()),
            },
            true,
        ),
        _ => (query, false),
    }
}

fn apply_secondary_order<'a>(
    query: SweepProfilesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> (SweepProfilesQuery<'a>, bool) {
    match field {
        "name" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_name.asc()),
                OrderDirection::Desc => query.then_order_by(col_name.desc()),
            },
            true,
        ),
        "updated_at" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_updated_at.asc()),
                OrderDirection::Desc => query.then_order_by(col_updated_at.desc()),
            },
            true,
        ),
        "enabled" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_enabled.asc()),
                OrderDirection::Desc => query.then_order_by(col_enabled.desc()),
            },
            true,
        ),
        "admin_only" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_admin_only.asc()),
                OrderDirection::Desc => query.then_order_by(col_admin_only.desc()),
            },
            true,
        ),
        _ => (query, false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Filter, FilterOp, FilterValue};

    fn plan_with(filters: Vec<Filter>) -> QueryPlan {
        QueryPlan {
            entity: Entity::SweepProfiles,
            filters,
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        }
    }

    #[test]
    fn builds_query_with_name_filter() {
        let plan = plan_with(vec![Filter {
            field: "name".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("default".to_string()),
        }]);
        assert!(
            build_query(&plan).is_ok(),
            "should build query with name filter"
        );
    }

    #[test]
    fn builds_query_with_enabled_filter() {
        let plan = plan_with(vec![Filter {
            field: "enabled".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("true".to_string()),
        }]);
        assert!(
            build_query(&plan).is_ok(),
            "should build query with enabled filter"
        );
    }

    /// Regression test for the authorization bypass fix: `admin_only` must
    /// stay rejected as a caller filter field, or `admin_only:true` could
    /// re-select rows the unconditional restriction excludes.
    #[test]
    fn admin_only_filter_field_is_rejected() {
        let plan = plan_with(vec![Filter {
            field: "admin_only".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("true".to_string()),
        }]);

        match build_query(&plan) {
            Err(err) => assert!(
                err.to_string().contains("unsupported filter field"),
                "unexpected error: {err}"
            ),
            Ok(_) => panic!("expected error for admin_only filter field"),
        }
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let plan = plan_with(vec![Filter {
            field: "timeout".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("3s".to_string()),
        }]);

        match build_query(&plan) {
            Err(err) => assert!(
                err.to_string().contains("unsupported filter field"),
                "unexpected error: {err}"
            ),
            Ok(_) => panic!("expected error for unsupported filter field"),
        }
    }

    #[test]
    fn unknown_sort_field_falls_back_to_default_order() {
        let mut plan = plan_with(vec![]);
        plan.order = vec![OrderClause {
            field: "bogus".into(),
            direction: OrderDirection::Desc,
        }];

        let (sql, _) = to_sql_and_params(&plan).expect("should build sql for unknown sort field");
        assert!(
            sql.contains("ORDER BY \"sweep_profiles\".\"name\" ASC"),
            "expected default ORDER BY to survive an unrecognized sort field: {sql}"
        );
    }

    /// Regression test for a live authorization bypass: the Ash row-level
    /// read policy in `sweep_profile.ex` restricts non-admins to
    /// `admin_only == false`, but this raw-SQL entity had no equivalent and
    /// returned every profile's full configuration to any caller with
    /// `networks.sweeps.view` (a viewer role). SRQL has no actor/scope
    /// context, so the fix is an unconditional restriction rather than a
    /// per-caller filter, making this entity a strict subset of what every
    /// caller may already read through Ash. Assert it applies to both
    /// `execute` and `to_sql_and_params` by asserting on the shared
    /// `build_query`-generated SQL.
    #[test]
    fn generated_sql_restricts_to_non_admin_only_profiles() {
        let plan = plan_with(vec![]);
        let (sql, _) = to_sql_and_params(&plan).expect("should build sql");

        assert!(
            sql.contains("\"sweep_profiles\".\"admin_only\" = false"),
            "expected an unconditional admin_only=false restriction: {sql}"
        );
    }

    /// Regression test for issue 4167 review finding 2: `to_sql_and_params`
    /// is the query the web-ng/core Elixir executors actually run (`execute`
    /// is only the standalone Rust HTTP service). Before this fix it emitted
    /// the raw `banner_grab` column — every timeout/concurrency/rate/queue
    /// knob and the per-protocol ports map — while the Rust `execute` path
    /// narrowed it to `banner_grab_enabled`/`banner_grab_protocols` via
    /// `into_json`. The same entity returned two different shapes depending
    /// on which path executed it.
    #[test]
    fn generated_sql_does_not_select_raw_banner_grab_column() {
        let plan = plan_with(vec![]);
        let (sql, _) = to_sql_and_params(&plan).expect("should build sql");

        assert!(
            !sql.contains("\"banner_grab\""),
            "raw banner_grab column must never be selected: {sql}"
        );
        assert!(
            sql.contains("AS banner_grab_enabled") && sql.contains("AS banner_grab_protocols"),
            "expected the narrowed banner-grab expressions to be selected: {sql}"
        );
    }
}
