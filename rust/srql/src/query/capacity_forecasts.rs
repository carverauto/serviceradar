use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::CapacityForecastRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::capacity_forecasts::dsl::{
        capacity_forecasts, confidence as col_confidence, current_value as col_current_value,
        exhaustion_threshold as col_exhaustion_threshold, forecasted_at as col_forecasted_at,
        horizon_ends_at as col_horizon_ends_at, horizon_seconds as col_horizon_seconds,
        metric_class as col_metric_class, metric_name as col_metric_name, model as col_model,
        projected_exhaustion_at as col_projected_exhaustion_at,
        projected_value as col_projected_value, resource_id as col_resource_id,
        resource_key as col_resource_key, resource_label as col_resource_label,
        resource_type as col_resource_type, sample_count as col_sample_count,
        skip_reason as col_skip_reason, status as col_status,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type CapacityForecastsTable = crate::schema::capacity_forecasts::table;
type CapacityForecastsFromClause = FromClause<CapacityForecastsTable>;
type CapacityForecastsQuery<'a> = BoxedSelectStatement<
    'a,
    <CapacityForecastsTable as AsQuery>::SqlType,
    CapacityForecastsFromClause,
    Pg,
>;

macro_rules! apply_float_filter {
    ($query:expr, $filter:expr, $column:expr) => {{
        let value = parse_f64($filter.value.as_scalar()?, &$filter.field)?;
        match $filter.op {
            FilterOp::Eq => $query.filter($column.eq(value)),
            FilterOp::NotEq => $query.filter($column.ne(value)),
            FilterOp::Gt => $query.filter($column.gt(value)),
            FilterOp::Gte => $query.filter($column.ge(value)),
            FilterOp::Lt => $query.filter($column.lt(value)),
            FilterOp::Lte => $query.filter($column.le(value)),
            _ => {
                return Err(ServiceError::InvalidRequest(format!(
                    "{} filter expects numeric comparison",
                    $filter.field
                )));
            }
        }
    }};
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<CapacityForecastRow> = query
        .select(CapacityForecastRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<CapacityForecastRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(CapacityForecastRow::into_json)
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
        Entity::CapacityForecasts => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by capacity forecasts query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<CapacityForecastsQuery<'static>> {
    let mut query = capacity_forecasts.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_forecasted_at.ge(*start).and(col_forecasted_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: CapacityForecastsQuery<'a>,
    filter: &Filter,
) -> Result<CapacityForecastsQuery<'a>> {
    match filter.field.as_str() {
        "resource_key" => query = apply_text_filter!(query, filter, col_resource_key)?,
        "resource_type" => query = apply_text_filter!(query, filter, col_resource_type)?,
        "resource_id" => query = apply_text_filter!(query, filter, col_resource_id)?,
        "resource_label" => query = apply_text_filter!(query, filter, col_resource_label)?,
        "metric_class" => query = apply_text_filter!(query, filter, col_metric_class)?,
        "metric_name" => query = apply_text_filter!(query, filter, col_metric_name)?,
        "model" => query = apply_text_filter!(query, filter, col_model)?,
        "status" => query = apply_text_filter!(query, filter, col_status)?,
        "skip_reason" => query = apply_text_filter!(query, filter, col_skip_reason)?,
        "horizon_seconds" => {
            let value = parse_i64(filter.value.as_scalar()?, "horizon_seconds")?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_horizon_seconds.eq(value)),
                FilterOp::NotEq => query.filter(col_horizon_seconds.ne(value)),
                FilterOp::Gt => query.filter(col_horizon_seconds.gt(value)),
                FilterOp::Gte => query.filter(col_horizon_seconds.ge(value)),
                FilterOp::Lt => query.filter(col_horizon_seconds.lt(value)),
                FilterOp::Lte => query.filter(col_horizon_seconds.le(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "horizon_seconds filter expects numeric comparison".into(),
                    ));
                }
            };
        }
        "sample_count" => {
            let value = parse_i32(filter.value.as_scalar()?, "sample_count")?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_sample_count.eq(value)),
                FilterOp::NotEq => query.filter(col_sample_count.ne(value)),
                FilterOp::Gt => query.filter(col_sample_count.gt(value)),
                FilterOp::Gte => query.filter(col_sample_count.ge(value)),
                FilterOp::Lt => query.filter(col_sample_count.lt(value)),
                FilterOp::Lte => query.filter(col_sample_count.le(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "sample_count filter expects numeric comparison".into(),
                    ));
                }
            };
        }
        "current_value" => query = apply_float_filter!(query, filter, col_current_value),
        "projected_value" => query = apply_float_filter!(query, filter, col_projected_value),
        "confidence" => query = apply_float_filter!(query, filter, col_confidence),
        "exhaustion_threshold" => {
            query = apply_float_filter!(query, filter, col_exhaustion_threshold)
        }
        "has_exhaustion" => {
            let value = parse_bool(filter.value.as_scalar()?, "has_exhaustion")?;
            query = match filter.op {
                FilterOp::Eq => {
                    if value {
                        query.filter(col_projected_exhaustion_at.is_not_null())
                    } else {
                        query.filter(col_projected_exhaustion_at.is_null())
                    }
                }
                FilterOp::NotEq => {
                    if value {
                        query.filter(col_projected_exhaustion_at.is_null())
                    } else {
                        query.filter(col_projected_exhaustion_at.is_not_null())
                    }
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "has_exhaustion filter expects true/false equality".into(),
                    ));
                }
            };
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for capacity_forecasts: '{other}'"
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
        "resource_key" | "resource_type" | "resource_id" | "resource_label" | "metric_class"
        | "metric_name" | "model" | "status" | "skip_reason" => collect_text_params(params, filter),
        "has_exhaustion" => Ok(()),
        "horizon_seconds" => {
            params.push(BindParam::Int(parse_i64(
                filter.value.as_scalar()?,
                "horizon_seconds",
            )?));
            Ok(())
        }
        "sample_count" => {
            params.push(BindParam::Int(i64::from(parse_i32(
                filter.value.as_scalar()?,
                "sample_count",
            )?)));
            Ok(())
        }
        "current_value" | "projected_value" | "confidence" | "exhaustion_threshold" => {
            params.push(BindParam::Float(parse_f64(
                filter.value.as_scalar()?,
                &filter.field,
            )?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for capacity_forecasts: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: CapacityForecastsQuery<'a>,
    order: &[OrderClause],
) -> CapacityForecastsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "forecasted_at" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_forecasted_at.asc()),
                    OrderDirection::Desc => query.order(col_forecasted_at.desc()),
                },
                "horizon_ends_at" => match clause.direction {
                    OrderDirection::Asc => query.order(col_horizon_ends_at.asc()),
                    OrderDirection::Desc => query.order(col_horizon_ends_at.desc()),
                },
                "projected_exhaustion_at" => match clause.direction {
                    OrderDirection::Asc => query.order(col_projected_exhaustion_at.asc()),
                    OrderDirection::Desc => query.order(col_projected_exhaustion_at.desc()),
                },
                "resource_key" => match clause.direction {
                    OrderDirection::Asc => query.order(col_resource_key.asc()),
                    OrderDirection::Desc => query.order(col_resource_key.desc()),
                },
                "metric_name" => match clause.direction {
                    OrderDirection::Asc => query.order(col_metric_name.asc()),
                    OrderDirection::Desc => query.order(col_metric_name.desc()),
                },
                "status" => match clause.direction {
                    OrderDirection::Asc => query.order(col_status.asc()),
                    OrderDirection::Desc => query.order(col_status.desc()),
                },
                "current_value" => match clause.direction {
                    OrderDirection::Asc => query.order(col_current_value.asc()),
                    OrderDirection::Desc => query.order(col_current_value.desc()),
                },
                "projected_value" => match clause.direction {
                    OrderDirection::Asc => query.order(col_projected_value.asc()),
                    OrderDirection::Desc => query.order(col_projected_value.desc()),
                },
                "confidence" => match clause.direction {
                    OrderDirection::Asc => query.order(col_confidence.asc()),
                    OrderDirection::Desc => query.order(col_confidence.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "forecasted_at" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_forecasted_at.asc()),
                    OrderDirection::Desc => query.then_order_by(col_forecasted_at.desc()),
                },
                "horizon_ends_at" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_horizon_ends_at.asc()),
                    OrderDirection::Desc => query.then_order_by(col_horizon_ends_at.desc()),
                },
                "projected_exhaustion_at" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_projected_exhaustion_at.asc()),
                    OrderDirection::Desc => query.then_order_by(col_projected_exhaustion_at.desc()),
                },
                "resource_key" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_resource_key.asc()),
                    OrderDirection::Desc => query.then_order_by(col_resource_key.desc()),
                },
                "metric_name" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_metric_name.asc()),
                    OrderDirection::Desc => query.then_order_by(col_metric_name.desc()),
                },
                "status" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_status.asc()),
                    OrderDirection::Desc => query.then_order_by(col_status.desc()),
                },
                "current_value" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_current_value.asc()),
                    OrderDirection::Desc => query.then_order_by(col_current_value.desc()),
                },
                "projected_value" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_projected_value.asc()),
                    OrderDirection::Desc => query.then_order_by(col_projected_value.desc()),
                },
                "confidence" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_confidence.asc()),
                    OrderDirection::Desc => query.then_order_by(col_confidence.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order(col_forecasted_at.desc());
    }

    query
}

fn parse_i64(value: &str, field: &str) -> Result<i64> {
    value.parse::<i64>().map_err(|_| {
        ServiceError::InvalidRequest(format!("{field} filter expects an integer value"))
    })
}

fn parse_bool(value: &str, field: &str) -> Result<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" | "on" => Ok(true),
        "false" | "0" | "no" | "off" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "{field} filter expects a boolean value"
        ))),
    }
}

fn parse_i32(value: &str, field: &str) -> Result<i32> {
    value.parse::<i32>().map_err(|_| {
        ServiceError::InvalidRequest(format!("{field} filter expects an integer value"))
    })
}

fn parse_f64(value: &str, field: &str) -> Result<f64> {
    value
        .parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("{field} filter expects a number")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        config::AppConfig,
        parser,
        query::{QueryRequest, build_query_plan},
    };

    fn plan(query: &str) -> QueryPlan {
        let request = QueryRequest {
            query: query.to_string(),
            limit: Some(25),
            cursor: None,
            direction: Default::default(),
            mode: None,
        };
        let ast = parser::parse(query).expect("parse capacity forecast query");
        build_query_plan(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            &request,
            ast,
        )
        .expect("build capacity forecast plan")
    }

    #[test]
    fn translates_capacity_forecasts_query() {
        let plan = plan("in:capacity_forecasts status:projected sort:forecasted_at:desc limit:10");
        let (sql, params) = to_sql_and_params(&plan).expect("translate capacity forecast query");

        assert!(sql.contains("FROM \"capacity_forecasts\""));
        assert!(sql.contains("\"status\" = $1"));
        assert!(sql.contains("ORDER BY \"capacity_forecasts\".\"forecasted_at\" DESC"));
        assert!(
            matches!(params.as_slice().first(), Some(BindParam::Text(value)) if value == "projected")
        );
    }

    #[test]
    fn supports_numeric_projection_filters() {
        let plan = plan("in:capacity_forecasts projected_value:>80 confidence:>=0.8 limit:10");
        let (_sql, params) = to_sql_and_params(&plan).expect("translate numeric filters");

        assert!(matches!(
            (params.as_slice().first(), params.as_slice().get(1)),
            (Some(BindParam::Float(projected)), Some(BindParam::Float(confidence)))
                if *projected == 80.0 && *confidence == 0.8
        ));
    }

    #[test]
    fn supports_has_exhaustion_filter() {
        let plan = plan("in:capacity_forecasts has_exhaustion:true limit:10");
        let (sql, params) = to_sql_and_params(&plan).expect("translate exhaustion filter");

        assert!(sql.contains("\"capacity_forecasts\".\"projected_exhaustion_at\" IS NOT NULL"));
        assert!(
            params
                .iter()
                .all(|param| !matches!(param, BindParam::Text(value) if value == "true"))
        );
    }
}
