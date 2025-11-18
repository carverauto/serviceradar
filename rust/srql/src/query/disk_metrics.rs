use super::QueryPlan;
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
        _ => {}
    }

    Ok(query)
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
