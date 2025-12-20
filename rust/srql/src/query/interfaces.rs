use super::{BindParam, QueryPlan};
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

const MAX_IP_ADDRESS_FILTER_VALUES: usize = 64;

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

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    let mut params = Vec::new();
    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }
    for filter in &plan.filters {
        collect_filter_params(&mut params, filter)?;
    }

    if let Some(spec) = parse_stats_spec(plan.stats.as_deref())? {
        let base = base_query(plan)?;
        let count = base.count();
        let count_sql = super::diesel_sql(&count)?;

        #[cfg(any(test, debug_assertions))]
        {
            let bind_count = super::diesel_bind_count(&count)?;
            if bind_count != params.len() {
                return Err(ServiceError::Internal(anyhow::anyhow!(
                    "bind count mismatch (diesel {bind_count} vs params {})",
                    params.len()
                )));
            }
        }

        let sql = format!("SELECT ({count_sql}) AS {}", spec.alias);
        return Ok((sql, params));
    }

    let query = build_query(plan)?.limit(plan.limit).offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

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
            if values.len() > MAX_IP_ADDRESS_FILTER_VALUES {
                return Err(ServiceError::InvalidRequest(format!(
                    "ip_addresses filter supports at most {MAX_IP_ADDRESS_FILTER_VALUES} values"
                )));
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
                _ => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "ip_addresses filter does not support operator {:?}",
                        filter.op
                    )));
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

fn collect_text_params(
    params: &mut Vec<BindParam>,
    filter: &Filter,
    allow_lists: bool,
) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn if allow_lists => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => Err(ServiceError::InvalidRequest(
            "list filters are not supported for this field".into(),
        )),
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "device_id" | "poller_id" | "agent_id" | "if_name" | "if_descr" | "description"
        | "if_alias" | "if_phys_address" | "mac" => collect_text_params(params, filter, true),
        "device_ip" | "ip" => collect_text_params(params, filter, false),
        "if_admin_status" | "if_oper_status" | "status" => {
            params.push(BindParam::Int(i64::from(parse_i32(
                filter.value.as_scalar()?,
            )?)));
            Ok(())
        }
        "if_speed" | "speed" => {
            params.push(BindParam::Int(parse_i64(filter.value.as_scalar()?)?));
            Ok(())
        }
        "ip_addresses" | "ip_address" => {
            let values: Vec<String> = match &filter.value {
                FilterValue::Scalar(value) => vec![value.to_string()],
                FilterValue::List(list) => list.clone(),
            };
            if values.is_empty() {
                return Ok(());
            }
            if values.len() > MAX_IP_ADDRESS_FILTER_VALUES {
                return Err(ServiceError::InvalidRequest(format!(
                    "ip_addresses filter supports at most {MAX_IP_ADDRESS_FILTER_VALUES} values"
                )));
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn stats_count_interfaces_emits_count_query() {
        let plan = stats_plan("count() as interface_count");
        let spec = parse_stats_spec(plan.stats.as_deref())
            .expect("stats parse should succeed")
            .expect("stats expected");
        assert_eq!(spec.alias, "interface_count");

        let (sql, _) = to_sql_and_params(&plan).expect("stats SQL should be generated");
        assert!(
            sql.to_lowercase().contains("count("),
            "unexpected stats SQL: {}",
            sql
        );
    }

    fn stats_plan(stats: &str) -> QueryPlan {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        QueryPlan {
            entity: Entity::Interfaces,
            filters: vec![Filter {
                field: "device_id".into(),
                value: FilterValue::Scalar("dev-1".into()),
                op: FilterOp::Eq,
            }],
            order: vec![OrderClause {
                field: "timestamp".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 50,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(stats.to_string()),
            downsample: None,
            rollup_stats: None,
        }
    }
}
