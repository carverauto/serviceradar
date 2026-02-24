//! Telemetry and interface metric formatting.
//!
//! Contains fallback logic and formatting heuristics to
//! annotate link-layer graphs with realtime performance numbers.

use crate::types::telemetry::InterfaceTelemetryRecord;
use std::collections::HashMap;

/// Discovers an aggregated telemetry payload by comparing interface indexes and names.
pub(crate) fn find_interface_for_edge(
    by_index: &HashMap<(String, i64), InterfaceTelemetryRecord>,
    by_name: &HashMap<(String, String), Vec<InterfaceTelemetryRecord>>,
    device_id: &str,
    if_name: &str,
    if_index: i64,
) -> Option<InterfaceTelemetryRecord> {
    if if_index >= 0 {
        if let Some(found) = by_index.get(&(device_id.to_string(), if_index)) {
            return Some(found.clone());
        }
    }

    let trimmed = if_name.trim().to_lowercase();
    if !trimmed.is_empty() {
        if let Some(found) = by_name
            .get(&(device_id.to_string(), trimmed.clone()))
            .and_then(|records| records.first())
        {
            return Some(found.clone());
        }
        let fallback_name = trimmed
            .split(':')
            .next()
            .unwrap_or_default()
            .trim()
            .to_string();
        if !fallback_name.is_empty() {
            if let Some(found) = by_name
                .get(&(device_id.to_string(), fallback_name))
                .and_then(|records| records.first())
            {
                return Some(found.clone());
            }
        }
    }

    None
}

fn resolved_metric_index(
    explicit_if_index: i64,
    iface: Option<&InterfaceTelemetryRecord>,
) -> Option<i64> {
    if explicit_if_index >= 0 {
        Some(explicit_if_index)
    } else {
        iface.and_then(|record| (record.if_index >= 0).then_some(record.if_index))
    }
}

fn metric_score(
    pps_by_if: &HashMap<(String, i64), (u32, u32)>,
    bps_by_if: &HashMap<(String, i64), (u64, u64)>,
    device_id: &str,
    if_index: i64,
) -> u128 {
    let (pps_in, pps_out) = pps_by_if
        .get(&(device_id.to_string(), if_index))
        .copied()
        .unwrap_or((0, 0));
    let (bps_in, bps_out) = bps_by_if
        .get(&(device_id.to_string(), if_index))
        .copied()
        .unwrap_or((0, 0));
    (pps_in as u128) + (pps_out as u128) + (bps_in as u128) + (bps_out as u128)
}

fn select_metric_backed_interface(
    by_name: &HashMap<(String, String), Vec<InterfaceTelemetryRecord>>,
    pps_by_if: &HashMap<(String, i64), (u32, u32)>,
    bps_by_if: &HashMap<(String, i64), (u64, u64)>,
    device_id: &str,
    if_name: &str,
) -> Option<InterfaceTelemetryRecord> {
    let trimmed = if_name.trim().to_lowercase();
    if trimmed.is_empty() {
        return None;
    }

    let mut name_keys = vec![trimmed.clone()];
    let fallback_name = trimmed
        .split(':')
        .next()
        .unwrap_or_default()
        .trim()
        .to_string();
    if !fallback_name.is_empty() && fallback_name != trimmed {
        name_keys.push(fallback_name);
    }

    let mut best: Option<(u128, InterfaceTelemetryRecord)> = None;

    for key in name_keys {
        if let Some(records) = by_name.get(&(device_id.to_string(), key)) {
            for record in records {
                if record.if_index < 0 {
                    continue;
                }
                let score = metric_score(pps_by_if, bps_by_if, device_id, record.if_index);
                if score == 0 {
                    continue;
                }
                match &best {
                    Some((best_score, _)) if *best_score >= score => {}
                    _ => best = Some((score, record.clone())),
                }
            }
        }
    }

    best.map(|(_, record)| record)
}

/// Helper function to create shorthand human-readable string values for packet rates.
pub(crate) fn format_rate(value: u64) -> String {
    if value >= 1_000_000 {
        format!("{:.1}Mpps", value as f64 / 1_000_000.0)
    } else if value >= 1_000 {
        format!("{:.1}Kpps", value as f64 / 1_000.0)
    } else {
        format!("{value}pps")
    }
}

/// Helper function to create shorthand human-readable string values for data bandwidths.
pub(crate) fn format_capacity(value: u64) -> String {
    if value >= 1_000_000_000 {
        format!("{}G", value / 1_000_000_000)
    } else if value >= 100_000_000 {
        format!("{}M", value / 1_000_000)
    } else if value > 0 {
        format!("{}M", value / 1_000_000)
    } else {
        "UNK".to_string()
    }
}

/// Generates a standardized display label mapping the specific telemetry link format bounds.
pub(crate) fn edge_label(protocol: &str, flow_pps: u32, capacity_bps: u64) -> String {
    let p = protocol.trim().to_uppercase();
    let normalized = if p.is_empty() { "LINK" } else { p.as_str() };
    format!(
        "{normalized} {} / {}",
        format_rate(flow_pps as u64),
        format_capacity(capacity_bps)
    )
}

/// Orchestrates the total assembly of a real-time topology flow. Combines structural
/// graph layout edges with physical port index/PPS/BPS observations passed in from Elixir metric queries.
pub(crate) fn enrich_edges_telemetry_impl(
    edges: Vec<(
        String,
        String,
        String,
        (i64, String, i64, String),
        (u32, u64, u64),
    )>,
    interfaces: Vec<(String, String, i64, u64)>,
    pps_metrics: Vec<(String, i64, u32, u32)>,
    bps_metrics: Vec<(String, i64, u64, u64)>,
) -> Result<Vec<(String, String, u32, u64, u64, String, (u32, u32, u64, u64))>, rustler::Error> {
    let mut by_index = HashMap::<(String, i64), InterfaceTelemetryRecord>::new();
    let mut by_name = HashMap::<(String, String), Vec<InterfaceTelemetryRecord>>::new();

    for (device_id, if_name, if_index, speed_bps) in interfaces {
        let record = InterfaceTelemetryRecord {
            if_index,
            speed_bps,
        };

        if if_index >= 0 {
            by_index
                .entry((device_id.clone(), if_index))
                .or_insert_with(|| record.clone());
        }

        let lowered_name = if_name.trim().to_lowercase();
        if !lowered_name.is_empty() {
            by_name
                .entry((device_id.clone(), lowered_name))
                .or_default()
                .push(record.clone());
        }
    }

    let pps_by_if = pps_metrics
        .into_iter()
        .map(|(device_id, if_index, in_value, out_value)| {
            ((device_id, if_index), (in_value, out_value))
        })
        .collect::<HashMap<_, _>>();

    let bps_by_if = bps_metrics
        .into_iter()
        .map(|(device_id, if_index, in_value, out_value)| {
            ((device_id, if_index), (in_value, out_value))
        })
        .collect::<HashMap<_, _>>();

    let enriched = edges
        .into_iter()
        .map(
            |(source, target, protocol, directional_attrs, typed_telemetry)| {
                let (if_index_ab, if_name_ab, if_index_ba, if_name_ba) = directional_attrs;
                let (typed_flow_pps, typed_flow_bps, typed_capacity_bps) = typed_telemetry;
                let iface_ab =
                    find_interface_for_edge(&by_index, &by_name, &source, &if_name_ab, if_index_ab);
                let iface_ba =
                    find_interface_for_edge(&by_index, &by_name, &target, &if_name_ba, if_index_ba);

                let mut resolved_if_index_ab = resolved_metric_index(if_index_ab, iface_ab.as_ref());
                let mut resolved_if_index_ba = resolved_metric_index(if_index_ba, iface_ba.as_ref());

                // If a name maps to multiple interface rows, prefer the candidate with actual telemetry.
                if if_index_ab < 0
                    && resolved_if_index_ab
                        .map(|idx| metric_score(&pps_by_if, &bps_by_if, &source, idx) == 0)
                        .unwrap_or(true)
                {
                    if let Some(iface) = select_metric_backed_interface(
                        &by_name,
                        &pps_by_if,
                        &bps_by_if,
                        &source,
                        &if_name_ab,
                    ) {
                        resolved_if_index_ab = Some(iface.if_index);
                    }
                }

                if if_index_ba < 0
                    && resolved_if_index_ba
                        .map(|idx| metric_score(&pps_by_if, &bps_by_if, &target, idx) == 0)
                        .unwrap_or(true)
                {
                    if let Some(iface) = select_metric_backed_interface(
                        &by_name,
                        &pps_by_if,
                        &bps_by_if,
                        &target,
                        &if_name_ba,
                    ) {
                        resolved_if_index_ba = Some(iface.if_index);
                    }
                }

                let pps_ab_local = resolved_if_index_ab
                    .and_then(|idx| pps_by_if.get(&(source.clone(), idx)).copied());

                let pps_ba_local = resolved_if_index_ba
                    .and_then(|idx| pps_by_if.get(&(target.clone(), idx)).copied());

                let bps_ab_local = resolved_if_index_ab
                    .and_then(|idx| bps_by_if.get(&(source.clone(), idx)).copied());

                let bps_ba_local = resolved_if_index_ba
                    .and_then(|idx| bps_by_if.get(&(target.clone(), idx)).copied());

                // Primary directional signal uses egress on each edge endpoint.
                // When only one side can be attributed, fall back to that same interface ingress
                // for the opposite direction (still real SNMP telemetry, not synthetic).
                let flow_pps_ab = pps_ab_local
                    .map(|(_in_v, out_v)| out_v)
                    .or_else(|| pps_ba_local.map(|(in_v, _out_v)| in_v))
                    .unwrap_or(0);
                let flow_pps_ba = pps_ba_local
                    .map(|(_in_v, out_v)| out_v)
                    .or_else(|| pps_ab_local.map(|(in_v, _out_v)| in_v))
                    .unwrap_or(0);
                let flow_bps_ab = bps_ab_local
                    .map(|(_in_v, out_v)| out_v)
                    .or_else(|| bps_ba_local.map(|(in_v, _out_v)| in_v))
                    .unwrap_or(0);
                let flow_bps_ba = bps_ba_local
                    .map(|(_in_v, out_v)| out_v)
                    .or_else(|| bps_ab_local.map(|(in_v, _out_v)| in_v))
                    .unwrap_or(0);

                let cap_ab = iface_ab.map(|r| r.speed_bps).unwrap_or(0);
                let cap_ba = iface_ba.map(|r| r.speed_bps).unwrap_or(0);
                let iface_capacity = if cap_ab > 0 && cap_ba > 0 {
                    cap_ab.min(cap_ba)
                } else if cap_ab > 0 {
                    cap_ab
                } else {
                    cap_ba
                };

                let flow_pps = if typed_flow_pps > 0 {
                    typed_flow_pps
                } else {
                    flow_pps_ab.saturating_add(flow_pps_ba)
                };

                let flow_bps = if typed_flow_bps > 0 {
                    typed_flow_bps
                } else {
                    flow_bps_ab.saturating_add(flow_bps_ba)
                };

                let capacity_bps = if typed_capacity_bps > 0 {
                    typed_capacity_bps
                } else {
                    iface_capacity
                };

                let label = edge_label(&protocol, flow_pps, capacity_bps);
                (
                    source,
                    target,
                    flow_pps,
                    flow_bps,
                    capacity_bps,
                    label,
                    (flow_pps_ab, flow_pps_ba, flow_bps_ab, flow_bps_ba),
                )
            },
        )
        .collect();

    Ok(enriched)
}
