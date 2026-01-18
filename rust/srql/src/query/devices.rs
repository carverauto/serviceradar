use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::DeviceRow,
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    schema::ocsf_devices::dsl::{
        agent_id as col_agent_id, device_type as col_device_type,
        first_seen_time as col_first_seen_time, gateway_id as col_gateway_id,
        hostname as col_hostname, ip as col_ip, is_available as col_is_available,
        last_seen_time as col_last_seen_time, mac as col_mac, model as col_model, ocsf_devices,
        risk_level as col_risk_level, type_id as col_type_id, uid as col_uid,
        vendor_name as col_vendor_name,
    },
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::dsl::{not, sql};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, BoxedSqlQuery, FromClause, SqlQuery};
use diesel::sql_types::{Array, BigInt, Bool, Jsonb, Nullable, Text, Timestamptz};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type OcsfDevicesTable = crate::schema::ocsf_devices::table;
type DeviceFromClause = FromClause<OcsfDevicesTable>;
type DeviceQuery<'a> =
    BoxedSelectStatement<'a, <OcsfDevicesTable as AsQuery>::SqlType, DeviceFromClause, Pg>;
type DeviceStatsQuery<'a> = BoxedSelectStatement<'a, BigInt, DeviceFromClause, Pg>;

/// Groupable fields for device stats queries
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum DeviceGroupField {
    Type,
    VendorName,
    RiskLevel,
    IsAvailable,
    GatewayId,
}

impl DeviceGroupField {
    fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "type" | "device_type" => Some(Self::Type),
            "vendor_name" | "vendor" => Some(Self::VendorName),
            "risk_level" | "risk" => Some(Self::RiskLevel),
            "is_available" | "available" => Some(Self::IsAvailable),
            "gateway_id" | "gateway" => Some(Self::GatewayId),
            _ => None,
        }
    }

    fn column(&self) -> &'static str {
        match self {
            // Note: Diesel schema uses "device_type" but actual SQL column is "type"
            Self::Type => "COALESCE(type, 'Unknown')",
            Self::VendorName => "COALESCE(vendor_name, 'Unknown')",
            Self::RiskLevel => "COALESCE(risk_level, 'Unknown')",
            Self::IsAvailable => "COALESCE(is_available, false)",
            Self::GatewayId => "gateway_id",
        }
    }

    fn response_key(&self) -> &'static str {
        match self {
            Self::Type => "type",
            Self::VendorName => "vendor_name",
            Self::RiskLevel => "risk_level",
            Self::IsAvailable => "is_available",
            Self::GatewayId => "gateway_id",
        }
    }
}

/// SQL bind value for grouped stats queries
#[derive(Debug, Clone)]
enum DeviceSqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Bool(bool),
    Int(i64),
    Timestamp(DateTime<Utc>),
}

impl DeviceSqlBindValue {
    fn apply<'a>(&self, query: BoxedSqlQuery<'a, Pg, SqlQuery>) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            DeviceSqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            DeviceSqlBindValue::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            DeviceSqlBindValue::Bool(value) => query.bind::<Bool, _>(*value),
            DeviceSqlBindValue::Int(value) => query.bind::<BigInt, _>(*value),
            DeviceSqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

fn bind_param_from_device_stats(value: DeviceSqlBindValue) -> BindParam {
    match value {
        DeviceSqlBindValue::Text(value) => BindParam::Text(value),
        DeviceSqlBindValue::TextArray(values) => BindParam::TextArray(values),
        DeviceSqlBindValue::Bool(value) => BindParam::Bool(value),
        DeviceSqlBindValue::Int(value) => BindParam::Int(value),
        DeviceSqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
    }
}

#[derive(Debug, QueryableByName)]
struct DeviceStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<Value>,
}

/// Grouped stats query result
struct DeviceGroupedStatsSql {
    sql: String,
    binds: Vec<DeviceSqlBindValue>,
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        // Check if this is a grouped stats query
        if spec.group_field.is_some() {
            let grouped_sql = build_grouped_stats_query(plan, &spec)?;
            let mut query = diesel::sql_query(&grouped_sql.sql).into_boxed();
            for bind in grouped_sql.binds {
                query = bind.apply(query);
            }
            let rows: Vec<DeviceStatsPayload> = query
                .load(conn)
                .await
                .map_err(|err| ServiceError::Internal(err.into()))?;
            return Ok(rows.into_iter().filter_map(|row| row.payload).collect());
        }

        // Simple count (ungrouped)
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
    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        // Check if this is a grouped stats query
        if spec.group_field.is_some() {
            let grouped_sql = build_grouped_stats_query(plan, &spec)?;
            let sql = rewrite_placeholders(&grouped_sql.sql);
            let params: Vec<BindParam> = grouped_sql
                .binds
                .into_iter()
                .map(bind_param_from_device_stats)
                .collect();
            return Ok((sql, params));
        }

        // Simple count (ungrouped)
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
        query = query.filter(
            col_last_seen_time
                .ge(*start)
                .and(col_last_seen_time.le(*end)),
        );
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
    group_field: Option<DeviceGroupField>,
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

    // Parse optional "by <field>" clause
    let mut group_field = None;
    if tokens.len() >= 5 {
        if !tokens[3].eq_ignore_ascii_case("by") {
            return Err(ServiceError::InvalidRequest(
                "expected 'by <field>' after stats alias".into(),
            ));
        }
        group_field = Some(parse_group_field(tokens[4])?);
    } else if tokens.len() > 3 {
        return Err(ServiceError::InvalidRequest(
            "expected 'by <field>' after stats alias".into(),
        ));
    }

    Ok(Some(DeviceStatsSpec { alias, group_field }))
}

fn parse_group_field(raw: &str) -> Result<DeviceGroupField> {
    DeviceGroupField::from_str(raw).ok_or_else(|| {
        ServiceError::InvalidRequest(format!(
            "unsupported stats group field '{}'. Supported fields: type, vendor_name, risk_level, is_available, gateway_id",
            raw
        ))
    })
}

/// Builds a grouped stats query using raw SQL (Diesel doesn't support GROUP BY well)
fn build_grouped_stats_query(
    plan: &QueryPlan,
    spec: &DeviceStatsSpec,
) -> Result<DeviceGroupedStatsSql> {
    let group_field = spec
        .group_field
        .ok_or_else(|| ServiceError::Internal(anyhow::anyhow!("group_field is required")))?;

    let mut binds = Vec::new();
    let mut clauses = Vec::new();

    // Time range filter
    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("last_seen_time >= ?".to_string());
        binds.push(DeviceSqlBindValue::Timestamp(*start));
        clauses.push("last_seen_time <= ?".to_string());
        binds.push(DeviceSqlBindValue::Timestamp(*end));
    }

    // Apply filters
    for filter in &plan.filters {
        if let Some((clause, mut bind_values)) = build_grouped_stats_filter_clause(filter)? {
            clauses.push(clause);
            binds.append(&mut bind_values);
        }
    }

    let column = group_field.column();
    let response_key = group_field.response_key();

    // Build SELECT with jsonb_build_object
    let mut sql = format!(
        "SELECT jsonb_build_object('{}', {}, '{}', COUNT(*)) AS payload",
        response_key, column, spec.alias
    );
    sql.push_str("\nFROM ocsf_devices");

    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    sql.push_str(&format!("\nGROUP BY {column}"));

    // Order by count descending by default
    let order_sql = build_grouped_stats_order_clause(plan, &spec.alias, column);
    sql.push_str(&order_sql);

    // Apply limit (default 20 for distributions)
    let limit = if plan.limit > 0 && plan.limit <= 100 {
        plan.limit
    } else {
        20
    };
    sql.push_str(&format!("\nLIMIT {limit}"));

    if plan.offset > 0 {
        sql.push_str(&format!(" OFFSET {}", plan.offset));
    }

    Ok(DeviceGroupedStatsSql { sql, binds })
}

fn build_grouped_stats_order_clause(plan: &QueryPlan, alias: &str, group_column: &str) -> String {
    if plan.order.is_empty() {
        return "\nORDER BY COUNT(*) DESC".to_string();
    }

    let mut parts = Vec::new();
    for clause in &plan.order {
        let expr = if clause.field.eq_ignore_ascii_case(alias) || clause.field == "count" {
            "COUNT(*)".to_string()
        } else if clause
            .field
            .eq_ignore_ascii_case(group_column.split('(').next().unwrap_or(""))
        {
            group_column.to_string()
        } else {
            continue;
        };

        let dir = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{expr} {dir}"));
    }

    if parts.is_empty() {
        "\nORDER BY COUNT(*) DESC".to_string()
    } else {
        format!("\nORDER BY {}", parts.join(", "))
    }
}

fn build_grouped_stats_filter_clause(
    filter: &Filter,
) -> Result<Option<(String, Vec<DeviceSqlBindValue>)>> {
    let mut binds = Vec::new();
    let clause = match filter.field.as_str() {
        "uid" => build_grouped_text_clause("uid", filter, &mut binds)?,
        "hostname" => build_grouped_text_clause("hostname", filter, &mut binds)?,
        "ip" => build_grouped_text_clause("ip", filter, &mut binds)?,
        "mac" => build_grouped_text_clause("mac", filter, &mut binds)?,
        "gateway_id" => build_grouped_text_clause("gateway_id", filter, &mut binds)?,
        "agent_id" => build_grouped_text_clause("agent_id", filter, &mut binds)?,
        "type" | "device_type" => build_grouped_text_clause("device_type", filter, &mut binds)?,
        "type_id" => {
            let type_id: i64 =
                filter.value.as_scalar()?.parse().map_err(|_| {
                    ServiceError::InvalidRequest("type_id must be an integer".into())
                })?;
            binds.push(DeviceSqlBindValue::Int(type_id));
            match filter.op {
                FilterOp::Eq => "type_id = ?".to_string(),
                FilterOp::NotEq => "(type_id IS NULL OR type_id <> ?)".to_string(),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "type_id filter only supports equality".into(),
                    ))
                }
            }
        }
        "vendor_name" => build_grouped_text_clause("vendor_name", filter, &mut binds)?,
        "model" => build_grouped_text_clause("model", filter, &mut binds)?,
        "risk_level" => build_grouped_text_clause("risk_level", filter, &mut binds)?,
        "is_available" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            binds.push(DeviceSqlBindValue::Bool(value));
            match filter.op {
                FilterOp::Eq => "is_available = ?".to_string(),
                FilterOp::NotEq => "(is_available IS NULL OR is_available <> ?)".to_string(),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "is_available filter only supports equality".into(),
                    ))
                }
            }
        }
        "discovery_sources" => {
            let values = match &filter.value {
                FilterValue::Scalar(v) => vec![v.to_string()],
                FilterValue::List(list) => list.clone(),
            };
            if values.is_empty() {
                return Ok(None);
            }
            binds.push(DeviceSqlBindValue::TextArray(values));
            match filter.op {
                FilterOp::In | FilterOp::Eq => {
                    "coalesce(discovery_sources, ARRAY[]::text[]) @> ?".to_string()
                }
                FilterOp::NotIn | FilterOp::NotEq => {
                    "NOT (coalesce(discovery_sources, ARRAY[]::text[]) @> ?)".to_string()
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "discovery_sources filter only supports equality and list filters".into(),
                    ))
                }
            }
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for device stats: '{other}'"
            )));
        }
    };

    Ok(Some((clause, binds)))
}

fn build_grouped_text_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("({column} IS NULL OR {column} <> ?)"))
        }
        FilterOp::Like => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("({column} IS NULL OR {column} NOT ILIKE ?)"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            binds.push(DeviceSqlBindValue::TextArray(values));
            Ok(format!("{column} = ANY(?)"))
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            binds.push(DeviceSqlBindValue::TextArray(values));
            Ok(format!("({column} IS NULL OR NOT ({column} = ANY(?)))"))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

/// Rewrites ? placeholders to $1, $2, etc. for PostgreSQL
fn rewrite_placeholders(sql: &str) -> String {
    let mut result = String::with_capacity(sql.len());
    let mut index = 1;
    for ch in sql.chars() {
        if ch == '?' {
            result.push('$');
            result.push_str(&index.to_string());
            index += 1;
        } else {
            result.push(ch);
        }
    }
    result
}

fn build_stats_query(
    plan: &QueryPlan,
    spec: &DeviceStatsSpec,
) -> Result<DeviceStatsQuery<'static>> {
    let mut query = ocsf_devices.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(
            col_last_seen_time
                .ge(*start)
                .and(col_last_seen_time.le(*end)),
        );
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    let select_sql = format!("coalesce(COUNT(*), 0) as {}", spec.alias);
    Ok(query.select(sql::<BigInt>(&select_sql)))
}

fn apply_filter<'a>(mut query: DeviceQuery<'a>, filter: &Filter) -> Result<DeviceQuery<'a>> {
    match filter.field.as_str() {
        "uid" => {
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
        "gateway_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_gateway_id,
                filter.value.as_scalar()?.to_string(),
                "gateway filter only supports equality"
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
            let type_id: i32 =
                filter.value.as_scalar()?.parse().map_err(|_| {
                    ServiceError::InvalidRequest("type_id must be an integer".into())
                })?;
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
        "tags" => {
            query = apply_tags_filter(query, filter)?;
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
        // JSONB path queries for tags (arbitrary keys)
        field if field.starts_with("tags.") => {
            let key = field.strip_prefix("tags.").unwrap();
            if !is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid tags key '{key}'"
                )));
            }
            query = apply_jsonb_text_filter(query, filter, "tags", key)?;
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
        "uid" => collect_text_params(params, filter, true),
        "hostname" | "ip" | "mac" => collect_text_params(params, filter, false),
        "gateway_id" | "agent_id" | "type" | "device_type" | "vendor_name" | "model"
        | "risk_level" => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        "tags" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
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
            _ => Err(ServiceError::InvalidRequest(
                "tags filter only supports equality and list filters".into(),
            )),
        },
        "type_id" => {
            let type_id: i64 =
                filter.value.as_scalar()?.parse().map_err(|_| {
                    ServiceError::InvalidRequest("type_id must be an integer".into())
                })?;
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
        "os.name"
        | "os.version"
        | "os.type"
        | "hw_info.serial_number"
        | "hw_info.cpu_type"
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
        // Dynamic tags.* fields
        field if field.starts_with("tags.") => {
            let key = field.strip_prefix("tags.").unwrap();
            if !is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid tags key '{key}'"
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
                "uid" => match clause.direction {
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
                "uid" => match clause.direction {
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

fn apply_tags_filter<'a>(query: DeviceQuery<'a>, filter: &Filter) -> Result<DeviceQuery<'a>> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let tag = filter.value.as_scalar()?.to_string();
            let expr = sql::<Bool>("coalesce(tags, '{}'::jsonb) ? ").bind::<Text, _>(tag);
            if matches!(filter.op, FilterOp::NotEq) {
                Ok(query.filter(not(expr)))
            } else {
                Ok(query.filter(expr))
            }
        }
        FilterOp::In | FilterOp::NotIn => {
            let tags = filter.value.as_list()?.to_vec();
            if tags.is_empty() {
                return Ok(query);
            }
            let expr = sql::<Bool>("coalesce(tags, '{}'::jsonb) ?| ").bind::<Array<Text>, _>(tags);
            if matches!(filter.op, FilterOp::NotIn) {
                Ok(query.filter(not(expr)))
            } else {
                Ok(query.filter(expr))
            }
        }
        _ => Err(ServiceError::InvalidRequest(
            "tags filter only supports equality and list filters".into(),
        )),
    }
}
