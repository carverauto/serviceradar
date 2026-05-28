#![no_std]
#![no_main]

use aya_ebpf::{
    bindings::{BPF_ANY, TC_ACT_OK},
    helpers::{bpf_ktime_get_ns, bpf_probe_read_kernel},
    macros::{classifier, kprobe, kretprobe, map, tracepoint},
    maps::{HashMap as BpfHashMap, LruHashMap, RingBuf, XskMap},
    programs::{ProbeContext, RetProbeContext, TcContext, TracePointContext},
    EbpfContext,
};
use core::{ffi::c_void, panic::PanicInfo};

const EVENT_VERSION: u16 = 1;
const AF_INET: u16 = 2;
const AF_INET6: u16 = 10;
const IPPROTO_TCP: u16 = 6;
const IPPROTO_UDP: u16 = 17;
const ETH_P_IP: u16 = 0x0800;
const ETH_P_IPV6: u16 = 0x86dd;
const ETH_P_8021Q: u16 = 0x8100;
const ETH_P_8021AD: u16 = 0x88a8;
const ETH_HEADER_LEN: usize = 14;
const VLAN_HEADER_LEN: usize = 4;
const IPV4_MIN_HEADER_LEN: usize = 20;
const IPV6_HEADER_LEN: usize = 40;
const TCP_MIN_HEADER_LEN: usize = 20;
const UDP_HEADER_LEN: usize = 8;
const TCP_FLAG_SYN: u8 = 0x02;
const TCP_MAX_OPTIONS_LAYOUT: usize = 32;
const TCP_SYN_QUIRK_MALFORMED_OPTIONS: u32 = 1 << 0;
const TCP_PAYLOAD_CLASS_EMPTY: u8 = 0;
const TCP_PAYLOAD_CLASS_NON_EMPTY: u8 = 1;

const SKB_IIF_OFFSET: usize = 144;
const SKB_TRANSPORT_HEADER_OFFSET: usize = 178;
const SKB_NETWORK_HEADER_OFFSET: usize = 180;
const SKB_HEAD_OFFSET: usize = 192;

const FLOW_TABLE_MAX_ENTRIES: u32 = 65_536;
const FLOW_TO_PID_MAX_ENTRIES: u32 = 1_048_576;
const PROCESS_INFO_MAX_ENTRIES: u32 = 8_192;
const XSK_MAX_QUEUES: u32 = 1024;
const FLOW_REDIRECT_BUDGET: u32 = 16;

const EVENT_TCP_CONNECT: u16 = 1;
const EVENT_TCP_ACCEPT: u16 = 2;
const EVENT_TCP_CLOSE: u16 = 3;
const EVENT_UDP_SEND: u16 = 4;
const EVENT_UDP_RECV: u16 = 5;
const EVENT_INET_SOCK_SET_STATE: u16 = 6;

const TRACE_SKADDR_OFFSET: usize = 8;
const TRACE_OLDSTATE_OFFSET: usize = 16;
const TRACE_NEWSTATE_OFFSET: usize = 20;
const TRACE_SPORT_OFFSET: usize = 24;
const TRACE_DPORT_OFFSET: usize = 26;
const TRACE_FAMILY_OFFSET: usize = 28;
const TRACE_PROTOCOL_OFFSET: usize = 30;
const TRACE_SADDR_V4_OFFSET: usize = 32;
const TRACE_DADDR_V4_OFFSET: usize = 36;
const TRACE_SADDR_V6_OFFSET: usize = 40;
const TRACE_DADDR_V6_OFFSET: usize = 56;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct FlowTuple {
    pub family: u16,
    pub protocol: u16,
    pub source_port: u16,
    pub destination_port: u16,
    pub source_addr: [u8; 16],
    pub destination_addr: [u8; 16],
}

impl FlowTuple {
    const fn empty(protocol: u16) -> Self {
        Self {
            family: 0,
            protocol,
            source_port: 0,
            destination_port: 0,
            source_addr: [0; 16],
            destination_addr: [0; 16],
        }
    }
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct FlowAttributionRecord {
    pub version: u16,
    pub event_kind: u16,
    pub pid: u32,
    pub tgid: u32,
    pub uid: u32,
    pub gid: u32,
    pub socket_address: u64,
    pub old_state: i32,
    pub new_state: i32,
    pub tuple: FlowTuple,
    pub comm: [u8; 16],
}

#[repr(C)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct FlowKey {
    pub interface_index: u32,
    pub address_family: u16,
    pub transport_protocol: u16,
    pub endpoint_a_port: u16,
    pub endpoint_b_port: u16,
    pub endpoint_a_addr: [u8; 16],
    pub endpoint_b_addr: [u8; 16],
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct FlowTableEntry {
    pub classified_as: u32,
    pub packets_seen: u32,
    pub packets_redirected: u32,
    pub last_seen_ns: u64,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct FlowPidRecord {
    pub version: u16,
    pub event_kind: u16,
    pub pid: u32,
    pub tgid: u32,
    pub uid: u32,
    pub gid: u32,
    pub socket_address: u64,
    pub last_seen_ns: u64,
    pub old_state: i32,
    pub new_state: i32,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct ProcessInfoRecord {
    pub version: u16,
    pub reserved: u16,
    pub pid: u32,
    pub tgid: u32,
    pub uid: u32,
    pub gid: u32,
    pub last_seen_ns: u64,
    pub comm: [u8; 16],
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct TcpSynSignatureRecord {
    pub version: u16,
    pub ip_version: u16,
    pub ttl: u8,
    pub window_scale: u8,
    pub options_len: u8,
    pub payload_class: u8,
    pub window_size: u16,
    pub mss: u16,
    pub quirks: u32,
    pub observed_ns: u64,
    pub flow_key: FlowKey,
    pub options_layout: [u8; TCP_MAX_OPTIONS_LAYOUT],
}

#[map(name = "flow_events")]
static FLOW_EVENTS: RingBuf = RingBuf::pinned(1 << 20, 0);

#[map(name = "tcp_syn_signatures")]
static TCP_SYN_SIGNATURES: RingBuf = RingBuf::pinned(1 << 20, 0);

#[map(name = "flow_table")]
static FLOW_TABLE: LruHashMap<FlowKey, FlowTableEntry> =
    LruHashMap::pinned(FLOW_TABLE_MAX_ENTRIES, 0);

#[map(name = "flow_to_pid")]
static FLOW_TO_PID: LruHashMap<FlowKey, FlowPidRecord> =
    LruHashMap::pinned(FLOW_TO_PID_MAX_ENTRIES, 0);

#[map(name = "process_info")]
static PROCESS_INFO: BpfHashMap<u32, ProcessInfoRecord> =
    BpfHashMap::pinned(PROCESS_INFO_MAX_ENTRIES, 0);

#[map(name = "xsk_sockets")]
static XSK_SOCKETS: XskMap = XskMap::pinned(XSK_MAX_QUEUES, 0);

#[classifier]
pub fn netprobe_tc_ingress(ctx: TcContext) -> i32 {
    classify_and_maybe_redirect(ctx)
}

#[classifier]
pub fn netprobe_tc_egress(ctx: TcContext) -> i32 {
    classify_and_maybe_redirect(ctx)
}

#[kprobe(function = "tcp_rcv_state_process")]
pub fn tcp_rcv_state_process(ctx: ProbeContext) -> u32 {
    let Some(skb) = ctx.arg::<*const c_void>(1) else {
        return 0;
    };
    if skb.is_null() {
        return 0;
    }

    if let Some(signature) = parse_tcp_syn_signature_from_skb(skb, now_ns()) {
        let _ = TCP_SYN_SIGNATURES.output(&signature, 0);
    }

    0
}

#[kprobe(function = "tcp_connect")]
pub fn tcp_connect(ctx: ProbeContext) -> u32 {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return 0;
    };

    emit_event(
        &ctx,
        EVENT_TCP_CONNECT,
        sock,
        FlowTuple::empty(IPPROTO_TCP),
        0,
        0,
    );
    0
}

#[kretprobe(function = "inet_csk_accept")]
pub fn inet_csk_accept(ctx: RetProbeContext) -> u32 {
    let Some(sock) = ctx.ret::<*const c_void>() else {
        return 0;
    };

    if sock.is_null() {
        return 0;
    }

    emit_event(
        &ctx,
        EVENT_TCP_ACCEPT,
        sock,
        FlowTuple::empty(IPPROTO_TCP),
        0,
        0,
    );
    0
}

#[kprobe(function = "tcp_close")]
pub fn tcp_close(ctx: ProbeContext) -> u32 {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return 0;
    };

    emit_event(
        &ctx,
        EVENT_TCP_CLOSE,
        sock,
        FlowTuple::empty(IPPROTO_TCP),
        0,
        0,
    );
    0
}

#[kprobe(function = "udp_sendmsg")]
pub fn udp_sendmsg(ctx: ProbeContext) -> u32 {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return 0;
    };

    emit_event(
        &ctx,
        EVENT_UDP_SEND,
        sock,
        FlowTuple::empty(IPPROTO_UDP),
        0,
        0,
    );
    0
}

#[kprobe(function = "udp_recvmsg")]
pub fn udp_recvmsg(ctx: ProbeContext) -> u32 {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return 0;
    };

    emit_event(
        &ctx,
        EVENT_UDP_RECV,
        sock,
        FlowTuple::empty(IPPROTO_UDP),
        0,
        0,
    );
    0
}

#[tracepoint(name = "inet_sock_set_state", category = "sock")]
pub fn inet_sock_set_state(ctx: TracePointContext) -> u32 {
    let Ok(sock) = trace_read::<*const c_void>(&ctx, TRACE_SKADDR_OFFSET) else {
        return 0;
    };
    let Ok(old_state) = trace_read::<i32>(&ctx, TRACE_OLDSTATE_OFFSET) else {
        return 0;
    };
    let Ok(new_state) = trace_read::<i32>(&ctx, TRACE_NEWSTATE_OFFSET) else {
        return 0;
    };
    let Ok(family) = trace_read::<u16>(&ctx, TRACE_FAMILY_OFFSET) else {
        return 0;
    };
    let Ok(protocol) = trace_read::<u16>(&ctx, TRACE_PROTOCOL_OFFSET) else {
        return 0;
    };
    let Ok(source_port) = trace_read::<u16>(&ctx, TRACE_SPORT_OFFSET) else {
        return 0;
    };
    let Ok(destination_port) = trace_read::<u16>(&ctx, TRACE_DPORT_OFFSET) else {
        return 0;
    };

    if protocol != IPPROTO_TCP {
        return 0;
    }

    let mut tuple = FlowTuple::empty(protocol);
    tuple.family = family;
    tuple.source_port = source_port;
    tuple.destination_port = destination_port;

    if family == AF_INET {
        let Ok(source_addr) = trace_read::<[u8; 4]>(&ctx, TRACE_SADDR_V4_OFFSET) else {
            return 0;
        };
        let Ok(destination_addr) = trace_read::<[u8; 4]>(&ctx, TRACE_DADDR_V4_OFFSET) else {
            return 0;
        };
        tuple.source_addr[..4].copy_from_slice(&source_addr);
        tuple.destination_addr[..4].copy_from_slice(&destination_addr);
    } else if family == AF_INET6 {
        let Ok(source_addr) = trace_read::<[u8; 16]>(&ctx, TRACE_SADDR_V6_OFFSET) else {
            return 0;
        };
        let Ok(destination_addr) = trace_read::<[u8; 16]>(&ctx, TRACE_DADDR_V6_OFFSET) else {
            return 0;
        };
        tuple.source_addr = source_addr;
        tuple.destination_addr = destination_addr;
    } else {
        return 0;
    }

    emit_event(
        &ctx,
        EVENT_INET_SOCK_SET_STATE,
        sock,
        tuple,
        old_state,
        new_state,
    );
    0
}

fn emit_event(
    ctx: &impl EbpfContext,
    event_kind: u16,
    sock: *const c_void,
    tuple: FlowTuple,
    old_state: i32,
    new_state: i32,
) {
    let record = FlowAttributionRecord {
        version: EVENT_VERSION,
        event_kind,
        pid: ctx.pid(),
        tgid: ctx.tgid(),
        uid: ctx.uid(),
        gid: ctx.gid(),
        socket_address: sock as u64,
        old_state,
        new_state,
        tuple,
        comm: ctx.command().unwrap_or([0; 16]),
    };

    record_process_info(&record);
    record_flow_pid(&record);

    let _ = FLOW_EVENTS.output(&record, 0);
}

fn record_process_info(record: &FlowAttributionRecord) {
    let process = ProcessInfoRecord {
        version: EVENT_VERSION,
        reserved: 0,
        pid: record.pid,
        tgid: record.tgid,
        uid: record.uid,
        gid: record.gid,
        last_seen_ns: now_ns(),
        comm: record.comm,
    };

    let _ = PROCESS_INFO.insert(&record.tgid, &process, BPF_ANY as u64);
}

fn record_flow_pid(record: &FlowAttributionRecord) {
    let Some(flow_key) = flow_key_from_tuple(&record.tuple) else {
        return;
    };

    let pid = FlowPidRecord {
        version: EVENT_VERSION,
        event_kind: record.event_kind,
        pid: record.pid,
        tgid: record.tgid,
        uid: record.uid,
        gid: record.gid,
        socket_address: record.socket_address,
        last_seen_ns: now_ns(),
        old_state: record.old_state,
        new_state: record.new_state,
    };

    let _ = FLOW_TO_PID.insert(&flow_key, &pid, BPF_ANY as u64);
}

fn flow_key_from_tuple(tuple: &FlowTuple) -> Option<FlowKey> {
    if tuple.family != AF_INET && tuple.family != AF_INET6 {
        return None;
    }
    if tuple.protocol != IPPROTO_TCP && tuple.protocol != IPPROTO_UDP {
        return None;
    }

    Some(canonical_flow_key(
        0,
        tuple.family,
        tuple.protocol,
        tuple.source_addr,
        tuple.destination_addr,
        tuple.source_port,
        tuple.destination_port,
    ))
}

fn classify_and_maybe_redirect(ctx: TcContext) -> i32 {
    let Some(flow_key) = parse_flow_key(&ctx) else {
        return TC_ACT_OK as i32;
    };

    let now = now_ns();
    if let Some(entry_ptr) = FLOW_TABLE.get_ptr_mut(&flow_key) {
        // SAFETY: The pointer is returned by the kernel for this map lookup and
        // is valid for the duration of this eBPF program invocation. We only
        // mutate this entry before returning to the verifier-controlled context.
        let entry = unsafe { &mut *entry_ptr };
        entry.packets_seen = entry.packets_seen.saturating_add(1);
        entry.last_seen_ns = now;

        if entry.classified_as != 0 {
            return TC_ACT_OK as i32;
        }

        if entry.packets_redirected < FLOW_REDIRECT_BUDGET {
            entry.packets_redirected = entry.packets_redirected.saturating_add(1);
            return redirect_to_af_xdp(&ctx);
        }

        return TC_ACT_OK as i32;
    }

    let entry = FlowTableEntry {
        classified_as: 0,
        packets_seen: 1,
        packets_redirected: 1,
        last_seen_ns: now,
    };
    let _ = FLOW_TABLE.insert(&flow_key, &entry, BPF_ANY as u64);

    redirect_to_af_xdp(&ctx)
}

fn redirect_to_af_xdp(ctx: &TcContext) -> i32 {
    let queue = skb_queue_mapping(ctx);
    XSK_SOCKETS
        .redirect(queue, TC_ACT_OK as u64)
        .unwrap_or(TC_ACT_OK as u32) as i32
}

fn parse_flow_key(ctx: &TcContext) -> Option<FlowKey> {
    let mut offset = ETH_HEADER_LEN;
    let mut ethertype = load_be_u16(ctx, 12)?;
    if ethertype == ETH_P_8021Q || ethertype == ETH_P_8021AD {
        ethertype = load_be_u16(ctx, 16)?;
        offset = offset.saturating_add(VLAN_HEADER_LEN);
    }

    match ethertype {
        ETH_P_IP => parse_ipv4_flow_key(ctx, offset),
        ETH_P_IPV6 => parse_ipv6_flow_key(ctx, offset),
        _ => None,
    }
}

fn parse_tcp_syn_signature_from_skb(
    skb: *const c_void,
    observed_ns: u64,
) -> Option<TcpSynSignatureRecord> {
    let head = read_kernel_at::<*const u8>(skb, SKB_HEAD_OFFSET)?;
    let network_offset = usize::from(read_kernel_at::<u16>(skb, SKB_NETWORK_HEADER_OFFSET)?);
    let transport_offset = usize::from(read_kernel_at::<u16>(skb, SKB_TRANSPORT_HEADER_OFFSET)?);
    let interface_index = read_kernel_at::<u32>(skb, SKB_IIF_OFFSET).unwrap_or_default();

    let version = read_packet_u8(head, network_offset)? >> 4;
    match version {
        4 => parse_ipv4_tcp_syn_signature_from_skb(
            head,
            network_offset,
            transport_offset,
            interface_index,
            observed_ns,
        ),
        6 => parse_ipv6_tcp_syn_signature_from_skb(
            head,
            network_offset,
            transport_offset,
            interface_index,
            observed_ns,
        ),
        _ => None,
    }
}

fn parse_ipv4_tcp_syn_signature_from_skb(
    head: *const u8,
    ip_offset: usize,
    tcp_offset: usize,
    interface_index: u32,
    observed_ns: u64,
) -> Option<TcpSynSignatureRecord> {
    let version_ihl = read_packet_u8(head, ip_offset)?;
    if version_ihl >> 4 != 4 {
        return None;
    }

    let ihl = usize::from(version_ihl & 0x0f) * 4;
    if ihl < IPV4_MIN_HEADER_LEN {
        return None;
    }

    if read_packet_u8(head, ip_offset + 9)? != IPPROTO_TCP as u8 {
        return None;
    }

    let total_len = usize::from(read_packet_be_u16(head, ip_offset + 2)?);
    let ttl = read_packet_u8(head, ip_offset + 8)?;
    let mut source = [0u8; 16];
    let mut destination = [0u8; 16];
    source[..4].copy_from_slice(&read_packet_bytes::<4>(head, ip_offset + 12)?);
    destination[..4].copy_from_slice(&read_packet_bytes::<4>(head, ip_offset + 16)?);
    let source_port = read_packet_be_u16(head, tcp_offset)?;
    let destination_port = read_packet_be_u16(head, tcp_offset + 2)?;
    let flow_key = canonical_flow_key(
        interface_index,
        AF_INET,
        IPPROTO_TCP,
        source,
        destination,
        source_port,
        destination_port,
    );

    parse_tcp_syn_header(
        head,
        tcp_offset,
        total_len.saturating_sub(ihl),
        flow_key,
        observed_ns,
        4,
        ttl,
    )
}

fn parse_ipv6_tcp_syn_signature_from_skb(
    head: *const u8,
    ip_offset: usize,
    tcp_offset: usize,
    interface_index: u32,
    observed_ns: u64,
) -> Option<TcpSynSignatureRecord> {
    if read_packet_u8(head, ip_offset)? >> 4 != 6 {
        return None;
    }

    if read_packet_u8(head, ip_offset + 6)? != IPPROTO_TCP as u8 {
        return None;
    }

    let payload_len = usize::from(read_packet_be_u16(head, ip_offset + 4)?);
    let hop_limit = read_packet_u8(head, ip_offset + 7)?;
    let source = read_packet_bytes::<16>(head, ip_offset + 8)?;
    let destination = read_packet_bytes::<16>(head, ip_offset + 24)?;
    let source_port = read_packet_be_u16(head, tcp_offset)?;
    let destination_port = read_packet_be_u16(head, tcp_offset + 2)?;
    let flow_key = canonical_flow_key(
        interface_index,
        AF_INET6,
        IPPROTO_TCP,
        source,
        destination,
        source_port,
        destination_port,
    );

    parse_tcp_syn_header(
        head,
        tcp_offset,
        payload_len,
        flow_key,
        observed_ns,
        6,
        hop_limit,
    )
}

fn parse_tcp_syn_header(
    head: *const u8,
    tcp_offset: usize,
    tcp_segment_len: usize,
    flow_key: FlowKey,
    observed_ns: u64,
    ip_version: u16,
    ttl: u8,
) -> Option<TcpSynSignatureRecord> {
    if tcp_segment_len < TCP_MIN_HEADER_LEN {
        return None;
    }

    let data_offset = usize::from(read_packet_u8(head, tcp_offset + 12)? >> 4) * 4;
    if data_offset < TCP_MIN_HEADER_LEN || data_offset > tcp_segment_len {
        return None;
    }

    let flags = read_packet_u8(head, tcp_offset + 13)?;
    if flags & TCP_FLAG_SYN == 0 {
        return None;
    }

    let _ = read_packet_u8(head, tcp_offset + data_offset - 1)?;

    let window_size = read_packet_be_u16(head, tcp_offset + 14)?;
    let mut record = TcpSynSignatureRecord {
        version: EVENT_VERSION,
        ip_version,
        ttl,
        window_scale: 0,
        options_len: 0,
        payload_class: if tcp_segment_len > data_offset {
            TCP_PAYLOAD_CLASS_NON_EMPTY
        } else {
            TCP_PAYLOAD_CLASS_EMPTY
        },
        window_size,
        mss: 0,
        quirks: 0,
        observed_ns,
        flow_key,
        options_layout: [0; TCP_MAX_OPTIONS_LAYOUT],
    };

    parse_tcp_options_from_skb(
        head,
        tcp_offset + TCP_MIN_HEADER_LEN,
        data_offset - TCP_MIN_HEADER_LEN,
        &mut record,
    );
    Some(record)
}

fn parse_tcp_options_from_skb(
    head: *const u8,
    options_offset: usize,
    options_len: usize,
    record: &mut TcpSynSignatureRecord,
) {
    let mut offset = 0usize;
    let mut option_count = 0usize;

    while offset < options_len && option_count < TCP_MAX_OPTIONS_LAYOUT {
        let Some(kind) = read_packet_u8(head, options_offset + offset) else {
            record.quirks |= TCP_SYN_QUIRK_MALFORMED_OPTIONS;
            return;
        };

        record.options_layout[option_count] = kind;
        option_count += 1;

        if kind == 0 {
            break;
        }
        if kind == 1 {
            offset += 1;
            continue;
        }

        let Some(length) = read_packet_u8(head, options_offset + offset + 1).map(usize::from)
        else {
            record.quirks |= TCP_SYN_QUIRK_MALFORMED_OPTIONS;
            return;
        };
        if length < 2 || offset.saturating_add(length) > options_len {
            record.quirks |= TCP_SYN_QUIRK_MALFORMED_OPTIONS;
            return;
        }

        if kind == 2 && length == 4 {
            if let Some(mss) = read_packet_be_u16(head, options_offset + offset + 2) {
                record.mss = mss;
            }
        } else if kind == 3 && length == 3 {
            if let Some(window_scale) = read_packet_u8(head, options_offset + offset + 2) {
                record.window_scale = window_scale;
            }
        }

        offset += length;
    }

    record.options_len = option_count as u8;
}

fn parse_ipv4_flow_key(ctx: &TcContext, ip_offset: usize) -> Option<FlowKey> {
    let version_ihl = load_u8(ctx, ip_offset)?;
    if version_ihl >> 4 != 4 {
        return None;
    }

    let ihl = usize::from(version_ihl & 0x0f) * 4;
    if ihl < IPV4_MIN_HEADER_LEN {
        return None;
    }

    let protocol = load_u8(ctx, ip_offset + 9)?;
    if protocol != IPPROTO_TCP as u8 && protocol != IPPROTO_UDP as u8 {
        return None;
    }

    let mut source = [0u8; 16];
    let mut destination = [0u8; 16];
    source[..4].copy_from_slice(&load_bytes::<4>(ctx, ip_offset + 12)?);
    destination[..4].copy_from_slice(&load_bytes::<4>(ctx, ip_offset + 16)?);

    let transport_offset = ip_offset.saturating_add(ihl);
    let min_transport_len = if protocol == IPPROTO_TCP as u8 {
        TCP_MIN_HEADER_LEN
    } else {
        UDP_HEADER_LEN
    };
    let _ = ctx
        .load::<[u8; 1]>(transport_offset + min_transport_len - 1)
        .ok()?;

    let source_port = load_be_u16(ctx, transport_offset)?;
    let destination_port = load_be_u16(ctx, transport_offset + 2)?;
    Some(canonical_flow_key(
        skb_interface_index(ctx),
        AF_INET,
        u16::from(protocol),
        source,
        destination,
        source_port,
        destination_port,
    ))
}

fn parse_ipv6_flow_key(ctx: &TcContext, ip_offset: usize) -> Option<FlowKey> {
    let version = load_u8(ctx, ip_offset)? >> 4;
    if version != 6 {
        return None;
    }

    let protocol = load_u8(ctx, ip_offset + 6)?;
    if protocol != IPPROTO_TCP as u8 && protocol != IPPROTO_UDP as u8 {
        return None;
    }

    let source = load_bytes::<16>(ctx, ip_offset + 8)?;
    let destination = load_bytes::<16>(ctx, ip_offset + 24)?;

    let transport_offset = ip_offset.saturating_add(IPV6_HEADER_LEN);
    let min_transport_len = if protocol == IPPROTO_TCP as u8 {
        TCP_MIN_HEADER_LEN
    } else {
        UDP_HEADER_LEN
    };
    let _ = ctx
        .load::<[u8; 1]>(transport_offset + min_transport_len - 1)
        .ok()?;

    let source_port = load_be_u16(ctx, transport_offset)?;
    let destination_port = load_be_u16(ctx, transport_offset + 2)?;
    Some(canonical_flow_key(
        skb_interface_index(ctx),
        AF_INET6,
        u16::from(protocol),
        source,
        destination,
        source_port,
        destination_port,
    ))
}

fn canonical_flow_key(
    interface_index: u32,
    address_family: u16,
    transport_protocol: u16,
    source_addr: [u8; 16],
    destination_addr: [u8; 16],
    source_port: u16,
    destination_port: u16,
) -> FlowKey {
    let source_first = endpoint_less_or_equal(
        &source_addr,
        source_port,
        &destination_addr,
        destination_port,
    );
    if source_first {
        FlowKey {
            interface_index,
            address_family,
            transport_protocol,
            endpoint_a_port: source_port,
            endpoint_b_port: destination_port,
            endpoint_a_addr: source_addr,
            endpoint_b_addr: destination_addr,
        }
    } else {
        FlowKey {
            interface_index,
            address_family,
            transport_protocol,
            endpoint_a_port: destination_port,
            endpoint_b_port: source_port,
            endpoint_a_addr: destination_addr,
            endpoint_b_addr: source_addr,
        }
    }
}

fn endpoint_less_or_equal(
    left_addr: &[u8; 16],
    left_port: u16,
    right_addr: &[u8; 16],
    right_port: u16,
) -> bool {
    let mut index = 0usize;
    while index < 16 {
        if left_addr[index] < right_addr[index] {
            return true;
        }
        if left_addr[index] > right_addr[index] {
            return false;
        }
        index += 1;
    }

    left_port <= right_port
}

fn load_u8(ctx: &TcContext, offset: usize) -> Option<u8> {
    ctx.load::<u8>(offset).ok()
}

fn load_be_u16(ctx: &TcContext, offset: usize) -> Option<u16> {
    let bytes = ctx.load::<[u8; 2]>(offset).ok()?;
    Some(u16::from_be_bytes(bytes))
}

fn load_bytes<const N: usize>(ctx: &TcContext, offset: usize) -> Option<[u8; N]> {
    ctx.load::<[u8; N]>(offset).ok()
}

fn read_kernel_at<T: Copy>(base: *const c_void, offset: usize) -> Option<T> {
    // SAFETY: The caller passes a kernel pointer supplied by the probed kernel
    // function. bpf_probe_read_kernel copies the requested field and returns an
    // error instead of faulting if the address is invalid for this kernel.
    unsafe { bpf_probe_read_kernel((base as *const u8).add(offset) as *const T).ok() }
}

fn read_packet_u8(head: *const u8, offset: usize) -> Option<u8> {
    read_packet_at(head, offset)
}

fn read_packet_be_u16(head: *const u8, offset: usize) -> Option<u16> {
    let bytes = read_packet_bytes::<2>(head, offset)?;
    Some(u16::from_be_bytes(bytes))
}

fn read_packet_bytes<const N: usize>(head: *const u8, offset: usize) -> Option<[u8; N]> {
    read_packet_at(head, offset)
}

fn read_packet_at<T: Copy>(head: *const u8, offset: usize) -> Option<T> {
    // SAFETY: `head` is read from `struct sk_buff::head`; offsets come from
    // skb network/transport header metadata or bounded TCP option parsing.
    // The helper performs a checked kernel-memory copy for the verifier.
    unsafe { bpf_probe_read_kernel(head.add(offset) as *const T).ok() }
}

fn skb_interface_index(ctx: &TcContext) -> u32 {
    // SAFETY: TcContext owns the `__sk_buff` pointer for the lifetime of this
    // classifier invocation; reading scalar metadata fields is permitted by the
    // TC program type.
    let ifindex = unsafe { (*ctx.skb.skb).ifindex };
    if ifindex == 0 {
        // SAFETY: Same as above; ingress_ifindex is scalar SKB metadata.
        unsafe { (*ctx.skb.skb).ingress_ifindex }
    } else {
        ifindex
    }
}

fn skb_queue_mapping(ctx: &TcContext) -> u32 {
    // SAFETY: TcContext owns the `__sk_buff` pointer for the lifetime of this
    // classifier invocation; queue_mapping is scalar SKB metadata.
    unsafe { (*ctx.skb.skb).queue_mapping }
}

fn now_ns() -> u64 {
    // SAFETY: Kernel helper has no pointer arguments and is valid for TC and
    // tracing program types.
    unsafe { bpf_ktime_get_ns() }
}

fn trace_read<T: Copy>(ctx: &TracePointContext, offset: usize) -> Result<T, i64> {
    // SAFETY: Offsets match the kernel's sock/inet_sock_set_state tracepoint
    // format. The eBPF helper copies the value out and returns an error if the
    // tracepoint context cannot satisfy the read.
    unsafe { ctx.read_at(offset) }
}

#[panic_handler]
fn panic(_info: &PanicInfo<'_>) -> ! {
    loop {}
}
