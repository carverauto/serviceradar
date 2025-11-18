use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    models::DiscoveredInterfaceRow,
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    schema::discovered_interfaces::dsl::{
        agent_id as col_agent_id, created_at as col_created_at, device_id as col_device_id,
        device_ip as col_device_ip, discovered_interfaces, if_admin_status as col_if_admin_status,
        if_alias as col_if_alias, if_descr as col_if_descr, if_index as col_if_index,
        if_name as col_if_name, if_oper_status as col_if_oper_status,
        if_phys_address as col_if_phys_address, if_speed as col_if_speed,
        poller_id as col_poller_id, timestamp as col_timestamp,
    },
    time::TimeRange,
};
use diesel::dsl::{not, sql};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::sql_types::{Array, Bool, Text};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type InterfacesTable = crate::schema::discovered_interfaces::table;
type InterfacesFromClause = FromClause<InterfacesTable>;
type InterfacesQuery<'a> =
    BoxedSelectStatement<'a, <InterfacesTable as AsQuery>::SqlType, InterfacesFromClause, Pg>;

#[derive(Debug, Clone)]
struct CountStatsSpec {
    alias: String,
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    if let Some(stats) = parse_stats_spec(plan.stats.as_deref())? {
        let payload = execute_stats(conn, plan, &stats).await?;
        return Ok(vec![payload]);
    }

    let query = build_query(plan)?;
    let rows: Vec<DiscoveredInterfaceRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(DiscoveredInterfaceRow::into_json)
        .collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;

    if parse_stats_spec(plan.stats.as_deref())?.is_some() {
        let base = base_query(plan)?;
        let sql = diesel::debug_query::<Pg, _>(&base.count()).to_string();
        return Ok(sql);
    }

    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Interfaces => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by interfaces query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<InterfacesQuery<'static>> {
    let mut query = base_query(plan)?;
    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn base_query(plan: &QueryPlan) -> Result<InterfacesQuery<'static>> {
    let mut query = discovered_interfaces.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(query)
}

async fn execute_stats(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
    spec: &CountStatsSpec,
) -> Result<Value> {
    let query = base_query(plan)?;
    let total: i64 = query
        .count()
        .get_result(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(serde_json::json!({ &spec.alias: total }))
}

fn apply_filter<'a>(
    mut query: InterfacesQuery<'a>,
    filter: &Filter,
) -> Result<InterfacesQuery<'a>> {
    match filter.field.as_str() {
        "device_id" => {
            query = apply_text_filter!(query, filter, col_device_id)?;
        }
        "device_ip" | "ip" => {
            query = apply_text_filter_no_lists!(
                query,
                filter,
                col_device_ip,
                "device_ip filter does not support lists"
            )?;
        }
        "poller_id" => {
            query = apply_text_filter!(query, filter, col_poller_id)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "if_index" => {
            let value = parse_i32(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_if_index,
                value,
                "if_index filter only supports equality"
            )?;
        }
        "if_name" => {
            query = apply_text_filter!(query, filter, col_if_name)?;
        }
        "if_descr" | "description" => {
            query = apply_text_filter!(query, filter, col_if_descr)?;
        }
        "if_alias" => {
            query = apply_text_filter!(query, filter, col_if_alias)?;
        }
        "if_phys_address" | "mac" => {
            query = apply_text_filter!(query, filter, col_if_phys_address)?;
        }
        "if_admin_status" => {
            let value = parse_i32(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_if_admin_status,
                value,
                "if_admin_status filter only supports equality"
            )?;
        }
        "if_oper_status" | "status" => {
            let value = parse_i32(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_if_oper_status,
                value,
                "if_oper_status filter only supports equality"
            )?;
        }
        "if_speed" | "speed" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_if_speed,
                value,
                "if_speed filter only supports equality"
            )?;
        }
        "ip_addresses" | "ip_address" => {
            let values: Vec<String> = match &filter.value {
                FilterValue::Scalar(value) => vec![value.to_string()],
                FilterValue::List(list) => list.clone(),
            };
            if values.is_empty() {
                return Ok(query);
            }
            let expr = sql::<Bool>("coalesce(ip_addresses, ARRAY[]::text[]) @> ")
                .bind::<Array<Text>, _>(values);
            match filter.op {
                FilterOp::Eq | FilterOp::In => {
                    query = query.filter(expr);
                }
                FilterOp::NotEq | FilterOp::NotIn => {
                    query = query.filter(not(expr));
                }
                FilterOp::Like | FilterOp::NotLike => {
                    return Err(ServiceError::InvalidRequest(
                        "ip_addresses filter does not support pattern matching".into(),
                    ));
                }
            }
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_ordering<'a>(
    mut query: InterfacesQuery<'a>,
    order: &[OrderClause],
) -> InterfacesQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_timestamp.asc()),
                    OrderDirection::Desc => query.order(col_timestamp.desc()),
                },
                "device_ip" => match clause.direction {
                    OrderDirection::Asc => query.order(col_device_ip.asc()),
                    OrderDirection::Desc => query.order(col_device_ip.desc()),
                },
                "device_id" => match clause.direction {
                    OrderDirection::Asc => query.order(col_device_id.asc()),
                    OrderDirection::Desc => query.order(col_device_id.desc()),
                },
                "if_name" => match clause.direction {
                    OrderDirection::Asc => query.order(col_if_name.asc()),
                    OrderDirection::Desc => query.order(col_if_name.desc()),
                },
                "if_descr" => match clause.direction {
                    OrderDirection::Asc => query.order(col_if_descr.asc()),
                    OrderDirection::Desc => query.order(col_if_descr.desc()),
                },
                "if_index" => match clause.direction {
                    OrderDirection::Asc => query.order(col_if_index.asc()),
                    OrderDirection::Desc => query.order(col_if_index.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_timestamp.asc()),
                    OrderDirection::Desc => query.then_order_by(col_timestamp.desc()),
                },
                "device_ip" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_device_ip.asc()),
                    OrderDirection::Desc => query.then_order_by(col_device_ip.desc()),
                },
                "device_id" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_device_id.asc()),
                    OrderDirection::Desc => query.then_order_by(col_device_id.desc()),
                },
                "if_name" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_if_name.asc()),
                    OrderDirection::Desc => query.then_order_by(col_if_name.desc()),
                },
                "if_descr" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_if_descr.asc()),
                    OrderDirection::Desc => query.then_order_by(col_if_descr.desc()),
                },
                "if_index" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_if_index.asc()),
                    OrderDirection::Desc => query.then_order_by(col_if_index.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order((col_timestamp.desc(), col_created_at.desc()));
    }

    query
}

fn parse_stats_spec(raw: Option<&str>) -> Result<Option<CountStatsSpec>> {
    let value = match raw {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(None),
    };

    let lower = value.to_lowercase();
    if lower.contains(" by ") {
        return Err(ServiceError::InvalidRequest(
            "interfaces stats queries do not support grouping yet".into(),
        ));
    }

    let alias_pos = lower.rfind(" as ").ok_or_else(|| {
        ServiceError::InvalidRequest("stats expressions must include an alias".into())
    })?;
    let alias = value[alias_pos + 4..].trim();
    if alias.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "stats alias cannot be empty".into(),
        ));
    }
    if !alias
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
    {
        return Err(ServiceError::InvalidRequest(
            "stats alias must be alphanumeric".into(),
        ));
    }

    let expr = value[..alias_pos].trim().replace(' ', "").to_lowercase();
    if expr != "count()" && expr != "count(*)" {
        return Err(ServiceError::InvalidRequest(
            "interfaces stats queries only support count()".into(),
        ));
    }

    Ok(Some(CountStatsSpec {
        alias: alias.to_string(),
    }))
}

fn parse_i32(raw: &str) -> Result<i32> {
    raw.parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest(format!("expected integer value for '{raw}'")))
}

fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("expected integer value for '{raw}'")))
}
