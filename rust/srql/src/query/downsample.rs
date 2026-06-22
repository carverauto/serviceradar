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

#[cfg(test)]
mod tests {
    use super::to_sql_and_params;
    use crate::{
        parser::{DownsampleAgg, DownsampleSpec, Entity},
        query::QueryPlan,
        time::TimeRange,
    };
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn flow_downsample_coalesces_nullable_directional_volume_fields() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::minutes(30);

        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: Some(DownsampleSpec {
                bucket_seconds: 60,
                agg: DownsampleAgg::Sum,
                series: Some("protocol_group".to_string()),
                value_field: Some("bytes_in".to_string()),
            }),
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let (sql, _params) = to_sql_and_params(&plan).unwrap();

        assert!(
            sql.contains(
                "SUM((COALESCE(bytes_in, 0)::double precision * GREATEST(COALESCE(sampling_rate, 1), 1)::double precision)) AS value"
            ),
            "expected nullable flow downsample field to be coalesced before aggregation: {sql}"
        );
    }
}
