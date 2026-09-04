//! S2 acceptance: a capture driven end to end over the real IPC socket.
//!
//! Requires `CAP_NET_RAW`, so it is `#[ignore]` rather than self-skipping. A
//! test that notices it lacks the capability and returns `Ok(())` is a test
//! that cannot fail: it passes on RBE, passes on macOS, and never once opens a
//! socket. An ignored test is visibly not run.
//!
//! ```text
//! sudo -E cargo test -p serviceradar-netprobe --test live_capture_ipc -- --ignored --nocapture
//! ```
//!
//! What the unit tests cannot cover, and this does:
//!
//! * the `StartRemoteCapture` arm is actually reachable over the socket, with a
//!   real ring behind it;
//! * the bytes that come back are a pcapng file a reader accepts, containing
//!   the packets that were generated and none of the ones the filter excluded;
//! * a client that disappears mid-session frees the ring, and how long that
//!   takes measured rather than asserted from the design.

#![cfg(target_os = "linux")]

use std::{
    process::Command,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use serviceradar_netprobe::{
    capture::{
        self,
        service::{AfPacketActivator, CaptureService},
    },
    config::Config,
    event_queue,
    external_flow::SharedExternalFlowMatcher,
    framing::{read_frame, write_frame},
    metrics::Metrics,
    proto::netprobe::{
        CaptureTerminationReason, NetprobeFrame, PcapngBlock, StartRemoteCapture, netprobe_frame,
        start_remote_capture,
    },
    runtime_config::RuntimeConfig,
    server::IpcServer,
};
use tempfile::TempDir;
use tokio::{
    net::UnixStream,
    sync::{broadcast, watch},
};

/// `tcpdump -dd icmp` with a 262144 snaplen, as verified on Linux 6.8. Shared
/// with the afpacket live test on purpose: two hand-written encodings of the
/// same filter is two things to keep in agreement.
const ICMP_FILTER: &[(u32, u32, u32, i64)] = &[
    (0x28, 0, 0, 12),
    (0x15, 0, 3, 0x0800),
    (0x30, 0, 0, 23),
    (0x15, 0, 1, 1),
    (0x06, 0, 0, 262_144),
    (0x06, 0, 0, 0),
];

fn bpf(program: &[(u32, u32, u32, i64)]) -> start_remote_capture::Filter {
    start_remote_capture::Filter::FilterBpf(serviceradar_netprobe::proto::netprobe::BpfProgram {
        instructions: program
            .iter()
            .map(
                |&(code, jt, jf, k)| serviceradar_netprobe::proto::netprobe::BpfInstruction {
                    code,
                    jt,
                    jf,
                    k,
                },
            )
            .collect(),
    })
}

struct Harness {
    _dir: TempDir,
    socket: std::path::PathBuf,
    shutdown: watch::Sender<bool>,
    task: tokio::task::JoinHandle<anyhow::Result<()>>,
    service: Arc<CaptureService<AfPacketActivator>>,
}

async fn start_netprobe_ipc(interfaces: &[&str]) -> Harness {
    let dir = TempDir::new().unwrap();
    let socket = dir.path().join("ipc.sock");
    let config = Config {
        enabled: true,
        capture_interfaces: interfaces.iter().map(|s| (*s).to_string()).collect(),
        ..Default::default()
    };

    // The privileged step, exactly as `main` does it: descriptors are opened
    // here and never again.
    let handles = capture::open_allowlisted_interfaces(&config, &capture::AfPacketOpener)
        .expect("open capture descriptors (needs CAP_NET_RAW)");
    let service = Arc::new(CaptureService::new(
        Arc::new(Mutex::new(handles)),
        AfPacketActivator::default(),
    ));

    let (shutdown, shutdown_rx) = watch::channel(false);
    let (flow_tx, flow_rx) = event_queue::bounded(16);
    let (census_tx, _) = broadcast::channel(16);
    let (mdns_tx, _) = broadcast::channel(16);
    let server = IpcServer::new(
        &socket,
        flow_tx,
        flow_rx,
        census_tx,
        mdns_tx,
        SharedExternalFlowMatcher::new(0),
        RuntimeConfig::new(&config),
        Metrics::new().unwrap(),
        Some(Arc::clone(&service)),
    );
    let task = tokio::spawn(server.run(shutdown_rx));

    for _ in 0..200 {
        if socket.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(socket.exists(), "the IPC socket never appeared");

    Harness {
        _dir: dir,
        socket,
        shutdown,
        task,
        service,
    }
}

impl Harness {
    async fn stop(self) {
        let _ = self.shutdown.send(true);
        let _ = self.task.await;
    }
}

fn request(session: &str, filter: start_remote_capture::Filter) -> StartRemoteCapture {
    StartRemoteCapture {
        session_id: session.to_string(),
        actor: "live-test@example.com".to_string(),
        interfaces: vec!["lo".to_string()],
        filter: Some(filter),
        snaplen: 262_144,
        ..Default::default()
    }
}

fn ping_loopback(count: usize) {
    let _ = Command::new("ping")
        .args([
            "-c",
            &count.to_string(),
            "-i",
            "0.05",
            "-W",
            "1",
            "127.0.0.1",
        ])
        .output();
}

/// Collects log records so the host-local session record can be asserted.
///
/// design.md D8.6 makes the journal line the one control that survives an
/// attacker who owns core, which makes "we call `log::info!`" the wrong thing
/// to verify -- a format string that drops the actor still compiles, still
/// logs, and still looks right in a code review.
#[derive(Default)]
struct CapturedLog(Mutex<Vec<String>>);

static LOG: std::sync::OnceLock<Arc<CapturedLog>> = std::sync::OnceLock::new();

impl log::Log for CapturedLog {
    fn enabled(&self, _: &log::Metadata<'_>) -> bool {
        true
    }

    fn log(&self, record: &log::Record<'_>) {
        let line = format!("{} {}", record.level(), record.args());
        println!("{line}");
        self.0.lock().unwrap().push(line);
    }

    fn flush(&self) {}
}

fn captured_log() -> Arc<CapturedLog> {
    Arc::clone(LOG.get_or_init(|| {
        let sink = Arc::new(CapturedLog::default());
        // Leaked deliberately: `log` wants a `&'static dyn Log`, and the sink
        // lives for the whole test binary anyway.
        let _ = log::set_logger(Box::leak(Box::new(Arc::clone(&sink))));
        log::set_max_level(log::LevelFilter::Info);
        sink
    }))
}

impl CapturedLog {
    fn lines_containing(&self, needle: &str) -> Vec<String> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter(|line| line.contains(needle))
            .cloned()
            .collect()
    }
}

/// Section Header Block magic, little-endian on every host this runs on.
const SHB_TYPE: u32 = 0x0A0D_0D0A;
const IDB_TYPE: u32 = 0x0000_0001;
const EPB_TYPE: u32 = 0x0000_0006;

/// Walks a pcapng byte stream, returning (block type, body length) per block.
///
/// Deliberately an independent reader rather than netprobe's own encoder in
/// reverse: an encoder checked against itself agrees with itself, including
/// about a length field it got wrong.
fn walk_pcapng(bytes: &[u8]) -> Vec<(u32, usize)> {
    let mut blocks = Vec::new();
    let mut offset = 0usize;
    while offset + 12 <= bytes.len() {
        let block_type = u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
        let total = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap()) as usize;
        assert!(
            total >= 12 && total.is_multiple_of(4),
            "block at {offset} declares a length of {total}, which pcapng forbids"
        );
        assert!(
            offset + total <= bytes.len(),
            "block at {offset} declares {total} bytes but only {} remain",
            bytes.len() - offset
        );
        let trailing = u32::from_le_bytes(
            bytes[offset + total - 4..offset + total]
                .try_into()
                .unwrap(),
        ) as usize;
        assert_eq!(
            trailing, total,
            "the trailing length of the block at {offset} disagrees with the leading one; \
             a reader uses it to walk backwards and would desynchronise here"
        );
        blocks.push((block_type, total));
        offset += total;
    }
    assert_eq!(
        offset,
        bytes.len(),
        "the stream ends mid-block, with {} bytes left over",
        bytes.len() - offset
    );
    blocks
}

#[tokio::test]
#[ignore = "needs CAP_NET_RAW and a loopback interface"]
async fn a_capture_streams_a_readable_pcapng_of_the_filtered_traffic() {
    let log = captured_log();
    let harness = start_netprobe_ipc(&["lo"]).await;
    let mut client = UnixStream::connect(&harness.socket).await.unwrap();

    write_frame(
        &mut client,
        &NetprobeFrame {
            sequence: 1,
            payload: Some(netprobe_frame::Payload::StartRemoteCapture(request(
                "01JLIVE0000000000000000001",
                bpf(ICMP_FILTER),
            ))),
        },
    )
    .await
    .unwrap();

    // The header arrives on the request's own sequence, so a client learns its
    // request succeeded and gets the section header in one round trip.
    let response = read_frame(&mut client).await.unwrap().unwrap();
    assert_eq!(response.sequence, 1, "got {response:?}");
    let Some(netprobe_frame::Payload::PcapngBlock(header)) = response.payload else {
        panic!("expected a pcapng header, got {:?}", response.payload);
    };
    assert!(!header.r#final);

    let mut stream = header.bytes.clone();
    ping_loopback(6);

    // Read until the terminal block, cancelling once packets have arrived.
    let mut terminal: Option<PcapngBlock> = None;
    let mut packet_blocks = 0usize;
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        let Ok(Ok(Some(frame))) =
            tokio::time::timeout(Duration::from_secs(5), read_frame(&mut client)).await
        else {
            break;
        };
        let Some(netprobe_frame::Payload::PcapngBlock(block)) = frame.payload else {
            continue;
        };
        if block.r#final {
            terminal = Some(block);
            break;
        }
        assert_eq!(frame.sequence, 0, "stream blocks are unsolicited");
        stream.extend_from_slice(&block.bytes);
        packet_blocks += 1;

        if packet_blocks >= 4 {
            // Cancel by closing the connection, which is what a real client
            // disconnect looks like.
            break;
        }
    }

    let blocks = walk_pcapng(&stream);
    println!(
        "pcapng: {} blocks from {} bytes",
        blocks.len(),
        stream.len()
    );
    assert_eq!(
        blocks[0].0, SHB_TYPE,
        "the stream opens with a section header"
    );
    assert_eq!(blocks[1].0, IDB_TYPE, "then one interface description");
    let epbs = blocks.iter().filter(|(t, _)| *t == EPB_TYPE).count();
    assert!(
        epbs > 0,
        "the ICMP filter matched nothing; a capture that yields no packets and reports success \
         is the failure this path exists to avoid"
    );
    println!("captured {epbs} ICMP packet block(s)");

    if let Some(terminal) = terminal {
        println!(
            "terminal: reason={:?} captured={} dropped={} bytes={}",
            CaptureTerminationReason::try_from(terminal.termination_reason),
            terminal.packets_captured,
            terminal.packets_dropped,
            terminal.bytes_streamed
        );
    }

    // An INDEPENDENT reader, not this crate's encoder run backwards. An encoder
    // checked against itself agrees with itself, including about a length field
    // it got wrong.
    let path = std::env::temp_dir().join("serviceradar-s2-live.pcapng");
    std::fs::write(&path, &stream).unwrap();
    let capinfos = Command::new("capinfos")
        .args(["-c", "-t", path.to_str().unwrap()])
        .output()
        .expect("capinfos is part of the wireshark tools this acceptance needs");
    let report = String::from_utf8_lossy(&capinfos.stdout);
    println!("--- capinfos ---\n{report}");
    assert!(
        capinfos.status.success(),
        "capinfos rejected the stream: {}",
        String::from_utf8_lossy(&capinfos.stderr)
    );
    assert!(
        report.contains(&format!("Number of packets:   {epbs}"))
            || report.contains(&format!("Number of packets = {epbs}")),
        "capinfos disagrees with our own EPB count of {epbs}: {report}"
    );

    let tshark = Command::new("tshark")
        .args([
            "-r",
            path.to_str().unwrap(),
            "-T",
            "fields",
            "-e",
            "ip.proto",
        ])
        .output()
        .expect("tshark");
    let protocols = String::from_utf8_lossy(&tshark.stdout);
    println!("--- tshark ip.proto ---\n{protocols}");
    assert!(
        protocols.lines().filter(|l| !l.is_empty()).count() == epbs,
        "tshark decoded a different number of packets than capinfos counted"
    );
    assert!(
        protocols
            .lines()
            .filter(|l| !l.is_empty())
            .all(|l| l == "1"),
        "the ICMP filter let a non-ICMP packet through: {protocols}"
    );
    let _ = std::fs::remove_file(&path);

    // The stop line is written by the capture thread, so the assertions below
    // are about a session that has actually ended -- not one that is still
    // draining. Asserting straight after the disconnect passes or fails on
    // thread scheduling, which is a flake rather than a test.
    drop(client);
    let ended = Instant::now();
    while harness.service.active_interface().is_some() {
        assert!(
            ended.elapsed() < Duration::from_secs(5),
            "the session never ended"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    harness.stop().await;

    // design.md D8.6: the captured host keeps its own record.
    let starts = log.lines_containing("started: interface=lo");
    assert_eq!(
        starts.len(),
        1,
        "exactly one session-start line: {:?}",
        log.lines_containing("capture session")
    );
    assert!(
        starts[0].contains("01JLIVE0000000000000000001")
            && starts[0].contains("live-test@example.com"),
        "the start line must name the session and the actor: {}",
        starts[0]
    );

    let stops = log.lines_containing("stopped: interface=lo");
    assert_eq!(stops.len(), 1, "exactly one session-stop line: {stops:?}");
    assert!(
        stops[0].contains("01JLIVE0000000000000000001")
            && stops[0].contains("live-test@example.com")
            && stops[0].contains("packets="),
        "the stop line must name the session, the actor and the counts: {}",
        stops[0]
    );
}

#[tokio::test]
#[ignore = "needs CAP_NET_RAW and a loopback interface"]
async fn a_client_that_disappears_frees_the_ring_within_the_teardown_budget() {
    // Task 2.5. The budget is 5 s; what is asserted is the measured value, and
    // the measurement is printed so a regression shows as a number rather than
    // as a pass that got slower.
    let harness = start_netprobe_ipc(&["lo"]).await;
    let mut client = UnixStream::connect(&harness.socket).await.unwrap();

    write_frame(
        &mut client,
        &NetprobeFrame {
            sequence: 1,
            payload: Some(netprobe_frame::Payload::StartRemoteCapture(request(
                "01JLIVE0000000000000000002",
                bpf(ICMP_FILTER),
            ))),
        },
    )
    .await
    .unwrap();
    let response = read_frame(&mut client).await.unwrap().unwrap();
    assert!(matches!(
        response.payload,
        Some(netprobe_frame::Payload::PcapngBlock(_))
    ));
    assert_eq!(
        harness.service.active_interface().as_deref(),
        Some("lo"),
        "the session must be holding the interface before the disconnect means anything"
    );

    // The interface is deliberately SILENT here: a teardown that only works
    // when the next packet arrives is the bug, and a busy loopback would hide
    // it.
    let disconnected = Instant::now();
    drop(client);

    let mut freed = None;
    while disconnected.elapsed() < Duration::from_secs(10) {
        if harness.service.active_interface().is_none() {
            freed = Some(disconnected.elapsed());
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let freed = freed.expect("the capture session never released the interface");
    println!("ring freed {:?} after the client disconnected", freed);
    assert!(
        freed < Duration::from_secs(5),
        "teardown took {freed:?}, over the 5 s budget"
    );

    // And the descriptor is genuinely reusable, not merely un-slotted.
    let mut client = UnixStream::connect(&harness.socket).await.unwrap();
    write_frame(
        &mut client,
        &NetprobeFrame {
            sequence: 2,
            payload: Some(netprobe_frame::Payload::StartRemoteCapture(request(
                "01JLIVE0000000000000000003",
                bpf(ICMP_FILTER),
            ))),
        },
    )
    .await
    .unwrap();
    let response = read_frame(&mut client).await.unwrap().unwrap();
    match response.payload {
        Some(netprobe_frame::Payload::PcapngBlock(_)) => {}
        other => panic!("the descriptor did not come back: {other:?}"),
    }

    drop(client);
    harness.stop().await;
}

#[tokio::test]
#[ignore = "needs CAP_NET_RAW and a loopback interface"]
async fn an_unattributed_request_is_refused_against_a_real_descriptor() {
    // The unit test proves the rule; this proves it still holds when netprobe
    // is actually holding an openable descriptor for the interface asked for,
    // which is the only configuration in which the refusal matters.
    let harness = start_netprobe_ipc(&["lo"]).await;
    let mut client = UnixStream::connect(&harness.socket).await.unwrap();

    let mut unattributed = request("01JLIVE0000000000000000004", bpf(ICMP_FILTER));
    unattributed.actor = String::new();

    write_frame(
        &mut client,
        &NetprobeFrame {
            sequence: 9,
            payload: Some(netprobe_frame::Payload::StartRemoteCapture(unattributed)),
        },
    )
    .await
    .unwrap();

    let response = read_frame(&mut client).await.unwrap().unwrap();
    assert_eq!(response.sequence, 9);
    match response.payload {
        Some(netprobe_frame::Payload::Error(err)) => {
            assert_eq!(err.code, "capture_unattributed");
            println!("refused: {}", err.message);
        }
        other => panic!("an unattributed request must be refused, got {other:?}"),
    }
    assert!(
        harness.service.active_interface().is_none(),
        "a refused request must not have taken the interface"
    );

    drop(client);
    harness.stop().await;
}
