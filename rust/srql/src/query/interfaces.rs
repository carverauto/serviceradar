mod bind;
mod filters;
mod order;
mod rows;
mod sql;
mod stats;

#[cfg(test)]
mod tests;

use self::{
    bind::bind_param,
    rows::{InterfaceRow, StatsPayload},
    sql::build_query_sql,
    stats::{build_stats_sql, parse_stats_spec},
};
use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    parser::Entity,
};
use diesel::pg::Pg;
use diesel::sql_query;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    if let Some(stats) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let stats_sql = build_stats_sql(plan, &stats)?;
        let mut query = sql_query(&stats_sql.sql).into_boxed::<Pg>();
        for param in stats_sql.binds {
            query = bind_param(query, param)?;
        }
        let rows: Vec<StatsPayload> = query
            .load::<StatsPayload>(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows
            .into_iter()
            .filter_map(|row| row.payload.map(serde_json::Value::from))
            .collect());
    }

    let query_sql = build_query_sql(plan)?;
    let mut query = sql_query(&query_sql.sql).into_boxed::<Pg>();
    for param in query_sql.binds {
        query = bind_param(query, param)?;
    }

    let rows: Vec<InterfaceRow> = query
        .load::<InterfaceRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(InterfaceRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<super::BindParam>)> {
    ensure_entity(plan)?;

    if let Some(stats) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let stats_sql = build_stats_sql(plan, &stats)?;
        return Ok((stats_sql.sql, stats_sql.binds));
    }

    let query_sql = build_query_sql(plan)?;
    Ok((query_sql.sql, query_sql.binds))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Interfaces => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by interfaces query".into(),
        )),
    }
}
