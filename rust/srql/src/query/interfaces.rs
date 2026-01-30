use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, BigInt, Bool, Float8, Int4, Jsonb, Nullable, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

const MAX_IP_ADDRESS_FILTER_VALUES: usize = 64;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    if let Some(stats) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let stats_sql = build_stats_sql(plan, &stats)?;
        let mut query = sql_query(&stats_sql.sql).into_boxed::<Pg>();
        for param in stats_sql.binds {
            query = bind_param(query, param)?;
        }
        let rows: Vec<StatsPayload> = query
            .load(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows.into_iter().filter_map(|row| row.payload).collect());
    }

    let query_sql = build_query_sql(plan)?;
    let mut query = sql_query(&query_sql.sql).into_boxed::<Pg>();
    for param in query_sql.binds {
        query = bind_param(query, param)?;
    }

    let rows: Vec<InterfaceRow> = query
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(InterfaceRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(stats) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let stats_sql = build_stats_sql(plan, &stats)?;
        return Ok((stats_sql.sql, stats_sql.binds));
    }

    let query_sql = build_query_sql(plan)?;
    Ok((query_sql.sql, query_sql.binds))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Interfaces => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by interfaces query".into(),
        )),
    }
}

#[derive(Debug, QueryableByName)]
struct InterfaceRow {
    #[diesel(sql_type = Timestamptz)]
    timestamp: DateTime<Utc>,
    #[diesel(sql_type = Nullable<Text>)]
    agent_id: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    gateway_id: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    device_ip: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    device_id: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    interface_uid: Option<String>,
    #[diesel(sql_type = Nullable<Int4>)]
    if_index: Option<i32>,
    #[diesel(sql_type = Nullable<Text>)]
    if_name: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    if_descr: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    if_alias: Option<String>,
    #[diesel(sql_type = Nullable<Int4>)]
    if_type: Option<i32>,
    #[diesel(sql_type = Nullable<Text>)]
    if_type_name: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    interface_kind: Option<String>,
    #[diesel(sql_type = Nullable<BigInt>)]
    if_speed: Option<i64>,
    #[diesel(sql_type = Nullable<BigInt>)]
    speed_bps: Option<i64>,
    #[diesel(sql_type = Nullable<Int4>)]
    mtu: Option<i32>,
    #[diesel(sql_type = Nullable<Text>)]
    duplex: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    if_phys_address: Option<String>,
    #[diesel(sql_type = Nullable<Array<Text>>)]
    ip_addresses: Option<Vec<String>>,
    #[diesel(sql_type = Nullable<Int4>)]
    if_admin_status: Option<i32>,
    #[diesel(sql_type = Nullable<Int4>)]
    if_oper_status: Option<i32>,
    #[diesel(sql_type = Nullable<Jsonb>)]
    metadata: Option<serde_json::Value>,
    #[diesel(sql_type = Nullable<Jsonb>)]
    available_metrics: Option<serde_json::Value>,
    #[diesel(sql_type = Nullable<Float8>)]
    in_errors: Option<f64>,
    #[diesel(sql_type = Nullable<Float8>)]
    out_errors: Option<f64>,
    #[diesel(sql_type = Timestamptz)]
    created_at: DateTime<Utc>,
    // Fields from interface_settings table (LEFT JOIN)
    #[diesel(sql_type = Bool)]
    favorited: bool,
    #[diesel(sql_type = Bool)]
    metrics_enabled: bool,
}

impl InterfaceRow {
    fn into_json(self) -> serde_json::Value {
        let speed_bps = self.speed_bps.or(self.if_speed);
        serde_json::json!({
            "timestamp": self.timestamp,
            "agent_id": self.agent_id,
            "gateway_id": self.gateway_id,
            "device_ip": self.device_ip,
            "device_id": self.device_id,
            "uid": self.device_id,
            "interface_uid": self.interface_uid,
            "if_index": self.if_index,
            "if_name": self.if_name,
            "if_descr": self.if_descr,
            "if_alias": self.if_alias,
            "if_type": self.if_type,
            "if_type_name": self.if_type_name,
            "interface_kind": self.interface_kind,
            "if_speed": self.if_speed,
            "speed_bps": speed_bps,
            "mtu": self.mtu,
            "duplex": self.duplex,
            "if_phys_address": self.if_phys_address,
            "mac": self.if_phys_address,
            "ip_addresses": self.ip_addresses.unwrap_or_default(),
            "if_admin_status": self.if_admin_status,
            "if_oper_status": self.if_oper_status,
            "metadata": self.metadata.unwrap_or(serde_json::json!({})),
            "available_metrics": self.available_metrics,
            "in_errors": self.in_errors,
            "out_errors": self.out_errors,
            "created_at": self.created_at,
            // Interface settings (from LEFT JOIN with interface_settings table)
            "favorited": self.favorited,
            "metrics_enabled": self.metrics_enabled,
        })
    }
}

#[derive(Debug, QueryableByName)]
struct StatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<Value>,
}

struct SqlBuildResult {
    sql: String,
    binds: Vec<BindParam>,
}

fn build_query_sql(plan: &QueryPlan) -> Result<SqlBuildResult> {
    let (latest_only, filters) = extract_latest_filter(&plan.filters)?;
    let mut binds = Vec::new();
    let mut clauses = Vec::new();
    let mut bind_idx = 1;

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(format!(
            "di.timestamp >= ${} AND di.timestamp <= ${}",
            bind_idx,
            bind_idx + 1
        ));
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
        bind_idx += 2;
    }

    for filter in &filters {
        if let Some(clause) = build_filter_clause(filter, &mut binds, &mut bind_idx)? {
            clauses.push(clause);
        }
    }

    // SELECT from discovered_interfaces with LEFT JOIN to interface_settings
    // to include favorited and metrics_enabled flags
    let mut base_select = String::from(
        "SELECT di.timestamp, di.agent_id, di.gateway_id, di.device_ip, di.device_id, di.interface_uid, \
        di.if_index, di.if_name, di.if_descr, di.if_alias, di.if_type, di.if_type_name, di.interface_kind, \
        di.if_speed, di.speed_bps, di.mtu, di.duplex, di.if_phys_address, di.ip_addresses, \
        di.if_admin_status, di.if_oper_status, di.metadata, di.available_metrics, \
        tm_in.value AS in_errors, tm_out.value AS out_errors, di.created_at, \
        COALESCE(ifs.favorited, false) AS favorited, \
        COALESCE(ifs.metrics_enabled, false) AS metrics_enabled \
        FROM discovered_interfaces di \
        LEFT JOIN interface_settings ifs ON ifs.device_id = di.device_id AND ifs.interface_uid = di.interface_uid \
        LEFT JOIN LATERAL ( \
          SELECT tm.value \
          FROM timeseries_metrics tm \
          WHERE tm.device_id = di.device_id \
            AND tm.if_index = di.if_index \
            AND tm.metric_name = 'ifInErrors' \
            AND tm.metric_type = 'snmp' \
          ORDER BY tm.timestamp DESC \
          LIMIT 1 \
        ) tm_in ON true \
        LEFT JOIN LATERAL ( \
          SELECT tm.value \
          FROM timeseries_metrics tm \
          WHERE tm.device_id = di.device_id \
            AND tm.if_index = di.if_index \
            AND tm.metric_name = 'ifOutErrors' \
            AND tm.metric_type = 'snmp' \
          ORDER BY tm.timestamp DESC \
          LIMIT 1 \
        ) tm_out ON true",
    );

    if !clauses.is_empty() {
        base_select.push_str(" WHERE ");
        base_select.push_str(&clauses.join(" AND "));
    }

    let (sql, binds) = if latest_only {
        let mut inner = String::from("SELECT DISTINCT ON (di.device_id, di.interface_uid) ");
        inner.push_str(&base_select["SELECT ".len()..]);
        inner.push_str(
            " ORDER BY di.device_id, di.interface_uid, di.timestamp DESC, di.created_at DESC",
        );

        let mut outer = format!("SELECT * FROM ({inner}) AS latest");
        if let Some(order_clause) = build_order_clause(&plan.order) {
            outer.push(' ');
            outer.push_str(&order_clause);
        }
        outer.push_str(&format!(" LIMIT ${} OFFSET ${}", bind_idx, bind_idx + 1));
        let mut binds = binds;
        binds.push(BindParam::Int(plan.limit));
        binds.push(BindParam::Int(plan.offset));
        (outer, binds)
    } else {
        let mut sql = base_select;
        if let Some(order_clause) = build_order_clause(&plan.order) {
            sql.push(' ');
            sql.push_str(&order_clause);
        }
        sql.push_str(&format!(" LIMIT ${} OFFSET ${}", bind_idx, bind_idx + 1));
        let mut binds = binds;
        binds.push(BindParam::Int(plan.limit));
        binds.push(BindParam::Int(plan.offset));
        (sql, binds)
    };

    Ok(SqlBuildResult { sql, binds })
}

fn build_stats_sql(plan: &QueryPlan, spec: &CountStatsSpec) -> Result<SqlBuildResult> {
    let (latest_only, filters) = extract_latest_filter(&plan.filters)?;
    let mut binds = Vec::new();
    let mut clauses = Vec::new();
    let mut bind_idx = 1;

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(format!(
            "di.timestamp >= ${} AND di.timestamp <= ${}",
            bind_idx,
            bind_idx + 1
        ));
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
        bind_idx += 2;
    }

    for filter in &filters {
        if let Some(clause) = build_filter_clause(filter, &mut binds, &mut bind_idx)? {
            clauses.push(clause);
        }
    }

    let mut base =
        String::from("SELECT di.device_id, di.interface_uid FROM discovered_interfaces di");
    if !clauses.is_empty() {
        base.push_str(" WHERE ");
        base.push_str(&clauses.join(" AND "));
    }

    let sql = if latest_only {
        format!(
            "SELECT jsonb_build_object('{}', COALESCE(COUNT(*), 0)::bigint) AS payload FROM (SELECT DISTINCT ON (di.device_id, di.interface_uid) {} ORDER BY di.device_id, di.interface_uid, di.timestamp DESC, di.created_at DESC) AS latest",
            spec.alias, base
        )
    } else {
        format!(
            "SELECT jsonb_build_object('{}', COALESCE(COUNT(*), 0)::bigint) AS payload FROM {}",
            spec.alias, base
        )
    };

    Ok(SqlBuildResult { sql, binds })
}

fn extract_latest_filter(filters: &[Filter]) -> Result<(bool, Vec<Filter>)> {
    let mut latest_only = false;
    let mut remaining = Vec::new();

    for filter in filters {
        if filter.field == "latest" {
            if !matches!(filter.op, FilterOp::Eq) {
                return Err(ServiceError::InvalidRequest(
                    "latest filter only supports equality".into(),
                ));
            }
            let value = filter.value.as_scalar()?.trim().to_lowercase();
            latest_only = parse_bool(&value).ok_or_else(|| {
                ServiceError::InvalidRequest("latest filter expects boolean true/false".into())
            })?;
        } else {
            remaining.push(filter.clone());
        }
    }

    Ok((latest_only, remaining))
}

fn build_filter_clause(
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    match filter.field.as_str() {
        "device_id" => build_text_clause("di.device_id", filter, binds, bind_idx),
        "device_ip" | "ip" => build_text_clause("di.device_ip", filter, binds, bind_idx),
        "gateway_id" => build_text_clause("di.gateway_id", filter, binds, bind_idx),
        "agent_id" => build_text_clause("di.agent_id", filter, binds, bind_idx),
        "interface_uid" => build_text_clause("di.interface_uid", filter, binds, bind_idx),
        "if_name" => build_text_clause("di.if_name", filter, binds, bind_idx),
        "if_descr" | "description" => build_text_clause("di.if_descr", filter, binds, bind_idx),
        "if_alias" => build_text_clause("di.if_alias", filter, binds, bind_idx),
        "if_type_name" => build_text_clause("di.if_type_name", filter, binds, bind_idx),
        "interface_kind" => build_text_clause("di.interface_kind", filter, binds, bind_idx),
        "duplex" => build_text_clause("di.duplex", filter, binds, bind_idx),
        "if_phys_address" | "mac" => build_mac_clause(filter, binds, bind_idx),
        "if_index" => build_int_clause("di.if_index", filter, binds, bind_idx),
        "if_type" => build_int_clause("di.if_type", filter, binds, bind_idx),
        "if_admin_status" | "admin_status" => {
            build_int_clause("di.if_admin_status", filter, binds, bind_idx)
        }
        "if_oper_status" | "oper_status" | "status" => {
            build_int_clause("di.if_oper_status", filter, binds, bind_idx)
        }
        "if_speed" | "speed" | "speed_bps" => build_int_clause(
            "COALESCE(di.speed_bps, di.if_speed)",
            filter,
            binds,
            bind_idx,
        ),
        "mtu" => build_int_clause("di.mtu", filter, binds, bind_idx),
        "ip_addresses" | "ip_address" => build_ip_addresses_clause(filter, binds, bind_idx),
        // Boolean filters from interface_settings (via LEFT JOIN)
        "favorited" => build_bool_clause("COALESCE(ifs.favorited, false)", filter, binds, bind_idx),
        "metrics_enabled" => build_bool_clause(
            "COALESCE(ifs.metrics_enabled, false)",
            filter,
            binds,
            bind_idx,
        ),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn build_text_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    match filter.op {
        FilterOp::Eq => {
            let value = filter.value.as_scalar()?.to_string();
            let clause = format!("{column} = ${bind_idx}");
            binds.push(BindParam::Text(value));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();
            let clause = format!("{column} != ${bind_idx}");
            binds.push(BindParam::Text(value));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::Like => {
            let value = filter.value.as_scalar()?.to_string();
            let clause = format!("{column} ILIKE ${bind_idx}");
            binds.push(BindParam::Text(value));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::NotLike => {
            let value = filter.value.as_scalar()?.to_string();
            let clause = format!("{column} NOT ILIKE ${bind_idx}");
            binds.push(BindParam::Text(value));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(None);
            }
            let clause = format!("{column} = ANY(${bind_idx})");
            binds.push(BindParam::TextArray(values));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(None);
            }
            let clause = format!("NOT ({column} = ANY(${bind_idx}))");
            binds.push(BindParam::TextArray(values));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn build_mac_clause(
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    let column = "lower(regexp_replace(di.if_phys_address, '[^0-9a-fA-F]', '', 'g'))";

    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            let raw = filter.value.as_scalar()?;
            let allow_wildcards = matches!(filter.op, FilterOp::Like | FilterOp::NotLike);
            let normalized = normalize_mac_value(raw, allow_wildcards)?;

            let clause = match filter.op {
                FilterOp::Eq => format!("{column} = ${bind_idx}"),
                FilterOp::NotEq => format!("{column} != ${bind_idx}"),
                FilterOp::Like => format!("{column} LIKE ${bind_idx}"),
                FilterOp::NotLike => format!("{column} NOT LIKE ${bind_idx}"),
                _ => unreachable!("filtered above"),
            };

            binds.push(BindParam::Text(normalized));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter
                .value
                .as_list()?
                .iter()
                .map(|value| normalize_mac_value(value, false))
                .collect::<Result<Vec<_>>>()?;

            if values.is_empty() {
                return Ok(None);
            }

            let clause = match filter.op {
                FilterOp::In => format!("{column} = ANY(${bind_idx})"),
                FilterOp::NotIn => format!("NOT ({column} = ANY(${bind_idx}))"),
                _ => unreachable!("filtered above"),
            };

            binds.push(BindParam::TextArray(values));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for mac filter: {:?}",
            filter.op
        ))),
    }
}

fn normalize_mac_value(raw: &str, allow_wildcards: bool) -> Result<String> {
    let mut normalized = String::with_capacity(raw.len());

    for ch in raw.chars() {
        if ch.is_ascii_hexdigit() {
            normalized.push(ch.to_ascii_lowercase());
        } else if allow_wildcards && (ch == '%' || ch == '_') {
            normalized.push(ch);
        }
    }

    if normalized.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "mac filter expects hex digits".into(),
        ));
    }

    Ok(normalized)
}

fn build_int_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    let value = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => parse_i64(filter.value.as_scalar()?)?,
        _ => {
            return Err(ServiceError::InvalidRequest(
                "numeric filters only support equality".into(),
            ))
        }
    };

    let clause = match filter.op {
        FilterOp::Eq => format!("{column} = ${bind_idx}"),
        FilterOp::NotEq => format!("{column} != ${bind_idx}"),
        _ => unreachable!("validated above"),
    };

    binds.push(BindParam::Int(value));
    *bind_idx += 1;
    Ok(Some(clause))
}

fn build_bool_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    let value = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let raw = filter.value.as_scalar()?.trim().to_lowercase();
            parse_bool(&raw).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "boolean filter expects true/false, got '{raw}'"
                ))
            })?
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "boolean filters only support equality".into(),
            ))
        }
    };

    let clause = match filter.op {
        FilterOp::Eq => format!("{column} = ${bind_idx}"),
        FilterOp::NotEq => format!("{column} != ${bind_idx}"),
        _ => unreachable!("validated above"),
    };

    binds.push(BindParam::Bool(value));
    *bind_idx += 1;
    Ok(Some(clause))
}

fn build_ip_addresses_clause(
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    let values: Vec<String> = match &filter.value {
        FilterValue::Scalar(value) => vec![value.to_string()],
        FilterValue::List(list) => list.clone(),
    };

    if values.is_empty() {
        return Ok(None);
    }
    if values.len() > MAX_IP_ADDRESS_FILTER_VALUES {
        return Err(ServiceError::InvalidRequest(format!(
            "ip_addresses filter supports at most {MAX_IP_ADDRESS_FILTER_VALUES} values"
        )));
    }

    match filter.op {
        FilterOp::Eq | FilterOp::In => {
            let clause = format!("coalesce(di.ip_addresses, ARRAY[]::text[]) @> ${bind_idx}");
            binds.push(BindParam::TextArray(values));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::NotEq | FilterOp::NotIn => {
            let clause = format!("NOT (coalesce(di.ip_addresses, ARRAY[]::text[]) @> ${bind_idx})");
            binds.push(BindParam::TextArray(values));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::Like | FilterOp::NotLike => Err(ServiceError::InvalidRequest(
            "ip_addresses filter does not support pattern matching".into(),
        )),
        _ => Err(ServiceError::InvalidRequest(format!(
            "ip_addresses filter does not support operator {:?}",
            filter.op
        ))),
    }
}

fn build_order_clause(order: &[OrderClause]) -> Option<String> {
    let mut clauses = Vec::new();

    for clause in order {
        let column = match clause.field.as_str() {
            "timestamp" => "timestamp",
            "device_ip" => "device_ip",
            "device_id" => "device_id",
            "interface_uid" => "interface_uid",
            "if_name" => "if_name",
            "if_descr" => "if_descr",
            "if_index" => "if_index",
            "if_type" => "if_type",
            "if_type_name" => "if_type_name",
            "interface_kind" => "interface_kind",
            "speed_bps" | "if_speed" | "speed" => "speed_bps",
            "mtu" => "mtu",
            _ => continue,
        };

        let direction = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };

        clauses.push(format!("{column} {direction}"));
    }

    if clauses.is_empty() {
        Some("ORDER BY timestamp DESC, created_at DESC".to_string())
    } else {
        Some(format!("ORDER BY {}", clauses.join(", ")))
    }
}

fn bind_param<'a>(
    query: BoxedSqlQuery<'a, Pg, SqlQuery>,
    param: BindParam,
) -> Result<BoxedSqlQuery<'a, Pg, SqlQuery>> {
    match param {
        BindParam::Text(value) => Ok(query.bind::<Text, _>(value)),
        BindParam::TextArray(values) => Ok(query.bind::<Array<Text>, _>(values)),
        BindParam::IntArray(values) => Ok(query.bind::<Array<BigInt>, _>(values)),
        BindParam::Int(value) => Ok(query.bind::<BigInt, _>(value)),
        BindParam::Bool(value) => Ok(query.bind::<Bool, _>(value)),
        BindParam::Float(value) => Ok(query.bind::<diesel::sql_types::Float8, _>(value)),
        BindParam::Timestamptz(value) => {
            let timestamp = chrono::DateTime::parse_from_rfc3339(&value)
                .map(|dt| dt.with_timezone(&chrono::Utc))
                .map_err(|err| {
                    ServiceError::Internal(anyhow::anyhow!(
                        "invalid timestamptz bind {value:?}: {err}"
                    ))
                })?;
            Ok(query.bind::<Timestamptz, _>(timestamp))
        }
        BindParam::Uuid(value) => Ok(query.bind::<diesel::sql_types::Uuid, _>(value)),
    }
}

#[derive(Debug, Clone)]
struct CountStatsSpec {
    alias: String,
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

fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("expected integer value for '{raw}'")))
}

fn parse_bool(input: &str) -> Option<bool> {
    if input.is_empty() {
        return None;
    }
    input.parse::<bool>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn stats_count_interfaces_emits_count_query() {
        let plan = stats_plan("count() as interface_count");
        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
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

    #[test]
    fn interfaces_query_includes_error_metric_joins() {
        let plan = QueryPlan {
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
            limit: 10,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let (sql, _) = to_sql_and_params(&plan).expect("interfaces SQL should be generated");
        let lower = sql.to_lowercase();
        assert!(
            lower.contains("timeseries_metrics"),
            "expected timeseries_metrics join, got: {sql}"
        );
        assert!(
            lower.contains("ifinerrors"),
            "expected ifInErrors join, got: {sql}"
        );
        assert!(
            lower.contains("ifouterrors"),
            "expected ifOutErrors join, got: {sql}"
        );
    }

    #[test]
    fn interfaces_mac_filter_normalizes_exact_match() {
        let plan = base_plan_with_filter(Filter {
            field: "mac".into(),
            value: FilterValue::Scalar("0E-EA-14-32-D2-78".into()),
            op: FilterOp::Eq,
        });

        let (sql, binds) = to_sql_and_params(&plan).expect("mac SQL should be generated");
        assert!(
            sql.contains("regexp_replace"),
            "expected mac normalization in SQL, got: {sql}"
        );

        match binds.as_slice().first() {
            Some(BindParam::Text(value)) => assert_eq!(value, "0eea1432d278"),
            other => panic!("unexpected binds: {other:?}"),
        }
    }

    #[test]
    fn interfaces_mac_filter_preserves_wildcards() {
        let plan = base_plan_with_filter(Filter {
            field: "mac".into(),
            value: FilterValue::Scalar("%0e:ea:14:32:d2:78%".into()),
            op: FilterOp::Like,
        });

        let (sql, binds) = to_sql_and_params(&plan).expect("mac LIKE SQL should be generated");
        assert!(
            sql.to_lowercase().contains("like"),
            "expected LIKE clause for mac filter, got: {sql}"
        );

        match binds.as_slice().first() {
            Some(BindParam::Text(value)) => assert_eq!(value, "%0eea1432d278%"),
            other => panic!("unexpected binds: {other:?}"),
        }
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
            stats: Some(crate::parser::StatsSpec::from_raw(stats)),
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        }
    }

    fn base_plan_with_filter(filter: Filter) -> QueryPlan {
        QueryPlan {
            entity: Entity::Interfaces,
            filters: vec![filter],
            order: vec![],
            limit: 25,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        }
    }
}
