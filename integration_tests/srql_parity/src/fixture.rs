//! The ONE generator both backends are seeded from.
//!
//! Every value here is invented: documentation address ranges (192.0.2.0/24, 198.51.100.0/24,
//! 203.0.113.0/24, 2001:db8::/32), made-up device, gateway and agent ids, arithmetic counter
//! values. Nothing is exported from a running system (AGENTS.md, Hard Rules).
//!
//! It is deterministic: no randomness, and every timestamp is a fixed offset from one ANCHOR.
//! The anchor is midnight UTC two days before the run rather than a constant date, because the
//! warehouse tables carry `partition_live_number = 90` -- a constant date would age out of
//! StarRocks and leave both backends agreeing on an empty result. The harness additionally
//! refuses an empty result for a must-match shape, so that failure cannot be silent either.
//!
//! Layout of the day after the anchor (A):
//!
//!   [A,     A+6h)   every ordinary row; `{window_main}` is [A, A+5h] (raw rows on both
//!                   backends), `{window_long}` is [A, A+6h] (the rollup routes)
//!   [A+7h,  A+8h]   the EDGE window: a few rows, one exactly at A+8h (inclusive/exclusive bound)
//!   [A+9h,  A+10h)  the HALVES window: flows with NULL totals and directional halves
//!
//! Adversarial rows are fenced into their own windows or device ids so that one deliberate
//! deviation cannot leak into, and mask a real difference in, an unrelated shape.

use chrono::{DateTime, Duration, NaiveTime, Utc};

pub mod events;
pub mod logs;
pub mod mtr;

pub const DEVICE_A: &str = "sr:parity-dev-a";
pub const DEVICE_B: &str = "sr:parity-dev-b";
pub const DEVICE_C: &str = "sr:parity-dev-c";
const GATEWAY_1: &str = "gw-parity-01";
const GATEWAY_2: &str = "gw-parity-02";
const AGENT_1: &str = "agent-parity-01";
const AGENT_2: &str = "agent-parity-02";

const TWO_POW_32: f64 = 4_294_967_296.0;
const TWO_POW_64: f64 = 18_446_744_073_709_551_616.0;

#[derive(Debug, Clone, Copy)]
pub struct Anchor(pub DateTime<Utc>);

impl Anchor {
    /// Midnight UTC, two days before `now`. Day granularity: two runs on one day seed identical
    /// rows.
    pub fn for_run(now: DateTime<Utc>) -> Self {
        let midnight = now.date_naive().and_time(NaiveTime::MIN).and_utc();
        Self(midnight - Duration::days(2))
    }

    pub fn at(&self, seconds: i64) -> DateTime<Utc> {
        self.0 + Duration::seconds(seconds)
    }

    /// The SRQL `time:[start,end]` text for each named window an inventory entry may use.
    pub fn windows(&self) -> Vec<(&'static str, String)> {
        let span = |from: i64, to: i64| {
            format!(
                "time:[{},{}]",
                self.at(from).format("%Y-%m-%dT%H:%M:%SZ"),
                self.at(to).format("%Y-%m-%dT%H:%M:%SZ")
            )
        };
        let range = |from_h: i64, to_h: i64| span(from_h * 3600, to_h * 3600);
        vec![
            // Just under five hours: under both dialects' six-hour rollup threshold, so raw
            // rows. It ends between two samples on purpose: whether the upper bound is
            // inclusive is the edge window's question, and must not leak into every shape.
            ("{window_main}", span(0, 5 * 3600 - 30)),
            // Six hours: at the threshold, so CNPG reads its continuous aggregates and
            // StarRocks its hourly materialized views.
            ("{window_long}", range(0, 6)),
            ("{window_cpu}", range(0, 2)),
            ("{window_edge}", range(7, 8)),
            ("{window_halves}", range(9, 10)),
        ]
    }

    /// The instant the edge window ends on, which exactly one row of each dataset sits at.
    pub fn edge_instant(&self) -> DateTime<Utc> {
        self.at(8 * 3600)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MetricRow {
    pub timestamp: DateTime<Utc>,
    pub gateway_id: &'static str,
    pub agent_id: &'static str,
    pub series_key: String,
    pub metric_name: &'static str,
    pub metric_type: &'static str,
    pub device_id: &'static str,
    pub value: f64,
    pub if_index: Option<i32>,
    pub counter_width: Option<i32>,
    /// JSON text. `jsonb` on CNPG, VARCHAR on StarRocks.
    pub tags: Option<String>,
    /// JSON text. CNPG only: the warehouse table has no `metadata` column, which is the whole
    /// of the documented "no rate ceiling, no 2^64 wrap arm" deviation.
    pub metadata: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FlowRow {
    pub id: String,
    pub time: DateTime<Utc>,
    pub start_time: Option<DateTime<Utc>>,
    pub end_time: Option<DateTime<Utc>>,
    pub src_endpoint_ip: &'static str,
    pub dst_endpoint_ip: &'static str,
    pub src_endpoint_port: i32,
    pub dst_endpoint_port: i32,
    pub protocol_num: i32,
    pub protocol_name: &'static str,
    pub tcp_flags: Option<i32>,
    pub bytes_total: Option<i64>,
    pub packets_total: Option<i64>,
    pub bytes_in: Option<i64>,
    pub bytes_out: Option<i64>,
    pub packets_in: Option<i64>,
    pub packets_out: Option<i64>,
    /// `None` is "the exporter reported no sampling". CNPG's column is `NOT NULL DEFAULT 1`, so
    /// it is loaded there as the default; StarRocks stores the NULL.
    pub sampling_rate: Option<i64>,
    /// An eBPF-attributed flow: `event_type = 'attributed_flow'` in the warehouse column and
    /// in the CNPG `ocsf_payload` document, the discriminator both dialects scope
    /// `in:attributed_flows` by.
    pub attributed: bool,
    /// What EventWriter's FlowEnrichment stores at ingest: the ServicePorts display label for
    /// the destination port (`ServiceRadar.ReferenceData.ServicePorts`), restated for the
    /// fixture's four ports.
    pub dst_service_label: Option<&'static str>,
}

fn service_label(protocol_num: i32, port: i32) -> Option<&'static str> {
    match (protocol_num, port) {
        (6, 443) => Some("HTTPS"),
        (6, 22) => Some("SSH"),
        (6, 8080) => Some("HTTP Alt"),
        (_, 53) => Some("DNS"),
        (17, 443) => Some("https"),
        (17, 22) => Some("ssh"),
        (17, 8080) => Some("http-alt"),
        _ => None,
    }
}

struct Series {
    gateway: &'static str,
    agent: &'static str,
    device: &'static str,
    metric_type: &'static str,
    metric_name: &'static str,
    if_index: Option<i32>,
    counter_width: Option<i32>,
    tags: Option<String>,
    metadata: Option<String>,
    key_suffix: &'static str,
}

impl Series {
    fn row(&self, timestamp: DateTime<Utc>, value: f64) -> MetricRow {
        MetricRow {
            timestamp,
            gateway_id: self.gateway,
            agent_id: self.agent,
            series_key: format!(
                "{}|{}|{}|{}",
                self.device, self.metric_type, self.metric_name, self.key_suffix
            ),
            metric_name: self.metric_name,
            metric_type: self.metric_type,
            device_id: self.device,
            value,
            if_index: self.if_index,
            counter_width: self.counter_width,
            tags: self.tags.clone(),
            metadata: self.metadata.clone(),
        }
    }
}

fn snmp(
    device: &'static str,
    metric_name: &'static str,
    if_index: Option<i32>,
    counter_width: Option<i32>,
    key_suffix: &'static str,
) -> Series {
    let second_site = device == DEVICE_B;
    Series {
        gateway: if second_site { GATEWAY_2 } else { GATEWAY_1 },
        agent: if second_site { AGENT_2 } else { AGENT_1 },
        device,
        metric_type: "snmp",
        metric_name,
        if_index,
        counter_width,
        tags: None,
        metadata: None,
        key_suffix,
    }
}

const POLL_SECONDS: i64 = 60;
const MAIN_POLLS: i64 = 360;

pub fn metrics(anchor: Anchor) -> Vec<MetricRow> {
    let mut rows = Vec::new();

    // 1. A 64-bit counter in the hundreds of GB stepping at exactly 1 Gbit/s (125 MB/s), with a
    //    MISSED POLL (poll 100 absent: one double interval, same rate) and a RESET at poll 200
    //    (device reboot: the previous value is far above 2^32, so neither dialect may read it as
    //    a 32-bit wrap).
    let hc_in = snmp(DEVICE_A, "ifHCInOctets", Some(7), Some(64), "if7");
    for poll in (0..MAIN_POLLS).filter(|poll| *poll != 100) {
        let value = if poll < 200 {
            3.0e11 + 7.5e9 * poll as f64
        } else {
            1.0e6 + 7.5e9 * (poll - 200) as f64
        };
        rows.push(hc_in.row(anchor.at(poll * POLL_SECONDS), value));
    }

    // 2. A clean 64-bit counter beside it, so `series:metric_name` has two series.
    let hc_out = snmp(DEVICE_A, "ifHCOutOctets", Some(7), Some(64), "if7");
    for poll in 0..MAIN_POLLS {
        rows.push(hc_out.row(anchor.at(poll * POLL_SECONDS), 1.0e11 + 1.5e9 * poll as f64));
    }

    // 3. A 32-bit counter that WRAPS between polls, several times over the window.
    let in32 = snmp(DEVICE_A, "ifInOctets", Some(7), Some(32), "if7");
    for poll in 0..MAIN_POLLS {
        let value = (4.0e9 + 6.0e7 * poll as f64) % TWO_POW_32;
        rows.push(in32.row(anchor.at(poll * POLL_SECONDS), value));
    }

    // 4. A legacy counter with NO recorded width that drops while still below 2^32: both
    //    dialects are documented to assume a 32-bit wrap there.
    let out_legacy = snmp(DEVICE_A, "ifOutOctets", Some(7), None, "if7");
    for poll in 0..MAIN_POLLS {
        let value = if poll < 150 {
            1.0e8 + 2.0e7 * poll as f64
        } else {
            5.0e5 + 2.0e7 * (poll - 150) as f64
        };
        rows.push(out_legacy.row(anchor.at(poll * POLL_SECONDS), value));
    }

    // 5. A second device behind a DIFFERENT gateway reporting the same metric on the same
    //    ifIndex at a tenth of the rate: one display series, two physical series. A rate that
    //    forgot to partition by gateway/series would difference one device against the other.
    let hc_in_b = snmp(DEVICE_B, "ifHCInOctets", Some(7), Some(64), "if7");
    for poll in 0..MAIN_POLLS {
        rows.push(hc_in_b.row(anchor.at(poll * POLL_SECONDS), 5.0e10 + 7.5e8 * poll as f64));
    }

    // 6. A second interface and a scalar with NO ifIndex: the NULL dimension of `series:if_index`.
    let hc_in_if3 = snmp(DEVICE_A, "ifHCInOctets", Some(3), Some(64), "if3");
    let uptime = snmp(DEVICE_A, "sysUpTime", None, None, "scalar");
    for poll in (0..MAIN_POLLS).step_by(5) {
        rows.push(hc_in_if3.row(anchor.at(poll * POLL_SECONDS), 2.0e9 + 3.0e8 * poll as f64));
        rows.push(uptime.row(
            anchor.at(poll * POLL_SECONDS),
            8.64e6 + 6000.0 * poll as f64,
        ));
    }

    // 7. A 64-bit counter that wraps past 2^64 with a producer-supplied plausibility ceiling.
    //    Only CNPG can honour it (the warehouse has no `metadata` column). Own device, own
    //    ifIndex, so no other shape sees it.
    let wrap64 = Series {
        metadata: Some(r#"{"max_counter_rate_per_second":"1250000000"}"#.to_string()),
        ..snmp(DEVICE_C, "ifHCInOctets", Some(9), Some(64), "if9")
    };
    //    The interval across the wrap (polls 2 -> 3) runs at twice the rate of the others,
    //    so a dialect that drops it as a reset averages to a visibly different number than
    //    one that recovers it.
    for poll in 0..30_i64 {
        let steps = poll as f64 + if poll >= 3 { 1.0 } else { 0.0 };
        let value = (TWO_POW_64 - 2.0e10 + 7.5e9 * steps) % TWO_POW_64;
        rows.push(wrap64.row(anchor.at(poll * POLL_SECONDS), value));
    }

    // 8. Per-core CPU, two samples a minute so `agg:max` differs from `agg:avg`, with the core in
    //    the `tags` JSON. Two more series carry NO `core_id` (absent key, and NULL tags): the
    //    NULL dimension of a tag-split series.
    let cpu = |tags: Option<String>, key_suffix: &'static str| Series {
        gateway: GATEWAY_1,
        agent: AGENT_1,
        device: DEVICE_A,
        metric_type: "sysmon.cpu",
        metric_name: "cpu.usage_percent",
        if_index: None,
        counter_width: None,
        tags,
        metadata: None,
        key_suffix,
    };
    let cores = [
        (cpu(Some(r#"{"core_id":"0"}"#.into()), "core0"), 0),
        (cpu(Some(r#"{"core_id":"1"}"#.into()), "core1"), 1),
        (cpu(Some(r#"{"core_id":"2"}"#.into()), "core2"), 2),
        (cpu(Some(r#"{"core_id":"3"}"#.into()), "core3"), 3),
        (
            cpu(Some(r#"{"host":"host01.example.com"}"#.into()), "nocore"),
            4,
        ),
        (cpu(None, "notags"), 5),
    ];
    for sample in 0..720_i64 {
        for (series, core) in &cores {
            let value = 5.0 + ((sample * 7 + core * 13) % 90) as f64 + 0.5;
            rows.push(series.row(anchor.at(sample * 30 + 5), value));
        }
    }

    // 9. ICMP round-trip and loss with UNEVEN sampling: every minute in even hours, every ten
    //    minutes in odd hours. A multi-hour average weighted by sample count then differs from
    //    a mean of hourly means, which is the documented rollup deviation.
    for (device, gateway, agent) in [
        (DEVICE_A, GATEWAY_1, AGENT_1),
        (DEVICE_B, GATEWAY_2, AGENT_2),
    ] {
        for (metric_name, base, step) in [("icmp.rtt_ms", 10.0, 1.5), ("icmp.loss_pct", 0.0, 0.5)] {
            let series = Series {
                gateway,
                agent,
                device,
                metric_type: "icmp",
                metric_name,
                if_index: None,
                counter_width: None,
                tags: None,
                metadata: None,
                key_suffix: "probe",
            };
            for minute in 0..360_i64 {
                let even_hour = (minute / 60) % 2 == 0;
                if even_hour || minute % 10 == 0 {
                    let bump = if device == DEVICE_B { 3.0 } else { 0.0 };
                    let value =
                        base + bump + ((minute * 3) % 17) as f64 * step + (minute / 60) as f64;
                    rows.push(series.row(anchor.at(minute * 60 + 5), value));
                }
            }
        }
    }

    // 9b. rperf throughput and jitter, two probes, a sample every two minutes.
    for (device, gateway, agent) in [
        (DEVICE_A, GATEWAY_1, AGENT_1),
        (DEVICE_B, GATEWAY_2, AGENT_2),
    ] {
        for (metric_name, base) in [("rperf.bandwidth_bps", 9.4e8), ("rperf.jitter_ms", 0.8)] {
            let series = Series {
                gateway,
                agent,
                device,
                metric_type: "rperf",
                metric_name,
                if_index: None,
                counter_width: None,
                tags: None,
                metadata: None,
                key_suffix: "rperf",
            };
            for sample in 0..180_i64 {
                let wobble = ((sample * 11) % 23) as f64 / 23.0;
                let bump = if device == DEVICE_B { 0.5 } else { 1.0 };
                rows.push(series.row(
                    anchor.at(sample * 120 + 29),
                    base * bump * (1.0 + wobble / 10.0),
                ));
            }
        }
    }

    // 10. The edge window: a few rows, one EXACTLY on the window's upper bound.
    let edge = Series {
        gateway: GATEWAY_1,
        agent: AGENT_1,
        device: DEVICE_A,
        metric_type: "parity.edge",
        metric_name: "edge.value",
        if_index: None,
        counter_width: None,
        tags: None,
        metadata: None,
        key_suffix: "edge",
    };
    for (offset_minutes, value) in [(10, 1.0), (20, 2.0), (30, 3.0), (40, 4.0), (50, 5.0)] {
        rows.push(edge.row(anchor.at(7 * 3600 + offset_minutes * 60), value));
    }
    rows.push(edge.row(anchor.edge_instant(), 100.0));

    rows
}

const SOURCES: [&str; 8] = [
    "192.0.2.10",
    "192.0.2.11",
    "192.0.2.200",
    "198.51.100.7",
    "198.51.100.8",
    "2001:db8::10",
    "2001:db8:0:1::20",
    "2001:db8:ffff::1",
];
const DESTINATIONS: [&str; 5] = [
    "203.0.113.5",
    "203.0.113.6",
    "198.51.100.99",
    "2001:db8:1::5",
    "2001:db8:1::6",
];
const TCP_FLAGS: [Option<i32>; 7] = [
    Some(0),
    Some(2),
    Some(18),
    Some(24),
    Some(17),
    Some(255),
    None,
];
/// Flow durations in milliseconds, one either side of and one exactly on every
/// `duration_bucket` boundary (1s, 10s, 60s, 300s), plus "no start/end at all".
const DURATIONS_MS: [Option<i64>; 10] = [
    None,
    Some(200),
    Some(1_000),
    Some(5_000),
    Some(10_000),
    Some(30_000),
    Some(60_000),
    Some(120_000),
    Some(300_000),
    Some(600_000),
];
const SAMPLING: [Option<i64>; 4] = [None, Some(1), Some(100), Some(1000)];
const PORTS: [i32; 4] = [443, 53, 22, 8080];

fn flow(id: String, time: DateTime<Utc>, index: i64) -> FlowRow {
    let pick = |len: usize| (index as usize) % len;
    let udp = index % 5 == 0;
    let duration = DURATIONS_MS[pick(DURATIONS_MS.len())];
    let bytes_total = 1_000 + index * 37;
    let packets_total = 10 + index % 13;
    FlowRow {
        id,
        time,
        start_time: duration.map(|ms| time - Duration::milliseconds(ms)),
        end_time: duration.map(|_| time),
        src_endpoint_ip: SOURCES[pick(SOURCES.len())],
        dst_endpoint_ip: DESTINATIONS[pick(DESTINATIONS.len())],
        src_endpoint_port: 40_000 + index as i32,
        dst_endpoint_port: PORTS[pick(PORTS.len())],
        protocol_num: if udp { 17 } else { 6 },
        protocol_name: if udp { "UDP" } else { "TCP" },
        tcp_flags: if udp {
            None
        } else {
            TCP_FLAGS[pick(TCP_FLAGS.len())]
        },
        bytes_total: Some(bytes_total),
        packets_total: Some(packets_total),
        bytes_in: Some(bytes_total * 6 / 10),
        bytes_out: Some(bytes_total - bytes_total * 6 / 10),
        packets_in: Some(packets_total / 2),
        packets_out: Some(packets_total - packets_total / 2),
        sampling_rate: SAMPLING[pick(SAMPLING.len())],
        attributed: index % 7 == 3,
        dst_service_label: service_label(if udp { 17 } else { 6 }, PORTS[pick(PORTS.len())]),
    }
}

pub fn flows(anchor: Anchor) -> Vec<FlowRow> {
    let mut rows = Vec::new();

    // Main window: one flow every two minutes, a quarter second off the minute so a flow time
    // carries sub-second precision on both backends.
    for index in 0..180_i64 {
        let time = anchor.at(index * 120 + 7) + Duration::milliseconds(250);
        rows.push(flow(format!("parity-flow-{index:04}"), time, index));
    }

    // Edge window: five flows inside it and one EXACTLY on its upper bound.
    for (slot, offset_minutes) in [10_i64, 20, 30, 40, 50].into_iter().enumerate() {
        let index = 200 + slot as i64;
        let time = anchor.at(7 * 3600 + offset_minutes * 60);
        rows.push(flow(format!("parity-flow-{index:04}"), time, index));
    }
    rows.push(flow("parity-flow-0299".into(), anchor.edge_instant(), 299));

    // Halves window: NULL totals with directional halves, and two flows with no volume at all.
    for slot in 0..12_i64 {
        let index = 300 + slot;
        let mut row = flow(
            format!("parity-flow-{index:04}"),
            anchor.at(9 * 3600 + slot * 300 + 11),
            index,
        );
        row.bytes_total = None;
        row.packets_total = None;
        if slot >= 10 {
            row.bytes_in = None;
            row.bytes_out = None;
            row.packets_in = None;
            row.packets_out = None;
        }
        rows.push(row);
    }

    rows
}

/// TCP flag names in the order `ServiceRadar.EventWriter.FlowEnrichment.decode_tcp_flags/1`
/// writes `tcp_flags_labels` to CNPG: most significant bit first, `nil` -> `[]`.
pub fn tcp_flag_labels(flags: Option<i32>) -> Vec<&'static str> {
    const BITS: [(i32, &str); 8] = [
        (128, "CWR"),
        (64, "ECE"),
        (32, "URG"),
        (16, "ACK"),
        (8, "PSH"),
        (4, "RST"),
        (2, "SYN"),
        (1, "FIN"),
    ];
    match flags {
        Some(flags) if flags >= 0 => BITS
            .iter()
            .filter(|(bit, _)| flags & bit != 0)
            .map(|(_, name)| *name)
            .collect(),
        _ => Vec::new(),
    }
}

/// A deterministic, obviously synthetic UUID: `kind` names the dataset, `n` the row.
pub fn synthetic_uuid(kind: u16, n: u64) -> String {
    format!("00000000-0000-4000-8{kind:03x}-{n:012x}")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    Cnpg,
    StarRocks,
}

pub(crate) fn text(value: &str) -> String {
    // No fixture value contains a backslash, which the two backends escape differently.
    assert!(
        !value.contains('\\'),
        "fixture text must not contain a backslash: {value}"
    );
    format!("'{}'", value.replace('\'', "''"))
}

pub(crate) fn opt_text(value: Option<&str>) -> String {
    value.map(text).unwrap_or_else(|| "NULL".into())
}

pub(crate) fn opt_num<T: ToString>(value: Option<T>) -> String {
    value
        .map(|v| v.to_string())
        .unwrap_or_else(|| "NULL".into())
}

pub(crate) fn instant(value: DateTime<Utc>, backend: Backend) -> String {
    let rendered = value.format("%Y-%m-%d %H:%M:%S%.6f");
    match backend {
        Backend::Cnpg => format!("'{rendered}+00'"),
        Backend::StarRocks => format!("'{rendered}'"),
    }
}

pub(crate) fn opt_instant(value: Option<DateTime<Utc>>, backend: Backend) -> String {
    value
        .map(|v| instant(v, backend))
        .unwrap_or_else(|| "NULL".into())
}

pub(crate) const BATCH_ROWS: usize = 500;

/// `INSERT` statements loading `rows` into `<qualifier>.timeseries_metrics`.
pub fn metric_inserts(rows: &[MetricRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = match backend {
        Backend::Cnpg => {
            "\"timestamp\", gateway_id, agent_id, series_key, metric_name, metric_type, device_id, \
             value, if_index, counter_width, tags, metadata"
        }
        Backend::StarRocks => {
            "`timestamp`, gateway_id, agent_id, series_key, metric_name, metric_type, device_id, \
             value, if_index, counter_width, tags"
        }
    };
    rows.chunks(BATCH_ROWS)
        .map(|chunk| {
            let values: Vec<String> = chunk
                .iter()
                .map(|row| {
                    let mut fields = vec![
                        instant(row.timestamp, backend),
                        text(row.gateway_id),
                        text(row.agent_id),
                        text(&row.series_key),
                        text(row.metric_name),
                        text(row.metric_type),
                        text(row.device_id),
                        format!("{:?}", row.value),
                        opt_num(row.if_index),
                        opt_num(row.counter_width),
                    ];
                    match backend {
                        Backend::Cnpg => {
                            fields.push(json_literal(row.tags.as_deref()));
                            fields.push(json_literal(row.metadata.as_deref()));
                        }
                        Backend::StarRocks => fields.push(opt_text(row.tags.as_deref())),
                    }
                    format!("({})", fields.join(", "))
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.timeseries_metrics ({columns}) VALUES\n{}",
                values.join(",\n")
            )
        })
        .collect()
}

pub(crate) fn json_literal(value: Option<&str>) -> String {
    value
        .map(|json| format!("{}::jsonb", text(json)))
        .unwrap_or_else(|| "NULL".into())
}

/// `INSERT` statements loading `rows` into `<qualifier>.ocsf_network_activity`.
pub fn flow_inserts(rows: &[FlowRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let shared = "start_time, end_time, src_endpoint_ip, dst_endpoint_ip, src_endpoint_port, \
                  dst_endpoint_port, protocol_num, protocol_name, tcp_flags, bytes_total, \
                  packets_total, bytes_in, bytes_out, packets_in, packets_out, dst_service_label, \
                  sampling_rate";
    let columns = match backend {
        // `ocsf_payload` is NOT NULL on CNPG; `tcp_flags_labels` is what its label query reads.
        Backend::Cnpg => format!("\"time\", {shared}, tcp_flags_labels, ocsf_payload"),
        Backend::StarRocks => format!("`time`, {shared}, id, device_uid, event_type"),
    };
    rows.chunks(BATCH_ROWS)
        .map(|chunk| {
            let values: Vec<String> = chunk
                .iter()
                .map(|row| {
                    let mut fields = vec![
                        instant(row.time, backend),
                        opt_instant(row.start_time, backend),
                        opt_instant(row.end_time, backend),
                        text(row.src_endpoint_ip),
                        text(row.dst_endpoint_ip),
                        row.src_endpoint_port.to_string(),
                        row.dst_endpoint_port.to_string(),
                        row.protocol_num.to_string(),
                        text(row.protocol_name),
                        opt_num(row.tcp_flags),
                        opt_num(row.bytes_total),
                        opt_num(row.packets_total),
                        opt_num(row.bytes_in),
                        opt_num(row.bytes_out),
                        opt_num(row.packets_in),
                        opt_num(row.packets_out),
                        opt_text(row.dst_service_label),
                    ];
                    match backend {
                        Backend::Cnpg => {
                            fields.push(
                                row.sampling_rate
                                    .map(|rate| rate.to_string())
                                    .unwrap_or_else(|| "DEFAULT".into()),
                            );
                            let labels: Vec<String> = tcp_flag_labels(row.tcp_flags)
                                .into_iter()
                                .map(text)
                                .collect();
                            fields.push(format!("ARRAY[{}]::text[]", labels.join(", ")));
                            fields.push(if row.attributed {
                                r#"'{"event_type":"attributed_flow"}'::jsonb"#.into()
                            } else {
                                "'{}'::jsonb".into()
                            });
                        }
                        Backend::StarRocks => {
                            fields.push(opt_num(row.sampling_rate));
                            fields.push(text(&row.id));
                            fields.push(text(DEVICE_A));
                            fields.push(if row.attributed {
                                text("attributed_flow")
                            } else {
                                "NULL".into()
                            });
                        }
                    }
                    format!("({})", fields.join(", "))
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.ocsf_network_activity ({columns}) VALUES\n{}",
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

    #[test]
    fn the_anchor_is_a_whole_day_and_the_generator_is_deterministic() {
        assert_eq!(anchor().0.to_rfc3339(), "2030-03-02T00:00:00+00:00");
        assert_eq!(metrics(anchor()), metrics(anchor()));
        assert_eq!(flows(anchor()), flows(anchor()));
    }

    #[test]
    fn primary_keys_are_unique_on_both_backends() {
        let keys: BTreeSet<_> = metrics(anchor())
            .into_iter()
            .map(|row| (row.timestamp, row.gateway_id, row.series_key))
            .collect();
        assert_eq!(keys.len(), metrics(anchor()).len());
        let ids: BTreeSet<_> = flows(anchor()).into_iter().map(|row| row.id).collect();
        assert_eq!(ids.len(), flows(anchor()).len());
    }

    /// The adversarial cases the spec names, asserted on the ROWS so that an edit to the
    /// generator cannot quietly drop one and leave the comparison proving less than it claims.
    #[test]
    fn the_counter_fixture_contains_every_adversarial_case() {
        let rows = metrics(anchor());
        let series = |device: &str, name: &str, if_index: i32| -> Vec<&MetricRow> {
            rows.iter()
                .filter(|row| {
                    row.device_id == device
                        && row.metric_name == name
                        && row.if_index == Some(if_index)
                })
                .collect()
        };

        let hc = series(DEVICE_A, "ifHCInOctets", 7);
        assert!(
            hc[0].value >= 1.0e11,
            "64-bit counter in the hundreds of GB"
        );
        let gaps: BTreeSet<i64> = hc
            .windows(2)
            .map(|pair| (pair[1].timestamp - pair[0].timestamp).num_seconds())
            .collect();
        assert_eq!(gaps, BTreeSet::from([60, 120]), "exactly one missed poll");
        let resets = hc
            .windows(2)
            .filter(|pair| pair[1].value < pair[0].value)
            .count();
        assert_eq!(resets, 1, "one counter reset");
        assert!(
            hc.windows(2)
                .filter(|pair| pair[1].value < pair[0].value)
                .all(|pair| pair[0].value > TWO_POW_32),
            "the reset must not be readable as a 32-bit wrap"
        );

        let wraps32 = series(DEVICE_A, "ifInOctets", 7)
            .windows(2)
            .filter(|pair| pair[1].value < pair[0].value)
            .count();
        assert!(wraps32 >= 2, "32-bit counter wraps between polls");

        let gateways: BTreeSet<&str> = rows
            .iter()
            .filter(|row| row.metric_name == "ifHCInOctets" && row.if_index == Some(7))
            .map(|row| row.gateway_id)
            .collect();
        assert_eq!(gateways.len(), 2, "one display series from two gateways");

        assert!(
            rows.iter()
                .any(|row| row.tags.as_deref() == Some(r#"{"core_id":"3"}"#))
        );
        let null_dimension = rows
            .iter()
            .filter(|row| row.metric_type == "sysmon.cpu")
            .filter(|row| !row.tags.as_deref().unwrap_or("").contains("core_id"))
            .count();
        assert!(null_dimension > 0, "a NULL tag dimension");
        assert!(
            rows.iter()
                .any(|row| row.metric_type == "snmp" && row.if_index.is_none()),
            "a NULL column dimension"
        );

        let buckets: BTreeSet<i64> = hc
            .iter()
            .map(|row| row.timestamp.timestamp() / 300)
            .collect();
        assert!(
            buckets.len() > 20,
            "more 5m buckets than the inventory's limit:20"
        );
        assert!(
            rows.iter()
                .any(|row| row.timestamp == anchor().edge_instant())
        );
    }

    #[test]
    fn the_flow_fixture_contains_every_adversarial_case() {
        let rows = flows(anchor());
        assert!(rows.iter().any(|row| row.sampling_rate.is_none()));
        assert!(rows.iter().any(|row| row.sampling_rate == Some(1000)));
        assert!(
            rows.iter()
                .any(|row| row.bytes_total.is_none() && row.bytes_in.is_some())
        );
        assert!(
            rows.iter()
                .any(|row| row.bytes_total.is_none() && row.bytes_in.is_none())
        );
        assert!(rows.iter().any(|row| row.src_endpoint_ip.contains(':')));
        assert!(
            rows.iter()
                .any(|row| row.src_endpoint_ip.starts_with("192.0.2."))
        );
        for flags in [None, Some(0), Some(18)] {
            assert!(
                rows.iter()
                    .any(|row| row.protocol_num == 6 && row.tcp_flags == flags)
            );
        }
        let durations: BTreeSet<Option<i64>> = rows
            .iter()
            .map(|row| {
                row.start_time
                    .zip(row.end_time)
                    .map(|(start, end)| (end - start).num_milliseconds())
            })
            .collect();
        assert_eq!(durations, BTreeSet::from(DURATIONS_MS));
        assert!(rows.iter().any(|row| row.time == anchor().edge_instant()));
    }

    #[test]
    fn tcp_flag_labels_follow_the_writer() {
        assert_eq!(tcp_flag_labels(Some(18)), vec!["ACK", "SYN"]);
        assert!(tcp_flag_labels(Some(0)).is_empty());
        assert!(tcp_flag_labels(None).is_empty());
    }

    #[test]
    fn a_missing_sampling_rate_is_the_column_default_on_cnpg_and_null_on_starrocks() {
        let rows = flows(anchor());
        let unsampled: Vec<FlowRow> = rows
            .into_iter()
            .filter(|r| r.sampling_rate.is_none())
            .take(1)
            .collect();
        assert!(
            flow_inserts(&unsampled, Backend::Cnpg, "platform")[0].contains(", DEFAULT, ARRAY[")
        );
        assert!(
            flow_inserts(&unsampled, Backend::StarRocks, "db")[0].contains(", NULL, 'parity-flow-")
        );
    }
}
