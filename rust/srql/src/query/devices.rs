use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::DeviceRow,
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    schema::ocsf_devices::dsl::{
        agent_id as col_agent_id, device_type as col_device_type,
        first_seen_time as col_first_seen_time, hostname as col_hostname, ip as col_ip,
        is_available as col_is_available, last_seen_time as col_last_seen_time, mac as col_mac,
        model as col_model, ocsf_devices, poller_id as col_poller_id,
        risk_level as col_risk_level, type_id as col_type_id, uid as col_uid,
        vendor_name as col_vendor_name,
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

type OcsfDevicesTable = crate::schema::ocsf_devices::table;
type DeviceFromClause = FromClause<OcsfDevicesTable>;
type DeviceQuery<'a> =
    BoxedSelectStatement<'a, <OcsfDevicesTable as AsQuery>::SqlType, DeviceFromClause, Pg>;
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
    let mut query = ocsf_devices.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_last_seen_time.ge(*start).and(col_last_seen_time.le(*end)));
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
    let mut query = ocsf_devices.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_last_seen_time.ge(*start).and(col_last_seen_time.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    let select_sql = format!("coalesce(COUNT(*), 0) as {}", spec.alias);
    Ok(query.select(sql::<BigInt>(&select_sql)))
}

fn apply_filter<'a>(mut query: DeviceQuery<'a>, filter: &Filter) -> Result<DeviceQuery<'a>> {
    match filter.field.as_str() {
        // Support both OCSF "uid" and legacy "device_id" for backward compatibility
        "uid" | "device_id" => {
            query = apply_text_filter!(query, filter, col_uid)?;
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
        // OCSF device type (string name like "Server", "Router", etc.)
        "type" | "device_type" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_device_type,
                filter.value.as_scalar()?.to_string(),
                "device_type filter only supports equality"
            )?;
        }
        // OCSF device type_id (numeric enum)
        "type_id" => {
            let type_id: i32 = filter
                .value
                .as_scalar()?
                .parse()
                .map_err(|_| ServiceError::InvalidRequest("type_id must be an integer".into()))?;
            query = apply_eq_filter!(
                query,
                filter,
                col_type_id,
                type_id,
                "type_id filter only supports equality"
            )?;
        }
        // OCSF vendor_name
        "vendor_name" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_vendor_name,
                filter.value.as_scalar()?.to_string(),
                "vendor_name filter only supports equality"
            )?;
        }
        // OCSF model
        "model" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_model,
                filter.value.as_scalar()?.to_string(),
                "model filter only supports equality"
            )?;
        }
        // OCSF risk_level
        "risk_level" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_risk_level,
                filter.value.as_scalar()?.to_string(),
                "risk_level filter only supports equality"
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
        // JSONB path queries for os object
        "os.name" => {
            query = apply_jsonb_text_filter(query, filter, "os", "name")?;
        }
        "os.version" => {
            query = apply_jsonb_text_filter(query, filter, "os", "version")?;
        }
        "os.type" => {
            query = apply_jsonb_text_filter(query, filter, "os", "type")?;
        }
        // JSONB path queries for hw_info object
        "hw_info.serial_number" => {
            query = apply_jsonb_text_filter(query, filter, "hw_info", "serial_number")?;
        }
        "hw_info.cpu_type" => {
            query = apply_jsonb_text_filter(query, filter, "hw_info", "cpu_type")?;
        }
        "hw_info.cpu_architecture" => {
            query = apply_jsonb_text_filter(query, filter, "hw_info", "cpu_architecture")?;
        }
        // JSONB path queries for metadata (arbitrary keys)
        field if field.starts_with("metadata.") => {
            let key = field.strip_prefix("metadata.").unwrap();
            if !is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid metadata key '{key}'"
                )));
            }
            query = apply_jsonb_text_filter(query, filter, "metadata", key)?;
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
        "uid" | "device_id" => collect_text_params(params, filter, true),
        "hostname" | "ip" | "mac" => collect_text_params(params, filter, false),
        "poller_id" | "agent_id" | "type" | "device_type" | "vendor_name" | "model"
        | "risk_level" => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        "type_id" => {
            let type_id: i64 = filter
                .value
                .as_scalar()?
                .parse()
                .map_err(|_| ServiceError::InvalidRequest("type_id must be an integer".into()))?;
            params.push(BindParam::Int(type_id));
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
        // JSONB path fields - all use text bind params
        "os.name" | "os.version" | "os.type" | "hw_info.serial_number" | "hw_info.cpu_type"
        | "hw_info.cpu_architecture" => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        // Dynamic metadata.* fields
        field if field.starts_with("metadata.") => {
            let key = field.strip_prefix("metadata.").unwrap();
            if !is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid metadata key '{key}'"
                )));
            }
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
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
                // Support both OCSF "uid" and legacy "device_id"
                "uid" | "device_id" => match clause.direction {
                    OrderDirection::Asc => query.order(col_uid.asc()),
                    OrderDirection::Desc => query.order(col_uid.desc()),
                },
                // Support both OCSF and legacy time field names
                "first_seen_time" | "first_seen" => match clause.direction {
                    OrderDirection::Asc => query.order(col_first_seen_time.asc()),
                    OrderDirection::Desc => query.order(col_first_seen_time.desc()),
                },
                "last_seen_time" | "last_seen" => match clause.direction {
                    OrderDirection::Asc => query.order(col_last_seen_time.asc()),
                    OrderDirection::Desc => query.order(col_last_seen_time.desc()),
                },
                "type_id" => match clause.direction {
                    OrderDirection::Asc => query.order(col_type_id.asc()),
                    OrderDirection::Desc => query.order(col_type_id.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "uid" | "device_id" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_uid.asc()),
                    OrderDirection::Desc => query.then_order_by(col_uid.desc()),
                },
                "first_seen_time" | "first_seen" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_first_seen_time.asc()),
                    OrderDirection::Desc => query.then_order_by(col_first_seen_time.desc()),
                },
                "last_seen_time" | "last_seen" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_last_seen_time.asc()),
                    OrderDirection::Desc => query.then_order_by(col_last_seen_time.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query
            .order(col_last_seen_time.desc())
            .then_order_by(col_uid.desc());
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

/// Validates that a JSONB key is safe to use in a query.
/// Only allows alphanumeric characters, underscores, and hyphens.
fn is_valid_jsonb_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 64
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Applies a text filter to a JSONB field path using the ->> operator.
/// Supports equality, inequality, and LIKE operations.
fn apply_jsonb_text_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
    column: &str,
    key: &str,
) -> Result<DeviceQuery<'a>> {
    // Construct the JSONB text extraction expression: column->>'key'
    let jsonb_expr = format!("{column}->>'{key}'");
    let value = filter.value.as_scalar()?.to_string();

    match filter.op {
        FilterOp::Eq => {
            let expr = sql::<Bool>(&format!("{jsonb_expr} = ")).bind::<Text, _>(value);
            Ok(query.filter(expr))
        }
        FilterOp::NotEq => {
            let expr = sql::<Bool>(&format!("({jsonb_expr} IS NULL OR {jsonb_expr} != "))
                .bind::<Text, _>(value)
                .sql(")");
            Ok(query.filter(expr))
        }
        FilterOp::Like => {
            let expr = sql::<Bool>(&format!("{jsonb_expr} ILIKE ")).bind::<Text, _>(value);
            Ok(query.filter(expr))
        }
        FilterOp::NotLike => {
            let expr = sql::<Bool>(&format!("({jsonb_expr} IS NULL OR {jsonb_expr} NOT ILIKE "))
                .bind::<Text, _>(value)
                .sql(")");
            Ok(query.filter(expr))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "JSONB field '{column}.{key}' only supports equality and LIKE filters"
        ))),
    }
}
