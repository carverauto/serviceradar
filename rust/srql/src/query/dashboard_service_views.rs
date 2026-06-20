use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, BigInt, Bool, Jsonb, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let built = build_query(plan)?;
    let query = built.to_boxed_query();

    let rows: Vec<JsonPayload> = query
        .load::<JsonPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(|row| row.payload.into()).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let built = build_query(plan)?;

    Ok((
        rewrite_placeholders(&built.sql),
        built
            .binds
            .into_iter()
            .map(BindValue::into_bind_param)
            .collect(),
    ))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::ServiceAvailability | Entity::MonitoredServices | Entity::SloEvaluations => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by dashboard service views query".into(),
        )),
    }
}

#[derive(Debug, Clone)]
struct BuiltSql {
    sql: String,
    binds: Vec<BindValue>,
}

impl BuiltSql {
    fn to_boxed_query(&self) -> BoxedSqlQuery<'_, Pg, SqlQuery> {
        let mut query = sql_query(rewrite_placeholders(&self.sql)).into_boxed::<Pg>();

        for bind in &self.binds {
            query = bind.bind(query);
        }

        query
    }
}

#[derive(Debug, Clone)]
enum BindValue {
    Bool(bool),
    Int(i64),
    Text(String),
    TextArray(Vec<String>),
    Timestamp(DateTime<Utc>),
}

type FilterClause = (String, Vec<BindValue>);
type FilterClauseFn = fn(&Filter) -> Result<FilterClause>;

impl BindValue {
    fn bind<'a>(&self, query: BoxedSqlQuery<'a, Pg, SqlQuery>) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            Self::Bool(value) => query.bind::<Bool, _>(*value),
            Self::Int(value) => query.bind::<BigInt, _>(*value),
            Self::Text(value) => query.bind::<Text, _>(value.clone()),
            Self::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            Self::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }

    fn into_bind_param(self) -> BindParam {
        match self {
            Self::Bool(value) => BindParam::Bool(value),
            Self::Int(value) => BindParam::Int(value),
            Self::Text(value) => BindParam::Text(value),
            Self::TextArray(values) => BindParam::TextArray(values),
            Self::Timestamp(value) => BindParam::timestamptz(value),
        }
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct JsonPayload {
    #[diesel(sql_type = Jsonb)]
    payload: DbJson,
}

fn build_query(plan: &QueryPlan) -> Result<BuiltSql> {
    match plan.entity {
        Entity::ServiceAvailability => build_service_availability_query(plan),
        Entity::MonitoredServices => build_monitored_services_query(plan),
        Entity::SloEvaluations => build_slo_evaluations_query(plan),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by dashboard service views query".into(),
        )),
    }
}

fn build_service_availability_query(plan: &QueryPlan) -> Result<BuiltSql> {
    if let Some(rollup) = plan.rollup_stats.as_deref() {
        if rollup != "availability" {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported rollup_stats type for service_availability: '{rollup}' (supported: availability)"
            )));
        }

        return build_service_availability_rollup(plan);
    }

    let mut binds = Vec::new();
    let base_where = base_time_where(plan, &mut binds);
    let mut sql = format!(
        r#"WITH ranked AS (
    SELECT
        ss.*,
        ROW_NUMBER() OVER (
            PARTITION BY ss.gateway_id, COALESCE(ss.agent_id, ''), ss.service_name, COALESCE(ss.service_type, ''), COALESCE(ss.partition, '')
            ORDER BY ss.timestamp DESC
        ) AS rn
    FROM platform.service_status ss
    WHERE {base_where}
),
latest AS (
    SELECT
        COALESCE(
            ranked.service_id::text,
            md5(concat_ws('|', ranked.gateway_id, COALESCE(ranked.agent_id, ''), ranked.service_name, COALESCE(ranked.service_type, ''), COALESCE(ranked.partition, '')))
        ) AS uid,
        ranked.service_name,
        concat_ws(':', ranked.gateway_id, COALESCE(ranked.agent_id, 'agentless'), ranked.service_name) AS service_key,
        COALESCE(ranked.service_type, 'service') AS service_kind,
        COALESCE(ranked.service_type, 'service') AS descriptor_id,
        CASE WHEN ranked.available THEN 'ok' ELSE 'critical' END AS status,
        ranked.available,
        COALESCE(
            NULLIF(substring(COALESCE(ranked.details, '') FROM '"response_time_ms"\s*:\s*([0-9]+)'), '')::bigint,
            NULLIF(substring(COALESCE(ranked.details, '') FROM '"latency_ms"\s*:\s*([0-9]+)'), '')::bigint,
            NULLIF(substring(COALESCE(ranked.message, '') FROM '([0-9]+)\s*ms'), '')::bigint
        ) AS response_time_ms,
        ranked.message AS summary,
        ranked.timestamp AS last_observed_at,
        ranked.gateway_id,
        ranked.agent_id,
        COALESCE(ranked.partition, 'default') AS partition
    FROM ranked
    WHERE ranked.rn = 1
)
SELECT jsonb_build_object(
    'uid', s.uid,
    'service_name', s.service_name,
    'name', s.service_name,
    'service_key', s.service_key,
    'service_kind', s.service_kind,
    'service_type', s.service_kind,
    'descriptor_id', s.descriptor_id,
    'status', s.status,
    'available', s.available,
    'response_time_ms', s.response_time_ms,
    'summary', s.summary,
    'message', s.summary,
    'last_observed_at', s.last_observed_at,
    'timestamp', s.last_observed_at,
    'gateway_id', s.gateway_id,
    'agent_id', s.agent_id,
    'partition', s.partition
) AS payload
FROM latest s"#,
    );

    append_where_filters(&mut sql, &mut binds, plan, availability_filter_clause)?;
    append_order_limit_offset(
        &mut sql,
        &mut binds,
        plan,
        availability_order_column,
        "s.last_observed_at DESC",
    )?;

    Ok(BuiltSql { sql, binds })
}

fn build_service_availability_rollup(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut binds = Vec::new();
    let base_where = base_time_where(plan, &mut binds);
    let mut sql = format!(
        r#"WITH ranked AS (
    SELECT
        ss.*,
        ROW_NUMBER() OVER (
            PARTITION BY ss.gateway_id, COALESCE(ss.agent_id, ''), ss.service_name, COALESCE(ss.service_type, ''), COALESCE(ss.partition, '')
            ORDER BY ss.timestamp DESC
        ) AS rn
    FROM platform.service_status ss
    WHERE {base_where}
),
latest AS (
    SELECT
        COALESCE(
            ranked.service_id::text,
            md5(concat_ws('|', ranked.gateway_id, COALESCE(ranked.agent_id, ''), ranked.service_name, COALESCE(ranked.service_type, ''), COALESCE(ranked.partition, '')))
        ) AS uid,
        ranked.service_name,
        concat_ws(':', ranked.gateway_id, COALESCE(ranked.agent_id, 'agentless'), ranked.service_name) AS service_key,
        COALESCE(ranked.service_type, 'service') AS service_kind,
        CASE WHEN ranked.available THEN 'ok' ELSE 'critical' END AS status,
        ranked.available,
        ranked.gateway_id,
        ranked.agent_id,
        COALESCE(ranked.partition, 'default') AS partition
    FROM ranked
    WHERE ranked.rn = 1
)
SELECT jsonb_build_object(
    'total', COUNT(*)::bigint,
    'ok', COUNT(*) FILTER (WHERE s.status = 'ok')::bigint,
    'warning', COUNT(*) FILTER (WHERE s.status = 'warning')::bigint,
    'critical', COUNT(*) FILTER (WHERE s.status = 'critical')::bigint,
    'unknown', COUNT(*) FILTER (WHERE s.status = 'unknown')::bigint,
    'available', COUNT(*) FILTER (WHERE s.available)::bigint,
    'unavailable', COUNT(*) FILTER (WHERE NOT s.available)::bigint,
    'availability_pct', CASE
        WHEN COUNT(*) = 0 THEN 0.0
        ELSE (COUNT(*) FILTER (WHERE s.available))::float / COUNT(*)::float * 100.0
    END
) AS payload
FROM latest s"#,
    );

    append_where_filters(&mut sql, &mut binds, plan, availability_filter_clause)?;

    Ok(BuiltSql { sql, binds })
}

fn build_monitored_services_query(plan: &QueryPlan) -> Result<BuiltSql> {
    if let Some(rollup) = plan.rollup_stats.as_deref() {
        return Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for monitored_services: '{rollup}'"
        )));
    }

    let mut binds = Vec::new();
    let base_where = base_time_where(plan, &mut binds);
    let mut sql = format!(
        r#"WITH ranked AS (
    SELECT
        ss.*,
        ROW_NUMBER() OVER (
            PARTITION BY ss.gateway_id, COALESCE(ss.agent_id, ''), ss.service_name, COALESCE(ss.service_type, ''), COALESCE(ss.partition, '')
            ORDER BY ss.timestamp DESC
        ) AS rn
    FROM platform.service_status ss
    WHERE {base_where}
),
inventory AS (
    SELECT
        COALESCE(
            ranked.service_id::text,
            md5(concat_ws('|', ranked.gateway_id, COALESCE(ranked.agent_id, ''), ranked.service_name, COALESCE(ranked.service_type, ''), COALESCE(ranked.partition, '')))
        ) AS uid,
        ranked.service_name AS display_name,
        concat_ws(':', ranked.gateway_id, COALESCE(ranked.agent_id, 'agentless'), ranked.service_name) AS service_key,
        COALESCE(ranked.service_type, 'service') AS service_kind,
        lower(NULLIF(substring(ranked.service_name FROM '^([a-zA-Z][a-zA-Z0-9+.-]*)://'), '')) AS protocol,
        NULLIF(substring(ranked.service_name FROM '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:]+)'), '') AS host,
        NULLIF(substring(ranked.service_name FROM '^[a-zA-Z][a-zA-Z0-9+.-]*://[^/:]+:([0-9]+)'), '')::integer AS port,
        CASE WHEN ranked.available THEN 'ok' ELSE 'critical' END AS status,
        ranked.available,
        ranked.timestamp AS last_observed_at,
        ranked.gateway_id,
        ranked.agent_id,
        COALESCE(ranked.partition, 'default') AS partition
    FROM ranked
    WHERE ranked.rn = 1
)
SELECT jsonb_build_object(
    'uid', s.uid,
    'display_name', s.display_name,
    'service_name', s.display_name,
    'service_key', s.service_key,
    'service_kind', s.service_kind,
    'service_type', s.service_kind,
    'protocol', s.protocol,
    'host', s.host,
    'port', s.port,
    'status', s.status,
    'available', s.available,
    'last_observed_at', s.last_observed_at,
    'timestamp', s.last_observed_at,
    'gateway_id', s.gateway_id,
    'agent_id', s.agent_id,
    'partition', s.partition
) AS payload
FROM inventory s"#,
    );

    append_where_filters(&mut sql, &mut binds, plan, monitored_filter_clause)?;
    append_order_limit_offset(
        &mut sql,
        &mut binds,
        plan,
        monitored_order_column,
        "s.display_name ASC",
    )?;

    Ok(BuiltSql { sql, binds })
}

fn build_slo_evaluations_query(plan: &QueryPlan) -> Result<BuiltSql> {
    match plan.rollup_stats.as_deref() {
        Some("slo_error_budget") => build_slo_error_budget_rollup(plan),
        Some(other) => Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for slo_evaluations: '{other}' (supported: slo_error_budget)"
        ))),
        None => build_slo_rows(plan),
    }
}

fn build_slo_rows(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut binds = Vec::new();
    let mut sql = slo_cte(plan, &mut binds);
    sql.push_str(
        r#"
SELECT jsonb_build_object(
    'uid', e.uid,
    'slo_key', e.slo_key,
    'slo_name', e.slo_name,
    'owner', e.owner,
    'compliance_state', e.compliance_state,
    'severity', e.severity,
    'budget_remaining_basis_points', e.budget_remaining_basis_points,
    'burn_rate_short', e.burn_rate_short,
    'projected_exhaustion_at', e.projected_exhaustion_at,
    'evaluated_at', e.evaluated_at,
    'service_key', e.service_key,
    'service_kind', e.service_kind,
    'partition', e.partition
) AS payload
FROM evaluations e"#,
    );

    append_where_filters(&mut sql, &mut binds, plan, slo_filter_clause)?;
    append_order_limit_offset(
        &mut sql,
        &mut binds,
        plan,
        slo_order_column,
        "e.evaluated_at DESC",
    )?;

    Ok(BuiltSql { sql, binds })
}

fn build_slo_error_budget_rollup(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut binds = Vec::new();
    let mut sql = slo_cte(plan, &mut binds);
    sql.push_str(
        r#"
SELECT jsonb_build_object(
    'total', COUNT(*)::bigint,
    'critical', COUNT(*) FILTER (WHERE e.severity = 'critical')::bigint,
    'warning', COUNT(*) FILTER (WHERE e.severity = 'warning')::bigint,
    'ok', COUNT(*) FILTER (WHERE e.severity = 'ok')::bigint,
    'error_budget_remaining', COALESCE(MIN(e.budget_remaining_basis_points), 0)::bigint,
    'avg_budget_remaining_basis_points', COALESCE(ROUND(AVG(e.budget_remaining_basis_points)), 0)::bigint,
    'max_burn_rate_short', COALESCE(MAX(e.burn_rate_short), 0.0),
    'next_projected_exhaustion_at', MIN(e.projected_exhaustion_at)
) AS payload
FROM evaluations e"#,
    );

    append_where_filters(&mut sql, &mut binds, plan, slo_filter_clause)?;

    Ok(BuiltSql { sql, binds })
}

fn slo_cte(plan: &QueryPlan, binds: &mut Vec<BindValue>) -> String {
    let base_where = base_time_where(plan, binds);

    format!(
        r#"WITH service_windows AS (
    SELECT
        ss.gateway_id,
        ss.agent_id,
        ss.service_name,
        COALESCE(ss.service_type, 'service') AS service_kind,
        COALESCE(ss.partition, 'default') AS partition,
        concat_ws(':', ss.gateway_id, COALESCE(ss.agent_id, 'agentless'), ss.service_name) AS service_key,
        COUNT(*)::bigint AS sample_count,
        COUNT(*) FILTER (WHERE ss.available)::bigint AS available_count,
        MAX(ss.timestamp) AS evaluated_at
    FROM platform.service_status ss
    WHERE {base_where}
    GROUP BY ss.gateway_id, ss.agent_id, ss.service_name, COALESCE(ss.service_type, 'service'), COALESCE(ss.partition, 'default')
),
availability AS (
    SELECT
        w.*,
        CASE
            WHEN w.sample_count = 0 THEN 0.0
            ELSE w.available_count::float / w.sample_count::float * 100.0
        END AS availability_pct
    FROM service_windows w
),
evaluations AS (
    SELECT
        md5(a.service_key || '|availability-99') AS uid,
        a.service_key || ':availability_99' AS slo_key,
        a.service_name || ' availability' AS slo_name,
        'operations' AS owner,
        CASE
            WHEN ROUND(((a.availability_pct - 99.0) * 100.0)::numeric)::bigint < 0 THEN 'noncompliant'
            WHEN ROUND(((a.availability_pct - 99.0) * 100.0)::numeric)::bigint < 25 THEN 'at_risk'
            ELSE 'compliant'
        END AS compliance_state,
        CASE
            WHEN ROUND(((a.availability_pct - 99.0) * 100.0)::numeric)::bigint < 0 THEN 'critical'
            WHEN ROUND(((a.availability_pct - 99.0) * 100.0)::numeric)::bigint < 25 THEN 'warning'
            ELSE 'ok'
        END AS severity,
        ROUND(((a.availability_pct - 99.0) * 100.0)::numeric)::bigint AS budget_remaining_basis_points,
        GREATEST((100.0 - a.availability_pct) / 1.0, 0.0) AS burn_rate_short,
        NULL::timestamptz AS projected_exhaustion_at,
        a.evaluated_at,
        a.service_key,
        a.service_kind,
        a.partition
    FROM availability a
)"#
    )
}

fn base_time_where(plan: &QueryPlan, binds: &mut Vec<BindValue>) -> String {
    if let Some(TimeRange { start, end }) = &plan.time_range {
        binds.push(BindValue::Timestamp(*start));
        binds.push(BindValue::Timestamp(*end));
        "ss.timestamp >= ? AND ss.timestamp <= ?".to_string()
    } else {
        "ss.timestamp >= now() - interval '24 hours'".to_string()
    }
}

fn append_where_filters(
    sql: &mut String,
    binds: &mut Vec<BindValue>,
    plan: &QueryPlan,
    filter_fn: FilterClauseFn,
) -> Result<()> {
    if plan.filters.is_empty() {
        return Ok(());
    }

    let mut clauses = Vec::with_capacity(plan.filters.len());
    for filter in &plan.filters {
        let (clause, mut filter_binds) = filter_fn(filter)?;
        clauses.push(clause);
        binds.append(&mut filter_binds);
    }

    sql.push_str("\nWHERE ");
    sql.push_str(&clauses.join(" AND "));
    Ok(())
}

fn append_order_limit_offset(
    sql: &mut String,
    binds: &mut Vec<BindValue>,
    plan: &QueryPlan,
    order_fn: fn(&str) -> Option<&'static str>,
    default_order: &str,
) -> Result<()> {
    sql.push('\n');
    sql.push_str(&order_clause(&plan.order, order_fn, default_order)?);
    sql.push_str("\nLIMIT ? OFFSET ?");
    binds.push(BindValue::Int(plan.limit));
    binds.push(BindValue::Int(plan.offset));
    Ok(())
}

fn availability_filter_clause(filter: &Filter) -> Result<FilterClause> {
    match filter.field.as_str() {
        "uid" => text_filter("s.uid", filter),
        "service_name" | "name" | "display_name" => text_filter("s.service_name", filter),
        "service_key" => text_filter("s.service_key", filter),
        "service_kind" | "service_type" | "type" => text_filter("s.service_kind", filter),
        "descriptor_id" => text_filter("s.descriptor_id", filter),
        "status" => text_filter("s.status", filter),
        "summary" | "message" => text_filter("COALESCE(s.summary, '')", filter),
        "gateway_id" => text_filter("s.gateway_id", filter),
        "agent_id" => nullable_text_filter("s.agent_id", filter),
        "partition" => text_filter("s.partition", filter),
        "available" => bool_filter("s.available", filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for service_availability: '{other}'"
        ))),
    }
}

fn monitored_filter_clause(filter: &Filter) -> Result<FilterClause> {
    match filter.field.as_str() {
        "uid" => text_filter("s.uid", filter),
        "display_name" | "service_name" | "name" => text_filter("s.display_name", filter),
        "service_key" => text_filter("s.service_key", filter),
        "service_kind" | "service_type" | "type" => text_filter("s.service_kind", filter),
        "protocol" => nullable_text_filter("s.protocol", filter),
        "host" => nullable_text_filter("s.host", filter),
        "status" => text_filter("s.status", filter),
        "gateway_id" => text_filter("s.gateway_id", filter),
        "agent_id" => nullable_text_filter("s.agent_id", filter),
        "partition" => text_filter("s.partition", filter),
        "available" => bool_filter("s.available", filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for monitored_services: '{other}'"
        ))),
    }
}

fn slo_filter_clause(filter: &Filter) -> Result<FilterClause> {
    match filter.field.as_str() {
        "uid" => text_filter("e.uid", filter),
        "slo_key" => text_filter("e.slo_key", filter),
        "slo_name" | "name" => text_filter("e.slo_name", filter),
        "owner" => text_filter("e.owner", filter),
        "compliance_state" => text_filter("e.compliance_state", filter),
        "severity" | "status" => text_filter("e.severity", filter),
        "service_key" => text_filter("e.service_key", filter),
        "service_kind" | "service_type" | "type" => text_filter("e.service_kind", filter),
        "partition" => text_filter("e.partition", filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for slo_evaluations: '{other}'"
        ))),
    }
}

fn text_filter(column: &str, filter: &Filter) -> Result<FilterClause> {
    match filter.op {
        FilterOp::Eq => Ok((format!("{column} = ?"), vec![text_scalar(filter)?])),
        FilterOp::NotEq => Ok((format!("{column} <> ?"), vec![text_scalar(filter)?])),
        FilterOp::Like => Ok((format!("{column} ILIKE ?"), vec![text_scalar(filter)?])),
        FilterOp::NotLike => Ok((format!("{column} NOT ILIKE ?"), vec![text_scalar(filter)?])),
        FilterOp::In => Ok((format!("{column} = ANY(?)"), vec![text_array(filter)?])),
        FilterOp::NotIn => Ok((format!("{column} <> ALL(?)"), vec![text_array(filter)?])),
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn nullable_text_filter(column: &str, filter: &Filter) -> Result<FilterClause> {
    text_filter(&format!("COALESCE({column}, '')"), filter)
}

fn bool_filter(column: &str, filter: &Filter) -> Result<FilterClause> {
    let value = parse_bool(filter.value.as_scalar()?)?;
    match filter.op {
        FilterOp::Eq => Ok((format!("{column} = ?"), vec![BindValue::Bool(value)])),
        FilterOp::NotEq => Ok((format!("{column} <> ?"), vec![BindValue::Bool(value)])),
        _ => Err(ServiceError::InvalidRequest(format!(
            "{} filter only supports equality comparisons",
            filter.field
        ))),
    }
}

fn text_scalar(filter: &Filter) -> Result<BindValue> {
    Ok(BindValue::Text(filter.value.as_scalar()?.to_string()))
}

fn text_array(filter: &Filter) -> Result<BindValue> {
    Ok(BindValue::TextArray(filter.value.as_list()?.to_vec()))
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_lowercase().as_str() {
        "true" | "1" | "yes" | "y" | "available" | "ok" => Ok(true),
        "false" | "0" | "no" | "n" | "unavailable" | "critical" => Ok(false),
        other => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{other}'"
        ))),
    }
}

fn order_clause(
    order: &[OrderClause],
    order_fn: fn(&str) -> Option<&'static str>,
    default_order: &str,
) -> Result<String> {
    if order.is_empty() {
        return Ok(format!("ORDER BY {default_order}"));
    }

    let mut pieces = Vec::with_capacity(order.len());
    for clause in order {
        let column = order_fn(&clause.field).ok_or_else(|| {
            ServiceError::InvalidRequest(format!("unsupported sort field: '{}'", clause.field))
        })?;
        let direction = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        pieces.push(format!("{column} {direction}"));
    }

    Ok(format!("ORDER BY {}", pieces.join(", ")))
}

fn availability_order_column(field: &str) -> Option<&'static str> {
    match field {
        "uid" => Some("s.uid"),
        "service_name" | "name" | "display_name" => Some("s.service_name"),
        "service_key" => Some("s.service_key"),
        "service_kind" | "service_type" | "type" => Some("s.service_kind"),
        "status" => Some("s.status"),
        "response_time_ms" | "latency" => Some("s.response_time_ms"),
        "last_observed_at" | "timestamp" | "observed_at" => Some("s.last_observed_at"),
        "gateway_id" => Some("s.gateway_id"),
        "agent_id" => Some("s.agent_id"),
        "partition" => Some("s.partition"),
        _ => None,
    }
}

fn monitored_order_column(field: &str) -> Option<&'static str> {
    match field {
        "uid" => Some("s.uid"),
        "display_name" | "service_name" | "name" => Some("s.display_name"),
        "service_key" => Some("s.service_key"),
        "service_kind" | "service_type" | "type" => Some("s.service_kind"),
        "protocol" => Some("s.protocol"),
        "host" => Some("s.host"),
        "status" => Some("s.status"),
        "last_observed_at" | "timestamp" | "observed_at" => Some("s.last_observed_at"),
        "gateway_id" => Some("s.gateway_id"),
        "agent_id" => Some("s.agent_id"),
        "partition" => Some("s.partition"),
        _ => None,
    }
}

fn slo_order_column(field: &str) -> Option<&'static str> {
    match field {
        "uid" => Some("e.uid"),
        "slo_key" => Some("e.slo_key"),
        "slo_name" | "name" => Some("e.slo_name"),
        "owner" => Some("e.owner"),
        "compliance_state" => Some("e.compliance_state"),
        "severity" | "status" => Some("e.severity"),
        "budget_remaining_basis_points" => Some("e.budget_remaining_basis_points"),
        "burn_rate_short" => Some("e.burn_rate_short"),
        "projected_exhaustion_at" => Some("e.projected_exhaustion_at"),
        "evaluated_at" | "timestamp" => Some("e.evaluated_at"),
        "service_key" => Some("e.service_key"),
        "service_kind" | "service_type" | "type" => Some("e.service_kind"),
        "partition" => Some("e.partition"),
        _ => None,
    }
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut idx = 0usize;
    let mut out = String::with_capacity(sql.len() + 8);

    for ch in sql.chars() {
        if ch == '?' {
            idx += 1;
            out.push('$');
            out.push_str(&idx.to_string());
        } else {
            out.push(ch);
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        parser::{FilterValue, StatsSpec},
        time::TimeRange,
    };
    use chrono::{Duration as ChronoDuration, TimeZone};

    fn plan(entity: Entity) -> QueryPlan {
        let start = Utc.with_ymd_and_hms(2026, 5, 21, 0, 0, 0).unwrap();
        QueryPlan {
            entity,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: Some(TimeRange {
                start,
                end: start + ChronoDuration::hours(1),
            }),
            stats: None::<StatsSpec>,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        }
    }

    #[test]
    fn service_availability_sql_projects_dashboard_fields() {
        let mut plan = plan(Entity::ServiceAvailability);
        plan.filters = vec![Filter {
            field: "status".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec!["critical".into(), "unknown".into(), "warning".into()]),
        }];
        plan.order = vec![OrderClause {
            field: "last_observed_at".into(),
            direction: OrderDirection::Desc,
        }];

        let (sql, params) = to_sql_and_params(&plan).unwrap();
        assert!(sql.contains("FROM platform.service_status ss"));
        assert!(sql.contains("'service_key', s.service_key"));
        assert!(sql.contains("s.status = ANY($3)"));
        assert!(sql.contains("ORDER BY s.last_observed_at DESC"));
        assert_eq!(params.len(), 5);
    }

    #[test]
    fn monitored_services_sql_projects_inventory_fields() {
        let mut plan = plan(Entity::MonitoredServices);
        plan.order = vec![OrderClause {
            field: "display_name".into(),
            direction: OrderDirection::Asc,
        }];

        let (sql, params) = to_sql_and_params(&plan).unwrap();
        assert!(sql.contains("'display_name', s.display_name"));
        assert!(sql.contains("'protocol', s.protocol"));
        assert!(sql.contains("ORDER BY s.display_name ASC"));
        assert_eq!(params.len(), 4);
    }

    #[test]
    fn slo_evaluations_sql_supports_severity_filters() {
        let mut plan = plan(Entity::SloEvaluations);
        plan.filters = vec![Filter {
            field: "severity".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec!["warning".into(), "critical".into()]),
        }];
        plan.order = vec![OrderClause {
            field: "evaluated_at".into(),
            direction: OrderDirection::Desc,
        }];

        let (sql, params) = to_sql_and_params(&plan).unwrap();
        assert!(sql.contains("WITH service_windows AS"));
        assert!(sql.contains("'budget_remaining_basis_points', e.budget_remaining_basis_points"));
        assert!(sql.contains("e.severity = ANY($3)"));
        assert!(sql.contains("ORDER BY e.evaluated_at DESC"));
        assert_eq!(params.len(), 5);
    }

    #[test]
    fn slo_error_budget_rollup_sql_projects_dashboard_kpis() {
        let mut plan = plan(Entity::SloEvaluations);
        plan.rollup_stats = Some("slo_error_budget".into());

        let (sql, params) = to_sql_and_params(&plan).unwrap();
        assert!(sql.contains("'avg_budget_remaining_basis_points'"));
        assert!(sql.contains("'max_burn_rate_short'"));
        assert!(!sql.contains("LIMIT"));
        assert_eq!(params.len(), 2);
    }

    #[test]
    fn unsupported_sort_field_returns_error() {
        let mut plan = plan(Entity::ServiceAvailability);
        plan.order = vec![OrderClause {
            field: "not_real".into(),
            direction: OrderDirection::Asc,
        }];

        let err = to_sql_and_params(&plan).unwrap_err();
        assert!(err.to_string().contains("unsupported sort field"));
    }
}
