//! Query execution for OCSF network_activity (flows) entity.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::ocsf_network_activity::dsl::*,
    time::TimeRange,
};
use diesel::dsl::not;
use diesel::dsl::sql;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, BoxedSqlQuery, FromClause, SqlQuery};
use diesel::sql_types::{Array, BigInt, Jsonb, Nullable, Text, Timestamptz};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde::{Deserialize, Serialize};
use serde_json::Value;

type FlowsTable = crate::schema::ocsf_network_activity::table;
type FlowsFromClause = FromClause<FlowsTable>;
type FlowsQuery<'a> =
    BoxedSelectStatement<'a, <FlowsTable as AsQuery>::SqlType, FlowsFromClause, Pg>;

// Directionality is persisted at ingestion time.
pub(super) const FLOW_DIRECTION_EXPR: &str = "COALESCE(direction_label, 'unknown')";

pub(super) const FLOW_PROTOCOL_GROUP_EXPR: &str =
    "CASE WHEN protocol_num = 6 THEN 'tcp' WHEN protocol_num = 17 THEN 'udp' ELSE 'other' END";

// Exporter/interface metadata projections for SRQL.
//
// These expressions are deliberately written without a table alias so they work in:
// - row queries (Diesel query builder)
// - stats queries (raw SQL with alias `f`)
// - downsample queries (raw SQL without alias)
//
// NOTE: cache tables live under `platform`, but SRQL assumes `search_path=platform,...`.
pub(super) const FLOW_SOURCE_EXPR: &str = "COALESCE(ocsf_payload->>'flow_source', 'Unknown')";

pub(super) const FLOW_EXPORTER_NAME_EXPR: &str = r#"
(SELECT ec.exporter_name
 FROM netflow_exporter_cache ec
 WHERE ec.sampler_address = sampler_address
 LIMIT 1)
"#;

pub(super) const FLOW_IN_IF_NAME_EXPR: &str = r#"
(SELECT ic.if_name
 FROM netflow_interface_cache ic
 WHERE ic.sampler_address = sampler_address
   AND ic.if_index = (CASE
     WHEN (ocsf_payload #>> '{connection_info,input_snmp}') ~ '^[0-9]+$'
     THEN (ocsf_payload #>> '{connection_info,input_snmp}')::int
     ELSE NULL
   END)
 LIMIT 1)
"#;

pub(super) const FLOW_OUT_IF_NAME_EXPR: &str = r#"
(SELECT ic.if_name
 FROM netflow_interface_cache ic
 WHERE ic.sampler_address = sampler_address
   AND ic.if_index = (CASE
     WHEN (ocsf_payload #>> '{connection_info,output_snmp}') ~ '^[0-9]+$'
     THEN (ocsf_payload #>> '{connection_info,output_snmp}')::int
     ELSE NULL
   END)
 LIMIT 1)
"#;

pub(super) const FLOW_IN_IF_SPEED_BPS_EXPR: &str = r#"
(SELECT ic.if_speed_bps
 FROM netflow_interface_cache ic
 WHERE ic.sampler_address = sampler_address
   AND ic.if_index = (CASE
     WHEN (ocsf_payload #>> '{connection_info,input_snmp}') ~ '^[0-9]+$'
     THEN (ocsf_payload #>> '{connection_info,input_snmp}')::int
     ELSE NULL
   END)
 LIMIT 1)
"#;

pub(super) const FLOW_OUT_IF_SPEED_BPS_EXPR: &str = r#"
(SELECT ic.if_speed_bps
 FROM netflow_interface_cache ic
 WHERE ic.sampler_address = sampler_address
   AND ic.if_index = (CASE
     WHEN (ocsf_payload #>> '{connection_info,output_snmp}') ~ '^[0-9]+$'
     THEN (ocsf_payload #>> '{connection_info,output_snmp}')::int
     ELSE NULL
   END)
 LIMIT 1)
"#;

pub(super) const FLOW_EXPORTER_NAME_GROUP_EXPR: &str =
    "COALESCE((SELECT ec.exporter_name FROM netflow_exporter_cache ec WHERE ec.sampler_address = sampler_address LIMIT 1), 'Unknown')";

pub(super) const FLOW_IN_IF_NAME_GROUP_EXPR: &str =
    "COALESCE((SELECT ic.if_name FROM netflow_interface_cache ic WHERE ic.sampler_address = sampler_address AND ic.if_index = (CASE WHEN (ocsf_payload #>> '{connection_info,input_snmp}') ~ '^[0-9]+$' THEN (ocsf_payload #>> '{connection_info,input_snmp}')::int ELSE NULL END) LIMIT 1), 'Unknown')";

pub(super) const FLOW_OUT_IF_NAME_GROUP_EXPR: &str =
    "COALESCE((SELECT ic.if_name FROM netflow_interface_cache ic WHERE ic.sampler_address = sampler_address AND ic.if_index = (CASE WHEN (ocsf_payload #>> '{connection_info,output_snmp}') ~ '^[0-9]+$' THEN (ocsf_payload #>> '{connection_info,output_snmp}')::int ELSE NULL END) LIMIT 1), 'Unknown')";

pub(super) const FLOW_IN_IF_SPEED_BPS_GROUP_EXPR: &str =
    "COALESCE((SELECT ic.if_speed_bps::text FROM netflow_interface_cache ic WHERE ic.sampler_address = sampler_address AND ic.if_index = (CASE WHEN (ocsf_payload #>> '{connection_info,input_snmp}') ~ '^[0-9]+$' THEN (ocsf_payload #>> '{connection_info,input_snmp}')::int ELSE NULL END) LIMIT 1), 'Unknown')";

pub(super) const FLOW_OUT_IF_SPEED_BPS_GROUP_EXPR: &str =
    "COALESCE((SELECT ic.if_speed_bps::text FROM netflow_interface_cache ic WHERE ic.sampler_address = sampler_address AND ic.if_index = (CASE WHEN (ocsf_payload #>> '{connection_info,output_snmp}') ~ '^[0-9]+$' THEN (ocsf_payload #>> '{connection_info,output_snmp}')::int ELSE NULL END) LIMIT 1), 'Unknown')";

// Application classification for flows.
//
// This is a derived label used by SRQL (`app:` filter, `by app` group-by, and downsample series).
// It is computed at query time using:
// - baseline protocol/port mapping
// - optional admin override rules in `netflow_app_classification_rules`
//
// NOTE: Table lives under `platform`, but SRQL assumes `search_path=platform,...`.
pub(super) const FLOW_APP_EXPR: &str = r#"
(SELECT
  COALESCE(override_rule.app_label, baseline.app_label, 'unknown')
  FROM LATERAL (
    SELECT
      CASE
        WHEN dst_endpoint_port IS NULL THEN NULL
        WHEN protocol_num = 6 AND dst_endpoint_port = 443 THEN 'https'
        WHEN protocol_num = 6 AND dst_endpoint_port = 80 THEN 'http'
        WHEN protocol_num = 6 AND dst_endpoint_port = 22 THEN 'ssh'
        WHEN dst_endpoint_port = 53 THEN 'dns'
        WHEN dst_endpoint_port = 123 THEN 'ntp'
        WHEN protocol_num = 6 AND dst_endpoint_port IN (25, 465, 587) THEN 'smtp'
        WHEN protocol_num = 6 AND dst_endpoint_port IN (143, 993) THEN 'imap'
        WHEN protocol_num = 6 AND dst_endpoint_port IN (110, 995) THEN 'pop3'
        WHEN protocol_num = 6 AND dst_endpoint_port = 3389 THEN 'rdp'
        WHEN protocol_num = 6 AND dst_endpoint_port = 5432 THEN 'postgres'
        WHEN protocol_num = 6 AND dst_endpoint_port = 3306 THEN 'mysql'
        WHEN protocol_num = 6 AND dst_endpoint_port = 6379 THEN 'redis'
        WHEN protocol_num = 6 AND dst_endpoint_port = 27017 THEN 'mongodb'
        WHEN protocol_num = 6 AND dst_endpoint_port = 9200 THEN 'elasticsearch'
        ELSE NULL
      END AS app_label
  ) baseline
  LEFT JOIN LATERAL (
    SELECT r.app_label
    FROM netflow_app_classification_rules r
    WHERE r.enabled
      AND (r.partition IS NULL OR r.partition = partition)
      AND (r.protocol_num IS NULL OR r.protocol_num = protocol_num)
      AND (r.dst_port IS NULL OR r.dst_port = dst_endpoint_port)
      AND (r.src_port IS NULL OR r.src_port = src_endpoint_port)
      AND (r.src_cidr IS NULL OR (try_inet(NULLIF(src_endpoint_ip, '')) <<= r.src_cidr))
      AND (r.dst_cidr IS NULL OR (try_inet(NULLIF(dst_endpoint_ip, '')) <<= r.dst_cidr))
    ORDER BY
      r.priority DESC,
      (
        (CASE WHEN r.protocol_num IS NULL THEN 0 ELSE 1 END) +
        (CASE WHEN r.dst_port IS NULL THEN 0 ELSE 1 END) +
        (CASE WHEN r.src_port IS NULL THEN 0 ELSE 1 END) +
        (CASE WHEN r.src_cidr IS NULL THEN 0 ELSE 1 END) +
        (CASE WHEN r.dst_cidr IS NULL THEN 0 ELSE 1 END)
      ) DESC,
      r.id ASC
    LIMIT 1
  ) override_rule ON TRUE)
"#;

#[derive(Queryable, Selectable, Serialize, Deserialize)]
#[diesel(table_name = crate::schema::ocsf_network_activity)]
struct FlowRow {
    time: chrono::NaiveDateTime,
    class_uid: i32,
    category_uid: i32,
    activity_id: i32,
    type_uid: i32,
    severity_id: i32,
    start_time: Option<chrono::NaiveDateTime>,
    end_time: Option<chrono::NaiveDateTime>,
    src_endpoint_ip: Option<String>,
    src_endpoint_port: Option<i32>,
    src_as_number: Option<i32>,
    dst_endpoint_ip: Option<String>,
    dst_endpoint_port: Option<i32>,
    dst_as_number: Option<i32>,
    protocol_num: Option<i32>,
    protocol_name: Option<String>,
    protocol_source: Option<String>,
    tcp_flags: Option<i32>,
    tcp_flags_labels: Option<Vec<String>>,
    tcp_flags_source: Option<String>,
    dst_service_label: Option<String>,
    dst_service_source: Option<String>,
    bytes_total: i64,
    packets_total: i64,
    bytes_in: i64,
    bytes_out: i64,
    direction_label: Option<String>,
    direction_source: Option<String>,
    src_hosting_provider: Option<String>,
    src_hosting_provider_source: Option<String>,
    dst_hosting_provider: Option<String>,
    dst_hosting_provider_source: Option<String>,
    src_mac: Option<String>,
    dst_mac: Option<String>,
    src_mac_vendor: Option<String>,
    src_mac_vendor_source: Option<String>,
    dst_mac_vendor: Option<String>,
    dst_mac_vendor_source: Option<String>,
    sampler_address: Option<String>,
    ocsf_payload: Value,
    partition: Option<String>,
    created_at: chrono::NaiveDateTime,
}

impl FlowRow {
    fn into_json(self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    // Handle stats aggregation queries separately
    if plan.stats.is_some() {
        return execute_stats(conn, plan).await;
    }

    let query = build_query(plan)?;
    let rows: Vec<FlowRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(FlowRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    // Handle stats aggregation queries separately
    if plan.stats.is_some() {
        return to_sql_and_params_stats(plan);
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
        Entity::Flows => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by flows query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<FlowsQuery<'static>> {
    let mut query = ocsf_network_activity.into_boxed::<Pg>();

    // Apply time filter
    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(time.ge(start.naive_utc()).and(time.le(end.naive_utc())));
    }

    // Apply filters
    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    // Apply ordering
    query = apply_ordering(query, &plan.order);

    Ok(query)
}

fn apply_filter<'a>(mut query: FlowsQuery<'a>, filter: &Filter) -> Result<FlowsQuery<'a>> {
    match filter.field.as_str() {
        "device_id" => {
            let expr = flow_device_scope_expr(filter)?;
            query = query.filter(sql::<diesel::sql_types::Bool>(&expr));
        }
        "src_endpoint_ip" | "src_ip" => {
            query = apply_text_filter!(query, filter, src_endpoint_ip)?;
        }
        "dst_endpoint_ip" | "dst_ip" => {
            query = apply_text_filter!(query, filter, dst_endpoint_ip)?;
        }
        "protocol_name" => {
            query = apply_text_filter!(query, filter, protocol_name)?;
        }
        "sampler_address" => {
            query = apply_text_filter!(query, filter, sampler_address)?;
        }
        "exporter_name" => {
            let expr = sql::<Text>(FLOW_EXPORTER_NAME_GROUP_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "in_if_name" => {
            let expr = sql::<Text>(FLOW_IN_IF_NAME_GROUP_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "out_if_name" => {
            let expr = sql::<Text>(FLOW_OUT_IF_NAME_GROUP_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "in_if_speed_bps" => {
            let expr = sql::<Text>(FLOW_IN_IF_SPEED_BPS_GROUP_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "out_if_speed_bps" => {
            let expr = sql::<Text>(FLOW_OUT_IF_SPEED_BPS_GROUP_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "protocol_num" | "proto" => {
            let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                ServiceError::InvalidRequest("protocol_num must be an integer".into())
            })?;
            query = apply_eq_filter!(
                query,
                filter,
                protocol_num,
                value,
                "protocol_num filter only supports equality"
            )?;
        }
        "src_port" | "src_endpoint_port" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("src_port must be an integer".into())
                })?;
                query = apply_eq_filter!(
                    query,
                    filter,
                    src_endpoint_port,
                    value,
                    "src_port filter only supports equality"
                )?;
            }
            FilterOp::Like | FilterOp::NotLike => {
                let value = filter.value.as_scalar()?.to_string();
                let text_column = sql::<Text>("src_endpoint_port::text");
                query = match filter.op {
                    FilterOp::Like => query.filter(text_column.ilike(value)),
                    FilterOp::NotLike => query.filter(text_column.not_ilike(value)),
                    _ => query,
                };
            }
            _ => {
                return Err(ServiceError::InvalidRequest(
                    "src_port filter only supports equality or wildcard matching".into(),
                ));
            }
        },
        "dst_port" | "dst_endpoint_port" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("dst_port must be an integer".into())
                })?;
                query = apply_eq_filter!(
                    query,
                    filter,
                    dst_endpoint_port,
                    value,
                    "dst_port filter only supports equality"
                )?;
            }
            FilterOp::Like | FilterOp::NotLike => {
                let value = filter.value.as_scalar()?.to_string();
                let text_column = sql::<Text>("dst_endpoint_port::text");
                query = match filter.op {
                    FilterOp::Like => query.filter(text_column.ilike(value)),
                    FilterOp::NotLike => query.filter(text_column.not_ilike(value)),
                    _ => query,
                };
            }
            _ => {
                return Err(ServiceError::InvalidRequest(
                    "dst_port filter only supports equality or wildcard matching".into(),
                ));
            }
        },
        "direction" => {
            // direction is computed from local CIDR configuration; support text-like operators.
            let expr = sql::<Text>(FLOW_DIRECTION_EXPR);
            match filter.op {
                FilterOp::Eq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.eq(value));
                }
                FilterOp::NotEq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ne(value));
                }
                FilterOp::Like => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ilike(value));
                }
                FilterOp::NotLike => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.not_ilike(value));
                }
                FilterOp::In => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(expr.eq_any(values));
                    }
                }
                FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(not(expr.eq_any(values)));
                    }
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "direction filter only supports equality, wildcard, or list matching"
                            .into(),
                    ));
                }
            }
        }
        "flow_source" | "collector" => {
            let expr = sql::<Text>(FLOW_SOURCE_EXPR);
            query = apply_text_filter!(query, filter, expr)?;
        }
        "protocol_group" | "proto_group" => {
            let expr = sql::<Text>(FLOW_PROTOCOL_GROUP_EXPR);
            match filter.op {
                FilterOp::Eq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.eq(value));
                }
                FilterOp::NotEq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ne(value));
                }
                FilterOp::Like => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ilike(value));
                }
                FilterOp::NotLike => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.not_ilike(value));
                }
                FilterOp::In => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(expr.eq_any(values));
                    }
                }
                FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(not(expr.eq_any(values)));
                    }
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "protocol_group filter only supports equality, wildcard, or list matching"
                            .into(),
                    ));
                }
            }
        }
        "app" => {
            let expr = sql::<Text>(FLOW_APP_EXPR);
            match filter.op {
                FilterOp::Eq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.eq(value));
                }
                FilterOp::NotEq => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ne(value));
                }
                FilterOp::Like => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.ilike(value));
                }
                FilterOp::NotLike => {
                    let value = filter.value.as_scalar()?.to_string();
                    query = query.filter(expr.not_ilike(value));
                }
                FilterOp::In => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(expr.eq_any(values));
                    }
                }
                FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if !values.is_empty() {
                        query = query.filter(not(expr.eq_any(values)));
                    }
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "app filter only supports equality, wildcard, or list matching".into(),
                    ));
                }
            }
        }
        "src_country_iso2" | "src_country" => {
            let cc = filter.value.as_scalar()?.to_string().to_uppercase();
            if cc.len() != 2 || !cc.chars().all(|c| c.is_ascii_alphabetic()) {
                return Err(ServiceError::InvalidRequest(
                    "src_country_iso2 must be a 2-letter ISO2 code".into(),
                ));
            }

            let exists = sql::<diesel::sql_types::Bool>(&format!(
                "EXISTS (SELECT 1 FROM ip_geo_enrichment_cache g WHERE g.ip = NULLIF(src_endpoint_ip, '') AND g.country_iso2 = '{cc}')"
            ));

            match filter.op {
                FilterOp::Eq => query = query.filter(exists),
                FilterOp::NotEq => query = query.filter(not(exists)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "src_country_iso2 filter only supports equality".into(),
                    ));
                }
            }
        }
        "dst_country_iso2" | "dst_country" => {
            let cc = filter.value.as_scalar()?.to_string().to_uppercase();
            if cc.len() != 2 || !cc.chars().all(|c| c.is_ascii_alphabetic()) {
                return Err(ServiceError::InvalidRequest(
                    "dst_country_iso2 must be a 2-letter ISO2 code".into(),
                ));
            }

            let exists = sql::<diesel::sql_types::Bool>(&format!(
                "EXISTS (SELECT 1 FROM ip_geo_enrichment_cache g WHERE g.ip = NULLIF(dst_endpoint_ip, '') AND g.country_iso2 = '{cc}')"
            ));

            match filter.op {
                FilterOp::Eq => query = query.filter(exists),
                FilterOp::NotEq => query = query.filter(not(exists)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "dst_country_iso2 filter only supports equality".into(),
                    ));
                }
            }
        }
        "src_cidr" => {
            let cidr = normalize_cidr_literal(filter.value.as_scalar()?)?;
            let within = sql::<diesel::sql_types::Bool>(&format!(
                "(try_inet(NULLIF(src_endpoint_ip, '')) <<= '{cidr}'::cidr)"
            ));

            match filter.op {
                FilterOp::Eq => query = query.filter(within),
                FilterOp::NotEq => query = query.filter(not(within)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "src_cidr filter only supports equality".into(),
                    ));
                }
            }
        }
        "dst_cidr" => {
            let cidr = normalize_cidr_literal(filter.value.as_scalar()?)?;
            let within = sql::<diesel::sql_types::Bool>(&format!(
                "(try_inet(NULLIF(dst_endpoint_ip, '')) <<= '{cidr}'::cidr)"
            ));

            match filter.op {
                FilterOp::Eq => query = query.filter(within),
                FilterOp::NotEq => query = query.filter(not(within)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "dst_cidr filter only supports equality".into(),
                    ));
                }
            }
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for flows: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn normalize_cidr_literal(input: &str) -> Result<String> {
    let s = input.trim();
    let (ip_raw, prefix_raw) = s
        .split_once('/')
        .ok_or_else(|| ServiceError::InvalidRequest("CIDR must be like 10.0.0.0/24".into()))?;

    let ip: std::net::IpAddr = ip_raw.trim().parse().map_err(|_| {
        ServiceError::InvalidRequest("CIDR must contain a valid IPv4/IPv6 address".into())
    })?;

    let prefix: u8 = prefix_raw.trim().parse().map_err(|_| {
        ServiceError::InvalidRequest("CIDR must contain a valid prefix length".into())
    })?;

    let max = match ip {
        std::net::IpAddr::V4(_) => 32,
        std::net::IpAddr::V6(_) => 128,
    };
    if prefix > max {
        return Err(ServiceError::InvalidRequest(format!(
            "CIDR prefix length must be <= {max}"
        )));
    }

    Ok(format!("{ip}/{prefix}"))
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
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
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        // device_id scope is expressed with validated SQL literals in `flow_device_scope_expr`.
        "device_id" => Ok(()),
        "src_endpoint_ip" | "src_ip" | "dst_endpoint_ip" | "dst_ip" | "protocol_name"
        | "sampler_address" | "direction" | "flow_source" | "collector" | "exporter_name"
        | "in_if_name" | "out_if_name" | "in_if_speed_bps" | "out_if_speed_bps" => {
            collect_text_params(params, filter)
        }
        // These filters are implemented using inline SQL literals in `apply_filter` (no binds),
        // so we must not collect bind params for them or we'll shift LIMIT/OFFSET binds.
        "src_country_iso2" | "src_country" | "dst_country_iso2" | "dst_country" => Ok(()),
        "src_cidr" | "dst_cidr" => Ok(()),
        "protocol_num" | "proto" => {
            let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                ServiceError::InvalidRequest(format!("{} must be an integer", filter.field))
            })?;
            params.push(BindParam::Int(value as i64));
            Ok(())
        }
        "src_port" | "src_endpoint_port" => collect_port_params(params, filter, "src_port"),
        "dst_port" | "dst_endpoint_port" => collect_port_params(params, filter, "dst_port"),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn collect_port_params(params: &mut Vec<BindParam>, filter: &Filter, label: &str) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value =
                filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest(format!("{label} must be an integer"))
                })?;
            params.push(BindParam::Int(value as i64));
            Ok(())
        }
        FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{label} filter does not support this operator"
        ))),
    }
}

fn apply_ordering<'a>(mut query: FlowsQuery<'a>, order: &[OrderClause]) -> FlowsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_single_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
    }

    // Default ordering by time descending
    if !applied {
        query = query.order(time.desc());
    }

    // Always apply a stable tie-breaker for deterministic pagination.
    query.then_order_by(created_at.desc())
}

fn apply_single_order<'a>(
    query: FlowsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> FlowsQuery<'a> {
    match field {
        "time" => match direction {
            OrderDirection::Asc => query.order(time.asc()),
            OrderDirection::Desc => query.order(time.desc()),
        },
        "bytes_total" => match direction {
            OrderDirection::Asc => query.order(bytes_total.asc()),
            OrderDirection::Desc => query.order(bytes_total.desc()),
        },
        "packets_total" => match direction {
            OrderDirection::Asc => query.order(packets_total.asc()),
            OrderDirection::Desc => query.order(packets_total.desc()),
        },
        "bytes_in" => match direction {
            OrderDirection::Asc => query.order(bytes_in.asc()),
            OrderDirection::Desc => query.order(bytes_in.desc()),
        },
        "bytes_out" => match direction {
            OrderDirection::Asc => query.order(bytes_out.asc()),
            OrderDirection::Desc => query.order(bytes_out.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: FlowsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> FlowsQuery<'a> {
    match field {
        "time" => match direction {
            OrderDirection::Asc => query.then_order_by(time.asc()),
            OrderDirection::Desc => query.then_order_by(time.desc()),
        },
        "bytes_total" => match direction {
            OrderDirection::Asc => query.then_order_by(bytes_total.asc()),
            OrderDirection::Desc => query.then_order_by(bytes_total.desc()),
        },
        "packets_total" => match direction {
            OrderDirection::Asc => query.then_order_by(packets_total.asc()),
            OrderDirection::Desc => query.then_order_by(packets_total.desc()),
        },
        "bytes_in" => match direction {
            OrderDirection::Asc => query.then_order_by(bytes_in.asc()),
            OrderDirection::Desc => query.then_order_by(bytes_in.desc()),
        },
        "bytes_out" => match direction {
            OrderDirection::Asc => query.then_order_by(bytes_out.asc()),
            OrderDirection::Desc => query.then_order_by(bytes_out.desc()),
        },
        _ => query,
    }
}

// Stats aggregation support
#[derive(Debug, Clone, Copy, PartialEq)]
enum FlowAggFunc {
    Count,
    CountDistinct,
    Sum,
    Avg,
    Min,
    Max,
}

impl FlowAggFunc {
    fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "count" => Some(Self::Count),
            "count_distinct" => Some(Self::CountDistinct),
            "sum" => Some(Self::Sum),
            "avg" => Some(Self::Avg),
            "min" => Some(Self::Min),
            "max" => Some(Self::Max),
            _ => None,
        }
    }

    fn sql(&self) -> &'static str {
        match self {
            Self::Count => "COUNT",
            Self::CountDistinct => "COUNT",
            Self::Sum => "SUM",
            Self::Avg => "AVG",
            Self::Min => "MIN",
            Self::Max => "MAX",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum FlowAggField {
    Star,
    BytesTotal,
    PacketsTotal,
    BytesIn,
    BytesOut,
    SrcEndpointPort,
    DstEndpointPort,
}

impl FlowAggField {
    fn from_str(s: &str) -> Option<Self> {
        match s {
            "*" => Some(Self::Star),
            "bytes_total" => Some(Self::BytesTotal),
            "packets_total" => Some(Self::PacketsTotal),
            "bytes_in" => Some(Self::BytesIn),
            "bytes_out" => Some(Self::BytesOut),
            "src_endpoint_port" | "src_port" => Some(Self::SrcEndpointPort),
            "dst_endpoint_port" | "dst_port" => Some(Self::DstEndpointPort),
            _ => None,
        }
    }

    fn sql(&self) -> &'static str {
        match self {
            Self::Star => "*",
            Self::BytesTotal => "bytes_total",
            Self::PacketsTotal => "packets_total",
            Self::BytesIn => "bytes_in",
            Self::BytesOut => "bytes_out",
            Self::SrcEndpointPort => "src_endpoint_port",
            Self::DstEndpointPort => "dst_endpoint_port",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum FlowGroupField {
    SrcEndpointIp,
    DstEndpointIp,
    SrcEndpointPort,
    DstEndpointPort,
    ProtocolNum,
    ProtocolName,
    ProtocolGroup,
    FlowSource,
    SamplerAddress,
    ExporterName,
    InIfName,
    OutIfName,
    InIfSpeedBps,
    OutIfSpeedBps,
    Direction,
    App,
    SrcCountryIso2,
    DstCountryIso2,
}

impl FlowGroupField {
    fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "src_endpoint_ip" | "src_ip" => Some(Self::SrcEndpointIp),
            "dst_endpoint_ip" | "dst_ip" => Some(Self::DstEndpointIp),
            "src_endpoint_port" | "src_port" => Some(Self::SrcEndpointPort),
            "dst_endpoint_port" | "dst_port" => Some(Self::DstEndpointPort),
            "protocol_num" | "proto" => Some(Self::ProtocolNum),
            "protocol_name" => Some(Self::ProtocolName),
            "protocol_group" | "proto_group" => Some(Self::ProtocolGroup),
            "flow_source" | "collector" => Some(Self::FlowSource),
            "sampler_address" => Some(Self::SamplerAddress),
            "exporter_name" => Some(Self::ExporterName),
            "in_if_name" => Some(Self::InIfName),
            "out_if_name" => Some(Self::OutIfName),
            "in_if_speed_bps" => Some(Self::InIfSpeedBps),
            "out_if_speed_bps" => Some(Self::OutIfSpeedBps),
            "direction" => Some(Self::Direction),
            "app" => Some(Self::App),
            "src_country_iso2" | "src_country" => Some(Self::SrcCountryIso2),
            "dst_country_iso2" | "dst_country" => Some(Self::DstCountryIso2),
            _ => None,
        }
    }

    fn response_key(&self) -> &'static str {
        match self {
            Self::SrcEndpointIp => "src_endpoint_ip",
            Self::DstEndpointIp => "dst_endpoint_ip",
            Self::SrcEndpointPort => "src_endpoint_port",
            Self::DstEndpointPort => "dst_endpoint_port",
            Self::ProtocolNum => "protocol_num",
            Self::ProtocolName => "protocol_name",
            Self::ProtocolGroup => "protocol_group",
            Self::FlowSource => "flow_source",
            Self::SamplerAddress => "sampler_address",
            Self::ExporterName => "exporter_name",
            Self::InIfName => "in_if_name",
            Self::OutIfName => "out_if_name",
            Self::InIfSpeedBps => "in_if_speed_bps",
            Self::OutIfSpeedBps => "out_if_speed_bps",
            Self::Direction => "direction",
            Self::App => "app",
            Self::SrcCountryIso2 => "src_country_iso2",
            Self::DstCountryIso2 => "dst_country_iso2",
        }
    }

    fn group_expr(&self) -> &'static str {
        match self {
            Self::SrcEndpointIp => "src_endpoint_ip",
            Self::DstEndpointIp => "dst_endpoint_ip",
            Self::SrcEndpointPort => "src_endpoint_port",
            Self::DstEndpointPort => "dst_endpoint_port",
            Self::ProtocolNum => "protocol_num",
            Self::ProtocolName => "protocol_name",
            Self::ProtocolGroup => FLOW_PROTOCOL_GROUP_EXPR,
            Self::FlowSource => FLOW_SOURCE_EXPR,
            Self::SamplerAddress => "sampler_address",
            Self::ExporterName => FLOW_EXPORTER_NAME_GROUP_EXPR,
            Self::InIfName => FLOW_IN_IF_NAME_GROUP_EXPR,
            Self::OutIfName => FLOW_OUT_IF_NAME_GROUP_EXPR,
            Self::InIfSpeedBps => FLOW_IN_IF_SPEED_BPS_GROUP_EXPR,
            Self::OutIfSpeedBps => FLOW_OUT_IF_SPEED_BPS_GROUP_EXPR,
            Self::Direction => FLOW_DIRECTION_EXPR,
            Self::App => FLOW_APP_EXPR,
            Self::SrcCountryIso2 => "COALESCE(src_geo.country_iso2, 'Unknown')",
            Self::DstCountryIso2 => "COALESCE(dst_geo.country_iso2, 'Unknown')",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum FlowGroupSpec {
    Field(FlowGroupField),
    SrcCidr { prefix: u8 },
    DstCidr { prefix: u8 },
}

impl FlowGroupSpec {
    fn parse(token: &str) -> Result<Self> {
        if let Some((kind, rest)) = token.split_once(':') {
            let kind = kind.to_lowercase();
            let prefix: u8 = rest.parse().map_err(|_| {
                ServiceError::InvalidRequest(format!(
                    "invalid CIDR prefix length in group-by: '{token}'"
                ))
            })?;
            if prefix > 32 {
                return Err(ServiceError::InvalidRequest(format!(
                    "CIDR prefix length must be <= 32 (got {prefix})"
                )));
            }
            match kind.as_str() {
                "src_cidr" => return Ok(Self::SrcCidr { prefix }),
                "dst_cidr" => return Ok(Self::DstCidr { prefix }),
                _ => {}
            }
        }

        if let Some(field) = FlowGroupField::from_str(token) {
            return Ok(Self::Field(field));
        }

        Err(ServiceError::InvalidRequest(format!(
            "unsupported group-by field for flows stats: '{token}'"
        )))
    }

    fn response_key(&self) -> &'static str {
        match self {
            Self::Field(field) => field.response_key(),
            Self::SrcCidr { .. } => "src_cidr",
            Self::DstCidr { .. } => "dst_cidr",
        }
    }

    fn group_expr(&self) -> String {
        match self {
            Self::Field(field) => field.group_expr().to_string(),
            Self::SrcCidr { prefix } => format!(
                "COALESCE(set_masklen(try_inet(NULLIF(src_endpoint_ip, '')), {prefix})::text, 'Unknown')"
            ),
            Self::DstCidr { prefix } => format!(
                "COALESCE(set_masklen(try_inet(NULLIF(dst_endpoint_ip, '')), {prefix})::text, 'Unknown')"
            ),
        }
    }
}

#[derive(Debug, Clone)]
struct FlowStatsSpec {
    agg_func: FlowAggFunc,
    agg_field: FlowAggField,
    alias: String,
    group_by: Vec<FlowGroupSpec>,
}

#[derive(Debug, Clone)]
enum FlowSqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Int(i64),
    IntArray(Vec<i64>),
    Timestamp(chrono::DateTime<chrono::Utc>),
}

impl FlowSqlBindValue {
    fn apply<'a>(&self, query: BoxedSqlQuery<'a, Pg, SqlQuery>) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            FlowSqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            FlowSqlBindValue::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            FlowSqlBindValue::Int(value) => query.bind::<BigInt, _>(*value),
            FlowSqlBindValue::IntArray(values) => query.bind::<Array<BigInt>, _>(values.clone()),
            FlowSqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

fn bind_param_from_flow_stats(value: FlowSqlBindValue) -> BindParam {
    match value {
        FlowSqlBindValue::Text(v) => BindParam::Text(v),
        FlowSqlBindValue::TextArray(v) => BindParam::TextArray(v),
        FlowSqlBindValue::Int(v) => BindParam::Int(v),
        FlowSqlBindValue::IntArray(v) => BindParam::IntArray(v),
        FlowSqlBindValue::Timestamp(v) => BindParam::timestamptz(v),
    }
}

#[derive(Debug, QueryableByName)]
struct FlowStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    result: Option<Value>,
}

struct FlowGroupedStatsSql {
    sql: String, // uses '?' placeholders for Diesel binds
    binds: Vec<FlowSqlBindValue>,
}

/// Rewrites ? placeholders to $1, $2, etc. for PostgreSQL (embedded/NIF mode).
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

async fn execute_stats(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    let spec = parse_stats_expr(
        plan.stats
            .as_ref()
            .ok_or_else(|| {
                ServiceError::InvalidRequest("stats expression required for aggregation".into())
            })?
            .as_raw(),
    )?;

    let grouped = build_grouped_stats_query(plan, &spec)?;
    let mut query = diesel::sql_query(&grouped.sql).into_boxed();
    for bind in &grouped.binds {
        query = bind.apply(query);
    }

    let rows: Vec<FlowStatsPayload> = query
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().filter_map(|row| row.result).collect())
}

fn to_sql_and_params_stats(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    let spec = parse_stats_expr(
        plan.stats
            .as_ref()
            .ok_or_else(|| {
                ServiceError::InvalidRequest("stats expression required for aggregation".into())
            })?
            .as_raw(),
    )?;

    let grouped = build_grouped_stats_query(plan, &spec)?;
    let sql = rewrite_placeholders(&grouped.sql);
    let params: Vec<BindParam> = grouped
        .binds
        .into_iter()
        .map(bind_param_from_flow_stats)
        .collect();
    Ok((sql, params))
}

fn parse_stats_expr(expr: &str) -> Result<FlowStatsSpec> {
    // Parse: "sum(bytes_total) as total_bytes by src_endpoint_ip"
    let parts: Vec<&str> = expr.split_whitespace().collect();

    if parts.len() < 3 {
        return Err(ServiceError::InvalidRequest(
            "stats expression must be like: sum(bytes_total) as total_bytes".into(),
        ));
    }

    let func_part = parts[0];
    let (func, field) = if let Some(open) = func_part.find('(') {
        if let Some(close) = func_part.find(')') {
            (&func_part[..open], &func_part[open + 1..close])
        } else {
            return Err(ServiceError::InvalidRequest(
                "invalid stats expression".into(),
            ));
        }
    } else {
        return Err(ServiceError::InvalidRequest(
            "invalid stats expression".into(),
        ));
    };

    let agg_func = FlowAggFunc::from_str(func).ok_or_else(|| {
        ServiceError::InvalidRequest(format!("unsupported aggregation function '{func}'"))
    })?;

    let agg_field = FlowAggField::from_str(field).ok_or_else(|| {
        ServiceError::InvalidRequest(format!("unsupported aggregation field '{field}'"))
    })?;

    // COUNT(*) is the only valid use of "*"
    if agg_field == FlowAggField::Star && !matches!(agg_func, FlowAggFunc::Count) {
        return Err(ServiceError::InvalidRequest(
            "only count(*) is supported for '*'".into(),
        ));
    }

    // Port columns only support count-like aggregates.
    if matches!(
        agg_field,
        FlowAggField::SrcEndpointPort | FlowAggField::DstEndpointPort
    ) && !matches!(agg_func, FlowAggFunc::Count | FlowAggFunc::CountDistinct)
    {
        return Err(ServiceError::InvalidRequest(
            "port fields only support count(...) or count_distinct(...)".into(),
        ));
    }

    let alias_idx = parts.iter().position(|&p| p == "as").ok_or_else(|| {
        ServiceError::InvalidRequest("stats expression must include 'as <alias>'".into())
    })?;

    let alias = parts
        .get(alias_idx + 1)
        .ok_or_else(|| {
            ServiceError::InvalidRequest("stats expression missing alias after 'as'".into())
        })?
        .to_string();

    // Group-by may include multiple keys separated by commas. We intentionally allow
    // spaces after commas by consuming the remainder of the expression after "by".
    let group_by: Vec<FlowGroupSpec> = if let Some(by_idx) = parts.iter().position(|&p| p == "by") {
        let raw = parts
            .get(by_idx + 1..)
            .ok_or_else(|| {
                ServiceError::InvalidRequest("stats expression missing group-by".into())
            })?
            .join(" ");

        let tokens: Vec<&str> = raw
            .split(',')
            .map(|t| t.trim())
            .filter(|t| !t.is_empty())
            .collect();

        let mut out: Vec<FlowGroupSpec> = Vec::with_capacity(tokens.len());
        for token in tokens {
            out.push(FlowGroupSpec::parse(token)?);
        }
        out
    } else {
        Vec::new()
    };

    Ok(FlowStatsSpec {
        agg_func,
        agg_field,
        alias,
        group_by,
    })
}

/// Minimum time range (hours) before we consider routing flow stats to a CAGG.
const FLOW_CAGG_ROUTING_THRESHOLD_HOURS: i64 = 6;

/// Returns the filter field names that can safely be applied against a given CAGG table.
/// Only direct dimension-column filters are allowed — expression-based filters (subqueries,
/// CASE expressions, geo joins) reference raw-table-only structures and must fall back.
fn cagg_filter_fields(table: &str) -> &'static [&'static str] {
    match table {
        "ocsf_network_activity_hourly_talkers" => {
            &["src_endpoint_ip", "src_ip"]
        }
        "ocsf_network_activity_hourly_listeners" => {
            &["dst_endpoint_ip", "dst_ip"]
        }
        "ocsf_network_activity_hourly_proto" => &["protocol_num", "proto"],
        "ocsf_network_activity_hourly_ports" => {
            &["dst_endpoint_port", "dst_port"]
        }
        "ocsf_network_activity_hourly_conversations" => {
            &[
                "src_endpoint_ip",
                "src_ip",
                "dst_endpoint_ip",
                "dst_ip",
            ]
        }
        // Traffic CAGGs (5m, 1h, 1d) have no dimension columns
        _ => &[],
    }
}

/// Returns `Some((cagg_table, ts_col))` when a flow stats query can be served
/// entirely from a pre-aggregated continuous aggregate.
fn should_route_flow_stats_to_cagg(
    plan: &QueryPlan,
    spec: &FlowStatsSpec,
) -> Option<(&'static str, &'static str)> {
    // 1. Must have a time range >= threshold
    let time_range = plan.time_range.as_ref()?;
    let span = time_range.end.signed_duration_since(time_range.start);
    if span < chrono::Duration::hours(FLOW_CAGG_ROUTING_THRESHOLD_HOURS) {
        return None;
    }

    // 2. Agg field must exist in CAGGs
    if !matches!(
        spec.agg_field,
        FlowAggField::BytesTotal | FlowAggField::PacketsTotal | FlowAggField::Star
    ) {
        return None;
    }

    // 3. Agg function must be Sum or Count (CAGGs store SUMs, not raw values)
    if !matches!(spec.agg_func, FlowAggFunc::Sum | FlowAggFunc::Count) {
        return None;
    }

    // 4. Group-by fields must match an available CAGG dimension
    let is_long_window = span >= chrono::Duration::hours(24);

    let table: &'static str = match spec.group_by.as_slice() {
        [] => {
            if is_long_window {
                "flow_traffic_1h"
            } else {
                "ocsf_network_activity_5m_traffic"
            }
        }
        [FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp)] => {
            "ocsf_network_activity_hourly_talkers"
        }
        [FlowGroupSpec::Field(FlowGroupField::DstEndpointIp)] => {
            "ocsf_network_activity_hourly_listeners"
        }
        [FlowGroupSpec::Field(FlowGroupField::ProtocolNum)] => {
            "ocsf_network_activity_hourly_proto"
        }
        [FlowGroupSpec::Field(FlowGroupField::DstEndpointPort)] => {
            "ocsf_network_activity_hourly_ports"
        }
        [FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp), FlowGroupSpec::Field(FlowGroupField::DstEndpointIp)]
        | [FlowGroupSpec::Field(FlowGroupField::DstEndpointIp), FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp)] => {
            "ocsf_network_activity_hourly_conversations"
        }
        _ => return None, // Unsupported group-by combination
    };

    // 5. All filters must target columns that exist in the selected CAGG.
    // Only simple dimension-column filters are safe; expression-based filters
    // (device_id, exporter_name, app, geo, CIDR, etc.) reference raw-table-only
    // columns/subqueries and would produce wrong results or SQL errors.
    let allowed_filters = cagg_filter_fields(table);
    if !plan
        .filters
        .iter()
        .all(|f| allowed_filters.contains(&f.field.as_str()))
    {
        return None;
    }

    Some((table, "bucket"))
}

fn build_grouped_stats_query(
    plan: &QueryPlan,
    spec: &FlowStatsSpec,
) -> Result<FlowGroupedStatsSql> {
    let mut binds: Vec<FlowSqlBindValue> = Vec::new();
    let mut where_parts: Vec<String> = Vec::new();

    // Guardrails: multi-dimension group-by can be expensive. Require explicit time window and cap limit.
    if spec.group_by.len() > 1 {
        if plan.time_range.is_none() {
            return Err(ServiceError::InvalidRequest(
                "multi-dimension flow stats queries require an explicit time window".into(),
            ));
        }
        if plan.limit > 500 {
            return Err(ServiceError::InvalidRequest(
                "multi-dimension flow stats queries require limit <= 500".into(),
            ));
        }
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        // ocsf_network_activity.time is a timestamp without timezone storing UTC; normalize the bind.
        where_parts.push(
            "f.time >= (?::timestamptz AT TIME ZONE 'UTC') AND f.time <= (?::timestamptz AT TIME ZONE 'UTC')"
                .to_string(),
        );
        binds.push(FlowSqlBindValue::Timestamp(*start));
        binds.push(FlowSqlBindValue::Timestamp(*end));
    }

    // Geo joins are only included if a requested group-by or filter needs them.
    let mut needs_src_geo = false;
    let mut needs_dst_geo = false;

    for group in &spec.group_by {
        if let FlowGroupSpec::Field(f) = group {
            match f {
                FlowGroupField::SrcCountryIso2 => needs_src_geo = true,
                FlowGroupField::DstCountryIso2 => needs_dst_geo = true,
                _ => {}
            }
        }
    }

    for filter in &plan.filters {
        match filter.field.as_str() {
            "src_country_iso2" | "src_country" => needs_src_geo = true,
            "dst_country_iso2" | "dst_country" => needs_dst_geo = true,
            _ => {}
        }
    }

    for filter in &plan.filters {
        where_parts.push(build_stats_filter_clause(filter, &mut binds)?);
    }

    let mut where_sql = if where_parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", where_parts.join(" AND "))
    };

    let mut join_sql = String::new();
    if needs_src_geo {
        join_sql.push_str(
            " LEFT JOIN ip_geo_enrichment_cache src_geo ON src_geo.ip = NULLIF(f.src_endpoint_ip, '')",
        );
    }
    if needs_dst_geo {
        join_sql.push_str(
            " LEFT JOIN ip_geo_enrichment_cache dst_geo ON dst_geo.ip = NULLIF(f.dst_endpoint_ip, '')",
        );
    }

    // Check if this query can be served from a CAGG
    let cagg_route = should_route_flow_stats_to_cagg(plan, spec);

    let (from_table, time_col) = if let Some((cagg_table, ts_col)) = cagg_route {
        (cagg_table, ts_col)
    } else {
        ("ocsf_network_activity", "time")
    };

    // For CAGG-routed queries, rewrite time predicates to use the bucket column
    // and re-add only the dimension-safe filters validated by should_route_flow_stats_to_cagg.
    if cagg_route.is_some() {
        where_parts.clear();
        binds.clear();
        if let Some(TimeRange { start, end }) = &plan.time_range {
            where_parts.push(format!(
                "f.{time_col} >= (?::timestamptz AT TIME ZONE 'UTC') AND f.{time_col} <= (?::timestamptz AT TIME ZONE 'UTC')"
            ));
            binds.push(FlowSqlBindValue::Timestamp(*start));
            binds.push(FlowSqlBindValue::Timestamp(*end));
        }
        // Re-add dimension filters (safe columns validated by cagg_filter_fields)
        for filter in &plan.filters {
            where_parts.push(build_stats_filter_clause(filter, &mut binds)?);
        }
        where_sql = if where_parts.is_empty() {
            String::new()
        } else {
            format!(" WHERE {}", where_parts.join(" AND "))
        };
        // No geo joins for CAGG queries
        join_sql = String::new();
    }

    // For CAGG-routed count(*), rewrite to SUM(flow_count)
    let agg_sql = if cagg_route.is_some() && matches!(spec.agg_func, FlowAggFunc::Count) {
        "SUM(flow_count)".to_string()
    } else if matches!(spec.agg_func, FlowAggFunc::CountDistinct) {
        if matches!(spec.agg_field, FlowAggField::Star) {
            return Err(ServiceError::InvalidRequest(
                "count_distinct(*) is not supported".into(),
            ));
        }
        format!("COUNT(DISTINCT {})", spec.agg_field.sql())
    } else {
        format!("{}({})", spec.agg_func.sql(), spec.agg_field.sql())
    };

    let outer_sql = if !spec.group_by.is_empty() {
        let mut seen: std::collections::HashSet<&'static str> = std::collections::HashSet::new();
        let mut group_keys: Vec<&'static str> = Vec::with_capacity(spec.group_by.len());
        let mut group_exprs: Vec<String> = Vec::with_capacity(spec.group_by.len());

        for g in &spec.group_by {
            let key = g.response_key();
            if !seen.insert(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "duplicate group-by key for flows stats: '{key}'"
                )));
            }
            group_keys.push(key);
            group_exprs.push(g.group_expr());
        }

        let select_groups = group_exprs
            .iter()
            .enumerate()
            .map(|(idx, expr)| format!("{expr} AS group_value_{idx}"))
            .collect::<Vec<_>>()
            .join(", ");

        let group_by_sql = group_exprs.join(", ");

        let inner = format!(
            "SELECT {select_groups}, {agg_sql} AS agg_value FROM {from_table} f{join_sql}{where_sql} GROUP BY {group_by_sql}"
        );

        let order_sql = build_stats_order_sql(plan, &group_keys, Some(&spec.alias))?;

        let mut json_parts: Vec<String> = Vec::with_capacity(group_keys.len() * 2 + 2);
        for (idx, key) in group_keys.iter().enumerate() {
            json_parts.push(format!("'{key}'"));
            json_parts.push(format!("group_value_{idx}"));
        }
        json_parts.push(format!("'{}'", spec.alias));
        json_parts.push("agg_value".to_string());

        format!(
            "SELECT jsonb_build_object({json_args}) AS result FROM ({inner}) t{order_sql} LIMIT {limit} OFFSET {offset}",
            json_args = json_parts.join(", "),
            inner = inner,
            order_sql = order_sql,
            limit = plan.limit,
            offset = plan.offset
        )
    } else {
        let inner = format!(
            "SELECT {agg_sql} AS agg_value FROM {from_table} f{join_sql}{where_sql}"
        );
        format!(
            "SELECT jsonb_build_object('{alias}', agg_value) AS result FROM ({inner}) t LIMIT 1",
            alias = spec.alias,
            inner = inner
        )
    };

    Ok(FlowGroupedStatsSql {
        sql: outer_sql,
        binds,
    })
}

fn build_stats_order_sql(
    plan: &QueryPlan,
    group_keys: &[&str],
    agg_alias: Option<&str>,
) -> Result<String> {
    if plan.order.is_empty() {
        // Default ordering for grouped stats: highest first.
        return Ok(if !group_keys.is_empty() {
            " ORDER BY agg_value DESC".to_string()
        } else {
            String::new()
        });
    }

    let mut parts: Vec<String> = Vec::new();
    for clause in &plan.order {
        let expr = if agg_alias.is_some_and(|a| clause.field == a) {
            "agg_value".to_string()
        } else if let Some(idx) = group_keys.iter().position(|k| *k == clause.field) {
            format!("group_value_{idx}")
        } else {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported order field for flows stats: '{}'",
                clause.field
            )));
        };

        let dir = if matches!(clause.direction, OrderDirection::Asc) {
            "ASC"
        } else {
            "DESC"
        };
        parts.push(format!("{expr} {dir}"));
    }

    Ok(format!(" ORDER BY {}", parts.join(", ")))
}

fn build_stats_text_filter(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<FlowSqlBindValue>,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(FlowSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(FlowSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("({column} IS NULL OR {column} <> ?)"))
        }
        FilterOp::Like => {
            binds.push(FlowSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(FlowSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("({column} IS NULL OR {column} NOT ILIKE ?)"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            binds.push(FlowSqlBindValue::TextArray(values));
            Ok(format!("{column} = ANY(?)"))
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            binds.push(FlowSqlBindValue::TextArray(values));
            Ok(format!("({column} IS NULL OR NOT ({column} = ANY(?)))"))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn build_stats_bigint_filter(
    column_expr: &str,
    filter: &Filter,
    binds: &mut Vec<FlowSqlBindValue>,
    label: &str,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            let value =
                filter.value.as_scalar()?.parse::<i64>().map_err(|_| {
                    ServiceError::InvalidRequest(format!("{label} must be an integer"))
                })?;
            binds.push(FlowSqlBindValue::Int(value));
            Ok(format!("{column_expr} = ?"))
        }
        FilterOp::NotEq => {
            let value =
                filter.value.as_scalar()?.parse::<i64>().map_err(|_| {
                    ServiceError::InvalidRequest(format!("{label} must be an integer"))
                })?;
            binds.push(FlowSqlBindValue::Int(value));
            Ok(format!("({column_expr} IS NULL OR {column_expr} <> ?)"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            let mut out: Vec<i64> = Vec::with_capacity(values.len());
            for v in values {
                out.push(v.parse::<i64>().map_err(|_| {
                    ServiceError::InvalidRequest(format!("{label} must be an integer"))
                })?);
            }
            binds.push(FlowSqlBindValue::IntArray(out));
            Ok(format!("{column_expr} = ANY(?)"))
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            let mut out: Vec<i64> = Vec::with_capacity(values.len());
            for v in values {
                out.push(v.parse::<i64>().map_err(|_| {
                    ServiceError::InvalidRequest(format!("{label} must be an integer"))
                })?);
            }
            binds.push(FlowSqlBindValue::IntArray(out));
            Ok(format!(
                "({column_expr} IS NULL OR NOT ({column_expr} = ANY(?)))"
            ))
        }
        FilterOp::Like | FilterOp::NotLike => {
            // Numeric-like filters are supported via ::text matching in the row query; keep that here too.
            binds.push(FlowSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            let text_expr = format!("{column_expr}::text");
            Ok(match filter.op {
                FilterOp::Like => format!("{text_expr} ILIKE ?"),
                FilterOp::NotLike => format!("({column_expr} IS NULL OR {text_expr} NOT ILIKE ?)"),
                _ => unreachable!(),
            })
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{label} filter does not support this operator"
        ))),
    }
}

fn build_stats_filter_clause(filter: &Filter, binds: &mut Vec<FlowSqlBindValue>) -> Result<String> {
    match filter.field.as_str() {
        "device_id" => flow_device_scope_expr(filter),
        "src_endpoint_ip" | "src_ip" => build_stats_text_filter("f.src_endpoint_ip", filter, binds),
        "dst_endpoint_ip" | "dst_ip" => build_stats_text_filter("f.dst_endpoint_ip", filter, binds),
        "protocol_name" => build_stats_text_filter("f.protocol_name", filter, binds),
        "sampler_address" => build_stats_text_filter("f.sampler_address", filter, binds),
        "flow_source" | "collector" => build_stats_text_filter(FLOW_SOURCE_EXPR, filter, binds),
        "exporter_name" => build_stats_text_filter(FLOW_EXPORTER_NAME_GROUP_EXPR, filter, binds),
        "in_if_name" => build_stats_text_filter(FLOW_IN_IF_NAME_GROUP_EXPR, filter, binds),
        "out_if_name" => build_stats_text_filter(FLOW_OUT_IF_NAME_GROUP_EXPR, filter, binds),
        "in_if_speed_bps" => {
            build_stats_text_filter(FLOW_IN_IF_SPEED_BPS_GROUP_EXPR, filter, binds)
        }
        "out_if_speed_bps" => {
            build_stats_text_filter(FLOW_OUT_IF_SPEED_BPS_GROUP_EXPR, filter, binds)
        }
        "protocol_group" | "proto_group" => {
            build_stats_text_filter(FLOW_PROTOCOL_GROUP_EXPR, filter, binds)
        }
        "protocol_num" | "proto" => {
            // protocol_num is int4; cast to bigint to keep bind typing consistent.
            build_stats_bigint_filter("f.protocol_num::bigint", filter, binds, "protocol_num")
        }
        "src_port" | "src_endpoint_port" => {
            build_stats_bigint_filter("f.src_endpoint_port::bigint", filter, binds, "src_port")
        }
        "dst_port" | "dst_endpoint_port" => {
            build_stats_bigint_filter("f.dst_endpoint_port::bigint", filter, binds, "dst_port")
        }
        "src_cidr" => {
            match filter.op {
                FilterOp::Eq | FilterOp::NotEq => {
                    let value = filter.value.as_scalar()?.to_string();
                    let cidr = normalize_cidr_literal(&value)?;
                    // Use binds in the stats query path (safe for user-supplied filters).
                    binds.push(FlowSqlBindValue::Text(cidr));
                    match filter.op {
                        FilterOp::Eq => {
                            Ok("(try_inet(NULLIF(f.src_endpoint_ip, '')) <<= ?::cidr)".to_string())
                        }
                        FilterOp::NotEq => Ok(
                            "(try_inet(NULLIF(f.src_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(f.src_endpoint_ip, '')) <<= ?::cidr))"
                                .to_string(),
                        ),
                        _ => unreachable!(),
                    }
                }
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?;
                    if values.is_empty() {
                        return Ok("1=1".to_string());
                    }
                    let mut out: Vec<String> = Vec::with_capacity(values.len());
                    for v in values {
                        out.push(normalize_cidr_literal(v)?);
                    }
                    binds.push(FlowSqlBindValue::TextArray(out));
                    match filter.op {
                        FilterOp::In => Ok(
                            "(try_inet(NULLIF(f.src_endpoint_ip, '')) <<= ANY(?::cidr[]))"
                                .to_string(),
                        ),
                        FilterOp::NotIn => Ok(
                            "(try_inet(NULLIF(f.src_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(f.src_endpoint_ip, '')) <<= ANY(?::cidr[])))"
                                .to_string(),
                        ),
                        _ => unreachable!(),
                    }
                }
                _ => Err(ServiceError::InvalidRequest(
                    "src_cidr filter only supports equality or list matching".into(),
                )),
            }
        }
        "dst_cidr" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.to_string();
                let cidr = normalize_cidr_literal(&value)?;
                binds.push(FlowSqlBindValue::Text(cidr));
                match filter.op {
                        FilterOp::Eq => Ok(
                            "(try_inet(NULLIF(f.dst_endpoint_ip, '')) <<= ?::cidr)".to_string(),
                        ),
                        FilterOp::NotEq => Ok(
                            "(try_inet(NULLIF(f.dst_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(f.dst_endpoint_ip, '')) <<= ?::cidr))"
                                .to_string(),
                        ),
                        _ => unreachable!(),
                    }
            }
            FilterOp::In | FilterOp::NotIn => {
                let values = filter.value.as_list()?;
                if values.is_empty() {
                    return Ok("1=1".to_string());
                }
                let mut out: Vec<String> = Vec::with_capacity(values.len());
                for v in values {
                    out.push(normalize_cidr_literal(v)?);
                }
                binds.push(FlowSqlBindValue::TextArray(out));
                match filter.op {
                        FilterOp::In => Ok(
                            "(try_inet(NULLIF(f.dst_endpoint_ip, '')) <<= ANY(?::cidr[]))"
                                .to_string(),
                        ),
                        FilterOp::NotIn => Ok(
                            "(try_inet(NULLIF(f.dst_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(f.dst_endpoint_ip, '')) <<= ANY(?::cidr[])))"
                                .to_string(),
                        ),
                        _ => unreachable!(),
                    }
            }
            _ => Err(ServiceError::InvalidRequest(
                "dst_cidr filter only supports equality or list matching".into(),
            )),
        },
        "direction" => {
            let expr = format!("({})", FLOW_DIRECTION_EXPR);
            build_stats_text_filter(&expr, filter, binds)
        }
        "app" => {
            let expr = format!("({})", FLOW_APP_EXPR);
            build_stats_text_filter(&expr, filter, binds)
        }
        "src_country_iso2" | "src_country" => {
            build_stats_text_filter("COALESCE(src_geo.country_iso2, 'Unknown')", filter, binds)
        }
        "dst_country_iso2" | "dst_country" => {
            build_stats_text_filter("COALESCE(dst_geo.country_iso2, 'Unknown')", filter, binds)
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for flows stats: '{other}'"
        ))),
    }
}

fn flow_device_scope_expr(filter: &Filter) -> Result<String> {
    let device_uid = normalize_device_uid_literal(filter.value.as_scalar()?)?;

    // Match flows for a device in two ways:
    // 1) exporter-owned flows (sampler -> exporter cache device_uid)
    // 2) endpoint flows (src/dst endpoint IP matches primary or active alias IPs)
    let base = format!(
        concat!(
            "(",
            "EXISTS (",
            "SELECT 1 FROM netflow_exporter_cache ec ",
            "WHERE ec.sampler_address = sampler_address ",
            "AND ec.device_uid = '{uid}'",
            ") ",
            "OR EXISTS (",
            "SELECT 1 FROM ocsf_devices d ",
            "WHERE d.uid = '{uid}' ",
            "AND d.ip IS NOT NULL AND d.ip <> '' ",
            "AND (src_endpoint_ip = d.ip OR dst_endpoint_ip = d.ip)",
            ") ",
            "OR EXISTS (",
            "SELECT 1 FROM device_alias_states das ",
            "WHERE das.device_id = '{uid}' ",
            "AND das.alias_type = 'ip' ",
            "AND das.state IN ('detected', 'confirmed', 'updated') ",
            "AND (src_endpoint_ip = das.alias_value OR dst_endpoint_ip = das.alias_value)",
            ")",
            ")"
        ),
        uid = device_uid
    );

    match filter.op {
        FilterOp::Eq => Ok(base),
        FilterOp::NotEq => Ok(format!("NOT ({base})")),
        _ => Err(ServiceError::InvalidRequest(
            "device_id filter only supports equality".into(),
        )),
    }
}

fn normalize_device_uid_literal(input: &str) -> Result<String> {
    let uid = input.trim();
    let valid = !uid.is_empty()
        && uid
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, ':' | '-' | '_' | '.'));

    if valid {
        Ok(uid.to_string())
    } else {
        Err(ServiceError::InvalidRequest(
            "device_id filter must be a canonical UID-like value".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn test_parse_stats_expr() {
        let expr = "sum(bytes_total) as total_bytes by src_endpoint_ip";
        let spec = parse_stats_expr(expr).unwrap();
        assert_eq!(spec.agg_func, FlowAggFunc::Sum);
        assert_eq!(spec.agg_field, FlowAggField::BytesTotal);
        assert_eq!(spec.alias, "total_bytes");
        assert_eq!(spec.group_by.len(), 1);
        assert_eq!(
            spec.group_by[0],
            FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp)
        );
    }

    #[test]
    fn test_parse_stats_expr_no_groupby() {
        let expr = "count(*) as total_flows";
        let spec = parse_stats_expr(expr).unwrap();
        assert_eq!(spec.agg_func, FlowAggFunc::Count);
        assert_eq!(spec.agg_field, FlowAggField::Star);
        assert_eq!(spec.alias, "total_flows");
        assert!(spec.group_by.is_empty());
    }

    #[test]
    fn parse_stats_expr_supports_cidr_group_by() {
        let expr = "sum(bytes_total) as total_bytes by src_cidr:24";
        let spec = parse_stats_expr(expr).unwrap();
        assert_eq!(spec.group_by.len(), 1);
        assert_eq!(spec.group_by[0], FlowGroupSpec::SrcCidr { prefix: 24 });
        assert_eq!(spec.group_by[0].response_key(), "src_cidr");
    }

    #[test]
    fn parse_stats_expr_supports_direction_group_by() {
        let expr = "count(*) as total_flows by direction";
        let spec = parse_stats_expr(expr).unwrap();
        assert_eq!(spec.group_by.len(), 1);
        assert_eq!(
            spec.group_by[0],
            FlowGroupSpec::Field(FlowGroupField::Direction)
        );
        assert_eq!(spec.group_by[0].response_key(), "direction");
    }

    #[test]
    fn parse_stats_expr_supports_app_group_by() {
        let expr = "sum(bytes_total) as total_bytes by app";
        let spec = parse_stats_expr(expr).unwrap();
        assert_eq!(spec.group_by.len(), 1);
        assert_eq!(spec.group_by[0], FlowGroupSpec::Field(FlowGroupField::App));
        assert_eq!(spec.group_by[0].response_key(), "app");
    }

    #[test]
    fn parse_stats_expr_supports_exporter_and_interface_group_by() {
        let expr = "count(*) as total_flows by exporter_name, in_if_name, out_if_name";
        let spec = parse_stats_expr(expr).unwrap();
        assert_eq!(spec.group_by.len(), 3);
        assert_eq!(
            spec.group_by[0],
            FlowGroupSpec::Field(FlowGroupField::ExporterName)
        );
        assert_eq!(
            spec.group_by[1],
            FlowGroupSpec::Field(FlowGroupField::InIfName)
        );
        assert_eq!(
            spec.group_by[2],
            FlowGroupSpec::Field(FlowGroupField::OutIfName)
        );
    }

    #[test]
    fn translate_grouped_stats_exporter_name_includes_cache_table() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);

        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "count(*) as total_flows by exporter_name",
            )),
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();
        assert!(
            sql.contains("netflow_exporter_cache"),
            "expected exporter cache in SQL, got: {sql}"
        );
    }

    #[test]
    fn translate_grouped_stats_in_if_name_includes_cache_table() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);

        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "count(*) as total_flows by in_if_name",
            )),
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();
        assert!(
            sql.contains("netflow_interface_cache"),
            "expected interface cache in SQL, got: {sql}"
        );
    }

    #[test]
    fn parse_stats_expr_supports_count_distinct() {
        let expr = "count_distinct(dst_endpoint_port) as unique_ports by src_endpoint_ip";
        let spec = parse_stats_expr(expr).unwrap();
        assert_eq!(spec.agg_func, FlowAggFunc::CountDistinct);
        assert_eq!(spec.agg_field, FlowAggField::DstEndpointPort);
        assert_eq!(spec.alias, "unique_ports");
        assert_eq!(spec.group_by.len(), 1);
        assert_eq!(
            spec.group_by[0],
            FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp)
        );
    }

    #[test]
    fn parse_stats_expr_supports_multi_group_by() {
        let expr = "sum(bytes_total) as total_bytes by src_cidr:24, dst_endpoint_port, dst_cidr:24";
        let spec = parse_stats_expr(expr).unwrap();
        assert_eq!(spec.group_by.len(), 3);
        assert_eq!(spec.group_by[0], FlowGroupSpec::SrcCidr { prefix: 24 });
        assert_eq!(
            spec.group_by[1],
            FlowGroupSpec::Field(FlowGroupField::DstEndpointPort)
        );
        assert_eq!(spec.group_by[2], FlowGroupSpec::DstCidr { prefix: 24 });
    }

    #[test]
    fn multi_group_by_requires_time_window() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: None,
            stats: Some(crate::parser::StatsSpec::from_raw(
                "sum(bytes_total) as total_bytes by src_endpoint_ip, dst_endpoint_ip",
            )),
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let err = to_sql_and_params_stats(&plan).unwrap_err();
        assert!(
            err.to_string().contains("require an explicit time window"),
            "expected time window guardrail error, got: {err}"
        );
    }

    #[test]
    fn translate_grouped_stats_uses_agg_value_for_order_and_includes_filters() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);

        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![
                Filter {
                    field: "src_ip".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("10.0.0.1".to_string()),
                },
                Filter {
                    field: "proto".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("6".to_string()),
                },
            ],
            order: vec![OrderClause {
                field: "total_bytes".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 10,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "sum(bytes_total) as total_bytes by src_endpoint_ip",
            )),
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let (sql, params) = to_sql_and_params_stats(&plan).unwrap();
        assert!(
            sql.contains("WHERE f.time >="),
            "should include time filter"
        );
        assert!(
            sql.contains("f.src_endpoint_ip = $3"),
            "should include src_endpoint_ip filter with binds"
        );
        assert!(
            sql.contains("f.protocol_num::bigint = $4"),
            "should include proto filter with binds"
        );
        assert!(
            sql.contains("ORDER BY agg_value DESC") || sql.contains("ORDER BY agg_value DESC"),
            "should order by agg_value, not JSON alias"
        );
        assert_eq!(params.len(), 4, "expected time + 2 filter binds");
    }

    #[test]
    fn translate_grouped_stats_app_group_by_includes_rule_table() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);

        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 10,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "sum(bytes_total) as total_bytes by app",
            )),
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();
        assert!(
            sql.contains("netflow_app_classification_rules"),
            "expected SQL to reference netflow_app_classification_rules for app derivation: {sql}"
        );
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "unknown_field".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("test".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let result = build_query(&plan);
        match result {
            Err(err) => {
                assert!(
                    err.to_string().contains("unsupported filter field"),
                    "error should mention unsupported filter field: {}",
                    err
                );
            }
            Ok(_) => panic!("expected error for unknown filter field"),
        }
    }

    #[test]
    fn builds_query_with_ip_filter() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "src_ip".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("10.0.0.1".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let result = build_query(&plan);
        assert!(result.is_ok(), "should build query with IP filter");
    }

    #[test]
    fn translate_device_id_filter_includes_exporter_and_alias_scope() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "device_id".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("sr:device-1".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let (sql, _params) = to_sql_and_params(&plan).expect("device filter should translate");
        assert!(
            sql.contains("netflow_exporter_cache"),
            "expected exporter scope in SQL: {sql}"
        );
        assert!(
            sql.contains("device_alias_states"),
            "expected alias scope in SQL: {sql}"
        );
        assert!(
            sql.contains("ocsf_devices"),
            "expected device IP scope in SQL: {sql}"
        );
    }

    #[test]
    fn translate_stats_device_id_filter_includes_exporter_and_alias_scope() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);

        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "device_id".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("sr:device-1".to_string()),
            }],
            order: Vec::new(),
            limit: 10,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "sum(bytes_total) as total_bytes by src_endpoint_ip",
            )),
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let (sql, _params) =
            to_sql_and_params_stats(&plan).expect("stats device filter should translate");
        assert!(
            sql.contains("netflow_exporter_cache"),
            "expected exporter scope in stats SQL: {sql}"
        );
        assert!(
            sql.contains("device_alias_states"),
            "expected alias scope in stats SQL: {sql}"
        );
        assert!(
            sql.contains("ocsf_devices"),
            "expected device IP scope in stats SQL: {sql}"
        );
    }

    #[test]
    fn builds_query_with_port_filter() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "dst_port".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("443".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let result = build_query(&plan);
        assert!(result.is_ok(), "should build query with port filter");
    }

    #[test]
    fn builds_query_with_wildcard_port_filter() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "dst_port".into(),
                op: FilterOp::Like,
                value: FilterValue::Scalar("%443%".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let result = build_query(&plan);
        assert!(
            result.is_ok(),
            "should build query with wildcard port filter"
        );
    }

    #[test]
    fn rejects_non_integer_port_with_eq() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "dst_port".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("abc".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let result = build_query(&plan);
        match result {
            Err(err) => assert!(
                err.to_string().contains("dst_port must be an integer"),
                "error should mention integer requirement: {}",
                err
            ),
            Ok(_) => panic!("expected error for non-integer port filter"),
        }
    }

    #[test]
    fn wildcard_port_filter_binds_text_param() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "dst_port".into(),
                op: FilterOp::Like,
                value: FilterValue::Scalar("%443%".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let (_, params) = to_sql_and_params(&plan).expect("should build SQL for wildcard port");
        let has_wildcard = params.iter().any(|param| match param {
            BindParam::Text(value) => value == "%443%",
            _ => false,
        });
        assert!(has_wildcard, "expected wildcard port to bind text param");
    }

    #[test]
    fn country_iso2_filter_does_not_shift_limit_offset_binds() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "dst_country_iso2".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("US".to_string()),
            }],
            order: vec![OrderClause {
                field: "time".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 5,
            offset: 0,
            time_range: Some(TimeRange {
                start: chrono::Utc::now() - chrono::Duration::hours(1),
                end: chrono::Utc::now(),
            }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let (sql, params) = to_sql_and_params(&plan).expect("should translate country filter");
        // Ensure we still have limit/offset binds present and typed correctly.
        assert!(sql.contains("LIMIT $3"), "expected LIMIT bind placeholder");
        assert!(
            sql.contains("OFFSET $4"),
            "expected OFFSET bind placeholder"
        );
        assert_eq!(params.len(), 4, "expected start/end + limit/offset params");
        assert!(matches!(params[2], BindParam::Int(5)));
        assert!(matches!(params[3], BindParam::Int(0)));
    }

    #[test]
    fn cidr_filter_does_not_shift_limit_offset_binds() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "src_cidr".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("192.168.0.0/16".to_string()),
            }],
            order: vec![OrderClause {
                field: "time".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 5,
            offset: 0,
            time_range: Some(TimeRange {
                start: chrono::Utc::now() - chrono::Duration::hours(1),
                end: chrono::Utc::now(),
            }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let (sql, params) = to_sql_and_params(&plan).expect("should translate cidr filter");
        assert!(sql.contains("LIMIT $3"), "expected LIMIT bind placeholder");
        assert!(
            sql.contains("OFFSET $4"),
            "expected OFFSET bind placeholder"
        );
        assert_eq!(params.len(), 4, "expected start/end + limit/offset params");
        assert!(matches!(params[2], BindParam::Int(5)));
        assert!(matches!(params[3], BindParam::Int(0)));
    }
}
