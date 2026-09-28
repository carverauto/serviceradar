//! BMP routing events.
//!
//! Addresses are documentation ranges (192.0.2.0/24, 198.51.100.0/24,
//! 203.0.113.0/24) and ASNs are from the private-use block (64512-65534), as
//! elsewhere in this fixture. Rows deliberately leave `severity_id` NULL on a
//! cadence (the God View causal overlay filters on `COALESCE(severity_id, 0)`)
//! and `prefix` NULL on another, so the row filters that keep or drop NULL rows
//! are exercised against both backends.

use super::{Anchor, BATCH_ROWS, Backend, instant, opt_num, opt_text, synthetic_uuid, text};
use serde_json::{Value, json};

#[derive(Debug, Clone, PartialEq)]
pub struct BmpRow {
    pub id: String,
    pub time: chrono::DateTime<chrono::Utc>,
    pub event_type: &'static str,
    pub severity_id: Option<i32>,
    pub router_id: Option<&'static str>,
    pub router_ip: Option<&'static str>,
    pub peer_ip: Option<&'static str>,
    pub peer_asn: Option<i64>,
    pub local_asn: Option<i64>,
    pub prefix: Option<&'static str>,
    pub message: Option<&'static str>,
    pub metadata: Value,
    pub raw_data: Option<&'static str>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

const ROUTERS: [(&str, &str, i64); 3] = [
    ("router-a", "192.0.2.1", 64512),
    ("router-b", "198.51.100.1", 64600),
    ("router-c", "203.0.113.1", 65534),
];
const PEERS: [(&str, i64); 4] = [
    ("192.0.2.10", 64512),
    ("198.51.100.20", 64600),
    ("203.0.113.30", 65534),
    ("192.0.2.40", 64599),
];
const EVENT_TYPES: [&str; 3] = ["route_update", "peer_down", "peer_up"];

pub fn rows(anchor: Anchor) -> Vec<BmpRow> {
    let mut rows = Vec::new();
    let mut n: u64 = 0;
    // Three event types per slot over 18 slots, each at a distinct time.
    for slot in 0..18_i64 {
        for (t, event_type) in EVENT_TYPES.iter().enumerate() {
            n += 1;
            let (router_id, router_ip, local_asn) = ROUTERS[(slot as usize + t) % 3];
            let (peer_ip, peer_asn) = PEERS[(slot as usize + t * 2) % 4];
            // Every third row leaves severity_id NULL.
            let severity_id = if slot % 3 == 0 {
                None
            } else {
                Some(((slot + t as i64) % 5) as i32)
            };
            // Every fourth row leaves prefix NULL.
            let prefix = if slot % 4 == 0 {
                None
            } else {
                Some("198.51.100.0/24")
            };
            let id = synthetic_uuid(0x33, n);
            let time = anchor.at(slot * 300 + t as i64 * 7);

            rows.push(BmpRow {
                id: id.clone(),
                time,
                event_type,
                severity_id,
                router_id: Some(router_id),
                router_ip: Some(router_ip),
                peer_ip: Some(peer_ip),
                peer_asn: Some(peer_asn),
                local_asn: Some(local_asn),
                prefix,
                message: Some("synthetic BMP routing signal"),
                metadata: json!({
                    "signal_type": "bmp",
                    "event_type": event_type,
                    "event_identity": id,
                    "routing_correlation": {
                        "router_id": router_id,
                        "router_ip": router_ip,
                        "peer_ip": peer_ip,
                        "peer_asn": peer_asn,
                        "local_asn": local_asn,
                        "prefix": prefix,
                    }
                }),
                raw_data: Some(r#"{"synthetic": true}"#),
                created_at: time,
            });
        }
    }
    rows
}

pub fn inserts(rows: &[BmpRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = match backend {
        Backend::Cnpg => {
            "id, \"time\", event_type, severity_id, router_id, router_ip, peer_ip, peer_asn, \
             local_asn, prefix, message, metadata, raw_data, created_at"
        }
        Backend::StarRocks => {
            "id, `time`, event_type, severity_id, router_id, router_ip, peer_ip, peer_asn, \
             local_asn, prefix, message, metadata, raw_data, created_at"
        }
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
                    let metadata = match backend {
                        Backend::Cnpg => format!("{}::jsonb", text(&r.metadata.to_string())),
                        Backend::StarRocks => text(&r.metadata.to_string()),
                    };
                    format!(
                        "({id}, {t}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {t})",
                        text(r.event_type),
                        opt_num(r.severity_id),
                        opt_text(r.router_id),
                        opt_text(r.router_ip),
                        opt_text(r.peer_ip),
                        opt_num(r.peer_asn),
                        opt_num(r.local_asn),
                        opt_text(r.prefix),
                        opt_text(r.message),
                        metadata,
                        opt_text(r.raw_data),
                        t = instant(r.time, backend),
                    )
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.bmp_routing_events ({columns}) VALUES\n{}",
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

    #[test]
    fn the_fixture_exercises_null_severity_prefix_and_distinct_ids() {
        let rows = rows(anchor());
        assert_eq!(rows.len(), 18 * 3);
        assert!(rows.iter().any(|r| r.severity_id.is_none()));
        assert!(rows.iter().any(|r| r.severity_id.is_some()));
        assert!(rows.iter().any(|r| r.prefix.is_none()));
        assert!(rows.iter().any(|r| r.prefix.is_some()));
        let ids: std::collections::BTreeSet<&String> = rows.iter().map(|r| &r.id).collect();
        assert_eq!(ids.len(), rows.len());
        // Distinct times: an ordered comparison has no ties to fall back on.
        let times: std::collections::BTreeSet<i64> =
            rows.iter().map(|r| r.time.timestamp_micros()).collect();
        assert_eq!(times.len(), rows.len());
    }
}
