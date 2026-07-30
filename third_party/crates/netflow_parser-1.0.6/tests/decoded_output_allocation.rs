//! Fresh-process allocation gates for adversarial decoded output.

#![cfg(feature = "parse_unknown_fields")]

use netflow_parser::{NetflowPacket, NetflowParser, PendingFlowsConfig};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

struct CountingAllocator;

static LIVE_BYTES: AtomicUsize = AtomicUsize::new(0);
static PEAK_BYTES: AtomicUsize = AtomicUsize::new(0);

fn record_live(live: usize) {
    let mut peak = PEAK_BYTES.load(Ordering::Relaxed);
    while live > peak {
        match PEAK_BYTES.compare_exchange_weak(peak, live, Ordering::Relaxed, Ordering::Relaxed)
        {
            Ok(_) => break,
            Err(actual) => peak = actual,
        }
    }
}

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() {
            let live = LIVE_BYTES.fetch_add(layout.size(), Ordering::Relaxed) + layout.size();
            record_live(live);
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
            let live = if new_size >= old.size() {
                LIVE_BYTES.fetch_add(new_size - old.size(), Ordering::Relaxed) + new_size
                    - old.size()
            } else {
                LIVE_BYTES.fetch_sub(old.size() - new_size, Ordering::Relaxed)
                    - (old.size() - new_size)
            };
            record_live(live);
        }
        new_ptr
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

fn reset_peak() -> usize {
    let live = LIVE_BYTES.load(Ordering::Relaxed);
    PEAK_BYTES.store(live, Ordering::Relaxed);
    live
}

fn peak_delta(baseline: usize) -> usize {
    PEAK_BYTES.load(Ordering::Relaxed).saturating_sub(baseline)
}

fn v9_message(flowsets: &[Vec<u8>]) -> Vec<u8> {
    let mut packet = vec![0, 9, 0, flowsets.len() as u8];
    packet.extend_from_slice(&[0; 12]);
    packet.extend_from_slice(&1u32.to_be_bytes());
    for flowset in flowsets {
        packet.extend_from_slice(flowset);
    }
    packet
}

fn wide_template() -> Vec<u8> {
    let mut fields: Vec<(u16, u16)> = (1000..1064).map(|field| (field, 0)).collect();
    fields.push((1, 1));
    let length = 8 + fields.len() * 4;
    let mut set = Vec::with_capacity(length);
    set.extend_from_slice(&0u16.to_be_bytes());
    set.extend_from_slice(&(length as u16).to_be_bytes());
    set.extend_from_slice(&256u16.to_be_bytes());
    set.extend_from_slice(&(fields.len() as u16).to_be_bytes());
    for (field_type, field_length) in fields {
        set.extend_from_slice(&field_type.to_be_bytes());
        set.extend_from_slice(&field_length.to_be_bytes());
    }
    set
}

fn data(body_len: usize) -> Vec<u8> {
    let mut set = Vec::with_capacity(body_len + 4);
    set.extend_from_slice(&256u16.to_be_bytes());
    set.extend_from_slice(&((body_len + 4) as u16).to_be_bytes());
    set.resize(body_len + 4, 1);
    set
}

#[test]
fn default_limit_stays_bounded_and_pending_shortage_is_preflight_only() {
    let template = wide_template();
    let mut parser = NetflowParser::default();
    assert!(
        parser
            .parse_bytes(&v9_message(std::slice::from_ref(&template)))
            .is_ok()
    );

    let baseline = reset_peak();
    let result = parser.parse_bytes(&v9_message(&[data(1000)]));
    assert!(result.is_ok(), "{:?}", result.error);
    let NetflowPacket::V9(packet) = &result.packets[0] else {
        panic!("expected v9 packet")
    };
    let records = packet
        .flowsets
        .iter()
        .map(|flowset| match &flowset.body {
            netflow_parser::variable_versions::v9::FlowSetBody::Data(data) => data.fields.len(),
            _ => 0,
        })
        .sum::<usize>();
    assert_eq!(records, 1000);
    let bounded_peak = peak_delta(baseline);
    eprintln!("default_bound_peak_requested_bytes={bounded_peak}");
    assert!(
        bounded_peak <= 16 * 1024 * 1024,
        "default-bound parse peaked {} requested bytes above baseline",
        bounded_peak
    );
    drop(result);

    let mut pending = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();
    assert!(pending.parse_bytes(&v9_message(&[data(1000)])).is_ok());
    assert_eq!(pending.v9_cache_info().pending_flow_count, 1);

    // Nine current records consume 585 values, leaving too little room for
    // the queued 65,000-value entry. Replay must stop after wire-only preflight.
    let baseline = reset_peak();
    let refresh = pending.parse_bytes(&v9_message(&[template, data(9)]));
    assert!(refresh.is_ok(), "{:?}", refresh.error);
    assert_eq!(pending.v9_cache_info().pending_flow_count, 1);
    let preflight_peak = peak_delta(baseline);
    eprintln!("pending_preflight_peak_requested_bytes={preflight_peak}");
    assert!(
        preflight_peak < 1024 * 1024,
        "temporarily blocked replay allocated {} requested bytes",
        preflight_peak
    );
}
