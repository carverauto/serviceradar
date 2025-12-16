//! Query module for otel_metrics_hourly_stats continuous aggregate.
//!
//! This CAGG provides pre-computed hourly metrics statistics for efficient dashboard queries.
//! Use `in:otel_metrics_hourly_stats` for fast aggregated KPIs instead of scanning raw metrics.
//!
//! Important: For accurate duration stats, filter by `metric_type:span` as only span metrics
//! contain valid duration data.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::OtelMetricsHourlyStatsRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::otel_metrics_hourly_stats::dsl::{
        avg_duration_ms as col_avg_duration_ms, bucket as col_bucket,
        error_count as col_error_count, metric_type as col_metric_type,
        otel_metrics_hourly_stats, p95_duration_ms as col_p95_duration_ms,
        service_name as col_service_name, total_count as col_total_count,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type StatsTable = crate::schema::otel_metrics_hourly_stats::table;
type StatsFromClause = FromClause<StatsTable>;
type StatsQuery<'a> = BoxedSelectStatement<'a, <StatsTable as AsQuery>::SqlType, StatsFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    let query = build_query(plan)?;
    let rows: Vec<OtelMetricsHourlyStatsRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(OtelMetricsHourlyStatsRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    let query = build_query(plan)?;
    let sql = super::diesel_sql(&query.limit(plan.limit).offset(plan.offset))?;

    let mut params = Vec::new();
    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params(&mut params, filter)?;
    }

    params.push(BindParam::Int(plan.limit));
    params.push(BindParam::Int(plan.offset));

    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::OtelMetricsHourlyStats => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by otel_metrics_hourly_stats query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<StatsQuery<'static>> {
    let mut query = otel_metrics_hourly_stats.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_bucket.ge(*start).and(col_bucket.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: StatsQuery<'a>, filter: &Filter) -> Result<StatsQuery<'a>> {
    match filter.field.as_str() {
        "service_name" | "service" => {
            query = apply_text_filter!(query, filter, col_service_name)?;
        }
        "metric_type" | "type" => {
            query = apply_text_filter!(query, filter, col_metric_type)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for otel_metrics_hourly_stats: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_ordering<'a>(mut query: StatsQuery<'a>, order: &[OrderClause]) -> StatsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "bucket" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_bucket.asc()),
                    OrderDirection::Desc => query.order(col_bucket.desc()),
                },
                "total_count" | "total" => match clause.direction {
                    OrderDirection::Asc => query.order(col_total_count.asc()),
                    OrderDirection::Desc => query.order(col_total_count.desc()),
                },
                "error_count" | "errors" => match clause.direction {
                    OrderDirection::Asc => query.order(col_error_count.asc()),
                    OrderDirection::Desc => query.order(col_error_count.desc()),
                },
                "avg_duration_ms" | "avg_duration" => match clause.direction {
                    OrderDirection::Asc => query.order(col_avg_duration_ms.asc()),
                    OrderDirection::Desc => query.order(col_avg_duration_ms.desc()),
                },
                "p95_duration_ms" | "p95" => match clause.direction {
                    OrderDirection::Asc => query.order(col_p95_duration_ms.asc()),
                    OrderDirection::Desc => query.order(col_p95_duration_ms.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "bucket" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_bucket.asc()),
                    OrderDirection::Desc => query.then_order_by(col_bucket.desc()),
                },
                "total_count" | "total" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_total_count.asc()),
                    OrderDirection::Desc => query.then_order_by(col_total_count.desc()),
                },
                "error_count" | "errors" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_error_count.asc()),
                    OrderDirection::Desc => query.then_order_by(col_error_count.desc()),
                },
                "avg_duration_ms" | "avg_duration" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_avg_duration_ms.asc()),
                    OrderDirection::Desc => query.then_order_by(col_avg_duration_ms.desc()),
                },
                "p95_duration_ms" | "p95" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_p95_duration_ms.asc()),
                    OrderDirection::Desc => query.then_order_by(col_p95_duration_ms.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order(col_bucket.desc());
    }

    query
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "service_name" | "service" | "metric_type" | "type" => collect_text_params(params, filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for otel_metrics_hourly_stats: '{other}'"
        ))),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::Entity;
    use crate::time::TimeRange;
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn builds_basic_query() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::OtelMetricsHourlyStats,
            filters: vec![],
            order: vec![],
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
        };

        let query = build_query(&plan).expect("should build query");
        let sql = super::super::diesel_sql(&query.limit(100).offset(0)).expect("should serialize");

        assert!(sql.to_lowercase().contains("otel_metrics_hourly_stats"));
        assert!(sql.to_lowercase().contains("bucket"));
    }

    #[test]
    fn filters_by_metric_type() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::OtelMetricsHourlyStats,
            filters: vec![crate::parser::Filter {
                field: "metric_type".to_string(),
                op: FilterOp::Eq,
                value: crate::parser::FilterValue::Scalar("span".to_string()),
            }],
            order: vec![],
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
        };

        let query = build_query(&plan).expect("should build query");
        let sql = super::super::diesel_sql(&query.limit(100).offset(0)).expect("should serialize");

        assert!(sql.to_lowercase().contains("metric_type"));
    }
}
