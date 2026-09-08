use std::{
    env,
    time::{Duration, Instant},
};

use anyhow::{Context, Result};
use serviceradar_netprobe::{
    af_xdp::AfXdpPacket,
    af_xdp_classifier::{AfXdpClassifier, FlowTableKey, FlowTableWriter},
};

const DEFAULT_TOTAL_PPS: u64 = 50_000;
const DEFAULT_TARGET_MBPS: f64 = 500.0;
const DEFAULT_DURATION_SECS: u64 = 1;
const DEFAULT_BYPASS_RATIO: f64 = 0.96;
const DEFAULT_MIN_HIT_RATIO: f64 = 0.95;
const DEFAULT_CPU_LIMIT: f64 = 0.03;
const TARGET_PACKET_BYTES: usize = 1_250;

fn main() -> Result<()> {
    let args = BenchArgs::parse()?;
    let total_packets = args.total_pps.saturating_mul(args.duration.as_secs());
    let redirected_packets = ((total_packets as f64) * (1.0 - args.bypass_ratio)).ceil() as u64;
    let packets = Workload::new(redirected_packets.max(1) as usize);
    let mut classifier = AfXdpClassifier::new(CountingFlowTable::default());

    let cpu_start = process_cpu_time();
    let wall_start = Instant::now();
    let mut events = 0u64;

    for packet in packets.iter() {
        let classified = classifier.classify_packet(packet, 123_456)?;
        events += classified.len() as u64;
    }

    let elapsed = wall_start.elapsed();
    let cpu = process_cpu_time().saturating_sub(cpu_start);
    let cpu_share = cpu.as_secs_f64() / args.duration.as_secs_f64();
    let processed_pps = redirected_packets as f64 / elapsed.as_secs_f64().max(f64::EPSILON);
    let modeled_mbps = args.total_pps as f64 * TARGET_PACKET_BYTES as f64 * 8.0 / 1_000_000.0;
    let hit_ratio = if total_packets == 0 {
        1.0
    } else {
        (total_packets.saturating_sub(redirected_packets)) as f64 / total_packets as f64
    };

    println!(
        "netprobe_af_xdp_cpu total_pps={} target_mbps={:.1} duration_s={:.3} bypass_ratio={:.4} redirected_packets={} dpi_events={} classifier_pps={:.0} cpu_s={:.6} cpu_share_one_core={:.4} flow_table_hit_ratio={:.4}",
        args.total_pps,
        modeled_mbps,
        args.duration.as_secs_f64(),
        args.bypass_ratio,
        redirected_packets,
        events,
        processed_pps,
        cpu.as_secs_f64(),
        cpu_share,
        hit_ratio,
    );

    if args.assert && modeled_mbps < args.target_mbps {
        anyhow::bail!(
            "modeled workload {:.1} Mbps is below requested {:.1} Mbps",
            modeled_mbps,
            args.target_mbps
        );
    }
    if args.assert && cpu_share > args.cpu_limit {
        anyhow::bail!(
            "CPU share {:.4} exceeded limit {:.4}",
            cpu_share,
            args.cpu_limit
        );
    }
    if args.assert && hit_ratio <= args.min_hit_ratio {
        anyhow::bail!(
            "flow_table hit ratio {:.4} did not exceed minimum {:.4}",
            hit_ratio,
            args.min_hit_ratio
        );
    }

    Ok(())
}

#[derive(Clone, Debug)]
struct BenchArgs {
    total_pps: u64,
    target_mbps: f64,
    duration: Duration,
    bypass_ratio: f64,
    min_hit_ratio: f64,
    cpu_limit: f64,
    assert: bool,
}

impl BenchArgs {
    fn parse() -> Result<Self> {
        let mut args = Self {
            total_pps: DEFAULT_TOTAL_PPS,
            target_mbps: DEFAULT_TARGET_MBPS,
            duration: Duration::from_secs(DEFAULT_DURATION_SECS),
            bypass_ratio: DEFAULT_BYPASS_RATIO,
            min_hit_ratio: DEFAULT_MIN_HIT_RATIO,
            cpu_limit: DEFAULT_CPU_LIMIT,
            assert: env::var_os("SERVICERADAR_NETPROBE_BENCH_ASSERT").is_some(),
        };
        let mut iter = env::args().skip(1);
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--bench" => {}
                "--assert" => args.assert = true,
                "--pps" => args.total_pps = parse_next(&mut iter, "--pps")?,
                "--mbps" => args.target_mbps = parse_next(&mut iter, "--mbps")?,
                "--duration-secs" => {
                    let value: f64 = parse_next(&mut iter, "--duration-secs")?;
                    args.duration = Duration::from_secs_f64(value);
                }
                "--bypass-ratio" => args.bypass_ratio = parse_next(&mut iter, "--bypass-ratio")?,
                "--min-hit-ratio" => args.min_hit_ratio = parse_next(&mut iter, "--min-hit-ratio")?,
                "--cpu-limit" => args.cpu_limit = parse_next(&mut iter, "--cpu-limit")?,
                "--help" | "-h" => {
                    print_help();
                    std::process::exit(0);
                }
                _ => anyhow::bail!("unknown argument {arg}"),
            }
        }
        if !(0.0..=1.0).contains(&args.bypass_ratio) {
            anyhow::bail!("--bypass-ratio must be between 0.0 and 1.0");
        }
        if !(0.0..=1.0).contains(&args.min_hit_ratio) {
            anyhow::bail!("--min-hit-ratio must be between 0.0 and 1.0");
        }
        if args.total_pps == 0 {
            anyhow::bail!("--pps must be greater than zero");
        }
        if args.duration.is_zero() {
            anyhow::bail!("--duration-secs must be greater than zero");
        }

        Ok(args)
    }
}

fn parse_next<T>(iter: &mut impl Iterator<Item = String>, name: &str) -> Result<T>
where
    T: std::str::FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    iter.next()
        .with_context(|| format!("{name} requires a value"))?
        .parse()
        .with_context(|| format!("invalid {name} value"))
}

fn print_help() {
    println!(
        "Usage: cargo bench -p serviceradar-netprobe --bench af_xdp_cpu -- [--assert] [--pps N] [--mbps N] [--duration-secs N] [--bypass-ratio N] [--min-hit-ratio N] [--cpu-limit N]"
    );
}

#[derive(Default)]
struct CountingFlowTable {
    updates: u64,
}

impl FlowTableWriter for CountingFlowTable {
    fn update_classification(
        &mut self,
        _key: FlowTableKey,
        _classified_as: u32,
        _observed_at_unix_nano: i64,
    ) -> Result<()> {
        self.updates += 1;
        Ok(())
    }
}

struct Workload {
    packets: Vec<AfXdpPacket>,
}

impl Workload {
    fn new(count: usize) -> Self {
        let templates = [
            packet_template(
                49_152,
                80,
                b"GET / HTTP/1.1\r\nHost: redacted.invalid\r\n\r\n",
            ),
            packet_template(49_153, 443, &tls_client_hello()),
            udp_packet_template(49_154, 53, &dns_query()),
        ];
        let packets = (0..count)
            .map(|index| AfXdpPacket {
                interface: "eth0".to_string(),
                ifindex: 2,
                queue_id: 0,
                data: templates[index % templates.len()].clone(),
            })
            .collect();

        Self { packets }
    }

    fn iter(&self) -> impl Iterator<Item = &AfXdpPacket> {
        self.packets.iter()
    }
}

fn packet_template(source_port: u16, destination_port: u16, payload: &[u8]) -> Vec<u8> {
    ipv4_packet(6, source_port, destination_port, payload)
}

fn udp_packet_template(source_port: u16, destination_port: u16, payload: &[u8]) -> Vec<u8> {
    ipv4_packet(17, source_port, destination_port, payload)
}

fn ipv4_packet(protocol: u8, source_port: u16, destination_port: u16, payload: &[u8]) -> Vec<u8> {
    let transport_len = match protocol {
        6 => 20,
        17 => 8,
        _ => 0,
    };
    let mut packet = vec![0u8; 20 + transport_len];
    packet[0] = 0x45;
    packet[8] = 64;
    packet[9] = protocol;
    packet[12..16].copy_from_slice(&[192, 0, 2, 10]);
    packet[16..20].copy_from_slice(&[198, 51, 100, 20]);
    packet[20..22].copy_from_slice(&source_port.to_be_bytes());
    packet[22..24].copy_from_slice(&destination_port.to_be_bytes());
    if protocol == 6 {
        packet[32] = 0x50;
    } else if protocol == 17 {
        let udp_len = (8 + payload.len()).min(u16::MAX as usize) as u16;
        packet[24..26].copy_from_slice(&udp_len.to_be_bytes());
    }
    packet.extend_from_slice(payload);
    packet.resize(TARGET_PACKET_BYTES, 0);
    let total_len = packet.len().min(u16::MAX as usize) as u16;
    packet[2..4].copy_from_slice(&total_len.to_be_bytes());
    packet
}

fn tls_client_hello() -> Vec<u8> {
    let mut payload = vec![
        0x16, 0x03, 0x01, 0x00, 0x34, 0x01, 0x00, 0x00, 0x30, 0x03, 0x03,
    ];
    payload.extend_from_slice(&[0u8; 32]);
    payload.extend_from_slice(&[
        0x00, 0x00, 0x02, 0x13, 0x01, 0x01, 0x00, 0x00, 0x05, 0x00, 0x0d, 0x00, 0x00,
    ]);
    payload
}

fn dns_query() -> Vec<u8> {
    vec![
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, b'e', b'x',
        b'a', b'm', b'p', b'l', b'e', 0x03, b'c', b'o', b'm', 0x00, 0x00, 0x01, 0x00, 0x01,
    ]
}

#[cfg(unix)]
fn process_cpu_time() -> Duration {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    let rc = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) };
    if rc != 0 {
        return Duration::ZERO;
    }
    let usage = unsafe { usage.assume_init() };
    timeval_duration(usage.ru_utime) + timeval_duration(usage.ru_stime)
}

#[cfg(unix)]
fn timeval_duration(value: libc::timeval) -> Duration {
    let secs = value.tv_sec.max(0) as u64;
    let micros = value.tv_usec.max(0) as u32;
    Duration::new(secs, micros.saturating_mul(1_000))
}

#[cfg(not(unix))]
fn process_cpu_time() -> Duration {
    Duration::ZERO
}
