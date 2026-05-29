use std::{
    collections::{HashMap, HashSet},
    fs,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[cfg(target_os = "linux")]
use std::{
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
const IPPROTO_TCP: u16 = 6;
const IPPROTO_UDP: u16 = 17;
const FLOW_ENDPOINT_A: u8 = 1;
const FLOW_ENDPOINT_B: u8 = 2;
#[cfg(target_os = "linux")]
const FLOW_ATTRIBUTION_POLL_INTERVAL: Duration = Duration::from_secs(1);

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
    pub comm: [u8; 16],
}

#[cfg(target_os = "linux")]
// SAFETY: ProcessInfoRecord is #[repr(C)], Copy, and contains only integer
// fields and a fixed byte array. Its layout mirrors the eBPF process_info map value.
unsafe impl aya::Pod for ProcessInfoRecord {}

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

        ProcessSnapshot {
            fingerprint: snapshot_fingerprint(&entries),
            observed_at_unix_nano,
            entries,
        }
    }
}

#[cfg(target_os = "linux")]
pub struct AyaAttributionReader {
    flow_to_pid: aya::maps::HashMap<aya::maps::MapData, FlowKey, FlowPidRecord>,
    process_info: aya::maps::HashMap<aya::maps::MapData, u32, ProcessInfoRecord>,
    procfs: ProcfsEnricher,
}

#[cfg(target_os = "linux")]
impl AyaAttributionReader {
    pub fn from_ebpf(ebpf: &mut aya::Ebpf) -> anyhow::Result<Self> {
        let flow_to_pid = ebpf.take_map("flow_to_pid").ok_or_else(|| {
            anyhow::anyhow!("flow_to_pid map is missing from netprobe eBPF object")
        })?;
        let process_info = ebpf.take_map("process_info").ok_or_else(|| {
            anyhow::anyhow!("process_info map is missing from netprobe eBPF object")
        })?;

        Ok(Self {
            flow_to_pid: aya::maps::HashMap::try_from(flow_to_pid)?,
            process_info: aya::maps::HashMap::try_from(process_info)?,
            procfs: ProcfsEnricher::host(),
        })
    }

    pub fn snapshot(&self) -> Vec<AttributedFlow> {
        self.flow_to_pid
            .iter()
            .filter_map(Result::ok)
            .map(|(flow, pid)| {
                let process = self
                    .process_info
                    .get(&pid.tgid, 0)
                    .ok()
                    .map(|record| self.procfs.process_details(&record));
                AttributedFlow { flow, pid, process }
            })
            .collect()
    }

    fn process_snapshot(&self) -> ProcessSnapshot {
        self.procfs
            .process_snapshot(&self.process_info_records(), now_unix_nano())
    }

    fn process_info_records(&self) -> HashMap<u32, ProcessInfoRecord> {
        self.process_info.iter().filter_map(Result::ok).collect()
    }
}

#[cfg(target_os = "linux")]
#[allow(dead_code)]
pub struct FlowAttributionRuntime {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

#[cfg(target_os = "linux")]
#[allow(dead_code)]
impl FlowAttributionRuntime {
    pub fn start(
        reader: AyaAttributionReader,
        tx: tokio::sync::broadcast::Sender<FlowAttributionEvent>,
        process_snapshot_tx: tokio::sync::broadcast::Sender<ProcessSnapshot>,
        metrics: Metrics,
        process_snapshot_interval: Option<Duration>,
    ) -> std::io::Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let stop_worker = Arc::clone(&stop);
        let thread = thread::Builder::new()
            .name("netprobe-flow-attribution-map-reader".to_owned())
            .spawn(move || {
                let mut seen = HashSet::new();
                let mut last_process_snapshot =
                    process_snapshot_interval.map(|interval| Instant::now() - interval);
                while !stop_worker.load(Ordering::Relaxed) {
                    emit_snapshot(&reader, &tx, &metrics, &mut seen);
                    if let Some(interval) = process_snapshot_interval {
                        let last = last_process_snapshot.get_or_insert_with(Instant::now);
                        if last.elapsed() >= interval {
                            emit_process_snapshot(&reader, &process_snapshot_tx, &metrics);
                            *last = Instant::now();
                        }
                    }
                    thread::sleep(FLOW_ATTRIBUTION_POLL_INTERVAL);
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
fn emit_snapshot(
    reader: &AyaAttributionReader,
    tx: &tokio::sync::broadcast::Sender<FlowAttributionEvent>,
    metrics: &Metrics,
    seen: &mut HashSet<FlowAttributionJoinKey>,
) {
    for flow in reader.snapshot() {
        let key = FlowAttributionJoinKey::from(&flow);
        if !seen.insert(key) {
            continue;
        }
        let Some(event) = flow.event() else {
            continue;
        };
        metrics.inc_flow_attribution_events();
        if tx.send(event).is_err() {
            metrics.inc_flow_attribution_events_dropped("no_receiver", 1);
        }
    }
}

#[cfg(target_os = "linux")]
fn emit_process_snapshot(
    reader: &AyaAttributionReader,
    tx: &tokio::sync::broadcast::Sender<ProcessSnapshot>,
    metrics: &Metrics,
) {
    let snapshot = reader.process_snapshot();
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
}

#[cfg(target_os = "linux")]
impl From<&AttributedFlow> for FlowAttributionJoinKey {
    fn from(value: &AttributedFlow) -> Self {
        Self {
            flow: value.flow,
            pid: value.pid.pid,
            tgid: value.pid.tgid,
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
        redacted_cmdline: process
            .map(|details| details.cmdline.clone())
            .unwrap_or_default(),
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
        IPPROTO_TCP => "tcp".to_owned(),
        IPPROTO_UDP => "udp".to_owned(),
        _ => value.to_string(),
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
        comm_from_bytes, container_id, flow_attribution_event, redacted_cmdline, AttributedFlow,
        FlowPidRecord, ProcessDetails, ProcessInfoRecord, ProcfsEnricher, AF_INET, FLOW_ENDPOINT_B,
        IPPROTO_TCP,
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
            comm,
        };

        let details = ProcfsEnricher::with_root(root.path()).process_details(&record);

        assert_eq!(details.comm, "app");
        assert_eq!(details.cmdline, vec!["/bin/app", "[redacted 2 arg(s)]"]);
        assert_eq!(details.uid, 1000);
        assert_eq!(details.last_seen_ns, 42);
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
            }),
        };

        let event = flow_attribution_event(&flow, 123_456).unwrap();

        assert_eq!(event.local_ip, "198.51.100.20");
        assert_eq!(event.local_port, 51_000);
        assert_eq!(event.remote_ip, "192.0.2.10");
        assert_eq!(event.remote_port, 443);
        assert_eq!(event.transport_protocol, "tcp");
        assert_eq!(event.comm, "curl");
        assert_eq!(event.redacted_cmdline.len(), 2);
        assert_eq!(event.observed_at_unix_nano, 123_456);
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
