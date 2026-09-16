//! Reusable, lossless application dimensions with query-time classification.

use crate::query::QueryPlan;

pub(in crate::query) const TABLE: &str = "ocsf_network_activity_hourly_app_dimensions";

pub(in crate::query) fn supports_filters(plan: &QueryPlan) -> bool {
    plan.filters.iter().all(|filter| {
        matches!(
            filter.field.as_str(),
            "app"
                | "partition"
                | "proto"
                | "protocol_num"
                | "protocol_group"
                | "proto_group"
                | "dst_port"
                | "dst_endpoint_port"
        )
    })
}

/// The relation owns two time binds and exposes pre-scaled volumes. Keep
/// classification outside the aggregate so editing a rule takes effect at once.
/// Rules requiring a source port or address cannot use these dimensions: a
/// statement-snapshot guard selects raw rows instead, without combining them
/// with aggregate rows. Uncorrelated guards become one-time executor filters.
pub(in crate::query) fn source_sql(inclusive_end: bool) -> String {
    let end_operator = if inclusive_end { "<=" } else { "<" };
    let raw = "time, partition, protocol_num, dst_endpoint_port, src_endpoint_port, src_endpoint_ip, dst_endpoint_ip, \
        bytes_total::double precision * GREATEST(COALESCE(sampling_rate, 1), 1)::double precision AS bytes_total, \
        packets_total::double precision * GREATEST(COALESCE(sampling_rate, 1), 1)::double precision AS packets_total, 1::bigint AS flow_count";
    format!(
        "(WITH requested_window AS NOT MATERIALIZED (\n\
SELECT ?::timestamptz AS start_at, ?::timestamptz AS end_at\n\
), classification_guard AS MATERIALIZED (\n\
SELECT NOT EXISTS (SELECT 1 FROM netflow_app_classification_rules WHERE enabled AND (src_port IS NOT NULL OR src_cidr IS NOT NULL OR dst_cidr IS NOT NULL)) AS allowed\n\
), bounds AS NOT MATERIALIZED (\n\
SELECT start_at, end_at,\n\
GREATEST(date_trunc('hour', start_at, 'UTC') + CASE WHEN start_at = date_trunc('hour', start_at, 'UTC') THEN INTERVAL '0 hours' ELSE INTERVAL '1 hour' END, COALESCE((SELECT MIN(bucket) FROM {TABLE}), 'infinity'::timestamptz)) AS rollup_start,\n\
LEAST(date_trunc('hour', end_at, 'UTC'), COALESCE((SELECT MAX(bucket) + INTERVAL '1 hour' FROM {TABLE}), '-infinity'::timestamptz)) AS rollup_end\n\
FROM requested_window\n\
)\n\
SELECT bucket AS time, partition, protocol_num, dst_endpoint_port, NULL::integer AS src_endpoint_port, NULL::text AS src_endpoint_ip, NULL::text AS dst_endpoint_ip, bytes_total::double precision AS bytes_total, packets_total::double precision AS packets_total, flow_count\n\
FROM {TABLE} CROSS JOIN bounds\n\
WHERE (SELECT allowed FROM classification_guard) AND bucket >= rollup_start AND bucket < rollup_end\n\
UNION ALL\n\
SELECT {raw} FROM ocsf_network_activity CROSS JOIN bounds\n\
WHERE (SELECT allowed FROM classification_guard) AND time >= start_at AND time {end_operator} end_at AND (time < rollup_start OR time >= rollup_end)\n\
UNION ALL\n\
SELECT {raw} FROM ocsf_network_activity CROSS JOIN requested_window\n\
WHERE NOT (SELECT allowed FROM classification_guard) AND time >= start_at AND time {end_operator} end_at)"
    )
}

#[cfg(test)]
mod tests {
    use crate::{
        config::AppConfig,
        query::{QueryRequest, translate_request, translate_request_with_drivers},
    };

    fn request(query: &str) -> QueryRequest {
        QueryRequest {
            query: query.into(),
            limit: None,
            cursor: None,
            direction: Default::default(),
            mode: None,
        }
    }

    #[test]
    fn application_activity_routes_both_ranking_and_series_without_per_flow_classification() {
        for shape in [
            "stats:\"sum(bytes_total) as total_bytes by app\" sort:total_bytes:desc limit:8",
            "stats:\"count(*) as total by app\" limit:8",
            "bucket:12h agg:sum value_field:bytes_total series:app limit:2000",
        ] {
            let query = format!("in:flows time:last_30d app:(https,dns) {shape}");
            let output =
                translate_request(&AppConfig::embedded(String::new()), request(&query)).unwrap();
            let sql = output.sql;
            assert!(sql.contains(super::TABLE), "{sql}");
            assert!(sql.contains("classification_guard AS MATERIALIZED"));
            assert!(sql.contains("WHERE NOT (SELECT allowed FROM classification_guard)"));
            assert!(
                sql.contains(
                    "src_port IS NOT NULL OR src_cidr IS NOT NULL OR dst_cidr IS NOT NULL"
                )
            );
            assert!(sql.contains("bounds AS NOT MATERIALIZED"));
            assert!(sql.contains("requested_window AS NOT MATERIALIZED"));
            assert!(sql.contains("time < rollup_start OR time >= rollup_end"));
            assert!(
                sql.contains("COALESCE(override_rule.app_label, baseline.app_label, 'unknown')")
            );
            assert_eq!(
                output.params.len(),
                if shape.starts_with("stats:") { 3 } else { 5 }
            );
        }
    }

    #[test]
    fn application_activity_unsupported_dimensions_and_duckdb_keep_their_raw_path() {
        let config = AppConfig::embedded(String::new());
        for extra in ["src_ip:192.0.2.4", "src_port:1234", "dst_ip:198.51.100.5"] {
            let query = format!("in:flows time:last_30d {extra} bucket:12h agg:sum series:app");
            let output = translate_request(&config, request(&query)).unwrap();
            assert!(!output.sql.contains(super::TABLE), "{extra}");
        }
        let drivers =
            std::collections::HashMap::from([("ocsf_network_activity".into(), "pg_duckdb".into())]);
        let output = translate_request_with_drivers(
            &config,
            request("in:flows time:last_90d bucket:24h agg:sum series:app"),
            &drivers,
        )
        .unwrap();
        assert!(!output.sql.contains(super::TABLE));
    }

    #[test]
    fn protocol_activity_uses_existing_hourly_sums_without_changing_other_group() {
        for filter in ["", "protocol_group:(tcp,udp,other)", "proto_group:other"] {
            let query = format!(
                "in:flows time:last_90d {filter} bucket:24h agg:sum value_field:bytes_total series:protocol_group limit:2000"
            );
            let output =
                translate_request(&AppConfig::embedded(String::new()), request(&query)).unwrap();
            assert!(
                output
                    .sql
                    .contains("FROM ocsf_network_activity_hourly_proto CROSS JOIN bounds")
            );
            assert!(output.sql.contains("ELSE 'other'"));
            assert!(output.sql.contains("time <= end_at"));
        }
    }
}
