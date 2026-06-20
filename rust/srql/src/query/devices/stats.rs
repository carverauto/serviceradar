use super::{
    filters::{
        apply_default_active_filter, apply_filter, has_deleted_filter, is_valid_jsonb_key,
        parse_bool, should_apply_default_active_filter,
    },
    DeviceStatsQuery,
};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Filter, FilterOp, FilterValue, OrderDirection},
    query::{is_negated_membership_op, normalize_mac_value, BindParam, QueryPlan},
    schema::ocsf_devices::dsl::{
        deleted_at as col_deleted_at, last_seen_time as col_last_seen_time, ocsf_devices,
    },
    time::{parse_time_value, TimeRange},
};
use chrono::{DateTime, Utc};
use diesel::dsl::sql;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_types::{Array, BigInt, Bool, Jsonb, Nullable, Text, Timestamptz};

/// Groupable fields for device stats queries
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) enum DeviceGroupField {
    Type,
    VendorName,
    RiskLevel,
    IsAvailable,
    IsActive,
    GatewayId,
}

impl DeviceGroupField {
    fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "type" | "device_type" => Some(Self::Type),
            "vendor_name" | "vendor" => Some(Self::VendorName),
            "risk_level" | "risk" => Some(Self::RiskLevel),
            "is_available" | "available" => Some(Self::IsAvailable),
            "is_active" | "active" => Some(Self::IsActive),
            "gateway_id" | "gateway" => Some(Self::GatewayId),
            _ => None,
        }
    }

    fn column(&self) -> &'static str {
        match self {
            Self::Type => "COALESCE(NULLIF(trim(type), ''), 'Unknown')",
            Self::VendorName => "COALESCE(vendor_name, 'Unknown')",
            Self::RiskLevel => "COALESCE(risk_level, 'Unknown')",
            Self::IsAvailable => "COALESCE(is_available, false)",
            Self::IsActive => "COALESCE(is_active, true)",
            Self::GatewayId => "gateway_id",
        }
    }

    fn response_key(&self) -> &'static str {
        match self {
            Self::Type => "type",
            Self::VendorName => "vendor_name",
            Self::RiskLevel => "risk_level",
            Self::IsAvailable => "is_available",
            Self::IsActive => "is_active",
            Self::GatewayId => "gateway_id",
        }
    }
}

/// SQL bind value for grouped stats queries
#[derive(Debug, Clone)]
pub(super) enum DeviceSqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Bool(bool),
    Int(i64),
    Timestamp(DateTime<Utc>),
}

impl DeviceSqlBindValue {
    pub(super) fn apply<'a>(
        &self,
        query: BoxedSqlQuery<'a, Pg, SqlQuery>,
    ) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            DeviceSqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            DeviceSqlBindValue::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            DeviceSqlBindValue::Bool(value) => query.bind::<Bool, _>(*value),
            DeviceSqlBindValue::Int(value) => query.bind::<BigInt, _>(*value),
            DeviceSqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

pub(super) fn bind_param_from_device_stats(value: DeviceSqlBindValue) -> BindParam {
    match value {
        DeviceSqlBindValue::Text(value) => BindParam::Text(value),
        DeviceSqlBindValue::TextArray(values) => BindParam::TextArray(values),
        DeviceSqlBindValue::Bool(value) => BindParam::Bool(value),
        DeviceSqlBindValue::Int(value) => BindParam::Int(value),
        DeviceSqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
pub(super) struct DeviceStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    pub(super) payload: Option<DbJson>,
}

/// Grouped stats query result
pub(super) struct DeviceGroupedStatsSql {
    pub(super) sql: String,
    pub(super) binds: Vec<DeviceSqlBindValue>,
}

/// Rollup stats query result
pub(super) struct DeviceRollupStatsSql {
    pub(super) sql: String,
}

pub(super) fn build_rollup_stats_query(plan: &QueryPlan) -> Result<Option<DeviceRollupStatsSql>> {
    let rollup_type = match plan.rollup_stats.as_ref() {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(None),
    };

    if !plan.filters.is_empty() || plan.time_range.is_some() {
        return Err(ServiceError::InvalidRequest(
            "devices rollup_stats does not support filters or time constraints".into(),
        ));
    }

    match rollup_type {
        "inventory_summary" => Ok(Some(DeviceRollupStatsSql {
            sql: String::from(
                r#"SELECT jsonb_build_object(
    'total', COALESCE((SELECT value FROM device_inventory_counts WHERE key = 'total'), 0)::bigint,
    'available', COALESCE((SELECT value FROM device_inventory_counts WHERE key = 'available'), 0)::bigint,
    'unavailable', COALESCE((SELECT value FROM device_inventory_counts WHERE key = 'unavailable'), 0)::bigint,
    'by_type', COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object('type', type, 'count', count)
            ORDER BY count DESC
        )
        FROM (
            SELECT type, count
            FROM device_inventory_type_counts
            ORDER BY count DESC, type ASC
        ) t
    ), '[]'::jsonb),
    'by_vendor', COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object('vendor_name', vendor_name, 'count', count)
            ORDER BY count DESC
        )
        FROM (
            SELECT vendor_name, count
            FROM device_inventory_vendor_counts
            ORDER BY count DESC, vendor_name ASC
        ) v
    ), '[]'::jsonb)
) AS payload"#,
            ),
        })),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for devices: '{other}' (supported: inventory_summary)"
        ))),
    }
}

#[derive(Debug, Clone)]
pub(super) struct DeviceStatsSpec {
    pub(super) alias: String,
    pub(super) group_fields: Vec<DeviceGroupField>,
}

pub(super) fn parse_stats_spec(raw: Option<&str>) -> Result<Option<DeviceStatsSpec>> {
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

    // Parse optional "by <field>[,<field>...]" clause
    let mut group_fields = Vec::new();
    if tokens.len() >= 5 {
        if !tokens[3].eq_ignore_ascii_case("by") {
            return Err(ServiceError::InvalidRequest(
                "expected 'by <field>' after stats alias".into(),
            ));
        }
        group_fields = parse_group_fields(tokens[4])?;
    } else if tokens.len() > 3 {
        return Err(ServiceError::InvalidRequest(
            "expected 'by <field>' after stats alias".into(),
        ));
    }

    Ok(Some(DeviceStatsSpec {
        alias,
        group_fields,
    }))
}

fn parse_group_fields(raw: &str) -> Result<Vec<DeviceGroupField>> {
    let fields: Vec<DeviceGroupField> = raw
        .split(',')
        .map(str::trim)
        .filter(|field| !field.is_empty())
        .map(parse_group_field)
        .collect::<Result<Vec<_>>>()?;

    if fields.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "expected at least one stats group field".into(),
        ));
    }

    Ok(fields)
}

fn parse_group_field(raw: &str) -> Result<DeviceGroupField> {
    DeviceGroupField::from_str(raw).ok_or_else(|| {
        ServiceError::InvalidRequest(format!(
            "unsupported stats group field '{}'. Supported fields: type, vendor_name, risk_level, is_available, is_active, gateway_id",
            raw
        ))
    })
}

/// Builds a grouped stats query using raw SQL (Diesel doesn't support GROUP BY well)
pub(super) fn build_grouped_stats_query(
    plan: &QueryPlan,
    spec: &DeviceStatsSpec,
) -> Result<DeviceGroupedStatsSql> {
    if spec.group_fields.is_empty() {
        return Err(ServiceError::Internal(anyhow::anyhow!(
            "at least one group field is required"
        )));
    }

    let mut binds = Vec::new();
    let mut clauses = Vec::new();

    if !plan.include_deleted && !has_deleted_filter(&plan.filters) {
        clauses.push("deleted_at IS NULL".to_string());
    }

    if should_apply_default_active_filter(&plan.filters)? {
        clauses.push("COALESCE(is_active, true) = true".to_string());
    }

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

    let group_pairs = spec
        .group_fields
        .iter()
        .map(|field| format!("'{}', {}", field.response_key(), field.column()))
        .collect::<Vec<_>>()
        .join(", ");
    let group_columns = spec
        .group_fields
        .iter()
        .map(DeviceGroupField::column)
        .collect::<Vec<_>>();
    let group_by_sql = group_columns.join(", ");

    // Build SELECT with jsonb_build_object
    let mut sql = format!(
        "SELECT jsonb_build_object({}, '{}', COUNT(*)) AS payload",
        group_pairs, spec.alias
    );
    sql.push_str("\nFROM ocsf_devices");

    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    sql.push_str(&format!("\nGROUP BY {group_by_sql}"));

    // Order by count descending by default
    let order_sql = build_grouped_stats_order_clause(plan, &spec.alias, &spec.group_fields);
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

fn build_grouped_stats_order_clause(
    plan: &QueryPlan,
    alias: &str,
    group_fields: &[DeviceGroupField],
) -> String {
    if plan.order.is_empty() {
        return "\nORDER BY COUNT(*) DESC".to_string();
    }

    let mut parts = Vec::new();
    for clause in &plan.order {
        let expr = if clause.field.eq_ignore_ascii_case(alias) || clause.field == "count" {
            "COUNT(*)".to_string()
        } else if let Some(group_field) = group_fields
            .iter()
            .find(|field| clause.field.eq_ignore_ascii_case(field.response_key()))
        {
            group_field.column().to_string()
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
        "mac" => build_grouped_mac_clause(filter, &mut binds)?,
        "gateway_id" => build_grouped_text_clause("gateway_id", filter, &mut binds)?,
        "agent_id" => build_grouped_text_clause("agent_id", filter, &mut binds)?,
        "availability_source_agent_id"
        | "availability_source_agent"
        | "primary_availability_source"
        | "primary_availability_source_agent_id" => {
            build_grouped_text_clause("availability_source_agent_id", filter, &mut binds)?
        }
        "available_from_agent" => {
            build_grouped_agent_availability_clause(filter, true, &mut binds)?
        }
        "unavailable_from_agent" => {
            build_grouped_agent_availability_clause(filter, false, &mut binds)?
        }
        "availability_source_fresh_within" => {
            build_grouped_availability_source_freshness_clause(filter, true, &mut binds)?
        }
        "availability_source_stale_after" => {
            build_grouped_availability_source_freshness_clause(filter, false, &mut binds)?
        }
        "type" | "device_type" => build_grouped_device_type_clause(filter, &mut binds)?,
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
        "is_active" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            binds.push(DeviceSqlBindValue::Bool(value));
            match filter.op {
                FilterOp::Eq => "COALESCE(is_active, true) = ?".to_string(),
                FilterOp::NotEq => "COALESCE(is_active, true) <> ?".to_string(),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "is_active filter only supports equality".into(),
                    ))
                }
            }
        }
        "include_inactive" => {
            let _ = parse_bool(filter.value.as_scalar()?)?;
            return Ok(None);
        }
        "deleted" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => {
                    if value {
                        "deleted_at IS NOT NULL".to_string()
                    } else {
                        "deleted_at IS NULL".to_string()
                    }
                }
                FilterOp::NotEq => {
                    if value {
                        "deleted_at IS NULL".to_string()
                    } else {
                        "deleted_at IS NOT NULL".to_string()
                    }
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "deleted filter only supports equality".into(),
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
            match &filter.op {
                FilterOp::In | FilterOp::Eq => {
                    "coalesce(discovery_sources, ARRAY[]::text[]) && ?".to_string()
                }
                op if is_negated_membership_op(op) => {
                    "NOT (coalesce(discovery_sources, ARRAY[]::text[]) && ?)".to_string()
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "discovery_sources filter only supports equality and list filters".into(),
                    ))
                }
            }
        }
        field if field.starts_with("metadata.") => {
            let key = field.strip_prefix("metadata.").unwrap();
            if !is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid metadata key '{key}'"
                )));
            }
            build_grouped_jsonb_text_clause("metadata", key, filter, &mut binds)?
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

fn build_grouped_device_type_clause(
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    let column = "COALESCE(NULLIF(trim(type), ''), 'Unknown')";

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
            Ok(format!("{column} <> ?"))
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
            Ok(format!("NOT ({column} = ANY(?))"))
        }
        _ => Err(ServiceError::InvalidRequest(
            "device_type filter only supports equality and list filters".into(),
        )),
    }
}

fn build_grouped_jsonb_text_clause(
    column: &str,
    key: &str,
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    let jsonb_expr = format!("{column}->>'{key}'");

    match filter.op {
        FilterOp::Eq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{jsonb_expr} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("({jsonb_expr} IS NULL OR {jsonb_expr} <> ?)"))
        }
        FilterOp::Like => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{jsonb_expr} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!(
                "({jsonb_expr} IS NULL OR {jsonb_expr} NOT ILIKE ?)"
            ))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "JSONB field '{column}.{key}' only supports equality and LIKE filters"
        ))),
    }
}

fn build_grouped_agent_availability_clause(
    filter: &Filter,
    available: bool,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(
            "per-agent availability filters only support equality".into(),
        ));
    }

    binds.push(DeviceSqlBindValue::Text(
        filter.value.as_scalar()?.to_string(),
    ));

    Ok(format!(
        "EXISTS (SELECT 1 FROM device_agent_availability daa WHERE daa.device_uid = ocsf_devices.uid AND daa.agent_id = ? AND daa.is_available = {available})"
    ))
}

fn build_grouped_availability_source_freshness_clause(
    filter: &Filter,
    fresh: bool,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(
            "availability source freshness filters only support equality".into(),
        ));
    }

    let threshold = filter
        .value
        .as_scalar()
        .and_then(parse_time_value)?
        .resolve(Utc::now())?
        .start;

    binds.push(DeviceSqlBindValue::Timestamp(threshold));

    let exists_op = if fresh { "EXISTS" } else { "NOT EXISTS" };

    Ok(format!(
        "NULLIF(BTRIM(ocsf_devices.availability_source_agent_id), '') IS NOT NULL \
         AND {exists_op} (SELECT 1 FROM device_agent_availability daa \
         WHERE daa.device_uid = ocsf_devices.uid \
         AND daa.agent_id = ocsf_devices.availability_source_agent_id \
         AND daa.checked_at >= ?)"
    ))
}

/// Rewrites ? placeholders to $1, $2, etc. for PostgreSQL
pub(super) fn rewrite_placeholders(sql: &str) -> String {
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

pub(super) fn build_stats_query(
    plan: &QueryPlan,
    spec: &DeviceStatsSpec,
) -> Result<DeviceStatsQuery<'static>> {
    let mut query = ocsf_devices.into_boxed::<Pg>();

    if !plan.include_deleted && !has_deleted_filter(&plan.filters) {
        query = query.filter(col_deleted_at.is_null());
    }

    if should_apply_default_active_filter(&plan.filters)? {
        query = apply_default_active_filter(query);
    }

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

/// Normalized MAC clause for the grouped stats raw-SQL path.
fn build_grouped_mac_clause(
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    let norm_col = "lower(regexp_replace(mac, '[^0-9a-fA-F]', '', 'g'))";

    match filter.op {
        FilterOp::Eq => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, false)?;
            binds.push(DeviceSqlBindValue::Text(normalized));
            Ok(format!("{norm_col} = ?"))
        }
        FilterOp::NotEq => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, false)?;
            binds.push(DeviceSqlBindValue::Text(normalized));
            Ok(format!("(mac IS NULL OR {norm_col} <> ?)"))
        }
        FilterOp::Like => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, true)?;
            binds.push(DeviceSqlBindValue::Text(normalized));
            Ok(format!("{norm_col} LIKE ?"))
        }
        FilterOp::NotLike => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, true)?;
            binds.push(DeviceSqlBindValue::Text(normalized));
            Ok(format!("(mac IS NULL OR {norm_col} NOT LIKE ?)"))
        }
        _ => Err(ServiceError::InvalidRequest(
            "mac filter only supports equality and LIKE operators".into(),
        )),
    }
}
