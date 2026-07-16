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
/// entirely from a pre-aggregated continuous aggregate.
pub(in crate::query::flows) fn should_route_flow_stats_to_cagg(
    plan: &QueryPlan,
    spec: &FlowStatsSpec,
) -> Option<(&'static str, &'static str)> {
    if !matches!(plan.entity, Entity::Flows) {
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

    // 4. Group-by fields must match an available CAGG dimension
    let is_long_window = span >= chrono::Duration::hours(24);

    let table: &'static str = match spec.group_by.as_slice() {
        [] => {
            if is_long_window {
                "flow_traffic_1h"
            } else {
                "ocsf_network_activity_5m_traffic"
            }
        }
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
