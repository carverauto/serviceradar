use super::filters_common::{NumericComparison, NumericKind, NumericValue};
use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::MtrTraceRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::mtr_traces::dsl::{
        agent_id as col_agent_id, check_name as col_check_name, created_at as col_created_at,
        device_id as col_device_id, error as col_error, id as col_id, mtr_traces,
        protocol as col_protocol, target as col_target, target_ip as col_target_ip,
        target_reached as col_target_reached, tcp_ack_mismatch as col_tcp_ack_mismatch,
        tcp_answered_after_retx as col_tcp_answered_after_retx,
        tcp_handshake_attempts as col_tcp_handshake_attempts,
        tcp_handshake_rtt_avg_us as col_tcp_handshake_rtt_avg_us,
        tcp_handshake_rtt_max_us as col_tcp_handshake_rtt_max_us,
        tcp_handshake_rtt_min_us as col_tcp_handshake_rtt_min_us,
        tcp_handshake_ttl as col_tcp_handshake_ttl, tcp_rst_received as col_tcp_rst_received,
        tcp_server_response_us as col_tcp_server_response_us,
        tcp_syn_drop_pct as col_tcp_syn_drop_pct, tcp_syn_retransmits as col_tcp_syn_retransmits,
        tcp_syn_sent as col_tcp_syn_sent, tcp_syn_unanswered as col_tcp_syn_unanswered,
        tcp_synack_duplicates as col_tcp_synack_duplicates,
        tcp_synack_received as col_tcp_synack_received, time as col_time,
        total_hops as col_total_hops,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type MtrTracesTable = crate::schema::mtr_traces::table;
type MtrTracesFromClause = FromClause<MtrTracesTable>;
type MtrTracesQuery<'a> =
    BoxedSelectStatement<'a, <MtrTracesTable as AsQuery>::SqlType, MtrTracesFromClause, Pg>;

/// TCP SYN handshake diagnostics, filterable with equality and ordered
/// comparisons and aggregatable in `stats:`.
///
/// Every column is nullable, and NULL means "not reported": an older agent, or a
/// trace that did not run the raw SYN handshake (a non-TCP protocol, or the
/// connect() fallback). NULL fails every comparison, so `tcp_syn_drop_pct:>=0`
/// is how a caller restricts a query to traces that measured a handshake.
pub(crate) const TRACE_HANDSHAKE_FIELDS: &[(&str, NumericKind)] = &[
    ("tcp_handshake_ttl", NumericKind::Int4),
    ("tcp_handshake_attempts", NumericKind::Int4),
    ("tcp_syn_sent", NumericKind::Int4),
    ("tcp_synack_received", NumericKind::Int4),
    ("tcp_rst_received", NumericKind::Int4),
    ("tcp_syn_unanswered", NumericKind::Int4),
    ("tcp_syn_drop_pct", NumericKind::Float8),
    ("tcp_syn_retransmits", NumericKind::Int4),
    ("tcp_answered_after_retx", NumericKind::Int4),
    ("tcp_ack_mismatch", NumericKind::Int4),
    ("tcp_synack_duplicates", NumericKind::Int4),
    ("tcp_handshake_rtt_min_us", NumericKind::Int8),
    ("tcp_handshake_rtt_avg_us", NumericKind::Int8),
    ("tcp_handshake_rtt_max_us", NumericKind::Int8),
    ("tcp_server_response_us", NumericKind::Int8),
];

/// Resolves a handshake filter to its column name and a parsed comparison, or
/// `None` when the field is not a handshake column.
pub(crate) fn handshake_comparison(
    filter: &Filter,
) -> Result<Option<(&'static str, NumericComparison)>> {
    TRACE_HANDSHAKE_FIELDS
        .iter()
        .find(|(name, _)| *name == filter.field)
        .map(|&(name, kind)| Ok((name, NumericComparison::parse(filter, kind)?)))
        .transpose()
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;

    if let Some(stats) = &plan.stats {
        let sql = build_stats_sql(plan, stats.as_raw())?;
        return execute_stats(conn, &sql).await;
    }

    let query = build_query(plan)?;
    let rows: Vec<MtrTraceRow> = query
        .select(MtrTraceRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<MtrTraceRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(MtrTraceRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(stats) = &plan.stats {
        let sql = build_stats_sql(plan, stats.as_raw())?;
        let params = sql.binds.into_iter().map(bind_param_from_trace).collect();
        return Ok((rewrite_placeholders(&sql.sql), params));
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
        Entity::MtrTraces => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by mtr_traces query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<MtrTracesQuery<'static>> {
    let mut query = mtr_traces.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_time.ge(*start).and(col_time.lt(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    apply_ordering(query, &plan.order)
}

fn apply_filter<'a>(mut query: MtrTracesQuery<'a>, filter: &Filter) -> Result<MtrTracesQuery<'a>> {
    match filter.field.as_str() {
        "target" => query = apply_text_filter!(query, filter, col_target)?,
        "target_ip" => query = apply_text_filter!(query, filter, col_target_ip)?,
        "agent_id" => query = apply_text_filter!(query, filter, col_agent_id)?,
        "protocol" => query = apply_text_filter!(query, filter, col_protocol)?,
        "check_name" => query = apply_text_filter!(query, filter, col_check_name)?,
        "device_id" => query = apply_text_filter!(query, filter, col_device_id)?,
        "error" => query = apply_text_filter!(query, filter, col_error)?,
        "target_reached" => query = apply_target_reached_filter(query, filter)?,
        other => match handshake_comparison(filter)? {
            Some((_, comparison)) => {
                query = apply_handshake_filter(query, filter, comparison.value)?;
            }
            None => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported filter field for mtr_traces: '{other}'"
                )));
            }
        },
    }

    Ok(query)
}

fn apply_handshake_filter<'a>(
    query: MtrTracesQuery<'a>,
    filter: &Filter,
    value: NumericValue,
) -> Result<MtrTracesQuery<'a>> {
    use NumericValue::{Float8, Int4, Int8};

    match (filter.field.as_str(), value) {
        ("tcp_handshake_ttl", Int4(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_handshake_ttl, v)
        }
        ("tcp_handshake_attempts", Int4(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_handshake_attempts, v)
        }
        ("tcp_syn_sent", Int4(v)) => apply_ordered_filter!(query, filter, col_tcp_syn_sent, v),
        ("tcp_synack_received", Int4(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_synack_received, v)
        }
        ("tcp_rst_received", Int4(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_rst_received, v)
        }
        ("tcp_syn_unanswered", Int4(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_syn_unanswered, v)
        }
        ("tcp_syn_drop_pct", Float8(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_syn_drop_pct, v)
        }
        ("tcp_syn_retransmits", Int4(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_syn_retransmits, v)
        }
        ("tcp_answered_after_retx", Int4(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_answered_after_retx, v)
        }
        ("tcp_ack_mismatch", Int4(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_ack_mismatch, v)
        }
        ("tcp_synack_duplicates", Int4(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_synack_duplicates, v)
        }
        ("tcp_handshake_rtt_min_us", Int8(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_handshake_rtt_min_us, v)
        }
        ("tcp_handshake_rtt_avg_us", Int8(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_handshake_rtt_avg_us, v)
        }
        ("tcp_handshake_rtt_max_us", Int8(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_handshake_rtt_max_us, v)
        }
        ("tcp_server_response_us", Int8(v)) => {
            apply_ordered_filter!(query, filter, col_tcp_server_response_us, v)
        }
        (other, value) => Err(ServiceError::Internal(anyhow::anyhow!(
            "TRACE_HANDSHAKE_FIELDS maps '{other}' to {value:?}, which has no column binding"
        ))),
    }
}

fn apply_target_reached_filter<'a>(
    query: MtrTracesQuery<'a>,
    filter: &Filter,
) -> Result<MtrTracesQuery<'a>> {
    let value = parse_bool(filter.value.as_scalar()?)?;
    match filter.op {
        FilterOp::Eq => Ok(query.filter(col_target_reached.eq(value))),
        FilterOp::NotEq => Ok(query.filter(col_target_reached.ne(value))),
        _ => Err(ServiceError::InvalidRequest(
            "target_reached only supports equality comparisons".into(),
        )),
    }
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if !values.is_empty() {
                params.push(BindParam::TextArray(values));
            }
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
        "target" | "target_ip" | "agent_id" | "protocol" | "check_name" | "device_id" | "error" => {
            collect_text_params(params, filter)
        }
        "target_reached" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => match handshake_comparison(filter)? {
            Some((_, comparison)) => {
                params.push(comparison.value.bind_param());
                Ok(())
            }
            None => Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for mtr_traces: '{other}'"
            ))),
        },
    }
}

pub(crate) fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "t" | "yes" | "y" | "1" => Ok(true),
        "false" | "f" | "no" | "n" | "0" => Ok(false),
        other => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: MtrTracesQuery<'a>,
    order: &[OrderClause],
) -> Result<MtrTracesQuery<'a>> {
    if order.is_empty() {
        return Ok(query.order(col_time.desc()).then_order_by(col_id.desc()));
    }

    for (index, clause) in order.iter().enumerate() {
        query = if index == 0 {
            apply_primary_order(query, clause)?
        } else {
            apply_secondary_order(query, clause)?
        };
    }

    let tie_direction = order
        .iter()
        .find(|clause| matches!(clause.field.as_str(), "time" | "timestamp"))
        .map(|clause| clause.direction)
        .unwrap_or(order[0].direction);
    let has_time_order = order
        .iter()
        .any(|clause| matches!(clause.field.as_str(), "time" | "timestamp"));

    if !has_time_order {
        query = match tie_direction {
            OrderDirection::Asc => query.then_order_by(col_time.asc()),
            OrderDirection::Desc => query.then_order_by(col_time.desc()),
        };
    }

    query = match tie_direction {
        OrderDirection::Asc => query.then_order_by(col_id.asc()),
        OrderDirection::Desc => query.then_order_by(col_id.desc()),
    };

    Ok(query)
}

fn apply_primary_order<'a>(
    query: MtrTracesQuery<'a>,
    clause: &OrderClause,
) -> Result<MtrTracesQuery<'a>> {
    let query = match clause.field.as_str() {
        "time" | "timestamp" => match clause.direction {
            OrderDirection::Asc => query.order(col_time.asc()),
            OrderDirection::Desc => query.order(col_time.desc()),
        },
        "target" => match clause.direction {
            OrderDirection::Asc => query.order(col_target.asc()),
            OrderDirection::Desc => query.order(col_target.desc()),
        },
        "target_ip" => match clause.direction {
            OrderDirection::Asc => query.order(col_target_ip.asc()),
            OrderDirection::Desc => query.order(col_target_ip.desc()),
        },
        "agent_id" => match clause.direction {
            OrderDirection::Asc => query.order(col_agent_id.asc()),
            OrderDirection::Desc => query.order(col_agent_id.desc()),
        },
        "protocol" => match clause.direction {
            OrderDirection::Asc => query.order(col_protocol.asc()),
            OrderDirection::Desc => query.order(col_protocol.desc()),
        },
        "check_name" => match clause.direction {
            OrderDirection::Asc => query.order(col_check_name.asc()),
            OrderDirection::Desc => query.order(col_check_name.desc()),
        },
        "device_id" => match clause.direction {
            OrderDirection::Asc => query.order(col_device_id.asc()),
            OrderDirection::Desc => query.order(col_device_id.desc()),
        },
        "error" => match clause.direction {
            OrderDirection::Asc => query.order(col_error.asc()),
            OrderDirection::Desc => query.order(col_error.desc()),
        },
        "target_reached" => match clause.direction {
            OrderDirection::Asc => query.order(col_target_reached.asc()),
            OrderDirection::Desc => query.order(col_target_reached.desc()),
        },
        "total_hops" => match clause.direction {
            OrderDirection::Asc => query.order(col_total_hops.asc()),
            OrderDirection::Desc => query.order(col_total_hops.desc()),
        },
        "created_at" => match clause.direction {
            OrderDirection::Asc => query.order(col_created_at.asc()),
            OrderDirection::Desc => query.order(col_created_at.desc()),
        },
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported sort field for mtr_traces: '{other}'"
            )));
        }
    };

    Ok(query)
}

fn apply_secondary_order<'a>(
    query: MtrTracesQuery<'a>,
    clause: &OrderClause,
) -> Result<MtrTracesQuery<'a>> {
    let query = match clause.field.as_str() {
        "time" | "timestamp" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_time.asc()),
            OrderDirection::Desc => query.then_order_by(col_time.desc()),
        },
        "target" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_target.asc()),
            OrderDirection::Desc => query.then_order_by(col_target.desc()),
        },
        "target_ip" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_target_ip.asc()),
            OrderDirection::Desc => query.then_order_by(col_target_ip.desc()),
        },
        "agent_id" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_agent_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_agent_id.desc()),
        },
        "protocol" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_protocol.asc()),
            OrderDirection::Desc => query.then_order_by(col_protocol.desc()),
        },
        "check_name" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_check_name.asc()),
            OrderDirection::Desc => query.then_order_by(col_check_name.desc()),
        },
        "device_id" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_device_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_device_id.desc()),
        },
        "error" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_error.asc()),
            OrderDirection::Desc => query.then_order_by(col_error.desc()),
        },
        "target_reached" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_target_reached.asc()),
            OrderDirection::Desc => query.then_order_by(col_target_reached.desc()),
        },
        "total_hops" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_total_hops.asc()),
            OrderDirection::Desc => query.then_order_by(col_total_hops.desc()),
        },
        "created_at" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_created_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_created_at.desc()),
        },
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported sort field for mtr_traces: '{other}'"
            )));
        }
    };

    Ok(query)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parser::parse, query::build_query_plan};
    use std::sync::Arc;

    fn plan_for(query: &str) -> QueryPlan {
        let config = Arc::new(crate::config::AppConfig::embedded(
            "postgres://localhost/serviceradar".to_string(),
        ));
        let request = crate::query::QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: crate::query::QueryDirection::Next,
            mode: None,
        };
        let ast = parse(query).expect("query should parse");
        build_query_plan(config.as_ref(), &request, ast).expect("query plan should build")
    }

    fn where_predicates(sql: &str) -> &str {
        let (_, predicates_and_ordering) = sql
            .split_once(" where ")
            .expect("filtered SQL must contain a WHERE clause");

        predicates_and_ordering
            .split_once(" order by ")
            .map_or(predicates_and_ordering, |(predicates, _)| predicates)
    }

    #[test]
    fn filter_predicate_check_ignores_projection_and_ordering() {
        let sql = r#"select "mtr_traces"."target", "mtr_traces"."agent_id"
            from "mtr_traces"
            where "mtr_traces"."agent_id" = $1
            order by "mtr_traces"."target" desc"#
            .to_lowercase();
        let predicate_sql = where_predicates(&sql);

        assert!(predicate_sql.contains("\"mtr_traces\".\"agent_id\""));
        assert!(
            !predicate_sql.contains("\"mtr_traces\".\"target\""),
            "projection and ordering columns must not count as filter predicates: {predicate_sql}"
        );
    }

    #[test]
    fn sql_supports_every_catalog_filter_and_typed_boolean() {
        let plan = plan_for(
            "in:mtr_traces target:edge.example target_ip:%203.0.113% agent_id:agent-a protocol:icmp check_name:%edge% device_id:device-a target_reached:false error:%timeout% time:last_1h sort:time:desc limit:1",
        );
        let (sql, params) = to_sql_and_params(&plan).expect("MTR SQL should translate");
        let lower = sql.to_lowercase();
        let predicate_sql = where_predicates(&lower);

        for field in [
            "target",
            "target_ip",
            "agent_id",
            "protocol",
            "check_name",
            "device_id",
            "target_reached",
            "error",
        ] {
            assert!(
                predicate_sql.contains(&format!("\"mtr_traces\".\"{field}\"")),
                "missing {field} WHERE predicate: {sql}"
            );
        }
        assert!(
            params
                .iter()
                .any(|param| matches!(param, BindParam::Bool(false))),
            "target_reached must use a boolean bind: {params:?}"
        );
    }

    #[test]
    fn time_range_is_half_open_and_descending_order_uses_uuid_tie_break() {
        let plan = plan_for(
            "in:mtr_traces time:[2026-06-01T00:00:00Z,2026-06-01T01:00:00Z] sort:time:desc limit:2",
        );
        let (sql, _) = to_sql_and_params(&plan).expect("MTR SQL should translate");
        let lower = sql.to_lowercase();

        assert!(lower.contains("\"mtr_traces\".\"time\" >= $1"), "{sql}");
        assert!(lower.contains("\"mtr_traces\".\"time\" < $2"), "{sql}");
        assert!(
            lower.contains("order by \"mtr_traces\".\"time\" desc, \"mtr_traces\".\"id\" desc"),
            "{sql}"
        );
    }

    #[test]
    fn ascending_time_order_uses_ascending_uuid_tie_break() {
        let plan = plan_for("in:mtr_traces sort:time:asc limit:2");
        let (sql, _) = to_sql_and_params(&plan).expect("MTR SQL should translate");
        let lower = sql.to_lowercase();

        assert!(
            lower.contains("order by \"mtr_traces\".\"time\" asc, \"mtr_traces\".\"id\" asc"),
            "{sql}"
        );
    }

    #[test]
    fn reach_rate_per_target_is_expressible() {
        // The endpoint signal. A trace that never reached its target has no
        // terminal hop, so "this device is not being reached at all" is only
        // visible at trace level -- hop metrics cannot express it.
        let plan = plan_for(
            "in:mtr_traces time:last_24h stats:\"count() as traces, avg(target_reached) as reach_rate by target_ip\" limit:50",
        );
        let (sql, _) = to_sql_and_params(&plan).expect("trace stats should translate");
        let lower = sql.to_lowercase();

        assert!(lower.contains("count(*)"), "{sql}");
        // Cast so AVG yields the reached proportion instead of erroring on a bool.
        assert!(lower.contains("avg(target_reached::int)"), "{sql}");
        assert!(lower.contains("group by target_ip"), "{sql}");
    }

    #[test]
    fn trace_stats_accept_a_time_bucket_and_render_ascending() {
        let plan =
            plan_for("in:mtr_traces time:last_24h stats:count() as traces by time:1h limit:500");
        let (sql, _) = to_sql_and_params(&plan).expect("bucketed trace stats should translate");
        let lower = sql.to_lowercase();

        assert!(lower.contains("extract(epoch from time) / 3600"), "{sql}");
        assert!(lower.contains("order by __bucket asc"), "{sql}");
    }

    #[test]
    fn trace_stats_refuse_hop_only_aggregates() {
        // loss_ratio and wavg consume probe counters, which live on hops. Offering
        // them here would invite computing loss from rows that do not carry it.
        for query in [
            "in:mtr_traces stats:loss_ratio(sent, received) as loss by target_ip limit:10",
            "in:mtr_traces stats:wavg(avg_us, received) as latency by target_ip limit:10",
        ] {
            let result = to_sql_and_params(&plan_for(query));
            assert!(
                matches!(result, Err(ServiceError::InvalidRequest(_))),
                "{query} should be refused with a pointer to in:mtr_hops"
            );
        }
    }

    #[test]
    fn trace_stats_reject_an_unsupported_group_field() {
        let plan = plan_for("in:mtr_traces stats:count() as n by total_hops limit:10");
        let result = to_sql_and_params(&plan);
        assert!(
            matches!(result, Err(ServiceError::InvalidRequest(_))),
            "an aggregatable measure is not a grouping dimension"
        );
    }

    #[test]
    fn trace_stats_scope_to_a_device() {
        let plan = plan_for(
            "in:mtr_traces time:last_24h target_ip:192.0.2.50 stats:count() as traces by agent_id limit:10",
        );
        let (sql, params) = to_sql_and_params(&plan).expect("scoped trace stats should translate");

        assert!(sql.to_lowercase().contains("target_ip"), "{sql}");
        assert!(
            params
                .iter()
                .any(|p| matches!(p, BindParam::Text(v) if v == "192.0.2.50")),
            "target_ip bind not found: {params:?}"
        );
    }

    #[test]
    fn trace_stats_text_filter_uses_case_insensitive_matching() {
        let plan =
            plan_for("in:mtr_traces target:%.Example% stats:count() as n by agent_id limit:10");
        let (sql, _) =
            to_sql_and_params(&plan).expect("text-filtered trace stats should translate");
        assert!(
            sql.to_lowercase().contains("ilike"),
            "stats text filter must use ILIKE: {sql}"
        );
    }

    /// Whether `param` is the bind a filter value of `1` must produce for a
    /// column of `kind`.
    fn is_one_bind(kind: NumericKind, param: Option<&BindParam>) -> bool {
        match kind {
            NumericKind::Int4 | NumericKind::Int8 => matches!(param, Some(BindParam::Int(1))),
            NumericKind::Float8 => matches!(param, Some(BindParam::Float(v)) if *v == 1.0),
        }
    }

    #[test]
    fn every_handshake_field_filters_with_a_typed_bind() {
        for &(field, kind) in TRACE_HANDSHAKE_FIELDS {
            for (token, op_sql) in [
                ("1", "="),
                (">1", ">"),
                (">=1", ">="),
                ("<1", "<"),
                ("<=1", "<="),
            ] {
                let query = format!("in:mtr_traces {field}:{token} limit:1");
                let (sql, params) = to_sql_and_params(&plan_for(&query))
                    .unwrap_or_else(|err| panic!("{query} should translate: {err}"));
                let lower = sql.to_lowercase();

                assert!(
                    where_predicates(&lower)
                        .contains(&format!("\"mtr_traces\".\"{field}\" {op_sql} $1")),
                    "{query} must render a {op_sql} predicate on {field}: {sql}"
                );
                assert!(
                    is_one_bind(kind, params.as_slice().first()),
                    "{query} must bind the value as its column type: {params:?}"
                );
            }

            let negated = format!("in:mtr_traces !{field}:1 limit:1");
            let (sql, _) = to_sql_and_params(&plan_for(&negated))
                .unwrap_or_else(|err| panic!("{negated} should translate: {err}"));
            assert!(
                where_predicates(&sql.to_lowercase())
                    .contains(&format!("\"mtr_traces\".\"{field}\" != $1")),
                "{negated} must render an inequality: {sql}"
            );
        }
    }

    #[test]
    fn syn_drop_pct_ordered_comparison_binds_a_float() {
        let plan = plan_for("in:mtr_traces time:last_24h tcp_syn_drop_pct:>12.5 limit:10");
        let (sql, params) = to_sql_and_params(&plan).expect("drop filter should translate");
        let lower = sql.to_lowercase();

        // $1 and $2 are the time window.
        assert!(
            where_predicates(&lower).contains("\"mtr_traces\".\"tcp_syn_drop_pct\" > $3"),
            "{sql}"
        );
        assert!(
            matches!(params.get(2), Some(BindParam::Float(v)) if *v == 12.5),
            "{params:?}"
        );
    }

    #[test]
    fn handshake_rtt_filter_binds_a_bigint_value() {
        // RTTs are microseconds in BIGINT columns; a value past i32::MAX must
        // still parse rather than overflow into a rejection.
        let plan = plan_for("in:mtr_traces tcp_handshake_rtt_avg_us:>=3000000000 limit:10");
        let (sql, params) = to_sql_and_params(&plan).expect("rtt filter should translate");

        assert!(
            sql.to_lowercase()
                .contains("\"mtr_traces\".\"tcp_handshake_rtt_avg_us\" >= $1"),
            "{sql}"
        );
        assert!(
            matches!(
                params.as_slice().first(),
                Some(BindParam::Int(3_000_000_000))
            ),
            "{params:?}"
        );
    }

    #[test]
    fn handshake_filters_reject_values_that_are_not_numbers_of_the_column_type() {
        for query in [
            "in:mtr_traces tcp_syn_sent:many",
            // An integer column refuses a fractional value instead of truncating it.
            "in:mtr_traces tcp_syn_unanswered:1.5",
            // Beyond INTEGER range for an Int4 column.
            "in:mtr_traces tcp_syn_sent:3000000000",
            "in:mtr_traces tcp_syn_drop_pct:abc",
            "in:mtr_traces tcp_syn_drop_pct:NaN",
            "in:mtr_traces tcp_syn_drop_pct:inf",
            "in:mtr_traces tcp_handshake_rtt_avg_us:fast",
            // Lists are not a numeric comparison.
            "in:mtr_traces tcp_syn_sent:(1,2)",
            // The same guard applies inside a stats query.
            "in:mtr_traces tcp_syn_drop_pct:high stats:count() as n by target_ip limit:10",
            "in:mtr_traces tcp_rst_received:(1,2) stats:count() as n by target_ip limit:10",
        ] {
            let result = to_sql_and_params(&plan_for(query));
            assert!(
                matches!(result, Err(ServiceError::InvalidRequest(_))),
                "{query} should be rejected, got {result:?}"
            );
        }
    }

    #[test]
    fn handshake_columns_are_projected_in_row_results() {
        let (sql, _) =
            to_sql_and_params(&plan_for("in:mtr_traces limit:1")).expect("SQL should translate");
        let lower = sql.to_lowercase();

        for &(field, _) in TRACE_HANDSHAKE_FIELDS {
            assert!(
                lower.contains(&format!("\"mtr_traces\".\"{field}\"")),
                "row projection is missing {field}: {sql}"
            );
        }
    }

    #[test]
    fn stats_aggregate_the_handshake_rtt_by_target() {
        let plan = plan_for(
            "in:mtr_traces time:last_24h stats:\"avg(tcp_handshake_rtt_avg_us) as rtt by target_ip\" limit:50",
        );
        let (sql, params) = to_sql_and_params(&plan).expect("handshake stats should translate");
        let lower = sql.to_lowercase();

        assert!(
            lower.contains("'rtt', avg(tcp_handshake_rtt_avg_us)"),
            "{sql}"
        );
        assert!(lower.contains("group by target_ip"), "{sql}");
        assert_eq!(params.len(), 2, "only the time window binds: {params:?}");
    }

    #[test]
    fn every_handshake_field_is_aggregatable() {
        for &(field, _) in TRACE_HANDSHAKE_FIELDS {
            for func in ["sum", "avg", "min", "max"] {
                let query =
                    format!("in:mtr_traces stats:{func}({field}) as v by target_ip limit:10");
                let (sql, _) = to_sql_and_params(&plan_for(&query))
                    .unwrap_or_else(|err| panic!("{query} should translate: {err}"));
                assert!(
                    sql.to_lowercase().contains(&format!("{func}({field})")),
                    "{query}: {sql}"
                );
            }
        }
    }

    #[test]
    fn handshake_filters_constrain_stats_queries() {
        let plan = plan_for(
            "in:mtr_traces time:last_24h protocol:tcp tcp_syn_drop_pct:>0 tcp_handshake_attempts:>=3 stats:\"count() as lossy, max(tcp_syn_drop_pct) as worst by target_ip\" limit:20",
        );
        let (sql, params) = to_sql_and_params(&plan).expect("filtered stats should translate");
        let lower = sql.to_lowercase();

        // $1/$2 time window, $3 protocol, then the handshake predicates in order.
        assert!(lower.contains("tcp_syn_drop_pct > $4"), "{sql}");
        assert!(lower.contains("tcp_handshake_attempts >= $5"), "{sql}");
        assert!(lower.contains("max(tcp_syn_drop_pct)"), "{sql}");
        assert!(
            matches!(params.get(3), Some(BindParam::Float(v)) if *v == 0.0),
            "{params:?}"
        );
        assert!(
            matches!(params.get(4), Some(BindParam::Int(3))),
            "{params:?}"
        );
        assert_eq!(params.len(), 5, "{params:?}");
    }

    #[test]
    fn invalid_boolean_and_unknown_filter_are_rejected() {
        for query in [
            "in:mtr_traces target_reached:maybe",
            "in:mtr_traces unsupported:value",
            // Stats used to drop a filter they could not express and answer
            // for every trace.
            "in:mtr_traces total_hops:5 stats:count() as n by target_ip limit:10",
            "in:mtr_traces gateway_id:gw-a stats:count() as n by target_ip limit:10",
        ] {
            let result = to_sql_and_params(&plan_for(query));
            assert!(
                matches!(result, Err(ServiceError::InvalidRequest(_))),
                "{query} should be rejected"
            );
        }
    }

    #[test]
    fn trace_stats_honor_the_requested_sort() {
        // The "lowest reach rate" panel. Ignoring the sort listed the busiest
        // targets instead: the first aggregation, descending.
        let plan = plan_for(
            "in:mtr_traces time:last_24h stats:\"count() as traces, avg(target_reached) as reach_rate by target_ip\" sort:reach_rate:asc limit:25",
        );
        let (sql, _) = to_sql_and_params(&plan).expect("trace stats should translate");
        assert!(
            sql.to_lowercase()
                .contains("order by avg(target_reached::int) asc"),
            "{sql}"
        );

        let plan =
            plan_for("in:mtr_traces stats:count() as n by agent_id sort:agent_id:asc limit:5");
        let (sql, _) = to_sql_and_params(&plan).expect("trace stats should translate");
        assert!(
            sql.to_lowercase().contains("order by agent_id asc"),
            "{sql}"
        );

        let plan = plan_for("in:mtr_traces stats:count() as n by agent_id limit:5");
        let (sql, _) = to_sql_and_params(&plan).expect("trace stats should translate");
        assert!(
            sql.to_lowercase().contains("order by count(*) desc"),
            "{sql}"
        );
    }

    #[test]
    fn trace_stats_target_reached_filter_honors_negation() {
        let plan =
            plan_for("in:mtr_traces !target_reached:true stats:count() as n by target_ip limit:5");
        let (sql, params) = to_sql_and_params(&plan).expect("trace stats should translate");
        assert!(sql.contains("target_reached <> $1"), "{sql}");
        assert!(
            matches!(params.as_slice().first(), Some(BindParam::Bool(true))),
            "{params:?}"
        );
    }
}

// ─── stats ───────────────────────────────────────────────────────────────────
//
// Trace-level aggregation answers a question hop-level data cannot. A trace that
// never reached its target has no terminal hop to measure, so "this device is not
// being reached at all" is only visible here. That is the endpoint signal, as
// distinct from which path segment is lossy.
//
// Reach rate needs no new aggregate function: `target_reached` is exposed as an
// aggregatable 0/1 indicator, and the mean of an indicator IS the proportion. So
// `avg(target_reached)` is the reach rate, computed correctly, with the aggregates
// that already exist.
//
// This builder deliberately does NOT offer `loss_ratio` or `wavg`. Those consume
// probe counters, which live on hops; offering them here would invite a caller to
// compute loss from trace rows that do not carry it.

/// Aggregatable columns, mapped to the SQL that makes them numeric.
///
/// The TCP handshake columns aggregate as-is; SQL aggregates skip NULL, so a
/// trace that reported no handshake does not pull an average toward zero.
pub(crate) const TRACE_AGGREGATABLE_COLUMNS: &[(&str, &str)] = &[
    ("total_hops", "total_hops"),
    // Cast so AVG yields the reached proportion rather than erroring on a bool.
    ("target_reached", "target_reached::int"),
    ("tcp_handshake_ttl", "tcp_handshake_ttl"),
    ("tcp_handshake_attempts", "tcp_handshake_attempts"),
    ("tcp_syn_sent", "tcp_syn_sent"),
    ("tcp_synack_received", "tcp_synack_received"),
    ("tcp_rst_received", "tcp_rst_received"),
    ("tcp_syn_unanswered", "tcp_syn_unanswered"),
    ("tcp_syn_drop_pct", "tcp_syn_drop_pct"),
    ("tcp_syn_retransmits", "tcp_syn_retransmits"),
    ("tcp_answered_after_retx", "tcp_answered_after_retx"),
    ("tcp_ack_mismatch", "tcp_ack_mismatch"),
    ("tcp_synack_duplicates", "tcp_synack_duplicates"),
    ("tcp_handshake_rtt_min_us", "tcp_handshake_rtt_min_us"),
    ("tcp_handshake_rtt_avg_us", "tcp_handshake_rtt_avg_us"),
    ("tcp_handshake_rtt_max_us", "tcp_handshake_rtt_max_us"),
    ("tcp_server_response_us", "tcp_server_response_us"),
];

pub(crate) const TRACE_GROUP_BY_FIELDS: &[&str] = &[
    "target_ip",
    "target",
    "device_id",
    "agent_id",
    "protocol",
    "check_name",
];

const TRACE_BUCKET_ALIAS: &str = "bucket";

#[derive(Debug, Clone)]
struct TraceStatsSql {
    sql: String,
    binds: Vec<TraceStatsBind>,
}

#[derive(Debug, Clone)]
enum TraceStatsBind {
    Text(String),
    Timestamp(chrono::DateTime<chrono::Utc>),
    Bool(bool),
    Numeric(NumericValue),
}

#[derive(Debug, Clone)]
struct TraceAgg {
    expr: String,
    alias: String,
}

/// One trace grouping dimension. Dialect-neutral: the StarRocks dialect parses
/// the `by` clause with [`parse_trace_stats`] and renders these itself.
#[derive(Debug, Clone)]
pub(crate) enum TraceGroupDim {
    Column(&'static str),
    TimeBucket { seconds: i64 },
}

impl TraceGroupDim {
    fn expr(&self) -> String {
        match self {
            TraceGroupDim::Column(col) => (*col).to_string(),
            TraceGroupDim::TimeBucket { seconds } => {
                format!("to_timestamp(floor(extract(epoch from time) / {seconds}) * {seconds})")
            }
        }
    }

    pub(crate) fn alias(&self) -> &str {
        match self {
            TraceGroupDim::Column(col) => col,
            TraceGroupDim::TimeBucket { .. } => TRACE_BUCKET_ALIAS,
        }
    }
}

/// Splits and validates a trace `stats:` expression. Dialect-neutral: the CNPG
/// builder below and the StarRocks dialect (`starrocks/mtr.rs`) both start
/// here, so the two backends accept exactly the same aggregations.
pub(crate) fn parse_trace_stats(raw: &str) -> Result<(Vec<ParsedTraceAgg>, Vec<TraceGroupDim>)> {
    let (agg_part, group_part) = split_trace_group_clause(raw).ok_or_else(|| {
        ServiceError::InvalidRequest(
            "mtr_traces stats expression must include 'by <field>' — e.g. \
             stats:count() as traces by target_ip"
                .into(),
        )
    })?;

    let dims = parse_trace_group_dims(group_part.trim())?;
    let aggs = parse_trace_aggs(agg_part.trim())?;
    Ok((aggs, dims))
}

fn build_stats_sql(plan: &QueryPlan, raw: &str) -> Result<TraceStatsSql> {
    let (parsed, dims) = parse_trace_stats(raw)?;
    let aggs: Vec<TraceAgg> = parsed.iter().map(TraceAgg::postgres).collect();

    let mut clauses: Vec<String> = Vec::new();
    let mut binds: Vec<TraceStatsBind> = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("time >= ?".into());
        binds.push(TraceStatsBind::Timestamp(*start));
        clauses.push("time < ?".into());
        binds.push(TraceStatsBind::Timestamp(*end));
    }

    for filter in &plan.filters {
        let (clause, mut filter_binds) = build_trace_stats_filter(filter)?;
        clauses.push(clause);
        binds.append(&mut filter_binds);
    }

    let json_kv: Vec<String> = aggs
        .iter()
        .flat_map(|agg| [format!("'{}'", agg.alias), agg.expr.clone()])
        .chain(
            dims.iter()
                .flat_map(|dim| [format!("'{}'", dim.alias()), dim.expr()]),
        )
        .collect();

    let payload = format!("jsonb_build_object({})", json_kv.join(", "));
    let group_exprs: Vec<String> = dims.iter().map(TraceGroupDim::expr).collect();

    let bucket = dims.iter().find_map(|dim| match dim {
        TraceGroupDim::TimeBucket { .. } => Some(dim.expr()),
        TraceGroupDim::Column(_) => None,
    });

    let mut body = format!("SELECT {payload} AS payload");
    if let Some(b) = &bucket {
        body.push_str(&format!(", {b} AS __bucket"));
    }
    body.push_str("\nFROM mtr_traces");
    if !clauses.is_empty() {
        body.push_str("\nWHERE ");
        body.push_str(&clauses.join(" AND "));
    }
    body.push_str(&format!("\nGROUP BY {}", group_exprs.join(", ")));

    let sql = match &bucket {
        // Newest buckets when limit truncates, still rendered ascending — the
        // defect recorded in downsample/sql.rs.
        Some(_) => {
            body.push_str("\nORDER BY __bucket DESC");
            body.push_str(&format!("\nLIMIT {} OFFSET {}", plan.limit, plan.offset));
            format!("SELECT payload\nFROM (\n{body}\n) AS bucketed\nORDER BY __bucket ASC")
        }
        None => {
            body.push_str(&build_trace_stats_order_clause(plan, &aggs));
            body.push_str(&format!("\nLIMIT {} OFFSET {}", plan.limit, plan.offset));
            body
        }
    };

    Ok(TraceStatsSql { sql, binds })
}

/// `sort:` resolved the way the hop builder resolves it. Trace stats used to
/// ignore it and always order by the first aggregation descending, so the
/// "lowest reach rate" panel (`sort:reach_rate:asc`) listed the busiest
/// targets instead.
fn build_trace_stats_order_clause(plan: &QueryPlan, aggs: &[TraceAgg]) -> String {
    use super::mtr_hops::{StatsOrderKey, resolve_stats_order};

    let aliases: Vec<&str> = aggs.iter().map(|agg| agg.alias.as_str()).collect();
    let parts: Vec<String> = resolve_stats_order(&plan.order, &aliases, TRACE_GROUP_BY_FIELDS)
        .into_iter()
        .map(|(key, direction)| {
            let expr = match key {
                StatsOrderKey::Agg(index) => aggs[index].expr.as_str(),
                StatsOrderKey::Group(field) => field,
            };
            let dir = match direction {
                OrderDirection::Asc => "ASC",
                OrderDirection::Desc => "DESC",
            };
            format!("{expr} {dir}")
        })
        .collect();

    if parts.is_empty() {
        String::new()
    } else {
        format!("\nORDER BY {}", parts.join(", "))
    }
}

fn split_trace_group_clause(raw: &str) -> Option<(&str, &str)> {
    let lower = raw.to_ascii_lowercase();
    let pos = lower.find(" by ")?;
    Some((&raw[..pos], &raw[pos + 4..]))
}

pub(crate) fn parse_trace_group_dims(part: &str) -> Result<Vec<TraceGroupDim>> {
    let mut dims: Vec<TraceGroupDim> = Vec::new();

    for raw in part.split(',') {
        let token = raw.trim();
        if token.is_empty() {
            continue;
        }

        if let Some((key, value)) = token.split_once(':') {
            if !key.trim().eq_ignore_ascii_case("time") {
                return Err(ServiceError::InvalidRequest(format!(
                    "only the 'time' group dimension takes a duration; got '{token}'"
                )));
            }
            if dims
                .iter()
                .any(|d| matches!(d, TraceGroupDim::TimeBucket { .. }))
            {
                return Err(ServiceError::InvalidRequest(
                    "only one time bucket dimension is supported".into(),
                ));
            }
            let seconds = crate::parser::parse_group_bucket_seconds(value.trim())?;
            dims.push(TraceGroupDim::TimeBucket { seconds });
        } else {
            let lower = token.to_ascii_lowercase();
            let field = TRACE_GROUP_BY_FIELDS
                .iter()
                .find(|&&f| f == lower.as_str())
                .copied()
                .ok_or_else(|| {
                    ServiceError::InvalidRequest(format!(
                        "unsupported group-by field '{token}' for mtr_traces stats; supported: {}",
                        TRACE_GROUP_BY_FIELDS.join(", ")
                    ))
                })?;
            dims.push(TraceGroupDim::Column(field));
        }
    }

    if dims.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "mtr_traces stats requires at least one group dimension".into(),
        ));
    }

    Ok(dims)
}

fn parse_trace_aggs(part: &str) -> Result<Vec<ParsedTraceAgg>> {
    let mut result = Vec::new();

    for expr in crate::parser::split_top_level_commas(part) {
        let expr = expr.trim();
        if expr.is_empty() {
            continue;
        }
        result.push(parse_trace_agg(expr)?);
    }

    if result.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "mtr_traces stats requires at least one aggregation expression".into(),
        ));
    }

    Ok(result)
}

/// What a trace aggregation computes, with its column validated. Dialect-neutral
/// for the same reason as the hop builder's `HopAggKind`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TraceAggKind {
    /// A bare `count()`: the number of traces in the group.
    CountRows,
    /// `count|sum|avg|min|max(<column>)`. `function` is the SQL spelling and
    /// `column` a name from [`TRACE_AGGREGATABLE_COLUMNS`].
    Column {
        function: &'static str,
        column: &'static str,
    },
}

#[derive(Debug, Clone)]
pub(crate) struct ParsedTraceAgg {
    pub(crate) kind: TraceAggKind,
    pub(crate) alias: String,
}

impl TraceAgg {
    fn postgres(agg: &ParsedTraceAgg) -> Self {
        let expr = match agg.kind {
            TraceAggKind::CountRows => "COUNT(*)".to_string(),
            TraceAggKind::Column { function, column } => {
                format!("{function}({})", pg_trace_column(column))
            }
        };
        TraceAgg {
            expr,
            alias: agg.alias.clone(),
        }
    }
}

/// The Postgres expression that makes an aggregatable trace column numeric.
pub(crate) fn pg_trace_column(column: &str) -> &'static str {
    TRACE_AGGREGATABLE_COLUMNS
        .iter()
        .find(|(name, _)| *name == column)
        .map(|(_, sql)| *sql)
        .expect("trace aggregation columns are validated against TRACE_AGGREGATABLE_COLUMNS")
}

fn parse_trace_agg(expr: &str) -> Result<ParsedTraceAgg> {
    let lower = expr.to_ascii_lowercase();

    let (call, alias) = match lower.find(" as ") {
        Some(pos) => (expr[..pos].trim(), expr[pos + 4..].trim()),
        None => (expr, ""),
    };

    let open = call.find('(').ok_or_else(|| {
        ServiceError::InvalidRequest(format!("expected aggregation like count(), got '{expr}'"))
    })?;
    let close = call.rfind(')').ok_or_else(|| {
        ServiceError::InvalidRequest(format!("unmatched parenthesis in '{expr}'"))
    })?;

    let func = call[..open].trim().to_ascii_lowercase();
    let arg = call[open + 1..close].trim();

    let (kind, default_alias) = match (func.as_str(), arg.is_empty()) {
        ("count", true) => (TraceAggKind::CountRows, "count".to_string()),
        ("count", false) => {
            let column = validate_trace_agg_column(arg)?;
            (
                TraceAggKind::Column {
                    function: "COUNT",
                    column,
                },
                format!("count_{arg}"),
            )
        }
        ("sum" | "avg" | "min" | "max", false) => {
            let column = validate_trace_agg_column(arg)?;
            let function = match func.as_str() {
                "sum" => "SUM",
                "avg" => "AVG",
                "min" => "MIN",
                _ => "MAX",
            };
            (
                TraceAggKind::Column { function, column },
                format!("{func}_{arg}"),
            )
        }
        ("loss_ratio" | "wavg", _) => {
            return Err(ServiceError::InvalidRequest(format!(
                "'{func}' aggregates probe counters, which live on hops; \
                 use in:mtr_hops for loss and latency"
            )));
        }
        (other, _) => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported aggregation '{other}' for mtr_traces; \
                 use count, sum, avg, min, or max"
            )));
        }
    };

    let alias = if alias.is_empty() {
        sanitize_trace_alias(&default_alias)?
    } else {
        sanitize_trace_alias(alias)?
    };

    Ok(ParsedTraceAgg { kind, alias })
}

fn validate_trace_agg_column(col: &str) -> Result<&'static str> {
    let lower = col.to_ascii_lowercase();

    TRACE_AGGREGATABLE_COLUMNS
        .iter()
        .find(|(name, _)| *name == lower.as_str())
        .map(|(name, _)| *name)
        .ok_or_else(|| {
            ServiceError::InvalidRequest(format!(
                "unsupported column '{col}' for mtr_traces stats; supported: {}",
                TRACE_AGGREGATABLE_COLUMNS
                    .iter()
                    .map(|(name, _)| *name)
                    .collect::<Vec<_>>()
                    .join(", ")
            ))
        })
}

fn sanitize_trace_alias(raw: &str) -> Result<String> {
    let clean: String = raw
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '_')
        .collect();

    if clean.is_empty() || clean.starts_with(|c: char| c.is_ascii_digit()) {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid alias '{raw}'"
        )));
    }

    Ok(clean)
}

/// Refuses a filter it cannot express rather than dropping it, as the hop
/// builder does; the row path already refuses the same fields.
fn build_trace_stats_filter(filter: &Filter) -> Result<(String, Vec<TraceStatsBind>)> {
    let field = filter.field.as_str();

    match field {
        "target" | "target_ip" | "agent_id" | "protocol" | "check_name" | "device_id" | "error" => {
            let value = filter.value.as_scalar()?.to_string();
            let op = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                FilterOp::Like => "ILIKE",
                FilterOp::NotLike => "NOT ILIKE",
                _ => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "unsupported operator for '{field}' in mtr_traces stats"
                    )));
                }
            };
            Ok((format!("{field} {op} ?"), vec![TraceStatsBind::Text(value)]))
        }
        // `!target_reached:true` used to compile to `target_reached = true`: the
        // operator was never read.
        "target_reached" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            let op = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "target_reached only supports equality comparisons".into(),
                    ));
                }
            };
            Ok((
                format!("target_reached {op} ?"),
                vec![TraceStatsBind::Bool(value)],
            ))
        }
        other => match handshake_comparison(filter)? {
            Some((column, comparison)) => Ok((
                format!("{column} {} ?", comparison.op_sql),
                vec![TraceStatsBind::Numeric(comparison.value)],
            )),
            None => Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for mtr_traces: '{other}'"
            ))),
        },
    }
}

fn bind_param_from_trace(bind: TraceStatsBind) -> BindParam {
    match bind {
        TraceStatsBind::Text(v) => BindParam::Text(v),
        TraceStatsBind::Timestamp(v) => BindParam::timestamptz(v),
        TraceStatsBind::Bool(v) => BindParam::Bool(v),
        TraceStatsBind::Numeric(v) => v.bind_param(),
    }
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut out = String::with_capacity(sql.len() + 16);
    let mut index = 1;

    for ch in sql.chars() {
        if ch == '?' {
            out.push('$');
            out.push_str(&index.to_string());
            index += 1;
        } else {
            out.push(ch);
        }
    }

    out
}

async fn execute_stats(
    conn: &mut AsyncPgConnection,
    sql: &TraceStatsSql,
) -> Result<Vec<serde_json::Value>> {
    use diesel::sql_query;
    use diesel::sql_types::{Bool, Text, Timestamptz};

    let mut q = sql_query(rewrite_placeholders(&sql.sql)).into_boxed::<Pg>();

    for bind in &sql.binds {
        q = match bind {
            TraceStatsBind::Text(v) => q.bind::<Text, _>(v.clone()),
            TraceStatsBind::Timestamp(v) => q.bind::<Timestamptz, _>(*v),
            TraceStatsBind::Bool(v) => q.bind::<Bool, _>(*v),
            TraceStatsBind::Numeric(v) => v.bind_sql_query(q),
        };
    }

    #[derive(Debug, diesel::QueryableByName)]
    #[diesel(check_for_backend(diesel::pg::Pg))]
    struct TraceStatsPayload {
        #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Jsonb>)]
        payload: Option<crate::jsonb::DbJson>,
    }

    let rows: Vec<TraceStatsPayload> = q
        .load::<TraceStatsPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .filter_map(|row| row.payload.map(|p| p.0))
        .collect())
}
