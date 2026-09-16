use super::*;

/// Minimum time range (hours) before we consider routing flow stats to a CAGG.
const FLOW_CAGG_ROUTING_THRESHOLD_HOURS: i64 = 6;

/// Returns the filter field names that can safely be applied against a given CAGG table.
/// Only direct dimension-column filters are allowed — expression-based filters (subqueries,
/// CASE expressions, geo joins) reference raw-table-only structures and must fall back.
fn cagg_filter_fields(table: &str) -> &'static [&'static str] {
    match table {
        "ocsf_network_activity_hourly_talkers" => &["src_endpoint_ip", "src_ip"],
        "ocsf_network_activity_hourly_listeners" => &["dst_endpoint_ip", "dst_ip"],
        "ocsf_network_activity_hourly_proto" => &["protocol_num", "proto"],
        "ocsf_network_activity_hourly_ports" => &["dst_endpoint_port", "dst_port"],
        "ocsf_network_activity_hourly_conversations" => {
            &["src_endpoint_ip", "src_ip", "dst_endpoint_ip", "dst_ip"]
        }
        // Traffic CAGGs (5m, 1h, 1d) have no dimension columns
        _ => &[],
    }
}

/// Returns `Some((cagg_table, ts_col))` when a flow stats query can be served
/// from a continuous aggregate with raw edges and ambiguous dimensions repaired.
pub(in crate::query::flows) fn should_route_flow_stats_to_cagg(
    plan: &QueryPlan,
    spec: &FlowStatsSpec,
) -> Option<(&'static str, &'static str)> {
    if !matches!(plan.entity, Entity::Flows)
        || !matches!(plan.dialect, crate::query::SqlDialect::Postgres)
    {
        return None;
    }

    // CAGG routing currently supports only one aggregate expression.
    let agg = match spec.aggregations.as_slice() {
        [agg] => agg,
        _ => return None,
    };

    // 1. Must have a time range >= threshold
    let time_range = plan.time_range.as_ref()?;
    let span = time_range.end.signed_duration_since(time_range.start);
    if span < chrono::Duration::hours(FLOW_CAGG_ROUTING_THRESHOLD_HOURS) {
        return None;
    }

    // 2. Agg field must exist in CAGGs
    if !matches!(
        agg.agg_field,
        FlowAggField::BytesTotal | FlowAggField::PacketsTotal | FlowAggField::Star
    ) {
        return None;
    }

    // 3. Agg function must be Sum or Count (CAGGs store SUMs, not raw values)
    if !matches!(agg.agg_func, FlowAggFunc::Sum | FlowAggFunc::Count) {
        return None;
    }

    // 3b. Only count(*) can be safely rewritten to CAGGs (SUM(flow_count));
    // count(field) would count pre-aggregated rows/buckets, not underlying flows.
    if matches!(agg.agg_func, FlowAggFunc::Count) && !matches!(agg.agg_field, FlowAggField::Star) {
        return None;
    }

    // 3c. sum(*) is not valid
    if matches!(agg.agg_field, FlowAggField::Star) && matches!(agg.agg_func, FlowAggFunc::Sum) {
        return None;
    }

    // Scalar filters previously used raw rows; the shared protocol aggregate
    // is selected for unfiltered totals only.
    if spec.group_by.is_empty() && !plan.filters.is_empty() {
        return None;
    }

    // 4. Group-by fields must match an available CAGG dimension
    let table: &'static str = match spec.group_by.as_slice() {
        // Use the same coverage as protocol totals; summing all dimensions
        // also preserves flows whose protocol was NULL before materialization.
        [] => "ocsf_network_activity_hourly_proto",
        [FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp)] => {
            "ocsf_network_activity_hourly_talkers"
        }
        [FlowGroupSpec::Field(FlowGroupField::DstEndpointIp)] => {
            "ocsf_network_activity_hourly_listeners"
        }
        [FlowGroupSpec::Field(FlowGroupField::ProtocolNum)] => "ocsf_network_activity_hourly_proto",
        [FlowGroupSpec::Field(FlowGroupField::DstEndpointPort)] => {
            "ocsf_network_activity_hourly_ports"
        }
        [
            FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp),
            FlowGroupSpec::Field(FlowGroupField::DstEndpointIp),
        ]
        | [
            FlowGroupSpec::Field(FlowGroupField::DstEndpointIp),
            FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp),
        ] => "ocsf_network_activity_hourly_conversations",
        _ => return None, // Unsupported group-by combination
    };

    // 5. All filters must target columns that exist in the selected CAGG.
    // Only simple dimension-column filters are safe; expression-based filters
    // (device_id, exporter_name, app, geo, CIDR, etc.) reference raw-table-only
    // columns/subqueries and would produce wrong results or SQL errors.
    let allowed_filters = cagg_filter_fields(table);
    if !plan
        .filters
        .iter()
        .all(|f| allowed_filters.contains(&f.field.as_str()))
    {
        return None;
    }

    Some((table, "bucket"))
}

// Conjunctive positive predicates can prove a dimension's NULL/sentinel rows
// are outside the query. Negative predicates intentionally retain NULL rows.
fn excludes_sentinel(filter: &crate::parser::Filter, column: &str) -> bool {
    use crate::parser::{FilterOp, FilterValue};

    let filter_column = match filter.field.as_str() {
        "src_ip" | "src_endpoint_ip" => "src_endpoint_ip",
        "dst_ip" | "dst_endpoint_ip" => "dst_endpoint_ip",
        "proto" | "protocol_num" => "protocol_num",
        "dst_port" | "dst_endpoint_port" => "dst_endpoint_port",
        _ => return false,
    };
    if filter_column != column {
        return false;
    }
    let safe_value = |value: &str| match column {
        "protocol_num" | "dst_endpoint_port" => value.parse::<i64>().is_ok_and(|value| value != 0),
        _ => value.parse::<std::net::IpAddr>().is_ok(),
    };
    match (&filter.op, &filter.value) {
        (FilterOp::Eq, FilterValue::Scalar(value)) => safe_value(value),
        (FilterOp::In, FilterValue::List(values)) => {
            !values.is_empty() && values.iter().all(|value| safe_value(value))
        }
        _ => false,
    }
}

/// Restore exact window and NULL semantics around lossy hourly materializations.
/// Bounds are global, never scoped to a selected dimension. A missing dimension
/// is not evidence that aggregate coverage ended.
pub(super) fn source_sql(table: &str, spec: &FlowStatsSpec, plan: &QueryPlan) -> String {
    let dimensions: Vec<(&str, &str)> = spec
        .group_by
        .iter()
        .filter_map(|group| match group {
            FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp) => {
                Some(("src_endpoint_ip", "'Unknown'"))
            }
            FlowGroupSpec::Field(FlowGroupField::DstEndpointIp) => {
                Some(("dst_endpoint_ip", "'Unknown'"))
            }
            FlowGroupSpec::Field(FlowGroupField::ProtocolNum) => Some(("protocol_num", "0")),
            FlowGroupSpec::Field(FlowGroupField::DstEndpointPort) => {
                Some(("dst_endpoint_port", "0"))
            }
            _ => None,
        })
        .collect();
    let projection = dimensions
        .iter()
        .map(|(column, _)| format!(", f.{column}"))
        .collect::<String>();
    let ambiguous = dimensions
        .iter()
        .filter(|(column, _)| {
            !plan
                .filters
                .iter()
                .any(|filter| excludes_sentinel(filter, column))
        })
        .map(|(column, sentinel)| format!("f.{column} IS NULL OR f.{column} = {sentinel}"))
        .collect::<Vec<_>>()
        .join(" OR ");
    let cagg_filter = if ambiguous.is_empty() {
        String::new()
    } else {
        format!(" AND NOT ({ambiguous})")
    };
    let raw_projection = format!(
        "(f.bytes_total::double precision * GREATEST(COALESCE(f.sampling_rate, 1), 1)::double precision) AS bytes_total, \
(f.packets_total::double precision * GREATEST(COALESCE(f.sampling_rate, 1), 1)::double precision) AS packets_total, \
1::bigint AS flow_count{projection}"
    );
    // Keep the boolean in an uncorrelated scalar subquery. A plain EXISTS can
    // become a semi-join with raw rows on the outer side, scanning historical
    // chunks even when the aggregate has no ambiguous dimensions.
    let guard = if ambiguous.is_empty() {
        String::new()
    } else {
        format!(
            ", sentinel_guard AS MATERIALIZED (SELECT EXISTS (SELECT 1 FROM {table} f CROSS JOIN bounds WHERE f.bucket >= rollup_start AND f.bucket < rollup_end AND ({ambiguous})) AS needed)"
        )
    };
    // The sentinel can represent either NULL or a genuine value. Recover only
    // those interior groups; scalar totals need no NULL identity repair.
    let interior = if ambiguous.is_empty() {
        String::new()
    } else {
        format!(
            "\nUNION ALL\nSELECT {raw_projection} FROM ocsf_network_activity f CROSS JOIN bounds\n\
WHERE f.time >= rollup_start AND f.time < rollup_end AND ({ambiguous})\n\
  AND (SELECT needed FROM sentinel_guard)"
        )
    };
    format!(
        "(WITH requested_window AS (SELECT ?::timestamptz AS start_at, ?::timestamptz AS end_at),\n\
bounds AS NOT MATERIALIZED (\n\
SELECT start_at, end_at,\n\
  GREATEST(date_trunc('hour', start_at, 'UTC') + CASE WHEN start_at = date_trunc('hour', start_at, 'UTC') THEN INTERVAL '0 hours' ELSE INTERVAL '1 hour' END, COALESCE((SELECT MIN(bucket) FROM {table}), 'infinity'::timestamptz)) AS rollup_start,\n\
  LEAST(date_trunc('hour', end_at, 'UTC'), COALESCE((SELECT MAX(bucket) + INTERVAL '1 hour' FROM {table}), '-infinity'::timestamptz)) AS rollup_end\n\
FROM requested_window\n\
){guard}\n\
SELECT f.bytes_total::double precision AS bytes_total, f.packets_total::double precision AS packets_total, f.flow_count{projection}\n\
FROM {table} f CROSS JOIN bounds\n\
WHERE f.bucket >= rollup_start AND f.bucket < rollup_end{cagg_filter}\n\
UNION ALL\n\
SELECT {raw_projection} FROM ocsf_network_activity f CROSS JOIN bounds\n\
WHERE f.time >= start_at AND f.time < end_at AND (f.time < rollup_start OR f.time >= rollup_end){interior})"
    )
}

#[cfg(test)]
mod tests {
    use crate::{
        config::AppConfig,
        parser,
        query::{QueryPlan, QueryRequest, SqlDialect, build_query_plan},
    };
    use serde_json::json;

    fn plan(stats: &str, filters: &str) -> QueryPlan {
        let request = QueryRequest {
            query: format!(
                "in:flows time:[2025-01-01T00:17:00Z,2025-01-08T02:43:00Z] {filters} stats:\"{stats}\" limit:8"
            ),
            limit: None,
            cursor: None,
            direction: Default::default(),
            mode: None,
        };
        build_query_plan(
            &AppConfig::embedded(String::new()),
            &request,
            parser::parse(&request.query).unwrap(),
        )
        .unwrap()
    }

    fn sql(plan: &QueryPlan) -> (String, Vec<crate::query::BindParam>) {
        super::super::to_sql_and_params_stats(plan).unwrap()
    }

    #[test]
    fn flow_stats_cagg_scalar_and_protocol_share_coverage_and_exact_edges() {
        for stats in [
            "count(*) as total",
            "sum(bytes_total) as total",
            "sum(packets_total) as total",
            "count(*) as total by protocol_num",
        ] {
            let (sql, params) = sql(&plan(stats, ""));
            assert!(sql.contains("FROM ocsf_network_activity_hourly_proto f CROSS JOIN bounds"));
            assert!(sql.contains("bounds AS NOT MATERIALIZED"));
            assert!(sql.contains("SELECT MIN(bucket) FROM ocsf_network_activity_hourly_proto"));
            assert!(sql.contains("SELECT MAX(bucket) + INTERVAL '1 hour'"));
            assert!(sql.contains("f.time >= start_at AND f.time < end_at AND (f.time < rollup_start OR f.time >= rollup_end)"));
            assert_eq!(
                serde_json::to_value(&params).unwrap(),
                json!([
                    {"t":"timestamptz","v":"2025-01-01T00:17:00+00:00"},
                    {"t":"timestamptz","v":"2025-01-08T02:43:00+00:00"}
                ])
            );
        }
        let (sql, _) = sql(&plan("count(*) as total", ""));
        assert!(sql.contains("COALESCE(SUM(flow_count), 0)"));
        assert!(
            !sql.contains("sentinel_guard"),
            "scalar totals must not scan interior raw rows"
        );
    }

    #[test]
    fn flow_stats_cagg_preserves_null_groups_and_filter_bind_order() {
        for (field, sentinel) in [
            ("protocol_num", "0"),
            ("dst_endpoint_port", "0"),
            ("src_endpoint_ip", "'Unknown'"),
        ] {
            let (sql, _) = sql(&plan(&format!("count(*) as total by {field}"), ""));
            assert!(sql.contains(&format!(
                "AND NOT (f.{field} IS NULL OR f.{field} = {sentinel})"
            )));
            assert!(sql.contains(&format!("f.time >= rollup_start AND f.time < rollup_end AND (f.{field} IS NULL OR f.{field} = {sentinel})")));
            assert!(sql.contains("sentinel_guard AS MATERIALIZED (SELECT EXISTS"));
            assert!(sql.contains("AND (SELECT needed FROM sentinel_guard)"));
        }
        let (sql, params) = sql(&plan("count(*) as total by protocol_num", "proto:(6,17)"));
        assert_eq!(
            serde_json::to_value(&params[2..]).unwrap(),
            json!([{"t":"int_array","v":[6,17]}])
        );
        assert!(sql.contains("protocol_num::bigint = ANY($3)"));
    }

    #[test]
    fn flow_stats_duckdb_and_unsupported_filters_stay_raw() {
        let mut duckdb = plan("count(*) as total by protocol_num", "");
        duckdb.dialect = SqlDialect::Duckdb;
        for plan in [
            duckdb,
            plan("count(*) as total", "proto:6"),
            plan("count(*) as total by protocol_num", "src_ip:192.0.2.9"),
        ] {
            let (sql, _) = sql(&plan);
            assert!(!sql.contains("hourly_proto"));
            assert!(sql.contains("FROM ocsf_network_activity f"));
        }
    }

    #[test]
    fn flow_stats_cagg_positive_dimension_filters_skip_interior_recovery() {
        for (group, filter) in [
            ("protocol_num", "proto:(6,17)"),
            ("protocol_num", "proto:1 proto:(6,17)"),
            ("dst_endpoint_port", "dst_port:443"),
            ("src_endpoint_ip", "src_ip:(192.0.2.8,2001:db8::8)"),
        ] {
            let (sql, _) = sql(&plan(&format!("count(*) as total by {group}"), filter));
            assert!(sql.contains("CROSS JOIN bounds"));
            assert!(
                !sql.contains("sentinel_guard"),
                "unneeded historical raw scan: {sql}"
            );
            assert_eq!(sql.matches("FROM ocsf_network_activity f").count(), 1);
        }
        for filter in ["proto:0", "proto:(0,6)"] {
            let (sql, _) = sql(&plan("count(*) as total by protocol_num", filter));
            assert!(
                sql.contains("sentinel_guard"),
                "must preserve ambiguous and NULL groups: {sql}"
            );
        }
        let mut negative = plan("count(*) as total by protocol_num", "proto:6");
        negative.filters[0].op = crate::parser::FilterOp::NotEq;
        assert!(sql(&negative).0.contains("sentinel_guard"));
        let (sql, _) = sql(&plan(
            "count(*) as total by src_endpoint_ip,dst_endpoint_ip",
            "src_ip:192.0.2.8",
        ));
        assert!(sql.contains("sentinel_guard"));
        assert!(sql.contains("f.dst_endpoint_ip IS NULL OR f.dst_endpoint_ip = 'Unknown'"));
        assert!(!sql.contains("f.src_endpoint_ip IS NULL OR f.src_endpoint_ip = 'Unknown'"));
    }
}
