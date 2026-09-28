//! OCSF event rows: detection findings (anomaly and capacity verdicts), other security
//! findings, scan activity, DNS activity and ordinary event-log rows.
//!
//! CNPG keeps the OCSF documents as `jsonb`; the warehouse keeps the same documents as JSON
//! text plus the scalar columns `Rows.encode_row(:events, _)` flattens out of them
//! (`src_endpoint_ip`, `source_type`, `firewall_rule_name`), which the loader below derives
//! from the documents exactly as that function does.
//!
//! The detection findings deliberately include rows that only one of the anomaly marker paths
//! identifies, a capacity verdict at risk by severity, one at risk by status, one not at risk,
//! and a document whose `event_type` is JSON `null` -- where `->>` and `get_json_string` are
//! most likely to part ways.

use super::{Anchor, BATCH_ROWS, Backend, instant, opt_num, opt_text, synthetic_uuid, text};
use serde_json::{Value, json};

#[derive(Debug, Clone, PartialEq)]
pub struct EventRow {
    pub id: String,
    pub time: chrono::DateTime<chrono::Utc>,
    pub class_uid: i32,
    pub category_uid: i32,
    pub type_uid: i32,
    pub activity_id: i32,
    pub activity_name: Option<&'static str>,
    pub severity_id: Option<i32>,
    pub severity: Option<&'static str>,
    pub message: String,
    pub status: Option<&'static str>,
    pub status_id: Option<i32>,
    pub log_name: Option<&'static str>,
    pub log_provider: Option<&'static str>,
    pub log_level: Option<&'static str>,
    pub metadata: Value,
    pub unmapped: Value,
    pub device: Value,
    pub src_endpoint: Value,
}

fn severity_name(id: i32) -> &'static str {
    match id {
        0 => "Unknown",
        1 => "Informational",
        2 => "Low",
        3 => "Medium",
        4 => "High",
        5 => "Critical",
        _ => "Fatal",
    }
}

struct Kind {
    class_uid: i32,
    category_uid: i32,
    activity_name: &'static str,
    log_provider: Option<&'static str>,
    log_name: Option<&'static str>,
    metadata: fn(i64) -> Value,
    unmapped: fn(i64) -> Value,
}

const KINDS: &[Kind] = &[
    // Anomaly verdict, marked every way at once.
    Kind {
        class_uid: 2004,
        category_uid: 2,
        activity_name: "Create",
        log_provider: Some("anomaly_detection"),
        log_name: Some("anomaly"),
        metadata: |n| json!({"service_radar": {"source_type": "anomaly_detection", "device_uid": "sr:parity-dev-a"}, "event_type": "anomaly", "finding_info": {"uid": format!("finding-{n:04}")}}),
        unmapped: |_| json!({"event_type": "anomaly"}),
    },
    // Anomaly verdict marked only by the detection-finding type; no event_type anywhere.
    Kind {
        class_uid: 2004,
        category_uid: 2,
        activity_name: "Create",
        log_provider: None,
        log_name: None,
        metadata: |_| json!({"detection_finding": {"type": "anomaly"}}),
        unmapped: |_| json!({}),
    },
    // Anomaly verdict marked by the security signal, with a JSON-null event_type.
    Kind {
        class_uid: 2004,
        category_uid: 2,
        activity_name: "Update",
        log_provider: Some("serviceradar"),
        log_name: None,
        metadata: |_| json!({"security_signal": {"source": "anomaly_detection"}, "event_type": null}),
        unmapped: |_| json!({"event_type": "anomaly_detection"}),
    },
    // Capacity verdicts: at risk by status, by projected exhaustion, or not at all.
    Kind {
        class_uid: 2004,
        category_uid: 2,
        activity_name: "Create",
        log_provider: Some("capacity_forecasting"),
        log_name: None,
        metadata: |_| json!({"event_type": "capacity_forecast"}),
        unmapped: |n| match n % 3 {
            0 => {
                json!({"event_type": "capacity_forecast", "capacity_forecast": {"status": "at_risk"}})
            }
            1 => {
                json!({"event_type": "capacity_forecast", "capacity_forecast": {"projected_exhaustion_at": "2031-01-01T00:00:00Z"}})
            }
            _ => {
                json!({"event_type": "capacity_forecast", "capacity_forecast": {"status": "healthy", "projected_exhaustion_at": ""}})
            }
        },
    },
    // Other security findings (vulnerability, compliance).
    Kind {
        class_uid: 2002,
        category_uid: 2,
        activity_name: "Create",
        log_provider: Some("trivy"),
        log_name: Some("trivy"),
        metadata: |n| json!({"service_radar": {"source_type": "trivy"}, "uid": format!("vuln-{n:04}")}),
        unmapped: |_| json!({}),
    },
    Kind {
        class_uid: 2003,
        category_uid: 2,
        activity_name: "Create",
        log_provider: Some("falco"),
        log_name: None,
        metadata: |_| json!({"serviceradar": {"source_type": "falco"}}),
        unmapped: |_| json!({"source_type": "falco"}),
    },
    // Scan activity.
    Kind {
        class_uid: 6007,
        category_uid: 6,
        activity_name: "Scan",
        log_provider: Some("bumblebee"),
        log_name: Some("bumblebee"),
        metadata: |_| json!({"service_radar": {"source_type": "bumblebee"}}),
        unmapped: |_| json!({}),
    },
    // DNS activity.
    Kind {
        class_uid: 4003,
        category_uid: 4,
        activity_name: "Query",
        log_provider: Some("powerdns"),
        log_name: Some("powerdns"),
        metadata: |_| json!({"source": "powerdns"}),
        unmapped: |_| json!({}),
    },
    // Ordinary event-log rows.
    Kind {
        class_uid: 1008,
        category_uid: 1,
        activity_name: "Log",
        log_provider: Some("serviceradar"),
        log_name: Some("events"),
        metadata: |_| json!({"service_radar": {"event_type": "status_change", "device_hostname": "host01.example.com"}}),
        unmapped: |_| json!({}),
    },
];

const DEVICES: [&str; 2] = ["sr:parity-dev-a", "sr:parity-dev-b"];
const SOURCE_IPS: [&str; 3] = ["192.0.2.31", "198.51.100.32", "2001:db8::33"];

pub fn events(anchor: Anchor) -> Vec<EventRow> {
    let mut rows = Vec::new();
    let mut n: i64 = 0;
    for slot in 0..90_i64 {
        for (k, kind) in KINDS.iter().enumerate() {
            // Uneven frequency per kind, so no two kinds share a count.
            if (slot + k as i64) % (k as i64 % 4 + 1) != 0 {
                continue;
            }
            n += 1;
            let severity_id = ((slot + 2 * k as i64) % 6) as i32;
            let severity_id = if n % 17 == 0 { None } else { Some(severity_id) };
            rows.push(EventRow {
                id: synthetic_uuid(0x51, n as u64),
                time: anchor.at(slot * 240 + 17 + k as i64),
                class_uid: kind.class_uid,
                category_uid: kind.category_uid,
                type_uid: kind.class_uid * 100 + 1,
                activity_id: 1,
                activity_name: Some(kind.activity_name),
                severity_id,
                severity: severity_id.map(severity_name),
                message: format!("synthetic event {n}"),
                status: Some(if n % 5 == 0 { "Failure" } else { "Success" }),
                status_id: Some(if n % 5 == 0 { 2 } else { 1 }),
                log_name: kind.log_name,
                log_provider: kind.log_provider,
                log_level: Some(["info", "warning", "error"][(n % 3) as usize]),
                metadata: (kind.metadata)(n),
                unmapped: (kind.unmapped)(n),
                device: json!({"uid": DEVICES[(n % 2) as usize], "name": "host01.example.com"}),
                src_endpoint: json!({"ip": SOURCE_IPS[(n % 3) as usize]}),
            });
        }
    }
    rows
}

fn source_type(row: &EventRow) -> Option<String> {
    let service = row
        .metadata
        .get("service_radar")
        .or_else(|| row.metadata.get("serviceradar"))?;
    service
        .get("source_type")?
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

pub fn inserts(rows: &[EventRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let (table, columns) = match backend {
        Backend::Cnpg => (
            "ocsf_events",
            "id, \"time\", class_uid, category_uid, type_uid, activity_id, activity_name, \
             severity_id, severity, message, status, status_id, log_name, log_provider, \
             log_level, metadata, unmapped, device, src_endpoint",
        ),
        Backend::StarRocks => (
            "events",
            "id, `time`, class_uid, category_uid, type_uid, activity_id, activity_name, \
             severity_id, severity, message, status, status_id, log_name, log_provider, \
             log_level, metadata, unmapped, device, src_endpoint_ip, source_type, observables",
        ),
    };
    rows.chunks(BATCH_ROWS)
        .map(|chunk| {
            let values: Vec<String> = chunk
                .iter()
                .map(|r| {
                    let mut fields = vec![
                        match backend {
                            Backend::Cnpg => format!("{}::uuid", text(&r.id)),
                            Backend::StarRocks => text(&r.id),
                        },
                        instant(r.time, backend),
                        r.class_uid.to_string(),
                        r.category_uid.to_string(),
                        r.type_uid.to_string(),
                        r.activity_id.to_string(),
                        opt_text(r.activity_name),
                        opt_num(r.severity_id),
                        opt_text(r.severity),
                        text(&r.message),
                        opt_text(r.status),
                        opt_num(r.status_id),
                        opt_text(r.log_name),
                        opt_text(r.log_provider),
                        opt_text(r.log_level),
                    ];
                    let doc = |value: &Value| match backend {
                        Backend::Cnpg => format!("{}::jsonb", text(&value.to_string())),
                        Backend::StarRocks => text(&value.to_string()),
                    };
                    fields.push(doc(&r.metadata));
                    fields.push(doc(&r.unmapped));
                    fields.push(doc(&r.device));
                    match backend {
                        Backend::Cnpg => fields.push(doc(&r.src_endpoint)),
                        Backend::StarRocks => {
                            fields.push(opt_text(r.src_endpoint.get("ip").and_then(Value::as_str)));
                            fields.push(opt_text(source_type(r).as_deref()));
                            // CNPG's column default.
                            fields.push(text("[]"));
                        }
                    }
                    format!("({})", fields.join(", "))
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.{table} ({columns}) VALUES\n{}",
                values.join(",\n")
            )
        })
        .collect()
}
