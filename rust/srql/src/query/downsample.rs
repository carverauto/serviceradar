mod bind;
mod fields;
mod filters;
mod row;
mod sql;

use self::{
    row::DownsampleRow,
    sql::{build_bind_values, build_params, build_sql, rewrite_placeholders},
};
use super::{BindParam, QueryPlan};
use crate::error::{Result, ServiceError};
use diesel::{pg::Pg, sql_query};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    let sql = build_sql(plan)?;
    let params = build_params(plan)?;
    Ok((rewrite_placeholders(&sql), params))
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    let sql = build_sql(plan)?;
    let mut query = sql_query(rewrite_placeholders(&sql)).into_boxed::<Pg>();

    for bind in build_bind_values(plan)? {
        query = bind.apply(query);
    }

    let rows: Vec<DownsampleRow> = query
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(|row| {
            serde_json::json!({
                "timestamp": row.timestamp.to_rfc3339(),
                "series": row.series,
                "value": row.value,
            })
        })
        .collect())
}
