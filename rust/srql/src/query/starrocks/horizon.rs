//! StarRocks-only SRQL dialect for Horizon telemetry entities:
//! `in:horizon_outages`, `in:horizon_bgp`, `in:horizon_zombies`,
//! `in:horizon_paths` (`priv/starrocks/0044_horizon_tables.sql`), and
//! `in:horizon_isp_accountability`
//! (`priv/starrocks/0045_horizon_isp_accountability_mv.sql`).

mod specs;
#[cfg(test)]
mod tests;

use super::super::{PaginationMeta, QueryPlan, TranslateResponse, types::BindParam};
use super::{pg_order_sql, text_filter_sql};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
};
use specs::{
    BGP_SPEC, HorizonSpec, ISP_ACCOUNTABILITY_SPEC, OUTAGES_SPEC, PATHS_SPEC, ZOMBIES_SPEC,
};

pub(super) fn translate(plan: &QueryPlan, database: &str) -> Result<TranslateResponse> {
    let spec = spec_for(&plan.entity)?;
    refuse_unsupported_clauses(plan, spec.entity_name)?;

    let from = format!("{database}.{}", spec.table);
    let (mut predicates, params) = time_bounds(spec, plan);
    for filter in &plan.filters {
        predicates.push(filter_sql(spec, filter)?);
    }

    let where_sql = if predicates.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", predicates.join(" AND "))
    };

    let select_list = spec
        .columns
        .iter()
        .map(|col| quoted(col))
        .collect::<Vec<_>>()
        .join(", ");
    let order_sql = order_clause(spec, &plan.order);
    let sql = format!(
        "SELECT {select_list} FROM {from}{where_sql} ORDER BY {order_sql} LIMIT {} OFFSET {}",
        plan.limit, plan.offset
    );

    Ok(TranslateResponse {
        read_model: None,
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
        },
        viz: super::super::viz::meta_for_plan(plan),
    })
}

fn spec_for(entity: &Entity) -> Result<&'static HorizonSpec> {
    match entity {
        Entity::HorizonOutages => Ok(&OUTAGES_SPEC),
        Entity::HorizonBgp => Ok(&BGP_SPEC),
        Entity::HorizonZombies => Ok(&ZOMBIES_SPEC),
        Entity::HorizonPaths => Ok(&PATHS_SPEC),
        Entity::HorizonIspAccountability => Ok(&ISP_ACCOUNTABILITY_SPEC),
        other => Err(ServiceError::Internal(anyhow::anyhow!(
            "the StarRocks Horizon dialect was handed {other:?}"
        ))),
    }
}

fn refuse_unsupported_clauses(plan: &QueryPlan, entity_name: &str) -> Result<()> {
    super::super::reject_stats(plan, entity_name)?;

    if let Some(kind) = plan
        .rollup_stats
        .as_deref()
        .map(str::trim)
        .filter(|kind| !kind.is_empty())
    {
        return Err(ServiceError::InvalidRequest(format!(
            "rollup_stats:{kind} is not supported for {entity_name}"
        )));
    }

    if plan.downsample.is_some() {
        return Err(ServiceError::InvalidRequest(format!(
            "bucket: is not supported for {entity_name}"
        )));
    }

    if plan.other {
        return Err(ServiceError::InvalidRequest(
            "other:true is currently supported only for flow or timeseries stats".into(),
        ));
    }

    Ok(())
}

fn quoted(column: &str) -> String {
    format!("`{column}`")
}

fn time_bounds(spec: &HorizonSpec, plan: &QueryPlan) -> (Vec<String>, Vec<BindParam>) {
    let Some(range) = &plan.time_range else {
        return (Vec::new(), Vec::new());
    };
    let literal = |value: chrono::DateTime<chrono::Utc>| {
        format!("'{}'", value.format("%Y-%m-%d %H:%M:%S%.6f"))
    };
    let time_col = quoted(spec.time_column);
    (
        vec![
            format!("{time_col} >= {}", literal(range.start)),
            format!("{time_col} <= {}", literal(range.end)),
        ],
        vec![
            BindParam::timestamptz(range.start),
            BindParam::timestamptz(range.end),
        ],
    )
}

fn filter_sql(spec: &HorizonSpec, filter: &Filter) -> Result<String> {
    let field = filter.field.as_str();
    if spec.text_fields.contains(&field) {
        return text_filter_sql(&quoted(field), filter, true);
    }
    if spec.i32_fields.contains(&field) {
        let value = parse_i32(filter.value.as_scalar()?)?;
        return numeric_sql(field, filter.op.clone(), &value.to_string());
    }
    if spec.i64_fields.contains(&field) {
        let value = parse_i64(filter.value.as_scalar()?)?;
        return numeric_sql(field, filter.op.clone(), &value.to_string());
    }
    if spec.f64_fields.contains(&field) {
        let value = parse_f64(filter.value.as_scalar()?)?;
        return numeric_sql(field, filter.op.clone(), &value.to_string());
    }
    if spec.bool_fields.contains(&field) {
        let value = parse_bool(filter.value.as_scalar()?)?;
        let op = match filter.op {
            FilterOp::Eq => "=",
            FilterOp::NotEq => "<>",
            _ => {
                return Err(ServiceError::InvalidRequest(format!(
                    "{field} only supports equality comparisons"
                )));
            }
        };
        let literal = if value { "TRUE" } else { "FALSE" };
        return Ok(format!("{} {op} {literal}", quoted(field)));
    }

    Err(ServiceError::InvalidRequest(format!(
        "unsupported filter field for {}: '{field}'",
        spec.entity_name
    )))
}

fn numeric_sql(field: &str, op: FilterOp, literal: &str) -> Result<String> {
    let sql_op = match op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{field} supports equality and ordered comparisons"
            )));
        }
    };
    Ok(format!("{} {sql_op} {literal}", quoted(field)))
}

fn order_clause(spec: &HorizonSpec, order: &[OrderClause]) -> String {
    let terms: Vec<String> = order
        .iter()
        .filter_map(|clause| {
            let field = if clause.field == "time" {
                spec.time_column
            } else {
                clause.field.as_str()
            };
            spec.sort_fields
                .contains(&field)
                .then(|| format!("{} {}", quoted(field), pg_order_sql(clause.direction)))
        })
        .collect();

    if terms.is_empty() {
        format!(
            "{} {}",
            quoted(spec.time_column),
            pg_order_sql(OrderDirection::Desc)
        )
    } else {
        terms.join(", ")
    }
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

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean '{raw}'"
        ))),
    }
}
