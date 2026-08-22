//! CPU budget for the passive device census decode path.
//!
//! The census must stay cheap enough that operators never notice it. On a live
//! /24 the eBPF side holds the ring to ~0.36 observations/sec at 0.0416% CPU,
//! so userspace decoding is nowhere near the bottleneck in practice. This bench
//! exists to keep it that way: it drives the decode path far harder than any
//! real segment would and asserts a CPU ceiling, so a future change that makes
//! per-record decoding expensive fails here rather than on a customer's host.
//!
//! Run:
//!   cargo bench --bench census_decode_cpu
//!   SERVICERADAR_NETPROBE_BENCH_ASSERT=1 cargo bench --bench census_decode_cpu

use std::{
    env,
    net::IpAddr,
    time::{Duration, Instant},
};

use anyhow::Result;
use serviceradar_netprobe::census::{
    L2_FLAG_LOCALLY_ADMINISTERED, L2_KIND_ARP_REPLY, L2_KIND_ARP_REQUEST, L2_KIND_IPV6_NDP,
    L2_OBSERVATION_RECORD_LEN, L2_OBSERVATION_VERSION, SegmentScope, parse_l2_ring_record,
};

/// Records decoded per run. Four orders of magnitude above what a real segment
/// produces in the same wall time.
const DEFAULT_RECORDS: usize = 2_000_000;
/// Per-record decode ceiling.
///
/// This, not "share of a core", is the meaningful budget. A decode loop is
/// single-threaded and saturating, so its CPU share is ~1.0 by construction no
/// matter how fast it is -- asserting on that would pass or fail for reasons
/// unrelated to the code. Cost per record is what composes into a real rate.
///
/// Measured at ~10 ns/record; 200 ns leaves 20x headroom for a slower machine
/// while still failing a change that makes decoding an order of magnitude
/// dearer.
const DEFAULT_MAX_NS_PER_RECORD: f64 = 200.0;
/// Floor on decode throughput, as a second guard on the same property.
const DEFAULT_MIN_RECORDS_PER_SEC: f64 = 1_000_000.0;
/// The rate above which CensusWatchdog shuts the census down. Used to express
/// the decode cost as the share of a core it would consume at the worst rate
/// the census is ever allowed to reach.
const WATCHDOG_CEILING_PER_SEC: f64 = 200.0;

fn main() -> Result<()> {
    let args = BenchArgs::parse();
    let workload = Workload::new(args.records);
    let scope = SegmentScope::new(vec![("192.168.1.0".parse::<IpAddr>()?, 24)]);

    let cpu_start = process_cpu_time();
    let wall_start = Instant::now();

    let mut decoded = 0u64;
    let mut anchorable = 0u64;
    let mut randomized = 0u64;
    let mut off_segment = 0u64;

    for record in workload.records.iter() {
        let Some(observation) = parse_l2_ring_record(record) else {
            continue;
        };
        decoded += 1;
        if observation.randomized_mac {
            randomized += 1;
        }
        if observation.is_off_segment(&scope) {
            off_segment += 1;
        }
        if observation.can_anchor_identity(&scope) {
            anchorable += 1;
        }
    }

    let wall = wall_start.elapsed();
    let cpu = process_cpu_time().saturating_sub(cpu_start);
    let records_per_sec = decoded as f64 / wall.as_secs_f64().max(f64::EPSILON);
    let ns_per_record = wall.as_nanos() as f64 / decoded.max(1) as f64;
    // What the decode path would cost at the highest rate the census can reach
    // before the watchdog kills it. This is the number an operator cares about.
    let core_share_at_ceiling = ns_per_record * WATCHDOG_CEILING_PER_SEC / 1_000_000_000.0;

    println!("census decode bench");
    println!("  records            {decoded}");
    println!("  wall               {:.3}s", wall.as_secs_f64());
    println!(
        "  cpu                {:.3}s  (saturating loop; see ns/record)",
        cpu.as_secs_f64()
    );
    println!("  records/sec        {records_per_sec:.0}");
    println!("  ns/record          {ns_per_record:.1}");
    println!(
        "  core share @ {WATCHDOG_CEILING_PER_SEC:.0}/s  {core_share_at_ceiling:.9}  \
         (the watchdog ceiling; real segments measured 0.36/s)"
    );
    println!("  anchorable         {anchorable}");
    println!("  randomized         {randomized}");
    println!("  off-segment        {off_segment}");

    // Sanity: the workload must actually exercise every classification branch,
    // otherwise the bench could pass by decoding nothing interesting.
    if decoded == 0 || anchorable == 0 || randomized == 0 || off_segment == 0 {
        anyhow::bail!(
            "workload did not exercise all branches: decoded={decoded} anchorable={anchorable} \
             randomized={randomized} off_segment={off_segment}"
        );
    }

    if args.assert && ns_per_record > args.max_ns_per_record {
        anyhow::bail!(
            "census decode cost {ns_per_record:.1} ns/record, above the {:.1} ns budget",
            args.max_ns_per_record
        );
    }
    if args.assert && records_per_sec < args.min_records_per_sec {
        anyhow::bail!(
            "census decode managed {records_per_sec:.0} records/sec, below the {:.0} floor",
            args.min_records_per_sec
        );
    }

    Ok(())
}

struct BenchArgs {
    records: usize,
    max_ns_per_record: f64,
    min_records_per_sec: f64,
    assert: bool,
}

impl BenchArgs {
    fn parse() -> Self {
        Self {
            records: env_usize("SERVICERADAR_NETPROBE_BENCH_RECORDS", DEFAULT_RECORDS),
            max_ns_per_record: env_f64(
                "SERVICERADAR_NETPROBE_BENCH_MAX_NS",
                DEFAULT_MAX_NS_PER_RECORD,
            ),
            min_records_per_sec: env_f64(
                "SERVICERADAR_NETPROBE_BENCH_MIN_RPS",
                DEFAULT_MIN_RECORDS_PER_SEC,
            ),
            assert: env::var_os("SERVICERADAR_NETPROBE_BENCH_ASSERT").is_some(),
        }
    }
}

fn env_usize(key: &str, default: usize) -> usize {
    env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_f64(key: &str, default: f64) -> f64 {
    env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// A mix that mirrors what a live segment produced: mostly NDP and ARP
/// requests, with a realistic share of randomized MACs and off-segment
/// (router-forwarded) addresses.
struct Workload {
    records: Vec<[u8; L2_OBSERVATION_RECORD_LEN]>,
}

impl Workload {
    fn new(count: usize) -> Self {
        let mut records = Vec::with_capacity(count);
        for i in 0..count {
            let n = (i % 100) as u8;
            // ~13% randomized, matching the live measurement.
            let randomized = i % 100 < 13;
            // ~15% off-segment.
            let off_segment = i % 100 >= 85;
            let first_octet = if randomized { 0x1a } else { 0xbc };
            let mac = [first_octet, 0x24, 0x11, n, (i >> 8) as u8, (i >> 16) as u8];

            // Live mix: 124 NDP / 85 ARP request / 8 ARP reply.
            let kind = match i % 217 {
                0..=123 => L2_KIND_IPV6_NDP,
                124..=208 => L2_KIND_ARP_REQUEST,
                _ => L2_KIND_ARP_REPLY,
            };

            let (ip_version, addr) = if kind == L2_KIND_IPV6_NDP {
                let mut a = [0u8; 16];
                // fe80::/10 link-local, which is what NDP actually carries.
                a[0] = 0xfe;
                a[1] = 0x80;
                a[13] = n;
                a[14] = (i >> 8) as u8;
                a[15] = (i >> 16) as u8;
                (6u16, a)
            } else {
                let mut a = [0u8; 16];
                a[0] = 192;
                a[1] = 168;
                a[2] = if off_segment { 2 } else { 1 };
                a[3] = n.max(1);
                (4u16, a)
            };

            let mut flags = 0u16;
            if randomized {
                flags |= L2_FLAG_LOCALLY_ADMINISTERED;
            }

            let mut b = [0u8; L2_OBSERVATION_RECORD_LEN];
            b[0..2].copy_from_slice(&L2_OBSERVATION_VERSION.to_ne_bytes());
            b[2..4].copy_from_slice(&kind.to_ne_bytes());
            b[4..6].copy_from_slice(&ip_version.to_ne_bytes());
            b[6..8].copy_from_slice(&flags.to_ne_bytes());
            b[8..12].copy_from_slice(&2u32.to_ne_bytes());
            b[16..24].copy_from_slice(&(i as u64).to_ne_bytes());
            b[24..30].copy_from_slice(&mac);
            b[32..48].copy_from_slice(&addr);
            records.push(b);
        }
        Self { records }
    }
}

#[cfg(target_os = "linux")]
fn process_cpu_time() -> Duration {
    let mut usage = unsafe { std::mem::zeroed::<libc::rusage>() };
    // SAFETY: getrusage fills the caller-provided struct; RUSAGE_SELF is valid.
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) } != 0 {
        return Duration::ZERO;
    }
    timeval_to_duration(usage.ru_utime) + timeval_to_duration(usage.ru_stime)
}

#[cfg(not(target_os = "linux"))]
fn process_cpu_time() -> Duration {
    let mut usage = unsafe { std::mem::zeroed::<libc::rusage>() };
    // SAFETY: as above; getrusage is POSIX and available on macOS too, which
    // matters because a bench nobody can run off Linux is a bench nobody runs.
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) } != 0 {
        return Duration::ZERO;
    }
    timeval_to_duration(usage.ru_utime) + timeval_to_duration(usage.ru_stime)
}

fn timeval_to_duration(tv: libc::timeval) -> Duration {
    Duration::new(tv.tv_sec.max(0) as u64, (tv.tv_usec.max(0) as u32) * 1_000)
}
