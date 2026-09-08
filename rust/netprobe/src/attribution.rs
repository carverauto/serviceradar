use std::{
    collections::{HashMap, HashSet},
    fs,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[cfg(target_os = "linux")]
use std::{
    cmp::{Ordering as CmpOrdering, Reverse},
    collections::{BinaryHeap, VecDeque},
    hash::{BuildHasherDefault, Hash, Hasher},
    io, mem,
    os::fd::AsRawFd,
    ptr,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use crate::af_xdp_classifier::FlowKey;
#[cfg(target_os = "linux")]
use crate::event_queue::EventSender;
#[cfg(target_os = "linux")]
use crate::external_flow::SharedExternalFlowMatcher;
use crate::proto::netprobe::{FlowAttributionEvent, ProcessSnapshot, ProcessSnapshotEntry};

#[cfg(target_os = "linux")]
use crate::metrics::Metrics;

const AF_INET: u16 = 2;
const AF_INET6: u16 = 10;
const IPPROTO_ICMP: u16 = 1;
const IPPROTO_TCP: u16 = 6;
const IPPROTO_UDP: u16 = 17;
const IPPROTO_ICMPV6: u16 = 58;
const FLOW_ENDPOINT_A: u8 = 1;
const FLOW_ENDPOINT_B: u8 = 2;
/// Maximum byte length for the joined `redacted_cmdline` payload on a
/// `FlowAttributionEvent`. The cap mirrors the Elixir `cap_bytes`/
/// `trim_to_utf8_boundary` contract enforced in `flows.ex` so that the
/// producer never publishes a payload that the downstream consumer would
/// have to truncate.
const REDACTED_CMDLINE_MAX_BYTES: usize = 256;
#[cfg(target_os = "linux")]
// Maximum time the ring-reader thread waits in poll(2) before rechecking timers
// and shutdown state. Data readiness wakes it sooner.
const FLOW_ATTRIBUTION_RING_MAX_WAIT: Duration = Duration::from_secs(1);
#[cfg(target_os = "linux")]
// Drop a cached attribution that has not been refreshed by a new ring record
// within this window. TCP flows are normally evicted on close; this bounds the
// cache for flows that never emit a close (and caps memory regardless of churn).
const FLOW_ATTRIBUTION_CACHE_TTL: Duration = Duration::from_secs(300);
#[cfg(target_os = "linux")]
const FLOW_ATTRIBUTION_CACHE_PRUNE_INTERVAL: Duration = Duration::from_secs(10);
#[cfg(target_os = "linux")]
const FLOW_ATTRIBUTION_CACHE_MAX_ENTRIES: usize = 65_536;
#[cfg(target_os = "linux")]
const FLOW_ATTRIBUTION_CACHE_LOW_WATERMARK: usize = FLOW_ATTRIBUTION_CACHE_MAX_ENTRIES * 7 / 8;
#[cfg(target_os = "linux")]
// Process cmdline/container metadata is useful but not required to attribute a
// flow. Keep procfs reads on a bounded cold path so eBPF PID/comm attribution
// is emitted immediately.
const PROCESS_DETAILS_CACHE_TTL: Duration = Duration::from_secs(300);
#[cfg(target_os = "linux")]
const PROCESS_DETAILS_CACHE_MAX_ENTRIES: usize = 4096;
#[cfg(target_os = "linux")]
const PROCESS_DETAILS_COLD_READS_PER_SECOND: u32 = 1;
#[cfg(target_os = "linux")]
const PROCESS_DETAILS_COLD_READ_BURST: u32 = 4;
#[cfg(target_os = "linux")]
const PROCESS_DETAILS_RETRY_INTERVAL: Duration = Duration::from_secs(5);
#[cfg(target_os = "linux")]
const PROCESS_DETAILS_PENDING_MAX_ENTRIES: usize = 8192;
#[cfg(target_os = "linux")]
// Listener inventory changes are useful for host forensics, but a busy runtime
// can flap several local sockets per second. Coalesce dirty snapshots so one
// listener change does not become a continuous IPC stream.
const PROCESS_SNAPSHOT_DIRTY_MIN_INTERVAL: Duration = Duration::from_secs(10);
#[cfg(target_os = "linux")]
const EVENT_TCP_CONNECT: u16 = 1;
#[cfg(target_os = "linux")]
const EVENT_TCP_ACCEPT: u16 = 2;
#[cfg(target_os = "linux")]
// Mirrors EVENT_TCP_CLOSE in the eBPF.
const EVENT_TCP_CLOSE: u16 = 3;
#[cfg(target_os = "linux")]
const EVENT_UDP_SEND: u16 = 4;
#[cfg(target_os = "linux")]
const EVENT_UDP_RECV: u16 = 5;
const EVENT_INET_SOCK_SET_STATE: u16 = 6;
#[cfg(target_os = "linux")]
const EVENT_ICMP_SEND: u16 = 7;
#[cfg(target_os = "linux")]
const TCP_CLOSE_STATE: i32 = 7;
#[cfg(target_os = "linux")]
const TCP_LISTEN_STATE: i32 = 10;
#[cfg(target_os = "linux")]
// Keep long-lived tuples fresh enough for delayed central NetFlow joins without
// replaying every kernel refresh. This is deliberately shorter than the core
// correlation skew (15 minutes today) and longer than the eBPF 240s refresh.
const FLOW_ATTRIBUTION_RAW_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(300);
#[cfg(target_os = "linux")]
const UDP_SERVER_REMOTE_THRESHOLD: usize = 2;
#[cfg(target_os = "linux")]
const UDP_ROLE_CACHE_MAX_ENTRIES: usize = 8192;
#[cfg(target_os = "linux")]
const UDP_ROLE_CACHE_PRUNE_INTERVAL: Duration = Duration::from_secs(10);
const EPHEMERAL_PORT_FLOOR: u16 = 32768;
#[cfg(target_os = "linux")]
type FastHashMap<K, V> = HashMap<K, V, BuildHasherDefault<FastHasher>>;
#[cfg(target_os = "linux")]
type FastHashSet<K> = HashSet<K, BuildHasherDefault<FastHasher>>;

#[cfg(target_os = "linux")]
struct FastHasher {
    state: u64,
}

#[cfg(target_os = "linux")]
impl Default for FastHasher {
    fn default() -> Self {
        Self {
            state: 0xcbf29ce484222325,
        }
    }
}

#[cfg(target_os = "linux")]
impl FastHasher {
    #[inline]
    fn mix(&mut self, value: u64) {
        self.state ^= value;
        self.state = self.state.wrapping_mul(0x100000001b3);
        self.state ^= self.state >> 32;
    }
}

#[cfg(target_os = "linux")]
impl Hasher for FastHasher {
    #[inline]
    fn finish(&self) -> u64 {
        let mut state = self.state;
        state ^= state >> 32;
        state = state.wrapping_mul(0x9e3779b97f4a7c15);
        state ^ (state >> 32)
    }

    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        let (chunks, remainder) = bytes.as_chunks::<8>();
        for chunk in chunks {
            self.mix(u64::from_le_bytes(*chunk));
        }
        for byte in remainder {
            self.mix(u64::from(*byte));
        }
    }

    #[inline]
    fn write_u8(&mut self, i: u8) {
        self.mix(u64::from(i));
    }

    #[inline]
    fn write_u16(&mut self, i: u16) {
        self.mix(u64::from(i));
    }

    #[inline]
    fn write_u32(&mut self, i: u32) {
        self.mix(u64::from(i));
    }

    #[inline]
    fn write_u64(&mut self, i: u64) {
        self.mix(i);
    }

    #[inline]
    fn write_usize(&mut self, i: usize) {
        self.mix(i as u64);
    }

    #[inline]
    fn write_i32(&mut self, i: i32) {
        self.mix(i as u64);
    }

    #[inline]
    fn write_i64(&mut self, i: i64) {
        self.mix(i as u64);
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
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

#[cfg(target_os = "linux")]
// SAFETY: FlowPidRecord is #[repr(C)], Copy, and contains only integer fields
// and a fixed byte array. Its layout mirrors the eBPF flow_to_pid map value.
unsafe impl aya::Pod for FlowPidRecord {}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
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

#[cfg(target_os = "linux")]
// SAFETY: ProcessInfoRecord is #[repr(C)], Copy, and contains only integer
// fields and a fixed byte array. Its layout mirrors the eBPF process_info map value.
unsafe impl aya::Pod for ProcessInfoRecord {}

// Userspace mirror of the eBPF `FlowAttributionRecord` submitted to the
// `flow_events` BPF ring buffer (rust/netprobe/ebpf/src/lib.rs). #[repr(C)] and
// laid out byte-for-byte with the eBPF struct so a ring slot can be read
// directly with `ptr::read_unaligned`. The `inet_sock_set_state` (TCP),
// udp_sendmsg/udp_recvmsg (UDP), and ping_sendmsg/raw_sendmsg (ICMP) records
// carry a populated tuple. tcp_connect caches the owner for the later state
// tracepoint; accept/close also carry a tuple so service ownership and cleanup
// do not depend on the task scheduled when the state tracepoint fires.
#[repr(C)]
#[derive(Clone, Copy)]
struct FlowTupleRecord {
    family: u16,
    protocol: u16,
    source_port: u16,
    destination_port: u16,
    source_addr: [u8; 16],
    destination_addr: [u8; 16],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct FlowAttributionRecord {
    version: u16,
    event_kind: u16,
    pid: u32,
    tgid: u32,
    uid: u32,
    gid: u32,
    socket_address: u64,
    process_generation_ns: u64,
    old_state: i32,
    new_state: i32,
    tuple: FlowTupleRecord,
    comm: [u8; 16],
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProcessDetails {
    pub pid: u32,
    pub tgid: u32,
    pub uid: u32,
    pub gid: u32,
    pub comm: String,
    pub cmdline: Vec<String>,
    pub container_id: Option<String>,
    pub last_seen_ns: u64,
    pub process_generation_ns: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AttributedFlow {
    pub flow: FlowKey,
    pub pid: FlowPidRecord,
    pub process: Option<ProcessDetails>,
}

impl AttributedFlow {
    pub fn event(&self) -> Option<FlowAttributionEvent> {
        flow_attribution_event(self, now_unix_nano())
    }
}

#[cfg(target_os = "linux")]
#[derive(Default)]
struct SocketInventory {
    entries: FastHashMap<SocketInventoryKey, CachedProcessSocket>,
    dirty: bool,
}

#[cfg(target_os = "linux")]
impl SocketInventory {
    fn update(&mut self, flow: &AttributedFlow) {
        let Some((local_ip, local_port, _, _)) = endpoints(&flow.flow, flow.pid.local_endpoint)
        else {
            return;
        };
        let process = flow.process.as_ref();
        // Key by local listen endpoint only — not PID — so host/container dual
        // ownership of the same socket collapses to one inventory row.
        let key = SocketInventoryKey {
            address_family: flow.flow.address_family,
            transport_protocol: flow.flow.transport_protocol,
            local_addr: match flow.pid.local_endpoint {
                FLOW_ENDPOINT_A => flow.flow.endpoint_a_addr,
                FLOW_ENDPOINT_B => flow.flow.endpoint_b_addr,
                _ => return,
            },
            local_port,
        };

        let entry = ProcessSnapshotEntry {
            local_ip: local_ip.to_string(),
            local_port: u32::from(local_port),
            transport_protocol: transport_protocol(flow.flow.transport_protocol),
            pid: flow.pid.pid,
            tgid: flow.pid.tgid,
            uid: process.map_or(flow.pid.uid, |details| details.uid),
            gid: process.map_or(flow.pid.gid, |details| details.gid),
            comm: process
                .map(|details| details.comm.clone())
                .unwrap_or_default(),
            redacted_cmdline: cap_redacted_cmdline(
                process
                    .map(|details| details.cmdline.clone())
                    .unwrap_or_default(),
            ),
            container_id: process
                .and_then(|details| details.container_id.clone())
                .unwrap_or_default(),
            workload_identity: None,
        };
        let now = Instant::now();

        match self.entries.get_mut(&key) {
            Some(cached) if cached.entry == entry => {
                cached.last_seen = now;
            }
            Some(cached) => {
                if prefer_snapshot_entry(&entry, &cached.entry) {
                    cached.entry = entry;
                    self.dirty = true;
                }
                cached.last_seen = now;
            }
            None => {
                self.entries.insert(
                    key,
                    CachedProcessSocket {
                        entry,
                        last_seen: now,
                    },
                );
                self.dirty = true;
            }
        }
    }

    fn remove_record(&mut self, record: &FlowAttributionRecord) {
        if !should_remove_inventory(record) {
            return;
        }

        let Some(key) = SocketInventoryKey::from_record(record, None) else {
            return;
        };

        if self.entries.remove(&key).is_some() {
            self.dirty = true;
        }
    }

    fn touch_record(&mut self, record: &FlowAttributionRecord) -> bool {
        let Some(key) = SocketInventoryKey::from_record(record, None) else {
            return false;
        };

        let Some(cached) = self.entries.get_mut(&key) else {
            return false;
        };

        cached.last_seen = Instant::now();
        true
    }

    fn has_listener_for_record(&self, record: &FlowAttributionRecord) -> bool {
        if should_record_inventory(record) || record.tuple.protocol != IPPROTO_TCP {
            return false;
        }

        let Some(exact_key) = SocketInventoryKey::from_record(record, None) else {
            return false;
        };

        if self.entries.contains_key(&exact_key) {
            return true;
        }

        let wildcard_addr = [0; 16];
        if exact_key.local_addr == wildcard_addr {
            return false;
        }

        SocketInventoryKey::from_record(record, Some(wildcard_addr))
            .is_some_and(|wildcard_key| self.entries.contains_key(&wildcard_key))
    }

    fn snapshot_if_dirty(&mut self, observed_at_unix_nano: i64) -> Option<ProcessSnapshot> {
        self.prune(Instant::now());
        if !self.dirty {
            return None;
        }

        let mut entries = self
            .entries
            .values()
            .map(|cached| cached.entry.clone())
            .collect::<Vec<_>>();
        sort_snapshot_entries(&mut entries);

        self.dirty = false;
        Some(ProcessSnapshot {
            fingerprint: snapshot_fingerprint(&entries),
            observed_at_unix_nano,
            entries,
        })
    }

    fn prune(&mut self, now: Instant) {
        let len_before = self.entries.len();
        self.entries
            .retain(|_, entry| now.duration_since(entry.last_seen) < FLOW_ATTRIBUTION_CACHE_TTL);
        if self.entries.len() != len_before {
            self.dirty = true;
        }
    }

    fn is_dirty(&self) -> bool {
        self.dirty
    }
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct SocketInventoryKey {
    address_family: u16,
    transport_protocol: u16,
    local_addr: [u8; 16],
    local_port: u16,
}

#[cfg(target_os = "linux")]
impl SocketInventoryKey {
    fn from_record(record: &FlowAttributionRecord, local_addr: Option<[u8; 16]>) -> Option<Self> {
        let flow = flow_key_from_record(record)?;

        Some(Self {
            address_family: flow.address_family,
            transport_protocol: flow.transport_protocol,
            local_addr: local_addr.unwrap_or(flow.endpoint_a_addr),
            local_port: flow.endpoint_a_port,
        })
    }
}

/// True when `candidate` is a better socket owner than `current` (container
/// over host-only; otherwise accept any identity change).
#[cfg(target_os = "linux")]
fn prefer_snapshot_entry(candidate: &ProcessSnapshotEntry, current: &ProcessSnapshotEntry) -> bool {
    let candidate_container = !candidate.container_id.is_empty();
    let current_container = !current.container_id.is_empty();
    if candidate_container != current_container {
        return candidate_container;
    }
    candidate != current
}

#[cfg(target_os = "linux")]
struct CachedProcessSocket {
    entry: ProcessSnapshotEntry,
    last_seen: Instant,
}

#[cfg(target_os = "linux")]
struct UdpRoleInventory {
    entries: FastHashMap<UdpSocketKey, UdpSocketRole>,
    last_prune: Instant,
}

#[cfg(target_os = "linux")]
impl Default for UdpRoleInventory {
    fn default() -> Self {
        Self {
            entries: FastHashMap::default(),
            last_prune: Instant::now(),
        }
    }
}

#[cfg(target_os = "linux")]
impl UdpRoleInventory {
    fn should_coalesce_record(&mut self, record: &FlowAttributionRecord) -> bool {
        if !matches!(record.event_kind, EVENT_UDP_SEND | EVENT_UDP_RECV)
            || record.tuple.protocol != IPPROTO_UDP
            || record.tuple.source_port == 0
            || record.tuple.destination_port == 0
        {
            return false;
        }

        if likely_udp_client_record(record) {
            return false;
        }

        let now = Instant::now();
        self.prune_if_due(now);

        let Some(key) = UdpSocketKey::from_record(record) else {
            return false;
        };
        let peer = UdpPeerKey::from_record(record);
        let Some(role) = self.role_for_key(key, now) else {
            return false;
        };

        role.last_seen = now;

        if !role.peers.contains(&peer) {
            if role.peers.len() < UDP_SERVER_REMOTE_THRESHOLD {
                role.peers.push(peer);
            }
            if role.peers.len() >= UDP_SERVER_REMOTE_THRESHOLD {
                role.server_side = true;
            }
        }

        role.server_side
    }

    fn role_for_key(&mut self, key: UdpSocketKey, now: Instant) -> Option<&mut UdpSocketRole> {
        if self.entries.contains_key(&key) {
            return self.entries.get_mut(&key);
        }

        if self.entries.len() >= UDP_ROLE_CACHE_MAX_ENTRIES {
            return None;
        }

        Some(self.entries.entry(key).or_insert_with(|| UdpSocketRole {
            peers: Vec::with_capacity(UDP_SERVER_REMOTE_THRESHOLD),
            server_side: false,
            last_seen: now,
        }))
    }

    fn prune_if_due(&mut self, now: Instant) {
        if now.duration_since(self.last_prune) < UDP_ROLE_CACHE_PRUNE_INTERVAL {
            return;
        }

        self.last_prune = now;
        self.entries
            .retain(|_, role| now.duration_since(role.last_seen) < FLOW_ATTRIBUTION_CACHE_TTL);

        if self.entries.len() <= UDP_ROLE_CACHE_MAX_ENTRIES {
            return;
        }

        let mut by_age = self
            .entries
            .iter()
            .map(|(key, role)| (*key, role.last_seen))
            .collect::<Vec<_>>();
        by_age.sort_by_key(|(_, last_seen)| *last_seen);

        let overflow = self
            .entries
            .len()
            .saturating_sub(UDP_ROLE_CACHE_MAX_ENTRIES);
        for (key, _) in by_age.into_iter().take(overflow) {
            self.entries.remove(&key);
        }
    }
}

#[cfg(target_os = "linux")]
fn likely_udp_client_record(record: &FlowAttributionRecord) -> bool {
    record.tuple.source_port >= EPHEMERAL_PORT_FLOOR
        && record.tuple.destination_port < EPHEMERAL_PORT_FLOOR
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct UdpSocketKey {
    address_family: u16,
    local_addr: [u8; 16],
    local_port: u16,
    socket_address: u64,
    pid: u32,
    tgid: u32,
    process_generation_ns: u64,
}

#[cfg(target_os = "linux")]
impl UdpSocketKey {
    fn from_record(record: &FlowAttributionRecord) -> Option<Self> {
        let flow = flow_key_from_record(record)?;

        Some(Self {
            address_family: flow.address_family,
            local_addr: flow.endpoint_a_addr,
            local_port: flow.endpoint_a_port,
            socket_address: record.socket_address,
            pid: record.pid,
            tgid: record.tgid,
            process_generation_ns: record.process_generation_ns,
        })
    }
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct UdpPeerKey {
    remote_addr: [u8; 16],
    remote_port: u16,
}

#[cfg(target_os = "linux")]
impl UdpPeerKey {
    fn from_record(record: &FlowAttributionRecord) -> Self {
        Self {
            remote_addr: record.tuple.destination_addr,
            remote_port: record.tuple.destination_port,
        }
    }
}

#[cfg(target_os = "linux")]
struct UdpSocketRole {
    peers: Vec<UdpPeerKey>,
    server_side: bool,
    last_seen: Instant,
}

#[cfg(target_os = "linux")]
trait AttributionBackend {
    fn drain_records(&mut self, records: &mut Vec<FlowAttributionRecord>);
    fn wait_for_records(&self, timeout: Duration) -> io::Result<bool>;
    fn method(&self) -> &'static str;
}

#[cfg(target_os = "linux")]
struct EbpfAttributionBackend {
    ring: aya::maps::RingBuf<aya::maps::MapData>,
    process_info: aya::maps::HashMap<aya::maps::MapData, u32, ProcessInfoRecord>,
}

#[cfg(target_os = "linux")]
impl EbpfAttributionBackend {
    fn from_ebpf(ebpf: &mut aya::Ebpf) -> anyhow::Result<Self> {
        let flow_events = ebpf.take_map("flow_events").ok_or_else(|| {
            anyhow::anyhow!("flow_events map is missing from netprobe eBPF object")
        })?;
        let process_info = ebpf.take_map("process_info").ok_or_else(|| {
            anyhow::anyhow!("process_info map is missing from netprobe eBPF object")
        })?;

        Ok(Self {
            ring: aya::maps::RingBuf::try_from(flow_events)?,
            process_info: aya::maps::HashMap::try_from(process_info)?,
        })
    }
}

#[cfg(target_os = "linux")]
impl AttributionBackend for EbpfAttributionBackend {
    /// Drain every record currently queued in the FLOW_EVENTS ring buffer,
    /// copying each into an owned `FlowAttributionRecord`. Reading the ring is a
    /// cheap mmap operation (no `bpf_map_get_next_key` scan), so this is
    /// O(new records) rather than O(map capacity) like the old map snapshot —
    /// which is what keeps idle CPU near zero.
    fn drain_records(&mut self, records: &mut Vec<FlowAttributionRecord>) {
        records.clear();
        while let Some(item) = self.ring.next() {
            let bytes = item.as_ref();
            if bytes.len() >= mem::size_of::<FlowAttributionRecord>() {
                // SAFETY: FlowAttributionRecord is #[repr(C)] and mirrors the eBPF
                // layout byte-for-byte; the slot is at least that many bytes. Read
                // unaligned because the ring slot carries no alignment guarantee.
                records.push(unsafe {
                    ptr::read_unaligned(bytes.as_ptr() as *const FlowAttributionRecord)
                });
            }
        }
    }

    fn wait_for_records(&self, timeout: Duration) -> io::Result<bool> {
        if timeout.is_zero() {
            return Ok(false);
        }

        let timeout_ms = timeout.as_millis().min(i32::MAX as u128) as i32;
        let mut poll_fd = libc::pollfd {
            fd: self.ring.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };

        loop {
            let result = unsafe { libc::poll(&mut poll_fd, 1, timeout_ms) };
            if result >= 0 {
                if poll_fd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                    return Err(io::Error::other(format!(
                        "unexpected ring fd poll event: {}",
                        poll_fd.revents
                    )));
                }
                return Ok(result > 0 && poll_fd.revents & libc::POLLIN != 0);
            }

            let err = io::Error::last_os_error();
            if err.kind() != io::ErrorKind::Interrupted {
                return Err(err);
            }
        }
    }

    fn method(&self) -> &'static str {
        "ebpf"
    }
}

#[derive(Clone, Debug)]
pub struct ProcfsEnricher {
    root: PathBuf,
}

impl ProcfsEnricher {
    pub fn host() -> Self {
        Self {
            root: PathBuf::from("/proc"),
        }
    }

    pub fn with_root(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn process_details(&self, record: &ProcessInfoRecord) -> ProcessDetails {
        // Structural gate: only userspace processes own sockets we care about.
        // Kernel tasks (no address space / no exe) are not process owners —
        // never invent identity from idle/softirq context by name denylist.
        if !is_userspace_process(&self.root, record.tgid)
            && !is_userspace_process(&self.root, record.pid)
        {
            return ProcessDetails {
                pid: 0,
                tgid: 0,
                uid: 0,
                gid: 0,
                comm: String::new(),
                cmdline: Vec::new(),
                container_id: None,
                last_seen_ns: record.last_seen_ns,
                process_generation_ns: 0,
            };
        }

        let resolve_pid = if is_userspace_process(&self.root, record.tgid) {
            record.tgid
        } else {
            record.pid
        };
        let comm =
            read_comm(&self.root, resolve_pid).unwrap_or_else(|| comm_from_bytes(&record.comm));
        let container_id = container_id(&self.root, resolve_pid);

        ProcessDetails {
            pid: record.pid,
            tgid: record.tgid,
            uid: record.uid,
            gid: record.gid,
            comm,
            cmdline: redacted_cmdline(&self.root, resolve_pid),
            container_id,
            last_seen_ns: record.last_seen_ns,
            process_generation_ns: record.process_generation_ns,
        }
    }

    fn process_details_for_pid(
        &self,
        pid: u32,
        process_info: &HashMap<u32, ProcessInfoRecord>,
    ) -> Option<ProcessDetails> {
        if !is_userspace_process(&self.root, pid) {
            return None;
        }

        if let Some(record) = process_info.get(&pid) {
            let mut details = self.process_details(record);
            details.pid = pid;
            if details.tgid == 0 {
                return None;
            }
            return Some(details);
        }

        let (uid, gid) = read_status_ids(&self.root, pid).unwrap_or_default();
        let container_id = container_id(&self.root, pid);
        Some(ProcessDetails {
            pid,
            tgid: pid,
            uid,
            gid,
            comm: read_comm(&self.root, pid).unwrap_or_default(),
            cmdline: redacted_cmdline(&self.root, pid),
            container_id,
            last_seen_ns: 0,
            process_generation_ns: 0,
        })
    }

    fn process_snapshot(
        &self,
        process_info: &HashMap<u32, ProcessInfoRecord>,
        observed_at_unix_nano: i64,
    ) -> ProcessSnapshot {
        let sockets = listening_sockets(&self.root);
        let wanted_inodes = sockets.iter().map(|socket| socket.inode).collect();
        let owners = socket_owners(&self.root, wanted_inodes);
        let mut entries = Vec::new();

        for socket in sockets {
            let Some(pids) = owners.get(&socket.inode) else {
                continue;
            };
            // One owner per socket inode: prefer a container-scoped process over
            // host dual-views of the same fd (e.g. k3s-agent vs app in pod netns).
            let mut candidates = Vec::with_capacity(pids.len());
            for pid in pids {
                if let Some(process) = self.process_details_for_pid(*pid, process_info) {
                    candidates.push(process);
                }
            }
            let Some(process) = preferred_process_owner(candidates) else {
                continue;
            };
            entries.push(ProcessSnapshotEntry {
                local_ip: socket.local_ip.to_string(),
                local_port: u32::from(socket.local_port),
                transport_protocol: socket.transport_protocol.clone(),
                pid: process.pid,
                tgid: process.tgid,
                uid: process.uid,
                gid: process.gid,
                comm: process.comm,
                redacted_cmdline: process.cmdline,
                container_id: process.container_id.unwrap_or_default(),
                workload_identity: None,
            });
        }

        sort_snapshot_entries(&mut entries);

        ProcessSnapshot {
            fingerprint: snapshot_fingerprint(&entries),
            observed_at_unix_nano,
            entries,
        }
    }
}

/// Prefer container-scoped process details when multiple PIDs hold the same
/// socket inode. Specificity beats recency: any non-empty container_id wins
/// over host-only; ties break on lower pid for stability.
fn preferred_process_owner(mut candidates: Vec<ProcessDetails>) -> Option<ProcessDetails> {
    candidates.retain(|c| c.pid != 0 && c.tgid != 0 && !c.comm.is_empty());
    if candidates.is_empty() {
        return None;
    }
    candidates.sort_by(|left, right| {
        let left_container = left.container_id.as_ref().is_some_and(|id| !id.is_empty());
        let right_container = right.container_id.as_ref().is_some_and(|id| !id.is_empty());
        right_container
            .cmp(&left_container)
            .then_with(|| left.pid.cmp(&right.pid))
    });
    candidates.into_iter().next()
}

#[cfg(target_os = "linux")]
struct MetadataEnricher {
    procfs: ProcfsEnricher,
    cache: FastHashMap<ProcessDetailsCacheKey, CachedProcessDetails>,
    pending: VecDeque<ProcessInfoRecord>,
    pending_keys: FastHashSet<ProcessDetailsCacheKey>,
    read_budget: MetadataReadBudget,
}

#[cfg(target_os = "linux")]
impl MetadataEnricher {
    fn host() -> Self {
        Self::with_procfs(ProcfsEnricher::host())
    }

    fn with_procfs(procfs: ProcfsEnricher) -> Self {
        Self {
            procfs,
            cache: FastHashMap::default(),
            pending: VecDeque::new(),
            pending_keys: FastHashSet::default(),
            read_budget: MetadataReadBudget::new(
                PROCESS_DETAILS_COLD_READS_PER_SECOND,
                PROCESS_DETAILS_COLD_READ_BURST,
            ),
        }
    }

    fn process_details(
        &mut self,
        record: &ProcessInfoRecord,
    ) -> (ProcessDetails, ProcessDetailsCacheKey, bool) {
        self.process_details_with_priority(record, false)
    }

    fn process_details_priority(
        &mut self,
        record: &ProcessInfoRecord,
    ) -> (ProcessDetails, ProcessDetailsCacheKey, bool) {
        self.process_details_with_priority(record, true)
    }

    fn process_details_with_priority(
        &mut self,
        record: &ProcessInfoRecord,
        priority: bool,
    ) -> (ProcessDetails, ProcessDetailsCacheKey, bool) {
        let key = ProcessDetailsCacheKey::from(record);
        let now = Instant::now();

        if let Some(cached) = self.cache.get_mut(&key)
            && now.duration_since(cached.updated_at) < PROCESS_DETAILS_CACHE_TTL
        {
            cached.last_used = now;
            return (cached.details.clone(), key, false);
        }

        if self.read_budget.try_acquire(now) {
            let details = self.procfs.process_details(record);
            self.cache_process_details(key, details.clone(), now);
            return (details, key, true);
        }

        self.queue_pending_metadata(key, *record, priority);

        (process_details_from_record(record), key, false)
    }

    fn queue_pending_metadata(
        &mut self,
        key: ProcessDetailsCacheKey,
        record: ProcessInfoRecord,
        priority: bool,
    ) {
        if self.pending_keys.insert(key) {
            if priority {
                self.pending.push_front(record);
            } else {
                self.pending.push_back(record);
            }
            self.trim_pending_metadata(priority);
            return;
        }

        if priority {
            if let Some(index) = self
                .pending
                .iter()
                .position(|pending| ProcessDetailsCacheKey::from(pending) == key)
            {
                let _ = self.pending.remove(index);
            }
            self.pending.push_front(record);
        }
    }

    fn trim_pending_metadata(&mut self, priority_insert: bool) {
        while self.pending.len() > PROCESS_DETAILS_PENDING_MAX_ENTRIES {
            let removed = if priority_insert {
                self.pending.pop_back()
            } else {
                self.pending.pop_front()
            };
            if let Some(record) = removed {
                self.pending_keys
                    .remove(&ProcessDetailsCacheKey::from(&record));
            } else {
                break;
            }
        }
    }

    fn process_pending(&mut self) -> Vec<(ProcessDetailsCacheKey, ProcessDetails)> {
        let mut updated = Vec::new();
        while self.read_budget.try_acquire(Instant::now()) {
            let Some(record) = self.pending.pop_front() else {
                break;
            };
            let key = ProcessDetailsCacheKey::from(&record);
            self.pending_keys.remove(&key);

            let now = Instant::now();
            let details = self.procfs.process_details(&record);
            self.cache_process_details(key, details.clone(), now);
            updated.push((key, details));
        }
        updated
    }

    fn cache_len(&self) -> usize {
        self.cache.len()
    }

    fn prune(&mut self, now: Instant) {
        if self.cache.len() < PROCESS_DETAILS_CACHE_MAX_ENTRIES {
            return;
        }

        self.cache
            .retain(|_, cached| now.duration_since(cached.last_used) < PROCESS_DETAILS_CACHE_TTL);

        if self.cache.len() >= PROCESS_DETAILS_CACHE_MAX_ENTRIES {
            self.cache.clear();
        }
    }

    fn cache_process_details(
        &mut self,
        key: ProcessDetailsCacheKey,
        details: ProcessDetails,
        now: Instant,
    ) {
        self.prune(now);
        self.pending_keys.remove(&key);
        self.cache.insert(
            key,
            CachedProcessDetails {
                details,
                updated_at: now,
                last_used: now,
            },
        );
    }
}

#[cfg(target_os = "linux")]
struct MetadataReadBudget {
    available: u32,
    max_burst: u32,
    refill_per_second: u32,
    last_refill: Instant,
}

#[cfg(target_os = "linux")]
impl MetadataReadBudget {
    fn new(refill_per_second: u32, max_burst: u32) -> Self {
        Self {
            available: max_burst,
            max_burst,
            refill_per_second,
            last_refill: Instant::now(),
        }
    }

    fn try_acquire(&mut self, now: Instant) -> bool {
        self.refill(now);
        if self.available == 0 {
            return false;
        }

        self.available -= 1;
        true
    }

    fn refill(&mut self, now: Instant) {
        let elapsed = now.duration_since(self.last_refill).as_secs();
        if elapsed == 0 {
            return;
        }

        let refill = elapsed
            .saturating_mul(u64::from(self.refill_per_second))
            .min(u64::from(u32::MAX)) as u32;
        self.available = self.available.saturating_add(refill).min(self.max_burst);
        self.last_refill = now;
    }
}

#[cfg(target_os = "linux")]
pub struct AyaAttributionReader {
    backend: EbpfAttributionBackend,
    metadata: MetadataEnricher,
    socket_inventory: SocketInventory,
    udp_roles: UdpRoleInventory,
}

#[cfg(target_os = "linux")]
impl AyaAttributionReader {
    pub fn from_ebpf(ebpf: &mut aya::Ebpf) -> anyhow::Result<Self> {
        Ok(Self {
            backend: EbpfAttributionBackend::from_ebpf(ebpf)?,
            metadata: MetadataEnricher::host(),
            socket_inventory: SocketInventory::default(),
            udp_roles: UdpRoleInventory::default(),
        })
    }

    fn drain_records(&mut self, records: &mut Vec<FlowAttributionRecord>) {
        self.backend.drain_records(records)
    }

    fn wait_for_records(&self, timeout: Duration) -> io::Result<bool> {
        self.backend.wait_for_records(timeout)
    }

    /// Build an `AttributedFlow` from a ring record. Returns `None` for records
    /// without a usable 5-tuple (the per-packet tcp/udp probes emit empty
    /// tuples). The record's `tuple` is directional with the local socket as the
    /// source, so endpoint A is always the local side — matching the local/remote
    /// semantics the map-snapshot path produced via the canonical key.
    fn attributed_flow_from_record_basic(
        record: &FlowAttributionRecord,
        coalesce_service: bool,
    ) -> Option<AttributedFlow> {
        let flow = attribution_flow_key_from_record(record, coalesce_service)?;
        let process = Some(process_details_from_record(&ProcessInfoRecord {
            version: record.version,
            reserved: 0,
            pid: record.pid,
            tgid: record.tgid,
            uid: record.uid,
            gid: record.gid,
            last_seen_ns: 0,
            process_generation_ns: record.process_generation_ns,
            comm: record.comm,
        }));
        Some(AttributedFlow {
            flow,
            pid: FlowPidRecord {
                version: record.version,
                event_kind: record.event_kind,
                pid: record.pid,
                tgid: record.tgid,
                uid: record.uid,
                gid: record.gid,
                socket_address: record.socket_address,
                last_seen_ns: 0,
                process_generation_ns: record.process_generation_ns,
                old_state: record.old_state,
                new_state: record.new_state,
                local_endpoint: FLOW_ENDPOINT_A,
                reserved: [0; 7],
            },
            process,
        })
    }

    fn attributed_flow_from_record_enriched(
        &mut self,
        record: &FlowAttributionRecord,
        metrics: &Metrics,
        coalesce_service: bool,
    ) -> Option<AttributedFlow> {
        let flow = attribution_flow_key_from_record(record, coalesce_service)?;
        let pid = FlowPidRecord {
            version: record.version,
            event_kind: record.event_kind,
            pid: record.pid,
            tgid: record.tgid,
            uid: record.uid,
            gid: record.gid,
            socket_address: record.socket_address,
            last_seen_ns: 0,
            process_generation_ns: record.process_generation_ns,
            old_state: record.old_state,
            new_state: record.new_state,
            local_endpoint: FLOW_ENDPOINT_A,
            reserved: [0; 7],
        };
        let info = ProcessInfoRecord {
            version: record.version,
            reserved: 0,
            pid: record.pid,
            tgid: record.tgid,
            uid: record.uid,
            gid: record.gid,
            last_seen_ns: 0,
            process_generation_ns: record.process_generation_ns,
            comm: record.comm,
        };
        let (details, _, cold_read) = self.metadata.process_details(&info);
        if cold_read {
            metrics.inc_attribution_backend_events("procfs", "metadata_cold_read", 1);
        }
        metrics.set_attribution_cache_entries("process_metadata", self.metadata.cache_len());
        let process = Some(details);
        Some(AttributedFlow { flow, pid, process })
    }

    fn record_inventory(&mut self, record: &FlowAttributionRecord, flow: &AttributedFlow) {
        if should_record_inventory(record) {
            self.socket_inventory.update(flow);
        }
    }

    fn remove_inventory_record(&mut self, record: &FlowAttributionRecord) {
        self.socket_inventory.remove_record(record);
    }

    fn touch_inventory_record(&mut self, record: &FlowAttributionRecord) -> bool {
        self.socket_inventory.touch_record(record)
    }

    fn has_listener_for_record(&self, record: &FlowAttributionRecord) -> bool {
        self.socket_inventory.has_listener_for_record(record)
    }

    fn should_coalesce_record(&mut self, record: &FlowAttributionRecord) -> bool {
        if self.has_listener_for_record(record) || likely_service_side_record(record) {
            return true;
        }

        self.udp_roles.should_coalesce_record(record)
    }

    fn process_snapshot_if_dirty(&mut self) -> Option<ProcessSnapshot> {
        let observed_at_unix_nano = now_unix_nano();
        if let Some(snapshot) = self
            .socket_inventory
            .snapshot_if_dirty(observed_at_unix_nano)
        {
            return Some(snapshot);
        }

        if !self.socket_inventory.entries.is_empty() {
            return None;
        }
        None
    }

    fn backend_method(&self) -> &'static str {
        self.backend.method()
    }

    fn inventory_len(&self) -> usize {
        self.socket_inventory.entries.len()
    }

    fn inventory_dirty(&self) -> bool {
        self.socket_inventory.is_dirty()
    }

    fn process_pending_metadata(&mut self) -> Vec<(ProcessDetailsCacheKey, ProcessDetails)> {
        self.metadata.process_pending()
    }

    fn metadata_cache_len(&self) -> usize {
        self.metadata.cache_len()
    }

    fn refresh_cached_process_details(
        &mut self,
        record: &FlowAttributionRecord,
        metrics: &Metrics,
        cached: &mut CachedAttribution,
        now: Instant,
    ) -> bool {
        if process_metadata_complete(&cached.event) {
            return false;
        }
        if now.duration_since(cached.last_metadata_attempt) < PROCESS_DETAILS_RETRY_INTERVAL {
            return false;
        }

        cached.last_metadata_attempt = now;
        let info = ProcessInfoRecord {
            version: record.version,
            reserved: 0,
            pid: record.pid,
            tgid: record.tgid,
            uid: record.uid,
            gid: record.gid,
            last_seen_ns: 0,
            process_generation_ns: record.process_generation_ns,
            comm: record.comm,
        };
        let (details, _, cold_read) = self.metadata.process_details_priority(&info);
        if cold_read {
            metrics.inc_attribution_backend_events("procfs", "metadata_cold_read", 1);
        }
        metrics.set_attribution_cache_entries("process_metadata", self.metadata.cache_len());

        apply_process_details_to_event(Arc::make_mut(&mut cached.event), &details)
    }
}

#[cfg(target_os = "linux")]
fn process_metadata_complete(event: &FlowAttributionEvent) -> bool {
    !event.redacted_cmdline.is_empty() && !event.container_id.is_empty()
}

#[cfg(target_os = "linux")]
#[allow(dead_code)]
pub struct FlowAttributionRuntime {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug)]
pub struct FlowAttributionRuntimeConfig {
    pub process_snapshot_interval: Option<Duration>,
    pub resend_interval: Option<Duration>,
}

#[cfg(target_os = "linux")]
#[allow(dead_code)]
impl FlowAttributionRuntime {
    pub fn start(
        mut reader: AyaAttributionReader,
        tx: Option<EventSender<Arc<FlowAttributionEvent>>>,
        process_snapshot_tx: tokio::sync::broadcast::Sender<ProcessSnapshot>,
        external_flow_matcher: SharedExternalFlowMatcher,
        metrics: Metrics,
        runtime_config: FlowAttributionRuntimeConfig,
    ) -> std::io::Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let stop_worker = Arc::clone(&stop);
        let thread = thread::Builder::new()
            .name("netprobe-flow-attribution-ring-reader".to_owned())
            .spawn(move || {
                // Live attribution cache, keyed by (flow, pid, tgid). New flows are
                // broadcast immediately and core persists them for delayed NetFlow
                // correlation. Whole-cache re-broadcast is opt-in only because it is
                // O(cache) work on the ring-reader thread.
                let mut cache = FlowAttributionCache::default();
                let mut process_index = ProcessAttributionIndex::default();
                let mut expiry_queue: AttributionExpiryQueue = BinaryHeap::new();
                let mut ring_records = Vec::with_capacity(1024);
                let mut next_expiry_sequence = 0_u64;
                let mut last_process_snapshot = runtime_config
                    .process_snapshot_interval
                    .map(|interval| Instant::now() - interval);
                let mut last_dirty_process_snapshot =
                    Instant::now() - PROCESS_SNAPSHOT_DIRTY_MIN_INTERVAL;
                let mut last_resend = Instant::now();
                let mut last_cache_prune = Instant::now();
                while !stop_worker.load(Ordering::Relaxed) {
                    drain_ring(
                        &mut reader,
                        tx.as_ref(),
                        &external_flow_matcher,
                        &metrics,
                        &mut cache,
                        &mut process_index,
                        &mut expiry_queue,
                        &mut next_expiry_sequence,
                        &mut ring_records,
                    );
                    let enriched = reader.process_pending_metadata();
                    if !enriched.is_empty() {
                        refresh_enriched_attributions(
                            tx.as_ref(),
                            &external_flow_matcher,
                            &metrics,
                            &mut cache,
                            &process_index,
                            enriched,
                        );
                        metrics.set_attribution_cache_entries(
                            "process_metadata",
                            reader.metadata_cache_len(),
                        );
                    }
                    if reader.inventory_dirty()
                        && last_dirty_process_snapshot.elapsed()
                            >= PROCESS_SNAPSHOT_DIRTY_MIN_INTERVAL
                    {
                        emit_process_snapshot(&mut reader, &process_snapshot_tx, &metrics);
                        last_dirty_process_snapshot = Instant::now();
                    }
                    if let Some(resend_interval) = runtime_config.resend_interval
                        && last_resend.elapsed() >= resend_interval
                    {
                        resend_cache(
                            tx.as_ref(),
                            &external_flow_matcher,
                            &metrics,
                            &mut cache,
                            &mut process_index,
                            &mut expiry_queue,
                            &mut next_expiry_sequence,
                        );
                        last_resend = Instant::now();
                    }
                    if last_cache_prune.elapsed() >= FLOW_ATTRIBUTION_CACHE_PRUNE_INTERVAL
                        || cache.len() > FLOW_ATTRIBUTION_CACHE_MAX_ENTRIES
                    {
                        prune_attribution_cache(
                            &mut cache,
                            &mut process_index,
                            &external_flow_matcher,
                            &mut expiry_queue,
                            &mut next_expiry_sequence,
                            Instant::now(),
                        );
                        metrics.set_attribution_cache_entries("flow_attribution", cache.len());
                        last_cache_prune = Instant::now();
                    }
                    if let Some(interval) = runtime_config.process_snapshot_interval {
                        let last = last_process_snapshot.get_or_insert_with(Instant::now);
                        if last.elapsed() >= interval {
                            emit_process_snapshot(&mut reader, &process_snapshot_tx, &metrics);
                            *last = Instant::now();
                        }
                    }

                    let wait = ring_wait_duration(
                        last_resend,
                        runtime_config.resend_interval,
                        runtime_config.process_snapshot_interval,
                        last_process_snapshot,
                    );
                    if let Err(err) = reader.wait_for_records(wait) {
                        log::warn!("flow attribution ring poll failed: {err}");
                        thread::sleep(wait);
                    }
                }
            })?;

        Ok(Self {
            stop,
            thread: Some(thread),
        })
    }
}

#[cfg(target_os = "linux")]
impl Drop for FlowAttributionRuntime {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take()
            && thread.join().is_err()
        {
            log::warn!("flow attribution map reader thread panicked during shutdown");
        }
    }
}

#[cfg(target_os = "linux")]
fn ring_wait_duration(
    last_resend: Instant,
    resend_interval: Option<Duration>,
    process_snapshot_interval: Option<Duration>,
    last_process_snapshot: Option<Instant>,
) -> Duration {
    let resend_wait = resend_interval
        .map(|interval| interval.saturating_sub(last_resend.elapsed()))
        .unwrap_or(FLOW_ATTRIBUTION_RING_MAX_WAIT);
    let process_wait = match (process_snapshot_interval, last_process_snapshot) {
        (Some(interval), Some(last)) => interval.saturating_sub(last.elapsed()),
        (Some(_), None) => Duration::ZERO,
        (None, _) => FLOW_ATTRIBUTION_RING_MAX_WAIT,
    };

    resend_wait
        .min(process_wait)
        .min(FLOW_ATTRIBUTION_RING_MAX_WAIT)
}

#[cfg(target_os = "linux")]
struct CachedAttribution {
    event: Arc<FlowAttributionEvent>,
    process_key: ProcessDetailsCacheKey,
    last_seen: Instant,
    last_emitted: Instant,
    last_emitted_fingerprint: u64,
    last_metadata_attempt: Instant,
}

#[cfg(target_os = "linux")]
type FlowAttributionCache = FastHashMap<FlowAttributionJoinKey, CachedAttribution>;

#[cfg(target_os = "linux")]
type ProcessAttributionIndex =
    FastHashMap<ProcessDetailsCacheKey, FastHashSet<FlowAttributionJoinKey>>;

#[cfg(target_os = "linux")]
type AttributionExpiryQueue = BinaryHeap<Reverse<AttributionExpiry>>;

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct ProcessDetailsCacheKey {
    tgid: u32,
    uid: u32,
    gid: u32,
    process_generation_ns: u64,
}

#[cfg(target_os = "linux")]
impl From<&ProcessInfoRecord> for ProcessDetailsCacheKey {
    fn from(value: &ProcessInfoRecord) -> Self {
        Self {
            tgid: value.tgid,
            uid: value.uid,
            gid: value.gid,
            process_generation_ns: value.process_generation_ns,
        }
    }
}

#[cfg(target_os = "linux")]
impl From<&FlowAttributionRecord> for ProcessDetailsCacheKey {
    fn from(value: &FlowAttributionRecord) -> Self {
        Self {
            tgid: value.tgid,
            uid: value.uid,
            gid: value.gid,
            process_generation_ns: value.process_generation_ns,
        }
    }
}

#[cfg(target_os = "linux")]
struct CachedProcessDetails {
    details: ProcessDetails,
    updated_at: Instant,
    last_used: Instant,
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug)]
struct AttributionExpiry {
    expires_at: Instant,
    sequence: u64,
    key: FlowAttributionJoinKey,
}

#[cfg(target_os = "linux")]
const ATTRIBUTION_EVENT_KIND_LABELS: [&str; 8] = [
    "tcp_connect",
    "tcp_accept",
    "tcp_close",
    "udp_send",
    "udp_recv",
    "inet_sock_set_state",
    "icmp_send",
    "other",
];

#[cfg(target_os = "linux")]
const ATTRIBUTION_PROTOCOL_LABELS: [&str; 5] = ["icmp", "tcp", "udp", "icmpv6", "other"];

#[cfg(target_os = "linux")]
fn attribution_protocol_label(protocol: u16) -> &'static str {
    ATTRIBUTION_PROTOCOL_LABELS[attribution_protocol_index(protocol)]
}

#[cfg(target_os = "linux")]
const ATTRIBUTION_OUTCOME_CLOSE: usize = 0;
#[cfg(target_os = "linux")]
const ATTRIBUTION_OUTCOME_TUPLE_REJECTED: usize = 1;
#[cfg(target_os = "linux")]
const ATTRIBUTION_OUTCOME_OWNER_MISS: usize = 2;
#[cfg(target_os = "linux")]
const ATTRIBUTION_OUTCOME_CACHED: usize = 3;
#[cfg(target_os = "linux")]
const ATTRIBUTION_OUTCOME_UPDATED: usize = 4;
#[cfg(target_os = "linux")]
const ATTRIBUTION_OUTCOME_NEW: usize = 5;

#[cfg(target_os = "linux")]
const ATTRIBUTION_OUTCOME_LABELS: [&str; 6] = [
    "close",
    "tuple_rejected",
    "owner_miss",
    "cached",
    "updated",
    "new",
];

#[cfg(target_os = "linux")]
const ATTRIBUTION_RECORD_METRIC_SLOTS: usize = ATTRIBUTION_EVENT_KIND_LABELS.len()
    * ATTRIBUTION_PROTOCOL_LABELS.len()
    * ATTRIBUTION_OUTCOME_LABELS.len()
    * 2;

#[cfg(target_os = "linux")]
struct DrainMetricAccumulator {
    backend_method: &'static str,
    backend_hits: u64,
    backend_misses: u64,
    attribution_records: [u64; ATTRIBUTION_RECORD_METRIC_SLOTS],
    touched_record_slots: [usize; ATTRIBUTION_RECORD_METRIC_SLOTS],
    touched_record_slot_count: usize,
}

#[cfg(target_os = "linux")]
impl DrainMetricAccumulator {
    fn new(backend_method: &'static str) -> Self {
        Self {
            backend_method,
            backend_hits: 0,
            backend_misses: 0,
            attribution_records: [0; ATTRIBUTION_RECORD_METRIC_SLOTS],
            touched_record_slots: [0; ATTRIBUTION_RECORD_METRIC_SLOTS],
            touched_record_slot_count: 0,
        }
    }

    fn inc_backend_hit(&mut self) {
        self.backend_hits = self.backend_hits.saturating_add(1);
    }

    fn inc_backend_miss(&mut self) {
        self.backend_misses = self.backend_misses.saturating_add(1);
    }

    fn inc_record(
        &mut self,
        event_kind: u16,
        protocol: u16,
        outcome_index: usize,
        service_coalesced: bool,
    ) {
        let slot = attribution_record_metric_slot(
            attribution_event_kind_index(event_kind),
            attribution_protocol_index(protocol),
            outcome_index,
            service_coalesced,
        );
        if self.attribution_records[slot] == 0 {
            self.touched_record_slots[self.touched_record_slot_count] = slot;
            self.touched_record_slot_count += 1;
        }
        self.attribution_records[slot] = self.attribution_records[slot].saturating_add(1);
    }

    fn flush(&self, metrics: &Metrics) {
        if self.backend_hits > 0 {
            metrics.inc_attribution_backend_events(self.backend_method, "hit", self.backend_hits);
        }
        if self.backend_misses > 0 {
            metrics.inc_attribution_backend_events(
                self.backend_method,
                "miss",
                self.backend_misses,
            );
        }

        for slot in self
            .touched_record_slots
            .iter()
            .take(self.touched_record_slot_count)
            .copied()
        {
            let count = self.attribution_records[slot];

            let service_index = slot % 2;
            let outcome_index = (slot / 2) % ATTRIBUTION_OUTCOME_LABELS.len();
            let protocol_index =
                (slot / (2 * ATTRIBUTION_OUTCOME_LABELS.len())) % ATTRIBUTION_PROTOCOL_LABELS.len();
            let event_kind_index =
                slot / (2 * ATTRIBUTION_OUTCOME_LABELS.len() * ATTRIBUTION_PROTOCOL_LABELS.len());

            metrics.inc_attribution_records(
                ATTRIBUTION_EVENT_KIND_LABELS[event_kind_index],
                ATTRIBUTION_PROTOCOL_LABELS[protocol_index],
                ATTRIBUTION_OUTCOME_LABELS[outcome_index],
                service_index == 1,
                count,
            );
        }
    }
}

#[cfg(target_os = "linux")]
fn attribution_record_metric_slot(
    event_kind_index: usize,
    protocol_index: usize,
    outcome_index: usize,
    service_coalesced: bool,
) -> usize {
    (((event_kind_index * ATTRIBUTION_PROTOCOL_LABELS.len() + protocol_index)
        * ATTRIBUTION_OUTCOME_LABELS.len()
        + outcome_index)
        * 2)
        + usize::from(service_coalesced)
}

#[cfg(target_os = "linux")]
impl PartialEq for AttributionExpiry {
    fn eq(&self, other: &Self) -> bool {
        self.expires_at == other.expires_at && self.sequence == other.sequence
    }
}

#[cfg(target_os = "linux")]
impl Eq for AttributionExpiry {}

#[cfg(target_os = "linux")]
impl PartialOrd for AttributionExpiry {
    fn partial_cmp(&self, other: &Self) -> Option<CmpOrdering> {
        Some(self.cmp(other))
    }
}

#[cfg(target_os = "linux")]
impl Ord for AttributionExpiry {
    fn cmp(&self, other: &Self) -> CmpOrdering {
        self.expires_at
            .cmp(&other.expires_at)
            .then_with(|| self.sequence.cmp(&other.sequence))
    }
}

// Drain the ring buffer and emit a flow-attribution event for every newly-seen
// flow. A record for an already-cached flow refreshes the cached event (so the
// next resend carries its latest state) without re-broadcasting. A close record
// evicts the flow. Returns the number of records drained so the caller can
// distinguish a busy ring (loop again) from an idle one (sleep).
#[cfg(target_os = "linux")]
#[allow(clippy::too_many_arguments)]
fn drain_ring(
    reader: &mut AyaAttributionReader,
    tx: Option<&EventSender<Arc<FlowAttributionEvent>>>,
    external_flow_matcher: &SharedExternalFlowMatcher,
    metrics: &Metrics,
    cache: &mut FlowAttributionCache,
    process_index: &mut ProcessAttributionIndex,
    expiry_queue: &mut AttributionExpiryQueue,
    next_expiry_sequence: &mut u64,
    records: &mut Vec<FlowAttributionRecord>,
) -> usize {
    reader.drain_records(records);
    let drained = records.len();
    let mut drain_metrics = DrainMetricAccumulator::new(reader.backend_method());
    for record in records.iter() {
        let coalesce_service = reader.should_coalesce_record(record);

        if record.event_kind == EVENT_TCP_CLOSE {
            drain_metrics.inc_record(
                record.event_kind,
                record.tuple.protocol,
                ATTRIBUTION_OUTCOME_CLOSE,
                coalesce_service,
            );
            reader.remove_inventory_record(record);
            if let Some(key) = join_key_from_record(record, coalesce_service) {
                touch_closed_cached_attribution(cache, &key);
            }
            continue;
        }
        if record.event_kind == EVENT_INET_SOCK_SET_STATE && record.new_state == TCP_CLOSE_STATE {
            drain_metrics.inc_record(
                record.event_kind,
                record.tuple.protocol,
                ATTRIBUTION_OUTCOME_CLOSE,
                coalesce_service,
            );
            reader.remove_inventory_record(record);
            if let Some(key) = join_key_from_record(record, coalesce_service) {
                touch_closed_cached_attribution(cache, &key);
            }
            continue;
        }
        let flow = match validate_attribution_record(record, coalesce_service) {
            Ok(flow) => flow,
            Err(AttributionRecordValidationError::TupleRejected) => {
                drain_metrics.inc_record(
                    record.event_kind,
                    record.tuple.protocol,
                    ATTRIBUTION_OUTCOME_TUPLE_REJECTED,
                    coalesce_service,
                );
                drain_metrics.inc_backend_miss();
                metrics.inc_attribution_stage(
                    "tuple_extraction",
                    attribution_protocol_label(record.tuple.protocol),
                    "rejected",
                );
                continue;
            }
            Err(AttributionRecordValidationError::OwnerMiss) => {
                metrics.inc_attribution_stage(
                    "tuple_extraction",
                    attribution_protocol_label(record.tuple.protocol),
                    "accepted",
                );
                drain_metrics.inc_record(
                    record.event_kind,
                    record.tuple.protocol,
                    ATTRIBUTION_OUTCOME_OWNER_MISS,
                    coalesce_service,
                );
                drain_metrics.inc_backend_miss();
                metrics.inc_attribution_stage(
                    "owner_resolution",
                    attribution_protocol_label(record.tuple.protocol),
                    "miss",
                );
                continue;
            }
        };
        metrics.inc_attribution_stage(
            "tuple_extraction",
            attribution_protocol_label(record.tuple.protocol),
            "accepted",
        );
        metrics.inc_attribution_stage(
            "owner_resolution",
            attribution_protocol_label(record.tuple.protocol),
            "hit",
        );
        let key = FlowAttributionJoinKey {
            flow,
            pid: record.pid,
            tgid: record.tgid,
            process_generation_ns: record.process_generation_ns,
        };
        if let Some(existing) = cache.get_mut(&key) {
            drain_metrics.inc_backend_hit();
            if !should_record_inventory(record) || reader.touch_inventory_record(record) {
                drain_metrics.inc_record(
                    record.event_kind,
                    record.tuple.protocol,
                    ATTRIBUTION_OUTCOME_CACHED,
                    coalesce_service,
                );
                let now = Instant::now();
                Arc::make_mut(&mut existing.event).observed_at_unix_nano = now_unix_nano();
                if reader.refresh_cached_process_details(record, metrics, existing, now) {
                    Arc::make_mut(&mut existing.event).observed_at_unix_nano = now_unix_nano();
                }
                existing.last_seen = now;
                maybe_emit_cached_attribution(tx, metrics, existing, now);
                continue;
            }
        }
        let should_record_inventory = should_record_inventory(record);
        let needs_enrichment = tx.is_some() || should_record_inventory;
        let flow = if needs_enrichment {
            reader.attributed_flow_from_record_enriched(record, metrics, coalesce_service)
        } else {
            AyaAttributionReader::attributed_flow_from_record_basic(record, coalesce_service)
        };
        let Some(flow) = flow else {
            drain_metrics.inc_record(
                record.event_kind,
                record.tuple.protocol,
                ATTRIBUTION_OUTCOME_TUPLE_REJECTED,
                coalesce_service,
            );
            drain_metrics.inc_backend_miss();
            continue;
        };
        drain_metrics.inc_backend_hit();
        if should_record_inventory {
            reader.record_inventory(record, &flow);
            metrics.set_attribution_cache_entries("socket_inventory", reader.inventory_len());
        }
        let Some(event) = flow.event() else {
            continue;
        };
        let process_key = ProcessDetailsCacheKey::from(record);
        let event = Arc::new(event);
        let now = Instant::now();
        if let Some(existing) = cache.get_mut(&key) {
            drain_metrics.inc_record(
                record.event_kind,
                record.tuple.protocol,
                ATTRIBUTION_OUTCOME_UPDATED,
                coalesce_service,
            );
            existing.event = event;
            if existing.process_key != process_key {
                move_process_index(process_index, key, existing.process_key, process_key);
                existing.process_key = process_key;
            }
            existing.last_seen = now;
            maybe_emit_cached_attribution(tx, metrics, existing, now);
        } else {
            drain_metrics.inc_record(
                record.event_kind,
                record.tuple.protocol,
                ATTRIBUTION_OUTCOME_NEW,
                coalesce_service,
            );
            external_flow_matcher.observe_attribution_key(key.flow, &event);
            emit_raw_flow_attribution_event(tx, metrics, Arc::clone(&event));
            insert_cached_attribution(
                cache,
                process_index,
                expiry_queue,
                next_expiry_sequence,
                key,
                CachedAttribution {
                    last_emitted: now,
                    last_emitted_fingerprint: attribution_event_fingerprint(&event),
                    event,
                    process_key,
                    last_seen: now,
                    last_metadata_attempt: now,
                },
            );
        }
    }
    drain_metrics.flush(metrics);
    drained
}

// Prune stale entries, then re-broadcast every live attribution. This is an
// explicit compatibility knob for deployments that need periodic replays; the
// default data path emits on eBPF events and relies on core-side persistence for
// delayed NetFlow correlation.
#[cfg(target_os = "linux")]
fn resend_cache(
    tx: Option<&EventSender<Arc<FlowAttributionEvent>>>,
    external_flow_matcher: &SharedExternalFlowMatcher,
    metrics: &Metrics,
    cache: &mut FlowAttributionCache,
    process_index: &mut ProcessAttributionIndex,
    expiry_queue: &mut AttributionExpiryQueue,
    next_expiry_sequence: &mut u64,
) {
    prune_attribution_cache(
        cache,
        process_index,
        external_flow_matcher,
        expiry_queue,
        next_expiry_sequence,
        Instant::now(),
    );
    let now = Instant::now();
    for entry in cache.values_mut() {
        emit_cached_attribution(tx, metrics, entry, now);
    }
}

#[cfg(target_os = "linux")]
fn insert_cached_attribution(
    cache: &mut FlowAttributionCache,
    process_index: &mut ProcessAttributionIndex,
    expiry_queue: &mut AttributionExpiryQueue,
    next_expiry_sequence: &mut u64,
    key: FlowAttributionJoinKey,
    entry: CachedAttribution,
) {
    let last_seen = entry.last_seen;
    let process_key = entry.process_key;
    if let Some(previous) = cache.insert(key, entry) {
        remove_process_index_key(process_index, previous.process_key, &key);
    }
    process_index.entry(process_key).or_default().insert(key);
    push_attribution_expiry(expiry_queue, next_expiry_sequence, key, last_seen);
}

#[cfg(target_os = "linux")]
fn remove_cached_attribution(
    cache: &mut FlowAttributionCache,
    process_index: &mut ProcessAttributionIndex,
    key: &FlowAttributionJoinKey,
) -> Option<CachedAttribution> {
    let removed = cache.remove(key)?;
    remove_process_index_key(process_index, removed.process_key, key);
    Some(removed)
}

#[cfg(target_os = "linux")]
fn touch_closed_cached_attribution(cache: &mut FlowAttributionCache, key: &FlowAttributionJoinKey) {
    if let Some(entry) = cache.get_mut(key) {
        entry.last_seen = Instant::now();
    }
}

#[cfg(target_os = "linux")]
fn move_process_index(
    process_index: &mut ProcessAttributionIndex,
    key: FlowAttributionJoinKey,
    old_process_key: ProcessDetailsCacheKey,
    new_process_key: ProcessDetailsCacheKey,
) {
    remove_process_index_key(process_index, old_process_key, &key);
    process_index
        .entry(new_process_key)
        .or_default()
        .insert(key);
}

#[cfg(target_os = "linux")]
fn remove_process_index_key(
    process_index: &mut ProcessAttributionIndex,
    process_key: ProcessDetailsCacheKey,
    key: &FlowAttributionJoinKey,
) {
    let Some(keys) = process_index.get_mut(&process_key) else {
        return;
    };
    keys.remove(key);
    if keys.is_empty() {
        process_index.remove(&process_key);
    }
}

#[cfg(target_os = "linux")]
fn push_attribution_expiry(
    expiry_queue: &mut AttributionExpiryQueue,
    next_expiry_sequence: &mut u64,
    key: FlowAttributionJoinKey,
    last_seen: Instant,
) {
    let sequence = *next_expiry_sequence;
    *next_expiry_sequence = next_expiry_sequence.wrapping_add(1);
    expiry_queue.push(Reverse(AttributionExpiry {
        expires_at: last_seen + FLOW_ATTRIBUTION_CACHE_TTL,
        sequence,
        key,
    }));
}

#[cfg(target_os = "linux")]
fn prune_attribution_cache(
    cache: &mut FlowAttributionCache,
    process_index: &mut ProcessAttributionIndex,
    external_flow_matcher: &SharedExternalFlowMatcher,
    expiry_queue: &mut AttributionExpiryQueue,
    next_expiry_sequence: &mut u64,
    now: Instant,
) {
    let mut remove_keys = Vec::new();

    while let Some(Reverse(expiry)) = expiry_queue.peek().copied() {
        if expiry.expires_at > now {
            break;
        }
        expiry_queue.pop();

        let Some(entry) = cache.get(&expiry.key) else {
            continue;
        };
        let refreshed_expires_at = entry.last_seen + FLOW_ATTRIBUTION_CACHE_TTL;
        if refreshed_expires_at <= now {
            remove_keys.push(expiry.key);
        } else {
            push_attribution_expiry(
                expiry_queue,
                next_expiry_sequence,
                expiry.key,
                entry.last_seen,
            );
        }
    }

    if cache.len().saturating_sub(remove_keys.len()) > FLOW_ATTRIBUTION_CACHE_MAX_ENTRIES {
        let remove_set = remove_keys.iter().copied().collect::<FastHashSet<_>>();
        let mut by_age = cache
            .iter()
            .filter(|(key, _)| !remove_set.contains(key))
            .map(|(key, entry)| (*key, entry.last_seen))
            .collect::<Vec<_>>();
        by_age.sort_by_key(|(_, last_seen)| *last_seen);

        let overflow = cache
            .len()
            .saturating_sub(remove_keys.len())
            .saturating_sub(FLOW_ATTRIBUTION_CACHE_LOW_WATERMARK);
        remove_keys.extend(by_age.into_iter().take(overflow).map(|(key, _)| key));
    }

    for key in remove_keys {
        if remove_cached_attribution(cache, process_index, &key).is_some() {
            external_flow_matcher.remove_flow(&key.flow);
        }
    }
}

#[cfg(target_os = "linux")]
fn refresh_enriched_attributions(
    tx: Option<&EventSender<Arc<FlowAttributionEvent>>>,
    external_flow_matcher: &SharedExternalFlowMatcher,
    metrics: &Metrics,
    cache: &mut FlowAttributionCache,
    process_index: &ProcessAttributionIndex,
    updated: Vec<(ProcessDetailsCacheKey, ProcessDetails)>,
) {
    for (process_key, details) in updated {
        metrics.inc_attribution_backend_events("procfs", "metadata_cold_read", 1);
        let Some(flow_keys) = process_index.get(&process_key) else {
            continue;
        };
        for key in flow_keys {
            let Some(entry) = cache.get_mut(key) else {
                continue;
            };
            if !apply_process_details_to_event(Arc::make_mut(&mut entry.event), &details) {
                continue;
            }
            Arc::make_mut(&mut entry.event).observed_at_unix_nano = now_unix_nano();
            let now = Instant::now();
            entry.last_seen = now;
            external_flow_matcher.observe_attribution_key(key.flow, &entry.event);
            emit_cached_attribution(tx, metrics, entry, now);
        }
    }
}

#[cfg(target_os = "linux")]
fn maybe_emit_cached_attribution(
    tx: Option<&EventSender<Arc<FlowAttributionEvent>>>,
    metrics: &Metrics,
    entry: &mut CachedAttribution,
    now: Instant,
) {
    let fingerprint = attribution_event_fingerprint(&entry.event);
    if fingerprint != entry.last_emitted_fingerprint
        || now.duration_since(entry.last_emitted) >= FLOW_ATTRIBUTION_RAW_HEARTBEAT_INTERVAL
    {
        emit_cached_attribution(tx, metrics, entry, now);
    } else {
        metrics.inc_flow_attribution_events_dropped("duplicate_coalesced", 1);
    }
}

#[cfg(target_os = "linux")]
fn emit_cached_attribution(
    tx: Option<&EventSender<Arc<FlowAttributionEvent>>>,
    metrics: &Metrics,
    entry: &mut CachedAttribution,
    now: Instant,
) {
    let event = Arc::clone(&entry.event);
    entry.last_emitted = now;
    entry.last_emitted_fingerprint = attribution_event_fingerprint(&event);
    emit_raw_flow_attribution_event(tx, metrics, event);
}

#[cfg(target_os = "linux")]
fn emit_raw_flow_attribution_event(
    tx: Option<&EventSender<Arc<FlowAttributionEvent>>>,
    metrics: &Metrics,
    event: Arc<FlowAttributionEvent>,
) {
    let Some(tx) = tx else {
        return;
    };

    let protocol = match event.transport_protocol.as_str() {
        "tcp" => "tcp",
        "udp" => "udp",
        "icmp" => "icmp",
        "icmpv6" => "icmpv6",
        _ => "other",
    };
    metrics.inc_flow_attribution_events();
    match tx.try_send(event) {
        Ok(()) => {
            metrics.inc_attribution_stage("agent_handoff", protocol, "queued");
        }
        Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
            metrics.inc_flow_attribution_events_dropped("queue_full", 1);
            metrics.inc_attribution_stage("agent_handoff", protocol, "queue_full");
        }
        Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
            metrics.inc_flow_attribution_events_dropped("no_receiver", 1);
            metrics.inc_attribution_stage("agent_handoff", protocol, "no_receiver");
        }
    }
}

fn apply_process_details_to_event(
    event: &mut FlowAttributionEvent,
    details: &ProcessDetails,
) -> bool {
    let redacted_cmdline = cap_redacted_cmdline_ref(&details.cmdline);
    let container_id = details.container_id.clone().unwrap_or_default();
    let changed = event.uid != details.uid
        || event.gid != details.gid
        || event.comm != details.comm
        || event.redacted_cmdline != redacted_cmdline
        || event.container_id != container_id;

    if changed {
        event.uid = details.uid;
        event.gid = details.gid;
        event.comm = details.comm.clone();
        event.redacted_cmdline = redacted_cmdline;
        event.container_id = container_id;
    }

    changed
}

// Directional FlowKey from a ring record's tuple: endpoint A is the local socket
// (source), endpoint B the peer. Returns None for empty / non-IP /
// non-TCP-UDP-ICMP tuples. ICMP carries no ports, so a zero source/destination
// port is expected and accepted (do NOT drop it for missing ports).
fn flow_key_from_record(record: &FlowAttributionRecord) -> Option<FlowKey> {
    if record.tuple.family != AF_INET && record.tuple.family != AF_INET6 {
        return None;
    }
    if record.tuple.protocol != IPPROTO_TCP
        && record.tuple.protocol != IPPROTO_UDP
        && record.tuple.protocol != IPPROTO_ICMP
        && record.tuple.protocol != IPPROTO_ICMPV6
    {
        return None;
    }
    Some(FlowKey {
        address_family: record.tuple.family,
        transport_protocol: record.tuple.protocol,
        endpoint_a_port: record.tuple.source_port,
        endpoint_b_port: record.tuple.destination_port,
        endpoint_a_addr: record.tuple.source_addr,
        endpoint_b_addr: record.tuple.destination_addr,
    })
}

fn attribution_flow_key_from_record(
    record: &FlowAttributionRecord,
    coalesce_service: bool,
) -> Option<FlowKey> {
    let mut flow = flow_key_from_record(record)?;
    if should_coalesce_udp_client_attribution(&flow) {
        flow.endpoint_a_port = 0;
        return Some(flow);
    }
    if should_coalesce_service_attribution(&flow, coalesce_service) {
        flow.endpoint_b_addr = [0; 16];
        flow.endpoint_b_port = 0;
    }
    Some(flow)
}

fn should_coalesce_service_attribution(flow: &FlowKey, coalesce_service: bool) -> bool {
    coalesce_service
        && matches!(flow.transport_protocol, IPPROTO_TCP | IPPROTO_UDP)
        && flow.endpoint_a_port > 0
        && flow.endpoint_b_port > 0
}

fn should_coalesce_udp_client_attribution(flow: &FlowKey) -> bool {
    flow.transport_protocol == IPPROTO_UDP
        && flow.endpoint_a_port >= EPHEMERAL_PORT_FLOOR
        && flow.endpoint_b_port > 0
        && flow.endpoint_b_port < EPHEMERAL_PORT_FLOOR
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AttributionRecordValidationError {
    TupleRejected,
    OwnerMiss,
}

fn validate_attribution_record(
    record: &FlowAttributionRecord,
    coalesce_service: bool,
) -> Result<FlowKey, AttributionRecordValidationError> {
    let flow = attribution_flow_key_from_record(record, coalesce_service)
        .ok_or(AttributionRecordValidationError::TupleRejected)?;
    if record.pid == 0 || record.tgid == 0 {
        return Err(AttributionRecordValidationError::OwnerMiss);
    }
    Ok(flow)
}

#[cfg(target_os = "linux")]
fn likely_service_side_record(record: &FlowAttributionRecord) -> bool {
    likely_service_side_tuple(
        record.tuple.protocol,
        record.tuple.source_port,
        record.tuple.destination_port,
    )
}

fn likely_service_side_tuple(protocol: u16, source_port: u16, destination_port: u16) -> bool {
    matches!(protocol, IPPROTO_TCP | IPPROTO_UDP)
        && source_port > 0
        && source_port < EPHEMERAL_PORT_FLOOR
        && destination_port >= EPHEMERAL_PORT_FLOOR
}

#[cfg(target_os = "linux")]
fn should_record_inventory(record: &FlowAttributionRecord) -> bool {
    record.event_kind == EVENT_INET_SOCK_SET_STATE && record.new_state == TCP_LISTEN_STATE
}

#[cfg(target_os = "linux")]
fn should_remove_inventory(record: &FlowAttributionRecord) -> bool {
    record.event_kind == EVENT_INET_SOCK_SET_STATE
        && record.old_state == TCP_LISTEN_STATE
        && record.new_state == TCP_CLOSE_STATE
}

#[cfg(target_os = "linux")]
fn attribution_event_kind_index(event_kind: u16) -> usize {
    match event_kind {
        EVENT_TCP_CONNECT => 0,
        EVENT_TCP_ACCEPT => 1,
        EVENT_TCP_CLOSE => 2,
        EVENT_UDP_SEND => 3,
        EVENT_UDP_RECV => 4,
        EVENT_INET_SOCK_SET_STATE => 5,
        EVENT_ICMP_SEND => 6,
        _ => 7,
    }
}

#[cfg(target_os = "linux")]
fn attribution_protocol_index(protocol: u16) -> usize {
    match protocol {
        IPPROTO_ICMP => 0,
        IPPROTO_TCP => 1,
        IPPROTO_UDP => 2,
        IPPROTO_ICMPV6 => 3,
        _ => 4,
    }
}

#[cfg(target_os = "linux")]
fn join_key_from_record(
    record: &FlowAttributionRecord,
    coalesce_service: bool,
) -> Option<FlowAttributionJoinKey> {
    Some(FlowAttributionJoinKey {
        flow: attribution_flow_key_from_record(record, coalesce_service)?,
        pid: record.pid,
        tgid: record.tgid,
        process_generation_ns: record.process_generation_ns,
    })
}

#[cfg(target_os = "linux")]
fn emit_process_snapshot(
    reader: &mut AyaAttributionReader,
    tx: &tokio::sync::broadcast::Sender<ProcessSnapshot>,
    metrics: &Metrics,
) {
    let snapshot = reader.process_snapshot_if_dirty();
    metrics.set_attribution_cache_entries("socket_inventory", reader.inventory_len());
    let Some(snapshot) = snapshot else {
        return;
    };

    metrics.inc_process_snapshot_events();
    if tx.send(snapshot).is_err() {
        metrics.inc_process_snapshot_events_dropped("no_receiver", 1);
    }
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct FlowAttributionJoinKey {
    flow: FlowKey,
    pid: u32,
    tgid: u32,
    process_generation_ns: u64,
}

#[cfg(target_os = "linux")]
impl From<&AttributedFlow> for FlowAttributionJoinKey {
    fn from(value: &AttributedFlow) -> Self {
        Self {
            flow: value.flow,
            pid: value.pid.pid,
            tgid: value.pid.tgid,
            process_generation_ns: value.pid.process_generation_ns,
        }
    }
}

fn comm_from_bytes(bytes: &[u8; 16]) -> String {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).to_string()
}

fn redacted_cmdline(proc_root: &Path, tgid: u32) -> Vec<String> {
    let Ok(bytes) = fs::read(proc_root.join(tgid.to_string()).join("cmdline")) else {
        return Vec::new();
    };
    let mut args = bytes
        .split(|byte| *byte == 0)
        .filter(|arg| !arg.is_empty())
        .map(|arg| String::from_utf8_lossy(arg).to_string());

    let Some(argv0) = args.next() else {
        return Vec::new();
    };

    let remaining = args.count();
    if remaining == 0 {
        vec![argv0]
    } else {
        vec![argv0, format!("[redacted {remaining} arg(s)]")]
    }
}

fn container_id(proc_root: &Path, tgid: u32) -> Option<String> {
    let cgroup = fs::read_to_string(proc_root.join(tgid.to_string()).join("cgroup")).ok()?;
    cgroup
        .split(|ch: char| !ch.is_ascii_hexdigit())
        .find(|part| part.len() == 64 || part.len() == 32)
        .map(str::to_string)
}

/// True when `pid` is a userspace process that can own sockets we attribute.
///
/// Structural only — no process-name denylists. Kernel threads (idle/softirq
/// workers, etc.) have no executable mapping and no `VmSize` address space.
/// Pid 0 is the idle task (`swapper/*`) and is never a valid owner.
fn is_userspace_process(proc_root: &Path, pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    let dir = proc_root.join(pid.to_string());
    if !dir.is_dir() {
        return false;
    }
    // Userspace processes almost always have a resolvable exe link.
    if fs::read_link(dir.join("exe")).is_ok() {
        return true;
    }
    // Fallback: kernel threads omit Vm* lines; userspace processes report VmSize.
    let Ok(status) = fs::read_to_string(dir.join("status")) else {
        return false;
    };
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmSize:") {
            let kb = rest
                .split_whitespace()
                .next()
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0);
            return kb > 0;
        }
    }
    false
}

/// Joins `parts` with a single space and truncates the result to
/// [`REDACTED_CMDLINE_MAX_BYTES`] bytes on a UTF-8 codepoint boundary.
///
/// Returns an empty vector when `parts` is empty so that the
/// `repeated string redacted_cmdline` field stays unset on the wire.
/// Otherwise the helper always returns a single-element vector — the
/// joined, possibly-truncated payload — because the §20.15 contract
/// caps the cumulative byte length of the field, not its element count.
fn cap_redacted_cmdline(parts: Vec<String>) -> Vec<String> {
    cap_redacted_cmdline_ref(&parts)
}

fn cap_redacted_cmdline_ref(parts: &[String]) -> Vec<String> {
    if parts.is_empty() {
        return Vec::new();
    }
    let total_len = parts.iter().map(String::len).sum::<usize>() + parts.len().saturating_sub(1);
    let mut joined = String::with_capacity(total_len);
    for (idx, part) in parts.iter().enumerate() {
        if idx > 0 {
            joined.push(' ');
        }
        joined.push_str(part);
    }
    let capped = trim_to_utf8_boundary(&joined, REDACTED_CMDLINE_MAX_BYTES);
    vec![capped]
}

/// Truncates `value` to at most `max_bytes` bytes, walking back to the
/// nearest UTF-8 codepoint boundary so multi-byte sequences are never
/// split. Mirrors the Elixir `trim_to_utf8_boundary/2` helper.
fn trim_to_utf8_boundary(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_string();
    }
    let mut cut = max_bytes;
    while cut > 0 && !value.is_char_boundary(cut) {
        cut -= 1;
    }
    value[..cut].to_string()
}

#[cfg(target_os = "linux")]
fn attribution_event_fingerprint(event: &FlowAttributionEvent) -> u64 {
    let mut hasher = FastHasher::default();
    event.local_ip.hash(&mut hasher);
    event.local_port.hash(&mut hasher);
    event.remote_ip.hash(&mut hasher);
    event.remote_port.hash(&mut hasher);
    event.transport_protocol.hash(&mut hasher);
    event.pid.hash(&mut hasher);
    event.tgid.hash(&mut hasher);
    event.uid.hash(&mut hasher);
    event.gid.hash(&mut hasher);
    event.comm.hash(&mut hasher);
    event.redacted_cmdline.hash(&mut hasher);
    event.container_id.hash(&mut hasher);
    event.socket_address.hash(&mut hasher);
    event.event_kind.hash(&mut hasher);
    event.old_state.hash(&mut hasher);
    event.new_state.hash(&mut hasher);
    event.source.hash(&mut hasher);
    event.external_flow_id.hash(&mut hasher);
    hasher.finish()
}

fn flow_attribution_event(
    flow: &AttributedFlow,
    observed_at_unix_nano: i64,
) -> Option<FlowAttributionEvent> {
    let (local_ip, local_port, remote_ip, remote_port) =
        endpoints(&flow.flow, flow.pid.local_endpoint)?;
    // Never emit process name without a userspace pid. Kernel idle/softirq
    // paths previously produced comm=swapper/* with pid=0 ("Unmatched" rows).
    let process = flow
        .process
        .as_ref()
        .filter(|details| details.pid != 0 && details.tgid != 0 && !details.comm.is_empty());
    let has_process = process.is_some() && flow.pid.pid != 0 && flow.pid.tgid != 0;

    Some(FlowAttributionEvent {
        local_ip: local_ip.to_string(),
        local_port: u32::from(local_port),
        remote_ip: remote_ip.to_string(),
        remote_port: u32::from(remote_port),
        transport_protocol: transport_protocol(flow.flow.transport_protocol),
        pid: if has_process { flow.pid.pid } else { 0 },
        tgid: if has_process { flow.pid.tgid } else { 0 },
        uid: if has_process {
            process.map_or(flow.pid.uid, |details| details.uid)
        } else {
            0
        },
        gid: if has_process {
            process.map_or(flow.pid.gid, |details| details.gid)
        } else {
            0
        },
        comm: process
            .map(|details| details.comm.clone())
            .unwrap_or_default(),
        redacted_cmdline: process
            .map(|details| cap_redacted_cmdline_ref(&details.cmdline))
            .unwrap_or_default(),
        container_id: process
            .and_then(|details| details.container_id.clone())
            .unwrap_or_default(),
        workload_identity: None,
        observed_at_unix_nano,
        socket_address: flow.pid.socket_address,
        event_kind: u32::from(flow.pid.event_kind),
        old_state: flow.pid.old_state,
        new_state: flow.pid.new_state,
        source: String::new(),
        external_flow_id: 0,
    })
}

fn endpoints(flow: &FlowKey, local_endpoint: u8) -> Option<(IpAddr, u16, IpAddr, u16)> {
    let endpoint_a = ip_addr(flow.address_family, flow.endpoint_a_addr)?;
    let endpoint_b = ip_addr(flow.address_family, flow.endpoint_b_addr)?;
    match local_endpoint {
        FLOW_ENDPOINT_A => Some((
            endpoint_a,
            flow.endpoint_a_port,
            endpoint_b,
            flow.endpoint_b_port,
        )),
        FLOW_ENDPOINT_B => Some((
            endpoint_b,
            flow.endpoint_b_port,
            endpoint_a,
            flow.endpoint_a_port,
        )),
        _ => None,
    }
}

fn ip_addr(address_family: u16, bytes: [u8; 16]) -> Option<IpAddr> {
    match address_family {
        AF_INET => Some(IpAddr::V4(Ipv4Addr::new(
            bytes[0], bytes[1], bytes[2], bytes[3],
        ))),
        AF_INET6 => Some(IpAddr::V6(Ipv6Addr::from(bytes))),
        _ => None,
    }
}

fn transport_protocol(value: u16) -> String {
    match value {
        IPPROTO_ICMP => "icmp".to_owned(),
        IPPROTO_ICMPV6 => "icmpv6".to_owned(),
        IPPROTO_TCP => "tcp".to_owned(),
        IPPROTO_UDP => "udp".to_owned(),
        _ => value.to_string(),
    }
}

#[cfg(target_os = "linux")]
fn process_details_from_record(record: &ProcessInfoRecord) -> ProcessDetails {
    // Without procfs, still refuse zero-pid identities (idle task).
    if record.pid == 0 || record.tgid == 0 {
        return ProcessDetails {
            pid: 0,
            tgid: 0,
            uid: 0,
            gid: 0,
            comm: String::new(),
            cmdline: Vec::new(),
            container_id: None,
            last_seen_ns: record.last_seen_ns,
            process_generation_ns: 0,
        };
    }
    ProcessDetails {
        pid: record.pid,
        tgid: record.tgid,
        uid: record.uid,
        gid: record.gid,
        comm: comm_from_bytes(&record.comm),
        cmdline: Vec::new(),
        container_id: None,
        last_seen_ns: record.last_seen_ns,
        process_generation_ns: record.process_generation_ns,
    }
}

fn now_unix_nano() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as i64)
        .unwrap_or_default()
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ListeningSocket {
    inode: u64,
    local_ip: IpAddr,
    local_port: u16,
    transport_protocol: String,
}

fn listening_sockets(proc_root: &Path) -> Vec<ListeningSocket> {
    let mut sockets = Vec::new();
    sockets.extend(read_proc_net_sockets(proc_root, "tcp", false, "tcp"));
    sockets.extend(read_proc_net_sockets(proc_root, "tcp6", true, "tcp"));
    sockets.extend(read_proc_net_sockets(proc_root, "udp", false, "udp"));
    sockets.extend(read_proc_net_sockets(proc_root, "udp6", true, "udp"));
    sockets
}

fn read_proc_net_sockets(
    proc_root: &Path,
    file_name: &str,
    ipv6: bool,
    protocol: &str,
) -> Vec<ListeningSocket> {
    let Ok(contents) = fs::read_to_string(proc_root.join("net").join(file_name)) else {
        return Vec::new();
    };

    contents
        .lines()
        .skip(1)
        .filter_map(|line| parse_proc_net_socket(line, ipv6, protocol))
        .collect()
}

fn parse_proc_net_socket(line: &str, ipv6: bool, protocol: &str) -> Option<ListeningSocket> {
    let fields = line.split_whitespace().collect::<Vec<_>>();
    let local_address = *fields.get(1)?;
    let state = *fields.get(3)?;
    if protocol == "tcp" && state != "0A" {
        return None;
    }

    let inode = fields.get(9)?.parse().ok()?;
    let (local_ip, local_port) = parse_proc_net_endpoint(local_address, ipv6)?;
    if protocol == "udp" && local_port == 0 {
        return None;
    }

    Some(ListeningSocket {
        inode,
        local_ip,
        local_port,
        transport_protocol: protocol.to_string(),
    })
}

fn parse_proc_net_endpoint(value: &str, ipv6: bool) -> Option<(IpAddr, u16)> {
    let (addr_hex, port_hex) = value.split_once(':')?;
    let port = u16::from_str_radix(port_hex, 16).ok()?;
    let ip = if ipv6 {
        IpAddr::V6(parse_proc_net_ipv6(addr_hex)?)
    } else {
        IpAddr::V4(parse_proc_net_ipv4(addr_hex)?)
    };
    Some((ip, port))
}

fn parse_proc_net_ipv4(value: &str) -> Option<Ipv4Addr> {
    if value.len() != 8 {
        return None;
    }
    let raw = u32::from_str_radix(value, 16).ok()?.to_le_bytes();
    Some(Ipv4Addr::new(raw[0], raw[1], raw[2], raw[3]))
}

fn parse_proc_net_ipv6(value: &str) -> Option<Ipv6Addr> {
    if value.len() != 32 {
        return None;
    }
    let mut bytes = [0u8; 16];
    for index in 0..16 {
        bytes[index] = u8::from_str_radix(&value[index * 2..index * 2 + 2], 16).ok()?;
    }
    for chunk in bytes.as_chunks_mut::<4>().0 {
        chunk.reverse();
    }
    Some(Ipv6Addr::from(bytes))
}

fn socket_owners(proc_root: &Path, wanted_inodes: HashSet<u64>) -> HashMap<u64, Vec<u32>> {
    let mut owners: HashMap<u64, Vec<u32>> = HashMap::new();
    if wanted_inodes.is_empty() {
        return owners;
    }

    let Ok(entries) = fs::read_dir(proc_root) else {
        return owners;
    };

    for entry in entries.filter_map(Result::ok) {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|value| value.parse::<u32>().ok())
        else {
            continue;
        };
        let fd_dir = entry.path().join("fd");
        let Ok(fds) = fs::read_dir(fd_dir) else {
            continue;
        };
        for fd in fds.filter_map(Result::ok) {
            let Ok(target) = fs::read_link(fd.path()) else {
                continue;
            };
            let Some(inode) = socket_inode_from_link(&target) else {
                continue;
            };
            if wanted_inodes.contains(&inode) {
                owners.entry(inode).or_default().push(pid);
            }
        }
    }

    owners
}

fn socket_inode_from_link(path: &Path) -> Option<u64> {
    let value = path.to_str()?;
    let inode = value.strip_prefix("socket:[")?.strip_suffix(']')?;
    inode.parse().ok()
}

fn read_status_ids(proc_root: &Path, pid: u32) -> Option<(u32, u32)> {
    let status = fs::read_to_string(proc_root.join(pid.to_string()).join("status")).ok()?;
    let mut uid = None;
    let mut gid = None;

    for line in status.lines() {
        if let Some(value) = line.strip_prefix("Uid:") {
            uid = value.split_whitespace().next()?.parse().ok();
        }
        if let Some(value) = line.strip_prefix("Gid:") {
            gid = value.split_whitespace().next()?.parse().ok();
        }
    }

    Some((uid.unwrap_or_default(), gid.unwrap_or_default()))
}

fn read_comm(proc_root: &Path, pid: u32) -> Option<String> {
    fs::read_to_string(proc_root.join(pid.to_string()).join("comm"))
        .ok()
        .map(|value| value.trim_end_matches('\n').to_string())
}

fn sort_snapshot_entries(entries: &mut [ProcessSnapshotEntry]) {
    entries.sort_by(|left, right| {
        (
            &left.transport_protocol,
            &left.local_ip,
            left.local_port,
            left.pid,
        )
            .cmp(&(
                &right.transport_protocol,
                &right.local_ip,
                right.local_port,
                right.pid,
            ))
    });
}

fn snapshot_fingerprint(entries: &[ProcessSnapshotEntry]) -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for entry in entries {
        hash_bytes(&mut hash, entry.transport_protocol.as_bytes());
        hash_bytes(&mut hash, entry.local_ip.as_bytes());
        hash_bytes(&mut hash, &entry.local_port.to_le_bytes());
        hash_bytes(&mut hash, &entry.pid.to_le_bytes());
        hash_bytes(&mut hash, entry.comm.as_bytes());
    }
    format!("{hash:016x}")
}

fn hash_bytes(hash: &mut u64, bytes: &[u8]) {
    for byte in bytes {
        *hash ^= u64::from(*byte);
        *hash = hash.wrapping_mul(0x100000001b3);
    }
    *hash ^= 0xff;
    *hash = hash.wrapping_mul(0x100000001b3);
}

#[cfg(test)]
mod tests {
    use std::fs;
    #[cfg(target_os = "linux")]
    use std::sync::Arc;

    use std::collections::HashMap;

    use super::{
        AF_INET, AttributedFlow, AttributionRecordValidationError, EVENT_INET_SOCK_SET_STATE,
        FLOW_ENDPOINT_B, FlowPidRecord, IPPROTO_TCP, IPPROTO_UDP, ProcessDetails,
        ProcessInfoRecord, ProcfsEnricher, REDACTED_CMDLINE_MAX_BYTES, cap_redacted_cmdline,
        comm_from_bytes, container_id, flow_attribution_event, is_userspace_process,
        likely_service_side_tuple, preferred_process_owner, redacted_cmdline,
        trim_to_utf8_boundary, validate_attribution_record,
    };
    #[cfg(target_os = "linux")]
    use super::{
        AttributionExpiryQueue, CachedAttribution, EVENT_UDP_RECV, EVENT_UDP_SEND,
        FLOW_ATTRIBUTION_CACHE_LOW_WATERMARK, FLOW_ATTRIBUTION_CACHE_MAX_ENTRIES,
        FLOW_ATTRIBUTION_RAW_HEARTBEAT_INTERVAL, FLOW_ENDPOINT_A, FlowAttributionCache,
        MetadataEnricher, ProcessAttributionIndex, ProcessDetailsCacheKey, SocketInventory,
        TCP_CLOSE_STATE, TCP_LISTEN_STATE, UdpRoleInventory, attribution_event_fingerprint,
        attribution_flow_key_from_record, insert_cached_attribution, likely_service_side_record,
        maybe_emit_cached_attribution, process_details_from_record, process_metadata_complete,
        prune_attribution_cache, refresh_enriched_attributions, touch_closed_cached_attribution,
    };
    use crate::af_xdp_classifier::FlowKey;
    #[cfg(target_os = "linux")]
    use crate::external_flow::SharedExternalFlowMatcher;

    #[test]
    fn comm_stops_at_nul() {
        let mut comm = [0u8; 16];
        comm[..7].copy_from_slice(b"netprob");

        assert_eq!(comm_from_bytes(&comm), "netprob");
    }

    #[test]
    fn tuple_validation_precedes_owner_resolution() {
        let mut record = flow_record(IPPROTO_TCP, 51_000, 443);
        record.pid = 0;
        record.tgid = 0;

        assert_eq!(
            validate_attribution_record(&record, false),
            Err(AttributionRecordValidationError::OwnerMiss)
        );

        record.tuple.family = 0;
        assert_eq!(
            validate_attribution_record(&record, false),
            Err(AttributionRecordValidationError::TupleRejected)
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn listener_side_attribution_coalesces_remote_endpoint() {
        let record = flow_record(IPPROTO_TCP, 8080, 51_000);
        let key = attribution_flow_key_from_record(&record, true).unwrap();

        assert_eq!(key.endpoint_a_port, 8080);
        assert_eq!(key.endpoint_b_port, 0);
        assert_eq!(key.endpoint_b_addr, [0; 16]);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn attribution_without_listener_keeps_exact_remote_endpoint() {
        let record = flow_record(IPPROTO_TCP, 8080, 51_000);
        let key = attribution_flow_key_from_record(&record, false).unwrap();

        assert_eq!(key.endpoint_a_port, 8080);
        assert_eq!(key.endpoint_b_port, 51_000);
        assert_eq!(key.endpoint_b_addr, ipv4([198, 51, 100, 20]));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn socket_inventory_matches_exact_and_wildcard_listeners() {
        let record = flow_record(IPPROTO_TCP, 8080, 51_000);
        let mut exact_inventory = SocketInventory::default();
        exact_inventory.update(&listener_flow(ipv4([192, 0, 2, 10]), 8080));

        assert!(exact_inventory.has_listener_for_record(&record));

        let mut wildcard_inventory = SocketInventory::default();
        wildcard_inventory.update(&listener_flow([0; 16], 8080));

        assert!(wildcard_inventory.has_listener_for_record(&record));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn client_side_attribution_keeps_exact_remote_endpoint() {
        let record = flow_record(IPPROTO_TCP, 51_000, 443);
        let key = attribution_flow_key_from_record(&record, false).unwrap();

        assert_eq!(key.endpoint_a_port, 51_000);
        assert_eq!(key.endpoint_b_port, 443);
        assert_eq!(key.endpoint_b_addr, ipv4([198, 51, 100, 20]));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn udp_client_service_attribution_coalesces_local_ephemeral_port() {
        let record = udp_record(EVENT_UDP_SEND, 51_000, 53);
        let key = attribution_flow_key_from_record(&record, false).unwrap();

        assert_eq!(key.endpoint_a_port, 0);
        assert_eq!(key.endpoint_a_addr, ipv4([192, 0, 2, 10]));
        assert_eq!(key.endpoint_b_port, 53);
        assert_eq!(key.endpoint_b_addr, ipv4([198, 51, 100, 20]));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn udp_client_high_remote_port_keeps_exact_local_port() {
        let record = udp_record(EVENT_UDP_SEND, 51_000, 51_001);
        let key = attribution_flow_key_from_record(&record, false).unwrap();

        assert_eq!(key.endpoint_a_port, 51_000);
        assert_eq!(key.endpoint_b_port, 51_001);
        assert_eq!(key.endpoint_b_addr, ipv4([198, 51, 100, 20]));
    }

    #[test]
    fn likely_service_side_tuple_detects_tcp_server_shape() {
        assert!(likely_service_side_tuple(IPPROTO_TCP, 8080, 51_000));
    }

    #[test]
    fn likely_service_side_tuple_detects_udp_server_shape() {
        assert!(likely_service_side_tuple(IPPROTO_UDP, 53, 51_000));
    }

    #[test]
    fn likely_service_side_tuple_keeps_client_shape_exact() {
        assert!(!likely_service_side_tuple(IPPROTO_TCP, 51_000, 443));
        assert!(!likely_service_side_tuple(IPPROTO_UDP, 51_000, 53));
    }

    #[test]
    fn likely_service_side_tuple_keeps_same_port_protocols_exact() {
        assert!(!likely_service_side_tuple(IPPROTO_UDP, 7946, 7946));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn likely_tcp_service_side_record_coalesces_without_listener_inventory() {
        let record = flow_record(IPPROTO_TCP, 8080, 51_000);
        let key =
            attribution_flow_key_from_record(&record, likely_service_side_record(&record)).unwrap();

        assert_eq!(key.endpoint_a_port, 8080);
        assert_eq!(key.endpoint_b_port, 0);
        assert_eq!(key.endpoint_b_addr, [0; 16]);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn likely_service_side_record_keeps_tcp_client_tuple_exact() {
        let record = flow_record(IPPROTO_TCP, 51_000, 443);
        let key =
            attribution_flow_key_from_record(&record, likely_service_side_record(&record)).unwrap();

        assert_eq!(key.endpoint_a_port, 51_000);
        assert_eq!(key.endpoint_b_port, 443);
        assert_eq!(key.endpoint_b_addr, ipv4([198, 51, 100, 20]));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn likely_udp_service_side_record_coalesces_first_packet() {
        let record = udp_record(EVENT_UDP_RECV, 53, 51_000);
        let key =
            attribution_flow_key_from_record(&record, likely_service_side_record(&record)).unwrap();

        assert_eq!(key.endpoint_a_port, 53);
        assert_eq!(key.endpoint_b_port, 0);
        assert_eq!(key.endpoint_b_addr, [0; 16]);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn udp_role_inventory_promotes_multi_peer_socket() {
        let mut roles = UdpRoleInventory::default();
        let first = udp_record(EVENT_UDP_RECV, 53, 51_000);
        let second = udp_record(EVENT_UDP_RECV, 53, 51_001);
        let send = udp_record(EVENT_UDP_SEND, 53, 51_002);

        assert!(!roles.should_coalesce_record(&first));
        assert!(roles.should_coalesce_record(&second));
        assert!(roles.should_coalesce_record(&send));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn udp_role_inventory_promotes_multi_peer_send_socket() {
        let mut roles = UdpRoleInventory::default();
        let first = udp_record(EVENT_UDP_SEND, 53, 51_000);
        let second = udp_record(EVENT_UDP_SEND, 53, 51_001);

        assert!(!roles.should_coalesce_record(&first));
        assert!(roles.should_coalesce_record(&second));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn udp_role_inventory_keeps_single_peer_client_socket_exact() {
        let mut roles = UdpRoleInventory::default();
        let send = udp_record(EVENT_UDP_SEND, 51_000, 53);
        let recv = udp_record(EVENT_UDP_RECV, 51_000, 53);

        assert!(!roles.should_coalesce_record(&send));
        assert!(!roles.should_coalesce_record(&recv));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn udp_role_inventory_does_not_cache_obvious_ephemeral_client_socket() {
        let mut roles = UdpRoleInventory::default();
        let send = udp_record(EVENT_UDP_SEND, 51_000, 53);

        assert!(!roles.should_coalesce_record(&send));
        assert_eq!(roles.entries.len(), 0);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn udp_server_side_attribution_coalesces_remote_endpoint_after_promotion() {
        let mut roles = UdpRoleInventory::default();
        let first = udp_record(EVENT_UDP_RECV, 53, 51_000);
        let second = udp_record(EVENT_UDP_RECV, 53, 51_001);

        assert!(!roles.should_coalesce_record(&first));
        assert!(roles.should_coalesce_record(&second));

        let key = attribution_flow_key_from_record(&second, true).unwrap();

        assert_eq!(key.endpoint_a_port, 53);
        assert_eq!(key.endpoint_b_port, 0);
        assert_eq!(key.endpoint_b_addr, [0; 16]);
    }

    #[test]
    fn cmdline_preserves_argv0_and_redacts_args() {
        let root = temp_proc("123", b"/usr/bin/curl\0--header\0secret\0", "");

        assert_eq!(
            redacted_cmdline(root.path(), 123),
            vec!["/usr/bin/curl", "[redacted 2 arg(s)]"]
        );
    }

    #[test]
    fn extracts_container_id_from_cgroup() {
        let id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let root = temp_proc("123", b"", &format!("0::/docker/{id}\n"));

        assert_eq!(container_id(root.path(), 123).as_deref(), Some(id));
    }

    #[test]
    fn enriches_process_record_from_procfs() {
        let root = temp_proc("123", b"/bin/app\0--token\0abc\0", "");
        let mut comm = [0u8; 16];
        comm[..3].copy_from_slice(b"app");
        let record = ProcessInfoRecord {
            version: 1,
            reserved: 0,
            pid: 123,
            tgid: 123,
            uid: 1000,
            gid: 1000,
            last_seen_ns: 42,
            process_generation_ns: 123_456,
            comm,
        };

        let details = ProcfsEnricher::with_root(root.path()).process_details(&record);

        assert_eq!(details.comm, "app");
        assert_eq!(details.cmdline, vec!["/bin/app", "[redacted 2 arg(s)]"]);
        assert_eq!(details.uid, 1000);
        assert_eq!(details.last_seen_ns, 42);
        assert_eq!(details.process_generation_ns, 123_456);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn metadata_enricher_uses_budget_for_active_process_metadata() {
        let id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let root = temp_proc(
            "123",
            b"/bin/app\0--token\0abc\0",
            &format!("0::/kubepods.slice/cri-containerd-{id}.scope\n"),
        );
        let mut comm = [0u8; 16];
        comm[..3].copy_from_slice(b"app");
        let record = ProcessInfoRecord {
            version: 1,
            reserved: 0,
            pid: 123,
            tgid: 123,
            uid: 1000,
            gid: 1000,
            last_seen_ns: 42,
            process_generation_ns: 123_456,
            comm,
        };
        let mut enricher = MetadataEnricher::with_procfs(ProcfsEnricher::with_root(root.path()));

        let (details, key, cold_read) = enricher.process_details(&record);

        assert!(cold_read);
        assert_eq!(key.tgid, 123);
        assert_eq!(details.cmdline, vec!["/bin/app", "[redacted 2 arg(s)]"]);
        assert_eq!(details.container_id.as_deref(), Some(id));
        assert_eq!(enricher.cache_len(), 1);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn metadata_enricher_prioritizes_active_cached_flow_metadata() {
        let low_id = "1111111111111111111111111111111111111111111111111111111111111111";
        let active_id = "2222222222222222222222222222222222222222222222222222222222222222";
        let root = temp_proc(
            "100",
            b"/bin/low\0",
            &format!("0::/kubepods.slice/cri-containerd-{low_id}.scope\n"),
        );
        let active_dir = root.path().join("200");
        fs::create_dir_all(&active_dir).unwrap();
        fs::write(active_dir.join("cmdline"), b"/bin/active\0--secret\0").unwrap();
        fs::write(
            active_dir.join("cgroup"),
            format!("0::/kubepods.slice/cri-containerd-{active_id}.scope\n"),
        )
        .unwrap();
        // Second pid built by hand rather than through temp_proc, so it needs the same
        // userspace shape the helper now writes.
        fs::write(active_dir.join("status"), "VmSize:\t1234 kB\n").unwrap();

        let mut low_comm = [0u8; 16];
        low_comm[..3].copy_from_slice(b"low");
        let low = ProcessInfoRecord {
            version: 1,
            reserved: 0,
            pid: 100,
            tgid: 100,
            uid: 1000,
            gid: 1000,
            last_seen_ns: 0,
            process_generation_ns: 1,
            comm: low_comm,
        };
        let mut active_comm = [0u8; 16];
        active_comm[..6].copy_from_slice(b"active");
        let active = ProcessInfoRecord {
            version: 1,
            reserved: 0,
            pid: 200,
            tgid: 200,
            uid: 1000,
            gid: 1000,
            last_seen_ns: 0,
            process_generation_ns: 2,
            comm: active_comm,
        };
        let mut enricher = MetadataEnricher::with_procfs(ProcfsEnricher::with_root(root.path()));
        enricher.read_budget.available = 0;

        let (_, low_key, low_cold_read) = enricher.process_details(&low);
        let (_, active_key, active_cold_read) = enricher.process_details(&active);
        assert!(!low_cold_read);
        assert!(!active_cold_read);
        assert_eq!(enricher.pending.len(), 2);

        let (_, priority_key, priority_cold_read) = enricher.process_details_priority(&active);
        assert_eq!(priority_key, active_key);
        assert!(!priority_cold_read);
        assert_eq!(enricher.pending.len(), 2);

        enricher.read_budget.available = 1;
        let updated = enricher.process_pending();

        assert_eq!(updated.len(), 1);
        assert_eq!(updated[0].0, active_key);
        assert_eq!(updated[0].1.container_id.as_deref(), Some(active_id));
        assert_eq!(
            updated[0].1.cmdline,
            vec!["/bin/active", "[redacted 1 arg(s)]"]
        );
        assert!(enricher.pending_keys.contains(&low_key));
        assert!(!enricher.pending_keys.contains(&active_key));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn process_details_from_record_uses_ebpf_process_identity() {
        let mut comm = [0u8; 16];
        comm[..3].copy_from_slice(b"app");
        let record = ProcessInfoRecord {
            version: 1,
            reserved: 0,
            pid: 123,
            tgid: 123,
            uid: 1000,
            gid: 1000,
            last_seen_ns: 42,
            process_generation_ns: 111,
            comm,
        };

        let details = process_details_from_record(&record);

        assert_eq!(details.pid, 123);
        assert_eq!(details.tgid, 123);
        assert_eq!(details.uid, 1000);
        assert_eq!(details.gid, 1000);
        assert_eq!(details.comm, "app");
        assert!(details.cmdline.is_empty());
        assert_eq!(details.container_id, None);
        assert_eq!(details.process_generation_ns, 111);
    }

    #[test]
    fn builds_flow_attribution_event_with_local_endpoint() {
        let flow = AttributedFlow {
            flow: FlowKey {
                address_family: AF_INET,
                transport_protocol: IPPROTO_TCP,
                endpoint_a_port: 443,
                endpoint_b_port: 51_000,
                endpoint_a_addr: ipv4([192, 0, 2, 10]),
                endpoint_b_addr: ipv4([198, 51, 100, 20]),
            },
            pid: FlowPidRecord {
                version: 1,
                event_kind: 2,
                pid: 123,
                tgid: 123,
                uid: 1000,
                gid: 1000,
                socket_address: 0xfeed,
                last_seen_ns: 99,
                process_generation_ns: 123_456,
                old_state: 1,
                new_state: 2,
                local_endpoint: FLOW_ENDPOINT_B,
                reserved: [0; 7],
            },
            process: Some(ProcessDetails {
                pid: 123,
                tgid: 123,
                uid: 1000,
                gid: 1000,
                comm: "curl".to_string(),
                cmdline: vec![
                    "/usr/bin/curl".to_string(),
                    "[redacted 1 arg(s)]".to_string(),
                ],
                container_id: Some("0123456789abcdef0123456789abcdef".to_string()),
                last_seen_ns: 99,
                process_generation_ns: 123_456,
            }),
        };

        let event = flow_attribution_event(&flow, 123_456).unwrap();

        assert_eq!(event.local_ip, "198.51.100.20");
        assert_eq!(event.local_port, 51_000);
        assert_eq!(event.remote_ip, "192.0.2.10");
        assert_eq!(event.remote_port, 443);
        assert_eq!(event.transport_protocol, "tcp");
        assert_eq!(event.comm, "curl");
        // §20.15: redacted_cmdline is joined and byte-capped at the event
        // construction site, so the wire payload is always a single element
        // (or empty when the producer had no cmdline data).
        assert_eq!(event.redacted_cmdline.len(), 1);
        assert_eq!(
            event.redacted_cmdline[0],
            "/usr/bin/curl [redacted 1 arg(s)]"
        );
        assert_eq!(event.observed_at_unix_nano, 123_456);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn process_snapshot_serializes_event_inventory_without_procfs_walk() {
        let mut inventory = SocketInventory::default();
        let flow = AttributedFlow {
            flow: FlowKey {
                address_family: AF_INET,
                transport_protocol: IPPROTO_TCP,
                endpoint_a_port: 8080,
                endpoint_b_port: 51_000,
                endpoint_a_addr: ipv4([127, 0, 0, 1]),
                endpoint_b_addr: ipv4([198, 51, 100, 20]),
            },
            pid: FlowPidRecord {
                version: 1,
                event_kind: EVENT_INET_SOCK_SET_STATE,
                pid: 123,
                tgid: 123,
                uid: 1000,
                gid: 1001,
                socket_address: 0xfeed,
                last_seen_ns: 99,
                process_generation_ns: 123_456,
                old_state: 2,
                new_state: 1,
                local_endpoint: FLOW_ENDPOINT_A,
                reserved: [0; 7],
            },
            process: Some(ProcessDetails {
                pid: 123,
                tgid: 123,
                uid: 1000,
                gid: 1001,
                comm: "app".to_string(),
                cmdline: vec![
                    "/usr/bin/app".to_string(),
                    "[redacted 1 arg(s)]".to_string(),
                ],
                container_id: Some("0123456789abcdef0123456789abcdef".to_string()),
                last_seen_ns: 99,
                process_generation_ns: 123_456,
            }),
        };

        inventory.update(&flow);
        let snapshot = inventory.snapshot_if_dirty(123).unwrap();
        inventory.update(&flow);
        let snapshot_again = inventory.snapshot_if_dirty(456);

        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].local_ip, "127.0.0.1");
        assert_eq!(snapshot.entries[0].local_port, 8080);
        assert_eq!(snapshot.entries[0].transport_protocol, "tcp");
        assert_eq!(snapshot.entries[0].pid, 123);
        assert_eq!(snapshot.entries[0].uid, 1000);
        assert_eq!(snapshot.entries[0].gid, 1001);
        assert_eq!(snapshot.entries[0].redacted_cmdline.len(), 1);
        assert_eq!(
            snapshot.entries[0].redacted_cmdline[0],
            "/usr/bin/app [redacted 1 arg(s)]"
        );
        assert!(snapshot_again.is_none());

        inventory.remove_record(&super::FlowAttributionRecord {
            version: 1,
            event_kind: EVENT_INET_SOCK_SET_STATE,
            pid: 123,
            tgid: 123,
            uid: 1000,
            gid: 1001,
            socket_address: 0xfeed,
            process_generation_ns: 123_456,
            old_state: TCP_LISTEN_STATE,
            new_state: TCP_CLOSE_STATE,
            tuple: super::FlowTupleRecord {
                family: AF_INET,
                protocol: IPPROTO_TCP,
                source_port: 8080,
                destination_port: 51_000,
                source_addr: ipv4([127, 0, 0, 1]),
                destination_addr: ipv4([198, 51, 100, 20]),
            },
            comm: [0; 16],
        });

        assert!(inventory.snapshot_if_dirty(789).unwrap().entries.is_empty());
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn socket_inventory_keeps_listener_when_accepted_connection_closes() {
        let mut inventory = SocketInventory::default();
        inventory.update(&listener_flow(ipv4([192, 0, 2, 10]), 8080));
        let _ = inventory.snapshot_if_dirty(123);

        let mut close_record = flow_record(IPPROTO_TCP, 8080, 51_000);
        close_record.new_state = TCP_CLOSE_STATE;
        inventory.remove_record(&close_record);

        assert!(inventory.snapshot_if_dirty(456).is_none());
        assert!(inventory.has_listener_for_record(&flow_record(IPPROTO_TCP, 8080, 51_001)));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn socket_inventory_only_tracks_durable_lifecycle_records() {
        let mut record = super::FlowAttributionRecord {
            version: 1,
            event_kind: EVENT_INET_SOCK_SET_STATE,
            pid: 123,
            tgid: 123,
            uid: 1000,
            gid: 1001,
            socket_address: 0xfeed,
            process_generation_ns: 123_456,
            old_state: 1,
            new_state: 1,
            tuple: super::FlowTupleRecord {
                family: AF_INET,
                protocol: IPPROTO_TCP,
                source_port: 8080,
                destination_port: 51_000,
                source_addr: ipv4([127, 0, 0, 1]),
                destination_addr: ipv4([198, 51, 100, 20]),
            },
            comm: [0; 16],
        };

        assert!(!super::should_record_inventory(&record));

        record.new_state = TCP_LISTEN_STATE;

        assert!(super::should_record_inventory(&record));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn socket_inventory_caps_snapshot_cmdline_payload() {
        let mut inventory = SocketInventory::default();
        let flow = AttributedFlow {
            flow: FlowKey {
                address_family: AF_INET,
                transport_protocol: IPPROTO_TCP,
                endpoint_a_port: 8080,
                endpoint_b_port: 0,
                endpoint_a_addr: ipv4([127, 0, 0, 1]),
                endpoint_b_addr: ipv4([0, 0, 0, 0]),
            },
            pid: FlowPidRecord {
                version: 1,
                event_kind: EVENT_INET_SOCK_SET_STATE,
                pid: 123,
                tgid: 123,
                uid: 1000,
                gid: 1001,
                socket_address: 0xfeed,
                last_seen_ns: 0,
                process_generation_ns: 123_456,
                old_state: 1,
                new_state: TCP_LISTEN_STATE,
                local_endpoint: FLOW_ENDPOINT_A,
                reserved: [0; 7],
            },
            process: Some(ProcessDetails {
                pid: 123,
                tgid: 123,
                uid: 1000,
                gid: 1001,
                comm: "app".to_string(),
                cmdline: vec![
                    "a".repeat(REDACTED_CMDLINE_MAX_BYTES + 1024),
                    "[redacted 3 arg(s)]".to_string(),
                ],
                container_id: None,
                last_seen_ns: 99,
                process_generation_ns: 123_456,
            }),
        };

        inventory.update(&flow);
        let snapshot = inventory.snapshot_if_dirty(123).unwrap();

        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].redacted_cmdline.len(), 1);
        assert!(snapshot.entries[0].redacted_cmdline[0].len() <= REDACTED_CMDLINE_MAX_BYTES);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn refresh_enriched_attributions_uses_process_index() {
        let mut cache = FlowAttributionCache::default();
        let mut process_index = ProcessAttributionIndex::default();
        let mut expiry_queue = AttributionExpiryQueue::default();
        let mut next_expiry_sequence = 0_u64;
        let matcher = SharedExternalFlowMatcher::new(0);
        let metrics = crate::metrics::Metrics::new().unwrap();
        let matching_process = ProcessDetailsCacheKey {
            tgid: 123,
            uid: 1000,
            gid: 1001,
            process_generation_ns: 42,
        };
        let other_process = ProcessDetailsCacheKey {
            tgid: 456,
            uid: 1000,
            gid: 1001,
            process_generation_ns: 84,
        };
        let matching_key = join_key(443, 51_000, 123, 42);
        let other_key = join_key(8443, 52_000, 456, 84);

        insert_cached_attribution(
            &mut cache,
            &mut process_index,
            &mut expiry_queue,
            &mut next_expiry_sequence,
            matching_key,
            cached_attribution(matching_process, "old"),
        );
        insert_cached_attribution(
            &mut cache,
            &mut process_index,
            &mut expiry_queue,
            &mut next_expiry_sequence,
            other_key,
            cached_attribution(other_process, "other"),
        );

        refresh_enriched_attributions(
            None,
            &matcher,
            &metrics,
            &mut cache,
            &process_index,
            vec![(
                matching_process,
                ProcessDetails {
                    pid: 123,
                    tgid: 123,
                    uid: 2000,
                    gid: 2001,
                    comm: "new".to_string(),
                    cmdline: vec!["/bin/new".to_string()],
                    container_id: Some("container".to_string()),
                    last_seen_ns: 0,
                    process_generation_ns: 42,
                },
            )],
        );

        assert_eq!(cache.get(&matching_key).unwrap().event.comm, "new");
        assert_eq!(cache.get(&matching_key).unwrap().event.uid, 2000);
        assert_eq!(cache.get(&other_key).unwrap().event.comm, "other");
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn refresh_enriched_attributions_emits_changed_metadata() {
        let mut cache = FlowAttributionCache::default();
        let mut process_index = ProcessAttributionIndex::default();
        let mut expiry_queue = AttributionExpiryQueue::default();
        let mut next_expiry_sequence = 0_u64;
        let matcher = SharedExternalFlowMatcher::new(0);
        let metrics = crate::metrics::Metrics::new().unwrap();
        let (tx, mut rx) = crate::event_queue::bounded(4);
        let process = ProcessDetailsCacheKey {
            tgid: 123,
            uid: 1000,
            gid: 1001,
            process_generation_ns: 42,
        };
        let key = join_key(443, 51_000, 123, 42);

        insert_cached_attribution(
            &mut cache,
            &mut process_index,
            &mut expiry_queue,
            &mut next_expiry_sequence,
            key,
            cached_attribution(process, "old"),
        );

        refresh_enriched_attributions(
            Some(&tx),
            &matcher,
            &metrics,
            &mut cache,
            &process_index,
            vec![(
                process,
                ProcessDetails {
                    pid: 123,
                    tgid: 123,
                    uid: 2000,
                    gid: 2001,
                    comm: "new".to_string(),
                    cmdline: vec!["/bin/new".to_string()],
                    container_id: Some("container".to_string()),
                    last_seen_ns: 0,
                    process_generation_ns: 42,
                },
            )],
        );

        assert_eq!(cache.get(&key).unwrap().event.comm, "new");
        let emitted = rx.try_recv().expect("enriched metadata event");
        assert_eq!(emitted.comm, "new");
        assert_eq!(emitted.redacted_cmdline, vec!["/bin/new"]);
        assert_eq!(emitted.container_id, "container");
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn close_keeps_cached_attribution_for_delayed_central_join() {
        let mut cache = FlowAttributionCache::default();
        let mut process_index = ProcessAttributionIndex::default();
        let mut expiry_queue = AttributionExpiryQueue::default();
        let mut next_expiry_sequence = 0_u64;
        let process = ProcessDetailsCacheKey {
            tgid: 123,
            uid: 1000,
            gid: 1001,
            process_generation_ns: 42,
        };
        let key = join_key(443, 51_000, 123, 42);

        insert_cached_attribution(
            &mut cache,
            &mut process_index,
            &mut expiry_queue,
            &mut next_expiry_sequence,
            key,
            cached_attribution(process, "app"),
        );

        touch_closed_cached_attribution(&mut cache, &key);

        assert!(cache.contains_key(&key));
        assert!(
            process_index
                .get(&process)
                .is_some_and(|keys| keys.contains(&key))
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn duplicate_cached_attribution_is_coalesced_until_heartbeat() {
        let metrics = crate::metrics::Metrics::new().unwrap();
        let (tx, mut rx) = crate::event_queue::bounded(4);
        let process = ProcessDetailsCacheKey {
            tgid: 123,
            uid: 1000,
            gid: 1001,
            process_generation_ns: 42,
        };
        let mut entry = cached_attribution(process, "app");
        let now = std::time::Instant::now();
        entry.last_emitted = now;
        entry.last_emitted_fingerprint = attribution_event_fingerprint(&entry.event);

        maybe_emit_cached_attribution(Some(&tx), &metrics, &mut entry, now);
        assert!(rx.try_recv().is_err());

        maybe_emit_cached_attribution(
            Some(&tx),
            &metrics,
            &mut entry,
            now + FLOW_ATTRIBUTION_RAW_HEARTBEAT_INTERVAL,
        );
        assert!(rx.try_recv().is_ok());
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn process_metadata_complete_requires_cmdline_and_container() {
        let process = ProcessDetailsCacheKey {
            tgid: 123,
            uid: 1000,
            gid: 1001,
            process_generation_ns: 42,
        };
        let mut entry = cached_attribution(process, "app");

        assert!(!process_metadata_complete(&entry.event));

        Arc::make_mut(&mut entry.event).redacted_cmdline = vec!["/bin/app".to_string()];
        assert!(!process_metadata_complete(&entry.event));

        Arc::make_mut(&mut entry.event).container_id = "container".to_string();
        assert!(process_metadata_complete(&entry.event));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn prune_attribution_cache_enforces_max_entries_and_index() {
        let mut cache = FlowAttributionCache::default();
        let mut process_index = ProcessAttributionIndex::default();
        let mut expiry_queue = AttributionExpiryQueue::default();
        let mut next_expiry_sequence = 0_u64;
        let matcher = SharedExternalFlowMatcher::new(0);

        for i in 0..(FLOW_ATTRIBUTION_CACHE_MAX_ENTRIES + 8) {
            let tgid = 123 + i as u32;
            let generation = 42 + i as u64;
            let process = ProcessDetailsCacheKey {
                tgid,
                uid: 1000,
                gid: 1001,
                process_generation_ns: generation,
            };
            let key = join_key(
                10_000u16.wrapping_add(i as u16),
                50_000u16.wrapping_add(i as u16),
                tgid,
                generation,
            );
            insert_cached_attribution(
                &mut cache,
                &mut process_index,
                &mut expiry_queue,
                &mut next_expiry_sequence,
                key,
                cached_attribution(process, "app"),
            );
        }

        prune_attribution_cache(
            &mut cache,
            &mut process_index,
            &matcher,
            &mut expiry_queue,
            &mut next_expiry_sequence,
            std::time::Instant::now(),
        );

        assert_eq!(cache.len(), FLOW_ATTRIBUTION_CACHE_LOW_WATERMARK);
        assert_eq!(
            process_index.values().map(|keys| keys.len()).sum::<usize>(),
            cache.len()
        );
    }

    #[test]
    fn parses_proc_net_tcp_listener() {
        let socket = super::parse_proc_net_socket(
            "0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 4242 1 0000000000000000 100 0 0 10 0",
            false,
            "tcp",
        )
        .unwrap();

        assert_eq!(socket.local_ip.to_string(), "127.0.0.1");
        assert_eq!(socket.local_port, 8080);
        assert_eq!(socket.inode, 4242);
    }

    #[test]
    #[cfg(unix)]
    fn process_snapshot_lists_procfs_socket_owner_with_stable_fingerprint() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join("net")).unwrap();
        fs::write(
            root.path().join("net/tcp"),
            "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 4242 1 0000000000000000 100 0 0 10 0\n",
        )
        .unwrap();

        let pid_dir = root.path().join("123");
        fs::create_dir_all(pid_dir.join("fd")).unwrap();
        fs::write(pid_dir.join("cmdline"), b"/usr/bin/app\0--secret\0").unwrap();
        fs::write(pid_dir.join("cgroup"), "").unwrap();
        fs::write(pid_dir.join("comm"), "app\n").unwrap();
        fs::write(
            pid_dir.join("status"),
            "Uid:\t1000\t1000\t1000\t1000\nGid:\t1001\t1001\t1001\t1001\nVmSize:\t1234 kB\n",
        )
        .unwrap();
        std::os::unix::fs::symlink("socket:[4242]", pid_dir.join("fd/3")).unwrap();

        let mut scheduler_comm = [0u8; 16];
        scheduler_comm[..12].copy_from_slice(b"erts_sched_3");
        let mut process_info = std::collections::HashMap::new();
        process_info.insert(
            123,
            ProcessInfoRecord {
                version: 1,
                reserved: 0,
                pid: 456,
                tgid: 123,
                uid: 1000,
                gid: 1001,
                last_seen_ns: 0,
                process_generation_ns: 99,
                comm: scheduler_comm,
            },
        );

        let snapshot = ProcfsEnricher::with_root(root.path()).process_snapshot(&process_info, 123);
        let snapshot_again =
            ProcfsEnricher::with_root(root.path()).process_snapshot(&process_info, 456);

        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].local_ip, "127.0.0.1");
        assert_eq!(snapshot.entries[0].local_port, 8080);
        assert_eq!(snapshot.entries[0].pid, 123);
        assert_eq!(snapshot.entries[0].tgid, 123);
        assert_eq!(snapshot.entries[0].comm, "app");
        assert_eq!(snapshot.entries[0].uid, 1000);
        assert_eq!(snapshot.entries[0].redacted_cmdline.len(), 2);
        assert_eq!(snapshot.fingerprint, snapshot_again.fingerprint);
        assert_ne!(
            snapshot.observed_at_unix_nano,
            snapshot_again.observed_at_unix_nano
        );
    }

    #[test]
    fn is_userspace_process_rejects_missing_and_kernel_like_status() {
        let root = tempfile::tempdir().unwrap();
        assert!(!is_userspace_process(root.path(), 0));
        assert!(!is_userspace_process(root.path(), 999_999));

        let kthread = root.path().join("42");
        fs::create_dir_all(&kthread).unwrap();
        fs::write(kthread.join("comm"), "swapper/0\n").unwrap();
        // Kernel threads: no exe, no VmSize.
        fs::write(kthread.join("status"), "Name:\tswapper/0\nPid:\t42\n").unwrap();
        assert!(!is_userspace_process(root.path(), 42));

        let app = root.path().join("99");
        fs::create_dir_all(&app).unwrap();
        fs::write(app.join("comm"), "gitea\n").unwrap();
        fs::write(
            app.join("status"),
            "Name:\tgitea\nPid:\t99\nVmSize:\t1234 kB\n",
        )
        .unwrap();
        std::os::unix::fs::symlink("/usr/bin/gitea", app.join("exe")).unwrap();
        assert!(is_userspace_process(root.path(), 99));
    }

    #[test]
    fn flow_event_strips_process_identity_without_userspace_pid() {
        let flow = AttributedFlow {
            flow: crate::af_xdp_classifier::FlowKey {
                address_family: AF_INET,
                transport_protocol: IPPROTO_TCP,
                endpoint_a_port: 443,
                endpoint_b_port: 50000,
                endpoint_a_addr: [10, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                endpoint_b_addr: [1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            },
            pid: FlowPidRecord {
                version: 1,
                event_kind: 2,
                pid: 0,
                tgid: 0,
                uid: 0,
                gid: 0,
                socket_address: 0,
                last_seen_ns: 0,
                process_generation_ns: 0,
                old_state: 0,
                new_state: 0,
                local_endpoint: 1,
                reserved: [0; 7],
            },
            process: Some(ProcessDetails {
                pid: 0,
                tgid: 0,
                uid: 0,
                gid: 0,
                comm: "swapper/20".into(),
                cmdline: Vec::new(),
                container_id: None,
                last_seen_ns: 0,
                process_generation_ns: 0,
            }),
        };
        let event = flow_attribution_event(&flow, 1).unwrap();
        assert_eq!(event.pid, 0);
        assert_eq!(event.tgid, 0);
        assert!(
            event.comm.is_empty(),
            "must not emit kernel comm without pid"
        );
    }

    #[test]
    fn preferred_process_owner_prefers_container_over_host() {
        let host = ProcessDetails {
            pid: 10,
            tgid: 10,
            uid: 0,
            gid: 0,
            comm: "k3s-agent".to_string(),
            cmdline: vec!["/usr/local/bin/k3s".to_string()],
            container_id: None,
            last_seen_ns: 0,
            process_generation_ns: 0,
        };
        let container = ProcessDetails {
            pid: 99,
            tgid: 99,
            uid: 1000,
            gid: 1000,
            comm: "beam.smp".to_string(),
            cmdline: vec![],
            container_id: Some("a".repeat(64)),
            last_seen_ns: 0,
            process_generation_ns: 0,
        };

        let winner = preferred_process_owner(vec![host.clone(), container.clone()]).unwrap();
        assert_eq!(winner.pid, 99);
        assert_eq!(winner.comm, "beam.smp");

        let winner_reversed = preferred_process_owner(vec![container, host]).unwrap();
        assert_eq!(winner_reversed.pid, 99);
    }

    #[test]
    #[cfg(unix)]
    fn process_snapshot_prefers_container_owner_when_inode_shared() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join("net")).unwrap();
        fs::write(
            root.path().join("net/tcp"),
            "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 4242 1 0000000000000000 100 0 0 10 0\n",
        )
        .unwrap();

        // Host dual-view: no container id in cgroup.
        let host_dir = root.path().join("10");
        fs::create_dir_all(host_dir.join("fd")).unwrap();
        fs::write(host_dir.join("cmdline"), b"/usr/local/bin/k3s\0agent\0").unwrap();
        fs::write(host_dir.join("cgroup"), "0::/system.slice/k3s.service\n").unwrap();
        fs::write(host_dir.join("comm"), "k3s-agent\n").unwrap();
        fs::write(
            host_dir.join("status"),
            "Uid:\t0\t0\t0\t0\nGid:\t0\t0\t0\t0\nVmSize:\t2048 kB\n",
        )
        .unwrap();
        std::os::unix::fs::symlink("socket:[4242]", host_dir.join("fd/3")).unwrap();

        // Container process: 64-hex container id in cgroup path.
        let cid = "a".repeat(64);
        let app_dir = root.path().join("99");
        fs::create_dir_all(app_dir.join("fd")).unwrap();
        fs::write(app_dir.join("cmdline"), b"/app/bin/server\0").unwrap();
        fs::write(
            app_dir.join("cgroup"),
            format!("0::/kubepods.slice/cri-containerd-{cid}.scope\n"),
        )
        .unwrap();
        fs::write(app_dir.join("comm"), "beam.smp\n").unwrap();
        fs::write(
            app_dir.join("status"),
            "Uid:\t1000\t1000\t1000\t1000\nGid:\t1000\t1000\t1000\t1000\nVmSize:\t4096 kB\n",
        )
        .unwrap();
        std::os::unix::fs::symlink("socket:[4242]", app_dir.join("fd/3")).unwrap();

        let snapshot = ProcfsEnricher::with_root(root.path()).process_snapshot(&HashMap::new(), 1);

        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].pid, 99);
        assert_eq!(snapshot.entries[0].comm, "beam.smp");
        assert_eq!(snapshot.entries[0].container_id, cid);
    }

    #[test]
    fn cap_redacted_cmdline_returns_empty_for_empty_parts() {
        assert!(cap_redacted_cmdline(Vec::new()).is_empty());
    }

    #[test]
    fn cap_redacted_cmdline_preserves_short_ascii_payload() {
        let parts = vec![
            "/usr/bin/curl".to_string(),
            "[redacted 2 arg(s)]".to_string(),
        ];
        let capped = cap_redacted_cmdline(parts);
        assert_eq!(capped.len(), 1);
        assert_eq!(capped[0], "/usr/bin/curl [redacted 2 arg(s)]");
        assert!(capped[0].len() <= REDACTED_CMDLINE_MAX_BYTES);
    }

    #[test]
    fn cap_redacted_cmdline_caps_payload_exactly_at_limit() {
        // Build a single argv0 whose joined length is exactly 256 bytes — no
        // truncation should occur and the cap helper should pass it through.
        let argv0 = "a".repeat(REDACTED_CMDLINE_MAX_BYTES);
        let capped = cap_redacted_cmdline(vec![argv0.clone()]);
        assert_eq!(capped.len(), 1);
        assert_eq!(capped[0].len(), REDACTED_CMDLINE_MAX_BYTES);
        assert_eq!(capped[0], argv0);
    }

    #[test]
    fn cap_redacted_cmdline_truncates_oversized_ascii_argv0() {
        let argv0 = "a".repeat(REDACTED_CMDLINE_MAX_BYTES + 64);
        let capped = cap_redacted_cmdline(vec![argv0, "[redacted 1 arg(s)]".to_string()]);
        assert_eq!(capped.len(), 1);
        assert_eq!(capped[0].len(), REDACTED_CMDLINE_MAX_BYTES);
        assert!(capped[0].chars().all(|c| c == 'a'));
    }

    #[test]
    fn cap_redacted_cmdline_respects_utf8_codepoint_boundary() {
        // The 4-byte UTF-8 sequence "🚀" (U+1F680) crosses 256 bytes when
        // joined with enough leading single-byte padding. The cap must
        // truncate *before* the multi-byte sequence so the returned string
        // is still valid UTF-8 (Rust would panic on slice otherwise, but we
        // assert the boundary explicitly).
        let padding_len = REDACTED_CMDLINE_MAX_BYTES - 2; // landing mid-rocket
        let mut argv0 = "a".repeat(padding_len);
        argv0.push_str("🚀🚀");
        let capped = cap_redacted_cmdline(vec![argv0]);
        assert_eq!(capped.len(), 1);
        assert!(capped[0].len() <= REDACTED_CMDLINE_MAX_BYTES);
        // The single byte at offset `padding_len` lies inside a 4-byte UTF-8
        // sequence, so the helper walks back to the previous codepoint
        // boundary at `padding_len` itself.
        assert_eq!(capped[0].len(), padding_len);
        assert!(capped[0].is_char_boundary(capped[0].len()));
        // Round-tripping through `from_utf8` proves the slice is valid.
        assert!(std::str::from_utf8(capped[0].as_bytes()).is_ok());
    }

    #[test]
    fn trim_to_utf8_boundary_is_no_op_when_under_limit() {
        let value = "hello world";
        assert_eq!(trim_to_utf8_boundary(value, 256), value);
    }

    #[test]
    fn trim_to_utf8_boundary_walks_back_through_multibyte() {
        // "héllo" — the "é" is two bytes (0xC3 0xA9). Asking for a 2-byte
        // cap lands in the middle of "é", so the helper must walk back to
        // byte 1 (just after the leading "h").
        let trimmed = trim_to_utf8_boundary("héllo", 2);
        assert_eq!(trimmed, "h");
    }

    #[test]
    fn flow_attribution_event_caps_redacted_cmdline_to_contract() {
        let argv0 = "a".repeat(REDACTED_CMDLINE_MAX_BYTES + 32);
        let flow = AttributedFlow {
            flow: FlowKey {
                address_family: AF_INET,
                transport_protocol: IPPROTO_TCP,
                endpoint_a_port: 443,
                endpoint_b_port: 51_000,
                endpoint_a_addr: ipv4([192, 0, 2, 10]),
                endpoint_b_addr: ipv4([198, 51, 100, 20]),
            },
            pid: FlowPidRecord {
                version: 1,
                event_kind: 2,
                pid: 7,
                tgid: 7,
                uid: 0,
                gid: 0,
                socket_address: 0,
                last_seen_ns: 0,
                process_generation_ns: 0,
                old_state: 0,
                new_state: 0,
                local_endpoint: FLOW_ENDPOINT_B,
                reserved: [0; 7],
            },
            process: Some(ProcessDetails {
                pid: 7,
                tgid: 7,
                uid: 0,
                gid: 0,
                comm: "longargv".to_string(),
                cmdline: vec![argv0, "[redacted 9 arg(s)]".to_string()],
                container_id: None,
                last_seen_ns: 0,
                process_generation_ns: 0,
            }),
        };

        let event = flow_attribution_event(&flow, 1).unwrap();
        assert_eq!(event.redacted_cmdline.len(), 1);
        assert!(event.redacted_cmdline[0].len() <= REDACTED_CMDLINE_MAX_BYTES);
    }

    #[test]
    fn redacted_cmdline_producer_reads_unbounded_proc_payload() {
        // Confirms /proc reads keep returning raw argv material and capping
        // happens at the outbound payload construction sites.
        let big_argv0 = "b".repeat(1024);
        let mut bytes = big_argv0.clone().into_bytes();
        bytes.push(0);
        bytes.extend_from_slice(b"--token\0secret\0");
        let root = temp_proc("321", &bytes, "");
        let parts = redacted_cmdline(root.path(), 321);
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0], big_argv0);
        assert_eq!(parts[1], "[redacted 2 arg(s)]");
    }

    #[cfg(target_os = "linux")]
    fn join_key(
        local_port: u16,
        remote_port: u16,
        tgid: u32,
        process_generation_ns: u64,
    ) -> super::FlowAttributionJoinKey {
        super::FlowAttributionJoinKey {
            flow: FlowKey {
                address_family: AF_INET,
                transport_protocol: IPPROTO_TCP,
                endpoint_a_port: local_port,
                endpoint_b_port: remote_port,
                endpoint_a_addr: ipv4([192, 0, 2, 10]),
                endpoint_b_addr: ipv4([198, 51, 100, 20]),
            },
            pid: tgid,
            tgid,
            process_generation_ns,
        }
    }

    #[cfg(target_os = "linux")]
    fn cached_attribution(process_key: ProcessDetailsCacheKey, comm: &str) -> CachedAttribution {
        CachedAttribution {
            event: Arc::new(crate::proto::netprobe::FlowAttributionEvent {
                local_ip: "192.0.2.10".to_string(),
                local_port: 443,
                remote_ip: "198.51.100.20".to_string(),
                remote_port: 51_000,
                transport_protocol: "tcp".to_string(),
                pid: process_key.tgid,
                tgid: process_key.tgid,
                uid: process_key.uid,
                gid: process_key.gid,
                comm: comm.to_string(),
                redacted_cmdline: Vec::new(),
                container_id: String::new(),
                observed_at_unix_nano: 1,
                socket_address: 0,
                event_kind: u32::from(EVENT_INET_SOCK_SET_STATE),
                old_state: 1,
                new_state: 1,
                source: String::new(),
                external_flow_id: 0,
                workload_identity: None,
            }),
            process_key,
            last_seen: std::time::Instant::now(),
            last_emitted: std::time::Instant::now(),
            last_emitted_fingerprint: 0,
            last_metadata_attempt: std::time::Instant::now(),
        }
    }

    fn flow_record(
        protocol: u16,
        source_port: u16,
        destination_port: u16,
    ) -> super::FlowAttributionRecord {
        super::FlowAttributionRecord {
            version: 1,
            event_kind: EVENT_INET_SOCK_SET_STATE,
            pid: 123,
            tgid: 123,
            uid: 1000,
            gid: 1001,
            socket_address: 0xfeed,
            process_generation_ns: 42,
            old_state: 1,
            new_state: 1,
            tuple: super::FlowTupleRecord {
                family: AF_INET,
                protocol,
                source_port,
                destination_port,
                source_addr: ipv4([192, 0, 2, 10]),
                destination_addr: ipv4([198, 51, 100, 20]),
            },
            comm: [0; 16],
        }
    }

    #[cfg(target_os = "linux")]
    fn udp_record(
        event_kind: u16,
        local_port: u16,
        remote_port: u16,
    ) -> super::FlowAttributionRecord {
        let mut record = flow_record(IPPROTO_UDP, local_port, remote_port);
        record.event_kind = event_kind;
        record
    }

    #[cfg(target_os = "linux")]
    fn listener_flow(local_addr: [u8; 16], local_port: u16) -> AttributedFlow {
        AttributedFlow {
            flow: FlowKey {
                address_family: AF_INET,
                transport_protocol: IPPROTO_TCP,
                endpoint_a_port: local_port,
                endpoint_b_port: 0,
                endpoint_a_addr: local_addr,
                endpoint_b_addr: [0; 16],
            },
            pid: FlowPidRecord {
                version: 1,
                event_kind: EVENT_INET_SOCK_SET_STATE,
                pid: 123,
                tgid: 123,
                uid: 1000,
                gid: 1001,
                socket_address: 0xfeed,
                last_seen_ns: 0,
                process_generation_ns: 42,
                old_state: 1,
                new_state: TCP_LISTEN_STATE,
                local_endpoint: FLOW_ENDPOINT_A,
                reserved: [0; 7],
            },
            process: None,
        }
    }

    fn temp_proc(pid: &str, cmdline: &[u8], cgroup: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let pid_dir = dir.path().join(pid);
        fs::create_dir_all(&pid_dir).unwrap();
        fs::write(pid_dir.join("cmdline"), cmdline).unwrap();
        fs::write(pid_dir.join("cgroup"), cgroup).unwrap();
        // Gives the fixture a userspace shape. `is_userspace_process` accepts a resolvable
        // `exe` link or a `VmSize:` line, and rejects everything else -- so without this the
        // process reads as a kernel task and `process_details` returns an empty record
        // (comm "", cmdline [], container_id None) before touching the files above.
        //
        // VmSize is the only line written on purpose: `status` is also the source for Uid:/Gid:
        // (see read_process_ids), so adding those here would silently change which value every
        // test using this helper resolves uid/gid from.
        fs::write(pid_dir.join("status"), "VmSize:\t1234 kB\n").unwrap();
        dir
    }

    fn ipv4(bytes: [u8; 4]) -> [u8; 16] {
        let mut out = [0u8; 16];
        out[..4].copy_from_slice(&bytes);
        out
    }
}
