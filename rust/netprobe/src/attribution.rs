use std::{
    fs,
    path::{Path, PathBuf},
};

use crate::af_xdp_classifier::FlowKey;

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

#[cfg(test)]
mod tests {
    use std::fs;

    use super::{
        comm_from_bytes, container_id, redacted_cmdline, ProcessInfoRecord, ProcfsEnricher,
    };

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

    fn temp_proc(pid: &str, cmdline: &[u8], cgroup: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let pid_dir = dir.path().join(pid);
        fs::create_dir_all(&pid_dir).unwrap();
        fs::write(pid_dir.join("cmdline"), cmdline).unwrap();
        fs::write(pid_dir.join("cgroup"), cgroup).unwrap();
        dir
    }
}
