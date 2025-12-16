use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::DeviceRow,
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    schema::unified_devices::dsl::{
        agent_id as col_agent_id, device_id as col_device_id, device_type as col_device_type,
        first_seen as col_first_seen, hostname as col_hostname, ip as col_ip,
        is_available as col_is_available, last_seen as col_last_seen, mac as col_mac,
        poller_id as col_poller_id, service_status as col_service_status,
        service_type as col_service_type, unified_devices, version_info as col_version_info,
    },
    time::TimeRange,
};
use diesel::dsl::{not, sql};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::sql_types::{Array, BigInt, Bool, Text};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type UnifiedDevicesTable = crate::schema::unified_devices::table;
type DeviceFromClause = FromClause<UnifiedDevicesTable>;
type DeviceQuery<'a> =
    BoxedSelectStatement<'a, <UnifiedDevicesTable as AsQuery>::SqlType, DeviceFromClause, Pg>;
type DeviceStatsQuery<'a> = BoxedSelectStatement<'a, BigInt, DeviceFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;

    if let Some(spec) = parse_stats_spec(plan.stats.as_deref())? {
        let query = build_stats_query(plan, &spec)?;
        let values: Vec<i64> = query
            .load(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        let count = values.into_iter().next().unwrap_or(0);
        return Ok(vec![serde_json::json!({ spec.alias: count })]);
    }

    let query = build_query(plan)?;
    let rows: Vec<DeviceRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(DeviceRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    if let Some(spec) = parse_stats_spec(plan.stats.as_deref())? {
        let query = build_stats_query(plan, &spec)?;
        let sql = super::diesel_sql(&query)?;

        let mut params = Vec::new();

        if let Some(TimeRange { start, end }) = &plan.time_range {
            params.push(BindParam::timestamptz(*start));
            params.push(BindParam::timestamptz(*end));
        }

        for filter in &plan.filters {
            collect_filter_params(&mut params, filter)?;
        }

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

        return Ok((sql, params));
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
        Entity::Devices => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by devices query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<DeviceQuery<'static>> {
    let mut query = unified_devices.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_last_seen.ge(*start).and(col_last_seen.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

#[derive(Debug, Clone)]
struct DeviceStatsSpec {
    alias: String,
}

fn parse_stats_spec(raw: Option<&str>) -> Result<Option<DeviceStatsSpec>> {
    let raw = match raw {
        Some(raw) if !raw.trim().is_empty() => raw.trim(),
        _ => return Ok(None),
    };

    let tokens: Vec<&str> = raw.split_whitespace().collect();
    if tokens.len() < 3 {
        return Err(ServiceError::InvalidRequest(
            "stats expressions must be of the form 'count() as alias'".into(),
        ));
    }

    if !tokens[0].eq_ignore_ascii_case("count()") || !tokens[1].eq_ignore_ascii_case("as") {
        return Err(ServiceError::InvalidRequest(
            "devices stats only support count()".into(),
        ));
    }

    let alias = tokens[2]
        .trim_matches('"')
        .trim_matches('\'')
        .to_lowercase();

    if alias.is_empty()
        || alias
            .chars()
            .any(|ch| !ch.is_ascii_alphanumeric() && ch != '_')
    {
        return Err(ServiceError::InvalidRequest(
            "stats alias must be alphanumeric".into(),
        ));
    }

    if tokens.len() > 3 {
        return Err(ServiceError::InvalidRequest(
            "devices stats do not support grouping yet".into(),
        ));
    }

    Ok(Some(DeviceStatsSpec { alias }))
}

fn build_stats_query(
    plan: &QueryPlan,
    spec: &DeviceStatsSpec,
) -> Result<DeviceStatsQuery<'static>> {
    let mut query = unified_devices.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_last_seen.ge(*start).and(col_last_seen.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    let select_sql = format!("coalesce(COUNT(*), 0) as {}", spec.alias);
    Ok(query.select(sql::<BigInt>(&select_sql)))
}

fn apply_filter<'a>(mut query: DeviceQuery<'a>, filter: &Filter) -> Result<DeviceQuery<'a>> {
    match filter.field.as_str() {
        "device_id" => {
            query = apply_text_filter!(query, filter, col_device_id)?;
        }
        "hostname" => {
            query = apply_text_filter_no_lists!(
                query,
                filter,
                col_hostname,
                "hostname filter does not support lists"
            )?;
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
        "poller_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_poller_id,
                filter.value.as_scalar()?.to_string(),
                "poller filter only supports equality"
            )?;
        }
        "agent_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_agent_id,
                filter.value.as_scalar()?.to_string(),
                "agent filter only supports equality"
            )?;
        }
        "is_available" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_is_available,
                parse_bool(filter.value.as_scalar()?)?,
                "is_available only supports equality"
            )?;
        }
        "device_type" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_device_type,
                filter.value.as_scalar()?.to_string(),
                "device_type filter only supports equality"
            )?;
        }
        "service_type" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_service_type,
                filter.value.as_scalar()?.to_string(),
                "service_type filter only supports equality"
            )?;
        }
        "service_status" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_service_status,
                filter.value.as_scalar()?.to_string(),
                "service_status filter only supports equality"
            )?;
        }
        "discovery_sources" => {
            let values = match &filter.value {
                FilterValue::Scalar(v) => vec![v.to_string()],
                FilterValue::List(list) => list.clone(),
            };
            if values.is_empty() {
                return Ok(query);
            }
            let expr = sql::<Bool>("coalesce(discovery_sources, ARRAY[]::text[]) @> ")
                .bind::<Array<Text>, _>(values);
            query = if matches!(filter.op, FilterOp::NotIn) {
                query.filter(not(expr))
            } else {
                query.filter(expr)
            };
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
        "device_id" => collect_text_params(params, filter, true),
        "hostname" | "ip" | "mac" => collect_text_params(params, filter, false),
        "poller_id" | "agent_id" | "device_type" | "service_type" | "service_status" => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        "is_available" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        "discovery_sources" => {
            let values = match &filter.value {
                FilterValue::Scalar(v) => vec![v.to_string()],
                FilterValue::List(list) => list.clone(),
            };
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(mut query: DeviceQuery<'a>, order: &[OrderClause]) -> DeviceQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "device_id" => match clause.direction {
                    OrderDirection::Asc => query.order(col_device_id.asc()),
                    OrderDirection::Desc => query.order(col_device_id.desc()),
                },
                "first_seen" => match clause.direction {
                    OrderDirection::Asc => query.order(col_first_seen.asc()),
                    OrderDirection::Desc => query.order(col_first_seen.desc()),
                },
                "last_seen" => match clause.direction {
                    OrderDirection::Asc => query.order(col_last_seen.asc()),
                    OrderDirection::Desc => query.order(col_last_seen.desc()),
                },
                "version_info" => match clause.direction {
                    OrderDirection::Asc => query.order(col_version_info.asc()),
                    OrderDirection::Desc => query.order(col_version_info.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "device_id" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_device_id.asc()),
                    OrderDirection::Desc => query.then_order_by(col_device_id.desc()),
                },
                "first_seen" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_first_seen.asc()),
                    OrderDirection::Desc => query.then_order_by(col_first_seen.desc()),
                },
                "last_seen" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_last_seen.asc()),
                    OrderDirection::Desc => query.then_order_by(col_last_seen.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query
            .order(col_last_seen.desc())
            .then_order_by(col_device_id.desc());
    }

    query
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
