//! Query execution for OCSF agents entity.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::AgentRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::ocsf_agents::dsl::{
        capabilities as col_capabilities, cert_expires_at as col_cert_expires_at,
        cert_fingerprint_sha256 as col_cert_fingerprint_sha256,
        cert_not_before as col_cert_not_before, cert_renewed_at as col_cert_renewed_at,
        cert_serial as col_cert_serial, config_source as col_config_source,
        created_time as col_created_time, desired_version as col_desired_version,
        first_seen_time as col_first_seen_time, gateway_id as col_gateway_id, host as col_host,
        ip as col_ip, last_seen_time as col_last_seen_time, last_update_at as col_last_update_at,
        last_update_error as col_last_update_error, modified_time as col_modified_time,
        name as col_name, ocsf_agents, release_rollout_state as col_release_rollout_state,
        status as col_status, superseded_at as col_superseded_at,
        superseded_by as col_superseded_by, type_id as col_type_id, uid as col_uid,
        vendor_name as col_vendor_name, version as col_version,
    },
    time::TimeRange,
};
use chrono::{DateTime, Duration as ChronoDuration, NaiveDate, NaiveDateTime, Utc};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type AgentsTable = crate::schema::ocsf_agents::table;
type AgentsFromClause = FromClause<AgentsTable>;
type AgentsQuery<'a> =
    BoxedSelectStatement<'a, <AgentsTable as AsQuery>::SqlType, AgentsFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<AgentRow> = query
        .select(AgentRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<AgentRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(AgentRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let now = Utc::now();
    let query = build_query_at(plan, now)?
        .limit(plan.limit)
        .offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

    let mut params = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params_at(&mut params, filter, now)?;
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
        Entity::Agents => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by agents query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<AgentsQuery<'static>> {
    build_query_at(plan, Utc::now())
}

fn build_query_at(plan: &QueryPlan, now: DateTime<Utc>) -> Result<AgentsQuery<'static>> {
    let mut query = ocsf_agents.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(
            col_last_seen_time
                .ge(*start)
                .and(col_last_seen_time.le(*end)),
        );
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter, now)?;
    }

    // A superseded identity stays in the table for history. Operational
    // `in:agents` leaves it out. include_deleted, or a filter on the lifecycle
    // columns, is how a caller asks for it.
    if !includes_superseded(plan) {
        query = query.filter(col_superseded_at.is_null());
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn includes_superseded(plan: &QueryPlan) -> bool {
    plan.include_deleted
        || plan.filters.iter().any(|filter| {
            let field = filter.field.to_ascii_lowercase();
            field == "status" || field == "superseded_by"
        })
}

fn apply_filter<'a>(
    mut query: AgentsQuery<'a>,
    filter: &Filter,
    now: DateTime<Utc>,
) -> Result<AgentsQuery<'a>> {
    match filter.field.as_str() {
        "uid" => {
            query = apply_text_filter!(query, filter, col_uid)?;
        }
        "name" => {
            query = apply_text_filter!(query, filter, col_name)?;
        }
        "gateway_id" => {
            query = apply_text_filter!(query, filter, col_gateway_id)?;
        }
        "host" => {
            query = apply_text_filter!(query, filter, col_host)?;
        }
        "version" => {
            query = apply_text_filter!(query, filter, col_version)?;
        }
        "vendor_name" => {
            query = apply_text_filter!(query, filter, col_vendor_name)?;
        }
        "ip" => {
            query = apply_text_filter!(query, filter, col_ip)?;
        }
        "type_id" => {
            let value =
                filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("type_id must be an integer".into())
                })?;
            query = apply_eq_filter!(
                query,
                filter,
                col_type_id,
                value,
                "type_id filter only supports equality"
            )?;
        }
        "capabilities" => {
            // Filter by capabilities using array overlap
            let values = match &filter.value {
                crate::parser::FilterValue::List(items) => items.clone(),
                crate::parser::FilterValue::Scalar(v) => vec![v.clone()],
            };
            if !values.is_empty() {
                match filter.op {
                    FilterOp::In | FilterOp::Eq => {
                        query = query.filter(col_capabilities.overlaps_with(values));
                    }
                    FilterOp::NotIn | FilterOp::NotEq => {
                        query =
                            query.filter(diesel::dsl::not(col_capabilities.overlaps_with(values)));
                    }
                    _ => {
                        return Err(ServiceError::InvalidRequest(
                            "capabilities filter only supports equality/containment".into(),
                        ));
                    }
                }
            }
        }
        "config_source" => {
            query = apply_text_filter!(query, filter, col_config_source)?;
        }
        "desired_version" => {
            query = apply_text_filter!(query, filter, col_desired_version)?;
        }
        "release_rollout_state" => {
            query = apply_text_filter!(query, filter, col_release_rollout_state)?;
        }
        "last_update_error" => {
            query = apply_text_filter!(query, filter, col_last_update_error)?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "superseded_by" => {
            query = apply_text_filter!(query, filter, col_superseded_by)?;
        }
        "cert_serial" | "cert_serial_number" => {
            query = apply_text_filter!(query, filter, col_cert_serial)?;
        }
        "cert_fingerprint_sha256" | "cert_fingerprint" => {
            query = apply_text_filter!(query, filter, col_cert_fingerprint_sha256)?;
        }
        "cert_expires_at" | "cert_not_after" => {
            let ts = parse_cert_timestamp_filter_value(filter.value.as_scalar()?, now)?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_cert_expires_at.eq(ts)),
                FilterOp::NotEq => query.filter(col_cert_expires_at.ne(ts)),
                FilterOp::Lt => query.filter(col_cert_expires_at.lt(ts)),
                FilterOp::Lte => query.filter(col_cert_expires_at.le(ts)),
                FilterOp::Gt => query.filter(col_cert_expires_at.gt(ts)),
                FilterOp::Gte => query.filter(col_cert_expires_at.ge(ts)),
                _ => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "unsupported operator for {}: {:?}",
                        filter.field, filter.op
                    )));
                }
            };
        }
        "cert_not_before" => {
            let ts = parse_cert_timestamp_filter_value(filter.value.as_scalar()?, now)?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_cert_not_before.eq(ts)),
                FilterOp::NotEq => query.filter(col_cert_not_before.ne(ts)),
                FilterOp::Lt => query.filter(col_cert_not_before.lt(ts)),
                FilterOp::Lte => query.filter(col_cert_not_before.le(ts)),
                FilterOp::Gt => query.filter(col_cert_not_before.gt(ts)),
                FilterOp::Gte => query.filter(col_cert_not_before.ge(ts)),
                _ => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "unsupported operator for cert_not_before: {:?}",
                        filter.op
                    )));
                }
            };
        }
        "cert_renewed_at" => {
            let ts = parse_cert_timestamp_filter_value(filter.value.as_scalar()?, now)?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_cert_renewed_at.eq(ts)),
                FilterOp::NotEq => query.filter(col_cert_renewed_at.ne(ts)),
                FilterOp::Lt => query.filter(col_cert_renewed_at.lt(ts)),
                FilterOp::Lte => query.filter(col_cert_renewed_at.le(ts)),
                FilterOp::Gt => query.filter(col_cert_renewed_at.gt(ts)),
                FilterOp::Gte => query.filter(col_cert_renewed_at.ge(ts)),
                _ => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "unsupported operator for cert_renewed_at: {:?}",
                        filter.op
                    )));
                }
            };
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for agents: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn parse_cert_timestamp_filter_value(raw: &str, now: DateTime<Utc>) -> Result<DateTime<Utc>> {
    let trimmed = raw.trim().trim_matches('"').trim_matches('\'');
    if trimmed.eq_ignore_ascii_case("now") {
        return Ok(now);
    }

    if let Some(dt) = parse_relative_duration_offset(trimmed, now)? {
        return Ok(dt);
    }

    if let Ok(dt) = DateTime::parse_from_rfc3339(trimmed) {
        return Ok(dt.with_timezone(&Utc));
    }

    if let Ok(dt) = NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%d %H:%M:%S") {
        return Ok(DateTime::<Utc>::from_naive_utc_and_offset(dt, Utc));
    }

    if let Ok(date) = NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
        && let Some(dt) = date.and_hms_opt(0, 0, 0)
    {
        return Ok(DateTime::<Utc>::from_naive_utc_and_offset(dt, Utc));
    }

    Err(ServiceError::InvalidRequest(format!(
        "invalid certificate timestamp or duration filter '{raw}'"
    )))
}

fn parse_relative_duration_offset(raw: &str, now: DateTime<Utc>) -> Result<Option<DateTime<Utc>>> {
    let (sign, rest) = if let Some(s) = raw.strip_prefix('-') {
        (-1i64, s)
    } else if let Some(s) = raw.strip_prefix('+') {
        (1i64, s)
    } else {
        (1i64, raw)
    };

    if rest.is_empty() || !rest.as_bytes()[0].is_ascii_digit() {
        return Ok(None);
    }

    // Avoid treating YYYY-MM-DD timestamps as relative durations
    if rest.contains('-') || rest.contains(':') {
        return Ok(None);
    }

    let digit_len = rest.chars().take_while(|ch| ch.is_ascii_digit()).count();
    let (digits, unit_raw) = rest.split_at(digit_len);
    let unit = unit_raw.trim().to_ascii_lowercase();
    if unit.is_empty() {
        return Ok(None);
    }

    let amount: i64 = digits
        .parse()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid duration value '{raw}'")))?;
    let signed_amount = amount.checked_mul(sign).ok_or_else(|| {
        ServiceError::InvalidRequest(format!("duration value '{raw}' is out of bounds"))
    })?;

    let duration = match unit.as_str() {
        "s" | "sec" | "secs" | "second" | "seconds" => ChronoDuration::try_seconds(signed_amount),
        "m" | "min" | "mins" | "minute" | "minutes" => ChronoDuration::try_minutes(signed_amount),
        "h" | "hr" | "hrs" | "hour" | "hours" => ChronoDuration::try_hours(signed_amount),
        "d" | "day" | "days" => ChronoDuration::try_days(signed_amount),
        "w" | "week" | "weeks" => signed_amount
            .checked_mul(7)
            .and_then(ChronoDuration::try_days),
        "y" | "year" | "years" => signed_amount
            .checked_mul(365)
            .and_then(ChronoDuration::try_days),
        _ => return Ok(None),
    }
    .ok_or_else(|| {
        ServiceError::InvalidRequest(format!("duration value '{raw}' is out of bounds"))
    })?;

    let target = now.checked_add_signed(duration).ok_or_else(|| {
        ServiceError::InvalidRequest(format!("duration value '{raw}' is out of bounds"))
    })?;

    Ok(Some(target))
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

fn collect_filter_params_at(
    params: &mut Vec<BindParam>,
    filter: &Filter,
    now: DateTime<Utc>,
) -> Result<()> {
    match filter.field.as_str() {
        "uid"
        | "name"
        | "gateway_id"
        | "host"
        | "version"
        | "vendor_name"
        | "ip"
        | "config_source"
        | "desired_version"
        | "release_rollout_state"
        | "last_update_error"
        | "status"
        | "superseded_by"
        | "cert_serial"
        | "cert_serial_number"
        | "cert_fingerprint_sha256"
        | "cert_fingerprint" => collect_text_params(params, filter),
        "cert_expires_at" | "cert_not_after" | "cert_not_before" | "cert_renewed_at" => {
            match filter.op {
                FilterOp::Eq
                | FilterOp::NotEq
                | FilterOp::Lt
                | FilterOp::Lte
                | FilterOp::Gt
                | FilterOp::Gte => {
                    let ts = parse_cert_timestamp_filter_value(filter.value.as_scalar()?, now)?;
                    params.push(BindParam::timestamptz(ts));
                    Ok(())
                }
                _ => Err(ServiceError::InvalidRequest(format!(
                    "unsupported operator for {}: {:?}",
                    filter.field, filter.op
                ))),
            }
        }
        "type_id" => {
            let value =
                filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("type_id must be an integer".into())
                })?;
            params.push(BindParam::Int(value as i64));
            Ok(())
        }
        "capabilities" => {
            let values = match &filter.value {
                crate::parser::FilterValue::List(items) => items.clone(),
                crate::parser::FilterValue::Scalar(v) => vec![v.clone()],
            };
            if !values.is_empty() {
                params.push(BindParam::TextArray(values));
            }
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(mut query: AgentsQuery<'a>, order: &[OrderClause]) -> AgentsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_single_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
    }

    if !applied {
        query = query.order(col_last_seen_time.desc());
    }

    query
}

fn apply_single_order<'a>(
    query: AgentsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> AgentsQuery<'a> {
    match field {
        "last_seen" | "last_seen_time" => match direction {
            OrderDirection::Asc => query.order(col_last_seen_time.asc()),
            OrderDirection::Desc => query.order(col_last_seen_time.desc()),
        },
        "first_seen" | "first_seen_time" => match direction {
            OrderDirection::Asc => query.order(col_first_seen_time.asc()),
            OrderDirection::Desc => query.order(col_first_seen_time.desc()),
        },
        "created_time" => match direction {
            OrderDirection::Asc => query.order(col_created_time.asc()),
            OrderDirection::Desc => query.order(col_created_time.desc()),
        },
        "modified_time" => match direction {
            OrderDirection::Asc => query.order(col_modified_time.asc()),
            OrderDirection::Desc => query.order(col_modified_time.desc()),
        },
        "uid" => match direction {
            OrderDirection::Asc => query.order(col_uid.asc()),
            OrderDirection::Desc => query.order(col_uid.desc()),
        },
        "name" => match direction {
            OrderDirection::Asc => query.order(col_name.asc()),
            OrderDirection::Desc => query.order(col_name.desc()),
        },
        "type_id" => match direction {
            OrderDirection::Asc => query.order(col_type_id.asc()),
            OrderDirection::Desc => query.order(col_type_id.desc()),
        },
        "gateway_id" => match direction {
            OrderDirection::Asc => query.order(col_gateway_id.asc()),
            OrderDirection::Desc => query.order(col_gateway_id.desc()),
        },
        "host" => match direction {
            OrderDirection::Asc => query.order(col_host.asc()),
            OrderDirection::Desc => query.order(col_host.desc()),
        },
        "ip" => match direction {
            OrderDirection::Asc => query.order(col_ip.asc()),
            OrderDirection::Desc => query.order(col_ip.desc()),
        },
        "desired_version" => match direction {
            OrderDirection::Asc => query.order(col_desired_version.asc()),
            OrderDirection::Desc => query.order(col_desired_version.desc()),
        },
        "release_rollout_state" => match direction {
            OrderDirection::Asc => query.order(col_release_rollout_state.asc()),
            OrderDirection::Desc => query.order(col_release_rollout_state.desc()),
        },
        "last_update_at" => match direction {
            OrderDirection::Asc => query.order(col_last_update_at.asc()),
            OrderDirection::Desc => query.order(col_last_update_at.desc()),
        },
        "cert_expires_at" | "cert_not_after" => match direction {
            OrderDirection::Asc => query.order(col_cert_expires_at.asc()),
            OrderDirection::Desc => query.order(col_cert_expires_at.desc()),
        },
        "cert_not_before" => match direction {
            OrderDirection::Asc => query.order(col_cert_not_before.asc()),
            OrderDirection::Desc => query.order(col_cert_not_before.desc()),
        },
        "cert_renewed_at" => match direction {
            OrderDirection::Asc => query.order(col_cert_renewed_at.asc()),
            OrderDirection::Desc => query.order(col_cert_renewed_at.desc()),
        },
        "cert_serial" | "cert_serial_number" => match direction {
            OrderDirection::Asc => query.order(col_cert_serial.asc()),
            OrderDirection::Desc => query.order(col_cert_serial.desc()),
        },
        "cert_fingerprint_sha256" | "cert_fingerprint" => match direction {
            OrderDirection::Asc => query.order(col_cert_fingerprint_sha256.asc()),
            OrderDirection::Desc => query.order(col_cert_fingerprint_sha256.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: AgentsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> AgentsQuery<'a> {
    match field {
        "last_seen" | "last_seen_time" => match direction {
            OrderDirection::Asc => query.then_order_by(col_last_seen_time.asc()),
            OrderDirection::Desc => query.then_order_by(col_last_seen_time.desc()),
        },
        "first_seen" | "first_seen_time" => match direction {
            OrderDirection::Asc => query.then_order_by(col_first_seen_time.asc()),
            OrderDirection::Desc => query.then_order_by(col_first_seen_time.desc()),
        },
        "created_time" => match direction {
            OrderDirection::Asc => query.then_order_by(col_created_time.asc()),
            OrderDirection::Desc => query.then_order_by(col_created_time.desc()),
        },
        "modified_time" => match direction {
            OrderDirection::Asc => query.then_order_by(col_modified_time.asc()),
            OrderDirection::Desc => query.then_order_by(col_modified_time.desc()),
        },
        "uid" => match direction {
            OrderDirection::Asc => query.then_order_by(col_uid.asc()),
            OrderDirection::Desc => query.then_order_by(col_uid.desc()),
        },
        "name" => match direction {
            OrderDirection::Asc => query.then_order_by(col_name.asc()),
            OrderDirection::Desc => query.then_order_by(col_name.desc()),
        },
        "type_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_type_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_type_id.desc()),
        },
        "gateway_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_gateway_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_gateway_id.desc()),
        },
        "host" => match direction {
            OrderDirection::Asc => query.then_order_by(col_host.asc()),
            OrderDirection::Desc => query.then_order_by(col_host.desc()),
        },
        "ip" => match direction {
            OrderDirection::Asc => query.then_order_by(col_ip.asc()),
            OrderDirection::Desc => query.then_order_by(col_ip.desc()),
        },
        "desired_version" => match direction {
            OrderDirection::Asc => query.then_order_by(col_desired_version.asc()),
            OrderDirection::Desc => query.then_order_by(col_desired_version.desc()),
        },
        "release_rollout_state" => match direction {
            OrderDirection::Asc => query.then_order_by(col_release_rollout_state.asc()),
            OrderDirection::Desc => query.then_order_by(col_release_rollout_state.desc()),
        },
        "last_update_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_last_update_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_last_update_at.desc()),
        },
        "cert_expires_at" | "cert_not_after" => match direction {
            OrderDirection::Asc => query.then_order_by(col_cert_expires_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_cert_expires_at.desc()),
        },
        "cert_not_before" => match direction {
            OrderDirection::Asc => query.then_order_by(col_cert_not_before.asc()),
            OrderDirection::Desc => query.then_order_by(col_cert_not_before.desc()),
        },
        "cert_renewed_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_cert_renewed_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_cert_renewed_at.desc()),
        },
        "cert_serial" | "cert_serial_number" => match direction {
            OrderDirection::Asc => query.then_order_by(col_cert_serial.asc()),
            OrderDirection::Desc => query.then_order_by(col_cert_serial.desc()),
        },
        "cert_fingerprint_sha256" | "cert_fingerprint" => match direction {
            OrderDirection::Asc => query.then_order_by(col_cert_fingerprint_sha256.asc()),
            OrderDirection::Desc => query.then_order_by(col_cert_fingerprint_sha256.desc()),
        },
        _ => query,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn unknown_filter_field_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        let plan = QueryPlan {
            entity: Entity::Agents,
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
            other: false,
            include_deleted: false,
            exhaustive_window: false,
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
    fn builds_query_with_gateway_filter() {
        let plan = QueryPlan {
            entity: Entity::Agents,
            filters: vec![Filter {
                field: "gateway_id".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("gateway-1".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
            exhaustive_window: false,
        };

        let result = build_query(&plan);
        assert!(result.is_ok(), "should build query with gateway filter");
    }

    #[test]
    fn builds_query_with_host_and_ip_filters() {
        for field in ["host", "ip"] {
            let plan = QueryPlan {
                entity: Entity::Agents,
                filters: vec![Filter {
                    field: field.into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("agent-sr-test-pve04".to_string()),
                }],
                order: Vec::new(),
                limit: 50,
                offset: 0,
                time_range: None,
                stats: None,
                downsample: None,
                rollup_stats: None,
                other: false,
                include_deleted: false,
                exhaustive_window: false,
            };

            let result = build_query(&plan);
            assert!(result.is_ok(), "should build query with {field} filter");
        }
    }

    #[test]
    fn builds_query_with_type_id_filter() {
        let plan = QueryPlan {
            entity: Entity::Agents,
            filters: vec![Filter {
                field: "type_id".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("4".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
            exhaustive_window: false,
        };

        let result = build_query(&plan);
        assert!(result.is_ok(), "should build query with type_id filter");
    }

    #[test]
    fn builds_query_with_config_source_filter() {
        let plan = QueryPlan {
            entity: Entity::Agents,
            filters: vec![Filter {
                field: "config_source".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("remote".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
            exhaustive_window: false,
        };

        let result = build_query(&plan);
        assert!(
            result.is_ok(),
            "should build query with config_source filter"
        );
    }

    #[test]
    fn builds_query_with_config_source_in_filter() {
        let plan = QueryPlan {
            entity: Entity::Agents,
            filters: vec![Filter {
                field: "config_source".into(),
                op: FilterOp::In,
                value: FilterValue::List(vec!["remote".to_string(), "local".to_string()]),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
            exhaustive_window: false,
        };

        let result = build_query(&plan);
        assert!(
            result.is_ok(),
            "should build query with config_source IN filter"
        );
    }

    #[test]
    fn builds_query_with_release_rollout_state_filter() {
        let plan = QueryPlan {
            entity: Entity::Agents,
            filters: vec![Filter {
                field: "release_rollout_state".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("staged".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
            exhaustive_window: false,
        };

        let result = build_query(&plan);
        assert!(
            result.is_ok(),
            "should build query with release_rollout_state filter"
        );
    }

    fn agent_plan(filters: Vec<Filter>, include_deleted: bool) -> QueryPlan {
        QueryPlan {
            entity: Entity::Agents,
            filters,
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted,
            exhaustive_window: false,
        }
    }

    fn eq_filter(field: &str, value: &str) -> Filter {
        Filter {
            field: field.into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar(value.to_string()),
        }
    }

    #[test]
    fn default_agent_query_excludes_superseded_identities() {
        let plan = agent_plan(Vec::new(), false);
        let (sql, params) = to_sql_and_params(&plan).expect("default agent query");

        assert!(
            sql.contains("\"superseded_at\" IS NULL"),
            "default query should exclude superseded rows: {sql}"
        );
        assert_eq!(
            params.len(),
            2,
            "only limit and offset are bound: {params:?}"
        );
    }

    #[test]
    fn host_filter_keeps_the_superseded_exclusion() {
        let plan = agent_plan(vec![eq_filter("host", "host01.example.com")], false);
        let (sql, params) = to_sql_and_params(&plan).expect("host filter");

        assert!(
            sql.contains("\"superseded_at\" IS NULL"),
            "a host filter is not a request for superseded rows: {sql}"
        );
        assert_eq!(
            params.len(),
            3,
            "host value plus limit and offset: {params:?}"
        );
    }

    #[test]
    fn include_deleted_and_lifecycle_filters_return_superseded_identities() {
        let included = agent_plan(Vec::new(), true);
        let (sql, params) = to_sql_and_params(&included).expect("include_deleted");
        assert!(
            !sql.contains("\"superseded_at\" IS NULL"),
            "include_deleted lifts the exclusion: {sql}"
        );
        assert_eq!(params.len(), 2);

        for field in ["status", "superseded_by"] {
            let plan = agent_plan(vec![eq_filter(field, "agent-new")], false);
            let (sql, params) = to_sql_and_params(&plan).expect(field);
            assert!(
                !sql.contains("\"superseded_at\" IS NULL"),
                "{field} filter lifts the exclusion: {sql}"
            );
            assert_eq!(params.len(), 3, "{field} binds its value: {params:?}");
        }
    }

    #[test]
    fn agent_query_selects_operator_label_and_note() {
        // The agent list and detail pages read `in:agents`. The row has to carry
        // the operator label and note, or those pages fall back to the gateway name.
        let plan = agent_plan(Vec::new(), true);
        let (sql, _params) = to_sql_and_params(&plan).expect("agent query");

        assert!(
            sql.contains("\"display_name\""),
            "in:agents must select the operator label: {sql}"
        );
        assert!(
            sql.contains("\"description\""),
            "in:agents must select the operator note: {sql}"
        );
    }

    #[test]
    fn agent_row_json_returns_operator_label_and_note() {
        let seen = chrono::TimeZone::with_ymd_and_hms(&chrono::Utc, 2026, 10, 22, 17, 11, 46)
            .single()
            .expect("timestamp");
        let expires = seen + ChronoDuration::days(90);
        let row = AgentRow {
            uid: "agent-1".into(),
            name: Some("Gateway Reported".into()),
            type_id: 0,
            agent_type: None,
            version: None,
            vendor_name: None,
            uid_alt: None,
            policies: None,
            gateway_id: None,
            capabilities: None,
            host: Some("192.0.2.10".into()),
            ip: None,
            first_seen_time: None,
            last_seen_time: Some(seen),
            created_time: seen,
            modified_time: seen,
            metadata: None,
            config_source: None,
            desired_version: None,
            release_rollout_state: None,
            last_update_at: None,
            last_update_error: None,
            status: "connected".into(),
            superseded_by: None,
            superseded_at: None,
            display_name: Some("North Sensor".into()),
            description: Some("Synthetic lab note".into()),
            cert_not_before: Some(seen),
            cert_expires_at: Some(expires),
            cert_serial: Some("01a2b3".into()),
            cert_fingerprint_sha256: Some("a".repeat(64)),
            cert_renewed_at: Some(seen),
        };

        let json = row.into_json();

        assert_eq!(json["uid"], "agent-1");
        assert_eq!(json["name"], "Gateway Reported");
        assert_eq!(json["display_name"], "North Sensor");
        assert_eq!(json["description"], "Synthetic lab note");
        assert_eq!(json["cert_serial"], "01a2b3");
        assert_eq!(json["cert_fingerprint_sha256"], "a".repeat(64));
        assert!(json["cert_not_before"].is_string());
        assert!(json["cert_expires_at"].is_string());
        assert!(json["cert_renewed_at"].is_string());
    }

    #[test]
    fn builds_query_with_certificate_expiry_relative_duration_and_serial_filters() {
        for duration in ["7d", "0d", "14d", "-1d"] {
            let plan = agent_plan(
                vec![Filter {
                    field: "cert_expires_at".into(),
                    op: FilterOp::Lt,
                    value: FilterValue::Scalar(duration.to_string()),
                }],
                false,
            );
            let (sql, params) =
                to_sql_and_params(&plan).expect("cert_expires_at relative duration query");
            assert!(
                sql.contains("\"cert_expires_at\" <"),
                "expected cert_expires_at < comparison in SQL: {sql}"
            );
            assert!(
                sql.contains("\"superseded_at\" IS NULL"),
                "expected superseded exclusion in SQL: {sql}"
            );
            assert_eq!(
                params.len(),
                3,
                "cert_expires_at timestamp plus limit and offset"
            );
        }

        let mut serial_plan = agent_plan(
            vec![
                eq_filter("cert_serial", "01a2b3c4"),
                eq_filter("cert_fingerprint_sha256", &"b".repeat(64)),
            ],
            false,
        );
        serial_plan.order = vec![OrderClause {
            field: "cert_expires_at".into(),
            direction: OrderDirection::Asc,
        }];
        let (sql, params) = to_sql_and_params(&serial_plan).expect("cert_serial query");
        assert!(
            sql.contains("\"cert_serial\" ="),
            "expected cert_serial = comparison in SQL: {sql}"
        );
        assert!(
            sql.contains("\"cert_fingerprint_sha256\" ="),
            "expected cert_fingerprint_sha256 = comparison in SQL: {sql}"
        );
        assert!(
            sql.contains("ORDER BY \"ocsf_agents\".\"cert_expires_at\" ASC"),
            "expected ORDER BY cert_expires_at ASC in SQL: {sql}"
        );
        assert_eq!(params.len(), 4);
    }
}
