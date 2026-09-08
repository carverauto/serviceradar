#![no_std]
#![no_main]

use aya_ebpf::{
    bindings::{xdp_action, BPF_ANY, TC_ACT_OK},
    helpers::{bpf_ktime_get_ns, bpf_probe_read_kernel, bpf_probe_read_kernel_buf},
    macros::{classifier, kprobe, kretprobe, map, tracepoint, xdp},
    maps::{HashMap as BpfHashMap, LruHashMap, PerCpuArray, ProgramArray, RingBuf, XskMap},
    programs::{ProbeContext, RetProbeContext, TcContext, TracePointContext, XdpContext},
    EbpfContext,
};
use core::{
    ffi::c_void,
    mem::{offset_of, size_of},
    panic::PanicInfo,
    ptr::addr_of_mut,
};

const EVENT_VERSION: u16 = 1;
const AF_INET: u16 = 2;
const AF_INET6: u16 = 10;
const IPPROTO_ICMP: u16 = 1;
const IPPROTO_TCP: u16 = 6;
const IPPROTO_UDP: u16 = 17;
const IPPROTO_ICMPV6: u16 = 58;
const ETH_P_IP: u16 = 0x0800;
const ETH_P_IPV6: u16 = 0x86dd;
const ETH_P_ARP: u16 = 0x0806;
const ETH_P_8021Q: u16 = 0x8100;
const ETH_P_8021AD: u16 = 0x88a8;
const ETH_HEADER_LEN: usize = 14;
const VLAN_HEADER_LEN: usize = 4;
// ARP payload layout (RFC 826), offsets relative to the end of the Ethernet
// header: htype(2) ptype(2) hlen(1) plen(1) oper(2) sha(6) spa(4) tha(6) tpa(4).
const ARP_OPER_OFFSET: usize = 6;
const ARP_SENDER_HA_OFFSET: usize = 8;
const ARP_SENDER_PA_OFFSET: usize = 14;
const ICMPV6_ROUTER_SOLICITATION: u8 = 133;
const ICMPV6_NEIGHBOR_ADVERTISEMENT: u8 = 136;
const ARP_OPER_REQUEST: u16 = 1;
const ARP_OPER_REPLY: u16 = 2;

// L2 observation kinds reported to userspace.
pub const L2_KIND_ARP_REQUEST: u16 = 1;
pub const L2_KIND_ARP_REPLY: u16 = 2;
pub const L2_KIND_IPV6_NDP: u16 = 4;

// L2 observation flags.
// A locally administered MAC (bit 1 of the first octet) is what every MAC
// randomization implementation sets. Classified here so userspace never has to
// re-derive it, and so identity can refuse to anchor on a rotating address.
pub const L2_FLAG_LOCALLY_ADMINISTERED: u16 = 1 << 0;
// Sender protocol address was all-zero: an RFC 5227 ARP probe. The device is
// announcing itself before it owns the address, which is the earliest possible
// sighting of a joining device.
pub const L2_FLAG_ARP_PROBE: u16 = 1 << 1;
// Sender and target protocol addresses matched: a gratuitous ARP announcement.
pub const L2_FLAG_ARP_GRATUITOUS: u16 = 1 << 2;

const IPV4_MIN_HEADER_LEN: usize = 20;
const IPV6_HEADER_LEN: usize = 40;
const TCP_MIN_HEADER_LEN: usize = 20;
const UDP_HEADER_LEN: usize = 8;
const TCP_FLAG_SYN: u8 = 0x02;
const TCP_MAX_OPTIONS_LAYOUT: usize = 32;
// p0f quirk bits emitted to userspace in TcpSynSignatureRecord.quirks. The
// userspace encoder (rust/netprobe/src/p0f_encode.rs) renders these into the
// p0f signature's quirks field; keep the bit values in sync with it.
const TCP_SYN_QUIRK_MALFORMED_OPTIONS: u32 = 1 << 0; // "bad"
const TCP_SYN_QUIRK_DF: u32 = 1 << 1; // "df": IPv4 don't-fragment set
const TCP_SYN_QUIRK_ID_PLUS: u32 = 1 << 2; // "id+": DF set but IP ID non-zero
const TCP_SYN_QUIRK_ID_MINUS: u32 = 1 << 3; // "id-": DF clear but IP ID zero
const IPV4_FLAG_DF: u16 = 0x4000;
const TCP_PAYLOAD_CLASS_EMPTY: u8 = 0;
const TCP_PAYLOAD_CLASS_NON_EMPTY: u8 = 1;

const FLOW_TABLE_ENTRIES_PER_INTERFACE: u32 = 65_536;
const FLOW_TABLE_DEFAULT_INTERFACE_SLOTS: u32 = 16;
const FLOW_TABLE_MAX_ENTRIES: u32 =
    FLOW_TABLE_ENTRIES_PER_INTERFACE * FLOW_TABLE_DEFAULT_INTERFACE_SLOTS;
const FLOW_TO_PID_MAX_ENTRIES: u32 = 1_048_576;
const SOCKET_TO_PID_MAX_ENTRIES: u32 = 1_048_576;
const PROCESS_INFO_MAX_ENTRIES: u32 = 8_192;
const INTERFACE_ALLOWLIST_MAX_ENTRIES: u32 = 1_024;
const XSK_MAX_QUEUES: u32 = 1024;
// Unchanged long-lived flow ownership is refreshed from the kernel less often
// than first/lifecycle/owner-change events. Userspace keeps these entries for
// 300s, so a 240s heartbeat preserves delayed central joins while avoiding the
// 60s ring-buffer churn that busy workers mostly coalesce downstream.
const FLOW_ATTRIBUTION_REFRESH_INTERVAL_NS: u64 = 240_000_000_000;
const FLOW_ENDPOINT_A: u8 = 1;
const FLOW_ENDPOINT_B: u8 = 2;
const EPHEMERAL_PORT_FLOOR: u16 = 32_768;

const EVENT_TCP_CONNECT: u16 = 1;
const EVENT_TCP_ACCEPT: u16 = 2;
const EVENT_TCP_CLOSE: u16 = 3;
const EVENT_UDP_SEND: u16 = 4;
const EVENT_UDP_RECV: u16 = 5;
const EVENT_INET_SOCK_SET_STATE: u16 = 6;
const EVENT_ICMP_SEND: u16 = 7;
const TCP_ESTABLISHED_STATE: i32 = 1;
const TCP_CLOSE_STATE: i32 = 7;
const TCP_LISTEN_STATE: i32 = 10;

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
const TRACE_RHEL9_LAYOUT_SHIFT: usize = 8;

// `struct sock` field reads for the kprobe attribution path.
//
// aya-ebpf 0.1.1 ships no CO-RE / vmlinux `struct sock` bindings (only BPF
// helper signatures + BPF-internal structs), and this crate has no CO-RE field
// relocation — the existing kernel-struct reads (inet_sock_set_state's
// TRACE_*_OFFSET tracepoint constants above, and the TC `__sk_buff` metadata
// reads) all use fixed offsets. We mirror that established pattern here: a
// `#[repr(C)]` SockCommon faithfully reproducing the head of `struct sock`
// (which begins with `struct sock_common __sk_common` at offset 0) so the
// compiler computes each field offset via `offset_of!` — self-documenting and
// checkable against rust/netprobe/ebpf/include/vmlinux.h rather than scattered
// magic integers. Layout is the canonical x86_64 LP64 sock_common with
// CONFIG_NET_NS=y (matches the committed vmlinux.h dump): skc_daddr@0,
// skc_rcv_saddr@4, skc_dport@12, skc_num@14, skc_family@16, skc_v6_daddr@56,
// skc_v6_rcv_saddr@72. NOTE (kernel fragility): these offsets are NOT
// CO-RE-relocated, so a kernel whose sock_common layout differs from the target
// 6.8 dump would mis-read. The userspace loader therefore validates these
// exact field offsets against `/sys/kernel/btf/vmlinux` before attaching any
// attribution probe and reports TCP attribution unavailable on a mismatch.
#[repr(C)]
struct In6Addr {
    addr: [u8; 16],
}

#[repr(C)]
struct SockCommon {
    skc_daddr: u32,            // @0  __be32 peer v4 addr (network order)
    skc_rcv_saddr: u32,        // @4  __be32 local v4 addr (network order)
    skc_hash: u32,             // @8  (union)
    skc_dport: u16,            // @12 __be16 peer port (network order)
    skc_num: u16,              // @14 local port (HOST order)
    skc_family: u16,           // @16 address family
    skc_state: u8,             // @18
    skc_flags: u8,             // @19 reuse/reuseport/ipv6only/net_refcnt bitfield byte
    skc_bound_dev_if: i32,     // @20
    skc_bind_node: [u64; 2],   // @24 hlist_node (two pointers)
    skc_prot: u64,             // @40 struct proto *
    skc_net: u64,              // @48 possible_net_t { struct net * } (CONFIG_NET_NS=y)
    skc_v6_daddr: In6Addr,     // @56 peer v6 addr
    skc_v6_rcv_saddr: In6Addr, // @72 local v6 addr
}

#[repr(C)]
struct MsgHdr {
    msg_name: *const c_void,
    msg_namelen: i32,
}

#[repr(C)]
struct SockAddrIn {
    sin_family: u16,
    sin_port: u16,
    sin_addr: u32,
    pad: [u8; 8],
}

#[repr(C)]
struct SockAddrIn6 {
    sin6_family: u16,
    sin6_port: u16,
    sin6_flowinfo: u32,
    sin6_addr: In6Addr,
    sin6_scope_id: u32,
}

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
    pub process_generation_ns: u64,
    pub old_state: i32,
    pub new_state: i32,
    pub tuple: FlowTuple,
    pub comm: [u8; 16],
}

#[repr(C)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct FlowKey {
    pub address_family: u16,
    pub transport_protocol: u16,
    pub endpoint_a_port: u16,
    pub endpoint_b_port: u16,
    pub endpoint_a_addr: [u8; 16],
    pub endpoint_b_addr: [u8; 16],
}

#[repr(C)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct FlowTableKey {
    pub interface_index: u32,
    pub reserved: u32,
    pub flow: FlowKey,
}

struct CanonicalFlowKey {
    key: FlowKey,
    source_endpoint: u8,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct FlowTableEntry {
    pub classified_as: u32,
    pub packets_seen: u64,
    pub packets_redirected: u32,
    pub reserved: u32,
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
    pub process_generation_ns: u64,
    pub old_state: i32,
    pub new_state: i32,
    pub local_endpoint: u8,
    pub reserved: [u8; 7],
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
    pub process_generation_ns: u64,
    pub comm: [u8; 16],
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct InterfaceConfig {
    pub enabled: u32,
    pub redirect_budget: u32,
    pub flags: u32,
    pub xsk_queue_count: u32,
}

// Raw TCP-SYN observation emitted to userspace. The p0f signature STRING is
// built in userspace (rust/netprobe/src/p0f_encode.rs) from these fields — the
// eBPF only parses the SYN, keeping the program cheap for the verifier. The
// explicit reserved fields give a deterministic #[repr(C)] layout (104 bytes,
// no implicit padding) that the userspace parser mirrors byte-for-byte.
#[repr(C)]
#[derive(Copy, Clone)]
pub struct TcpSynSignatureRecord {
    pub version: u16,                                 // @0
    pub ip_version: u16,                              // @2
    pub ttl: u8,                                      // @4
    pub window_scale: u8,                             // @5
    pub options_len: u8,                              // @6
    pub payload_class: u8,                            // @7
    pub source_endpoint: u8, // @8  FLOW_ENDPOINT_A/B: which endpoint sent the SYN
    pub reserved0: u8,       // @9
    pub window_size: u16,    // @10
    pub mss: u16,            // @12
    pub reserved1: u16,      // @14
    pub quirks: u32,         // @16
    pub reserved2: u32,      // @20
    pub observed_ns: u64,    // @24
    pub flow_key: FlowKey,   // @32..72
    pub options_layout: [u8; TCP_MAX_OPTIONS_LAYOUT], // @72..104
}

// Passive L2 device observation: the (MAC, IP) binding seen on the wire, plus
// enough context for userspace to decide how much to trust it. 48 bytes,
// explicit offsets because userspace decodes this from raw ring bytes.
#[repr(C)]
#[derive(Copy, Clone)]
pub struct L2ObservationRecord {
    pub version: u16,           // @0
    pub observation_kind: u16,  // @2  L2_KIND_*
    pub ip_version: u16,        // @4  4, 6, or 0 when unknown
    pub flags: u16,             // @6  L2_FLAG_*
    pub interface_index: u32,   // @8
    pub observed_ns: u64,       // @16
    pub mac: [u8; 6],           // @24
    pub reserved0: [u8; 2],     // @30
    pub ip: [u8; 16],           // @32..48
}

pub const L2_OBSERVATION_VERSION: u16 = 1;

#[map(name = "flow_events")]
static FLOW_EVENTS: RingBuf = RingBuf::pinned(1 << 20, 0);

#[map(name = "tcp_syn_signatures")]
static TCP_SYN_SIGNATURES: RingBuf = RingBuf::pinned(1 << 20, 0);

#[map(name = "l2_observations")]
static L2_OBSERVATIONS: RingBuf = RingBuf::pinned(1 << 20, 0);

// Suppression cache for the passive census. ARP is chatty and every frame
// carries a MAC, so emitting per packet would flood the ring and the ingestion
// path behind it. Keyed by (interface, MAC, IP) -> last emitted timestamp, so a
// device's FIRST sighting is always emitted and refreshes are rate limited.
// LRU so a busy segment evicts cold entries instead of failing to insert.
#[map(name = "l2_seen")]
static L2_SEEN: LruHashMap<L2SeenKey, u64> = LruHashMap::pinned(L2_SEEN_MAX_ENTRIES, 0);

// Sized for the segment, not for a round number.
//
// An LRU hash PREALLOCATES: BPF_F_NO_PREALLOC is not supported for
// BPF_MAP_TYPE_LRU_HASH, so every entry is committed at load time whether or
// not it is ever used. At 65536 this map reserved 6.5 MB to hold 14 live
// entries on a real segment -- memory an edge device does not have to spare.
//
// The key is (interface, MAC, IP), so the worst realistic case is a full /24
// where every host has several IPv6 addresses as well: 254 * ~10 = ~2500.
// 8192 keeps roughly 3x headroom over that and costs ~0.85 MB.
//
// Undersizing has a real cost, which is why the headroom is deliberate: the
// LRU evicts under pressure, an evicted binding is re-emitted, and sustained
// re-emission is exactly what the watchdog shuts the census down for.
const L2_SEEN_MAX_ENTRIES: u32 = 8192;

// Census observations the ring could not accept because it was full.
//
// Per-CPU so the increment needs no atomic and cannot contend: it is a plain
// read-modify-write of CPU-local memory. Nothing touches this on the success
// path -- it is only written from the branch where `reserve` already failed,
// so a healthy census pays exactly nothing for it.
//
// Without this counter the snapshot's `dropped_since_last` would be
// permanently zero, and an operator could not tell a quiet segment from one
// that is silently losing observations.
// mDNS announcements, payload included. Separate ring from l2_observations so a
// burst of announcements cannot starve the census, which is the signal that
// binds MAC to IP and therefore the thing mDNS enriches.
#[map(name = "mdns_observations")]
static MDNS_OBSERVATIONS: RingBuf = RingBuf::pinned(1 << 20, 0);

// Suppression for mDNS, keyed by (interface, MAC, payload hash).
//
// NOT keyed by MAC alone, which is what the census does. The census can do that
// because every ARP sighting from one binding is equivalent. mDNS packets from
// one device are NOT equivalent: a device announces its service in one packet
// and the TXT carrying its model in another, milliseconds apart. Suppressing
// per MAC would keep the first and drop exactly the record that identifies the
// device.
//
// Hashing the content instead drops what is genuinely redundant -- devices
// re-announce identical records constantly -- while letting a burst of distinct
// records through. A sender that varies its payload defeats this, which is what
// the userspace watchdog is for.
#[map(name = "mdns_seen")]
static MDNS_SEEN: LruHashMap<MdnsSeenKey, u64> = LruHashMap::pinned(MDNS_SEEN_MAX_ENTRIES, 0);

// Same reasoning as L2_SEEN. Keyed by (interface, MAC, content hash), so a
// device contributes one entry per distinct announcement it makes within the
// refresh window rather than one entry total. 8192 covers a full /24 at ~30
// distinct announcements each and costs ~0.75 MB; the map held 39 entries on a
// live segment.
const MDNS_SEEN_MAX_ENTRIES: u32 = 8192;

#[repr(C)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct MdnsSeenKey {
    pub interface_index: u32,
    pub reserved: u32,
    pub mac: [u8; 6],
    pub reserved2: [u8; 2],
    pub payload_hash: u64,
}

pub const MDNS_PORT: u16 = 5353;
pub const MDNS_RECORD_VERSION: u16 = 1;
/// Bytes of UDP payload copied per announcement.
///
/// Live capture on a real segment topped out at 473 bytes, so 512 covers what
/// is actually sent while keeping the record small enough that a 1 MiB ring
/// holds ~1800 of them. Anything longer is copied up to the cap and flagged, so
/// a receiver knows the model may be in the part that was cut rather than
/// concluding the device did not send one.
pub const MDNS_PAYLOAD_CAP: usize = 512;
pub const MDNS_FLAG_TRUNCATED: u16 = 1 << 0;
pub const MDNS_FLAG_IPV6: u16 = 1 << 1;
/// How long an identical announcement stays suppressed.
const MDNS_REFRESH_INTERVAL_NS: u64 = 60 * 1_000_000_000;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct MdnsObservationRecord {
    pub version: u16,
    pub flags: u16,
    pub payload_len: u16,
    pub reserved0: u16,
    pub interface_index: u32,
    pub reserved1: u32,
    pub observed_ns: u64,
    pub mac: [u8; 6],
    pub reserved2: [u8; 2],
    pub ip: [u8; 16],
    pub payload: [u8; MDNS_PAYLOAD_CAP],
}

#[map(name = "l2_ring_drops")]
static L2_RING_DROPS: PerCpuArray<u64> = PerCpuArray::pinned(4, 0);

// Slot 0: observations the ring could not accept because it was full.
pub const L2_STAT_RING_FULL: u32 = 0;
// Slot 1: suppression-cache inserts that failed. Non-zero here means the
// census is emitting every frame instead of one per refresh interval, which
// the userspace watchdog will shut the census down for.
pub const L2_STAT_SUPPRESS_INSERT_FAILED: u32 = 1;
// Slot 2: mDNS announcements the ring could not accept.
pub const MDNS_STAT_RING_FULL: u32 = 2;
// Slot 3: mDNS suppression inserts that failed. Non-zero means every
// announcement is re-emitted; the watchdog will shut the collector down.
pub const MDNS_STAT_SUPPRESS_INSERT_FAILED: u32 = 3;

#[repr(C)]
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct L2SeenKey {
    pub interface_index: u32,
    pub reserved: u16,
    pub mac: [u8; 6],
    pub ip: [u8; 16],
}

#[map(name = "flow_table")]
static FLOW_TABLE: LruHashMap<FlowTableKey, FlowTableEntry> =
    LruHashMap::pinned(FLOW_TABLE_MAX_ENTRIES, 0);

#[map(name = "flow_to_pid")]
static FLOW_TO_PID: LruHashMap<FlowKey, FlowPidRecord> =
    LruHashMap::pinned(FLOW_TO_PID_MAX_ENTRIES, 0);

#[map(name = "socket_to_pid")]
static SOCKET_TO_PID: LruHashMap<u64, FlowPidRecord> =
    LruHashMap::pinned(SOCKET_TO_PID_MAX_ENTRIES, 0);

#[map(name = "process_info")]
static PROCESS_INFO: BpfHashMap<u32, ProcessInfoRecord> =
    BpfHashMap::pinned(PROCESS_INFO_MAX_ENTRIES, 0);

#[map(name = "interface_allowlist")]
static INTERFACE_ALLOWLIST: BpfHashMap<u32, InterfaceConfig> =
    BpfHashMap::pinned(INTERFACE_ALLOWLIST_MAX_ENTRIES, 0);

#[map(name = "xsk_sockets")]
static XSK_SOCKETS: XskMap = XskMap::pinned(XSK_MAX_QUEUES, 0);

// Tail-call jump table. The flow-accounting classifier hands the TCP-SYN
// observation to netprobe_tc_syn_signature (index TC_TAIL_SYN_SIGNATURE) so the
// SYN parse path runs with its own fresh 512-byte BPF stack budget — combined
// with flow accounting in one program the call chain's stack exceeds the limit.
// The userspace loader populates this with that program's fd.
const TC_TAIL_SYN_SIGNATURE: u32 = 0;

#[map(name = "tc_tail_calls")]
static TC_TAIL_CALLS: ProgramArray = ProgramArray::pinned(4, 0);

#[classifier]
pub fn netprobe_tc_ingress(ctx: TcContext) -> i32 {
    // Passive device census runs on ingress only: an egress frame's source MAC
    // is this host's own, which tells us nothing about the segment. Gated on
    // the same interface allowlist as flow accounting.
    // The interface allowlist lookup is NOT done here. It is a hash map lookup,
    // and doing it per frame to serve the ~1% that are ARP/NDP is waste;
    // observe_l2_device checks it only after the cheap ethertype filter passes.
    // now_ns() is likewise deferred: bpf_ktime_get_ns is a helper call.
    observe_l2_device(&ctx);
    observe_mdns(&ctx);
    if account_flow(&ctx) {
        // The tail call MUST live in the entry program: the BPF verifier rejects
        // bpf_tail_call inside bpf-to-bpf subprograms. Falls through to TC_ACT_OK
        // if the jump table is not yet populated.
        let _ = unsafe { TC_TAIL_CALLS.tail_call(&ctx, TC_TAIL_SYN_SIGNATURE) };
    }
    TC_ACT_OK as i32
}

#[classifier]
pub fn netprobe_tc_egress(ctx: TcContext) -> i32 {
    if account_flow(&ctx) {
        let _ = unsafe { TC_TAIL_CALLS.tail_call(&ctx, TC_TAIL_SYN_SIGNATURE) };
    }
    TC_ACT_OK as i32
}

// Tail-call target of netprobe_tc_{ingress,egress}: parses the TCP SYN and emits
// the raw observation. A separate program so the verifier gives it its own
// 512-byte stack budget (the SYN parse path's deepest frame is ~376 bytes; added
// to the flow-accounting classifier's frame it exceeds the BPF stack limit).
#[classifier]
pub fn netprobe_tc_syn_signature(ctx: TcContext) -> i32 {
    if interface_config(skb_interface_index(&ctx)).is_none() {
        return TC_ACT_OK as i32;
    }
    emit_tcp_syn_signature_from_tc(&ctx, now_ns());
    TC_ACT_OK as i32
}

#[xdp]
pub fn netprobe_xdp_ingress(ctx: XdpContext) -> u32 {
    xdp_redirect_to_af_xdp(&ctx)
}

// AF_XDP/XSKMAP redirect is only legal from an XDP hook: bpf_redirect_map into an
// XSKMAP is rejected by the verifier for TC/sched_cls ("unknown func
// bpf_redirect_map#51"). Redirect each frame into the AF_XDP socket bound to the
// rx queue it arrived on; the userspace loader registers one XSK per rx queue
// keyed by rx_queue_index, so the redirect key MUST be rx_queue_index (a flow
// hash cannot pick the kernel's delivery queue).
#[inline(always)]
fn xdp_redirect_to_af_xdp(ctx: &XdpContext) -> u32 {
    // SAFETY: ingress_ifindex/rx_queue_index are scalar xdp_md metadata valid for
    // the XDP context lifetime. Deny-by-default for interfaces not in the allowlist.
    let interface_index = unsafe { (*ctx.ctx).ingress_ifindex };
    if interface_config(interface_index).is_none() {
        return xdp_action::XDP_PASS;
    }
    let queue_id = unsafe { (*ctx.ctx).rx_queue_index };
    XSK_SOCKETS
        .redirect(queue_id, xdp_action::XDP_PASS as u64)
        .unwrap_or(xdp_action::XDP_PASS)
}

#[kprobe(function = "tcp_connect")]
pub fn tcp_connect(ctx: ProbeContext) -> u32 {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return 0;
    };

    remember_current_socket_owner(&ctx, EVENT_TCP_CONNECT, sock, 0, 0);

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

    remember_current_socket_owner(&ctx, EVENT_TCP_ACCEPT, sock, 0, 0);

    if let Some(tuple) = socket_tuple(sock, IPPROTO_TCP, true) {
        if !tuple_destination_is_zero(&tuple) {
            emit_event(&ctx, EVENT_TCP_ACCEPT, sock, tuple, 0, 0);
        }
    }

    0
}

#[kprobe(function = "tcp_close")]
pub fn tcp_close(ctx: ProbeContext) -> u32 {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return 0;
    };

    if let Some(tuple) = socket_tuple(sock, IPPROTO_TCP, true) {
        if !tuple_destination_is_zero(&tuple) {
            // Use the cached socket owner because tcp_close may run outside the
            // owning task. The close helper snapshots the owner and then evicts
            // both the actual attribution gate key and socket key before it can
            // return, even when the ring is full. If the tracepoint also fires,
            // its later duplicate has no cached owner and is suppressed.
            emit_event_with_cached_owner(&ctx, EVENT_TCP_CLOSE, sock, tuple, 0, 0);
        }
    }
    remove_socket_pid_by_address(sock as u64);

    0
}

#[kprobe(function = "udp_sendmsg")]
pub fn udp_sendmsg(ctx: ProbeContext) -> u32 {
    emit_udp(&ctx, EVENT_UDP_SEND);
    0
}

#[kprobe(function = "udp_recvmsg")]
pub fn udp_recvmsg(ctx: ProbeContext) -> u32 {
    emit_udp(&ctx, EVENT_UDP_RECV);
    0
}

// IPv6 UDP traverses udpv6_sendmsg/udpv6_recvmsg, NOT the v4 udp_* path — so v4-only
// hooks miss UDP-over-IPv6 entirely. socket_tuple reads the address family off the
// socket, so the same helper yields an AF_INET6 v6 tuple here.
#[kprobe(function = "udpv6_sendmsg")]
pub fn udpv6_sendmsg(ctx: ProbeContext) -> u32 {
    emit_udp(&ctx, EVENT_UDP_SEND);
    0
}

#[kprobe(function = "udpv6_recvmsg")]
pub fn udpv6_recvmsg(ctx: ProbeContext) -> u32 {
    emit_udp(&ctx, EVENT_UDP_RECV);
    0
}

#[inline(always)]
fn emit_udp(ctx: &ProbeContext, event_kind: u16) {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return;
    };
    // Read the real 5-tuple off the struct sock (arg0) instead of an empty tuple
    // (the bug that made fpa 100% TCP). socket_tuple reads the family, so this
    // serves both v4 (udp_*) and v6 (udpv6_*). Unreadable/empty tuples are dropped
    // in userspace anyway (flow_key_from_record).
    let Some(mut tuple) = socket_tuple(sock, IPPROTO_UDP, true) else {
        return;
    };
    if event_kind == EVENT_UDP_SEND {
        if let Some(msg) = ctx.arg::<*const c_void>(1) {
            let _ = apply_msg_name_destination(&mut tuple, msg, true);
        }
    }
    if tuple_destination_is_zero(&tuple) {
        return;
    }
    emit_event(ctx, event_kind, sock, tuple, 0, 0);
}

// ICMP echo (ping) attribution. The unprivileged ping path uses a dgram ICMP
// socket whose sendmsg is ping_sendmsg (ping_v4_sendmsg in older kernels);
// raw_sendmsg covers privileged raw ICMP sockets (e.g. classic setuid ping,
// `ping -s`, hping). Both take `struct sock *` as arg0, so socket_tuple reads
// the same sock_common head. ICMP has no ports, so we pass has_ports=false and
// emit ports=0 — userspace accepts proto 1 with zero ports.
// On modern kernels (incl. 6.8) the unprivileged dgram ICMP socket sendmsg is
// `ping_v4_sendmsg`; older kernels exposed `ping_sendmsg`. Attach is best-effort
// (see ebpf_runtime), so an absent symbol just warns. raw_sendmsg covers the
// privileged raw-ICMP path (e.g. setuid `ping`).
#[kprobe(function = "ping_v4_sendmsg")]
pub fn ping_v4_sendmsg(ctx: ProbeContext) -> u32 {
    emit_icmp_send(&ctx);
    0
}

#[kprobe(function = "raw_sendmsg")]
pub fn raw_sendmsg(ctx: ProbeContext) -> u32 {
    // raw_sendmsg also carries non-ICMP raw sockets (e.g. OSPF proto 89). Only
    // attribute IPv4/IPv6 ICMP raw sockets; socket_tuple still records the local
    // endpoint, and the protocol is forced to IPPROTO_ICMP for the flow key.
    emit_icmp_send(&ctx);
    0
}

// ICMPv6: the dgram ICMPv6 socket sendmsg is `ping_v6_sendmsg`; `rawv6_sendmsg`
// covers raw IPv6 (incl raw ICMPv6). Both take `struct sock *` as arg0. Attach is
// best-effort (see ebpf_runtime).
#[kprobe(function = "ping_v6_sendmsg")]
pub fn ping_v6_sendmsg(ctx: ProbeContext) -> u32 {
    emit_icmp_send(&ctx);
    0
}

#[kprobe(function = "rawv6_sendmsg")]
pub fn rawv6_sendmsg(ctx: ProbeContext) -> u32 {
    emit_icmp_send(&ctx);
    0
}

#[inline(always)]
fn emit_icmp_send(ctx: &ProbeContext) {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return;
    };
    // socket_tuple reads the address family; derive ICMP (v4) vs ICMPv6 (v6) from
    // it so the protocol stays consistent with the addresses (ping_v4/raw_sendmsg
    // -> AF_INET, ping_v6/rawv6_sendmsg -> AF_INET6). ICMP has no ports.
    let Some(mut tuple) = socket_tuple(sock, IPPROTO_ICMP, false) else {
        return;
    };
    if tuple.family == AF_INET6 {
        tuple.protocol = IPPROTO_ICMPV6;
    }
    if let Some(msg) = ctx.arg::<*const c_void>(1) {
        let _ = apply_msg_name_destination(&mut tuple, msg, false);
    }
    if tuple_destination_is_zero(&tuple) {
        return;
    }
    emit_event(ctx, EVENT_ICMP_SEND, sock, tuple, 0, 0);
}

#[tracepoint(name = "inet_sock_set_state", category = "sock")]
pub fn inet_sock_set_state(ctx: TracePointContext) -> u32 {
    emit_inet_sock_set_state::<0>(&ctx)
}

// RHEL/Alma 9's 5.14 tracepoint carries a 16-byte common header, while the
// Ubuntu 6.8 layout used by the original program carries an 8-byte header.
// Userspace validates the live tracefs field offsets and attaches exactly one
// of these programs; unsupported layouts fail startup as TCP-unavailable.
#[tracepoint(name = "inet_sock_set_state_rhel9", category = "sock")]
pub fn inet_sock_set_state_rhel9(ctx: TracePointContext) -> u32 {
    emit_inet_sock_set_state::<TRACE_RHEL9_LAYOUT_SHIFT>(&ctx)
}

#[inline(always)]
fn emit_inet_sock_set_state<const SHIFT: usize>(ctx: &TracePointContext) -> u32 {
    let Ok(sock) = trace_read::<*const c_void>(ctx, TRACE_SKADDR_OFFSET + SHIFT) else {
        return 0;
    };
    let Ok(old_state) = trace_read::<i32>(ctx, TRACE_OLDSTATE_OFFSET + SHIFT) else {
        return 0;
    };
    let Ok(new_state) = trace_read::<i32>(ctx, TRACE_NEWSTATE_OFFSET + SHIFT) else {
        return 0;
    };
    let Ok(family) = trace_read::<u16>(ctx, TRACE_FAMILY_OFFSET + SHIFT) else {
        return 0;
    };
    let Ok(protocol) = trace_read::<u16>(ctx, TRACE_PROTOCOL_OFFSET + SHIFT) else {
        return 0;
    };
    let Ok(source_port) = trace_read::<u16>(ctx, TRACE_SPORT_OFFSET + SHIFT) else {
        return 0;
    };
    let Ok(destination_port) = trace_read::<u16>(ctx, TRACE_DPORT_OFFSET + SHIFT) else {
        return 0;
    };

    if protocol != IPPROTO_TCP {
        return 0;
    }
    if new_state != TCP_ESTABLISHED_STATE
        && new_state != TCP_CLOSE_STATE
        && new_state != TCP_LISTEN_STATE
    {
        return 0;
    }

    let mut tuple = FlowTuple::empty(protocol);
    tuple.family = family;
    tuple.source_port = source_port;
    tuple.destination_port = destination_port;

    if family == AF_INET {
        let Ok(source_addr) = trace_read::<[u8; 4]>(ctx, TRACE_SADDR_V4_OFFSET + SHIFT) else {
            return 0;
        };
        let Ok(destination_addr) = trace_read::<[u8; 4]>(ctx, TRACE_DADDR_V4_OFFSET + SHIFT) else {
            return 0;
        };
        tuple.source_addr[..4].copy_from_slice(&source_addr);
        tuple.destination_addr[..4].copy_from_slice(&destination_addr);
    } else if family == AF_INET6 {
        let Ok(source_addr) = trace_read::<[u8; 16]>(ctx, TRACE_SADDR_V6_OFFSET + SHIFT) else {
            return 0;
        };
        let Ok(destination_addr) = trace_read::<[u8; 16]>(ctx, TRACE_DADDR_V6_OFFSET + SHIFT) else {
            return 0;
        };
        tuple.source_addr = source_addr;
        tuple.destination_addr = destination_addr;
    } else {
        return 0;
    }

    emit_event_with_cached_owner(
        ctx,
        EVENT_INET_SOCK_SET_STATE,
        sock,
        tuple,
        old_state,
        new_state,
    );
    0
}

#[tracepoint(name = "sched_process_exec", category = "sched")]
pub fn sched_process_exec(ctx: TracePointContext) -> u32 {
    record_current_process_generation(&ctx, now_ns());
    0
}

#[tracepoint(name = "sched_process_exit", category = "sched")]
pub fn sched_process_exit(ctx: TracePointContext) -> u32 {
    let _ = PROCESS_INFO.remove(&ctx.tgid());
    0
}

// Read a single field of `struct sock` at its (compile-time) offset via the
// kernel probe-read helper. The kprobe arg0 is a `struct sock *`; bpf_probe_read_kernel
// returns Err if the read faults, which the callers propagate so a bad pointer
// drops the record instead of emitting garbage.
#[inline(always)]
unsafe fn sock_field<T>(sock: *const c_void, offset: usize) -> Option<T> {
    kernel_field(sock, offset)
}

// Read a single field at a fixed offset from a kernel pointer. The caller must
// pass a kernel pointer whose layout matches the mirrored #[repr(C)] type used
// to compute `offset`.
#[inline(always)]
unsafe fn kernel_field<T>(ptr: *const c_void, offset: usize) -> Option<T> {
    if ptr.is_null() {
        return None;
    }
    bpf_probe_read_kernel((ptr as *const u8).add(offset) as *const T).ok()
}

// Read bytes from a kernel pointer into caller-provided storage. This avoids
// materializing temporary address arrays on the eBPF stack for sockaddr reads.
#[inline(always)]
unsafe fn kernel_bytes(ptr: *const c_void, offset: usize, dst: &mut [u8]) -> Option<()> {
    if ptr.is_null() {
        return None;
    }
    bpf_probe_read_kernel_buf((ptr as *const u8).add(offset), dst).ok()
}

// Build a populated FlowTuple from a `struct sock *` (kprobe arg0) for the
// connection-less protocols (UDP, ICMP) whose per-call kprobes have no
// tracepoint to read a ready-made 5-tuple from. The tuple is directional with
// the LOCAL socket as the source (skc_rcv_saddr/skc_num) and the peer as the
// destination (skc_daddr/skc_dport) — matching attributed_flow_from_record in
// userspace, which treats the record's source as endpoint A (local).
//
// Ports: skc_num is the local port in HOST byte order; skc_dport is the peer
// port in NETWORK byte order. The userspace consumer stores these directly into
// a FlowKey (no further byte-swap), so we normalize skc_dport to host order here
// to match the host-order skc_num and the host-order ports the inet_sock_set_state
// tracepoint path already emits. For ICMP (no ports) the caller passes 0/0.
#[inline(always)]
fn socket_tuple(sock: *const c_void, protocol: u16, has_ports: bool) -> Option<FlowTuple> {
    if sock.is_null() {
        return None;
    }
    // SAFETY: `sock` is the kprobe's `struct sock *` arg; each read goes through
    // bpf_probe_read_kernel (returns Err, mapped to None, on fault). Offsets are
    // derived from the SockCommon mirror via offset_of! (see SockCommon docs).
    let family: u16 = unsafe { sock_field(sock, offset_of!(SockCommon, skc_family))? };
    if family != AF_INET && family != AF_INET6 {
        return None;
    }

    let mut tuple = FlowTuple::empty(protocol);
    tuple.family = family;

    if has_ports {
        // skc_num: local port, host order. skc_dport: peer port, network order.
        let source_port: u16 = unsafe { sock_field(sock, offset_of!(SockCommon, skc_num))? };
        let destination_port_be: u16 =
            unsafe { sock_field(sock, offset_of!(SockCommon, skc_dport))? };
        tuple.source_port = source_port;
        tuple.destination_port = u16::from_be(destination_port_be);
    }

    if family == AF_INET {
        // skc_rcv_saddr = local v4, skc_daddr = peer v4 (both network order, which
        // is the wire/byte order the userspace Ipv4Addr::new consumer expects).
        // SAFETY: sock is the kprobe's kernel struct sock pointer; offsets are
        // derived from the SockCommon mirror, and reads fail closed on fault.
        unsafe {
            kernel_bytes(
                sock,
                offset_of!(SockCommon, skc_rcv_saddr),
                &mut tuple.source_addr[..4],
            )?;
            kernel_bytes(
                sock,
                offset_of!(SockCommon, skc_daddr),
                &mut tuple.destination_addr[..4],
            )?;
        }
        clear_ipv4_tail(&mut tuple.source_addr);
        clear_ipv4_tail(&mut tuple.destination_addr);
    } else {
        // SAFETY: sock is the kprobe's kernel struct sock pointer; offsets are
        // derived from the SockCommon mirror, and reads fail closed on fault.
        unsafe {
            kernel_bytes(
                sock,
                offset_of!(SockCommon, skc_v6_rcv_saddr),
                &mut tuple.source_addr,
            )?;
            kernel_bytes(
                sock,
                offset_of!(SockCommon, skc_v6_daddr),
                &mut tuple.destination_addr,
            )?;
        }
    }

    Some(tuple)
}

#[inline(always)]
fn apply_msg_name_destination(
    tuple: &mut FlowTuple,
    msg: *const c_void,
    has_ports: bool,
) -> Option<()> {
    if msg.is_null() {
        return None;
    }

    // SAFETY: msg is kprobe arg1 for *_sendmsg, a kernel `struct msghdr *`.
    // Reads are bounded to the mirrored field offsets and fail closed on fault.
    let name: *const c_void = unsafe { kernel_field(msg, offset_of!(MsgHdr, msg_name))? };
    let name_len: i32 = unsafe { kernel_field(msg, offset_of!(MsgHdr, msg_namelen))? };
    if name.is_null() {
        return None;
    }

    // SAFETY: name is msghdr->msg_name, a kernel sockaddr pointer when present.
    // Reading the family first lets us select the sockaddr shape before copying
    // address/port fields.
    let family: u16 = unsafe { kernel_field(name, 0)? };
    if family != tuple.family {
        return None;
    }

    if family == AF_INET {
        if name_len < size_of::<SockAddrIn>() as i32 {
            return None;
        }
        // SAFETY: name points at a kernel sockaddr_in with msg_namelen already
        // checked; read only the in-struct IPv4 address bytes into the tuple.
        unsafe {
            kernel_bytes(
                name,
                offset_of!(SockAddrIn, sin_addr),
                &mut tuple.destination_addr[..4],
            )?
        };
        clear_ipv4_tail(&mut tuple.destination_addr);
        if has_ports {
            let port_be: u16 = unsafe { kernel_field(name, offset_of!(SockAddrIn, sin_port))? };
            tuple.destination_port = u16::from_be(port_be);
        }
        Some(())
    } else if family == AF_INET6 {
        if name_len < size_of::<SockAddrIn6>() as i32 {
            return None;
        }
        // SAFETY: name points at a kernel sockaddr_in6 with msg_namelen already
        // checked; read only the in-struct IPv6 address bytes into the tuple.
        unsafe {
            kernel_bytes(
                name,
                offset_of!(SockAddrIn6, sin6_addr),
                &mut tuple.destination_addr,
            )?
        };
        if has_ports {
            let port_be: u16 = unsafe { kernel_field(name, offset_of!(SockAddrIn6, sin6_port))? };
            tuple.destination_port = u16::from_be(port_be);
        }
        Some(())
    } else {
        None
    }
}

#[inline(always)]
fn clear_ipv4_tail(addr: &mut [u8; 16]) {
    addr[4] = 0;
    addr[5] = 0;
    addr[6] = 0;
    addr[7] = 0;
    addr[8] = 0;
    addr[9] = 0;
    addr[10] = 0;
    addr[11] = 0;
    addr[12] = 0;
    addr[13] = 0;
    addr[14] = 0;
    addr[15] = 0;
}

#[inline(always)]
fn tuple_destination_is_zero(tuple: &FlowTuple) -> bool {
    if tuple.family == AF_INET {
        tuple.destination_addr[0] == 0
            && tuple.destination_addr[1] == 0
            && tuple.destination_addr[2] == 0
            && tuple.destination_addr[3] == 0
    } else if tuple.family == AF_INET6 {
        tuple.destination_addr[0] == 0
            && tuple.destination_addr[1] == 0
            && tuple.destination_addr[2] == 0
            && tuple.destination_addr[3] == 0
            && tuple.destination_addr[4] == 0
            && tuple.destination_addr[5] == 0
            && tuple.destination_addr[6] == 0
            && tuple.destination_addr[7] == 0
            && tuple.destination_addr[8] == 0
            && tuple.destination_addr[9] == 0
            && tuple.destination_addr[10] == 0
            && tuple.destination_addr[11] == 0
            && tuple.destination_addr[12] == 0
            && tuple.destination_addr[13] == 0
            && tuple.destination_addr[14] == 0
            && tuple.destination_addr[15] == 0
    } else {
        true
    }
}

fn emit_event(
    ctx: &impl EbpfContext,
    event_kind: u16,
    sock: *const c_void,
    tuple: FlowTuple,
    old_state: i32,
    new_state: i32,
) {
    let Some(canonical_flow) = flow_key_from_tuple(&tuple) else {
        return;
    };
    let now = now_ns();
    let socket_address = sock as u64;
    let close_event = is_close_event(event_kind, new_state);
    let gate_flow_key = attribution_gate_flow_key(&canonical_flow);
    // Prefer socket owner map (filled at connect/accept). Only fall back to the
    // current task when it has a non-zero pid — never attribute process identity
    // from the idle task (pid 0 / swapper) or other zero-pid contexts.
    let cached_owner = cached_owner_for_event(&gate_flow_key, socket_address);
    if close_event {
        // Cleanup is a lifecycle invariant, not a side effect of successful
        // publication. Remove the exact key that non-close emission stored and
        // the socket owner before any owner-miss or ring-reservation return.
        remove_flow_pid_by_key(&gate_flow_key);
        remove_socket_pid_by_address(socket_address);
    }
    let owner_record = if let Some(owner) = cached_owner {
        owner_pid_record(
            owner,
            event_kind,
            socket_address,
            now,
            old_state,
            new_state,
            canonical_flow.source_endpoint,
        )
    } else {
        let current = current_pid_record(
            ctx,
            event_kind,
            socket_address,
            now,
            old_state,
            new_state,
            canonical_flow.source_endpoint,
        );
        if is_valid_process_owner_ids(current.pid, current.tgid) {
            current
        } else {
            empty_process_owner_record(
                event_kind,
                socket_address,
                now,
                old_state,
                new_state,
                canonical_flow.source_endpoint,
            )
        }
    };
    if !close_event && !should_emit_flow_event(&gate_flow_key, &owner_record, now) {
        return;
    }

    let Some(mut entry) = FLOW_EVENTS.reserve::<FlowAttributionRecord>(0) else {
        return;
    };
    let record = entry.as_mut_ptr();
    // Comm must match the process owner, not the currently running CPU task.
    let comm = if is_valid_process_owner_ids(owner_record.pid, owner_record.tgid) {
        process_comm(owner_record.tgid).unwrap_or_else(|| ctx.command().unwrap_or([0; 16]))
    } else {
        [0u8; 16]
    };

    // SAFETY: `record` points to a freshly reserved ring-buffer slot for a
    // FlowAttributionRecord. Every field is written before the slot is submitted.
    unsafe {
        addr_of_mut!((*record).version).write(EVENT_VERSION);
        addr_of_mut!((*record).event_kind).write(event_kind);
        addr_of_mut!((*record).pid).write(owner_record.pid);
        addr_of_mut!((*record).tgid).write(owner_record.tgid);
        addr_of_mut!((*record).uid).write(owner_record.uid);
        addr_of_mut!((*record).gid).write(owner_record.gid);
        addr_of_mut!((*record).socket_address).write(socket_address);
        addr_of_mut!((*record).process_generation_ns).write(owner_record.process_generation_ns);
        addr_of_mut!((*record).old_state).write(old_state);
        addr_of_mut!((*record).new_state).write(new_state);
        addr_of_mut!((*record).tuple).write(tuple);
        addr_of_mut!((*record).comm).write(comm);
    }

    // SAFETY: All fields were initialized above and the ring-buffer slot is not
    // submitted until after the map updates finish.
    let record_ref = unsafe { &*record };
    if !close_event {
        if is_valid_process_owner_ids(owner_record.pid, owner_record.tgid) {
            record_process_info(record_ref, now);
            record_flow_pid_by_key(&gate_flow_key, &owner_record);
            record_socket_pid_by_address(socket_address, &owner_record);
        }
    }

    entry.submit(0);
}

fn emit_event_with_cached_owner(
    ctx: &impl EbpfContext,
    event_kind: u16,
    sock: *const c_void,
    tuple: FlowTuple,
    old_state: i32,
    new_state: i32,
) {
    let Some(canonical_flow) = flow_key_from_tuple(&tuple) else {
        return;
    };
    let now = now_ns();
    let socket_address = sock as u64;
    let close_event = is_close_event(event_kind, new_state);
    let gate_flow_key = attribution_gate_flow_key(&canonical_flow);
    let cached_owner = cached_owner_for_event(&gate_flow_key, socket_address);
    if close_event {
        // Snapshot above, then unconditionally evict before any early return.
        // In particular, a missing owner or full ring must never retain a stale
        // service-coalesced gate entry and suppress a later socket reuse.
        remove_flow_pid_by_key(&gate_flow_key);
        remove_socket_pid_by_address(socket_address);
    }
    // State-change hooks often run in softirq / idle context. Process identity
    // MUST come from the socket owner map only — never invent it from the
    // currently scheduled task (that produces swapper/ksoftirq false owners).
    let owner_record = if let Some(owner) = cached_owner {
        if is_valid_process_owner_ids(owner.pid, owner.tgid) {
            owner_pid_record(
                owner,
                event_kind,
                socket_address,
                now,
                old_state,
                new_state,
                canonical_flow.source_endpoint,
            )
        } else {
            empty_process_owner_record(
                event_kind,
                socket_address,
                now,
                old_state,
                new_state,
                canonical_flow.source_endpoint,
            )
        }
    } else if close_event {
        return;
    } else {
        empty_process_owner_record(
            event_kind,
            socket_address,
            now,
            old_state,
            new_state,
            canonical_flow.source_endpoint,
        )
    };

    if !close_event && !should_emit_flow_event(&gate_flow_key, &owner_record, now) {
        return;
    }

    let Some(mut entry) = FLOW_EVENTS.reserve::<FlowAttributionRecord>(0) else {
        return;
    };
    let record = entry.as_mut_ptr();
    let comm = if is_valid_process_owner_ids(owner_record.pid, owner_record.tgid) {
        process_comm(owner_record.tgid).unwrap_or([0; 16])
    } else {
        [0u8; 16]
    };

    // SAFETY: `record` points to a freshly reserved ring-buffer slot for a
    // FlowAttributionRecord. Every field is written before the slot is submitted.
    unsafe {
        addr_of_mut!((*record).version).write(EVENT_VERSION);
        addr_of_mut!((*record).event_kind).write(event_kind);
        addr_of_mut!((*record).pid).write(owner_record.pid);
        addr_of_mut!((*record).tgid).write(owner_record.tgid);
        addr_of_mut!((*record).uid).write(owner_record.uid);
        addr_of_mut!((*record).gid).write(owner_record.gid);
        addr_of_mut!((*record).socket_address).write(socket_address);
        addr_of_mut!((*record).process_generation_ns).write(owner_record.process_generation_ns);
        addr_of_mut!((*record).old_state).write(old_state);
        addr_of_mut!((*record).new_state).write(new_state);
        addr_of_mut!((*record).tuple).write(tuple);
        addr_of_mut!((*record).comm).write(comm);
    }

    // SAFETY: All fields were initialized above and the ring-buffer slot is not
    // submitted until after the map updates finish.
    let record_ref = unsafe { &*record };
    if !close_event && is_valid_process_owner_ids(owner_record.pid, owner_record.tgid) {
        record_process_info(record_ref, now);
        record_flow_pid_by_key(&gate_flow_key, &owner_record);
    }

    entry.submit(0);
}

fn remember_current_socket_owner(
    ctx: &impl EbpfContext,
    event_kind: u16,
    sock: *const c_void,
    old_state: i32,
    new_state: i32,
) {
    let now = now_ns();
    let socket_address = sock as u64;
    let owner = current_pid_record(
        ctx,
        event_kind,
        socket_address,
        now,
        old_state,
        new_state,
        0,
    );
    // Never bind a socket to idle/zero-pid context — that permanently poisons
    // later state-change attribution for the socket.
    if !is_valid_process_owner_ids(owner.pid, owner.tgid) {
        return;
    }
    record_pid_process_info(&owner, ctx.command().unwrap_or([0; 16]), now);
    record_socket_pid_by_address(socket_address, &owner);
}

/// Process ids that can own a userspace socket. Pid 0 is the idle task
/// (`swapper/*`); never treat it as a socket owner.
#[inline(always)]
fn is_valid_process_owner_ids(pid: u32, tgid: u32) -> bool {
    pid != 0 && tgid != 0
}

#[inline(always)]
fn empty_process_owner_record(
    event_kind: u16,
    socket_address: u64,
    now: u64,
    old_state: i32,
    new_state: i32,
    local_endpoint: u8,
) -> FlowPidRecord {
    FlowPidRecord {
        version: EVENT_VERSION,
        event_kind,
        pid: 0,
        tgid: 0,
        uid: 0,
        gid: 0,
        socket_address,
        last_seen_ns: now,
        process_generation_ns: 0,
        old_state,
        new_state,
        local_endpoint,
        reserved: [0; 7],
    }
}

#[inline(always)]
fn current_pid_record(
    ctx: &impl EbpfContext,
    event_kind: u16,
    socket_address: u64,
    now: u64,
    old_state: i32,
    new_state: i32,
    local_endpoint: u8,
) -> FlowPidRecord {
    let tgid = ctx.tgid();
    FlowPidRecord {
        version: EVENT_VERSION,
        event_kind,
        pid: ctx.pid(),
        tgid,
        uid: ctx.uid(),
        gid: ctx.gid(),
        socket_address,
        last_seen_ns: now,
        process_generation_ns: process_generation_ns(tgid).unwrap_or(now),
        old_state,
        new_state,
        local_endpoint,
        reserved: [0; 7],
    }
}

#[inline(always)]
fn owner_pid_record(
    owner: FlowPidRecord,
    event_kind: u16,
    socket_address: u64,
    now: u64,
    old_state: i32,
    new_state: i32,
    local_endpoint: u8,
) -> FlowPidRecord {
    FlowPidRecord {
        version: EVENT_VERSION,
        event_kind,
        pid: owner.pid,
        tgid: owner.tgid,
        uid: owner.uid,
        gid: owner.gid,
        socket_address,
        last_seen_ns: now,
        process_generation_ns: owner.process_generation_ns,
        old_state,
        new_state,
        local_endpoint,
        reserved: [0; 7],
    }
}

#[inline(always)]
fn cached_owner_for_event(flow: &FlowKey, socket_address: u64) -> Option<FlowPidRecord> {
    if let Some(owner) = cached_flow_pid_by_key(flow, socket_address) {
        return Some(owner);
    }

    cached_socket_pid_by_address(socket_address)
}

#[inline(always)]
fn cached_flow_pid_by_key(flow: &FlowKey, socket_address: u64) -> Option<FlowPidRecord> {
    let owner = unsafe { FLOW_TO_PID.get(flow) }.copied()?;
    if owner.socket_address == socket_address || owner.socket_address == 0 || socket_address == 0 {
        Some(owner)
    } else {
        None
    }
}

#[inline(always)]
fn cached_socket_pid_by_address(socket_address: u64) -> Option<FlowPidRecord> {
    if socket_address == 0 {
        return None;
    }

    unsafe { SOCKET_TO_PID.get(&socket_address) }.copied()
}

fn should_emit_flow_event(flow: &FlowKey, next: &FlowPidRecord, now: u64) -> bool {
    let Some(previous) = (unsafe { FLOW_TO_PID.get(flow) }) else {
        return true;
    };

    if previous.pid != next.pid
        || previous.tgid != next.tgid
        || previous.uid != next.uid
        || previous.gid != next.gid
        || previous.process_generation_ns != next.process_generation_ns
    {
        return true;
    }

    if should_emit_lifecycle_change(previous, next) {
        return true;
    }

    now.saturating_sub(previous.last_seen_ns) >= FLOW_ATTRIBUTION_REFRESH_INTERVAL_NS
}

#[inline(always)]
fn should_emit_lifecycle_change(previous: &FlowPidRecord, next: &FlowPidRecord) -> bool {
    if next.event_kind != EVENT_INET_SOCK_SET_STATE {
        return false;
    }

    if next.new_state != TCP_LISTEN_STATE && previous.new_state != TCP_LISTEN_STATE {
        return false;
    }

    previous.event_kind != next.event_kind
        || previous.old_state != next.old_state
        || previous.new_state != next.new_state
}

#[inline(always)]
fn is_close_event(event_kind: u16, new_state: i32) -> bool {
    event_kind == EVENT_TCP_CLOSE
        || (event_kind == EVENT_INET_SOCK_SET_STATE && new_state == TCP_CLOSE_STATE)
}

fn record_process_info(record: &FlowAttributionRecord, now: u64) {
    let owner = FlowPidRecord {
        version: EVENT_VERSION,
        event_kind: record.event_kind,
        pid: record.pid,
        tgid: record.tgid,
        uid: record.uid,
        gid: record.gid,
        socket_address: record.socket_address,
        last_seen_ns: now,
        process_generation_ns: record.process_generation_ns,
        old_state: record.old_state,
        new_state: record.new_state,
        local_endpoint: 0,
        reserved: [0; 7],
    };

    record_pid_process_info(&owner, record.comm, now);
}

fn record_pid_process_info(owner: &FlowPidRecord, comm: [u8; 16], now: u64) {
    let process = ProcessInfoRecord {
        version: EVENT_VERSION,
        reserved: 0,
        pid: owner.pid,
        tgid: owner.tgid,
        uid: owner.uid,
        gid: owner.gid,
        last_seen_ns: now,
        process_generation_ns: owner.process_generation_ns,
        comm,
    };

    let _ = PROCESS_INFO.insert(&owner.tgid, &process, BPF_ANY as u64);
}

fn record_current_process_generation(ctx: &impl EbpfContext, process_generation_ns: u64) {
    let process = ProcessInfoRecord {
        version: EVENT_VERSION,
        reserved: 0,
        pid: ctx.pid(),
        tgid: ctx.tgid(),
        uid: ctx.uid(),
        gid: ctx.gid(),
        last_seen_ns: now_ns(),
        process_generation_ns,
        comm: ctx.command().unwrap_or([0; 16]),
    };

    let _ = PROCESS_INFO.insert(&process.tgid, &process, BPF_ANY as u64);
}

fn process_generation_ns(tgid: u32) -> Option<u64> {
    // SAFETY: The pointer returned by the BPF map lookup is valid for this BPF
    // invocation only. Copy the scalar generation value immediately.
    unsafe { PROCESS_INFO.get(&tgid) }
        .map(|record| record.process_generation_ns)
        .filter(|generation| *generation != 0)
}

fn process_comm(tgid: u32) -> Option<[u8; 16]> {
    unsafe { PROCESS_INFO.get(&tgid) }.map(|record| record.comm)
}

fn record_flow_pid_by_key(flow: &FlowKey, pid: &FlowPidRecord) {
    let _ = FLOW_TO_PID.insert(flow, pid, BPF_ANY as u64);
}

fn remove_flow_pid_by_key(flow: &FlowKey) {
    let _ = FLOW_TO_PID.remove(flow);
}

fn record_socket_pid_by_address(socket_address: u64, pid: &FlowPidRecord) {
    if socket_address == 0 {
        return;
    }

    let _ = SOCKET_TO_PID.insert(&socket_address, pid, BPF_ANY as u64);
}

fn remove_socket_pid_by_address(socket_address: u64) {
    if socket_address == 0 {
        return;
    }

    let _ = SOCKET_TO_PID.remove(&socket_address);
}

#[inline(always)]
fn flow_key_from_tuple(tuple: &FlowTuple) -> Option<CanonicalFlowKey> {
    if tuple.family != AF_INET && tuple.family != AF_INET6 {
        return None;
    }
    if tuple.protocol != IPPROTO_TCP
        && tuple.protocol != IPPROTO_UDP
        && tuple.protocol != IPPROTO_ICMP
        && tuple.protocol != IPPROTO_ICMPV6
    {
        return None;
    }

    Some(canonical_flow_key(
        tuple.family,
        tuple.protocol,
        tuple.source_addr,
        tuple.destination_addr,
        tuple.source_port,
        tuple.destination_port,
    ))
}

#[inline(always)]
fn attribution_gate_flow_key(flow: &CanonicalFlowKey) -> FlowKey {
    let mut key = flow.key;

    if should_coalesce_udp_client_gate(flow) {
        if flow.source_endpoint == FLOW_ENDPOINT_A {
            key.endpoint_a_port = 0;
        } else {
            key.endpoint_b_port = 0;
        }
        return key;
    }

    if should_coalesce_service_gate(flow) {
        if flow.source_endpoint == FLOW_ENDPOINT_A {
            key.endpoint_b_port = 0;
            key.endpoint_b_addr = [0; 16];
        } else {
            key.endpoint_a_port = 0;
            key.endpoint_a_addr = [0; 16];
        }
    }

    key
}

#[inline(always)]
fn should_coalesce_udp_client_gate(flow: &CanonicalFlowKey) -> bool {
    if flow.key.transport_protocol != IPPROTO_UDP {
        return false;
    }

    let (local_port, peer_port) = if flow.source_endpoint == FLOW_ENDPOINT_A {
        (flow.key.endpoint_a_port, flow.key.endpoint_b_port)
    } else {
        (flow.key.endpoint_b_port, flow.key.endpoint_a_port)
    };

    local_port >= EPHEMERAL_PORT_FLOOR && peer_port > 0 && peer_port < EPHEMERAL_PORT_FLOOR
}

#[inline(always)]
fn should_coalesce_service_gate(flow: &CanonicalFlowKey) -> bool {
    if flow.key.transport_protocol != IPPROTO_TCP && flow.key.transport_protocol != IPPROTO_UDP {
        return false;
    }

    let (local_port, peer_port) = if flow.source_endpoint == FLOW_ENDPOINT_A {
        (flow.key.endpoint_a_port, flow.key.endpoint_b_port)
    } else {
        (flow.key.endpoint_b_port, flow.key.endpoint_a_port)
    };

    local_port > 0 && local_port < EPHEMERAL_PORT_FLOOR && peer_port >= EPHEMERAL_PORT_FLOOR
}

// Flow accounting: counts packets per flow into flow_table so userspace can join
// flow_table with flow_to_pid for netflow->process attribution. Returns true if
// the interface is allowlisted, signalling the entry program to tail-call the
// SYN-signature program. The AF_XDP redirect lives in netprobe_xdp_ingress (TC
// cannot redirect into an XSKMAP). De-inlined (shared by both entries, verified
// once); contains NO tail_call — bpf_tail_call is illegal inside subprograms.
#[inline(never)]
fn account_flow(ctx: &TcContext) -> bool {
    let interface_index = skb_interface_index(ctx);
    if interface_config(interface_index).is_none() {
        return false;
    }

    if let Some(flow_key) = parse_flow_key(ctx) {
        // Split out so the flow_table_key/entry locals don't share account_flow's
        // stack frame with the (deep, address-heavy) parse_flow_key call chain —
        // combined they exceed the 512-byte BPF stack limit. flow_key is passed
        // by reference: a 40-byte by-value arg would overflow the 5-register
        // bpf-to-bpf calling convention.
        update_flow_table(interface_index, &flow_key, now_ns());
    }

    true
}

// Not inlined: keeps the flow_table_key + entry locals in their own frame,
// separate from account_flow's parse_flow_key chain (see account_flow).
#[inline(never)]
fn update_flow_table(interface_index: u32, flow_key: &FlowKey, now: u64) {
    let flow_table_key = flow_table_key(interface_index, *flow_key);
    if let Some(entry_ptr) = FLOW_TABLE.get_ptr_mut(&flow_table_key) {
        // SAFETY: kernel-returned map pointer, valid for this invocation.
        let entry = unsafe { &mut *entry_ptr };
        entry.packets_seen = entry.packets_seen.saturating_add(1);
        entry.last_seen_ns = now;
    } else {
        let entry = FlowTableEntry {
            classified_as: 0,
            packets_seen: 1,
            packets_redirected: 0,
            reserved: 0,
            last_seen_ns: now,
        };
        let _ = FLOW_TABLE.insert(&flow_table_key, &entry, BPF_ANY as u64);
    }
}

#[inline(always)]
fn interface_config(interface_index: u32) -> Option<InterfaceConfig> {
    // SAFETY: The TC program only copies the map value out and does not retain
    // the borrowed reference. A missing or disabled entry is deny-by-default.
    let config = unsafe { INTERFACE_ALLOWLIST.get(&interface_index) }?;
    if config.enabled == 0 {
        return None;
    }

    Some(*config)
}

// Not inlined: keeps the flow-key parse subtree out of account_flow so the
// verifier checks it once (bpf-to-bpf) instead of re-exploring it inline.
#[inline(never)]
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

#[inline(always)]
fn flow_table_key(interface_index: u32, flow: FlowKey) -> FlowTableKey {
    FlowTableKey {
        interface_index,
        reserved: 0,
        flow,
    }
}

// Not inlined: the SYN-signature parse subtree is the bulk of this path's
// verifier work. It is the tail-call target netprobe_tc_syn_signature and stays
// a separate bpf-to-bpf function so the verifier checks it once.
#[inline(never)]
fn emit_tcp_syn_signature_from_tc(ctx: &TcContext, observed_ns: u64) {
    let mut offset = ETH_HEADER_LEN;
    let Some(mut ethertype) = load_be_u16(ctx, 12) else {
        return;
    };
    if ethertype == ETH_P_8021Q || ethertype == ETH_P_8021AD {
        let Some(vlan_ethertype) = load_be_u16(ctx, 16) else {
            return;
        };
        ethertype = vlan_ethertype;
        offset = offset.saturating_add(VLAN_HEADER_LEN);
    }

    match ethertype {
        ETH_P_IP => emit_ipv4_tcp_syn_signature_from_tc(ctx, offset, observed_ns),
        ETH_P_IPV6 => emit_ipv6_tcp_syn_signature_from_tc(ctx, offset, observed_ns),
        _ => {}
    }
}

// Not inlined: splitting the IPv4/IPv6 SYN paths into their own bpf-to-bpf
// frames keeps emit_tcp_syn_header_from_tc (inlined here) out of the parent's
// frame and prevents it being inlined twice (once per protocol) into a single
// frame, which blew past the 512-byte BPF stack limit. 3 args fit the 5-register
// calling convention.
#[inline(never)]
fn emit_ipv4_tcp_syn_signature_from_tc(ctx: &TcContext, ip_offset: usize, observed_ns: u64) {
    let Some(version_ihl) = load_u8(ctx, ip_offset) else {
        return;
    };
    if version_ihl >> 4 != 4 {
        return;
    }

    let ihl = usize::from(version_ihl & 0x0f) * 4;
    if ihl < IPV4_MIN_HEADER_LEN {
        return;
    }

    let Some(protocol) = load_u8(ctx, ip_offset + 9) else {
        return;
    };
    if protocol != IPPROTO_TCP as u8 {
        return;
    }

    let tcp_offset = ip_offset.saturating_add(ihl);
    let Some(total_len) = load_be_u16(ctx, ip_offset + 2).map(usize::from) else {
        return;
    };
    let Some(ttl) = load_u8(ctx, ip_offset + 8) else {
        return;
    };
    // p0f IP-level quirks: df (don't-fragment set), id+ (DF set yet IP ID
    // non-zero), id- (DF clear yet IP ID zero). Two cheap header reads — the
    // major OS corpus entries (Linux/Windows/macOS/...) require df,id+.
    let Some(ip_id) = load_be_u16(ctx, ip_offset + 4) else {
        return;
    };
    let Some(flags_frag) = load_be_u16(ctx, ip_offset + 6) else {
        return;
    };
    let mut ip_quirks = 0u32;
    if flags_frag & IPV4_FLAG_DF != 0 {
        ip_quirks |= TCP_SYN_QUIRK_DF;
        if ip_id != 0 {
            ip_quirks |= TCP_SYN_QUIRK_ID_PLUS;
        }
    } else if ip_id == 0 {
        ip_quirks |= TCP_SYN_QUIRK_ID_MINUS;
    }
    let mut source = [0u8; 16];
    let mut destination = [0u8; 16];
    let Some(source_ipv4) = load_bytes::<4>(ctx, ip_offset + 12) else {
        return;
    };
    let Some(destination_ipv4) = load_bytes::<4>(ctx, ip_offset + 16) else {
        return;
    };
    source[..4].copy_from_slice(&source_ipv4);
    destination[..4].copy_from_slice(&destination_ipv4);
    let Some(source_port) = load_be_u16(ctx, tcp_offset) else {
        return;
    };
    let Some(destination_port) = load_be_u16(ctx, tcp_offset + 2) else {
        return;
    };
    emit_tcp_syn_header_from_tc(
        ctx,
        tcp_offset,
        total_len.saturating_sub(ihl),
        AF_INET,
        &source,
        &destination,
        source_port,
        destination_port,
        observed_ns,
        4,
        ttl,
        ip_quirks,
    );
}

// Not inlined: see emit_ipv4_tcp_syn_signature_from_tc. Keeps its own stack
// frame so emit_tcp_syn_header_from_tc isn't inlined into the shared parent.
#[inline(never)]
fn emit_ipv6_tcp_syn_signature_from_tc(ctx: &TcContext, ip_offset: usize, observed_ns: u64) {
    let Some(version) = load_u8(ctx, ip_offset) else {
        return;
    };
    if version >> 4 != 6 {
        return;
    }

    let Some(protocol) = load_u8(ctx, ip_offset + 6) else {
        return;
    };
    if protocol != IPPROTO_TCP as u8 {
        return;
    }

    let tcp_offset = ip_offset.saturating_add(IPV6_HEADER_LEN);
    let Some(payload_len) = load_be_u16(ctx, ip_offset + 4).map(usize::from) else {
        return;
    };
    let Some(hop_limit) = load_u8(ctx, ip_offset + 7) else {
        return;
    };
    let Some(source) = load_bytes::<16>(ctx, ip_offset + 8) else {
        return;
    };
    let Some(destination) = load_bytes::<16>(ctx, ip_offset + 24) else {
        return;
    };
    let Some(source_port) = load_be_u16(ctx, tcp_offset) else {
        return;
    };
    let Some(destination_port) = load_be_u16(ctx, tcp_offset + 2) else {
        return;
    };
    // IPv6 has no fragmentation flags / IP ID in the base header, so the
    // df/id+/id- quirks do not apply.
    emit_tcp_syn_header_from_tc(
        ctx,
        tcp_offset,
        payload_len,
        AF_INET6,
        &source,
        &destination,
        source_port,
        destination_port,
        observed_ns,
        6,
        hop_limit,
        0,
    );
}

// Stays inlined: the parameter count exceeds the 5-register BPF bpf-to-bpf
// calling convention (stack args unsupported). Inlined into its de-inlined
// parent emit_tcp_syn_signature_from_tc, so it's still verified once there.
#[inline(always)]
#[allow(clippy::too_many_arguments)]
fn emit_tcp_syn_header_from_tc(
    ctx: &TcContext,
    tcp_offset: usize,
    tcp_segment_len: usize,
    address_family: u16,
    source_addr: &[u8; 16],
    destination_addr: &[u8; 16],
    source_port: u16,
    destination_port: u16,
    observed_ns: u64,
    ip_version: u16,
    ttl: u8,
    ip_quirks: u32,
) {
    if tcp_segment_len < TCP_MIN_HEADER_LEN {
        return;
    }

    let Some(data_offset_word) = load_u8(ctx, tcp_offset + 12) else {
        return;
    };
    let data_offset = usize::from(data_offset_word >> 4) * 4;
    if data_offset < TCP_MIN_HEADER_LEN || data_offset > tcp_segment_len {
        return;
    }

    let Some(flags) = load_u8(ctx, tcp_offset + 13) else {
        return;
    };
    if flags & TCP_FLAG_SYN == 0 {
        return;
    }

    if load_u8(ctx, tcp_offset + data_offset - 1).is_none() {
        return;
    }

    let Some(window_size) = load_be_u16(ctx, tcp_offset + 14) else {
        return;
    };
    let Some(mut entry) = TCP_SYN_SIGNATURES.reserve::<TcpSynSignatureRecord>(0) else {
        return;
    };
    let record = entry.as_mut_ptr();
    let payload_class = if tcp_segment_len > data_offset {
        TCP_PAYLOAD_CLASS_NON_EMPTY
    } else {
        TCP_PAYLOAD_CLASS_EMPTY
    };

    // SAFETY: `record` points to a freshly reserved ring-buffer slot for a
    // TcpSynSignatureRecord. Every field (including reserved padding) is
    // initialized before submit, so no uninitialized ring memory is exposed to
    // userspace, and the mutable reference is only used during this invocation.
    unsafe {
        addr_of_mut!((*record).version).write(EVENT_VERSION);
        addr_of_mut!((*record).ip_version).write(ip_version);
        addr_of_mut!((*record).ttl).write(ttl);
        addr_of_mut!((*record).window_scale).write(0);
        addr_of_mut!((*record).options_len).write(0);
        addr_of_mut!((*record).payload_class).write(payload_class);
        addr_of_mut!((*record).reserved0).write(0);
        addr_of_mut!((*record).window_size).write(window_size);
        addr_of_mut!((*record).mss).write(0);
        addr_of_mut!((*record).reserved1).write(0);
        // Seed quirks with the IP-level quirks; parse_tcp_options_from_tc ORs in
        // the malformed-options quirk if it sees bad TCP options.
        addr_of_mut!((*record).quirks).write(ip_quirks);
        addr_of_mut!((*record).reserved2).write(0);
        addr_of_mut!((*record).observed_ns).write(observed_ns);
        let source_endpoint = write_canonical_flow_key(
            addr_of_mut!((*record).flow_key),
            address_family,
            IPPROTO_TCP,
            source_addr,
            destination_addr,
            source_port,
            destination_port,
        );
        addr_of_mut!((*record).source_endpoint).write(source_endpoint);
        addr_of_mut!((*record).options_layout).write([0; TCP_MAX_OPTIONS_LAYOUT]);

        parse_tcp_options_from_tc(
            ctx,
            tcp_offset + TCP_MIN_HEADER_LEN,
            data_offset - TCP_MIN_HEADER_LEN,
            &mut *record,
        );
    }
    entry.submit(0);
}

#[inline(never)]
fn parse_tcp_options_from_tc(
    ctx: &TcContext,
    options_offset: usize,
    options_len: usize,
    record: &mut TcpSynSignatureRecord,
) {
    let mut offset = 0usize;
    let mut option_count = 0usize;

    while offset < options_len && option_count < TCP_MAX_OPTIONS_LAYOUT {
        let Some(kind) = load_u8(ctx, options_offset + offset) else {
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

        let Some(length) = load_u8(ctx, options_offset + offset + 1).map(usize::from) else {
            record.quirks |= TCP_SYN_QUIRK_MALFORMED_OPTIONS;
            return;
        };
        if length < 2 || offset.saturating_add(length) > options_len {
            record.quirks |= TCP_SYN_QUIRK_MALFORMED_OPTIONS;
            return;
        }

        if kind == 2 && length == 4 {
            if let Some(mss) = load_be_u16(ctx, options_offset + offset + 2) {
                record.mss = mss;
            }
        } else if kind == 3 && length == 3 {
            if let Some(window_scale) = load_u8(ctx, options_offset + offset + 2) {
                record.window_scale = window_scale;
            }
        }

        offset += length;
    }

    record.options_len = option_count as u8;
}

#[inline(always)]
fn write_canonical_flow_key(
    out: *mut FlowKey,
    address_family: u16,
    transport_protocol: u16,
    source_addr: &[u8; 16],
    destination_addr: &[u8; 16],
    source_port: u16,
    destination_port: u16,
) -> u8 {
    let source_first =
        endpoint_less_or_equal(source_addr, source_port, destination_addr, destination_port);
    // SAFETY: `out` is a field pointer into a reserved ring-buffer record that
    // the caller is initializing before submit. All fields of FlowKey are
    // written exactly once here.
    unsafe {
        if source_first {
            addr_of_mut!((*out).address_family).write(address_family);
            addr_of_mut!((*out).transport_protocol).write(transport_protocol);
            addr_of_mut!((*out).endpoint_a_port).write(source_port);
            addr_of_mut!((*out).endpoint_b_port).write(destination_port);
            addr_of_mut!((*out).endpoint_a_addr).write(*source_addr);
            addr_of_mut!((*out).endpoint_b_addr).write(*destination_addr);
        } else {
            addr_of_mut!((*out).address_family).write(address_family);
            addr_of_mut!((*out).transport_protocol).write(transport_protocol);
            addr_of_mut!((*out).endpoint_a_port).write(destination_port);
            addr_of_mut!((*out).endpoint_b_port).write(source_port);
            addr_of_mut!((*out).endpoint_a_addr).write(*destination_addr);
            addr_of_mut!((*out).endpoint_b_addr).write(*source_addr);
        }
    }

    if source_first {
        FLOW_ENDPOINT_A
    } else {
        FLOW_ENDPOINT_B
    }
}

// Not inlined: keeps the IPv4 parse (and its address buffers) in its own
// bpf-to-bpf frame instead of being inlined alongside the IPv6 parser into
// parse_flow_key, which pushed that combined frame past the BPF stack limit.
#[inline(never)]
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
    Some(
        canonical_flow_key(
            AF_INET,
            u16::from(protocol),
            source,
            destination,
            source_port,
            destination_port,
        )
        .key,
    )
}

// Not inlined: see parse_ipv4_flow_key. Own frame so it isn't inlined into
// parse_flow_key alongside the IPv4 parser.
#[inline(never)]
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
    Some(
        canonical_flow_key(
            AF_INET6,
            u16::from(protocol),
            source,
            destination,
            source_port,
            destination_port,
        )
        .key,
    )
}

#[inline(always)]
fn canonical_flow_key(
    address_family: u16,
    transport_protocol: u16,
    source_addr: [u8; 16],
    destination_addr: [u8; 16],
    source_port: u16,
    destination_port: u16,
) -> CanonicalFlowKey {
    // Delegate to the pointer-writing canonicalizer instead of building the
    // FlowKey by value in each branch. The by-value construction duplicated the
    // 16-byte address copies across both branches and blew the parse frame past
    // the 512-byte BPF stack limit; write_canonical_flow_key writes each field
    // in place exactly once.
    let mut key = core::mem::MaybeUninit::<FlowKey>::uninit();
    let source_endpoint = write_canonical_flow_key(
        key.as_mut_ptr(),
        address_family,
        transport_protocol,
        &source_addr,
        &destination_addr,
        source_port,
        destination_port,
    );
    // SAFETY: write_canonical_flow_key initializes every field of *key in both
    // branches before returning.
    CanonicalFlowKey {
        key: unsafe { key.assume_init() },
        source_endpoint,
    }
}

#[inline(always)]
fn endpoint_less_or_equal(
    left_addr: &[u8; 16],
    left_port: u16,
    right_addr: &[u8; 16],
    right_port: u16,
) -> bool {
    // Compare the 16-byte addresses as a single big-endian u128 rather than a
    // byte-by-byte loop: LLVM unrolls the loop and spills each byte to the stack,
    // which for full IPv6 addresses pushed parse_ipv6_flow_key's frame to ~392
    // bytes (past the 512-byte BPF stack limit once nested under the classifier).
    let left = u128::from_be_bytes(*left_addr);
    let right = u128::from_be_bytes(*right_addr);
    if left != right {
        return left < right;
    }

    left_port <= right_port
}

// Emission refresh interval for the passive census, per (interface, MAC, IP).
//
// This does NOT gate a device's first sighting -- an unseen binding is always
// emitted immediately, which is what makes a device present for seconds
// visible at all. It only rate limits refreshes of an already-known binding.
//
// 60s matches the kernel's own neighbour `gc_stale_time` default, so we emit
// roughly once per natural ARP re-query cycle rather than suppressing most of
// them. Volume stays trivial: a fully populated /24 refreshing every 60s is ~4
// observations/sec, and 1000 devices ~17/sec, both far below what the 1 MiB
// ring absorbs. Shorter buys last-seen precision inventory does not need; much
// longer makes last_seen stale enough to misreport a device as gone.
const L2_REFRESH_INTERVAL_NS: u64 = 60 * 1_000_000_000;

// A locally administered MAC sets bit 1 of the first octet, so the first octet
// ends in 2, 6, A or E. Every MAC randomization implementation sets it.
#[inline(always)]
fn mac_is_locally_administered(mac: &[u8; 6]) -> bool {
    mac[0] & 0x02 != 0
}

// True when this (interface, MAC, IP) binding should be emitted: either it has
// never been seen, or its refresh interval has elapsed.
//
// Uses get_ptr_mut + update-in-place, mirroring update_flow_table above. An
// earlier version used `get()` with an `insert()` on every emit and suppressed
// nothing on a live host: entries carried correct bpf_ktime_get_ns timestamps,
// yet lookups behaved as misses and every frame was emitted. The flow table is
// the pattern that demonstrably works in this same program, so match it.
#[inline(never)]
// Takes the key BY VALUE, and is deliberately NOT #[inline(never)].
//
// Both matter, and the second one cost a live debugging session. As a
// non-inlined function taking `&L2SeenKey`, this received a pointer into the
// CALLER's stack frame and handed it straight to bpf_map_update_elem across a
// BPF-to-BPF call. The program verified and loaded, `flow_table` (an
// LruHashMap updated the same way from the same program) filled normally, and
// yet `l2_seen` stayed at exactly 0 entries under live traffic -- every insert
// silently failed, nothing was ever suppressed, and the watchdog killed the
// census 10 seconds after every start.
//
// update_flow_table is the working precedent and does it the other way: it
// builds the key as a local value in its own frame and passes `&local` to the
// helpers. Copy that shape, not just its choice of get_ptr_mut + BPF_ANY.
fn l2_should_emit(key: L2SeenKey, observed_ns: u64) -> bool {
    if let Some(last_ptr) = L2_SEEN.get_ptr_mut(&key) {
        // SAFETY: kernel-returned map pointer, valid for this invocation.
        let last = unsafe { &mut *last_ptr };
        // saturating_sub so a non-monotonic clock cannot make this emit forever.
        if observed_ns.saturating_sub(*last) < L2_REFRESH_INTERVAL_NS {
            return false;
        }
        *last = observed_ns;
        return true;
    }
    if L2_SEEN.insert(&key, &observed_ns, BPF_ANY as u64).is_err() {
        // A failed insert means this binding is not remembered, so the next
        // frame from it emits again. Counted rather than discarded: silently
        // dropping this error is what turned a one-line calling-convention bug
        // into an unsuppressed flood with no diagnosable cause.
        if let Some(failures) = L2_RING_DROPS.get_ptr_mut(L2_STAT_SUPPRESS_INSERT_FAILED) {
            // SAFETY: per-CPU array slot 1 exists (capacity 2) and is only
            // accessed from this CPU for the duration of this program run.
            unsafe { *failures = (*failures).saturating_add(1) };
        }
    }
    true
}

// Passive device census. Extracts the sender MAC from the Ethernet header --
// present on every frame, costing no extra traffic -- and pairs it with the
// sender IP. ARP is handled separately because it carries no IP header, and it
// is the one signal every IPv4 device emits on joining a segment.
//
// Not inlined: keeps this parse out of the flow-accounting classifier's stack
// frame, which the SYN-signature path already pushes near the BPF limit.
#[inline(never)]
fn observe_l2_device(ctx: &TcContext) {
    // HOT PATH FIRST. This runs on every ingress frame, and the overwhelming
    // majority are ordinary TCP/UDP that the census discards. Read the 2-byte
    // ethertype before anything else and leave immediately when it is not a
    // census signal, so a discarded frame costs one small load and a compare --
    // not a MAC read it will never use.
    let mut offset = ETH_HEADER_LEN;
    let Some(mut ethertype) = load_be_u16(ctx, 12) else {
        return;
    };
    if ethertype == ETH_P_8021Q || ethertype == ETH_P_8021AD {
        let Some(inner) = load_be_u16(ctx, 16) else {
            return;
        };
        ethertype = inner;
        offset = offset.saturating_add(VLAN_HEADER_LEN);
    }
    if ethertype != ETH_P_ARP && ethertype != ETH_P_IPV6 {
        return;
    }
    // IPv6 is mostly ordinary traffic too, so reject non-NDP before the MAC
    // read as well: two 1-byte loads instead of a 6-byte one plus a lookup.
    if ethertype == ETH_P_IPV6 {
        let Some(next_header) = load_u8(ctx, offset + 6) else {
            return;
        };
        if u16::from(next_header) != IPPROTO_ICMPV6 {
            return;
        }
        let Some(icmp_type) = load_u8(ctx, offset + IPV6_HEADER_LEN) else {
            return;
        };
        if !(ICMPV6_ROUTER_SOLICITATION..=ICMPV6_NEIGHBOR_ADVERTISEMENT).contains(&icmp_type) {
            return;
        }
    }

    // Frame is a census signal. Only now is the allowlist lookup worth paying
    // for, and only now the clock read.
    let interface_index = skb_interface_index(ctx);
    if interface_config(interface_index).is_none() {
        return;
    }

    let Some(mac) = load_bytes::<6>(ctx, 6) else {
        return;
    };
    // A broadcast/multicast source is never a device's own hardware address.
    if mac[0] & 0x01 != 0 {
        return;
    }

    let observed_ns = now_ns();

    let mut record = L2ObservationRecord {
        version: L2_OBSERVATION_VERSION,
        observation_kind: 0,
        ip_version: 0,
        flags: 0,
        interface_index,
        observed_ns,
        mac,
        reserved0: [0; 2],
        ip: [0; 16],
    };

    match ethertype {
        ETH_P_ARP => {
            let Some(oper) = load_be_u16(ctx, offset + ARP_OPER_OFFSET) else {
                return;
            };
            record.observation_kind = if oper == ARP_OPER_REPLY {
                L2_KIND_ARP_REPLY
            } else if oper == ARP_OPER_REQUEST {
                L2_KIND_ARP_REQUEST
            } else {
                return;
            };
            // The ARP sender hardware address is the semantic binding: it can
            // differ from the frame source for a proxy-ARP responder, and the
            // sender field is the one that names the address owner.
            let Some(sender_ha) = load_bytes::<6>(ctx, offset + ARP_SENDER_HA_OFFSET) else {
                return;
            };
            let Some(sender_pa) = load_bytes::<4>(ctx, offset + ARP_SENDER_PA_OFFSET) else {
                return;
            };
            record.mac = sender_ha;
            if mac_is_locally_administered(&sender_ha) {
                record.flags |= L2_FLAG_LOCALLY_ADMINISTERED;
            }
            if sender_pa[0] == 0 && sender_pa[1] == 0 && sender_pa[2] == 0 && sender_pa[3] == 0 {
                // RFC 5227 probe: the device is claiming an address it does not
                // own yet. Earliest possible sighting, but it binds no IP.
                record.flags |= L2_FLAG_ARP_PROBE;
            } else {
                record.ip_version = 4;
                record.ip[0] = sender_pa[0];
                record.ip[1] = sender_pa[1];
                record.ip[2] = sender_pa[2];
                record.ip[3] = sender_pa[3];
                if let Some(target_pa) = load_bytes::<4>(ctx, offset + ARP_SENDER_PA_OFFSET + 10) {
                    if target_pa[0] == sender_pa[0]
                        && target_pa[1] == sender_pa[1]
                        && target_pa[2] == sender_pa[2]
                        && target_pa[3] == sender_pa[3]
                    {
                        record.flags |= L2_FLAG_ARP_GRATUITOUS;
                    }
                }
            }
        }
        ETH_P_IPV6 => {
            // NDP only -- already validated above, before the MAC read.
            //
            // Never ordinary IPv6 traffic: measured on a live segment, observing
            // every frame produced ~400 observations/sec from 41 MACs, because
            // routed traffic pairs the gateway's MAC with an unbounded set of
            // remote addresses, so every new remote IP became a new suppression
            // key and nothing was ever suppressed. NDP is link-local, so both
            // the MAC and the address belong to a device on this segment.
            let Some(src) = load_bytes::<16>(ctx, offset + 8) else {
                return;
            };
            record.observation_kind = L2_KIND_IPV6_NDP;
            record.ip_version = 6;
            record.ip = src;
            if mac_is_locally_administered(&mac) {
                record.flags |= L2_FLAG_LOCALLY_ADMINISTERED;
            }
        }
        _ => return,
    }

    let key = L2SeenKey {
        interface_index: record.interface_index,
        reserved: 0,
        mac: record.mac,
        ip: record.ip,
    };
    if !l2_should_emit(key, observed_ns) {
        return;
    }

    let Some(mut entry) = L2_OBSERVATIONS.reserve::<L2ObservationRecord>(0) else {
        // Ring full: userspace is not draining fast enough. Record the loss so
        // the snapshot can report it rather than silently under-reporting the
        // segment.
        if let Some(drops) = L2_RING_DROPS.get_ptr_mut(L2_STAT_RING_FULL) {
            // SAFETY: per-CPU array slot 0 exists (capacity 1) and is only
            // accessed from this CPU for the duration of this program run.
            unsafe { *drops = (*drops).saturating_add(1) };
        }
        return;
    };
    entry.write(record);
    entry.submit(0);
}

// Observe one mDNS announcement.
//
// HOT PATH FIRST, same discipline as observe_l2_device. This runs on every
// ingress frame and the overwhelming majority are ordinary unicast traffic, so
// the cheap rejections come first: ethertype, then IP protocol, then the
// destination port. Only a frame that is actually UDP/5353 pays for a MAC read,
// an allowlist lookup, a clock read, a hash, or a ring reservation.
fn observe_mdns(ctx: &TcContext) {
    let mut offset = ETH_HEADER_LEN;
    let Some(mut ethertype) = load_be_u16(ctx, 12) else {
        return;
    };
    if ethertype == ETH_P_8021Q || ethertype == ETH_P_8021AD {
        let Some(inner) = load_be_u16(ctx, 16) else {
            return;
        };
        ethertype = inner;
        offset = offset.saturating_add(VLAN_HEADER_LEN);
    }

    let (ip_protocol_offset, is_v6) = match ethertype {
        ETH_P_IP => (offset + 9, false),
        ETH_P_IPV6 => (offset + 6, true),
        _ => return,
    };

    let Some(protocol) = load_u8(ctx, ip_protocol_offset) else {
        return;
    };
    if u16::from(protocol) != IPPROTO_UDP {
        return;
    }

    // IPv4 carries a variable header length; IPv6's is fixed. An IPv4 packet
    // with options would otherwise have its ports read from the wrong offset.
    let udp_offset = if is_v6 {
        offset + IPV6_HEADER_LEN
    } else {
        let Some(version_ihl) = load_u8(ctx, offset) else {
            return;
        };
        let ihl = usize::from(version_ihl & 0x0F) * 4;
        if ihl < 20 {
            return;
        }
        offset + ihl
    };

    let Some(destination_port) = load_be_u16(ctx, udp_offset + 2) else {
        return;
    };
    if destination_port != MDNS_PORT {
        return;
    }

    // Past here the frame is genuinely mDNS, which is a vanishing fraction of
    // traffic, so the remaining work is affordable.
    if interface_config(skb_interface_index(ctx)).is_none() {
        return;
    }

    let Some(udp_length) = load_be_u16(ctx, udp_offset + 4) else {
        return;
    };
    let payload_offset = udp_offset + UDP_HEADER_LEN;
    // The UDP length covers the header, so anything at or below it carries no
    // payload and cannot be a DNS message.
    if usize::from(udp_length) <= UDP_HEADER_LEN {
        return;
    }
    let declared = usize::from(udp_length) - UDP_HEADER_LEN;

    let Some(source_mac) = load_bytes::<6>(ctx, 6) else {
        return;
    };
    if source_mac[0] & 0x01 != 0 {
        // Group/broadcast source address: never a device's own address.
        return;
    }

    let observed_ns = now_ns();

    let Some(mut entry) = MDNS_OBSERVATIONS.reserve::<MdnsObservationRecord>(0) else {
        if let Some(drops) = L2_RING_DROPS.get_ptr_mut(MDNS_STAT_RING_FULL) {
            // SAFETY: per-CPU slot 2 exists (capacity 4) and is CPU-local.
            unsafe { *drops = (*drops).saturating_add(1) };
        }
        return;
    };

    // SAFETY: reserve returned space sized for exactly this type; every field is
    // written below before submit, and the payload is zeroed first so a short
    // packet cannot leak whatever the ring held before.
    let record = unsafe { &mut *entry.as_mut_ptr() };
    record.version = MDNS_RECORD_VERSION;
    record.flags = if is_v6 { MDNS_FLAG_IPV6 } else { 0 };
    record.reserved0 = 0;
    record.reserved1 = 0;
    record.interface_index = skb_interface_index(ctx);
    record.observed_ns = observed_ns;
    record.mac = source_mac;
    record.reserved2 = [0u8; 2];
    record.ip = [0u8; 16];
    record.payload = [0u8; MDNS_PAYLOAD_CAP];

    if is_v6 {
        if let Some(source) = load_bytes::<16>(ctx, offset + 8) {
            record.ip = source;
        }
    } else if let Some(source) = load_bytes::<4>(ctx, offset + 12) {
        record.ip[..4].copy_from_slice(&source);
    }

    // Copy in ONE call whose length is a compile-time constant.
    //
    // A runtime-variable length is rejected outright. The verifier reported:
    //   R4 invalid zero-sized read: u64=[0,4294967233]
    // because a slice bound by a computed value gives it neither a non-zero
    // lower bound nor a usable upper one. Clamping the value in Rust is not
    // enough -- the constant has to be visible in the instruction stream.
    //
    // A descending ladder picks the largest constant that fits, so at most 63
    // bytes of a packet's tail are lost. Announcements observed on a live
    // segment ran 215-473 bytes, so in practice this copies what matters.
    // Below the smallest rung the packet is too short to carry a TXT record
    // worth reading, so it is dropped rather than partially copied.
    //
    // Copying straight into the ring reservation is also required rather than
    // stylistic: the BPF stack is 512 bytes in total and the payload alone is
    // 512.
    // The RAW helper, not TcContext::load_bytes.
    //
    // aya's wrapper clamps the length to `skb->len - offset` before calling
    // bpf_skb_load_bytes:
    //     let len = len.checked_sub(offset)?;   // runtime
    //     let len = len.min(dst.len());         // min(runtime, const) -> runtime
    // so even a constant-sized destination slice arrives at the helper as a
    // variable, and the verifier refuses it:
    //     R4 invalid zero-sized read: u64=[0,31]
    // It has no non-zero lower bound to work with. Passing the literal directly
    // is the only way to give R4 a constant.
    //
    // The helper itself rejects a read past the end of the packet, so trying
    // constants in descending order is safe: the first that fits wins, and no
    // bounds arithmetic of ours has to be trusted.
    let mut copied = 0usize;
    macro_rules! copy_largest_that_fits {
        ($($len:literal),*) => {
            $(
                if copied == 0 && declared >= $len {
                    // SAFETY: the destination is the ring reservation, which is
                    // sized MDNS_PAYLOAD_CAP and every literal below is <= that.
                    // The helper bounds the source read itself.
                    let ret = unsafe {
                        aya_ebpf::helpers::bpf_skb_load_bytes(
                            ctx.skb.skb as *const _,
                            payload_offset as u32,
                            record.payload.as_mut_ptr() as *mut _,
                            $len as u32,
                        )
                    };
                    if ret == 0 {
                        copied = $len;
                    }
                }
            )*
        };
    }
    // 16-byte granularity, not 64. The coarse ladder set MDNS_FLAG_TRUNCATED on
    // essentially every record observed on a live segment -- a 215-byte
    // announcement copied 192 bytes and lost 23 -- which both discarded the tail
    // where a trailing TXT can live and made the flag meaningless because it was
    // always set. At 16 bytes the worst case is 15 lost and the flag once again
    // means something a receiver can act on.
    //
    // The failed attempts cost only a helper call that returns an error, and
    // only for packets that are already rare.
    copy_largest_that_fits!(
        512, 496, 480, 464, 448, 432, 416, 400, 384, 368, 352, 336, 320, 304, 288, 272, 256, 240,
        224, 208, 192, 176, 160, 144, 128, 112, 96, 80, 64, 48, 32, 16
    );

    if copied == 0 {
        entry.discard(0);
        return;
    }
    // TRUNCATED means the announcement was longer than we can carry, which is
    // actionable: the model may be in the part that was never copied, so a
    // receiver should wait for another announcement rather than concluding the
    // device did not send one.
    //
    // It deliberately does NOT mean "the copy ladder rounded down". Setting it
    // for that fired on 26 of 27 records observed live -- the ladder lands on an
    // exact multiple only 1/16 of the time -- which made the flag carry no
    // information at all. The <=15 trailing bytes a round-down loses are
    // reflected honestly in payload_len, and the DNS parser simply stops at the
    // last record it can complete.
    if declared > MDNS_PAYLOAD_CAP {
        record.flags |= MDNS_FLAG_TRUNCATED;
    }
    record.payload_len = copied as u16;

    if !mdns_should_emit(record.interface_index, source_mac, &record.payload, copied, observed_ns) {
        entry.discard(0);
        return;
    }

    entry.submit(0);
}

// Suppress an announcement whose content we have already seen from this device.
//
// Hashes the copied payload rather than keying on the MAC alone: see MDNS_SEEN.
// FNV-1a over a bounded prefix -- the DNS header and first records are what
// differ between a service announcement and the TXT that names the model, so a
// prefix discriminates them without walking the whole packet on every frame.
#[inline(never)]
fn mdns_should_emit(
    interface_index: u32,
    mac: [u8; 6],
    payload: &[u8; MDNS_PAYLOAD_CAP],
    len: usize,
    observed_ns: u64,
) -> bool {
    const HASH_PREFIX: usize = 128;
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    // Both bounds are kept in the loop condition. The second is redundant in
    // Rust but not to the verifier, which needs a constant ceiling it can see
    // to prove the index stays inside the array.
    let bounded = if len < HASH_PREFIX { len } else { HASH_PREFIX };
    let mut index = 0usize;
    while index < bounded && index < HASH_PREFIX {
        hash ^= u64::from(payload[index]);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        index += 1;
    }
    // Length participates so two packets sharing a prefix but differing in size
    // are not collapsed.
    hash ^= len as u64;

    let key = MdnsSeenKey {
        interface_index,
        reserved: 0,
        mac,
        reserved2: [0u8; 2],
        payload_hash: hash,
    };

    // By VALUE, and not #[inline(never)] on the map access itself: a &key from
    // the caller's frame handed to a map helper across a BPF-to-BPF call makes
    // every insert silently fail. That cost a live debugging session on the
    // census (l2_seen sat at 0 entries while flow_table filled normally).
    if let Some(last_ptr) = MDNS_SEEN.get_ptr_mut(&key) {
        let last = unsafe { &mut *last_ptr };
        if observed_ns.saturating_sub(*last) < MDNS_REFRESH_INTERVAL_NS {
            return false;
        }
        *last = observed_ns;
        return true;
    }

    if MDNS_SEEN.insert(&key, &observed_ns, BPF_ANY as u64).is_err() {
        if let Some(failures) = L2_RING_DROPS.get_ptr_mut(MDNS_STAT_SUPPRESS_INSERT_FAILED) {
            // SAFETY: per-CPU slot 3 exists (capacity 4) and is CPU-local.
            unsafe { *failures = (*failures).saturating_add(1) };
        }
    }
    true
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
    // eBPF programs cannot unwind; spinning satisfies the panic ABI while the
    // verifier rejects any path that would rely on stack unwinding.
    loop {}
}
