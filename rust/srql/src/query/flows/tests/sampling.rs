use super::super::stats::to_sql_and_params_stats;
use super::super::*;
use crate::parser::Entity;
use chrono::Duration as ChronoDuration;
use chrono::{TimeZone, Utc};

#[test]
fn raw_flow_stats_scale_volume_fields_by_sampling_rate() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: vec![OrderClause {
            field: "bytes_total".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as bytes_total, sum(packets_total) as packets_total by src_endpoint_ip",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();

    assert!(
        sql.contains(
            "SUM((f.bytes_total::double precision * GREATEST(COALESCE(f.sampling_rate, 1), 1)::double precision))"
        ),
        "expected bytes_total sum to be sampling-rate weighted: {sql}"
    );
    assert!(
        sql.contains(
            "SUM((f.packets_total::double precision * GREATEST(COALESCE(f.sampling_rate, 1), 1)::double precision))"
        ),
        "expected packets_total sum to be sampling-rate weighted: {sql}"
    );
}

#[test]
fn raw_flow_stats_coalesce_nullable_directional_volume_fields() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: vec![],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_in) as bytes_in, sum(packets_out) as packets_out",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();

    assert!(
        sql.contains(
            "SUM((COALESCE(f.bytes_in, 0)::double precision * GREATEST(COALESCE(f.sampling_rate, 1), 1)::double precision))"
        ),
        "expected nullable bytes_in sum to be coalesced before sampling-rate weighting: {sql}"
    );
    assert!(
        sql.contains(
            "SUM((COALESCE(f.packets_out, 0)::double precision * GREATEST(COALESCE(f.sampling_rate, 1), 1)::double precision))"
        ),
        "expected nullable packets_out sum to be coalesced before sampling-rate weighting: {sql}"
    );
}

#[test]
fn flow_cagg_stats_read_pre_scaled_volume_columns() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(24);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: vec![],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as bytes_total by src_endpoint_ip",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();

    assert!(sql.contains("FROM ocsf_network_activity_hourly_talkers f"));
    assert!(
        sql.contains("SUM(bytes_total) AS agg_value_0"),
        "expected CAGG route to use pre-scaled bytes_total: {sql}"
    );
    assert!(
        !sql.contains("sampling_rate"),
        "CAGGs do not carry sampling_rate; they store scaled volume: {sql}"
    );
}

#[test]
fn raw_flow_stats_scale_all_six_directional_volume_fields() {
    // §26.4: a sampled exporter's bytes/packets must be weighted by
    // sampling_rate on the raw path for ALL six volume fields — not just
    // bytes_total/packets_total (covered above) but the directional
    // bytes_in/bytes_out/packets_in/packets_out too.
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: vec![],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_in) as bytes_in, sum(bytes_out) as bytes_out, sum(packets_in) as packets_in, sum(packets_out) as packets_out by src_endpoint_ip",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();

    // §38.1 (#4238) made the four directional columns nullable, so the
    // stats path wraps them in COALESCE(col, 0) before scaling. (Totals
    // bytes_total/packets_total are NOT nullable and are NOT wrapped —
    // covered by raw_flow_stats_scale_volume_fields_by_sampling_rate above.)
    for col in ["bytes_in", "bytes_out", "packets_in", "packets_out"] {
        let needle = format!(
            "SUM((COALESCE(f.{col}, 0)::double precision * GREATEST(COALESCE(f.sampling_rate, 1), 1)::double precision))"
        );
        assert!(
            sql.contains(&needle),
            "expected {col} sum to be sampling-rate weighted (COALESCE-wrapped, nullable per §38.1): {sql}"
        );
    }
}

#[test]
fn flow_stats_scale_per_window_group_by_sampler() {
    // §26.4: the per-window gauge/p95 path groups by sampler_address. Pin
    // that sampling-rate weighting applies regardless of the group-by
    // field (a sampled exporter's volume must be recovered under every
    // grouping the dashboard uses). 1h window → raw path.
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: vec![],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as bytes_total by sampler_address",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();

    assert!(
        sql.contains(
            "SUM((f.bytes_total::double precision * GREATEST(COALESCE(f.sampling_rate, 1), 1)::double precision))"
        ),
        "sampler_address group-by must still weight bytes by sampling_rate: {sql}"
    );
    assert!(
        sql.contains("GROUP BY sampler_address"),
        "expected group-by sampler_address: {sql}"
    );
}

#[test]
fn flow_time_min_max_emits_unscaled_raw_path() {
    // §38.1: stats:min(time)/stats:max(time) derive the data's covered span.
    // `time` is a timestamp, not a sampled volume field, so it must emit a
    // plain MIN(time) on the raw-table path (never scaled by sampling_rate,
    // never routed to a CAGG that only stores SUMs).
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: vec![],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "min(time) as min_time, max(time) as max_time",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();

    assert!(
        sql.contains("MIN(time)"),
        "expected MIN(time) on the raw path: {sql}"
    );
    assert!(
        sql.contains("MAX(time)"),
        "expected MAX(time) on the raw path: {sql}"
    );
    assert!(
        !sql.contains("sampling_rate"),
        "time is a timestamp, must not be sampling-rate weighted: {sql}"
    );
}
