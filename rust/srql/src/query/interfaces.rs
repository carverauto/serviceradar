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
use diesel::sql_types::{Array, BigInt, Bool, Int4, Jsonb, Nullable, Text, Timestamptz};
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
    #[diesel(sql_type = Nullable<Int4>)]
    if_index: Option<i32>,
    #[diesel(sql_type = Nullable<Text>)]
    if_name: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    if_descr: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    if_alias: Option<String>,
    #[diesel(sql_type = Nullable<BigInt>)]
    if_speed: Option<i64>,
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
    #[diesel(sql_type = Timestamptz)]
    created_at: DateTime<Utc>,
}

impl InterfaceRow {
    fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "timestamp": self.timestamp,
            "agent_id": self.agent_id,
            "gateway_id": self.gateway_id,
            "device_ip": self.device_ip,
            "uid": self.device_id,
            "if_index": self.if_index,
            "if_name": self.if_name,
            "if_descr": self.if_descr,
            "if_alias": self.if_alias,
            "if_speed": self.if_speed,
            "if_phys_address": self.if_phys_address,
            "ip_addresses": self.ip_addresses.unwrap_or_default(),
            "if_admin_status": self.if_admin_status,
            "if_oper_status": self.if_oper_status,
            "metadata": self.metadata.unwrap_or(serde_json::json!({})),
            "created_at": self.created_at,
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
    let select = r#"
SELECT
    d.modified_time AS timestamp,
    d.agent_id AS agent_id,
    d.gateway_id AS gateway_id,
    d.ip AS device_ip,
    d.uid AS device_id,
    CASE
        WHEN (iface->>'uid') ~ '^[0-9]+$' THEN (iface->>'uid')::int
        ELSE NULL
    END AS if_index,
    iface->>'name' AS if_name,
    iface->>'descr' AS if_descr,
    iface->>'alias' AS if_alias,
    NULLIF(iface->>'speed', '')::bigint AS if_speed,
    iface->>'mac' AS if_phys_address,
    CASE
        WHEN jsonb_typeof(iface->'ip_addresses') = 'array' THEN
            ARRAY(SELECT jsonb_array_elements_text(iface->'ip_addresses'))
        WHEN iface ? 'ip' AND (iface->>'ip') <> '' THEN ARRAY[iface->>'ip']
        ELSE ARRAY[]::text[]
    END AS ip_addresses,
    NULLIF(iface->>'admin_status', '')::int AS if_admin_status,
    NULLIF(iface->>'oper_status', '')::int AS if_oper_status,
    iface AS metadata,
    d.created_time AS created_at
FROM ocsf_devices d
JOIN LATERAL jsonb_array_elements(COALESCE(to_jsonb(d.network_interfaces), '[]'::jsonb)) AS iface ON TRUE
"#;

    let mut sql = select.trim().to_string();
    let mut binds = Vec::new();
    let mut clauses = Vec::new();
    let mut bind_idx = 1;

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(format!(
            "d.modified_time >= ${} AND d.modified_time <= ${}",
            bind_idx,
            bind_idx + 1
        ));
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
        bind_idx += 2;
    }

    for filter in &plan.filters {
        if let Some(clause) = build_filter_clause(filter, &mut binds, &mut bind_idx)? {
            clauses.push(clause);
        }
    }

    if !clauses.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    if let Some(order_clause) = build_order_clause(&plan.order) {
        sql.push(' ');
        sql.push_str(&order_clause);
    }

    sql.push_str(&format!(" LIMIT ${} OFFSET ${}", bind_idx, bind_idx + 1));
    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    Ok(SqlBuildResult { sql, binds })
}

fn build_stats_sql(plan: &QueryPlan, spec: &CountStatsSpec) -> Result<SqlBuildResult> {
    let mut sql = format!(
        "SELECT jsonb_build_object('{}', COALESCE(COUNT(*), 0)::bigint) AS payload FROM ocsf_devices d JOIN LATERAL jsonb_array_elements(COALESCE(to_jsonb(d.network_interfaces), '[]'::jsonb)) AS iface ON TRUE",
        spec.alias
    );

    let mut binds = Vec::new();
    let mut clauses = Vec::new();
    let mut bind_idx = 1;

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(format!(
            "d.modified_time >= ${} AND d.modified_time <= ${}",
            bind_idx,
            bind_idx + 1
        ));
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
        bind_idx += 2;
    }

    for filter in &plan.filters {
        if let Some(clause) = build_filter_clause(filter, &mut binds, &mut bind_idx)? {
            clauses.push(clause);
        }
    }

    if !clauses.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    Ok(SqlBuildResult { sql, binds })
}

fn build_filter_clause(
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    match filter.field.as_str() {
        "device_id" => build_text_clause("d.uid", filter, binds, bind_idx),
        "device_ip" | "ip" => build_text_clause("d.ip", filter, binds, bind_idx),
        "gateway_id" => build_text_clause("d.gateway_id", filter, binds, bind_idx),
        "agent_id" => build_text_clause("d.agent_id", filter, binds, bind_idx),
        "if_name" => build_text_clause("iface->>'name'", filter, binds, bind_idx),
        "if_descr" | "description" => build_text_clause("iface->>'descr'", filter, binds, bind_idx),
        "if_alias" => build_text_clause("iface->>'alias'", filter, binds, bind_idx),
        "if_phys_address" | "mac" => build_text_clause("iface->>'mac'", filter, binds, bind_idx),
        "if_admin_status" => build_int_clause(
            "NULLIF(iface->>'admin_status', '')::int",
            filter,
            binds,
            bind_idx,
        ),
        "if_oper_status" | "status" => build_int_clause(
            "NULLIF(iface->>'oper_status', '')::int",
            filter,
            binds,
            bind_idx,
        ),
        "if_speed" | "speed" => build_int_clause(
            "NULLIF(iface->>'speed', '')::bigint",
            filter,
            binds,
            bind_idx,
        ),
        "ip_addresses" | "ip_address" => build_ip_addresses_clause(filter, binds, bind_idx),
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

fn build_ip_addresses_clause(
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    match filter.op {
        FilterOp::Eq => {
            let value = filter.value.as_scalar()?.to_string();
            let clause = format!(
                "(iface->>'ip' = ${bind_idx} OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(iface->'ip_addresses', '[]'::jsonb)) AS addr WHERE addr = ${bind_idx}))"
            );
            binds.push(BindParam::Text(value));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();
            let clause = format!(
                "(iface->>'ip' != ${bind_idx} AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(iface->'ip_addresses', '[]'::jsonb)) AS addr WHERE addr = ${bind_idx}))"
            );
            binds.push(BindParam::Text(value));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::In | FilterOp::NotIn => {
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
            let clause = match filter.op {
                FilterOp::In => format!(
                    "(iface->>'ip' = ANY(${bind_idx}) OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(iface->'ip_addresses', '[]'::jsonb)) AS addr WHERE addr = ANY(${bind_idx})))"
                ),
                FilterOp::NotIn => format!(
                    "(NOT (iface->>'ip' = ANY(${bind_idx})) AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(iface->'ip_addresses', '[]'::jsonb)) AS addr WHERE addr = ANY(${bind_idx})))"
                ),
                _ => unreachable!("validated above"),
            };
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
            "if_name" => "if_name",
            "if_descr" => "if_descr",
            "if_index" => "if_index",
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
        }
    }
}
