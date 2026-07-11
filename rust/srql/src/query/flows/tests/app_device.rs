use super::super::stats::to_sql_and_params_stats;
use super::super::*;
use crate::parser::Entity;
use chrono::Duration as ChronoDuration;
use chrono::{TimeZone, Utc};

#[test]
fn translate_grouped_stats_app_group_by_includes_rule_table() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: Vec::new(),
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as total_bytes by app",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();
    assert!(
        sql.contains("netflow_app_classification_rules"),
        "expected SQL to reference netflow_app_classification_rules for app derivation: {sql}"
    );
    assert!(
        sql.contains("r.partition = baseline.flow_partition")
            && sql.contains("r.protocol_num = baseline.flow_protocol_num"),
        "expected aliased stats SQL to correlate override rules to f: {sql}"
    );
}
