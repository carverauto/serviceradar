//! MTR traces and hops.
//!
//! Three targets probed by two agents, a trace every twenty minutes. Every per-hop figure is
//! chosen so the wrong formula gives a different number than the right one:
//!
//! * `sent` varies by trace (5, 10, 20 probes), so loss as `SUM(sent - received) / SUM(sent)`
//!   (`loss_ratio`) differs from the mean of the per-hop `loss_pct` the rows also carry;
//! * latency varies with the received count, so `wavg(avg_us, received)` differs from
//!   `AVG(avg_us)`;
//! * one hop never replies (NULL address, nothing received, NULL latency), one sits in a private
//!   range with a NULL ASN and one in a range whose ASN lookup gave 0, so `asn:>0` and the
//!   `by addr` NULL group are exercised;
//! * one target is reached one trace in three, one always, one never.
//!
//! Addresses are documentation ranges; ASNs are from the private-use block (64512-65534).

use super::{Anchor, BATCH_ROWS, Backend, instant, opt_num, opt_text, synthetic_uuid, text};

#[derive(Debug, Clone, PartialEq)]
pub struct TraceRow {
    pub id: String,
    pub time: chrono::DateTime<chrono::Utc>,
    pub agent_id: &'static str,
    pub gateway_id: &'static str,
    pub device_id: &'static str,
    pub target: &'static str,
    pub target_ip: &'static str,
    pub target_reached: bool,
    pub total_hops: i32,
    pub protocol: &'static str,
    pub ip_version: i32,
    pub packet_size: i32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct HopRow {
    pub id: String,
    pub time: chrono::DateTime<chrono::Utc>,
    pub trace_id: String,
    pub target_ip: &'static str,
    pub device_id: &'static str,
    pub hop_number: i32,
    pub addr: Option<&'static str>,
    pub asn: Option<i32>,
    pub sent: i32,
    pub received: i32,
    pub loss_pct: f64,
    pub avg_us: Option<i64>,
    pub min_us: Option<i64>,
    pub max_us: Option<i64>,
}

const TARGETS: [(&str, &str, &str); 3] = [
    ("target-a.example.com", "198.51.100.10", "sr:parity-dev-a"),
    ("target-b.example.com", "198.51.100.20", "sr:parity-dev-b"),
    ("198.51.100.30", "198.51.100.30", "sr:parity-dev-c"),
];
const AGENTS: [(&str, &str); 2] = [
    ("agent-parity-01", "gw-parity-01"),
    ("agent-parity-02", "gw-parity-02"),
];

pub fn traces_and_hops(anchor: Anchor) -> (Vec<TraceRow>, Vec<HopRow>) {
    let mut traces = Vec::new();
    let mut hops = Vec::new();
    let mut n: u64 = 0;
    for slot in 0..18_i64 {
        for (t, (target, target_ip, device)) in TARGETS.iter().enumerate() {
            for (a, (agent, gateway)) in AGENTS.iter().enumerate() {
                // Agent two only probes the first target.
                if a == 1 && t != 0 {
                    continue;
                }
                n += 1;
                let time = anchor.at(slot * 1200 + 60 + (t as i64) * 7 + (a as i64) * 3);
                let trace_id = synthetic_uuid(0x31, n);
                let sent = [5, 10, 20][(slot as usize + t) % 3];
                let reached = match t {
                    0 => true,
                    1 => slot % 3 == 0,
                    _ => false,
                };
                // (addr, asn, received as a function of sent, base latency)
                let path: Vec<(Option<&'static str>, Option<i32>, i32, i64)> = vec![
                    (Some("192.0.2.1"), None, sent, 400 + 10 * a as i64),
                    (
                        Some("192.0.2.2"),
                        Some(0),
                        sent - ((slot % 2) as i32),
                        2_000,
                    ),
                    (None, None, 0, 0),
                    (
                        Some("203.0.113.4"),
                        Some(64_512),
                        sent - ((slot % 4) as i32).min(sent),
                        9_000 + 150 * slot,
                    ),
                    (
                        Some(if t == 2 { "203.0.113.9" } else { target_ip }),
                        Some(64_600 + t as i32),
                        if reached {
                            sent - (slot % 5 == 0) as i32
                        } else {
                            sent / 5
                        },
                        15_000 + 1_000 * t as i64 + 40 * slot,
                    ),
                ];
                for (index, (addr, asn, received, base)) in path.into_iter().enumerate() {
                    let received = received.max(0);
                    let avg = (received > 0).then(|| base + 37 * i64::from(sent - received));
                    hops.push(HopRow {
                        id: synthetic_uuid(0x32, n * 16 + index as u64),
                        time,
                        trace_id: trace_id.clone(),
                        target_ip,
                        device_id: device,
                        hop_number: index as i32 + 1,
                        addr,
                        asn,
                        sent,
                        received,
                        loss_pct: 100.0 * f64::from(sent - received) / f64::from(sent),
                        avg_us: avg,
                        min_us: avg.map(|v| v - 50),
                        max_us: avg.map(|v| v + 90),
                    });
                }
                traces.push(TraceRow {
                    id: trace_id,
                    time,
                    agent_id: agent,
                    gateway_id: gateway,
                    device_id: device,
                    target,
                    target_ip,
                    target_reached: reached,
                    total_hops: 5,
                    protocol: "icmp",
                    ip_version: 4,
                    packet_size: 64,
                });
            }
        }
    }
    (traces, hops)
}

pub fn trace_inserts(rows: &[TraceRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = "id, `time`, agent_id, gateway_id, device_id, target, target_ip, target_reached, \
                   total_hops, protocol, ip_version, packet_size, created_at";
    let columns = match backend {
        Backend::Cnpg => columns.replace('`', "\""),
        Backend::StarRocks => columns.to_string(),
    };
    rows.chunks(BATCH_ROWS)
        .map(|chunk| {
            let values: Vec<String> = chunk
                .iter()
                .map(|r| {
                    let id = match backend {
                        Backend::Cnpg => format!("{}::uuid", text(&r.id)),
                        Backend::StarRocks => text(&r.id),
                    };
                    format!(
                        "({id}, {t}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {t})",
                        text(r.agent_id),
                        text(r.gateway_id),
                        text(r.device_id),
                        text(r.target),
                        text(r.target_ip),
                        r.target_reached,
                        r.total_hops,
                        text(r.protocol),
                        r.ip_version,
                        r.packet_size,
                        t = instant(r.time, backend),
                    )
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.mtr_traces ({columns}) VALUES\n{}",
                values.join(",\n")
            )
        })
        .collect()
}

pub fn hop_inserts(rows: &[HopRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = "id, `time`, trace_id, target_ip, device_id, hop_number, addr, asn, sent, \
                   received, loss_pct, avg_us, min_us, max_us, created_at";
    let columns = match backend {
        Backend::Cnpg => columns.replace('`', "\""),
        Backend::StarRocks => columns.to_string(),
    };
    rows.chunks(BATCH_ROWS)
        .map(|chunk| {
            let values: Vec<String> = chunk
                .iter()
                .map(|r| {
                    let uuid = |value: &str| match backend {
                        Backend::Cnpg => format!("{}::uuid", text(value)),
                        Backend::StarRocks => text(value),
                    };
                    format!(
                        "({}, {t}, {}, {}, {}, {}, {}, {}, {}, {}, {:?}, {}, {}, {}, {t})",
                        uuid(&r.id),
                        uuid(&r.trace_id),
                        text(r.target_ip),
                        text(r.device_id),
                        r.hop_number,
                        opt_text(r.addr),
                        opt_num(r.asn),
                        r.sent,
                        r.received,
                        r.loss_pct,
                        opt_num(r.avg_us),
                        opt_num(r.min_us),
                        opt_num(r.max_us),
                        t = instant(r.time, backend),
                    )
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.mtr_hops ({columns}) VALUES\n{}",
                values.join(",\n")
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, Utc};

    fn anchor() -> Anchor {
        Anchor::for_run(
            DateTime::parse_from_rfc3339("2030-03-04T15:16:17Z")
                .unwrap()
                .with_timezone(&Utc),
        )
    }

    /// The property the harness exists for: a ratio of probe totals and a mean of per-hop
    /// percentages disagree on this fixture, so a dialect computing the second is caught.
    #[test]
    fn loss_ratio_and_mean_of_percentages_disagree_on_the_fixture() {
        let (_, hops) = traces_and_hops(anchor());
        let hop4: Vec<&HopRow> = hops
            .iter()
            .filter(|h| h.addr == Some("203.0.113.4"))
            .collect();
        let sent: i32 = hop4.iter().map(|h| h.sent).sum();
        let received: i32 = hop4.iter().map(|h| h.received).sum();
        let ratio = 100.0 * f64::from(sent - received) / f64::from(sent);
        let mean = hop4.iter().map(|h| h.loss_pct).sum::<f64>() / hop4.len() as f64;
        assert!((ratio - mean).abs() > 0.1, "ratio {ratio} mean {mean}");
        assert!(hops.iter().any(|h| h.addr.is_none() && h.avg_us.is_none()));
        assert!(hops.iter().any(|h| h.asn == Some(0)));
        let ids: std::collections::BTreeSet<&String> = hops.iter().map(|h| &h.id).collect();
        assert_eq!(ids.len(), hops.len());
    }
}
