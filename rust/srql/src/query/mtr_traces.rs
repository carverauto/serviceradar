use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::MtrTraceRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::mtr_traces::dsl::{
        agent_id as col_agent_id, check_name as col_check_name, created_at as col_created_at,
        device_id as col_device_id, error as col_error, id as col_id, mtr_traces,
        protocol as col_protocol, target as col_target, target_ip as col_target_ip,
        target_reached as col_target_reached, time as col_time, total_hops as col_total_hops,
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

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
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
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for mtr_traces: '{other}'"
            )));
        }
    }

    Ok(query)
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
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for mtr_traces: '{other}'"
        ))),
    }
}

fn parse_bool(raw: &str) -> Result<bool> {
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
    fn invalid_boolean_and_unknown_filter_are_rejected() {
        for query in [
            "in:mtr_traces target_reached:maybe",
            "in:mtr_traces unsupported:value",
        ] {
            let result = to_sql_and_params(&plan_for(query));
            assert!(
                matches!(result, Err(ServiceError::InvalidRequest(_))),
                "{query} should be rejected"
            );
        }
    }
}
