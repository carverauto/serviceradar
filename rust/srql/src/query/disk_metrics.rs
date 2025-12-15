use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::DiskMetricRow,
    parser::{Entity, Filter, OrderClause, OrderDirection},
    schema::disk_metrics::dsl::{
        agent_id as col_agent_id, available_bytes as col_available_bytes,
        device_id as col_device_id, device_name as col_device_name, disk_metrics,
        host_id as col_host_id, mount_point as col_mount_point, partition as col_partition,
        poller_id as col_poller_id, timestamp as col_timestamp, total_bytes as col_total_bytes,
        usage_percent as col_usage_percent, used_bytes as col_used_bytes,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel::QueryDsl;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type DiskTable = crate::schema::disk_metrics::table;
type DiskFromClause = FromClause<DiskTable>;
type DiskQuery<'a> = BoxedSelectStatement<'a, <DiskTable as AsQuery>::SqlType, DiskFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<DiskMetricRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(DiskMetricRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
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
        Entity::DiskMetrics => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by disk metrics query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<DiskQuery<'static>> {
    let mut query = disk_metrics.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: DiskQuery<'a>, filter: &Filter) -> Result<DiskQuery<'a>> {
    match filter.field.as_str() {
        "poller_id" => {
            query = apply_text_filter!(query, filter, col_poller_id)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "host_id" => {
            query = apply_text_filter!(query, filter, col_host_id)?;
        }
        "device_id" => {
            query = apply_text_filter!(query, filter, col_device_id)?;
        }
        "partition" => {
            query = apply_text_filter!(query, filter, col_partition)?;
        }
        "mount_point" => {
            query = apply_text_filter!(query, filter, col_mount_point)?;
        }
        "device_name" => {
            query = apply_text_filter!(query, filter, col_device_name)?;
        }
        "usage_percent" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_usage_percent,
                value,
                "usage_percent filter only supports equality"
            )?;
        }
        "total_bytes" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_total_bytes,
                value,
                "total_bytes filter only supports equality"
            )?;
        }
        "used_bytes" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_used_bytes,
                value,
                "used_bytes filter only supports equality"
            )?;
        }
        "available_bytes" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_available_bytes,
                value,
                "available_bytes filter only supports equality"
            )?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for disk_metrics: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        crate::parser::FilterOp::Eq
        | crate::parser::FilterOp::NotEq
        | crate::parser::FilterOp::Like
        | crate::parser::FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
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
        "poller_id" | "agent_id" | "host_id" | "device_id" | "partition" | "mount_point"
        | "device_name" => collect_text_params(params, filter),
        "usage_percent" => {
            params.push(BindParam::Float(parse_f64(filter.value.as_scalar()?)?));
            Ok(())
        }
        "total_bytes" | "used_bytes" | "available_bytes" => {
            params.push(BindParam::Int(parse_i64(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for disk_metrics: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(mut query: DiskQuery<'a>, order: &[OrderClause]) -> DiskQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_primary_order(query, clause)
        } else {
            apply_secondary_order(query, clause)
        };
    }

    if !applied {
        query = query.order(col_timestamp.desc());
    }

    query
}

fn apply_primary_order<'a>(query: DiskQuery<'a>, clause: &OrderClause) -> DiskQuery<'a> {
    match clause.field.as_str() {
        "timestamp" => match clause.direction {
            OrderDirection::Asc => query.order(col_timestamp.asc()),
            OrderDirection::Desc => query.order(col_timestamp.desc()),
        },
        "usage_percent" => match clause.direction {
            OrderDirection::Asc => query.order(col_usage_percent.asc()),
            OrderDirection::Desc => query.order(col_usage_percent.desc()),
        },
        "poller_id" => match clause.direction {
            OrderDirection::Asc => query.order(col_poller_id.asc()),
            OrderDirection::Desc => query.order(col_poller_id.desc()),
        },
        "device_id" => match clause.direction {
            OrderDirection::Asc => query.order(col_device_id.asc()),
            OrderDirection::Desc => query.order(col_device_id.desc()),
        },
        "host_id" => match clause.direction {
            OrderDirection::Asc => query.order(col_host_id.asc()),
            OrderDirection::Desc => query.order(col_host_id.desc()),
        },
        "mount_point" => match clause.direction {
            OrderDirection::Asc => query.order(col_mount_point.asc()),
            OrderDirection::Desc => query.order(col_mount_point.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(query: DiskQuery<'a>, clause: &OrderClause) -> DiskQuery<'a> {
    match clause.field.as_str() {
        "timestamp" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_timestamp.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_timestamp.desc()),
        },
        "usage_percent" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_usage_percent.asc()),
            OrderDirection::Desc => {
                diesel::QueryDsl::then_order_by(query, col_usage_percent.desc())
            }
        },
        "poller_id" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_poller_id.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_poller_id.desc()),
        },
        "device_id" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_device_id.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_device_id.desc()),
        },
        "host_id" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_host_id.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_host_id.desc()),
        },
        "mount_point" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_mount_point.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_mount_point.desc()),
        },
        _ => query,
    }
}

fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest("value must be numeric".into()))
}

fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest("value must be an integer".into()))
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
            entity: Entity::DiskMetrics,
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
}
