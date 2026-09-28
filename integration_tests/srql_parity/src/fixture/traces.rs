//! OTel spans (`otel_traces`) and the trace summaries derived from them
//! (`otel_trace_summaries`).
//!
//! One trace a minute per service over the main hours. A trace is a root span plus up to two
//! children, one of them in a second service, so a summary's service set differs from its root
//! service. Every seventh trace is an orphan (its spans point at a parent that was never
//! exported), so the earliest span stands in as root; every eleventh has a failed child, so
//! error counts differ from root status; one child in every thirteenth trace has no service
//! name, so the RED rollup's `COALESCE(service_name, '')` group and a summary's NULL-free
//! service set are exercised.
//!
//! Summaries are computed here with `RefreshTraceSummariesWorker`'s rules and seeded into both
//! backends: the harness compares readers, and the worker's CNPG and warehouse statements are
//! checked separately. Instants, trace durations and span starts within a trace are distinct,
//! so every compared order has one right answer.
//!
//! Every value is invented.

use super::{Anchor, BATCH_ROWS, Backend, instant, opt_text, text};
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, PartialEq)]
pub struct SpanRow {
    pub timestamp: DateTime<Utc>,
    pub trace_id: String,
    pub span_id: String,
    pub parent_span_id: Option<String>,
    pub name: &'static str,
    pub kind: i32,
    pub start_ns: i64,
    pub end_ns: i64,
    pub service_name: Option<&'static str>,
    pub status_code: i32,
    pub status_message: Option<&'static str>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SummaryRow {
    pub trace_id: String,
    pub timestamp: DateTime<Utc>,
    pub root_span_id: String,
    pub root_span_name: &'static str,
    pub root_service_name: Option<&'static str>,
    pub root_span_kind: i32,
    pub start_ns: i64,
    pub end_ns: i64,
    pub status_code: i32,
    pub status_message: Option<&'static str>,
    pub service_set: Vec<&'static str>,
    pub span_count: i64,
    pub error_count: i64,
}

impl SummaryRow {
    pub fn duration_ms(&self) -> f64 {
        (self.end_ns - self.start_ns) as f64 / 1_000_000.0
    }
}

const SERVICES: [(&str, &str, &str); 3] = [
    ("svc-alpha", "svc-beta", "GET /cart"),
    ("svc-beta", "svc-gamma", "POST /checkout"),
    ("svc-gamma", "svc-alpha", "grpc.health.Check"),
];

pub fn trace_id(n: u64) -> String {
    format!("{:032x}", 0x7100_0000_u64 + n)
}

fn span_id(n: u64, index: u64) -> String {
    format!("{:016x}", 0x7200_0000_u64 + n * 4 + index)
}

pub fn spans(anchor: Anchor) -> Vec<SpanRow> {
    let mut rows = Vec::new();
    for minute in 0..290_i64 {
        for (s, (service, downstream, operation)) in SERVICES.iter().enumerate() {
            let n = (minute * 3 + s as i64) as u64;
            let orphan = n % 7 == 3;
            let failed_child = n % 11 == 5;
            let unnamed_child = n % 13 == 8;
            let base = anchor.at(minute * 60 + s as i64 * 15);
            let base_ns = base.timestamp_nanos_opt().expect("in range");
            // Distinct per trace: the slowest-traces list has one right order.
            let root_ms = 20 + (n * 37 % 400) as i64;
            let root_id = span_id(n, 0);
            let root_parent = orphan.then(|| format!("{:016x}", 0x7f00_0000_u64 + n));
            rows.push(SpanRow {
                timestamp: base,
                trace_id: trace_id(n),
                span_id: root_id.clone(),
                parent_span_id: root_parent,
                name: operation,
                kind: 2,
                start_ns: base_ns,
                end_ns: base_ns + root_ms * 1_000_000 + n as i64,
                service_name: Some(service),
                status_code: if n % 17 == 4 { 2 } else { 0 },
                status_message: (n % 17 == 4).then_some("root failed"),
            });
            let children = if n.is_multiple_of(5) { 1 } else { 2 };
            for index in 1..=children {
                let start = base_ns + index as i64 * 3_000_000;
                rows.push(SpanRow {
                    timestamp: base + chrono::Duration::seconds(index as i64),
                    trace_id: trace_id(n),
                    span_id: span_id(n, index),
                    parent_span_id: Some(root_id.clone()),
                    name: if index == 1 { "db.query" } else { "rpc.call" },
                    kind: 3,
                    start_ns: start,
                    // `+ n` ns keeps every trace's duration distinct whichever span ends it.
                    end_ns: start + (5 + index as i64 * 7 + (n % 23) as i64) * 1_000_000 + n as i64,
                    service_name: match index {
                        2 if unnamed_child => None,
                        2 => Some(downstream),
                        _ => Some(service),
                    },
                    status_code: if failed_child && index == children {
                        2
                    } else {
                        0
                    },
                    status_message: None,
                });
            }
        }
    }
    rows
}

/// `RefreshTraceSummariesWorker`'s summary of each trace.
pub fn summaries(spans: &[SpanRow]) -> Vec<SummaryRow> {
    let mut by_trace: std::collections::BTreeMap<&str, Vec<&SpanRow>> = Default::default();
    for span in spans {
        by_trace.entry(&span.trace_id).or_default().push(span);
    }
    by_trace
        .into_iter()
        .map(|(trace, spans)| {
            let root = spans
                .iter()
                .min_by_key(|span| (span.parent_span_id.is_some(), span.start_ns, &span.span_id))
                .expect("a trace has spans");
            let mut service_set: Vec<&str> =
                spans.iter().filter_map(|span| span.service_name).collect();
            service_set.sort_unstable();
            service_set.dedup();
            SummaryRow {
                trace_id: trace.to_string(),
                timestamp: spans.iter().map(|s| s.timestamp).max().expect("spans"),
                root_span_id: root.span_id.clone(),
                root_span_name: root.name,
                root_service_name: root.service_name,
                root_span_kind: root.kind,
                start_ns: spans.iter().map(|s| s.start_ns).min().expect("spans"),
                end_ns: spans.iter().map(|s| s.end_ns).max().expect("spans"),
                status_code: root.status_code,
                status_message: root.status_message,
                service_set,
                span_count: spans.len() as i64,
                error_count: spans.iter().filter(|s| s.status_code == 2).count() as i64,
            }
        })
        .collect()
}

pub fn span_inserts(rows: &[SpanRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = "`timestamp`, trace_id, span_id, parent_span_id, name, kind, \
                   start_time_unix_nano, end_time_unix_nano, service_name, service_namespace, \
                   deployment_environment, status_code, status_message, attributes, \
                   dropped_attributes_count, dropped_events_count, dropped_links_count, \
                   created_at, ingest_identity, ingest_agent_id, ingest_partition";
    let columns = match backend {
        Backend::Cnpg => columns.replace('`', "\""),
        Backend::StarRocks => columns.to_string(),
    };
    rows.chunks(BATCH_ROWS)
        .map(|chunk| {
            let values: Vec<String> = chunk
                .iter()
                .map(|r| {
                    format!(
                        "({t}, {}, {}, {}, {}, {}, {}, {}, {}, '', '', {}, {}, {}, 0, 0, 0, {t}, '', 'agent-parity-01', 'default')",
                        text(&r.trace_id),
                        text(&r.span_id),
                        opt_text(r.parent_span_id.as_deref()),
                        text(r.name),
                        r.kind,
                        r.start_ns,
                        r.end_ns,
                        opt_text(r.service_name),
                        r.status_code,
                        opt_text(r.status_message),
                        text(r#"{"parity":"span"}"#),
                        t = instant(r.timestamp, backend),
                    )
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.otel_traces ({columns}) VALUES\n{}",
                values.join(",\n")
            )
        })
        .collect()
}

pub fn summary_inserts(rows: &[SummaryRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = "trace_id, `timestamp`, root_span_id, root_span_name, root_service_name, \
                   root_service_namespace, deployment_environment, root_span_kind, \
                   start_time_unix_nano, end_time_unix_nano, duration_ms, status_code, \
                   status_message, service_set, span_count, error_count, refreshed_at";
    let columns = match backend {
        Backend::Cnpg => columns.replace('`', "\""),
        Backend::StarRocks => columns.to_string(),
    };
    rows.chunks(BATCH_ROWS)
        .map(|chunk| {
            let values: Vec<String> = chunk
                .iter()
                .map(|r| {
                    let names = r.service_set.iter().map(|s| text(s)).collect::<Vec<_>>();
                    let set = match backend {
                        Backend::Cnpg => format!("ARRAY[{}]::text[]", names.join(", ")),
                        Backend::StarRocks => format!("[{}]", names.join(", ")),
                    };
                    format!(
                        "({}, {t}, {}, {}, {}, '', '', {}, {}, {}, {:?}, {}, {}, {set}, {}, {}, {t})",
                        text(&r.trace_id),
                        text(&r.root_span_id),
                        text(r.root_span_name),
                        opt_text(r.root_service_name),
                        r.root_span_kind,
                        r.start_ns,
                        r.end_ns,
                        r.duration_ms(),
                        r.status_code,
                        opt_text(r.status_message),
                        r.span_count,
                        r.error_count,
                        t = instant(r.timestamp, backend),
                    )
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.otel_trace_summaries ({columns}) VALUES\n{}",
                values.join(",\n")
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    fn anchor() -> Anchor {
        Anchor::for_run(
            DateTime::parse_from_rfc3339("2030-03-04T15:16:17Z")
                .unwrap()
                .with_timezone(&Utc),
        )
    }

    /// Every compared order has one right answer, the CNPG keys hold, and the adversarial
    /// cases the module promises are present.
    #[test]
    fn orders_are_total_and_every_case_is_present() {
        let spans = spans(anchor());
        let instants: BTreeSet<_> = spans.iter().map(|s| s.timestamp).collect();
        assert_eq!(instants.len(), spans.len());
        let keys: BTreeSet<_> = spans.iter().map(|s| (&s.trace_id, &s.span_id)).collect();
        assert_eq!(keys.len(), spans.len());

        let summaries = summaries(&spans);
        let durations: BTreeSet<_> = summaries
            .iter()
            .map(|s| s.duration_ms().to_bits())
            .collect();
        assert_eq!(durations.len(), summaries.len());
        let stamps: BTreeSet<_> = summaries.iter().map(|s| s.timestamp).collect();
        assert_eq!(stamps.len(), summaries.len());

        // An orphan trace takes its earliest span as root.
        let orphan = summaries
            .iter()
            .find(|s| s.trace_id == trace_id(3))
            .expect("orphan trace");
        assert_eq!(orphan.root_span_id, span_id(3, 0));
        assert!(
            summaries
                .iter()
                .any(|s| s.error_count > 0 && s.status_code == 0)
        );
        assert!(summaries.iter().any(|s| s.service_set.len() > 1));
        assert!(spans.iter().any(|s| s.service_name.is_none()));
        assert!(summaries.iter().any(|s| s.span_count == 2));
    }
}
