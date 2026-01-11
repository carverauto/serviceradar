use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::gateways::dsl::{
        agent_count as col_agent_count, checker_count as col_checker_count,
        component_id as col_component_id, created_by as col_created_by,
        first_registered as col_first_registered, first_seen as col_first_seen,
        is_healthy as col_is_healthy, last_seen as col_last_seen, gateway_id as col_gateway_id,
        gateways, registration_source as col_registration_source,
        spiffe_identity as col_spiffe_identity, status as col_status, updated_at as col_updated_at,
    },
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, BoxedSqlQuery, FromClause, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, BigInt, Bool, Float8, Int4, Jsonb, Nullable, Text, Timestamptz};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type GatewaysTable = crate::schema::gateways::table;
type GatewaysFromClause = FromClause<GatewaysTable>;
type GatewaysQuery<'a> =
    BoxedSelectStatement<'a, <GatewaysTable as AsQuery>::SqlType, GatewaysFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    // Use raw SQL query with QueryableByName to work around diesel-async's
    // 15-column tuple limit (diesel-async doesn't have 64-column-tables feature)
    let (sql, params) = to_sql_and_params(plan)?;

    let mut query = sql_query(&sql).into_boxed::<Pg>();
    for param in params {
        query = bind_param(query, param)?;
    }

    let rows: Vec<GatewayRowRow> = query
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(GatewayRowRow::into_json).collect())
}

fn bind_param<'a>(
    query: BoxedSqlQuery<'a, Pg, SqlQuery>,
    param: BindParam,
) -> Result<BoxedSqlQuery<'a, Pg, SqlQuery>> {
    match param {
        BindParam::Text(value) => Ok(query.bind::<Text, _>(value)),
        BindParam::TextArray(values) => Ok(query.bind::<Array<Text>, _>(values)),
        BindParam::IntArray(values) => Ok(query.bind::<Array<BigInt>, _>(values)),
        BindParam::Bool(value) => Ok(query.bind::<Bool, _>(value)),
        BindParam::Int(value) => Ok(query.bind::<BigInt, _>(value)),
        BindParam::Float(value) => Ok(query.bind::<Float8, _>(value)),
        BindParam::Timestamptz(value) => {
            let timestamp = chrono::DateTime::parse_from_rfc3339(&value)
                .map(|dt| dt.with_timezone(&chrono::Utc))
                .map_err(|err| {
                    ServiceError::Internal(anyhow::anyhow!(
                        "invalid timestamptz bind {value:?}: {err}"
                    ))
                })?;
            Ok(query.bind::<Timestamptz, _>(timestamp))
        }
    }
}

#[derive(Debug, QueryableByName)]
struct GatewayRowRow {
    #[diesel(sql_type = Text)]
    gateway_id: String,
    #[diesel(sql_type = Nullable<Text>)]
    component_id: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    registration_source: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    status: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    spiffe_identity: Option<String>,
    #[diesel(sql_type = Nullable<Timestamptz>)]
    first_registered: Option<DateTime<Utc>>,
    #[diesel(sql_type = Nullable<Timestamptz>)]
    first_seen: Option<DateTime<Utc>>,
    #[diesel(sql_type = Nullable<Timestamptz>)]
    last_seen: Option<DateTime<Utc>>,
    #[diesel(sql_type = Nullable<Jsonb>)]
    metadata: Option<serde_json::Value>,
    #[diesel(sql_type = Nullable<Text>)]
    created_by: Option<String>,
    #[diesel(sql_type = Nullable<Bool>)]
    is_healthy: Option<bool>,
    #[diesel(sql_type = Nullable<Int4>)]
    agent_count: Option<i32>,
    #[diesel(sql_type = Nullable<Int4>)]
    checker_count: Option<i32>,
    #[diesel(sql_type = Nullable<Timestamptz>)]
    updated_at: Option<DateTime<Utc>>,
}

impl GatewayRowRow {
    fn into_json(self) -> serde_json::Value {
        serde_json::json!({
            "gateway_id": self.gateway_id,
            "component_id": self.component_id,
            "registration_source": self.registration_source,
            "status": self.status,
            "spiffe_identity": self.spiffe_identity,
            "first_registered": self.first_registered,
            "first_seen": self.first_seen,
            "last_seen": self.last_seen,
            "metadata": self.metadata.unwrap_or(serde_json::json!({})),
            "created_by": self.created_by,
            "is_healthy": self.is_healthy,
            "agent_count": self.agent_count.unwrap_or(0),
            "checker_count": self.checker_count.unwrap_or(0),
            "updated_at": self.updated_at,
        })
    }
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
        Entity::Gateways => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by gateways query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<GatewaysQuery<'static>> {
    let mut query = gateways.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_last_seen.ge(*start).and(col_last_seen.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: GatewaysQuery<'a>, filter: &Filter) -> Result<GatewaysQuery<'a>> {
    match filter.field.as_str() {
        "gateway_id" => {
            query = apply_text_filter!(query, filter, col_gateway_id)?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "component_id" => {
            query = apply_text_filter!(query, filter, col_component_id)?;
        }
        "registration_source" => {
            query = apply_text_filter!(query, filter, col_registration_source)?;
        }
        "spiffe_identity" => {
            query = apply_text_filter!(query, filter, col_spiffe_identity)?;
        }
        "created_by" => {
            query = apply_text_filter!(query, filter, col_created_by)?;
        }
        "is_healthy" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => query = query.filter(col_is_healthy.eq(value)),
                FilterOp::NotEq => query = query.filter(col_is_healthy.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "is_healthy filter only supports equality".into(),
                    ))
                }
            }
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for gateways: '{other}'"
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
        "gateway_id"
        | "status"
        | "component_id"
        | "registration_source"
        | "spiffe_identity"
        | "created_by" => collect_text_params(params, filter),
        "is_healthy" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            params.push(BindParam::Bool(value));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(mut query: GatewaysQuery<'a>, order: &[OrderClause]) -> GatewaysQuery<'a> {
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
        query = query.order(col_last_seen.desc());
    }

    query
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{raw}'"
        ))),
    }
}

fn apply_single_order<'a>(
    query: GatewaysQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> GatewaysQuery<'a> {
    match field {
        "last_seen" => match direction {
            OrderDirection::Asc => query.order(col_last_seen.asc()),
            OrderDirection::Desc => query.order(col_last_seen.desc()),
        },
        "first_seen" => match direction {
            OrderDirection::Asc => query.order(col_first_seen.asc()),
            OrderDirection::Desc => query.order(col_first_seen.desc()),
        },
        "first_registered" => match direction {
            OrderDirection::Asc => query.order(col_first_registered.asc()),
            OrderDirection::Desc => query.order(col_first_registered.desc()),
        },
        "gateway_id" => match direction {
            OrderDirection::Asc => query.order(col_gateway_id.asc()),
            OrderDirection::Desc => query.order(col_gateway_id.desc()),
        },
        "status" => match direction {
            OrderDirection::Asc => query.order(col_status.asc()),
            OrderDirection::Desc => query.order(col_status.desc()),
        },
        "agent_count" => match direction {
            OrderDirection::Asc => query.order(col_agent_count.asc()),
            OrderDirection::Desc => query.order(col_agent_count.desc()),
        },
        "checker_count" => match direction {
            OrderDirection::Asc => query.order(col_checker_count.asc()),
            OrderDirection::Desc => query.order(col_checker_count.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.order(col_updated_at.asc()),
            OrderDirection::Desc => query.order(col_updated_at.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: GatewaysQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> GatewaysQuery<'a> {
    match field {
        "last_seen" => match direction {
            OrderDirection::Asc => query.then_order_by(col_last_seen.asc()),
            OrderDirection::Desc => query.then_order_by(col_last_seen.desc()),
        },
        "first_seen" => match direction {
            OrderDirection::Asc => query.then_order_by(col_first_seen.asc()),
            OrderDirection::Desc => query.then_order_by(col_first_seen.desc()),
        },
        "first_registered" => match direction {
            OrderDirection::Asc => query.then_order_by(col_first_registered.asc()),
            OrderDirection::Desc => query.then_order_by(col_first_registered.desc()),
        },
        "gateway_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_gateway_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_gateway_id.desc()),
        },
        "status" => match direction {
            OrderDirection::Asc => query.then_order_by(col_status.asc()),
            OrderDirection::Desc => query.then_order_by(col_status.desc()),
        },
        "agent_count" => match direction {
            OrderDirection::Asc => query.then_order_by(col_agent_count.asc()),
            OrderDirection::Desc => query.then_order_by(col_agent_count.desc()),
        },
        "checker_count" => match direction {
            OrderDirection::Asc => query.then_order_by(col_checker_count.asc()),
            OrderDirection::Desc => query.then_order_by(col_checker_count.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_updated_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_updated_at.desc()),
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
            entity: Entity::Gateways,
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
}
