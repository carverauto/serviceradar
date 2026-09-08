use std::{
    net::{IpAddr, Ipv4Addr},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::broadcast;

use anyhow::{Context, Result};
use crossbeam_channel::TryRecvError;

use crate::{
    af_xdp::{AfXdpConsumers, AfXdpPacket, AfXdpStream, NoopXskSocketRegistry, XskSocketRegistry},
    dpi::DpiPipeline,
    fingerprint::FingerprintAccumulator,
    metrics::Metrics,
    proto::netprobe::DpiEvent,
    runtime_config::DpiEventGate,
};

const AF_INET: u16 = 2;
const AF_INET6: u16 = 10;
const IPPROTO_ICMP: u16 = 1;
const IPPROTO_ICMPV6: u16 = 58;
const IPPROTO_TCP: u16 = 6;
const IPPROTO_UDP: u16 = 17;
const FLOW_TABLE_ENTRY_CLASSIFYING: u32 = 0;
const CLASSIFIER_IDLE_SLEEP: Duration = Duration::from_millis(1);

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct FlowKey {
    pub address_family: u16,
    pub transport_protocol: u16,
    pub endpoint_a_port: u16,
    pub endpoint_b_port: u16,
    pub endpoint_a_addr: [u8; 16],
    pub endpoint_b_addr: [u8; 16],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct FlowTableKey {
    pub interface_index: u32,
    pub reserved: u32,
    pub flow: FlowKey,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FlowTableEntry {
    pub classified_as: u32,
    pub packets_seen: u64,
    pub packets_redirected: u32,
    pub reserved: u32,
    pub last_seen_ns: u64,
}

#[cfg(target_os = "linux")]
// SAFETY: FlowKey is #[repr(C)], Copy, contains only integer fields and fixed
// byte arrays, and matches the eBPF FlowKey ABI exactly.
unsafe impl aya::Pod for FlowKey {}

#[cfg(target_os = "linux")]
// SAFETY: FlowTableKey is #[repr(C)], Copy, contains only Pod fields, and
// matches the eBPF flow_table key ABI exactly.
unsafe impl aya::Pod for FlowTableKey {}

#[cfg(target_os = "linux")]
// SAFETY: FlowTableEntry is #[repr(C)], Copy, contains only integer fields, and
// matches the eBPF flow_table value ABI exactly.
unsafe impl aya::Pod for FlowTableEntry {}

pub trait FlowTableWriter {
    fn update_classification(
        &mut self,
        key: FlowTableKey,
        classified_as: u32,
        observed_at_unix_nano: i64,
    ) -> Result<()>;
}

pub struct AfXdpClassifier<W> {
    pipeline: DpiPipeline,
    flow_table: W,
    fingerprint_accumulator: Option<FingerprintAccumulator>,
}

impl<W> AfXdpClassifier<W>
where
    W: FlowTableWriter,
{
    pub fn new(flow_table: W) -> Self {
        Self {
            pipeline: DpiPipeline::phase2(),
            flow_table,
            fingerprint_accumulator: None,
        }
    }

    pub fn with_fingerprint_accumulator(
        flow_table: W,
        fingerprint_accumulator: FingerprintAccumulator,
    ) -> Self {
        Self {
            pipeline: DpiPipeline::phase2(),
            flow_table,
            fingerprint_accumulator: Some(fingerprint_accumulator),
        }
    }

    pub fn classify_packet(
        &mut self,
        packet: &AfXdpPacket,
        observed_at_unix_nano: i64,
    ) -> Result<Vec<DpiEvent>> {
        let events = self.pipeline.analyze_packet_with_fingerprints(
            &packet.interface,
            observed_at_unix_nano,
            &packet.data,
            self.fingerprint_accumulator.as_ref(),
        );
        for event in &events {
            if let Some(key) = flow_table_key_from_event(packet.ifindex, event) {
                self.flow_table.update_classification(
                    key,
                    classified_as(event.protocol.as_str()),
                    observed_at_unix_nano,
                )?;
            }
        }

        Ok(events)
    }

    pub fn classify_next_from_stream(
        &mut self,
        stream: &AfXdpStream,
        observed_at_unix_nano: i64,
    ) -> Result<Option<Vec<DpiEvent>>> {
        match stream.receiver.try_recv() {
            Ok(packet) => self
                .classify_packet(&packet, observed_at_unix_nano)
                .map(Some),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => Ok(None),
        }
    }
}

#[cfg(target_os = "linux")]
pub struct AyaFlowTableWriter {
    map: aya::maps::HashMap<aya::maps::MapData, FlowTableKey, FlowTableEntry>,
}

#[cfg(target_os = "linux")]
impl AyaFlowTableWriter {
    pub fn from_ebpf(ebpf: &mut aya::Ebpf) -> Result<Self> {
        let map = ebpf.take_map("flow_table").ok_or_else(|| {
            anyhow::anyhow!("flow_table map is missing from netprobe eBPF object")
        })?;
        Ok(Self {
            map: aya::maps::HashMap::try_from(map)?,
        })
    }
}

#[cfg(target_os = "linux")]
impl FlowTableWriter for AyaFlowTableWriter {
    fn update_classification(
        &mut self,
        key: FlowTableKey,
        classified_as: u32,
        observed_at_unix_nano: i64,
    ) -> Result<()> {
        let mut entry = self.map.get(&key, 0).unwrap_or(FlowTableEntry {
            classified_as: FLOW_TABLE_ENTRY_CLASSIFYING,
            packets_seen: 0,
            packets_redirected: 0,
            reserved: 0,
            last_seen_ns: 0,
        });
        entry.classified_as = classified_as;
        entry.last_seen_ns = observed_at_unix_nano.max(0) as u64;
        self.map.insert(key, entry, 0)?;
        Ok(())
    }
}

pub struct AfXdpClassifierRuntime {
    stop: Arc<AtomicBool>,
    classifier_thread: Option<JoinHandle<()>>,
    _consumers: AfXdpConsumers,
}

impl AfXdpClassifierRuntime {
    pub fn start<W>(
        interfaces: &[String],
        flow_table: W,
        metrics: Metrics,
        dpi_events: broadcast::Sender<DpiEvent>,
        dpi_gate: Arc<DpiEventGate>,
    ) -> Result<Self>
    where
        W: FlowTableWriter + Send + 'static,
    {
        Self::start_with_xsk_registry(
            interfaces,
            flow_table,
            metrics,
            dpi_events,
            dpi_gate,
            Arc::new(NoopXskSocketRegistry),
            None,
        )
    }

    pub fn start_with_xsk_registry<W>(
        interfaces: &[String],
        flow_table: W,
        metrics: Metrics,
        dpi_events: broadcast::Sender<DpiEvent>,
        dpi_gate: Arc<DpiEventGate>,
        xsk_registry: Arc<dyn XskSocketRegistry>,
        fingerprint_accumulator: Option<FingerprintAccumulator>,
    ) -> Result<Self>
    where
        W: FlowTableWriter + Send + 'static,
    {
        let mut consumers = AfXdpConsumers::start_with_registry(interfaces, xsk_registry)
            .context("failed to start AF_XDP interface consumers")?;
        let streams = consumers.take_streams();
        let stop = Arc::new(AtomicBool::new(false));
        let stop_classifier = Arc::clone(&stop);
        let classifier_thread = thread::Builder::new()
            .name("netprobe-af-xdp-classifier".to_owned())
            .spawn(move || {
                run_classifier_loop(
                    streams,
                    flow_table,
                    metrics,
                    dpi_events,
                    dpi_gate,
                    stop_classifier,
                    fingerprint_accumulator,
                );
            })
            .context("failed to spawn AF_XDP classifier thread")?;

        Ok(Self {
            stop,
            classifier_thread: Some(classifier_thread),
            _consumers: consumers,
        })
    }

    #[cfg(target_os = "linux")]
    pub fn start_from_ebpf(
        interfaces: &[String],
        ebpf: &mut aya::Ebpf,
        metrics: Metrics,
        dpi_events: broadcast::Sender<DpiEvent>,
        dpi_gate: Arc<DpiEventGate>,
        fingerprint_accumulator: FingerprintAccumulator,
    ) -> Result<Self> {
        let flow_table = AyaFlowTableWriter::from_ebpf(ebpf)?;
        let xsk_registry = Arc::new(crate::af_xdp::AyaXskSocketRegistry::from_ebpf(ebpf)?);
        Self::start_with_xsk_registry(
            interfaces,
            flow_table,
            metrics,
            dpi_events,
            dpi_gate,
            xsk_registry,
            Some(fingerprint_accumulator),
        )
    }
}

impl Drop for AfXdpClassifierRuntime {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.classifier_thread.take()
            && thread.join().is_err()
        {
            log::warn!("AF_XDP classifier thread panicked during shutdown");
        }
    }
}

fn run_classifier_loop<W>(
    streams: Vec<AfXdpStream>,
    flow_table: W,
    metrics: Metrics,
    dpi_events: broadcast::Sender<DpiEvent>,
    dpi_gate: Arc<DpiEventGate>,
    stop: Arc<AtomicBool>,
    fingerprint_accumulator: Option<FingerprintAccumulator>,
) where
    W: FlowTableWriter,
{
    let mut classifier = match fingerprint_accumulator {
        Some(accumulator) => AfXdpClassifier::with_fingerprint_accumulator(flow_table, accumulator),
        None => AfXdpClassifier::new(flow_table),
    };
    while !stop.load(Ordering::Relaxed) {
        match classify_streams_once(
            &mut classifier,
            &streams,
            now_unix_nano(),
            &metrics,
            &dpi_events,
            &dpi_gate,
        ) {
            Ok(0) => thread::sleep(CLASSIFIER_IDLE_SLEEP),
            Ok(_) => {}
            Err(err) => {
                metrics.inc_packets_dropped();
                log::warn!("AF_XDP classifier iteration failed: {err:#}");
                thread::sleep(CLASSIFIER_IDLE_SLEEP);
            }
        }
    }
}

fn classify_streams_once<W>(
    classifier: &mut AfXdpClassifier<W>,
    streams: &[AfXdpStream],
    observed_at_unix_nano: i64,
    metrics: &Metrics,
    dpi_events: &broadcast::Sender<DpiEvent>,
    dpi_gate: &DpiEventGate,
) -> Result<usize>
where
    W: FlowTableWriter,
{
    let mut packets_classified = 0usize;
    for stream in streams {
        let Some(events) = classifier.classify_next_from_stream(stream, observed_at_unix_nano)?
        else {
            continue;
        };
        packets_classified = packets_classified.saturating_add(1);
        metrics.inc_packets_processed();
        for event in events {
            let Some(event) = dpi_gate.filter(event) else {
                continue;
            };
            let event_interface = event.interface_name.clone();
            let event_protocol = event.protocol.clone();
            metrics.inc_dpi_events();
            if dpi_events.send(event).is_err() {
                metrics.inc_dpi_events_dropped("no_receiver", 1);
                log::debug!(
                    "dropping AF_XDP DPI event because nothing is subscribed for {}",
                    event_interface
                );
            }
            log::debug!(
                "observed AF_XDP DPI protocol {} on {}",
                event_protocol,
                event_interface
            );
        }
    }

    Ok(packets_classified)
}

pub(crate) fn flow_table_key_from_event(
    interface_index: u32,
    event: &DpiEvent,
) -> Option<FlowTableKey> {
    Some(FlowTableKey {
        interface_index,
        reserved: 0,
        flow: canonical_flow_key(
            parse_ip(&event.source_ip)?,
            parse_ip(&event.destination_ip)?,
            event.source_port.try_into().ok()?,
            event.destination_port.try_into().ok()?,
            transport_protocol(event.transport_protocol.as_str())?,
        )?,
    })
}

fn parse_ip(value: &str) -> Option<IpAddr> {
    value.parse().ok()
}

pub(crate) fn transport_protocol(value: &str) -> Option<u16> {
    match value {
        "icmp" => Some(IPPROTO_ICMP),
        "icmpv6" => Some(IPPROTO_ICMPV6),
        "tcp" => Some(IPPROTO_TCP),
        "udp" => Some(IPPROTO_UDP),
        _ => None,
    }
}

fn classified_as(protocol: &str) -> u32 {
    fnv1a(protocol.as_bytes()).max(1)
}

pub(crate) fn canonical_flow_key(
    source_ip: IpAddr,
    destination_ip: IpAddr,
    source_port: u16,
    destination_port: u16,
    transport_protocol: u16,
) -> Option<FlowKey> {
    let (address_family, source_addr, destination_addr) = ip_addrs(source_ip, destination_ip)?;
    let source_first = endpoint_less_or_equal(
        &source_addr,
        source_port,
        &destination_addr,
        destination_port,
    );

    if source_first {
        Some(FlowKey {
            address_family,
            transport_protocol,
            endpoint_a_port: source_port,
            endpoint_b_port: destination_port,
            endpoint_a_addr: source_addr,
            endpoint_b_addr: destination_addr,
        })
    } else {
        Some(FlowKey {
            address_family,
            transport_protocol,
            endpoint_a_port: destination_port,
            endpoint_b_port: source_port,
            endpoint_a_addr: destination_addr,
            endpoint_b_addr: source_addr,
        })
    }
}

fn ip_addrs(source_ip: IpAddr, destination_ip: IpAddr) -> Option<(u16, [u8; 16], [u8; 16])> {
    match (source_ip, destination_ip) {
        (IpAddr::V4(source), IpAddr::V4(destination)) => {
            Some((AF_INET, ipv4_addr(source), ipv4_addr(destination)))
        }
        (IpAddr::V6(source), IpAddr::V6(destination)) => {
            Some((AF_INET6, source.octets(), destination.octets()))
        }
        _ => None,
    }
}

fn ipv4_addr(ip: Ipv4Addr) -> [u8; 16] {
    let mut out = [0u8; 16];
    out[..4].copy_from_slice(&ip.octets());
    out
}

fn endpoint_less_or_equal(
    left_addr: &[u8; 16],
    left_port: u16,
    right_addr: &[u8; 16],
    right_port: u16,
) -> bool {
    left_addr
        .iter()
        .zip(right_addr.iter())
        .find_map(|(left, right)| match left.cmp(right) {
            std::cmp::Ordering::Less => Some(true),
            std::cmp::Ordering::Greater => Some(false),
            std::cmp::Ordering::Equal => None,
        })
        .unwrap_or(left_port <= right_port)
}

fn fnv1a(bytes: &[u8]) -> u32 {
    let mut hash = 0x811c9dc5u32;
    for byte in bytes {
        hash ^= u32::from(*byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    hash
}

fn now_unix_nano() -> i64 {
    let Ok(duration) = SystemTime::now().duration_since(UNIX_EPOCH) else {
        return 0;
    };

    let nanos = i128::from(duration.as_secs())
        .saturating_mul(1_000_000_000)
        .saturating_add(i128::from(duration.subsec_nanos()));
    nanos.min(i128::from(i64::MAX)) as i64
}

#[cfg(test)]
mod tests {
    use std::{collections::HashMap, sync::Arc};

    use anyhow::Result;
    use crossbeam_channel::bounded;

    use super::{
        AF_INET, AfXdpClassifier, FlowTableEntry, FlowTableKey, FlowTableWriter, IPPROTO_TCP,
        classified_as, classify_streams_once,
    };
    use crate::af_xdp::{AfXdpConsumerConfig, AfXdpPacket, AfXdpStream};
    use crate::{
        config::Config,
        metrics::Metrics,
        proto::netprobe::{DpiConfig, VisibilityAgentConfig},
        runtime_config::{DpiEventGate, RuntimeConfig},
    };

    #[derive(Default)]
    struct RecordingFlowTable {
        entries: HashMap<FlowTableKey, FlowTableEntry>,
    }

    impl FlowTableWriter for RecordingFlowTable {
        fn update_classification(
            &mut self,
            key: FlowTableKey,
            classified_as: u32,
            observed_at_unix_nano: i64,
        ) -> Result<()> {
            self.entries.insert(
                key,
                FlowTableEntry {
                    classified_as,
                    packets_seen: 1,
                    packets_redirected: 1,
                    reserved: 0,
                    last_seen_ns: observed_at_unix_nano as u64,
                },
            );
            Ok(())
        }
    }

    #[test]
    fn classifier_emits_dpi_event_and_marks_flow_classified() {
        let packet = AfXdpPacket {
            interface: "eth0".to_owned(),
            ifindex: 7,
            queue_id: 0,
            data: tcp_packet(49152, 80, b"GET / HTTP/1.1\r\nHost: example\r\n\r\n"),
        };
        let mut classifier = AfXdpClassifier::new(RecordingFlowTable::default());

        let events = classifier.classify_packet(&packet, 123).unwrap();

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].protocol, "http1");
        assert_eq!(classifier.flow_table.entries.len(), 1);
        let (key, entry) = classifier.flow_table.entries.iter().next().unwrap();
        assert_eq!(key.interface_index, 7);
        assert_eq!(key.flow.address_family, AF_INET);
        assert_eq!(key.flow.transport_protocol, IPPROTO_TCP);
        assert_eq!(key.flow.endpoint_a_port, 49152);
        assert_eq!(key.flow.endpoint_b_port, 80);
        assert_eq!(entry.classified_as, classified_as("http1"));
        assert_eq!(entry.last_seen_ns, 123);
    }

    #[test]
    fn classifier_canonicalizes_reverse_flow_key() {
        let packet = AfXdpPacket {
            interface: "eth0".to_owned(),
            ifindex: 7,
            queue_id: 0,
            data: tcp_packet_with_ips(
                [198, 51, 100, 20],
                [192, 0, 2, 10],
                80,
                49152,
                b"HTTP/1.1 200 OK\r\n\r\n",
            ),
        };
        let mut classifier = AfXdpClassifier::new(RecordingFlowTable::default());

        let events = classifier.classify_packet(&packet, 123).unwrap();

        assert_eq!(events.len(), 1);
        let (key, _entry) = classifier.flow_table.entries.iter().next().unwrap();
        assert_eq!(key.flow.endpoint_a_port, 49152);
        assert_eq!(key.flow.endpoint_b_port, 80);
    }

    #[test]
    fn classify_next_from_stream_consumes_af_xdp_channel() {
        let (tx, rx) = bounded(1);
        tx.send(AfXdpPacket {
            interface: "eth0".to_owned(),
            ifindex: 7,
            queue_id: 0,
            data: tcp_packet(22, 49152, b"SSH-2.0-OpenSSH_9.9\r\n"),
        })
        .unwrap();
        let stream = AfXdpStream {
            config: AfXdpConsumerConfig {
                interface: "eth0".to_owned(),
                ifindex: 7,
                queue_id: 0,
                preferred_core: None,
                redirect_budget: 16,
            },
            receiver: rx,
        };
        let mut classifier = AfXdpClassifier::new(RecordingFlowTable::default());

        let events = classifier.classify_next_from_stream(&stream, 456).unwrap();

        let events = events.expect("expected one AF_XDP packet");
        assert_eq!(events[0].protocol, "ssh");
        assert!(
            classifier
                .classify_next_from_stream(&stream, 789)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn classify_streams_once_emits_gated_dpi_event() {
        let (tx, rx) = bounded(1);
        tx.send(AfXdpPacket {
            interface: "eth0".to_owned(),
            ifindex: 7,
            queue_id: 0,
            data: tcp_packet(22, 49152, b"SSH-2.0-OpenSSH_9.9\r\n"),
        })
        .unwrap();
        let stream = AfXdpStream {
            config: AfXdpConsumerConfig {
                interface: "eth0".to_owned(),
                ifindex: 7,
                queue_id: 0,
                preferred_core: None,
                redirect_budget: 16,
            },
            receiver: rx,
        };
        let runtime_config = RuntimeConfig::new(&Config::default());
        runtime_config
            .apply(VisibilityAgentConfig {
                enabled: true,
                dpi: Some(DpiConfig {
                    enabled: true,
                    protocols: vec!["ssh".to_string()],
                }),
                ..Default::default()
            })
            .unwrap();
        let gate = DpiEventGate::new(runtime_config);
        let metrics = Metrics::new().unwrap();
        // Subscribed BEFORE the classifier runs: broadcast drops a send with no
        // receivers, so a receiver created afterwards would see nothing.
        let (event_tx, mut event_rx) =
            tokio::sync::broadcast::channel::<crate::proto::netprobe::DpiEvent>(4);
        let mut classifier = AfXdpClassifier::new(RecordingFlowTable::default());

        let classified = classify_streams_once(
            &mut classifier,
            &[stream],
            456,
            &metrics,
            &event_tx,
            &Arc::new(gate),
        )
        .unwrap();

        assert_eq!(classified, 1);
        let event = event_rx.try_recv().unwrap();
        assert_eq!(event.protocol, "ssh");
        assert_eq!(event.interface_name, "eth0");
        assert_eq!(classifier.flow_table.entries.len(), 1);
    }

    fn tcp_packet(source_port: u16, destination_port: u16, payload: &[u8]) -> Vec<u8> {
        tcp_packet_with_ips(
            [192, 0, 2, 10],
            [198, 51, 100, 20],
            source_port,
            destination_port,
            payload,
        )
    }

    fn tcp_packet_with_ips(
        source_ip: [u8; 4],
        destination_ip: [u8; 4],
        source_port: u16,
        destination_port: u16,
        payload: &[u8],
    ) -> Vec<u8> {
        let total_len = 20 + 20 + payload.len();
        let mut packet = Vec::with_capacity(total_len);
        packet.extend_from_slice(&[
            0x45,
            0x00,
            ((total_len >> 8) & 0xff) as u8,
            (total_len & 0xff) as u8,
            0x12,
            0x34,
            0x40,
            0x00,
            0x40,
            6,
            0x00,
            0x00,
        ]);
        packet.extend_from_slice(&source_ip);
        packet.extend_from_slice(&destination_ip);
        packet.extend_from_slice(&source_port.to_be_bytes());
        packet.extend_from_slice(&destination_port.to_be_bytes());
        packet.extend_from_slice(&[0x01, 0x02, 0x03, 0x04]);
        packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        packet.extend_from_slice(&[0x50, 0x18]);
        packet.extend_from_slice(&0xfa_f0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(payload);
        packet
    }
}
