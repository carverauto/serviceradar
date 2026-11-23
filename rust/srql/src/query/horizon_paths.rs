use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::HorizonPathHopRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::horizon_path_hops::dsl::{
        as_org as col_as_org, asn as col_asn, avg_rtt_ms as col_avg_rtt_ms,
        cloud_provider as col_cloud_provider, cloud_region as col_cloud_region,
        forwarding_loss_pct as col_forwarding_loss_pct, hop_ip as col_hop_ip,
        hop_ttl as col_hop_ttl, horizon_path_hops, is_cloud as col_is_cloud,
        mtu_blackhole_detected as col_mtu_blackhole_detected, pop_id as col_pop_id,
        round_id as col_round_id, router_alias_id as col_router_alias_id,
        target_id as col_target_id, time as col_time,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type HorizonPathsTable = crate::schema::horizon_path_hops::table;
type HorizonPathsFromClause = FromClause<HorizonPathsTable>;
type HorizonPathsQuery<'a> =
    BoxedSelectStatement<'a, <HorizonPathsTable as AsQuery>::SqlType, HorizonPathsFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    super::reject_stats(plan, "horizon_paths")?;
    let query = build_query(plan)?;
    let rows: Vec<HorizonPathHopRow> = query
        .select(HorizonPathHopRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<HorizonPathHopRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(HorizonPathHopRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    super::reject_stats(plan, "horizon_paths")?;
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
        Entity::HorizonPaths => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by horizon_paths query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<HorizonPathsQuery<'static>> {
    let mut query = horizon_path_hops.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_time.ge(*start).and(col_time.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(apply_ordering(query, &plan.order))
}

fn apply_filter<'a>(
    mut query: HorizonPathsQuery<'a>,
    filter: &Filter,
) -> Result<HorizonPathsQuery<'a>> {
    match filter.field.as_str() {
        "round_id" => query = apply_text_filter!(query, filter, col_round_id)?,
        "target_id" => query = apply_text_filter!(query, filter, col_target_id)?,
        "pop_id" => query = apply_text_filter!(query, filter, col_pop_id)?,
        "hop_ip" => query = apply_text_filter!(query, filter, col_hop_ip)?,
        "router_alias_id" => query = apply_text_filter!(query, filter, col_router_alias_id)?,
        "as_org" => query = apply_text_filter!(query, filter, col_as_org)?,
        "cloud_provider" => query = apply_text_filter!(query, filter, col_cloud_provider)?,
        "cloud_region" => query = apply_text_filter!(query, filter, col_cloud_region)?,
        "hop_ttl" => {
            let value = parse_i32(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_hop_ttl, value)?;
        }
        "asn" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_asn, value)?;
        }
        "forwarding_loss_pct" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_forwarding_loss_pct, value)?;
        }
        "avg_rtt_ms" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_avg_rtt_ms, value)?;
        }
        "is_cloud" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_is_cloud,
                value,
                "is_cloud only supports equality comparisons"
            )?;
        }
        "mtu_blackhole_detected" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_mtu_blackhole_detected,
                value,
                "mtu_blackhole_detected only supports equality comparisons"
            )?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for horizon_paths: '{other}'"
            )));
        }
    }

    Ok(query)
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
        "round_id" | "target_id" | "pop_id" | "hop_ip" | "router_alias_id" | "as_org"
        | "cloud_provider" | "cloud_region" => collect_text_params(params, filter),
        "hop_ttl" => {
            params.push(BindParam::Int(i64::from(parse_i32(
                filter.value.as_scalar()?,
            )?)));
            Ok(())
        }
        "asn" => {
            params.push(BindParam::Int(parse_i64(filter.value.as_scalar()?)?));
            Ok(())
        }
        "forwarding_loss_pct" | "avg_rtt_ms" => {
            params.push(BindParam::Float(parse_f64(filter.value.as_scalar()?)?));
            Ok(())
        }
        "is_cloud" | "mtu_blackhole_detected" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for horizon_paths: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: HorizonPathsQuery<'a>,
    order: &[OrderClause],
) -> HorizonPathsQuery<'a> {
    let mut applied = false;
    for clause in order {
        let recognized = matches!(
            clause.field.as_str(),
            "time" | "timestamp" | "hop_ttl" | "forwarding_loss_pct" | "avg_rtt_ms"
        );
        if !recognized {
            continue;
        }
        query = if !applied {
            applied = true;
            match (clause.field.as_str(), clause.direction) {
                ("time" | "timestamp", OrderDirection::Asc) => query.order(col_time.asc()),
                ("time" | "timestamp", OrderDirection::Desc) => query.order(col_time.desc()),
                ("hop_ttl", OrderDirection::Asc) => query.order(col_hop_ttl.asc()),
                ("hop_ttl", OrderDirection::Desc) => query.order(col_hop_ttl.desc()),
                ("forwarding_loss_pct", OrderDirection::Asc) => {
                    query.order(col_forwarding_loss_pct.asc())
                }
                ("forwarding_loss_pct", OrderDirection::Desc) => {
                    query.order(col_forwarding_loss_pct.desc())
                }
                ("avg_rtt_ms", OrderDirection::Asc) => query.order(col_avg_rtt_ms.asc()),
                ("avg_rtt_ms", OrderDirection::Desc) => query.order(col_avg_rtt_ms.desc()),
                _ => query,
            }
        } else {
            match (clause.field.as_str(), clause.direction) {
                ("time" | "timestamp", OrderDirection::Asc) => query.then_order_by(col_time.asc()),
                ("time" | "timestamp", OrderDirection::Desc) => {
                    query.then_order_by(col_time.desc())
                }
                ("hop_ttl", OrderDirection::Asc) => query.then_order_by(col_hop_ttl.asc()),
                ("hop_ttl", OrderDirection::Desc) => query.then_order_by(col_hop_ttl.desc()),
                ("forwarding_loss_pct", OrderDirection::Asc) => {
                    query.then_order_by(col_forwarding_loss_pct.asc())
                }
                ("forwarding_loss_pct", OrderDirection::Desc) => {
                    query.then_order_by(col_forwarding_loss_pct.desc())
                }
                ("avg_rtt_ms", OrderDirection::Asc) => query.then_order_by(col_avg_rtt_ms.asc()),
                ("avg_rtt_ms", OrderDirection::Desc) => query.then_order_by(col_avg_rtt_ms.desc()),
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order(col_time.desc());
    }

    query
}

fn parse_i32(raw: &str) -> Result<i32> {
    raw.parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}

fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}

fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid float '{raw}'")))
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean '{raw}'"
        ))),
    }
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
            permitted_signals: None,
        };
        let ast = parse(query).expect("query should parse");
        build_query_plan(config.as_ref(), &request, ast).expect("query plan should build")
    }

    #[test]
    fn horizon_paths_sql_includes_filters_and_bind_parity() {
        let plan = plan_for(
            "in:horizon_paths target_id:tgt-1 pop_id:iad-1 hop_ip:198.51.100.1 router_alias_id:rtr-9 asn:15169 is_cloud:true cloud_provider:gcp mtu_blackhole_detected:false time:last_1h sort:hop_ttl:asc limit:100",
        );
        let (sql, params) = to_sql_and_params(&plan).expect("should build SQL");
        let lower = sql.to_lowercase();

        assert!(lower.contains("\"horizon_path_hops\".\"target_id\""));
        assert!(lower.contains("\"horizon_path_hops\".\"pop_id\""));
        assert!(lower.contains("\"horizon_path_hops\".\"hop_ip\""));
        assert!(lower.contains("\"horizon_path_hops\".\"router_alias_id\""));
        assert!(lower.contains("\"horizon_path_hops\".\"asn\""));
        assert!(lower.contains("\"horizon_path_hops\".\"is_cloud\""));
        assert!(lower.contains("\"horizon_path_hops\".\"cloud_provider\""));
        assert!(lower.contains("\"horizon_path_hops\".\"mtu_blackhole_detected\""));
        assert!(params.iter().any(|p| matches!(p, BindParam::Int(15169))));
        assert!(params.iter().any(|p| matches!(p, BindParam::Bool(true))));
        assert!(params.iter().any(|p| matches!(p, BindParam::Bool(false))));
    }

    #[test]
    fn horizon_paths_rejects_unknown_filter() {
        let plan = plan_for("in:horizon_paths bad_field:val");
        let result = to_sql_and_params(&plan);
        assert!(matches!(result, Err(ServiceError::InvalidRequest(_))));
    }
}
