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

    fn flow_plan(bucket_seconds: i64, agg: DownsampleAgg, span: ChronoDuration) -> QueryPlan {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        QueryPlan {
            entity: Entity::Flows,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 4000,
            offset: 0,
            time_range: Some(TimeRange {
                start,
                end: start + span,
            }),
            stats: None,
            downsample: Some(DownsampleSpec {
                bucket_seconds,
                agg,
                series: None,
                value_field: Some("bytes_total".to_string()),
            }),
            rollup_stats: None,
            other: false,
            include_deleted: false,
        }
    }

    #[test]
    fn flow_avg_throughput_routes_to_5m_cagg_with_current_bucket_union() {
        let plan = flow_plan(300, DownsampleAgg::Avg, ChronoDuration::hours(24));
        let (sql, params) = to_sql_and_params(&plan).unwrap();

        // Closed buckets from the materialized CAGG ...
        assert!(
            sql.contains("FROM ocsf_network_activity_5m_traffic"),
            "expected closed buckets to read from the 5m traffic CAGG: {sql}"
        );
        // ... the current open bucket from the raw hypertable ...
        assert!(
            sql.contains("UNION ALL") && sql.contains("FROM ocsf_network_activity\n"),
            "expected the current open bucket to be unioned from the raw hypertable: {sql}"
        );
        // ... and AVG reconstructed from the weighted SUM / flow COUNT.
        assert!(
            sql.contains("SUM(weighted_sum) / NULLIF(SUM(cnt), 0) AS value"),
            "expected sampling-rate-weighted avg to be reconstructed from the CAGG: {sql}"
        );
        assert!(
            sql.contains("flow_count::double precision AS cnt")
                && sql.contains(
                    "SUM((bytes_total::double precision * GREATEST(COALESCE(sampling_rate, 1), 1)::double precision)) AS weighted_sum"
                ),
            "expected CAGG and raw sides to share sampling-rate-weighted semantics: {sql}"
        );
        // start, end (CAGG upper), end (raw upper), limit, offset.
        assert_eq!(params.len(), 5, "unexpected bind count: {sql}");
    }

    #[test]
    fn flow_sum_throughput_routes_to_cagg_union() {
        let plan = flow_plan(300, DownsampleAgg::Sum, ChronoDuration::hours(24));
        let (sql, _params) = to_sql_and_params(&plan).unwrap();

        assert!(
            sql.contains("FROM ocsf_network_activity_5m_traffic")
                && sql.contains("UNION ALL")
                && sql.contains("SUM(weighted_sum) AS value"),
            "expected sum throughput to route to the CAGG union: {sql}"
        );
    }

    #[test]
    fn flow_avg_long_window_routes_to_hourly_cagg() {
        let plan = flow_plan(3600, DownsampleAgg::Avg, ChronoDuration::hours(48));
        let (sql, _params) = to_sql_and_params(&plan).unwrap();

        assert!(
            sql.contains("FROM flow_traffic_1h"),
            "expected hourly buckets to route to flow_traffic_1h: {sql}"
        );
    }

    #[test]
    fn snmp_rate_downsample_keeps_regex_literal_and_bind_numbering_aligned() {
        // Regression for fj #4408: the `?` regex quantifier inside the
        // max_counter_rate_per_second literal was rewritten to `$1`, shifting every
        // real bind and making Postgres fail all agg:rate queries with 42P18.
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let plan = QueryPlan {
            entity: Entity::SnmpMetrics,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 4000,
            offset: 0,
            time_range: Some(TimeRange {
                start,
                end: start + ChronoDuration::hours(6),
            }),
            stats: None,
            downsample: Some(DownsampleSpec {
                bucket_seconds: 300,
                agg: DownsampleAgg::Rate,
                series: None,
                value_field: None,
            }),
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let (sql, params) = to_sql_and_params(&plan).unwrap();

        // The plausibility-ceiling regex literal must survive placeholder rewriting
        // intact (no `$N` injected into the quoted string).
        assert!(
            sql.contains(r"~ '^[0-9]+(\.[0-9]+){0,1}$'"),
            "expected the max_counter_rate regex literal to survive rewriting: {sql}"
        );
        // Every `?` must have been rewritten; none may remain.
        assert!(
            !sql.contains('?'),
            "unrewritten placeholder left behind: {sql}"
        );
        // The number of `$N` placeholders must match the bind list exactly
        // (start, end, metric_type, limit, offset).
        let placeholder_count = (1..).take_while(|n| sql.contains(&format!("${n}"))).count();
        assert_eq!(
            placeholder_count,
            params.len(),
            "placeholder count must match bind count: {sql}"
        );
        assert_eq!(
            params.len(),
            5,
            "unexpected bind count for snmp rate plan: {sql}"
        );
    }

    #[test]
    fn flow_avg_short_window_stays_on_raw_table() {
        // Below the 6h CAGG routing threshold: must stay on the raw hypertable.
        let plan = flow_plan(300, DownsampleAgg::Avg, ChronoDuration::hours(1));
        let (sql, _params) = to_sql_and_params(&plan).unwrap();

        assert!(
            sql.contains("FROM ocsf_network_activity\n") && !sql.contains("5m_traffic"),
            "expected sub-threshold window to stay on the raw hypertable: {sql}"
        );
        assert!(
            sql.contains(
                "AVG((bytes_total::double precision * GREATEST(COALESCE(sampling_rate, 1), 1)::double precision)) AS value"
            ),
            "expected raw avg to keep the sampling-rate-weighted expression: {sql}"
        );
    }
}
