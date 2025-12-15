use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::DeviceUpdateRow,
    parser::{Entity, Filter, OrderClause, OrderDirection},
    schema::device_updates::dsl::{
        agent_id as col_agent_id, available as col_available, device_id as col_device_id,
        device_updates, discovery_source as col_discovery_source, hostname as col_hostname,
        ip as col_ip, mac as col_mac, observed_at as col_observed_at, partition as col_partition,
        poller_id as col_poller_id,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type DeviceUpdatesTable = crate::schema::device_updates::table;
type DeviceUpdatesFromClause = FromClause<DeviceUpdatesTable>;
type DeviceUpdatesQuery<'a> =
    BoxedSelectStatement<'a, <DeviceUpdatesTable as AsQuery>::SqlType, DeviceUpdatesFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<DeviceUpdateRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(DeviceUpdateRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let sql = super::diesel_sql(&query.limit(plan.limit).offset(plan.offset))?;

    let mut params = Vec::new();
    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params(&mut params, filter)?;
    }

    params.push(BindParam::Int(plan.limit));
    params.push(BindParam::Int(plan.offset));

    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::DeviceUpdates => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by device_updates query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<DeviceUpdatesQuery<'static>> {
    let mut query = device_updates.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_observed_at.ge(*start).and(col_observed_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: DeviceUpdatesQuery<'a>,
    filter: &Filter,
) -> Result<DeviceUpdatesQuery<'a>> {
    match filter.field.as_str() {
        "device_id" => {
            query = apply_text_filter!(query, filter, col_device_id)?;
        }
        "ip" => {
            query = apply_text_filter_no_lists!(
                query,
                filter,
                col_ip,
                "ip filter does not support lists"
            )?;
        }
        "mac" => {
            query = apply_text_filter_no_lists!(
                query,
                filter,
                col_mac,
                "mac filter does not support lists"
            )?;
        }
        "hostname" => {
            query = apply_text_filter_no_lists!(
                query,
                filter,
                col_hostname,
                "hostname filter does not support lists"
            )?;
        }
        "poller_id" => {
            query = apply_text_filter!(query, filter, col_poller_id)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "partition" => {
            query = apply_text_filter!(query, filter, col_partition)?;
        }
        "discovery_source" | "source" => {
            query = apply_text_filter!(query, filter, col_discovery_source)?;
        }
        "available" | "is_available" => {
            let value = filter.value.as_scalar()?.to_lowercase();
            let bool_val = value == "true" || value == "1";
            query = query.filter(col_available.eq(bool_val));
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for device_updates: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn collect_text_params(
    params: &mut Vec<BindParam>,
    filter: &Filter,
    allow_lists: bool,
) -> Result<()> {
    match filter.op {
        crate::parser::FilterOp::Eq
        | crate::parser::FilterOp::NotEq
        | crate::parser::FilterOp::Like
        | crate::parser::FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn if allow_lists => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => Err(
            ServiceError::InvalidRequest("list filters are not supported for this field".into()),
        ),
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "device_id" | "poller_id" | "agent_id" | "partition" | "discovery_source" | "source" => {
            collect_text_params(params, filter, true)
        }
        "ip" | "mac" | "hostname" => collect_text_params(params, filter, false),
        "available" | "is_available" => {
            let value = filter.value.as_scalar()?.to_lowercase();
            let bool_val = value == "true" || value == "1";
            params.push(BindParam::Bool(bool_val));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for device_updates: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: DeviceUpdatesQuery<'a>,
    order: &[OrderClause],
) -> DeviceUpdatesQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "observed_at" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_observed_at.asc()),
                    OrderDirection::Desc => query.order(col_observed_at.desc()),
                },
                "device_id" => match clause.direction {
                    OrderDirection::Asc => query.order(col_device_id.asc()),
                    OrderDirection::Desc => query.order(col_device_id.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "observed_at" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_observed_at.asc()),
                    OrderDirection::Desc => query.then_order_by(col_observed_at.desc()),
                },
                "device_id" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_device_id.asc()),
                    OrderDirection::Desc => query.then_order_by(col_device_id.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order(col_observed_at.desc());
    }

    query
}
