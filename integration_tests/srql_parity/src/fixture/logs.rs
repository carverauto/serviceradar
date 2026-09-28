//! Log rows.
//!
//! Three services, one row a minute over the main hours. The severity column pair covers every
//! arm of the bucket classifier both dialects implement (`serviceradar_log_severity_bucket` on
//! CNPG, `log_severity_bucket_sql` on StarRocks): recognised text in mixed case, text that
//! outranks a disagreeing number, a number with no text, unrecognised text that falls back to
//! the number, and a row neither classifies.

use super::{
    Anchor, BATCH_ROWS, Backend, instant, opt_instant, opt_num, opt_text, synthetic_uuid, text,
};

#[derive(Debug, Clone, PartialEq)]
pub struct LogRow {
    pub id: String,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    /// The collection instant (OTel `observedTimeUnixNano` / ingest receive time). Kept for
    /// display; window membership and ordering use `timestamp` on both backends.
    pub observed_timestamp: Option<chrono::DateTime<chrono::Utc>>,
    pub severity_text: Option<&'static str>,
    pub severity_number: Option<i32>,
    pub body: String,
    pub service_name: &'static str,
    pub source: &'static str,
    pub ingest_agent_id: &'static str,
    pub source_ip: &'static str,
}

const SEVERITIES: [(Option<&str>, Option<i32>); 12] = [
    (Some("INFO"), Some(9)),
    (Some("info"), Some(9)),
    (Some("Warn"), Some(13)),
    (Some("ERROR"), Some(17)),
    (Some("Critical"), Some(20)),
    (Some("FATAL"), Some(21)),
    (Some("debug"), Some(5)),
    (Some("notice"), Some(17)),
    (None, Some(14)),
    (Some("bogus"), Some(19)),
    (Some(""), Some(0)),
    (None, None),
];
const SERVICES: [(&str, &str, &str); 3] = [
    ("svc-alpha", "syslog", "192.0.2.21"),
    ("svc-beta", "otel", "192.0.2.22"),
    ("svc-gamma", "otel", "198.51.100.23"),
];

pub fn logs(anchor: Anchor) -> Vec<LogRow> {
    let mut rows = Vec::new();
    for minute in 0..360_i64 {
        // Uneven per service so severity counts differ between services.
        for (index, (service, source, ip)) in SERVICES.iter().enumerate() {
            if (minute + index as i64) % (index as i64 + 1) != 0 {
                continue;
            }
            let n = (minute as usize * 7 + index * 5) % SEVERITIES.len();
            let (severity_text, severity_number) = SEVERITIES[n];
            rows.push(LogRow {
                id: synthetic_uuid(0x41, (minute * 8 + index as i64) as u64),
                timestamp: anchor.at(minute * 60 + 13 + index as i64),
                observed_timestamp: None,
                severity_text,
                severity_number,
                body: format!("synthetic log line {minute} from {service}"),
                service_name: service,
                source,
                ingest_agent_id: "agent-parity-01",
                source_ip: ip,
            });
        }
    }

    // The edge window: five lines inside it and one EXACTLY on its upper bound, which a
    // half-open window leaves to the next one.
    let edge_times = [10_i64, 20, 30, 40, 50]
        .into_iter()
        .map(|offset_minutes| anchor.at(7 * 3600 + offset_minutes * 60))
        .chain(std::iter::once(anchor.edge_instant()));
    for (n, timestamp) in edge_times.enumerate() {
        let (service, source, ip) = SERVICES[0];
        rows.push(LogRow {
            id: synthetic_uuid(0x42, n as u64),
            timestamp,
            observed_timestamp: None,
            severity_text: Some("INFO"),
            severity_number: Some(9),
            body: format!("synthetic edge log line {n}"),
            service_name: service,
            source,
            ingest_agent_id: "agent-parity-01",
            source_ip: ip,
        });
    }

    // The observed-timestamp window ({window_skew}): rows whose collection instant
    // (`observed_timestamp`) disagrees with their event time (`timestamp`). They exist to prove
    // both backends window and order by the event time, so a row never migrates windows (or
    // changes list position) on one dialect only.
    //
    //   skew_inside   event +10m, observed +50m   } both inside: reversed order under observed
    //   skew_inside2  event +20m, observed +40m   }
    //   skew_cross    event +30m, observed +90m   observed lies past the window's upper bound
    let skew = [
        (600_i64, 3000_i64, "skew_inside"),
        (1200, 2400, "skew_inside2"),
        (1800, 5400, "skew_cross"),
    ];
    for (n, (event_offset, observed_offset, label)) in skew.into_iter().enumerate() {
        let (service, source, ip) = SERVICES[0];
        rows.push(LogRow {
            id: synthetic_uuid(0x43, n as u64),
            timestamp: anchor.at(11 * 3600 + event_offset),
            observed_timestamp: Some(anchor.at(11 * 3600 + observed_offset)),
            severity_text: Some("INFO"),
            severity_number: Some(9),
            body: format!("synthetic {label} log line"),
            service_name: service,
            source,
            ingest_agent_id: "agent-parity-01",
            source_ip: ip,
        });
    }
    rows
}

pub fn inserts(rows: &[LogRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = "id, `timestamp`, ingest_identity, severity_text, severity_number, body, \
                   service_name, source, ingest_agent_id, ingest_partition, source_ip, \
                   observed_timestamp";
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
                        "({id}, {}, {}, {}, {}, {}, {}, {}, {}, 'default', {}, {})",
                        instant(r.timestamp, backend),
                        text(&format!("parity:{}", r.id)),
                        opt_text(r.severity_text),
                        opt_num(r.severity_number),
                        text(&r.body),
                        text(r.service_name),
                        text(r.source),
                        text(r.ingest_agent_id),
                        text(r.source_ip),
                        opt_instant(r.observed_timestamp, backend),
                    )
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.logs ({columns}) VALUES\n{}",
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
    fn the_edge_window_has_a_line_exactly_on_its_upper_bound() {
        let rows = logs(anchor());
        assert!(
            rows.iter()
                .any(|row| row.timestamp == anchor().edge_instant())
        );
    }

    #[test]
    fn the_observed_window_has_rows_that_disagree_with_their_event_time() {
        let rows = logs(anchor());
        let skew: Vec<&LogRow> = rows
            .iter()
            .filter(|row| row.observed_timestamp.is_some())
            .collect();
        assert_eq!(skew.len(), 3, "three skew rows: two ordering, one crossing");
        assert!(
            skew.iter()
                .all(|row| row.observed_timestamp != Some(row.timestamp))
        );
        // The crossing row's observed instant lies past {window_skew}'s upper bound, while its
        // event time is inside: an observed-time window drops it, an event-time window keeps it.
        let skew_window_end = anchor().at(12 * 3600);
        assert!(
            skew.iter().any(|row| row.timestamp < skew_window_end
                && row.observed_timestamp > Some(skew_window_end))
        );
    }
}
