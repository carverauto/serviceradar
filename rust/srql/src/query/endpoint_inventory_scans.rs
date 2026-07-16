//! Query execution for endpoint inventory scan freshness rows.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::EndpointInventoryScanRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::endpoint_inventory_scans::dsl::{
        agent_id as col_agent_id, coverage_state as col_coverage_state, current as col_current,
        device_uid as col_device_uid, endpoint_inventory_scans, inserted_at as col_inserted_at,
        last_changed_scan_at as col_last_changed_scan_at, last_scan_at as col_last_scan_at,
        last_successful_scan_at as col_last_successful_scan_at,
        package_set_hash as col_package_set_hash, scan_id as col_scan_id, state as col_state,
        unchanged_scan_count as col_unchanged_scan_count, updated_at as col_updated_at,
        upload_reason as col_upload_reason,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::dsl::{not, sql};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::sql_types::{Nullable, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type EndpointInventoryScansTable = crate::schema::endpoint_inventory_scans::table;
type EndpointInventoryScansFromClause = FromClause<EndpointInventoryScansTable>;
type EndpointInventoryScansQuery<'a> = BoxedSelectStatement<
    'a,
    <EndpointInventoryScansTable as AsQuery>::SqlType,
    EndpointInventoryScansFromClause,
    Pg,
>;

const STALE_THRESHOLD_SQL: &str = "NOW() - INTERVAL '26 hours'";

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<EndpointInventoryScanRow> = query
        .select(EndpointInventoryScanRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<EndpointInventoryScanRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(EndpointInventoryScanRow::into_json)
        .collect())
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
        Entity::EndpointInventoryScans => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by endpoint_inventory_scans query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<EndpointInventoryScansQuery<'static>> {
    let mut query = endpoint_inventory_scans.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_last_scan_at.ge(*start).and(col_last_scan_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: EndpointInventoryScansQuery<'a>,
    filter: &Filter,
) -> Result<EndpointInventoryScansQuery<'a>> {
    match filter.field.as_str() {
        "device_uid" | "device_id" => {
            query = apply_text_filter!(query, filter, col_device_uid)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "scan_id" => {
            query = apply_text_filter!(query, filter, col_scan_id)?;
        }
        "state" => {
            query = apply_text_filter!(query, filter, col_state)?;
        }
        "coverage_state" | "coverage" => {
            query = apply_text_filter!(query, filter, col_coverage_state)?;
        }
        "package_set_hash" => {
            query = apply_text_filter!(query, filter, col_package_set_hash)?;
        }
        "upload_reason" => {
            query = apply_text_filter!(query, filter, col_upload_reason)?;
        }
        "current" => {
            query = apply_current_filter(query, filter)?;
        }
        "freshness" | "freshness_verdict" => {
            query = apply_freshness_filter(query, filter)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for endpoint_inventory_scans: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_current_filter<'a>(
    query: EndpointInventoryScansQuery<'a>,
    filter: &Filter,
) -> Result<EndpointInventoryScansQuery<'a>> {
    let value = parse_bool(filter.value.as_scalar()?)?;

    match filter.op {
        FilterOp::Eq => Ok(query.filter(col_current.eq(value))),
        FilterOp::NotEq => Ok(query.filter(col_current.ne(value))),
        _ => Err(ServiceError::InvalidRequest(
            "current filter only supports equality".into(),
        )),
    }
}

fn apply_freshness_filter<'a>(
    query: EndpointInventoryScansQuery<'a>,
    filter: &Filter,
) -> Result<EndpointInventoryScansQuery<'a>> {
    let value = filter.value.as_scalar()?.to_ascii_lowercase();
    let threshold = sql::<Nullable<Timestamptz>>(STALE_THRESHOLD_SQL);

    match (&filter.op, value.as_str()) {
        (FilterOp::Eq, "unknown") => Ok(query.filter(col_last_successful_scan_at.is_null())),
        (FilterOp::NotEq, "unknown") => Ok(query.filter(col_last_successful_scan_at.is_not_null())),
        (FilterOp::Eq, "fresh") => Ok(query.filter(
            col_last_successful_scan_at
                .is_not_null()
                .and(col_last_successful_scan_at.gt(threshold)),
        )),
        (FilterOp::NotEq, "fresh") => Ok(query.filter(not(col_last_successful_scan_at
            .is_not_null()
            .and(col_last_successful_scan_at.gt(threshold))))),
        (FilterOp::Eq, "stale") => Ok(query.filter(
            col_last_successful_scan_at
                .is_not_null()
                .and(col_last_successful_scan_at.le(threshold)),
        )),
        (FilterOp::NotEq, "stale") => Ok(query.filter(not(col_last_successful_scan_at
            .is_not_null()
            .and(col_last_successful_scan_at.le(threshold))))),
        (_, "fresh" | "stale" | "unknown") => Err(ServiceError::InvalidRequest(
            "freshness filter only supports equality".into(),
        )),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid endpoint inventory freshness verdict '{}'",
            value
        ))),
    }
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "t" | "yes" | "y" | "1" => Ok(true),
        "false" | "f" | "no" | "n" | "0" => Ok(false),
        other => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{other}'"
        ))),
    }
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
        "device_uid" | "device_id" | "agent_id" | "scan_id" | "state" | "coverage_state"
        | "coverage" | "package_set_hash" | "upload_reason" => collect_text_params(params, filter),
        "current" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        "freshness" | "freshness_verdict" => {
            let _ = filter.value.as_scalar()?;
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: EndpointInventoryScansQuery<'a>,
    order: &[OrderClause],
) -> EndpointInventoryScansQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_single_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
    }

    if !applied {
        query = query
            .order(col_last_scan_at.desc())
            .then_order_by(col_agent_id.asc());
    }

    query
}

fn apply_single_order<'a>(
    query: EndpointInventoryScansQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> EndpointInventoryScansQuery<'a> {
    match field {
        "device_uid" | "device_id" => match direction {
            OrderDirection::Asc => query.order(col_device_uid.asc()),
            OrderDirection::Desc => query.order(col_device_uid.desc()),
        },
        "agent_id" => match direction {
            OrderDirection::Asc => query.order(col_agent_id.asc()),
            OrderDirection::Desc => query.order(col_agent_id.desc()),
        },
        "scan_id" => match direction {
            OrderDirection::Asc => query.order(col_scan_id.asc()),
            OrderDirection::Desc => query.order(col_scan_id.desc()),
        },
        "state" => match direction {
            OrderDirection::Asc => query.order(col_state.asc()),
            OrderDirection::Desc => query.order(col_state.desc()),
        },
        "last_scan_at" => match direction {
            OrderDirection::Asc => query.order(col_last_scan_at.asc()),
            OrderDirection::Desc => query.order(col_last_scan_at.desc()),
        },
        "last_changed_scan_at" => match direction {
            OrderDirection::Asc => query.order(col_last_changed_scan_at.asc()),
            OrderDirection::Desc => query.order(col_last_changed_scan_at.desc()),
        },
        "unchanged_scan_count" => match direction {
            OrderDirection::Asc => query.order(col_unchanged_scan_count.asc()),
            OrderDirection::Desc => query.order(col_unchanged_scan_count.desc()),
        },
        "inserted_at" => match direction {
            OrderDirection::Asc => query.order(col_inserted_at.asc()),
            OrderDirection::Desc => query.order(col_inserted_at.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.order(col_updated_at.asc()),
            OrderDirection::Desc => query.order(col_updated_at.desc()),
        },
        "freshness" | "freshness_verdict" => match direction {
            OrderDirection::Asc => query.order(col_last_successful_scan_at.asc()),
            OrderDirection::Desc => query.order(col_last_successful_scan_at.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: EndpointInventoryScansQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> EndpointInventoryScansQuery<'a> {
    match field {
        "device_uid" | "device_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_device_uid.asc()),
            OrderDirection::Desc => query.then_order_by(col_device_uid.desc()),
        },
        "agent_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_agent_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_agent_id.desc()),
        },
        "scan_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_scan_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_scan_id.desc()),
        },
        "state" => match direction {
            OrderDirection::Asc => query.then_order_by(col_state.asc()),
            OrderDirection::Desc => query.then_order_by(col_state.desc()),
        },
        "last_scan_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_last_scan_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_last_scan_at.desc()),
        },
        "last_changed_scan_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_last_changed_scan_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_last_changed_scan_at.desc()),
        },
        "unchanged_scan_count" => match direction {
            OrderDirection::Asc => query.then_order_by(col_unchanged_scan_count.asc()),
            OrderDirection::Desc => query.then_order_by(col_unchanged_scan_count.desc()),
        },
        "inserted_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_inserted_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_inserted_at.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_updated_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_updated_at.desc()),
        },
        "freshness" | "freshness_verdict" => match direction {
            OrderDirection::Asc => query.then_order_by(col_last_successful_scan_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_last_successful_scan_at.desc()),
        },
        _ => query,
    }
}
