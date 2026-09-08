//! Query execution for OCSF network_activity (flows) entity.

mod expressions;
mod filters;
mod literals;
mod order;
mod params;
mod query;
mod row;
mod scope;
mod snmp;
mod stats;

#[cfg(test)]
mod tests;

pub(super) use self::expressions::*;
pub(crate) use self::literals::normalize_cidr_literal;
use self::{
    filters::apply_filter,
    literals::{near_exists_sql, normalize_device_uid_literal, normalize_near_literal, NearSide},
    order::apply_ordering,
    params::collect_filter_params,
    query::build_query,
    row::{FlowRow, FlowRowLegacy},
    scope::flow_device_scope_expr,
    snmp::apply_snmp_index_filter,
    stats::{execute_stats, to_sql_and_params_stats},
};
use super::{BindParam, QueryPlan};

// The query object `execute_stats` loads, so the placeholder guard can render the
// real execution path with `debug_query`; see `query/tests/placeholders.rs`.
#[cfg(test)]
pub(super) use stats::execution_query;
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    schema::ocsf_network_activity::dsl::*,
    time::TimeRange,
};
use diesel::dsl::{not, sql};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::sql_types::{Bool, Text};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type FlowsTable = crate::schema::ocsf_network_activity::table;
type FlowsFromClause = FromClause<FlowsTable>;
type FlowsQuery<'a> =
    BoxedSelectStatement<'a, <FlowsTable as AsQuery>::SqlType, FlowsFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    if plan.stats.is_some() {
        return execute_stats(conn, plan).await;
    }

    // Prefer the full projection (includes prefix-tag columns). If the
    // migration has not been applied yet, fall back so plain in:flows stays up.
    // Classify Diesel errors *before* wrapping in ServiceError::Internal, whose
    // Display is always "internal error" and would hide column names.
    match load_flow_rows_full(conn, plan).await {
        Ok(rows) => Ok(rows),
        Err(err) if is_missing_prefix_tag_column_diesel(&err) => {
            load_flow_rows_legacy(conn, plan).await
        }
        Err(FullLoadError::Plan(err)) => Err(err),
        Err(FullLoadError::Diesel(err)) => Err(ServiceError::Internal(err.into())),
    }
}

enum FullLoadError {
    Plan(ServiceError),
    Diesel(diesel::result::Error),
}

async fn load_flow_rows_full(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> std::result::Result<Vec<Value>, FullLoadError> {
    let query = build_query(plan).map_err(FullLoadError::Plan)?;
    let rows: Vec<FlowRow> = query
        .select(FlowRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<FlowRow>(conn)
        .await
        .map_err(FullLoadError::Diesel)?;
    Ok(rows.into_iter().map(FlowRow::into_json).collect())
}

async fn load_flow_rows_legacy(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<Value>> {
    let rows: Vec<FlowRowLegacy> = build_query(plan)?
        .select(FlowRowLegacy::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<FlowRowLegacy>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(rows.into_iter().map(FlowRowLegacy::into_json).collect())
}

fn is_missing_prefix_tag_column_diesel(err: &FullLoadError) -> bool {
    match err {
        FullLoadError::Diesel(diesel::result::Error::DatabaseError(_kind, info)) => {
            let msg = info.message().to_ascii_lowercase();
            let col = info.column_name().unwrap_or("").to_ascii_lowercase();
            let mentions = |s: &str| msg.contains(s) || col == s;
            mentions("src_prefix_tags")
                || mentions("dst_prefix_tags")
                || mentions("src_prefix_tags_source")
                || mentions("dst_prefix_tags_source")
                || (msg.contains("does not exist") && msg.contains("prefix_tag"))
        }
        _ => false,
    }
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if plan.stats.is_some() {
        return to_sql_and_params_stats(plan);
    }

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
        Entity::Flows | Entity::AttributedFlows => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by flows query".into(),
        )),
    }
}

#[cfg(test)]
mod fallback_classifier_tests {
    use super::{is_missing_prefix_tag_column_diesel, FullLoadError};
    use diesel::result::{DatabaseErrorKind, Error as DieselError};

    struct FakeDbInfo {
        message: String,
        column: Option<String>,
    }

    impl diesel::result::DatabaseErrorInformation for FakeDbInfo {
        fn message(&self) -> &str {
            &self.message
        }
        fn details(&self) -> Option<&str> {
            None
        }
        fn hint(&self) -> Option<&str> {
            None
        }
        fn table_name(&self) -> Option<&str> {
            None
        }
        fn column_name(&self) -> Option<&str> {
            self.column.as_deref()
        }
        fn constraint_name(&self) -> Option<&str> {
            None
        }
        fn statement_position(&self) -> Option<i32> {
            None
        }
    }

    #[test]
    fn classifies_undefined_prefix_tag_column() {
        let err = FullLoadError::Diesel(DieselError::DatabaseError(
            DatabaseErrorKind::Unknown,
            Box::new(FakeDbInfo {
                message: "column \"src_prefix_tags\" does not exist".into(),
                column: Some("src_prefix_tags".into()),
            }),
        ));
        assert!(is_missing_prefix_tag_column_diesel(&err));
    }

    #[test]
    fn ignores_unrelated_database_errors() {
        let err = FullLoadError::Diesel(DieselError::DatabaseError(
            DatabaseErrorKind::UniqueViolation,
            Box::new(FakeDbInfo {
                message: "duplicate key value".into(),
                column: None,
            }),
        ));
        assert!(!is_missing_prefix_tag_column_diesel(&err));
    }
}
