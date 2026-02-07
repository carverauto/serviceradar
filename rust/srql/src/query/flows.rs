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

// Directionality tagging for flows based on configured local CIDRs.
//
// NOTE: `netflow_local_cidrs` is stored under the `platform` schema, but SRQL
// typically runs with `search_path=platform,...`, so we intentionally omit the schema prefix.
const FLOW_DIRECTION_EXPR: &str = r#"
(SELECT
  CASE
    WHEN NULLIF(src_endpoint_ip, '') IS NULL OR NULLIF(dst_endpoint_ip, '') IS NULL THEN 'unknown'
    ELSE (
      CASE flags.mask
        WHEN 3 THEN 'internal'
        WHEN 2 THEN 'outbound'
        WHEN 1 THEN 'inbound'
        ELSE 'external'
      END
    )
  END
  FROM LATERAL (
    SELECT
      (
        CASE WHEN EXISTS (
          SELECT 1
          FROM netflow_local_cidrs c
          WHERE c.enabled
            AND (c.partition IS NULL OR c.partition = partition)
            AND (NULLIF(src_endpoint_ip, '')::inet <<= c.cidr)
        ) THEN 2 ELSE 0 END
      ) + (
        CASE WHEN EXISTS (
          SELECT 1
          FROM netflow_local_cidrs c
          WHERE c.enabled
            AND (c.partition IS NULL OR c.partition = partition)
            AND (NULLIF(dst_endpoint_ip, '')::inet <<= c.cidr)
        ) THEN 1 ELSE 0 END
      ) AS mask
  ) flags)
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
    tcp_flags: Option<i32>,
    bytes_total: i64,
    packets_total: i64,
    bytes_in: i64,
    bytes_out: i64,
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
                "(NULLIF(src_endpoint_ip, '')::inet <<= '{cidr}'::cidr)"
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
                "(NULLIF(dst_endpoint_ip, '')::inet <<= '{cidr}'::cidr)"
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
        "src_endpoint_ip" | "src_ip" | "dst_endpoint_ip" | "dst_ip" | "protocol_name"
        | "sampler_address" | "direction" => collect_text_params(params, filter),
        "src_country_iso2" | "src_country" | "dst_country_iso2" | "dst_country" => {
            collect_text_params(params, filter)
        }
        "src_cidr" | "dst_cidr" => collect_text_params(params, filter),
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

    query
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
    SamplerAddress,
    Direction,
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
            "sampler_address" => Some(Self::SamplerAddress),
            "direction" => Some(Self::Direction),
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
            Self::SamplerAddress => "sampler_address",
            Self::Direction => "direction",
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
            Self::SamplerAddress => "sampler_address",
            Self::Direction => FLOW_DIRECTION_EXPR,
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
                "COALESCE(set_masklen(NULLIF(src_endpoint_ip, '')::inet, {prefix})::text, 'Unknown')"
            ),
            Self::DstCidr { prefix } => format!(
                "COALESCE(set_masklen(NULLIF(dst_endpoint_ip, '')::inet, {prefix})::text, 'Unknown')"
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
    let group_by: Vec<FlowGroupSpec> = if let Some(by_idx) = parts.iter().position(|&p| p == "by")
    {
        let raw = parts
            .get(by_idx + 1..)
            .ok_or_else(|| ServiceError::InvalidRequest("stats expression missing group-by".into()))?
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

    let where_sql = if where_parts.is_empty() {
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

    let agg_sql = if matches!(spec.agg_func, FlowAggFunc::CountDistinct) {
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
            "SELECT {select_groups}, {agg_sql} AS agg_value FROM ocsf_network_activity f{join_sql}{where_sql} GROUP BY {group_by_sql}"
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
        let inner =
            format!("SELECT {agg_sql} AS agg_value FROM ocsf_network_activity f{join_sql}{where_sql}");
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
        "src_endpoint_ip" | "src_ip" => build_stats_text_filter("f.src_endpoint_ip", filter, binds),
        "dst_endpoint_ip" | "dst_ip" => build_stats_text_filter("f.dst_endpoint_ip", filter, binds),
        "protocol_name" => build_stats_text_filter("f.protocol_name", filter, binds),
        "sampler_address" => build_stats_text_filter("f.sampler_address", filter, binds),
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
                            Ok("(NULLIF(f.src_endpoint_ip, '')::inet <<= ?::cidr)".to_string())
                        }
                        FilterOp::NotEq => Ok(
                            "(NULLIF(f.src_endpoint_ip, '')::inet IS NULL OR NOT (NULLIF(f.src_endpoint_ip, '')::inet <<= ?::cidr))"
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
                            "(NULLIF(f.src_endpoint_ip, '')::inet <<= ANY(?::cidr[]))"
                                .to_string(),
                        ),
                        FilterOp::NotIn => Ok(
                            "(NULLIF(f.src_endpoint_ip, '')::inet IS NULL OR NOT (NULLIF(f.src_endpoint_ip, '')::inet <<= ANY(?::cidr[])))"
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
        "dst_cidr" => {
            match filter.op {
                FilterOp::Eq | FilterOp::NotEq => {
                    let value = filter.value.as_scalar()?.to_string();
                    let cidr = normalize_cidr_literal(&value)?;
                    binds.push(FlowSqlBindValue::Text(cidr));
                    match filter.op {
                        FilterOp::Eq => Ok(
                            "(NULLIF(f.dst_endpoint_ip, '')::inet <<= ?::cidr)".to_string(),
                        ),
                        FilterOp::NotEq => Ok(
                            "(NULLIF(f.dst_endpoint_ip, '')::inet IS NULL OR NOT (NULLIF(f.dst_endpoint_ip, '')::inet <<= ?::cidr))"
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
                            "(NULLIF(f.dst_endpoint_ip, '')::inet <<= ANY(?::cidr[]))"
                                .to_string(),
                        ),
                        FilterOp::NotIn => Ok(
                            "(NULLIF(f.dst_endpoint_ip, '')::inet IS NULL OR NOT (NULLIF(f.dst_endpoint_ip, '')::inet <<= ANY(?::cidr[])))"
                                .to_string(),
                        ),
                        _ => unreachable!(),
                    }
                }
                _ => Err(ServiceError::InvalidRequest(
                    "dst_cidr filter only supports equality or list matching".into(),
                )),
            }
        }
        "direction" => {
            let expr = format!("({})", FLOW_DIRECTION_EXPR);
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
        assert!(sql.contains("WHERE f.time >="), "should include time filter");
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
}
