use std::{
    collections::{HashMap, HashSet},
    fs,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[cfg(target_os = "linux")]
use std::{
    collections::VecDeque,
    io, mem,
    os::fd::AsRawFd,
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use crate::af_xdp_classifier::FlowKey;
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
// Mirrors EVENT_TCP_CLOSE in the eBPF: a close record evicts the flow.
const EVENT_TCP_CLOSE: u16 = 3;
#[cfg(target_os = "linux")]
const EVENT_INET_SOCK_SET_STATE: u16 = 6;
#[cfg(target_os = "linux")]
const TCP_CLOSE_STATE: i32 = 7;
#[cfg(target_os = "linux")]
const TCP_LISTEN_STATE: i32 = 10;

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
// carry a populated `tuple` read off the struct sock; the bare
// tcp_connect/accept/close lifecycle probes submit an empty tuple, so those
// records have no usable 5-tuple and are skipped by the consumer.
#[cfg(target_os = "linux")]
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

#[cfg(target_os = "linux")]
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
    entries: HashMap<SocketInventoryKey, CachedProcessSocket>,
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
        let key = SocketInventoryKey {
            address_family: flow.flow.address_family,
            transport_protocol: flow.flow.transport_protocol,
            local_addr: match flow.pid.local_endpoint {
                FLOW_ENDPOINT_A => flow.flow.endpoint_a_addr,
                FLOW_ENDPOINT_B => flow.flow.endpoint_b_addr,
                _ => return,
            },
            local_port,
            pid: flow.pid.pid,
            tgid: flow.pid.tgid,
            process_generation_ns: flow.pid.process_generation_ns,
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
            redacted_cmdline: process
                .map(|details| details.cmdline.clone())
                .unwrap_or_default(),
            container_id: process
                .and_then(|details| details.container_id.clone())
                .unwrap_or_default(),
        };
        let now = Instant::now();

        match self.entries.get_mut(&key) {
            Some(cached) if cached.entry == entry => {
                cached.last_seen = now;
            }
            Some(cached) => {
                cached.entry = entry;
                cached.last_seen = now;
                self.dirty = true;
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
        let Some(flow) = flow_key_from_record(record) else {
            return;
        };
        let key = SocketInventoryKey {
            address_family: flow.address_family,
            transport_protocol: flow.transport_protocol,
            local_addr: flow.endpoint_a_addr,
            local_port: flow.endpoint_a_port,
            pid: record.pid,
            tgid: record.tgid,
            process_generation_ns: record.process_generation_ns,
        };
        if self.entries.remove(&key).is_some() {
            self.dirty = true;
        }
    }

    fn touch_record(&mut self, record: &FlowAttributionRecord) -> bool {
        let Some(flow) = flow_key_from_record(record) else {
            return false;
        };
        let key = SocketInventoryKey {
            address_family: flow.address_family,
            transport_protocol: flow.transport_protocol,
            local_addr: flow.endpoint_a_addr,
            local_port: flow.endpoint_a_port,
            pid: record.pid,
            tgid: record.tgid,
            process_generation_ns: record.process_generation_ns,
        };
        let Some(cached) = self.entries.get_mut(&key) else {
            return false;
        };

        cached.last_seen = Instant::now();
        true
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
    pid: u32,
    tgid: u32,
    process_generation_ns: u64,
}

#[cfg(target_os = "linux")]
struct CachedProcessSocket {
    entry: ProcessSnapshotEntry,
    last_seen: Instant,
}

#[cfg(target_os = "linux")]
trait AttributionBackend {
    fn drain_records(&mut self) -> Vec<FlowAttributionRecord>;
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
    fn drain_records(&mut self) -> Vec<FlowAttributionRecord> {
        let mut records = Vec::new();
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
        records
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
        ProcessDetails {
            pid: record.pid,
            tgid: record.tgid,
            uid: record.uid,
            gid: record.gid,
            comm: comm_from_bytes(&record.comm),
            cmdline: redacted_cmdline(&self.root, record.tgid),
            container_id: container_id(&self.root, record.tgid),
            last_seen_ns: record.last_seen_ns,
            process_generation_ns: record.process_generation_ns,
        }
    }

    fn process_details_for_pid(
        &self,
        pid: u32,
        process_info: &HashMap<u32, ProcessInfoRecord>,
    ) -> Option<ProcessDetails> {
        if let Some(record) = process_info.get(&pid) {
            return Some(self.process_details(record));
        }

        let (uid, gid) = read_status_ids(&self.root, pid).unwrap_or_default();
        Some(ProcessDetails {
            pid,
            tgid: pid,
            uid,
            gid,
            comm: read_comm(&self.root, pid).unwrap_or_default(),
            cmdline: redacted_cmdline(&self.root, pid),
            container_id: container_id(&self.root, pid),
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
            for pid in pids {
                let Some(process) = self.process_details_for_pid(*pid, process_info) else {
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
                });
            }
        }

        sort_snapshot_entries(&mut entries);

        ProcessSnapshot {
            fingerprint: snapshot_fingerprint(&entries),
            observed_at_unix_nano,
            entries,
        }
    }
}

#[cfg(target_os = "linux")]
struct MetadataEnricher {
    procfs: ProcfsEnricher,
    cache: HashMap<ProcessDetailsCacheKey, CachedProcessDetails>,
    pending: VecDeque<ProcessInfoRecord>,
    pending_keys: HashSet<ProcessDetailsCacheKey>,
    read_budget: MetadataReadBudget,
}

#[cfg(target_os = "linux")]
impl MetadataEnricher {
    fn host() -> Self {
        Self {
            procfs: ProcfsEnricher::host(),
            cache: HashMap::new(),
            pending: VecDeque::new(),
            pending_keys: HashSet::new(),
            read_budget: MetadataReadBudget::new(
                PROCESS_DETAILS_COLD_READS_PER_SECOND,
                PROCESS_DETAILS_COLD_READ_BURST,
            ),
        }
    }

    fn process_details(
        &mut self,
        record: &ProcessInfoRecord,
    ) -> (ProcessDetails, ProcessDetailsCacheKey) {
        let key = ProcessDetailsCacheKey::from(record);
        let now = Instant::now();

        if let Some(cached) = self.cache.get_mut(&key) {
            if now.duration_since(cached.updated_at) < PROCESS_DETAILS_CACHE_TTL {
                cached.last_used = now;
                return (cached.details.clone(), key);
            }
        }

        if self.pending_keys.insert(key) {
            self.pending.push_back(*record);
        }

        (process_details_from_record(record), key)
    }

    fn process_pending(&mut self) -> Vec<(ProcessDetailsCacheKey, ProcessDetails)> {
        let mut updated = Vec::new();
        while self.read_budget.try_acquire(Instant::now()) {
            let Some(record) = self.pending.pop_front() else {
                break;
            };
            let key = ProcessDetailsCacheKey::from(&record);
            self.pending_keys.remove(&key);

            let details = self.procfs.process_details(&record);
            let now = Instant::now();
            self.prune(now);
            self.cache.insert(
                key,
                CachedProcessDetails {
                    details: details.clone(),
                    updated_at: now,
                    last_used: now,
                },
            );
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
}

#[cfg(target_os = "linux")]
impl AyaAttributionReader {
    pub fn from_ebpf(ebpf: &mut aya::Ebpf) -> anyhow::Result<Self> {
        Ok(Self {
            backend: EbpfAttributionBackend::from_ebpf(ebpf)?,
            metadata: MetadataEnricher::host(),
            socket_inventory: SocketInventory::default(),
        })
    }

    fn drain_records(&mut self) -> Vec<FlowAttributionRecord> {
        self.backend.drain_records()
    }

    fn wait_for_records(&self, timeout: Duration) -> io::Result<bool> {
        self.backend.wait_for_records(timeout)
    }

    /// Build an `AttributedFlow` from a ring record. Returns `None` for records
    /// without a usable 5-tuple (the per-packet tcp/udp probes emit empty
    /// tuples). The record's `tuple` is directional with the local socket as the
    /// source, so endpoint A is always the local side — matching the local/remote
    /// semantics the map-snapshot path produced via the canonical key.
    fn attributed_flow_from_record(
        &mut self,
        record: &FlowAttributionRecord,
        metrics: &Metrics,
    ) -> Option<AttributedFlow> {
        let flow = flow_key_from_record(record)?;
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
        let (details, _) = self.metadata.process_details(&info);
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
        let updated = self.metadata.process_pending();
        updated
    }

    fn metadata_cache_len(&self) -> usize {
        self.metadata.cache_len()
    }
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
        tx: tokio::sync::broadcast::Sender<FlowAttributionEvent>,
        process_snapshot_tx: tokio::sync::broadcast::Sender<ProcessSnapshot>,
        metrics: Metrics,
        runtime_config: FlowAttributionRuntimeConfig,
    ) -> std::io::Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let stop_worker = Arc::clone(&stop);
        let thread = thread::Builder::new()
            .name("netprobe-flow-attribution-ring-reader".to_owned())
            .spawn(move || {
                // Live attribution cache, keyed by (flow, pid, tgid). New flows are
                // broadcast immediately. Optional cache re-broadcasts keep long-lived
                // flows visible to reconnecting agents without flooding busy workers.
                let mut cache: HashMap<FlowAttributionJoinKey, CachedAttribution> = HashMap::new();
                let mut last_process_snapshot = runtime_config
                    .process_snapshot_interval
                    .map(|interval| Instant::now() - interval);
                let mut last_resend = Instant::now();
                while !stop_worker.load(Ordering::Relaxed) {
                    drain_ring(&mut reader, &tx, &metrics, &mut cache);
                    let enriched = reader.process_pending_metadata();
                    if !enriched.is_empty() {
                        refresh_enriched_attributions(&tx, &metrics, &mut cache, enriched);
                        metrics.set_attribution_cache_entries(
                            "process_metadata",
                            reader.metadata_cache_len(),
                        );
                    }
                    if reader.inventory_dirty() {
                        emit_process_snapshot(&mut reader, &process_snapshot_tx, &metrics);
                    }
                    if let Some(resend_interval) = runtime_config.resend_interval {
                        if last_resend.elapsed() >= resend_interval {
                            resend_cache(&tx, &metrics, &mut cache);
                            last_resend = Instant::now();
                        }
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
        if let Some(thread) = self.thread.take() {
            if thread.join().is_err() {
                log::warn!("flow attribution map reader thread panicked during shutdown");
            }
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
    event: FlowAttributionEvent,
    process_key: ProcessDetailsCacheKey,
    last_seen: Instant,
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct ProcessDetailsCacheKey {
    tgid: u32,
    uid: u32,
    gid: u32,
    process_generation_ns: u64,
    comm: [u8; 16],
}

#[cfg(target_os = "linux")]
impl From<&ProcessInfoRecord> for ProcessDetailsCacheKey {
    fn from(value: &ProcessInfoRecord) -> Self {
        Self {
            tgid: value.tgid,
            uid: value.uid,
            gid: value.gid,
            process_generation_ns: value.process_generation_ns,
            comm: value.comm,
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
            comm: value.comm,
        }
    }
}

#[cfg(target_os = "linux")]
struct CachedProcessDetails {
    details: ProcessDetails,
    updated_at: Instant,
    last_used: Instant,
}

// Drain the ring buffer and emit a flow-attribution event for every newly-seen
// flow. A record for an already-cached flow refreshes the cached event (so the
// next resend carries its latest state) without re-broadcasting. A close record
// evicts the flow. Returns the number of records drained so the caller can
// distinguish a busy ring (loop again) from an idle one (sleep).
#[cfg(target_os = "linux")]
fn drain_ring(
    reader: &mut AyaAttributionReader,
    tx: &tokio::sync::broadcast::Sender<FlowAttributionEvent>,
    metrics: &Metrics,
    cache: &mut HashMap<FlowAttributionJoinKey, CachedAttribution>,
) -> usize {
    let records = reader.drain_records();
    let drained = records.len();
    for record in &records {
        if record.event_kind == EVENT_TCP_CLOSE {
            reader.remove_inventory_record(record);
            if let Some(key) = join_key_from_record(record) {
                cache.remove(&key);
            }
            continue;
        }
        if record.event_kind == EVENT_INET_SOCK_SET_STATE && record.new_state == TCP_CLOSE_STATE {
            reader.remove_inventory_record(record);
            if let Some(key) = join_key_from_record(record) {
                cache.remove(&key);
            }
            continue;
        }
        let Some(key) = join_key_from_record(record) else {
            metrics.inc_attribution_backend_events(reader.backend_method(), "miss", 1);
            continue;
        };
        if let Some(existing) = cache.get_mut(&key) {
            metrics.inc_attribution_backend_events(reader.backend_method(), "hit", 1);
            if !should_record_inventory(record) || reader.touch_inventory_record(record) {
                existing.event.observed_at_unix_nano = now_unix_nano();
                existing.last_seen = Instant::now();
                continue;
            }
        }
        let Some(flow) = reader.attributed_flow_from_record(record, metrics) else {
            metrics.inc_attribution_backend_events(reader.backend_method(), "miss", 1);
            continue;
        };
        metrics.inc_attribution_backend_events(reader.backend_method(), "hit", 1);
        reader.record_inventory(record, &flow);
        metrics.set_attribution_cache_entries("socket_inventory", reader.inventory_len());
        let Some(event) = flow.event() else {
            continue;
        };
        let process_key = ProcessDetailsCacheKey::from(record);
        if let Some(existing) = cache.get_mut(&key) {
            existing.event = event;
            existing.process_key = process_key;
            existing.last_seen = Instant::now();
        } else {
            metrics.inc_flow_attribution_events();
            if tx.send(event.clone()).is_err() {
                metrics.inc_flow_attribution_events_dropped("no_receiver", 1);
            }
            cache.insert(
                key,
                CachedAttribution {
                    event,
                    process_key,
                    last_seen: Instant::now(),
                },
            );
        }
    }
    drained
}

// Prune stale entries, then re-broadcast every live attribution so an
// absent/reconnecting/lagging agent reliably receives them (broadcast sends are
// dropped when no receiver is attached and are otherwise never re-sent).
#[cfg(target_os = "linux")]
fn resend_cache(
    tx: &tokio::sync::broadcast::Sender<FlowAttributionEvent>,
    metrics: &Metrics,
    cache: &mut HashMap<FlowAttributionJoinKey, CachedAttribution>,
) {
    cache.retain(|_, entry| entry.last_seen.elapsed() < FLOW_ATTRIBUTION_CACHE_TTL);
    for entry in cache.values() {
        metrics.inc_flow_attribution_events();
        if tx.send(entry.event.clone()).is_err() {
            metrics.inc_flow_attribution_events_dropped("no_receiver", 1);
        }
    }
}

#[cfg(target_os = "linux")]
fn refresh_enriched_attributions(
    tx: &tokio::sync::broadcast::Sender<FlowAttributionEvent>,
    metrics: &Metrics,
    cache: &mut HashMap<FlowAttributionJoinKey, CachedAttribution>,
    updated: Vec<(ProcessDetailsCacheKey, ProcessDetails)>,
) {
    for (process_key, details) in updated {
        metrics.inc_attribution_backend_events("procfs", "metadata_cold_read", 1);
        for entry in cache
            .values_mut()
            .filter(|entry| entry.process_key == process_key)
        {
            if !apply_process_details_to_event(&mut entry.event, &details) {
                continue;
            }
            entry.event.observed_at_unix_nano = now_unix_nano();
            entry.last_seen = Instant::now();
            metrics.inc_flow_attribution_events();
            if tx.send(entry.event.clone()).is_err() {
                metrics.inc_flow_attribution_events_dropped("no_receiver", 1);
            }
        }
    }
}

fn apply_process_details_to_event(
    event: &mut FlowAttributionEvent,
    details: &ProcessDetails,
) -> bool {
    let redacted_cmdline = cap_redacted_cmdline(details.cmdline.clone());
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
#[cfg(target_os = "linux")]
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

#[cfg(target_os = "linux")]
fn should_record_inventory(record: &FlowAttributionRecord) -> bool {
    record.event_kind == EVENT_INET_SOCK_SET_STATE && record.new_state == TCP_LISTEN_STATE
}

#[cfg(target_os = "linux")]
fn join_key_from_record(record: &FlowAttributionRecord) -> Option<FlowAttributionJoinKey> {
    Some(FlowAttributionJoinKey {
        flow: flow_key_from_record(record)?,
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

/// Joins `parts` with a single space and truncates the result to
/// [`REDACTED_CMDLINE_MAX_BYTES`] bytes on a UTF-8 codepoint boundary.
///
/// Returns an empty vector when `parts` is empty so that the
/// `repeated string redacted_cmdline` field stays unset on the wire.
/// Otherwise the helper always returns a single-element vector — the
/// joined, possibly-truncated payload — because the §20.15 contract
/// caps the cumulative byte length of the field, not its element count.
fn cap_redacted_cmdline(parts: Vec<String>) -> Vec<String> {
    if parts.is_empty() {
        return Vec::new();
    }
    let joined = parts.join(" ");
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

fn flow_attribution_event(
    flow: &AttributedFlow,
    observed_at_unix_nano: i64,
) -> Option<FlowAttributionEvent> {
    let (local_ip, local_port, remote_ip, remote_port) =
        endpoints(&flow.flow, flow.pid.local_endpoint)?;
    let process = flow.process.as_ref();

    Some(FlowAttributionEvent {
        local_ip: local_ip.to_string(),
        local_port: u32::from(local_port),
        remote_ip: remote_ip.to_string(),
        remote_port: u32::from(remote_port),
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
    for chunk in bytes.chunks_exact_mut(4) {
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

    use super::{
        cap_redacted_cmdline, comm_from_bytes, container_id, flow_attribution_event,
        redacted_cmdline, trim_to_utf8_boundary, AttributedFlow, FlowPidRecord, ProcessDetails,
        ProcessInfoRecord, ProcfsEnricher, AF_INET, FLOW_ENDPOINT_B, IPPROTO_TCP,
        REDACTED_CMDLINE_MAX_BYTES,
    };
    #[cfg(target_os = "linux")]
    use super::{
        process_details_from_record, SocketInventory, EVENT_INET_SOCK_SET_STATE, FLOW_ENDPOINT_A,
        TCP_CLOSE_STATE, TCP_LISTEN_STATE,
    };
    use crate::af_xdp_classifier::FlowKey;

    #[test]
    fn comm_stops_at_nul() {
        let mut comm = [0u8; 16];
        comm[..7].copy_from_slice(b"netprob");

        assert_eq!(comm_from_bytes(&comm), "netprob");
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
        assert_eq!(snapshot.entries[0].redacted_cmdline.len(), 2);
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
            old_state: 1,
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
            "Uid:\t1000\t1000\t1000\t1000\nGid:\t1001\t1001\t1001\t1001\n",
        )
        .unwrap();
        std::os::unix::fs::symlink("socket:[4242]", pid_dir.join("fd/3")).unwrap();

        let snapshot = ProcfsEnricher::with_root(root.path())
            .process_snapshot(&std::collections::HashMap::new(), 123);
        let snapshot_again = ProcfsEnricher::with_root(root.path())
            .process_snapshot(&std::collections::HashMap::new(), 456);

        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].local_ip, "127.0.0.1");
        assert_eq!(snapshot.entries[0].local_port, 8080);
        assert_eq!(snapshot.entries[0].pid, 123);
        assert_eq!(snapshot.entries[0].uid, 1000);
        assert_eq!(snapshot.entries[0].redacted_cmdline.len(), 2);
        assert_eq!(snapshot.fingerprint, snapshot_again.fingerprint);
        assert_ne!(
            snapshot.observed_at_unix_nano,
            snapshot_again.observed_at_unix_nano
        );
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
        // Confirms the cap lives at the FlowAttributionEvent construction
        // site rather than the /proc read — the producer returns the raw
        // argv0 + placeholder as before so ProcessSnapshotEntry can stay
        // unchanged and the cap is only applied on the wire shape that
        // §20.15 governs.
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

    fn temp_proc(pid: &str, cmdline: &[u8], cgroup: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let pid_dir = dir.path().join(pid);
        fs::create_dir_all(&pid_dir).unwrap();
        fs::write(pid_dir.join("cmdline"), cmdline).unwrap();
        fs::write(pid_dir.join("cgroup"), cgroup).unwrap();
        dir
    }

    fn ipv4(bytes: [u8; 4]) -> [u8; 16] {
        let mut out = [0u8; 16];
        out[..4].copy_from_slice(&bytes);
        out
    }
}
