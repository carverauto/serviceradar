use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::BmpRoutingEventRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::bmp_routing_events::dsl::{
        bmp_routing_events, created_at as col_created_at, event_type as col_event_type,
        id as col_id, local_asn as col_local_asn, message as col_message, peer_asn as col_peer_asn,
        peer_ip as col_peer_ip, prefix as col_prefix, raw_data as col_raw_data,
        router_id as col_router_id, router_ip as col_router_ip, severity_id as col_severity_id,
        time as col_time,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type BmpEventsTable = crate::schema::bmp_routing_events::table;
type BmpEventsFromClause = FromClause<BmpEventsTable>;
type BmpEventsQuery<'a> =
    BoxedSelectStatement<'a, <BmpEventsTable as AsQuery>::SqlType, BmpEventsFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<BmpRoutingEventRow> = query
        .select(BmpRoutingEventRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<BmpRoutingEventRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(BmpRoutingEventRow::into_json)
        .collect())
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
        Entity::BmpEvents => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by bmp_events query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<BmpEventsQuery<'static>> {
    let mut query = bmp_routing_events.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_time.ge(*start).and(col_time.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: BmpEventsQuery<'a>, filter: &Filter) -> Result<BmpEventsQuery<'a>> {
    match filter.field.as_str() {
        "id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_id,
                parse_uuid(filter.value.as_scalar()?)?,
                "id only supports equality comparisons"
            )?;
        }
        "event_type" => {
            query = apply_text_filter!(query, filter, col_event_type)?;
        }
        "router_id" => {
            query = apply_text_filter!(query, filter, col_router_id)?;
        }
        "router_ip" => {
            query = apply_text_filter!(query, filter, col_router_ip)?;
        }
        "peer_ip" => {
            query = apply_text_filter!(query, filter, col_peer_ip)?;
        }
        "prefix" => {
            query = apply_text_filter!(query, filter, col_prefix)?;
        }
        "message" => {
            query = apply_text_filter!(query, filter, col_message)?;
        }
        "raw_data" => {
            query = apply_text_filter!(query, filter, col_raw_data)?;
        }
        "severity_id" => {
            let value = parse_i32(filter.value.as_scalar()?)?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_severity_id.eq(value)),
                FilterOp::NotEq => query.filter(col_severity_id.ne(value)),
                FilterOp::Gt => query.filter(col_severity_id.gt(value)),
                FilterOp::Gte => query.filter(col_severity_id.ge(value)),
                FilterOp::Lt => query.filter(col_severity_id.lt(value)),
                FilterOp::Lte => query.filter(col_severity_id.le(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "severity_id only supports scalar numeric operators".into(),
                    ))
                }
            };
        }
        "peer_asn" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_peer_asn.eq(value)),
                FilterOp::NotEq => query.filter(col_peer_asn.ne(value)),
                FilterOp::Gt => query.filter(col_peer_asn.gt(value)),
                FilterOp::Gte => query.filter(col_peer_asn.ge(value)),
                FilterOp::Lt => query.filter(col_peer_asn.lt(value)),
                FilterOp::Lte => query.filter(col_peer_asn.le(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "peer_asn only supports scalar numeric operators".into(),
                    ))
                }
            };
        }
        "local_asn" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_local_asn.eq(value)),
                FilterOp::NotEq => query.filter(col_local_asn.ne(value)),
                FilterOp::Gt => query.filter(col_local_asn.gt(value)),
                FilterOp::Gte => query.filter(col_local_asn.ge(value)),
                FilterOp::Lt => query.filter(col_local_asn.lt(value)),
                FilterOp::Lte => query.filter(col_local_asn.le(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "local_asn only supports scalar numeric operators".into(),
                    ))
                }
            };
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for bmp_events: '{other}'"
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

fn collect_i64_param(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    let value = parse_i64(filter.value.as_scalar()?)?;
    params.push(BindParam::Int(value));
    Ok(())
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "event_type" | "router_id" | "router_ip" | "peer_ip" | "prefix" | "message"
        | "raw_data" => collect_text_params(params, filter),
        "severity_id" | "peer_asn" | "local_asn" => collect_i64_param(params, filter),
        "id" => {
            params.push(BindParam::Uuid(parse_uuid(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for bmp_events: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(mut query: BmpEventsQuery<'a>, order: &[OrderClause]) -> BmpEventsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "time" | "event_timestamp" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_time.asc()),
                    OrderDirection::Desc => query.order(col_time.desc()),
                },
                "created_at" => match clause.direction {
                    OrderDirection::Asc => query.order(col_created_at.asc()),
                    OrderDirection::Desc => query.order(col_created_at.desc()),
                },
                "severity_id" => match clause.direction {
                    OrderDirection::Asc => query.order(col_severity_id.asc()),
                    OrderDirection::Desc => query.order(col_severity_id.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "time" | "event_timestamp" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_time.asc()),
                    OrderDirection::Desc => query.then_order_by(col_time.desc()),
                },
                "created_at" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_created_at.asc()),
                    OrderDirection::Desc => query.then_order_by(col_created_at.desc()),
                },
                "severity_id" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_severity_id.asc()),
                    OrderDirection::Desc => query.then_order_by(col_severity_id.desc()),
                },
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

fn parse_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
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

    #[test]
    fn bmp_events_sql_includes_routing_filters() {
        let plan =
            plan_for("in:bmp_events router_ip:10.42.68.85 event_type:route_update time:last_1h");
        let (sql, params) = to_sql_and_params(&plan).expect("should build SQL");
        let lower = sql.to_lowercase();

        assert!(lower.contains("\"bmp_routing_events\".\"router_ip\""));
        assert!(lower.contains("\"bmp_routing_events\".\"event_type\""));
        assert!(params
            .iter()
            .any(|param| { matches!(param, BindParam::Text(value) if value == "10.42.68.85") }));
    }

    #[test]
    fn bmp_events_unknown_filter_field_returns_error() {
        let plan = plan_for("in:bmp_events unsupported:value");
        let result = to_sql_and_params(&plan);
        assert!(matches!(result, Err(ServiceError::InvalidRequest(_))));
    }
}
