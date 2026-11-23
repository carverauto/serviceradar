use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::HorizonOutageRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::horizon_outages::dsl::{
        avg_forwarding_loss_pct as col_avg_forwarding_loss_pct,
        avg_synthetic_failure_pct as col_avg_synthetic_failure_pct,
        corroborating_pop_count as col_corroborating_pop_count,
        covering_prefix as col_covering_prefix, entity_key as col_entity_key,
        entity_type as col_entity_type, horizon_outages, origin_asn as col_origin_asn,
        outage_id as col_outage_id, region as col_region, severity as col_severity,
        status as col_status, time as col_time,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type HorizonOutagesTable = crate::schema::horizon_outages::table;
type HorizonOutagesFromClause = FromClause<HorizonOutagesTable>;
type HorizonOutagesQuery<'a> = BoxedSelectStatement<
    'a,
    <HorizonOutagesTable as AsQuery>::SqlType,
    HorizonOutagesFromClause,
    Pg,
>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    super::reject_stats(plan, "horizon_outages")?;
    let query = build_query(plan)?;
    let rows: Vec<HorizonOutageRow> = query
        .select(HorizonOutageRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<HorizonOutageRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(HorizonOutageRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    super::reject_stats(plan, "horizon_outages")?;
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
        Entity::HorizonOutages => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by horizon_outages query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<HorizonOutagesQuery<'static>> {
    let mut query = horizon_outages.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_time.ge(*start).and(col_time.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(apply_ordering(query, &plan.order))
}

fn apply_filter<'a>(
    mut query: HorizonOutagesQuery<'a>,
    filter: &Filter,
) -> Result<HorizonOutagesQuery<'a>> {
    match filter.field.as_str() {
        "outage_id" => query = apply_text_filter!(query, filter, col_outage_id)?,
        "status" => query = apply_text_filter!(query, filter, col_status)?,
        "severity" => query = apply_text_filter!(query, filter, col_severity)?,
        "entity_type" => query = apply_text_filter!(query, filter, col_entity_type)?,
        "entity_key" => query = apply_text_filter!(query, filter, col_entity_key)?,
        "region" => query = apply_text_filter!(query, filter, col_region)?,
        "prefix" | "covering_prefix" => {
            query = apply_text_filter!(query, filter, col_covering_prefix)?;
        }
        "origin_asn" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_origin_asn, value)?;
        }
        "corroborating_pop_count" => {
            let value = parse_i32(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_corroborating_pop_count, value)?;
        }
        "avg_forwarding_loss_pct" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_avg_forwarding_loss_pct, value)?;
        }
        "avg_synthetic_failure_pct" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            query = apply_ordered_filter!(query, filter, col_avg_synthetic_failure_pct, value)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for horizon_outages: '{other}'"
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
        "outage_id" | "status" | "severity" | "entity_type" | "entity_key" | "region"
        | "prefix" | "covering_prefix" => collect_text_params(params, filter),
        "origin_asn" => {
            params.push(BindParam::Int(parse_i64(filter.value.as_scalar()?)?));
            Ok(())
        }
        "corroborating_pop_count" => {
            params.push(BindParam::Int(i64::from(parse_i32(
                filter.value.as_scalar()?,
            )?)));
            Ok(())
        }
        "avg_forwarding_loss_pct" | "avg_synthetic_failure_pct" => {
            params.push(BindParam::Float(parse_f64(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for horizon_outages: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: HorizonOutagesQuery<'a>,
    order: &[OrderClause],
) -> HorizonOutagesQuery<'a> {
    let mut applied = false;
    for clause in order {
        let recognized = matches!(
            clause.field.as_str(),
            "time"
                | "timestamp"
                | "severity"
                | "status"
                | "corroborating_pop_count"
                | "avg_forwarding_loss_pct"
        );
        if !recognized {
            continue;
        }
        query = if !applied {
            applied = true;
            match (clause.field.as_str(), clause.direction) {
                ("time" | "timestamp", OrderDirection::Asc) => query.order(col_time.asc()),
                ("time" | "timestamp", OrderDirection::Desc) => query.order(col_time.desc()),
                ("severity", OrderDirection::Asc) => query.order(col_severity.asc()),
                ("severity", OrderDirection::Desc) => query.order(col_severity.desc()),
                ("status", OrderDirection::Asc) => query.order(col_status.asc()),
                ("status", OrderDirection::Desc) => query.order(col_status.desc()),
                ("corroborating_pop_count", OrderDirection::Asc) => {
                    query.order(col_corroborating_pop_count.asc())
                }
                ("corroborating_pop_count", OrderDirection::Desc) => {
                    query.order(col_corroborating_pop_count.desc())
                }
                ("avg_forwarding_loss_pct", OrderDirection::Asc) => {
                    query.order(col_avg_forwarding_loss_pct.asc())
                }
                ("avg_forwarding_loss_pct", OrderDirection::Desc) => {
                    query.order(col_avg_forwarding_loss_pct.desc())
                }
                _ => query,
            }
        } else {
            match (clause.field.as_str(), clause.direction) {
                ("time" | "timestamp", OrderDirection::Asc) => query.then_order_by(col_time.asc()),
                ("time" | "timestamp", OrderDirection::Desc) => {
                    query.then_order_by(col_time.desc())
                }
                ("severity", OrderDirection::Asc) => query.then_order_by(col_severity.asc()),
                ("severity", OrderDirection::Desc) => query.then_order_by(col_severity.desc()),
                ("status", OrderDirection::Asc) => query.then_order_by(col_status.asc()),
                ("status", OrderDirection::Desc) => query.then_order_by(col_status.desc()),
                ("corroborating_pop_count", OrderDirection::Asc) => {
                    query.then_order_by(col_corroborating_pop_count.asc())
                }
                ("corroborating_pop_count", OrderDirection::Desc) => {
                    query.then_order_by(col_corroborating_pop_count.desc())
                }
                ("avg_forwarding_loss_pct", OrderDirection::Asc) => {
                    query.then_order_by(col_avg_forwarding_loss_pct.asc())
                }
                ("avg_forwarding_loss_pct", OrderDirection::Desc) => {
                    query.then_order_by(col_avg_forwarding_loss_pct.desc())
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
    fn horizon_outages_sql_includes_filters_and_bind_parity() {
        let plan = plan_for(
            "in:horizon_outages status:active severity:major entity_type:asn entity_key:AS13335 region:us-east prefix:1.1.1.0/24 origin_asn:13335 outage_id:out-1 time:last_24h limit:25",
        );
        let (sql, params) = to_sql_and_params(&plan).expect("should build SQL");
        let lower = sql.to_lowercase();

        assert!(lower.contains("\"horizon_outages\".\"status\""));
        assert!(lower.contains("\"horizon_outages\".\"severity\""));
        assert!(lower.contains("\"horizon_outages\".\"entity_type\""));
        assert!(lower.contains("\"horizon_outages\".\"entity_key\""));
        assert!(lower.contains("\"horizon_outages\".\"region\""));
        assert!(lower.contains("\"horizon_outages\".\"covering_prefix\""));
        assert!(lower.contains("\"horizon_outages\".\"origin_asn\""));
        assert!(lower.contains("\"horizon_outages\".\"outage_id\""));
        assert!(params.iter().any(|p| matches!(p, BindParam::Int(13335))));
        assert!(
            params
                .iter()
                .any(|p| matches!(p, BindParam::Text(v) if v == "1.1.1.0/24"))
        );
    }

    #[test]
    fn horizon_outages_supports_alias_and_numeric_comparisons() {
        let plan = plan_for(
            "in:horizon_outage covering_prefix:203.0.113.0/24 corroborating_pop_count:>=3 avg_forwarding_loss_pct:>10.5 sort:severity:desc",
        );
        let (sql, params) = to_sql_and_params(&plan).expect("should build SQL");
        assert!(sql.to_lowercase().contains("\"horizon_outages\""));
        assert!(params.iter().any(|p| matches!(p, BindParam::Int(3))));
        assert!(
            params
                .iter()
                .any(|p| matches!(p, BindParam::Float(v) if (*v - 10.5).abs() < f64::EPSILON))
        );
    }

    #[test]
    fn horizon_outages_rejects_unknown_filter() {
        let plan = plan_for("in:horizon_outages unknown_col:abc");
        let result = to_sql_and_params(&plan);
        assert!(matches!(result, Err(ServiceError::InvalidRequest(_))));
    }
}
