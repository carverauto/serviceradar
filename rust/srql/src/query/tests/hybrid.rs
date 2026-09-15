use super::*;
use crate::pagination::{CursorStore, HybridCursor, decode_cursor_state, encode_hybrid_cursor};
use chrono::{DateTime, TimeZone, Utc};
use std::collections::HashMap;

fn request(query: &str) -> QueryRequest {
    QueryRequest {
        query: query.into(),
        limit: Some(25),
        cursor: None,
        direction: QueryDirection::Next,
        mode: None,
    }
}

fn drivers(days: i64) -> HashMap<String, AnalyticsDriver> {
    HashMap::from([(
        "timeseries_metrics".into(),
        AnalyticsDriver::Policy(AnalyticsPolicy::Hybrid {
            hot_window_days: days,
        }),
    )])
}

fn now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 6, 15, 12, 0, 0).unwrap()
}

fn planned(
    request: &QueryRequest,
    drivers: &HashMap<String, AnalyticsDriver>,
    now: DateTime<Utc>,
) -> Result<(QueryPlan, Option<HybridCursor>), ServiceError> {
    super::super::plan::build_query_plan_with_store_configs_at(
        &test_config(),
        request,
        parser::parse(&request.query)?,
        drivers,
        now,
    )
}

#[test]
fn hybrid_routes_whole_window_with_inclusive_hot_cutoff() {
    for (query, expected) in [
        (
            "in:timeseries_metrics time:last_24h",
            CursorStore::Timescale,
        ),
        ("in:snmp time:last_30d", CursorStore::Timescale),
        (
            "in:rperf time:[2026-05-16T12:00:00Z,2026-06-15T12:00:00Z]",
            CursorStore::Timescale,
        ),
        (
            "in:timeseries_metrics time:[2026-05-16T11:59:59.999999Z,2026-06-15T12:00:00Z]",
            CursorStore::PgDuckdb,
        ),
        (
            "in:snmp time:[2026-05-01T00:00:00Z,2026-05-02T00:00:00Z]",
            CursorStore::PgDuckdb,
        ),
        ("in:timeseries_metrics", CursorStore::PgDuckdb),
    ] {
        let (plan, route) = planned(&request(query), &drivers(30), now()).unwrap();
        assert_eq!(route.unwrap().store, expected, "{query}");
        assert_eq!(plan.dialect.is_duckdb(), expected == CursorStore::PgDuckdb);
    }
    let (_, route) = planned(&request("in:snmp time:last_8d"), &drivers(7), now()).unwrap();
    assert_eq!(route.unwrap().store, CursorStore::PgDuckdb);
    let (plan, route) = planned(&request("in:devices"), &drivers(30), now()).unwrap();
    assert_eq!(plan.dialect, SqlDialect::Postgres);
    assert!(route.is_none());
}

#[test]
fn hybrid_resolves_entity_defaults_before_routing() {
    let config: HashMap<String, AnalyticsDriver> =
        serde_json::from_str(r#"{"logs":{"driver":"hybrid","hot_window_days":30}}"#).unwrap();
    let (plan, route) = planned(&request("in:logs"), &config, now()).unwrap();
    assert_eq!(route.unwrap().store, CursorStore::Timescale);
    assert_eq!(
        plan.time_range.unwrap().start,
        now() - ChronoDuration::hours(24)
    );
}

#[test]
fn hybrid_driver_json_preserves_named_modes_and_rejects_malformed_policies() {
    let parsed: HashMap<String, AnalyticsDriver> =
        serde_json::from_str(r#"{"timeseries_metrics":{"driver":"hybrid"},"logs":"pg_duckdb"}"#)
            .unwrap();
    let (_, route) = planned(&request("in:snmp time:last_30d"), &parsed, now()).unwrap();
    assert_eq!(route.unwrap().store, CursorStore::Timescale);
    let (_, route) = planned(&request("in:snmp time:last_31d"), &parsed, now()).unwrap();
    assert_eq!(route.unwrap().store, CursorStore::PgDuckdb);
    let (plan, route) = planned(&request("in:logs time:last_1h"), &parsed, now()).unwrap();
    assert_eq!(plan.dialect, SqlDialect::Duckdb);
    assert!(route.is_none());

    for json in [
        r#"{"timeseries_metrics":{"driver":"invalid"}}"#,
        r#"{"timeseries_metrics":{"driver":"hybrid","hot_window_days":"30"}}"#,
        r#"{"timeseries_metrics":{"driver":"hybrid","unrecognized":true}}"#,
    ] {
        assert!(serde_json::from_str::<HashMap<String, AnalyticsDriver>>(json).is_err());
    }
    let missing_policy = HashMap::from([(
        "timeseries_metrics".into(),
        AnalyticsDriver::Named("hybrid".into()),
    )]);
    assert!(planned(&request("in:snmp time:last_1h"), &missing_policy, now()).is_err());
    for days in [0, -1, i64::MAX] {
        assert!(planned(&request("in:snmp time:last_1h"), &drivers(days), now()).is_err());
    }
}

#[test]
fn hybrid_hot_translation_keeps_postgres_sql_and_signed_absolute_pagination() {
    let config = test_config();
    let query = request("in:snmp time:last_1h metric_name:ifInOctets limit:25");
    let first = translate_request_with_store_configs(&config, query.clone(), &drivers(30)).unwrap();
    assert_eq!(first.read_store, Some(CursorStore::Timescale));
    assert_eq!(first.dialect, SqlDialect::Postgres);
    assert_eq!(first.analytics_table.as_deref(), Some("timeseries_metrics"));
    let window = first.time_range.as_ref().unwrap();
    let next = first.pagination.next_cursor.as_ref().unwrap();
    let state = decode_cursor_state(next, &config.cursor_secret, config.max_cursor_offset).unwrap();
    assert_eq!(state.time_range.as_ref(), Some(window));
    assert_eq!(state.hybrid.as_ref().unwrap().store, CursorStore::Timescale);

    let mut absolute = query.clone();
    absolute.query = format!(
        "in:snmp time:[{},{}] metric_name:ifInOctets limit:25",
        window.start.to_rfc3339(),
        window.end.to_rfc3339()
    );
    let pure = translate_request(&config, absolute).unwrap();
    assert_eq!(first.sql, pure.sql);
    assert_eq!(
        serde_json::to_value(&first.params).unwrap(),
        serde_json::to_value(&pure.params).unwrap()
    );

    let mut continuation = query;
    continuation.cursor = Some(next.clone());
    let second = translate_request_with_store_configs(&config, continuation, &drivers(30)).unwrap();
    assert_eq!(second.time_range, first.time_range);
    assert_eq!(second.read_store, first.read_store);
    let previous = second.pagination.prev_cursor.unwrap();
    let previous_state =
        decode_cursor_state(&previous, &config.cursor_secret, config.max_cursor_offset).unwrap();
    assert_eq!(previous_state.offset, 0);
    assert_eq!(previous_state.time_range, first.time_range);
    assert_eq!(previous_state.hybrid, state.hybrid);
}

#[test]
fn hybrid_cold_translation_keeps_duckdb_dialect_for_the_entire_crossing_window() {
    let config = test_config();
    let query =
        request("in:snmp time:last_31d metric_name:ifInOctets bucket:1h agg:rate series:if_index");
    let translated = translate_request_with_store_configs(&config, query, &drivers(30)).unwrap();
    assert_eq!(translated.read_store, Some(CursorStore::PgDuckdb));
    assert_eq!(translated.dialect, SqlDialect::Duckdb);
    assert!(translated.sql.contains("_partition_date"));
    assert!(!translated.sql.contains("timeseries_metrics_hourly"));
    let state = decode_cursor_state(
        &translated.pagination.next_cursor.unwrap(),
        &config.cursor_secret,
        config.max_cursor_offset,
    )
    .unwrap();
    assert_eq!(state.time_range, translated.time_range);
    assert_eq!(state.hybrid.unwrap().store, CursorStore::PgDuckdb);
}

#[test]
fn hybrid_hot_continuation_does_not_slide_and_expires_instead_of_switching_stores() {
    let mut query = request("in:snmp time:last_1h");
    let (first, route) = planned(&query, &drivers(30), now()).unwrap();
    query.cursor = Some(
        encode_hybrid_cursor(
            25,
            &test_config().cursor_secret,
            first.time_range.as_ref(),
            &route.unwrap(),
        )
        .unwrap(),
    );

    let (next, _) = planned(&query, &drivers(30), now() + ChronoDuration::hours(1)).unwrap();
    assert_eq!(next.time_range, first.time_range);
    assert_eq!(next.offset, 25);
    let error = planned(&query, &drivers(30), now() + ChronoDuration::days(31)).unwrap_err();
    assert!(error.to_string().contains("hot window has expired"));
}

#[test]
fn hybrid_cold_cursor_pins_store_even_when_retention_expands() {
    let mut query = request("in:snmp time:last_8d");
    let (first, route) = planned(&query, &drivers(7), now()).unwrap();
    query.cursor = Some(
        encode_hybrid_cursor(
            25,
            &test_config().cursor_secret,
            first.time_range.as_ref(),
            &route.unwrap(),
        )
        .unwrap(),
    );
    let (next, route) = planned(&query, &drivers(30), now()).unwrap();
    assert_eq!(next.time_range, first.time_range);
    assert_eq!(route.unwrap().store, CursorStore::PgDuckdb);
}

#[test]
fn hybrid_unbounded_cursor_stays_unbounded() {
    let mut query = request("in:timeseries_metrics");
    let (first, route) = planned(&query, &drivers(30), now()).unwrap();
    assert!(first.time_range.is_none());
    query.cursor = Some(
        encode_hybrid_cursor(25, &test_config().cursor_secret, None, &route.unwrap()).unwrap(),
    );
    query.query = "in:timeseries_metrics time:last_1h".into();
    let (next, route) = planned(&query, &drivers(30), now()).unwrap();
    assert!(next.time_range.is_none());
    assert_eq!(route.unwrap().store, CursorStore::PgDuckdb);
}

#[test]
fn hybrid_cursors_reject_changed_table_policy_and_legacy_continuations() {
    let mut query = request("in:snmp time:last_1h");
    let (first, route) = planned(&query, &drivers(30), now()).unwrap();
    query.cursor = Some(
        encode_hybrid_cursor(
            25,
            &test_config().cursor_secret,
            first.time_range.as_ref(),
            &route.unwrap(),
        )
        .unwrap(),
    );
    assert!(
        planned(&query, &HashMap::new(), now())
            .unwrap_err()
            .to_string()
            .contains("same hybrid table policy")
    );

    let mut changed = drivers(30);
    changed.insert(
        "logs".into(),
        AnalyticsDriver::Policy(AnalyticsPolicy::Hybrid {
            hot_window_days: 30,
        }),
    );
    query.query = "in:logs time:last_1h".into();
    assert!(
        planned(&query, &changed, now())
            .unwrap_err()
            .to_string()
            .contains("table does not match")
    );

    query.query = "in:snmp time:last_1h".into();
    query.cursor = Some(encode_cursor(25, &test_config().cursor_secret).unwrap());
    assert!(
        planned(&query, &drivers(30), now())
            .unwrap_err()
            .to_string()
            .contains("require a hybrid cursor")
    );
}

#[test]
fn hybrid_typed_named_driver_translation_is_identical_to_legacy_map() {
    let config = test_config();
    let query = request("in:snmp time:[2026-05-01T00:00:00Z,2026-05-02T00:00:00Z]");
    for driver in ["timescale", "pg_duckdb"] {
        let old = HashMap::from([("timeseries_metrics".into(), driver.into())]);
        let typed = HashMap::from([(
            "timeseries_metrics".into(),
            AnalyticsDriver::Named(driver.into()),
        )]);
        let legacy = translate_request_with_drivers(&config, query.clone(), &old).unwrap();
        let updated = translate_request_with_store_configs(&config, query.clone(), &typed).unwrap();
        assert_eq!(
            serde_json::to_string(&legacy).unwrap(),
            serde_json::to_string(&updated).unwrap()
        );
        assert!(updated.read_store.is_none());
    }
}
