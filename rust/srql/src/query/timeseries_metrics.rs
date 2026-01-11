//! SRQL support for timeseries-backed metrics (generic, SNMP, and rperf).

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::TimeseriesMetricRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::timeseries_metrics::dsl::{
        agent_id as col_agent_id, device_id as col_device_id, if_index as col_if_index,
        metric_name as col_metric_name, metric_type as col_metric_type, partition as col_partition,
        gateway_id as col_gateway_id, target_device_ip as col_target_device_ip, timeseries_metrics,
        timestamp as col_timestamp, value as col_value,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type TimeseriesTable = crate::schema::timeseries_metrics::table;
type TimeseriesFromClause = FromClause<TimeseriesTable>;
type TimeseriesQuery<'a> =
    BoxedSelectStatement<'a, <TimeseriesTable as AsQuery>::SqlType, TimeseriesFromClause, Pg>;

const RPERF_METRIC_TYPE: &str = "rperf";
const SNMP_METRIC_TYPE: &str = "snmp";

#[derive(Clone, Copy)]
enum MetricScope<'a> {
    Any,
    Forced(&'a str),
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    let scope = ensure_entity(plan)?;
    let query = build_query(plan, scope)?;
    let rows: Vec<TimeseriesMetricRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(TimeseriesMetricRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    let scope = ensure_entity(plan)?;
    let query = build_query(plan, scope)?
        .limit(plan.limit)
        .offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

    let mut params = Vec::new();

    if let MetricScope::Forced(metric_type) = scope {
        params.push(BindParam::Text(metric_type.to_string()));
    }

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

fn ensure_entity(plan: &QueryPlan) -> Result<MetricScope<'static>> {
    match plan.entity {
        Entity::TimeseriesMetrics => Ok(MetricScope::Any),
        Entity::SnmpMetrics => Ok(MetricScope::Forced(SNMP_METRIC_TYPE)),
        Entity::RperfMetrics => Ok(MetricScope::Forced(RPERF_METRIC_TYPE)),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by timeseries metrics query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan, scope: MetricScope<'static>) -> Result<TimeseriesQuery<'static>> {
    let mut query = timeseries_metrics.into_boxed::<Pg>();

    if let MetricScope::Forced(metric_type) = scope {
        query = query.filter(col_metric_type.eq(metric_type));
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(apply_ordering(query, &plan.order))
}

fn apply_filter<'a>(
    mut query: TimeseriesQuery<'a>,
    filter: &Filter,
) -> Result<TimeseriesQuery<'a>> {
    match filter.field.as_str() {
        "gateway_id" => {
            query = apply_text_filter!(query, filter, col_gateway_id)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "metric_name" => {
            query = apply_text_filter!(query, filter, col_metric_name)?;
        }
        "metric_type" => {
            query = apply_text_filter!(query, filter, col_metric_type)?;
        }
        "device_id" => {
            query = apply_text_filter!(query, filter, col_device_id)?;
        }
        "target_device_ip" => {
            query = apply_text_filter!(query, filter, col_target_device_ip)?;
        }
        "partition" => {
            query = apply_text_filter!(query, filter, col_partition)?;
        }
        "if_index" => {
            query = apply_if_index_filter(query, filter)?;
        }
        "value" => {
            query = apply_value_filter(query, filter)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for timeseries_metrics: '{other}'"
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
        "gateway_id" | "agent_id" | "metric_name" | "metric_type" | "device_id"
        | "target_device_ip" | "partition" => collect_text_params(params, filter),
        "if_index" => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("invalid if_index value".into()))?;
            params.push(BindParam::Int(i64::from(value)));
            Ok(())
        }
        "value" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            params.push(BindParam::Float(value));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for timeseries_metrics: '{other}'"
        ))),
    }
}

fn apply_if_index_filter<'a>(
    query: TimeseriesQuery<'a>,
    filter: &Filter,
) -> Result<TimeseriesQuery<'a>> {
    let value = filter
        .value
        .as_scalar()?
        .parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest("invalid if_index value".into()))?;

    let query = match filter.op {
        FilterOp::Eq => query.filter(col_if_index.eq(value)),
        FilterOp::NotEq => query.filter(col_if_index.ne(value)),
        _ => {
            return Err(ServiceError::InvalidRequest(
                "if_index filter only supports equality comparisons".into(),
            ))
        }
    };

    Ok(query)
}

fn apply_value_filter<'a>(
    query: TimeseriesQuery<'a>,
    filter: &Filter,
) -> Result<TimeseriesQuery<'a>> {
    let value = parse_f64(filter.value.as_scalar()?)?;
    let query = match filter.op {
        FilterOp::Eq => query.filter(col_value.eq(value)),
        FilterOp::NotEq => query.filter(col_value.ne(value)),
        FilterOp::Gt => query.filter(col_value.gt(value)),
        FilterOp::Gte => query.filter(col_value.ge(value)),
        FilterOp::Lt => query.filter(col_value.lt(value)),
        FilterOp::Lte => query.filter(col_value.le(value)),
        _ => {
            return Err(ServiceError::InvalidRequest(
                "value filter does not support this operator".into(),
            ))
        }
    };

    Ok(query)
}

fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest("invalid numeric value".into()))
}

fn apply_ordering<'a>(
    mut query: TimeseriesQuery<'a>,
    order: &[OrderClause],
) -> TimeseriesQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_primary_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
    }

    if !applied {
        query = query.order(col_timestamp.desc());
    }

    query
}

fn apply_primary_order<'a>(
    query: TimeseriesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> TimeseriesQuery<'a> {
    match field {
        "timestamp" => match direction {
            OrderDirection::Asc => query.order(col_timestamp.asc()),
            OrderDirection::Desc => query.order(col_timestamp.desc()),
        },
        "gateway_id" => match direction {
            OrderDirection::Asc => query.order(col_gateway_id.asc()),
            OrderDirection::Desc => query.order(col_gateway_id.desc()),
        },
        "metric_name" => match direction {
            OrderDirection::Asc => query.order(col_metric_name.asc()),
            OrderDirection::Desc => query.order(col_metric_name.desc()),
        },
        "metric_type" => match direction {
            OrderDirection::Asc => query.order(col_metric_type.asc()),
            OrderDirection::Desc => query.order(col_metric_type.desc()),
        },
        "device_id" => match direction {
            OrderDirection::Asc => query.order(col_device_id.asc()),
            OrderDirection::Desc => query.order(col_device_id.desc()),
        },
        "value" => match direction {
            OrderDirection::Asc => query.order(col_value.asc()),
            OrderDirection::Desc => query.order(col_value.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: TimeseriesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> TimeseriesQuery<'a> {
    match field {
        "timestamp" => match direction {
            OrderDirection::Asc => query.then_order_by(col_timestamp.asc()),
            OrderDirection::Desc => query.then_order_by(col_timestamp.desc()),
        },
        "gateway_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_gateway_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_gateway_id.desc()),
        },
        "metric_name" => match direction {
            OrderDirection::Asc => query.then_order_by(col_metric_name.asc()),
            OrderDirection::Desc => query.then_order_by(col_metric_name.desc()),
        },
        "metric_type" => match direction {
            OrderDirection::Asc => query.then_order_by(col_metric_type.asc()),
            OrderDirection::Desc => query.then_order_by(col_metric_type.desc()),
        },
        "device_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_device_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_device_id.desc()),
        },
        "value" => match direction {
            OrderDirection::Asc => query.then_order_by(col_value.asc()),
            OrderDirection::Desc => query.then_order_by(col_value.desc()),
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
            entity: Entity::TimeseriesMetrics,
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
        };

        let result = build_query(&plan, MetricScope::Any);
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
}
