use crate::types::telemetry::InterfaceTelemetryRecord;
use std::collections::HashMap;

pub fn find_interface_for_edge(
    by_index: &HashMap<(String, i64), InterfaceTelemetryRecord>,
    by_name: &HashMap<(String, String), InterfaceTelemetryRecord>,
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
        if let Some(found) = by_name.get(&(device_id.to_string(), trimmed.clone())) {
            return Some(found.clone());
        }
        let fallback_name = trimmed
            .split(':')
            .next()
            .unwrap_or_default()
            .trim()
            .to_string();
        if !fallback_name.is_empty() {
            if let Some(found) = by_name.get(&(device_id.to_string(), fallback_name)) {
                return Some(found.clone());
            }
        }
    }

    None
}

pub fn format_rate(value: u64) -> String {
    if value >= 1_000_000 {
        format!("{:.1}Mpps", value as f64 / 1_000_000.0)
    } else if value >= 1_000 {
        format!("{:.1}Kpps", value as f64 / 1_000.0)
    } else {
        format!("{value}pps")
    }
}

pub fn format_capacity(value: u64) -> String {
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

pub fn edge_label(protocol: &str, flow_pps: u32, capacity_bps: u64) -> String {
    let p = protocol.trim().to_uppercase();
    let normalized = if p.is_empty() { "LINK" } else { p.as_str() };
    format!(
        "{normalized} {} / {}",
        format_rate(flow_pps as u64),
        format_capacity(capacity_bps)
    )
}

pub fn enrich_edges_telemetry_impl(
    edges: Vec<(String, String, String, i64, String, (u32, u64, u64))>,
    interfaces: Vec<(String, String, i64, u64)>,
    pps_metrics: Vec<(String, i64, u32)>,
    bps_metrics: Vec<(String, i64, u64)>,
) -> Result<Vec<(String, String, u32, u64, u64, String)>, rustler::Error> {
    let mut by_index = HashMap::<(String, i64), InterfaceTelemetryRecord>::new();
    let mut by_name = HashMap::<(String, String), InterfaceTelemetryRecord>::new();

    for (device_id, if_name, if_index, speed_bps) in interfaces {
        let record = InterfaceTelemetryRecord { speed_bps };

        if if_index >= 0 {
            by_index
                .entry((device_id.clone(), if_index))
                .or_insert_with(|| record.clone());
        }

        let lowered_name = if_name.trim().to_lowercase();
        if !lowered_name.is_empty() {
            by_name
                .entry((device_id.clone(), lowered_name))
                .or_insert_with(|| record.clone());
        }
    }

    let pps_by_if = pps_metrics
        .into_iter()
        .map(|(device_id, if_index, value)| ((device_id, if_index), value))
        .collect::<HashMap<_, _>>();

    let bps_by_if = bps_metrics
        .into_iter()
        .map(|(device_id, if_index, value)| ((device_id, if_index), value))
        .collect::<HashMap<_, _>>();

    let enriched = edges
        .into_iter()
        .map(
            |(source, target, protocol, local_if_index, local_if_name, typed_telemetry)| {
                let (typed_flow_pps, typed_flow_bps, typed_capacity_bps) = typed_telemetry;
                let iface = find_interface_for_edge(
                    &by_index,
                    &by_name,
                    &source,
                    &local_if_name,
                    local_if_index,
                );

                let (iface_pps, iface_bps, iface_capacity) = if let Some(record) = iface {
                    let pps = if local_if_index >= 0 {
                        pps_by_if
                            .get(&(source.clone(), local_if_index))
                            .copied()
                            .map(|v| v as u64)
                    } else {
                        None
                    };

                    let bps = if local_if_index >= 0 {
                        bps_by_if.get(&(source.clone(), local_if_index)).copied()
                    } else {
                        None
                    };

                    (pps, bps, Some(record.speed_bps))
                } else {
                    (None, None, None)
                };

                let flow_pps = if typed_flow_pps > 0 {
                    typed_flow_pps
                } else {
                    iface_pps.unwrap_or(0).min(u32::MAX as u64) as u32
                };

                let flow_bps = if typed_flow_bps > 0 {
                    typed_flow_bps
                } else {
                    iface_bps.unwrap_or(0)
                };

                let capacity_bps = if typed_capacity_bps > 0 {
                    typed_capacity_bps
                } else {
                    iface_capacity.filter(|v| *v > 0).unwrap_or(0)
                };

                let label = edge_label(&protocol, flow_pps, capacity_bps);
                (source, target, flow_pps, flow_bps, capacity_bps, label)
            },
        )
        .collect();

    Ok(enriched)
}
