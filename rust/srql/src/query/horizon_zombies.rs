use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::HorizonBgpZombieRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::horizon_bgp_zombies::dsl::{
        divergence_pct as col_divergence_pct, episode_id as col_episode_id,
        first_seen_at as col_first_seen_at, horizon_bgp_zombies, is_beacon as col_is_beacon,
        origin_asn as col_origin_asn, prefix as col_prefix, status as col_status, time as col_time,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type HorizonZombiesTable = crate::schema::horizon_bgp_zombies::table;
type HorizonZombiesFromClause = FromClause<HorizonZombiesTable>;
type HorizonZombiesQuery<'a> = BoxedSelectStatement<
    'a,
    <HorizonZombiesTable as AsQuery>::SqlType,
    HorizonZombiesFromClause,
    Pg,
>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    super::reject_stats(plan, "horizon_zombies")?;
    let query = build_query(plan)?;
    let rows: Vec<HorizonBgpZombieRow> = query
        .select(HorizonBgpZombieRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<HorizonBgpZombieRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(HorizonBgpZombieRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    super::reject_stats(plan, "horizon_zombies")?;
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
        Entity::HorizonZombies => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by horizon_zombies query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<HorizonZombiesQuery<'static>> {
    let mut query = horizon_bgp_zombies.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_time.ge(*start).and(col_time.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(apply_ordering(query, &plan.order))
}

fn apply_filter<'a>(
    mut query: HorizonZombiesQuery<'a>,
    filter: &Filter,
) -> Result<HorizonZombiesQuery<'a>> {
    match filter.field.as_str() {
        "episode_id" => query = apply_text_filter!(query, filter, col_episode_id)?,
        "status" => query = apply_text_filter!(query, filter, col_status)?,
        "prefix" => query = apply_text_filter!(query, filter, col_prefix)?,
        "origin_asn" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_origin_asn, value)?;
        }
        "divergence_pct" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_divergence_pct, value)?;
        }
        "is_beacon" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_is_beacon,
                value,
                "is_beacon only supports equality comparisons"
            )?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for horizon_zombies: '{other}'"
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
        "episode_id" | "status" | "prefix" => collect_text_params(params, filter),
        "origin_asn" => {
            params.push(BindParam::Int(parse_i64(filter.value.as_scalar()?)?));
            Ok(())
        }
        "divergence_pct" => {
            params.push(BindParam::Float(parse_f64(filter.value.as_scalar()?)?));
            Ok(())
        }
        "is_beacon" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for horizon_zombies: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: HorizonZombiesQuery<'a>,
    order: &[OrderClause],
) -> HorizonZombiesQuery<'a> {
    let mut applied = false;
    for clause in order {
        let recognized = matches!(
            clause.field.as_str(),
            "time" | "timestamp" | "status" | "divergence_pct" | "first_seen_at"
        );
        if !recognized {
            continue;
        }
        query = if !applied {
            applied = true;
            match (clause.field.as_str(), clause.direction) {
                ("time" | "timestamp", OrderDirection::Asc) => query.order(col_time.asc()),
                ("time" | "timestamp", OrderDirection::Desc) => query.order(col_time.desc()),
                ("status", OrderDirection::Asc) => query.order(col_status.asc()),
                ("status", OrderDirection::Desc) => query.order(col_status.desc()),
                ("divergence_pct", OrderDirection::Asc) => query.order(col_divergence_pct.asc()),
                ("divergence_pct", OrderDirection::Desc) => query.order(col_divergence_pct.desc()),
                ("first_seen_at", OrderDirection::Asc) => query.order(col_first_seen_at.asc()),
                ("first_seen_at", OrderDirection::Desc) => query.order(col_first_seen_at.desc()),
                _ => query,
            }
        } else {
            match (clause.field.as_str(), clause.direction) {
                ("time" | "timestamp", OrderDirection::Asc) => query.then_order_by(col_time.asc()),
                ("time" | "timestamp", OrderDirection::Desc) => {
                    query.then_order_by(col_time.desc())
                }
                ("status", OrderDirection::Asc) => query.then_order_by(col_status.asc()),
                ("status", OrderDirection::Desc) => query.then_order_by(col_status.desc()),
                ("divergence_pct", OrderDirection::Asc) => {
                    query.then_order_by(col_divergence_pct.asc())
                }
                ("divergence_pct", OrderDirection::Desc) => {
                    query.then_order_by(col_divergence_pct.desc())
                }
                ("first_seen_at", OrderDirection::Asc) => {
                    query.then_order_by(col_first_seen_at.asc())
                }
                ("first_seen_at", OrderDirection::Desc) => {
                    query.then_order_by(col_first_seen_at.desc())
                }
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order(col_time.desc());
    }

    query
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
    fn horizon_zombies_sql_includes_filters_and_bind_parity() {
        let plan = plan_for(
            "in:horizon_zombies status:active prefix:203.0.113.0/24 origin_asn:64513 episode_id:ep-42 is_beacon:true divergence_pct:>=25.0 time:last_24h limit:20",
        );
        let (sql, params) = to_sql_and_params(&plan).expect("should build SQL");
        let lower = sql.to_lowercase();

        assert!(lower.contains("\"horizon_bgp_zombies\".\"status\""));
        assert!(lower.contains("\"horizon_bgp_zombies\".\"prefix\""));
        assert!(lower.contains("\"horizon_bgp_zombies\".\"origin_asn\""));
        assert!(lower.contains("\"horizon_bgp_zombies\".\"episode_id\""));
        assert!(lower.contains("\"horizon_bgp_zombies\".\"is_beacon\""));
        assert!(lower.contains("\"horizon_bgp_zombies\".\"divergence_pct\""));
        assert!(params.iter().any(|p| matches!(p, BindParam::Bool(true))));
        assert!(params.iter().any(|p| matches!(p, BindParam::Int(64513))));
    }

    #[test]
    fn horizon_zombies_rejects_invalid_bool_and_unknown_field() {
        let bad_bool = plan_for("in:horizon_zombies is_beacon:maybe");
        assert!(matches!(
            to_sql_and_params(&bad_bool),
            Err(ServiceError::InvalidRequest(_))
        ));

        let unknown = plan_for("in:horizon_zombies bogus:1");
        assert!(matches!(
            to_sql_and_params(&unknown),
            Err(ServiceError::InvalidRequest(_))
        ));
    }
}
