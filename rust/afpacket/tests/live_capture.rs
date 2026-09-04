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
