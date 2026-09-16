//! A small batch shares one immutable archive snapshot without changing hot CAGG routing.
use super::{AnalyticsDriver, QueryRequest, TranslateResponse, downsample, plan, translate};
use crate::{
    config::AppConfig,
    error::{Result, ServiceError},
    parser,
};
use serde::Serialize;
use std::collections::HashMap;

#[derive(Debug, Serialize)]
pub struct BatchTranslateResponse {
    pub translation: Option<TranslateResponse>,
    pub lanes: Vec<TranslateResponse>,
}

pub fn translate_batch_with_store_configs(
    config: &AppConfig,
    requests: Vec<QueryRequest>,
    drivers: &HashMap<String, AnalyticsDriver>,
) -> Result<BatchTranslateResponse> {
    if !(2..=4).contains(&requests.len()) || requests.iter().any(|r| r.cursor.is_some()) {
        return Err(ServiceError::InvalidRequest(
            "batch requires two to four cursor-free queries".into(),
        ));
    }
    let now = chrono::Utc::now();
    let mut plans = Vec::with_capacity(requests.len());
    let mut lanes = Vec::with_capacity(requests.len());
    for request in requests {
        let ast = parser::parse(&request.query)?;
        let (plan, _) =
            plan::build_query_plan_with_store_configs_at(config, &request, ast, drivers, now)?;
        if !matches!(plan.entity, parser::Entity::TimeseriesMetrics)
            || plan.downsample.is_none()
            || plan.stats.is_some()
            || plan.rollup_stats.is_some()
            || plan.other
        {
            return Err(ServiceError::InvalidRequest(
                "batch only supports timeseries_metrics downsampling".into(),
            ));
        }
        lanes.push(translate::translate_request_with_store_configs_at(
            config, request, drivers, now,
        )?);
        plans.push(plan);
    }
    let translation = downsample::build_batch(&plans)?.map(|(sql, params)| {
        let first = &lanes[0];
        TranslateResponse {
            sql,
            params,
            pagination: Default::default(),
            viz: None,
            dialect: first.dialect,
            read_store: first.read_store,
            analytics_table: first.analytics_table.clone(),
            time_range: first.time_range.clone(),
        }
    });
    Ok(BatchTranslateResponse { translation, lanes })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(query: &str) -> QueryRequest {
        QueryRequest {
            query: query.into(),
            limit: None,
            cursor: None,
            direction: Default::default(),
            mode: None,
        }
    }

    fn query(aggregate: &str, series: &str, filter: &str) -> QueryRequest {
        request(&format!(
            "in:timeseries_metrics {filter} time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z] bucket:1h agg:{aggregate} series:{series} limit:3"
        ))
    }

    fn config() -> AppConfig {
        AppConfig::embedded("postgres://unused/db".into())
    }

    fn drivers() -> HashMap<String, AnalyticsDriver> {
        HashMap::from([(
            "timeseries_metrics".into(),
            AnalyticsDriver::Named("pg_duckdb".into()),
        )])
    }

    #[test]
    fn batch_rejects_invalid_bounds_and_validates_every_lane() {
        for size in [0, 1, 5] {
            assert!(
                translate_batch_with_store_configs(
                    &config(),
                    vec![query("avg", "metric_name", ""); size],
                    &drivers()
                )
                .is_err()
            );
        }
        assert!(
            translate_batch_with_store_configs(
                &config(),
                vec![
                    query("avg", "metric_name", ""),
                    query("avg", "metric_name", "not_a_column:bad")
                ],
                &drivers()
            )
            .is_err()
        );
    }

    #[test]
    fn batch_rejects_special_scoped_and_non_metric_entities_on_hot_store() {
        for other in [
            "in:dashboards",
            "in:dashboard",
            "in:logs",
            "in:flows time:last_1h bucket:5m",
            "in:cpu time:last_1h bucket:5m",
        ] {
            assert!(
                translate_batch_with_store_configs(
                    &config(),
                    vec![query("avg", "metric_name", ""), request(other)],
                    &HashMap::new()
                )
                .is_err(),
                "{other} must not bypass its ordinary query contract"
            );
        }
    }

    #[test]
    fn batch_shares_scan_but_keeps_same_series_lanes_distinct() {
        let response = translate_batch_with_store_configs(
            &config(),
            vec![
                query("avg", "metric_name", "metric_name:alpha"),
                query("max", "metric_name", "metric_name:beta"),
            ],
            &drivers(),
        )
        .unwrap();
        let sql = response.translation.unwrap().sql;
        assert_eq!(sql.matches("FROM timeseries_metrics").count(), 1);
        assert!(sql.contains("(timestamp,series_0),(timestamp,series_1)"));
        assert!(sql.contains("AVG(CASE WHEN include_0 THEN value END)"));
        assert!(sql.contains("MAX(CASE WHEN include_1 THEN value END)"));
        assert!(sql.contains("bool_or(include_0)"));
        assert!(sql.contains("bool_or(include_1)"));
    }

    #[test]
    fn batch_preserves_missing_tags_and_individual_limit_order() {
        let mut newest = query("max", "core_id", "device_id:synthetic-device");
        newest.query.push_str(" sort:timestamp:desc");
        newest.limit = Some(7);
        let response = translate_batch_with_store_configs(
            &config(),
            vec![query("avg", "metric_name", ""), newest],
            &drivers(),
        )
        .unwrap();
        let sql = response.translation.unwrap().sql;
        assert!(sql.contains("coalesce((tags::JSON ->> 'core_id'), '')"));
        assert!(sql.contains("batch_index IN (1)"));
        assert!(sql.contains("WHEN 0 THEN 3 WHEN 1 THEN 7"));
        assert!(sql.contains("ORDER BY batch_index,timestamp ASC,series ASC NULLS FIRST"));
    }

    #[test]
    fn batch_retains_hot_cagg_and_rate_routes() {
        let requests = vec![query("avg", "metric_name", ""), query("max", "core_id", "")];
        let response =
            translate_batch_with_store_configs(&config(), requests, &HashMap::new()).unwrap();
        assert!(response.translation.is_none());
        assert!(response.lanes[0].sql.contains("timeseries_metrics_hourly"));
        assert!(
            translate_batch_with_store_configs(
                &config(),
                vec![
                    query("avg", "metric_name", ""),
                    query("rate", "metric_name", "")
                ],
                &drivers()
            )
            .is_err()
        );
    }

    #[test]
    fn batch_pins_relative_time_once_and_rejects_mixed_windows() {
        let requests = vec![
            request("in:timeseries_metrics time:last_90d bucket:12h agg:avg series:metric_name"),
            request("in:timeseries_metrics time:last_90d bucket:12h agg:max series:core_id"),
        ];
        let response = translate_batch_with_store_configs(&config(), requests, &drivers()).unwrap();
        assert!(response.translation.is_some());
        assert_eq!(
            response.lanes[0].time_range.as_ref().unwrap().end,
            response.lanes[1].time_range.as_ref().unwrap().end
        );
        let mut other_window = query("avg", "metric_name", "");
        other_window.query = other_window.query.replace("2026-01-02", "2026-01-03");
        assert!(
            translate_batch_with_store_configs(
                &config(),
                vec![query("avg", "metric_name", ""), other_window],
                &drivers()
            )
            .is_err()
        );
    }
}
