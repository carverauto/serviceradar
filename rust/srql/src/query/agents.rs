//! Query execution for OCSF agents entity.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::AgentRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::ocsf_agents::dsl::{
        capabilities as col_capabilities, created_time as col_created_time,
        first_seen_time as col_first_seen_time, ip as col_ip,
        last_seen_time as col_last_seen_time, modified_time as col_modified_time,
        name as col_name, ocsf_agents, poller_id as col_poller_id, type_id as col_type_id,
        uid as col_uid, vendor_name as col_vendor_name, version as col_version,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
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
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(AgentRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
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
        Entity::Agents => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by agents query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<AgentsQuery<'static>> {
    let mut query = ocsf_agents.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_last_seen_time.ge(*start).and(col_last_seen_time.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: AgentsQuery<'a>, filter: &Filter) -> Result<AgentsQuery<'a>> {
    match filter.field.as_str() {
        "uid" => {
            query = apply_text_filter!(query, filter, col_uid)?;
        }
        "name" => {
            query = apply_text_filter!(query, filter, col_name)?;
        }
        "poller_id" => {
            query = apply_text_filter!(query, filter, col_poller_id)?;
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
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("type_id must be an integer".into()))?;
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
                        query = query.filter(diesel::dsl::not(
                            col_capabilities.overlaps_with(values),
                        ));
                    }
                    _ => {
                        return Err(ServiceError::InvalidRequest(
                            "capabilities filter only supports equality/containment".into(),
                        ));
                    }
                }
            }
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for agents: '{other}'"
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
        "uid" | "name" | "poller_id" | "version" | "vendor_name" | "ip" => {
            collect_text_params(params, filter)
        }
        "type_id" => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("type_id must be an integer".into()))?;
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
        "poller_id" => match direction {
            OrderDirection::Asc => query.order(col_poller_id.asc()),
            OrderDirection::Desc => query.order(col_poller_id.desc()),
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
        "poller_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_poller_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_poller_id.desc()),
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
    fn builds_query_with_poller_filter() {
        let plan = QueryPlan {
            entity: Entity::Agents,
            filters: vec![Filter {
                field: "poller_id".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("poller-1".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
        };

        let result = build_query(&plan);
        assert!(result.is_ok(), "should build query with poller filter");
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
        };

        let result = build_query(&plan);
        assert!(result.is_ok(), "should build query with type_id filter");
    }
}
