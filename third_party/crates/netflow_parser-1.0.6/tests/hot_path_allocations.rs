// Deterministic warmed allocation measurements for the common parser APIs.

use netflow_parser::scoped_parser::AutoScopedParser;
use netflow_parser::{NetflowPacket, NetflowParser};
use std::alloc::{GlobalAlloc, Layout, System};
use std::hint::black_box;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

struct CountingAllocator;

static TRACKING: AtomicBool = AtomicBool::new(false);
static ALLOCATION_CALLS: AtomicUsize = AtomicUsize::new(0);
static REQUESTED_BYTES: AtomicUsize = AtomicUsize::new(0);
static LIVE_BYTES: AtomicUsize = AtomicUsize::new(0);

fn record_allocation(size: usize) {
    if TRACKING.load(Ordering::Relaxed) {
        ALLOCATION_CALLS.fetch_add(1, Ordering::Relaxed);
        REQUESTED_BYTES.fetch_add(size, Ordering::Relaxed);
    }
}

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() {
            LIVE_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
            record_allocation(layout.size());
        }
        ptr
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc_zeroed(layout) };
        if !ptr.is_null() {
            LIVE_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
            record_allocation(layout.size());
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE_BYTES.fetch_sub(layout.size(), Ordering::Relaxed);
        unsafe { System.dealloc(ptr, layout) };
    }

    unsafe fn realloc(&self, ptr: *mut u8, old: Layout, new_size: usize) -> *mut u8 {
        let new_ptr = unsafe { System.realloc(ptr, old, new_size) };
        if !new_ptr.is_null() {
            if new_size >= old.size() {
                LIVE_BYTES.fetch_add(new_size - old.size(), Ordering::Relaxed);
            } else {
                LIVE_BYTES.fetch_sub(old.size() - new_size, Ordering::Relaxed);
            }
            record_allocation(new_size);
        }
        new_ptr
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

const ITERATIONS: usize = 100;
const FIELDS: [(u16, u16); 6] = [(8, 4), (12, 4), (7, 2), (11, 2), (1, 4), (2, 4)];

#[derive(Clone, Copy)]
enum Protocol {
    V9,
    Ipfix,
}

impl Protocol {
    fn name(self) -> &'static str {
        match self {
            Self::V9 => "v9",
            Self::Ipfix => "ipfix",
        }
    }

    fn template_packet(self) -> Vec<u8> {
        match self {
            Self::V9 => v9_template_packet(),
            Self::Ipfix => ipfix_template_packet(),
        }
    }

    fn data_packet(self, flow_count: u16) -> Vec<u8> {
        match self {
            Self::V9 => v9_data_packet(flow_count),
            Self::Ipfix => ipfix_data_packet(flow_count),
        }
    }

    fn assert_records(self, packets: &[NetflowPacket], expected: usize) {
        assert_eq!(packets.len(), 1);
        let records: usize = match (self, &packets[0]) {
            (Self::V9, NetflowPacket::V9(packet)) => packet
                .flowsets
                .iter()
                .map(|flowset| match &flowset.body {
                    netflow_parser::variable_versions::v9::FlowSetBody::Data(data) => {
                        data.fields.len()
                    }
                    _ => 0,
                })
                .sum(),
            (Self::Ipfix, NetflowPacket::IPFix(packet)) => packet
                .flowsets
                .iter()
                .map(|flowset| match &flowset.body {
                    netflow_parser::variable_versions::ipfix::FlowSetBody::Data(data) => {
                        data.fields.len()
                    }
                    _ => 0,
                })
                .sum(),
            _ => panic!("wrong protocol"),
        };
        assert_eq!(records, expected);
    }
}

#[derive(Clone, Copy)]
enum Scenario {
    DirectParse,
    DirectIterator,
    AutoParse,
    AutoIterator,
}

impl Scenario {
    fn name(self) -> &'static str {
        match self {
            Self::DirectParse => "direct/parse",
            Self::DirectIterator => "direct/iterator",
            Self::AutoParse => "auto/parse",
            Self::AutoIterator => "auto/iterator",
        }
    }
}

fn v9_template_packet() -> Vec<u8> {
    let set_length = 8 + FIELDS.len() * 4;
    let mut packet = vec![0, 9, 0, 1];
    packet.extend_from_slice(&[0; 12]);
    packet.extend_from_slice(&1u32.to_be_bytes());
    packet.extend_from_slice(&0u16.to_be_bytes());
    packet.extend_from_slice(&(set_length as u16).to_be_bytes());
    packet.extend_from_slice(&256u16.to_be_bytes());
    packet.extend_from_slice(&(FIELDS.len() as u16).to_be_bytes());
    for (field, length) in FIELDS {
        packet.extend_from_slice(&field.to_be_bytes());
        packet.extend_from_slice(&length.to_be_bytes());
    }
    packet
}

fn v9_data_packet(flow_count: u16) -> Vec<u8> {
    let body = records(flow_count);
    let mut packet = vec![0, 9, 0, 1];
    packet.extend_from_slice(&[0; 12]);
    packet.extend_from_slice(&1u32.to_be_bytes());
    packet.extend_from_slice(&256u16.to_be_bytes());
    packet.extend_from_slice(&((body.len() + 4) as u16).to_be_bytes());
    packet.extend_from_slice(&body);
    packet
}

fn ipfix_template_packet() -> Vec<u8> {
    let set_length = 8 + FIELDS.len() * 4;
    let mut packet = Vec::with_capacity(16 + set_length);
    packet.extend_from_slice(&10u16.to_be_bytes());
    packet.extend_from_slice(&((16 + set_length) as u16).to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&1u32.to_be_bytes());
    packet.extend_from_slice(&1u32.to_be_bytes());
    packet.extend_from_slice(&2u16.to_be_bytes());
    packet.extend_from_slice(&(set_length as u16).to_be_bytes());
    packet.extend_from_slice(&256u16.to_be_bytes());
    packet.extend_from_slice(&(FIELDS.len() as u16).to_be_bytes());
    for (field, length) in FIELDS {
        packet.extend_from_slice(&field.to_be_bytes());
        packet.extend_from_slice(&length.to_be_bytes());
    }
    packet
}

fn ipfix_data_packet(flow_count: u16) -> Vec<u8> {
    let body = records(flow_count);
    let mut packet = Vec::with_capacity(20 + body.len());
    packet.extend_from_slice(&10u16.to_be_bytes());
    packet.extend_from_slice(&((20 + body.len()) as u16).to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&1u32.to_be_bytes());
    packet.extend_from_slice(&1u32.to_be_bytes());
    packet.extend_from_slice(&256u16.to_be_bytes());
    packet.extend_from_slice(&((body.len() + 4) as u16).to_be_bytes());
    packet.extend_from_slice(&body);
    packet
}

fn records(flow_count: u16) -> Vec<u8> {
    let mut body = Vec::with_capacity(usize::from(flow_count) * 20);
    for value in 0..flow_count {
        body.extend_from_slice(&[10, 0, (value >> 8) as u8, value as u8]);
        body.extend_from_slice(&[10, 0, 1, value as u8]);
        body.extend_from_slice(&80u16.to_be_bytes());
        body.extend_from_slice(&443u16.to_be_bytes());
        body.extend_from_slice(&1280u32.to_be_bytes());
        body.extend_from_slice(&10u32.to_be_bytes());
    }
    body
}

fn measure(mut operation: impl FnMut()) -> (usize, usize, isize) {
    operation();
    let baseline = LIVE_BYTES.load(Ordering::SeqCst);
    ALLOCATION_CALLS.store(0, Ordering::SeqCst);
    REQUESTED_BYTES.store(0, Ordering::SeqCst);
    TRACKING.store(true, Ordering::SeqCst);
    for _ in 0..ITERATIONS {
        operation();
    }
    TRACKING.store(false, Ordering::SeqCst);
    let after = LIVE_BYTES.load(Ordering::SeqCst);
    let calls = ALLOCATION_CALLS.load(Ordering::SeqCst);
    let bytes = REQUESTED_BYTES.load(Ordering::SeqCst);
    assert_eq!(calls % ITERATIONS, 0);
    assert_eq!(bytes % ITERATIONS, 0);
    (
        calls / ITERATIONS,
        bytes / ITERATIONS,
        after as isize - baseline as isize,
    )
}

fn run(protocol: Protocol, scenario: Scenario, flow_count: u16) -> (usize, usize, isize) {
    let template = protocol.template_packet();
    let packet = protocol.data_packet(flow_count);
    let source = SocketAddr::from(([192, 0, 2, 1], 2055));

    match scenario {
        Scenario::DirectParse => {
            let mut parser = NetflowParser::default();
            assert!(parser.parse_bytes(&template).is_ok());
            let check = parser.parse_bytes(&packet);
            assert!(check.is_ok());
            protocol.assert_records(&check.packets, usize::from(flow_count));
            measure(|| drop(black_box(parser.parse_bytes(black_box(&packet)))))
        }
        Scenario::DirectIterator => {
            let mut parser = NetflowParser::default();
            assert!(parser.parse_bytes(&template).is_ok());
            let check = parser
                .iter_packets(&packet)
                .map(Result::unwrap)
                .collect::<Vec<_>>();
            protocol.assert_records(&check, usize::from(flow_count));
            measure(|| {
                for result in parser.iter_packets(black_box(&packet)) {
                    black_box(result.unwrap());
                }
            })
        }
        Scenario::AutoParse => {
            let mut parser = AutoScopedParser::new();
            assert!(parser.parse_from_source(source, &template).is_ok());
            let check = parser.parse_from_source(source, &packet);
            assert!(check.is_ok());
            protocol.assert_records(&check.packets, usize::from(flow_count));
            measure(|| {
                drop(black_box(
                    parser.parse_from_source(source, black_box(&packet)),
                ));
            })
        }
        Scenario::AutoIterator => {
            let mut parser = AutoScopedParser::new();
            assert!(parser.parse_from_source(source, &template).is_ok());
            let check = parser
                .iter_packets_from_source(source, &packet)
                .unwrap()
                .map(Result::unwrap)
                .collect::<Vec<_>>();
            protocol.assert_records(&check, usize::from(flow_count));
            measure(|| {
                let iterator = parser
                    .iter_packets_from_source(source, black_box(&packet))
                    .unwrap();
                for result in iterator {
                    black_box(result.unwrap());
                }
            })
        }
    }
}

#[test]
fn warmed_common_hot_path_allocations() {
    for protocol in [Protocol::V9, Protocol::Ipfix] {
        for scenario in [
            Scenario::DirectParse,
            Scenario::DirectIterator,
            Scenario::AutoParse,
            Scenario::AutoIterator,
        ] {
            for flow_count in [1, 1000] {
                let (calls, bytes, live_delta) = run(protocol, scenario, flow_count);
                println!(
                    "allocation_profile\t{}/{}/{}\t{}\t{}\t{}",
                    protocol.name(),
                    scenario.name(),
                    flow_count,
                    calls,
                    bytes,
                    live_delta
                );
                assert_eq!(live_delta, 0);
            }
        }
    }
}
