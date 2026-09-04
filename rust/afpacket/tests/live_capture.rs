//! Live capture against a real interface. Requires root, so it is `#[ignore]`.
//!
//! Deliberately `#[ignore]` rather than self-skipping. A test that detects it
//! lacks CAP_NET_RAW and returns `Ok(())` is a test that cannot fail: it passes
//! on RBE, passes on macOS, and never once opens a socket. An ignored test is
//! visibly not run.
//!
//! Run it where it can actually work:
//!
//! ```text
//! sudo -E cargo test -p serviceradar-afpacket --test live_capture -- --ignored --nocapture
//! ```

#![cfg(target_os = "linux")]

use std::{
    process::Command,
    time::{Duration, Instant},
};

use serviceradar_afpacket::{Direction, RingConfig, Socket};

/// `tcpdump -dd icmp` with a 262144 snaplen, as verified on Linux 6.8.
const ICMP_FILTER: &[(u16, u8, u8, u32)] = &[
    (0x28, 0, 0, 12),
    (0x15, 0, 3, 0x0800),
    (0x30, 0, 0, 23),
    (0x15, 0, 1, 1),
    (0x06, 0, 0, 262_144),
    (0x06, 0, 0, 0),
];

/// `ret #0` — matches nothing. The negative control.
const DROP_ALL: &[(u16, u8, u8, u32)] = &[(0x06, 0, 0, 0)];

fn capture_for(
    filter: &[(u16, u8, u8, u32)],
    generate: impl FnOnce(),
) -> (usize, u32, Vec<u32>, u64) {
    let socket = Socket::open("lo").expect("open lo (needs CAP_NET_RAW)");
    let expected_ifindex = socket.ifindex();
    let mut ring = socket
        .activate(RingConfig::default(), filter)
        .expect("activate the ring");

    generate();

    // Drain for longer than tp_retire_blk_tov, or the kernel is still holding
    // the last partially filled block and the capture ends early.
    let deadline = Instant::now() + Duration::from_millis(1200);
    let mut frames = 0usize;
    let mut ifindexes = Vec::new();
    let mut outbound = 0usize;
    while Instant::now() < deadline {
        match ring.drain_block(|frame| {
            frames += 1;
            ifindexes.push(frame.ifindex);
            if frame.direction == Direction::Outbound {
                outbound += 1;
            }
            assert!(
                frame.original_len >= frame.data.len() as u32,
                "original_len must not be below captured length"
            );
            assert!(
                frame.timestamp_ns > 1_600_000_000_000_000_000,
                "timestamp must be wall-clock nanoseconds, got {}",
                frame.timestamp_ns
            );
        }) {
            Some(_) => {}
            None => std::thread::sleep(Duration::from_millis(20)),
        }
    }

    let stats = ring.refresh_stats().expect("read statistics");
    println!("frames={frames} outbound={outbound} stats={stats:?}");
    (frames, expected_ifindex, ifindexes, stats.captured)
}

fn ping() {
    let _ = Command::new("ping")
        .args(["-c", "4", "-i", "0.1", "-W", "1", "127.0.0.1"])
        .output();
}

#[test]
#[ignore = "requires root for CAP_NET_RAW"]
fn captures_matching_traffic_and_only_from_the_bound_interface() {
    let (frames, expected_ifindex, ifindexes, captured) = capture_for(ICMP_FILTER, ping);

    assert!(frames > 0, "the icmp filter captured nothing");
    // Loopback delivers each frame twice, once PACKET_HOST and once
    // PACKET_OUTGOING, so 4 echoes plus 4 replies is 16.
    assert!(frames >= 8, "expected at least 8 frames, got {frames}");

    // Compared against the SOCKET's ifindex, not the first frame's: comparing
    // frames to each other would pass if every frame came from the wrong
    // interface, which is the authorization bypass this guards.
    assert!(
        ifindexes.iter().all(|i| *i == expected_ifindex),
        "frames leaked in from another interface: expected {expected_ifindex}, saw {ifindexes:?}"
    );

    // Cross-check the two independent counts. The ring's own frame count and
    // the kernel's (tp_packets - tp_drops) disagreeing is itself a bug.
    assert_eq!(
        captured, frames as u64,
        "statistics disagree with the frames actually delivered"
    );
}

#[test]
#[ignore = "requires root for CAP_NET_RAW"]
fn a_reject_all_filter_captures_nothing() {
    // The negative control. Without it, a ring that captured everything
    // regardless of the filter would pass the test above.
    let (frames, _, _, _) = capture_for(DROP_ALL, ping);
    assert_eq!(frames, 0, "a `ret #0` filter must capture nothing");
}

/// Task 1.12: a ring that is deliberately too small must REPORT its losses.
///
/// The failure this guards is not dropping packets — a small ring under load
/// will always drop. It is dropping them *silently*: `PACKET_STATISTICS`
/// resets on read, so a second reader anywhere takes the drops out of the
/// session's total and the capture presents as complete. `Stats::is_complete`
/// is the assertion that matters; a non-zero `dropped` is what makes it
/// meaningful.
#[test]
#[ignore = "requires root for CAP_NET_RAW"]
fn a_starved_ring_reports_its_drops_rather_than_hiding_them() {
    let socket = Socket::open("lo").expect("open lo (needs CAP_NET_RAW)");
    // Smallest geometry the kernel accepts: one page-sized block. Two frames
    // of headroom against a flood guarantees overrun.
    let config = RingConfig {
        block_size: 4096,
        block_count: 1,
        frame_size: 2048,
        retire_timeout_ms: 10,
    };
    let mut ring = socket
        .activate(config, ACCEPT_ALL)
        .map_err(|e| e.error)
        .expect("activate a deliberately tiny ring");

    // Flood without draining, so the ring cannot be recycled.
    flood(20_000);
    std::thread::sleep(Duration::from_millis(300));

    let stats = ring.refresh_stats().expect("read statistics");
    println!("starved ring: {stats:?}");

    assert!(
        stats.dropped > 0,
        "a 4 KiB ring under a 20k-packet flood must report drops, got {stats:?}"
    );
    assert!(
        !stats.is_complete(),
        "a session that dropped packets must not present as complete"
    );
}

/// Task 1.13: sustained capture cost, recorded rather than asserted.
///
/// Deliberately prints instead of asserting a threshold. A pps or CPU bound
/// hard-coded here would be a number measured on one machine at one load,
/// and this repository already has a p99 assertion that fails at load average
/// 130 for reasons unrelated to the code under test.
#[test]
#[ignore = "requires root for CAP_NET_RAW"]
fn measure_sustained_capture_cost() {
    let socket = Socket::open("lo").expect("open lo (needs CAP_NET_RAW)");
    let mut ring = socket
        .activate(RingConfig::default(), ACCEPT_ALL)
        .map_err(|e| e.error)
        .expect("activate the ring");

    let cpu_before = cpu_time();
    let started = Instant::now();

    let flooder = std::thread::spawn(|| flood(200_000));
    let mut frames = 0usize;
    let mut bytes = 0usize;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if ring
            .drain_block(|f| {
                frames += 1;
                bytes += f.data.len();
            })
            .is_none()
        {
            std::thread::sleep(Duration::from_micros(200));
        }
    }
    let _ = flooder.join();

    let elapsed = started.elapsed().as_secs_f64();
    let cpu = cpu_time() - cpu_before;
    let stats = ring.refresh_stats().expect("read statistics");

    println!(
        "MEASUREMENT frames={frames} bytes={bytes} elapsed={elapsed:.2}s \
         pps={:.0} MiB/s={:.1} cpu={cpu:.2}s cpu_per_Mpkt={:.1}s {stats:?}",
        frames as f64 / elapsed,
        bytes as f64 / elapsed / (1024.0 * 1024.0),
        if frames > 0 {
            cpu / (frames as f64 / 1_000_000.0)
        } else {
            0.0
        }
    );
    assert!(frames > 0, "the measurement captured nothing");
}

/// `ret #262144` — accept every packet, full snaplen.
const ACCEPT_ALL: &[(u16, u8, u8, u32)] = &[(0x06, 0, 0, 262_144)];

/// Generate `count` loopback UDP datagrams as fast as the socket allows.
fn flood(count: usize) {
    let Ok(sock) = std::net::UdpSocket::bind("127.0.0.1:0") else {
        return;
    };
    let payload = [0u8; 64];
    for _ in 0..count {
        let _ = sock.send_to(&payload, "127.0.0.1:9099");
    }
}

/// Process CPU time (user + sys) in seconds, from `/proc/self/stat`.
///
/// Read from procfs rather than `getrusage` so this integration test needs no
/// dependency of its own: `tests/*.rs` sees only the crate's public API, so a
/// libc call here would mean a dev-dependency AND a matching Bazel dep, for a
/// number that is printed rather than asserted.
fn cpu_time() -> f64 {
    // Fields 14 and 15 (1-indexed) are utime and stime in clock ticks. The
    // comm field can contain spaces and parentheses, so split after the
    // closing paren rather than on whitespace from the start.
    let Ok(stat) = std::fs::read_to_string("/proc/self/stat") else {
        return 0.0;
    };
    let Some(after_comm) = stat.rsplit_once(')') else {
        return 0.0;
    };
    let fields: Vec<&str> = after_comm.1.split_whitespace().collect();
    // after_comm.1 starts at field 3 (state), so utime is index 11.
    let ticks = |i: usize| {
        fields
            .get(i)
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(0.0)
    };
    // _SC_CLK_TCK is 100 on every Linux this ships to; the value is printed,
    // not asserted, so a wrong constant would misreport rather than misgate.
    (ticks(11) + ticks(12)) / 100.0
}

/// A released descriptor can be armed again.
///
/// This is the whole reason `Ring::into_socket` exists, and until an end-to-end
/// capture exercised it, it did not work: `into_socket` unmapped the ring but
/// never freed it, and `setsockopt(PACKET_VERSION)` refuses to run against a
/// socket that still has one. The second `activate` failed with a bare `EBUSY`
/// from a call that has nothing obviously to do with rings, on a descriptor
/// that had been handed back "cleanly".
///
/// It matters because a capture descriptor is opened once, while privileged,
/// and cannot be reopened after the drop. Without this, the SECOND capture on
/// an interface fails for the life of the process -- and the first one looks
/// perfect.
#[test]
#[ignore = "needs CAP_NET_RAW"]
fn a_released_descriptor_can_be_armed_again() {
    let socket = Socket::open("lo").expect("open lo (needs CAP_NET_RAW)");

    let ring = socket
        .activate(RingConfig::default(), ICMP_FILTER)
        .expect("first activation");
    let socket = ring.into_socket();

    let ring = socket
        .activate(RingConfig::default(), ICMP_FILTER)
        .unwrap_or_else(|err| {
            panic!(
                "a descriptor returned by into_socket must be reusable, got: {}",
                err.error
            )
        });

    // And it still captures, rather than merely accepting the setsockopt.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut ring = ring;
    let _ = Command::new("ping")
        .args(["-c", "3", "-i", "0.05", "-W", "1", "127.0.0.1"])
        .output();

    let mut seen = 0usize;
    while Instant::now() < deadline && seen == 0 {
        match ring.drain_block(|_| seen += 1) {
            Some(_) => {}
            None => std::thread::sleep(Duration::from_millis(20)),
        }
    }
    assert!(
        seen > 0,
        "the re-armed ring accepted the syscalls but captured nothing"
    );
    println!("re-armed descriptor captured {seen} frame(s)");
}
