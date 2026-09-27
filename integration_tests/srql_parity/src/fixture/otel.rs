//! OTel metric samples (span-derived, `otel_metrics`) and OTLP data points
//! (`otel_metric_points`).
//!
//! Samples: three services, one span every two minutes each, at distinct instants. Every
//! seventh span is slow and every eleventh has no `is_slow` at all, so the two dialects'
//! opposite NULL handling of `!is_slow:` on the row and stats paths is exercised; some fast
//! spans have no duration. Every slow span has a duration, and no two the same, so the
//! slowest-spans list has one correct order.
//!
//! Points: three metric names reported by two services at distinct instants, at uneven rates
//! (every one, two and three minutes), so a count by metric name has no ties. Every fifth
//! point has NULL attributes, which the row path's `!attributes:` drops and the stats path
//! keeps. Values are distinct, so a sort by value has one correct order.
//!
//! Every value is invented.

use super::{Anchor, BATCH_ROWS, Backend, instant, opt_text, text};

#[derive(Debug, Clone, PartialEq)]
pub struct SampleRow {
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub trace_id: String,
    pub span_id: String,
    pub service_name: &'static str,
    pub span_name: &'static str,
    pub span_kind: &'static str,
    pub duration_ms: Option<f64>,
    pub metric_type: &'static str,
    pub http_route: Option<&'static str>,
    pub http_status_code: &'static str,
    pub is_slow: Option<bool>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PointRow {
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub metric_name: &'static str,
    pub metric_type: &'static str,
    pub unit: &'static str,
    pub temporality: Option<&'static str>,
    pub is_monotonic: Option<bool>,
    pub service_name: &'static str,
    pub attributes: Option<String>,
    pub attributes_hash: String,
    pub value: f64,
}

const SERVICES: [(&str, &str, Option<&str>); 3] = [
    ("svc-alpha", "GET /cart", Some("/cart")),
    ("svc-beta", "POST /checkout", Some("/checkout")),
    ("svc-gamma", "grpc.health.Check", None),
];

struct MetricSpec {
    name: &'static str,
    kind: &'static str,
    unit: &'static str,
    temporality: Option<&'static str>,
    monotonic: Option<bool>,
    every_minutes: i64,
}

const METRICS: [MetricSpec; 3] = [
    MetricSpec {
        name: "http.server.requests",
        kind: "sum",
        unit: "1",
        temporality: Some("cumulative"),
        monotonic: Some(true),
        every_minutes: 1,
    },
    MetricSpec {
        name: "process.memory.usage",
        kind: "gauge",
        unit: "By",
        temporality: None,
        monotonic: None,
        every_minutes: 2,
    },
    MetricSpec {
        name: "http.server.duration",
        kind: "histogram",
        unit: "ms",
        temporality: Some("delta"),
        monotonic: Some(false),
        every_minutes: 3,
    },
];

pub fn samples(anchor: Anchor) -> Vec<SampleRow> {
    let mut rows = Vec::new();
    for slot in 0..150_i64 {
        for (index, (service, span_name, route)) in SERVICES.iter().enumerate() {
            let n = (slot * 3 + index as i64) as u64;
            let slow = n.is_multiple_of(7);
            rows.push(SampleRow {
                timestamp: anchor.at(slot * 120 + 17 + index as i64 * 5),
                trace_id: format!("{:032x}", 0x5100_0000_u64 + n),
                span_id: format!("{:016x}", 0x5200_0000_u64 + n),
                service_name: service,
                span_name,
                span_kind: if index == 2 { "CLIENT" } else { "SERVER" },
                duration_ms: (slow || n % 13 != 5).then_some(if slow {
                    600.0 + n as f64 * 1.5
                } else {
                    5.0 + (n % 90) as f64 + index as f64 * 0.25
                }),
                metric_type: if index == 2 { "grpc" } else { "http" },
                http_route: *route,
                http_status_code: if n.is_multiple_of(17) { "500" } else { "200" },
                is_slow: (n % 11 != 3).then_some(slow),
            });
        }
    }
    rows
}

pub fn points(anchor: Anchor) -> Vec<PointRow> {
    let mut rows = Vec::new();
    for minute in 0..300_i64 {
        for (m, metric) in METRICS.iter().enumerate() {
            if minute % metric.every_minutes != 0 {
                continue;
            }
            for (s, service) in ["svc-alpha", "svc-beta"].iter().enumerate() {
                let n = rows.len() as u64;
                let route = ["/cart", "/checkout"][s];
                let attributes =
                    (n % 5 != 2).then(|| format!(r#"{{"http.route":"{route}","n":"{m}"}}"#));
                rows.push(PointRow {
                    timestamp: anchor.at(minute * 60 + 3 + m as i64 * 11 + s as i64 * 2),
                    metric_name: metric.name,
                    metric_type: metric.kind,
                    unit: metric.unit,
                    temporality: metric.temporality,
                    is_monotonic: metric.monotonic,
                    service_name: service,
                    attributes,
                    attributes_hash: format!("{:032x}", 0x6100_0000_u64 + (m * 2 + s) as u64),
                    value: 1_000.0 * m as f64 + minute as f64 + s as f64 * 0.5,
                });
            }
        }
    }
    rows
}

fn opt_bool(value: Option<bool>) -> String {
    value.map_or_else(|| "NULL".into(), |v| v.to_string())
}

fn opt_double(value: Option<f64>) -> String {
    value.map_or_else(|| "NULL".into(), |v| format!("{v:?}"))
}

/// The warehouse key the EventWriter encoder derives (`Rows.encode`); any value unique per
/// CNPG key serves the fixture, since no query reads it.
fn warehouse_id(prefix: &str, index: usize) -> String {
    text(&format!("{prefix}-{index:08}"))
}

pub fn sample_inserts(rows: &[SampleRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = "`timestamp`, trace_id, span_id, service_name, span_name, span_kind, \
                   duration_ms, metric_type, http_route, http_status_code, is_slow, created_at, \
                   ingest_identity, ingest_agent_id, ingest_partition";
    let columns = match backend {
        Backend::Cnpg => columns.replace('`', "\""),
        Backend::StarRocks => format!("id, {columns}"),
    };
    rows.chunks(BATCH_ROWS)
        .enumerate()
        .map(|(chunk_index, chunk)| {
            let values: Vec<String> = chunk
                .iter()
                .enumerate()
                .map(|(offset, r)| {
                    let fields = format!(
                        "{t}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {t}, '', 'agent-parity-01', 'default'",
                        text(&r.trace_id),
                        text(&r.span_id),
                        text(r.service_name),
                        text(r.span_name),
                        text(r.span_kind),
                        opt_double(r.duration_ms),
                        text(r.metric_type),
                        opt_text(r.http_route),
                        text(r.http_status_code),
                        opt_bool(r.is_slow),
                        t = instant(r.timestamp, backend),
                    );
                    match backend {
                        Backend::Cnpg => format!("({fields})"),
                        Backend::StarRocks => format!(
                            "({}, {fields})",
                            warehouse_id("sample", chunk_index * BATCH_ROWS + offset)
                        ),
                    }
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.otel_metrics ({columns}) VALUES\n{}",
                values.join(",\n")
            )
        })
        .collect()
}

pub fn point_inserts(rows: &[PointRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = "`timestamp`, metric_name, metric_type, unit, temporality, is_monotonic, \
                   service_name, attributes, attributes_hash, value, scope_name, \
                   service_instance_id, created_at, ingest_identity, ingest_agent_id, \
                   ingest_partition";
    let columns = match backend {
        Backend::Cnpg => columns.replace('`', "\""),
        Backend::StarRocks => format!("id, {columns}"),
    };
    rows.chunks(BATCH_ROWS)
        .enumerate()
        .map(|(chunk_index, chunk)| {
            let values: Vec<String> = chunk
                .iter()
                .enumerate()
                .map(|(offset, r)| {
                    let fields = format!(
                        "{t}, {}, {}, {}, {}, {}, {}, {}, {}, {:?}, 'parity.meter', '', {t}, '', 'agent-parity-01', 'default'",
                        text(r.metric_name),
                        text(r.metric_type),
                        text(r.unit),
                        opt_text(r.temporality),
                        opt_bool(r.is_monotonic),
                        text(r.service_name),
                        opt_text(r.attributes.as_deref()),
                        text(&r.attributes_hash),
                        r.value,
                        t = instant(r.timestamp, backend),
                    );
                    match backend {
                        Backend::Cnpg => format!("({fields})"),
                        Backend::StarRocks => format!(
                            "({}, {fields})",
                            warehouse_id("point", chunk_index * BATCH_ROWS + offset)
                        ),
                    }
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.otel_metric_points ({columns}) VALUES\n{}",
                values.join(",\n")
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, Utc};
    use std::collections::{BTreeMap, BTreeSet};

    fn anchor() -> Anchor {
        Anchor::for_run(
            DateTime::parse_from_rfc3339("2030-03-04T15:16:17Z")
                .unwrap()
                .with_timezone(&Utc),
        )
    }

    /// Orders the inventory compares must have one right answer: no two rows share an
    /// instant, no two slow spans a duration, no two points a value, no two metric names a
    /// count. The CNPG primary keys must hold too.
    #[test]
    fn every_compared_order_is_total_and_keys_are_unique() {
        let samples = samples(anchor());
        let instants: BTreeSet<_> = samples.iter().map(|r| r.timestamp).collect();
        assert_eq!(instants.len(), samples.len());
        let span_ids: BTreeSet<_> = samples.iter().map(|r| &r.span_id).collect();
        assert_eq!(span_ids.len(), samples.len());
        let slow: Vec<_> = samples.iter().filter(|r| r.is_slow == Some(true)).collect();
        let durations: BTreeSet<_> = slow
            .iter()
            .map(|r| r.duration_ms.map(f64::to_bits))
            .collect();
        assert_eq!(durations.len(), slow.len());
        assert!(slow.len() > 25, "the slowest-spans list is a real top 25");
        assert!(samples.iter().any(|r| r.is_slow.is_none()));
        assert!(samples.iter().any(|r| r.duration_ms.is_none()));

        let points = points(anchor());
        let instants: BTreeSet<_> = points.iter().map(|r| r.timestamp).collect();
        assert_eq!(instants.len(), points.len());
        let values: BTreeSet<_> = points.iter().map(|r| r.value.to_bits()).collect();
        assert_eq!(values.len(), points.len());
        let keys: BTreeSet<_> = points
            .iter()
            .map(|r| {
                (
                    r.timestamp,
                    r.metric_name,
                    r.service_name,
                    &r.attributes_hash,
                )
            })
            .collect();
        assert_eq!(keys.len(), points.len());
        let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
        for point in &points {
            *counts.entry(point.metric_name).or_default() += 1;
        }
        let distinct: BTreeSet<_> = counts.values().collect();
        assert_eq!(distinct.len(), counts.len());
        assert!(points.iter().any(|r| r.attributes.is_none()));
    }
}
