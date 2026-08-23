//! Passive L2 device census.
//!
//! Decodes `L2ObservationRecord` entries produced by the `observe_l2_device`
//! eBPF path (see `rust/netprobe/ebpf/src/lib.rs`) into device observations:
//! the `(MAC, IP)` binding seen on the wire, plus enough context for the
//! ingestion side to decide how much to trust it.
//!
//! The census is passive. Nothing here transmits a packet: the sender MAC is
//! read from the Ethernet header of frames the host already receives. That is
//! what makes a device present for seconds visible at all -- no scan schedule
//! can catch a host that joins and leaves between sweeps.

use std::collections::HashMap;
use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::{Duration, Instant};

/// Wire size of the eBPF `L2ObservationRecord` (`#[repr(C)]`).
pub const L2_OBSERVATION_RECORD_LEN: usize = 48;

/// Wire version understood by this decoder.
pub const L2_OBSERVATION_VERSION: u16 = 1;

pub const L2_KIND_ARP_REQUEST: u16 = 1;
pub const L2_KIND_ARP_REPLY: u16 = 2;
pub const L2_KIND_IPV6_NDP: u16 = 4;

pub const L2_FLAG_LOCALLY_ADMINISTERED: u16 = 1 << 0;
pub const L2_FLAG_ARP_PROBE: u16 = 1 << 1;
pub const L2_FLAG_ARP_GRATUITOUS: u16 = 1 << 2;

use crate::proto::netprobe::{
    DeviceCensusKind as WireKind, DeviceCensusObservation, DeviceCensusSnapshot,
};
use prost::Message as _;

/// How the binding was observed. Kept distinct from the transport because the
/// evidence quality differs: an ARP reply names its own address, while an
/// arbitrary IPv4 frame merely carries a source address that could be spoofed.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum ObservationKind {
    ArpRequest,
    ArpReply,
    /// IPv6 Neighbor/Router Discovery. Link-local by definition, which is why
    /// it is a census signal and ordinary routed IPv6 is not.
    Ipv6Ndp,
}

impl ObservationKind {
    fn from_wire(value: u16) -> Option<Self> {
        match value {
            L2_KIND_ARP_REQUEST => Some(Self::ArpRequest),
            L2_KIND_ARP_REPLY => Some(Self::ArpReply),
            L2_KIND_IPV6_NDP => Some(Self::Ipv6Ndp),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::ArpRequest => "arp_request",
            Self::ArpReply => "arp_reply",
            Self::Ipv6Ndp => "ipv6_ndp",
        }
    }
}

/// A MAC address observed on the segment.
#[derive(Clone, Copy, Eq, PartialEq, Hash)]
pub struct MacAddress([u8; 6]);

impl MacAddress {
    pub const fn new(octets: [u8; 6]) -> Self {
        Self(octets)
    }

    pub const fn octets(&self) -> [u8; 6] {
        self.0
    }

    /// A locally administered address sets bit 1 of the first octet, so the
    /// first octet ends in 2, 6, A or E.
    ///
    /// This is the single most important classification the census makes.
    /// iOS and Android rotate their MAC per SSID, so a randomized address is
    /// not hardware identity -- treating it as such mints a phantom device on
    /// every rotation. Detection is a bit test, not a heuristic.
    pub const fn is_locally_administered(&self) -> bool {
        self.0[0] & 0x02 != 0
    }

    /// Group bit set: broadcast or multicast. Never a device's own address.
    pub const fn is_group(&self) -> bool {
        self.0[0] & 0x01 != 0
    }
}

impl fmt::Display for MacAddress {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
            self.0[0], self.0[1], self.0[2], self.0[3], self.0[4], self.0[5]
        )
    }
}

impl fmt::Debug for MacAddress {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self}")
    }
}

/// One passive sighting of a device on the segment.
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct DeviceObservation {
    pub kind: ObservationKind,
    pub mac: MacAddress,
    /// Absent for an RFC 5227 ARP probe: the device is announcing before it
    /// owns an address, so there is a MAC to record but no binding yet.
    pub ip: Option<IpAddr>,
    pub interface_index: u32,
    pub observed_ns: u64,
    /// The MAC is locally administered, i.e. very likely randomized.
    pub randomized_mac: bool,
    /// RFC 5227 probe -- the earliest possible sighting of a joining device.
    pub arp_probe: bool,
    /// Gratuitous ARP: sender and target protocol addresses matched.
    pub gratuitous: bool,
}

impl DeviceObservation {
    /// Whether this observation may be used to anchor a canonical device.
    ///
    /// A randomized MAC must never anchor identity, and a probe carries no
    /// address binding at all. Both are still recorded as presence.
    ///
    /// `scope` rejects off-segment bindings. Traffic routed from another subnet
    /// arrives with the *router's* source MAC, so binding it would attribute
    /// every remote host to the gateway. Observed live on a test segment: one
    /// MAC appeared bound to three 192.168.2.x addresses while the interface
    /// sat on 192.168.1.0/24.
    pub fn can_anchor_identity(&self, scope: &SegmentScope) -> bool {
        if self.randomized_mac || self.arp_probe {
            return false;
        }
        match self.ip {
            Some(ip) => scope.contains(ip),
            None => false,
        }
    }

    /// True when the address is not on the observer's segment, i.e. the MAC is
    /// almost certainly a router forwarding for someone else.
    pub fn is_off_segment(&self, scope: &SegmentScope) -> bool {
        match self.ip {
            Some(ip) => !scope.contains(ip),
            None => false,
        }
    }
}

/// The address space directly reachable on the observing interface.
///
/// Only a device on the same broadcast domain sends frames with its own MAC.
/// Anything else was forwarded, and the MAC on the wire belongs to the
/// forwarder. Built from the interface's own addresses and prefix lengths.
#[derive(Debug, Clone, Default)]
pub struct SegmentScope {
    prefixes: Vec<(IpAddr, u8)>,
}

impl SegmentScope {
    pub fn new(prefixes: Vec<(IpAddr, u8)>) -> Self {
        Self { prefixes }
    }

    pub fn is_empty(&self) -> bool {
        self.prefixes.is_empty()
    }

    /// Whether `ip` falls inside any prefix on the observing interface.
    ///
    /// An empty scope answers `false`: without knowing the segment we cannot
    /// claim a binding is on it, and the safe default is to record presence
    /// without anchoring identity.
    pub fn contains(&self, ip: IpAddr) -> bool {
        // Link-local IPv6 is on this link by definition, whatever prefixes the
        // interface happens to carry -- and NDP, the v6 counterpart to ARP, is
        // overwhelmingly link-local. Checked before the prefix list so a host
        // with no global IPv6 prefix still counts its neighbours as on-segment.
        if is_ipv6_link_local(ip) {
            return true;
        }
        self.prefixes
            .iter()
            .any(|(network, bits)| prefix_contains(*network, *bits, ip))
    }
}

/// fe80::/10 -- an address only meaningful on the local link.
fn is_ipv6_link_local(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V6(addr) => {
            let o = addr.octets();
            o[0] == 0xfe && (o[1] & 0xc0) == 0x80
        }
        IpAddr::V4(_) => false,
    }
}

fn prefix_contains(network: IpAddr, bits: u8, ip: IpAddr) -> bool {
    match (network, ip) {
        (IpAddr::V4(net), IpAddr::V4(addr)) => {
            masked_eq(&net.octets(), &addr.octets(), bits.min(32))
        }
        (IpAddr::V6(net), IpAddr::V6(addr)) => {
            masked_eq(&net.octets(), &addr.octets(), bits.min(128))
        }
        _ => false,
    }
}

fn masked_eq(a: &[u8], b: &[u8], bits: u8) -> bool {
    let full = (bits / 8) as usize;
    if a[..full] != b[..full] {
        return false;
    }
    let rem = bits % 8;
    if rem == 0 {
        return true;
    }
    let mask = 0xffu8 << (8 - rem);
    a[full] & mask == b[full] & mask
}

/// Decode an `L2ObservationRecord` from raw ring bytes.
///
/// Field offsets mirror the explicit-padding layout in
/// `rust/netprobe/ebpf/src/lib.rs`; keep them in sync.
pub fn parse_l2_ring_record(bytes: &[u8]) -> Option<DeviceObservation> {
    if bytes.len() < L2_OBSERVATION_RECORD_LEN {
        return None;
    }

    let version = u16::from_ne_bytes(bytes.get(0..2)?.try_into().ok()?);
    if version != L2_OBSERVATION_VERSION {
        return None;
    }

    let kind = ObservationKind::from_wire(u16::from_ne_bytes(bytes.get(2..4)?.try_into().ok()?))?;
    let ip_version = u16::from_ne_bytes(bytes.get(4..6)?.try_into().ok()?);
    let flags = u16::from_ne_bytes(bytes.get(6..8)?.try_into().ok()?);
    let interface_index = u32::from_ne_bytes(bytes.get(8..12)?.try_into().ok()?);
    // bytes[12..16] = padding before the u64
    let observed_ns = u64::from_ne_bytes(bytes.get(16..24)?.try_into().ok()?);
    let mac_octets: [u8; 6] = bytes.get(24..30)?.try_into().ok()?;
    // bytes[30..32] = reserved0 pad
    let addr: [u8; 16] = bytes.get(32..48)?.try_into().ok()?;

    let mac = MacAddress::new(mac_octets);
    if mac.is_group() {
        // A group address is never a device identity. The eBPF side filters
        // these already; rejecting here too keeps the decoder honest against a
        // stale or mismatched producer.
        return None;
    }

    let ip = match ip_version {
        4 => Some(IpAddr::V4(Ipv4Addr::new(
            addr[0], addr[1], addr[2], addr[3],
        ))),
        6 => Some(IpAddr::V6(Ipv6Addr::from(addr))),
        _ => None,
    };

    Some(DeviceObservation {
        kind,
        mac,
        ip,
        interface_index,
        observed_ns,
        // Derived from the address as well as the producer's flag, deliberately.
        // This classification decides whether the MAC may anchor a canonical
        // device, so it must not depend on a producer remembering to set a bit:
        // a stale or mismatched eBPF object that omits the flag would otherwise
        // let a rotating MAC anchor identity. The two agree in practice; the OR
        // is what makes disagreement safe rather than silent.
        randomized_mac: flags & L2_FLAG_LOCALLY_ADMINISTERED != 0 || mac.is_locally_administered(),
        arp_probe: flags & L2_FLAG_ARP_PROBE != 0,
        gratuitous: flags & L2_FLAG_ARP_GRATUITOUS != 0,
    })
}

/// Detects that in-kernel suppression has stopped working, so the census can
/// shut itself down instead of degrading into a resource hog.
///
/// Suppression lives in the eBPF program on purpose: it keeps discarded frames
/// off the ring entirely, which is the whole point of netprobe's zero-copy
/// design. There is deliberately no userspace suppressor to fall back on -- a
/// fallback would mask exactly the failure we need to be loud about.
///
/// This exists because the in-kernel path once failed SILENTLY. The map held
/// well-formed entries with correct timestamps while every single frame was
/// still emitted; the only outward symptom was journald quietly discarding
/// ~1.15 million messages per 30 s, and the process burning ~40% of a core.
///
/// With suppression working, the rate is bounded by
/// `bindings / refresh_window`. Exceeding the ceiling below would require tens
/// of thousands of distinct bindings on one segment, so it does not happen on a
/// healthy system -- it means suppression is not suppressing.
#[derive(Debug)]
pub struct CensusWatchdog {
    ceiling_per_sec: u64,
    interval: Duration,
    window_started: Instant,
    observations: u64,
}

/// Sustained rate above which in-kernel suppression is considered broken.
///
/// A healthy segment measured 0.37 observations/sec. Reaching 200/sec with
/// working suppression would need ~12,000 distinct bindings on one broadcast
/// domain. The broken path produced ~38,000/sec.
pub const CENSUS_RATE_CEILING_PER_SEC: u64 = 200;

/// How long a breach must be sustained before shutting down, so a burst from a
/// legitimately busy moment does not trip it.
pub const CENSUS_WATCHDOG_INTERVAL: Duration = Duration::from_secs(10);

impl CensusWatchdog {
    pub fn new(ceiling_per_sec: u64, interval: Duration, now: Instant) -> Self {
        Self {
            ceiling_per_sec,
            interval,
            window_started: now,
            observations: 0,
        }
    }

    /// Record one observation. Returns false when the census must stop.
    #[must_use]
    pub fn record(&mut self, now: Instant) -> bool {
        self.observations = self.observations.saturating_add(1);
        let elapsed = now.duration_since(self.window_started);
        if elapsed < self.interval {
            return true;
        }
        let seconds = elapsed.as_secs().max(1);
        let rate = self.observations / seconds;
        self.window_started = now;
        self.observations = 0;
        rate <= self.ceiling_per_sec
    }
}

/// Converts an eBPF observation timestamp to wall-clock nanoseconds.
///
/// `bpf_ktime_get_ns()` returns **CLOCK_MONOTONIC**, not an epoch timestamp:
/// it counts from an arbitrary origin and pauses across suspend. Sending it to
/// core unconverted would stamp every observation somewhere in 1970.
///
/// Kept as a pure function of both clock readings so it unit-tests without
/// syscalls, and so the caller decides how often to resample. Resampling per
/// snapshot keeps suspend drift bounded to one interval rather than
/// accumulating for the process lifetime.
pub fn wall_nanos_from_monotonic(observed_ns: u64, monotonic_now_ns: u64, wall_now_ns: i64) -> i64 {
    // How long ago the observation happened, on the monotonic clock.
    let age_ns = monotonic_now_ns.saturating_sub(observed_ns);
    // `as i64` would WRAP here: u64::MAX as i64 is -1, which turns an absurd age
    // into a timestamp slightly in the FUTURE. Clamp instead, so a corrupt or
    // uninitialised reading degrades to "very old" rather than "just now".
    let age_ns = i64::try_from(age_ns).unwrap_or(i64::MAX);
    // saturating so a clock that jumped backwards cannot produce a negative
    // instant; the worst case is an observation stamped "now".
    wall_now_ns.saturating_sub(age_ns)
}

/// One device the census currently believes is present on a segment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CensusEntry {
    pub mac: MacAddress,
    pub ip: Option<IpAddr>,
    pub interface_index: u32,
    pub kind: ObservationKind,
    pub first_seen_ns: u64,
    pub last_seen_ns: u64,
    pub randomized_mac: bool,
    pub off_segment: bool,
}

/// Current-state view of the segment, emitted as a COMPLETE snapshot.
///
/// This is not an optimisation. `DeviceSourceObservationIngestor` writes nothing
/// unless the payload declares `snapshot_complete`, so a per-observation stream
/// would land no rows at all. Holding state here also gives `present: false` a
/// real meaning -- "this binding aged out" rather than "it happened to be quiet
/// during one tick".
#[derive(Debug)]
pub struct CensusTable {
    ttl: Duration,
    capacity: usize,
    entries: HashMap<(u32, [u8; 6], [u8; 16]), CensusEntry>,
}

impl CensusTable {
    pub fn new(ttl: Duration, capacity: usize) -> Self {
        Self {
            ttl,
            capacity,
            entries: HashMap::new(),
        }
    }

    fn key(observation: &DeviceObservation) -> (u32, [u8; 6], [u8; 16]) {
        let ip = match observation.ip {
            Some(IpAddr::V4(v4)) => {
                let mut o = [0u8; 16];
                o[..4].copy_from_slice(&v4.octets());
                o
            }
            Some(IpAddr::V6(v6)) => v6.octets(),
            None => [0u8; 16],
        };
        (observation.interface_index, observation.mac.octets(), ip)
    }

    /// Record a sighting. Returns true when this binding was not already known.
    pub fn observe(&mut self, observation: &DeviceObservation, scope: &SegmentScope) -> bool {
        let key = Self::key(observation);
        let off_segment = observation.is_off_segment(scope);

        if let Some(entry) = self.entries.get_mut(&key) {
            entry.last_seen_ns = observation.observed_ns;
            entry.kind = observation.kind;
            entry.off_segment = off_segment;
            return false;
        }

        if self.entries.len() >= self.capacity {
            // Evict the coldest binding rather than grow without bound on a
            // segment larger than we budgeted for.
            if let Some(coldest) = self
                .entries
                .iter()
                .min_by_key(|(_, e)| e.last_seen_ns)
                .map(|(k, _)| *k)
            {
                self.entries.remove(&coldest);
            }
        }

        self.entries.insert(
            key,
            CensusEntry {
                mac: observation.mac,
                ip: observation.ip,
                interface_index: observation.interface_index,
                kind: observation.kind,
                first_seen_ns: observation.observed_ns,
                last_seen_ns: observation.observed_ns,
                randomized_mac: observation.randomized_mac,
                off_segment,
            },
        );
        true
    }

    /// Drop bindings not seen within the TTL. Returns how many were evicted.
    pub fn evict_expired(&mut self, monotonic_now_ns: u64) -> usize {
        let ttl_ns = self.ttl.as_nanos() as u64;
        let before = self.entries.len();
        self.entries
            .retain(|_, e| monotonic_now_ns.saturating_sub(e.last_seen_ns) < ttl_ns);
        before - self.entries.len()
    }

    /// The complete current view, ordered so a snapshot is deterministic.
    pub fn snapshot(&self) -> Vec<CensusEntry> {
        let mut out: Vec<CensusEntry> = self.entries.values().cloned().collect();
        out.sort_by_key(|e| (e.interface_index, e.mac.octets(), e.first_seen_ns));
        out
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// Map an observation kind onto the wire enum.
///
/// Deliberately exhaustive rather than a numeric cast: the proto enum and the
/// internal enum are separate contracts, and a cast would silently mistranslate
/// if either gained a variant.
fn wire_kind(kind: ObservationKind) -> WireKind {
    match kind {
        ObservationKind::ArpRequest => WireKind::ArpRequest,
        ObservationKind::ArpReply => WireKind::ArpReply,
        ObservationKind::Ipv6Ndp => WireKind::Ipv6Ndp,
    }
}

/// Build the wire snapshot from the table's current view.
///
/// Timestamps cross a clock boundary here: the table stores CLOCK_MONOTONIC
/// nanoseconds (what `bpf_ktime_get_ns` returns), while the wire carries wall
/// clock. `wall_nanos_from_monotonic` does the conversion, which is why both
/// "now" values are parameters -- one sample of each is taken for the whole
/// snapshot so entries stay consistent with one another.
pub fn build_snapshot(
    entries: &[CensusEntry],
    interface_name: &str,
    snapshot_id: &str,
    monotonic_now_ns: u64,
    wall_now_ns: i64,
    dropped_since_last: u32,
) -> DeviceCensusSnapshot {
    let observations = entries
        .iter()
        .map(|entry| DeviceCensusObservation {
            mac: entry.mac.to_string(),
            ip: entry.ip.map(|ip| ip.to_string()).unwrap_or_default(),
            interface_index: entry.interface_index,
            kind: wire_kind(entry.kind) as i32,
            first_seen_unix_nano: wall_nanos_from_monotonic(
                entry.first_seen_ns,
                monotonic_now_ns,
                wall_now_ns,
            ),
            last_seen_unix_nano: wall_nanos_from_monotonic(
                entry.last_seen_ns,
                monotonic_now_ns,
                wall_now_ns,
            ),
            randomized_mac: entry.randomized_mac,
            off_segment: entry.off_segment,
        })
        .collect();

    DeviceCensusSnapshot {
        observations,
        snapshot_id: snapshot_id.to_owned(),
        interface_name: interface_name.to_owned(),
        generated_at_unix_nano: wall_now_ns,
        complete: true,
        chunk_index: 0,
        chunk_count: 1,
        dropped_since_last,
    }
}

/// Split a snapshot into frames that fit `max_payload_len`.
///
/// The chunk set is computed UP FRONT rather than emitted as it goes, because
/// `chunk_count` has to be correct on the first chunk -- a receiver that has to
/// wait for `complete` to learn how many chunks it is buffering cannot size
/// anything or detect a truncated set.
///
/// `complete` is set on the LAST chunk only. A receiver applies a snapshot when
/// it has `chunk_count` chunks sharing a `snapshot_id` and has seen the
/// complete flag; anything else is a partial set to discard. That matters
/// because this snapshot is authoritative -- applying half of one would read as
/// "every device in the missing chunks has left the segment".
///
/// An observation too large to fit alone is dropped rather than emitted in an
/// oversized frame that the reader would reject: losing one binding beats
/// losing the snapshot.
///
/// `dropped_since_last` is a property of the SNAPSHOT, so it is replicated
/// verbatim onto every chunk rather than divided among them. A receiver takes
/// it from any one chunk; summing across chunks would multiply it by
/// `chunk_count`.
pub fn chunk_snapshot(
    snapshot: DeviceCensusSnapshot,
    max_payload_len: usize,
) -> (Vec<DeviceCensusSnapshot>, u32) {
    let base_len = snapshot_base_payload_len(&snapshot);
    let DeviceCensusSnapshot {
        observations,
        snapshot_id,
        interface_name,
        generated_at_unix_nano,
        dropped_since_last,
        ..
    } = snapshot;

    let mut groups: Vec<Vec<DeviceCensusObservation>> = Vec::new();
    let mut current: Vec<DeviceCensusObservation> = Vec::new();
    let mut current_len = base_len;
    let mut dropped_oversized = 0u32;

    for observation in observations {
        let wire_len = observation_wire_len(&observation);
        if base_len + wire_len > max_payload_len {
            // Cannot fit even in a chunk of its own.
            dropped_oversized += 1;
            continue;
        }
        if current_len + wire_len > max_payload_len && !current.is_empty() {
            groups.push(std::mem::take(&mut current));
            current_len = base_len;
        }
        current_len += wire_len;
        current.push(observation);
    }
    if !current.is_empty() || groups.is_empty() {
        // An empty snapshot still ships exactly one chunk: "no devices" is a
        // real, meaningful state for a complete snapshot, and swallowing it
        // would leave stale bindings alive downstream forever.
        groups.push(current);
    }

    let chunk_count = groups.len() as u32;
    let last = chunk_count.saturating_sub(1);
    let chunks = groups
        .into_iter()
        .enumerate()
        .map(|(index, observations)| DeviceCensusSnapshot {
            observations,
            snapshot_id: snapshot_id.clone(),
            interface_name: interface_name.clone(),
            generated_at_unix_nano,
            complete: index as u32 == last,
            chunk_index: index as u32,
            chunk_count,
            dropped_since_last,
        })
        .collect();

    (chunks, dropped_oversized)
}

/// Encoded size of everything in a chunk except the observations.
fn snapshot_base_payload_len(snapshot: &DeviceCensusSnapshot) -> usize {
    DeviceCensusSnapshot {
        observations: Vec::new(),
        snapshot_id: snapshot.snapshot_id.clone(),
        interface_name: snapshot.interface_name.clone(),
        generated_at_unix_nano: snapshot.generated_at_unix_nano,
        // Budget the WIDEST encoding of every field the split rewrites, not the
        // values this snapshot happens to hold. proto3 omits zero-valued fields
        // and varint-encodes small ones, so measuring with the pre-split values
        // (chunk_index 0, chunk_count 1, complete on only the last chunk) would
        // under-budget every chunk and let it grow past the limit once the real
        // values are written back.
        complete: true,
        chunk_index: u32::MAX,
        chunk_count: u32::MAX,
        dropped_since_last: snapshot.dropped_since_last.max(1),
    }
    .encoded_len()
}

fn observation_wire_len(observation: &DeviceCensusObservation) -> usize {
    let len = observation.encoded_len();
    // Field 1 of the snapshot, length-delimited: tag + length prefix + body.
    1 + prost::length_delimiter_len(len) + len
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(
        kind: u16,
        ip_version: u16,
        flags: u16,
        mac: [u8; 6],
        addr: [u8; 16],
    ) -> [u8; L2_OBSERVATION_RECORD_LEN] {
        let mut b = [0u8; L2_OBSERVATION_RECORD_LEN];
        b[0..2].copy_from_slice(&L2_OBSERVATION_VERSION.to_ne_bytes());
        b[2..4].copy_from_slice(&kind.to_ne_bytes());
        b[4..6].copy_from_slice(&ip_version.to_ne_bytes());
        b[6..8].copy_from_slice(&flags.to_ne_bytes());
        b[8..12].copy_from_slice(&7u32.to_ne_bytes());
        b[16..24].copy_from_slice(&123_456_789u64.to_ne_bytes());
        b[24..30].copy_from_slice(&mac);
        b[32..48].copy_from_slice(&addr);
        b
    }

    fn local_scope() -> SegmentScope {
        SegmentScope::new(vec![("192.168.1.0".parse::<IpAddr>().unwrap(), 24)])
    }

    fn v4(a: u8, b: u8, c: u8, d: u8) -> [u8; 16] {
        let mut x = [0u8; 16];
        x[0] = a;
        x[1] = b;
        x[2] = c;
        x[3] = d;
        x
    }

    #[test]
    fn decodes_an_arp_reply_into_a_binding() {
        let bytes = record(
            L2_KIND_ARP_REPLY,
            4,
            0,
            [0xbc, 0x24, 0x11, 0xf5, 0x1c, 0x82],
            v4(192, 168, 1, 171),
        );
        let obs = parse_l2_ring_record(&bytes).expect("record should decode");
        assert_eq!(obs.kind, ObservationKind::ArpReply);
        assert_eq!(obs.mac.to_string(), "bc:24:11:f5:1c:82");
        assert_eq!(obs.ip, Some("192.168.1.171".parse::<IpAddr>().unwrap()));
        assert_eq!(obs.interface_index, 7);
        assert!(!obs.randomized_mac);
        assert!(obs.can_anchor_identity(&local_scope()));
    }

    #[test]
    fn decodes_ipv6_source_address() {
        let addr: [u8; 16] = "fe80::bc24:11ff:fef5:1c82"
            .parse::<Ipv6Addr>()
            .unwrap()
            .octets();
        let bytes = record(
            L2_KIND_IPV6_NDP,
            6,
            0,
            [0xbc, 0x24, 0x11, 0xf5, 0x1c, 0x82],
            addr,
        );
        let obs = parse_l2_ring_record(&bytes).expect("record should decode");
        assert_eq!(obs.kind, ObservationKind::Ipv6Ndp);
        assert_eq!(
            obs.ip,
            Some("fe80::bc24:11ff:fef5:1c82".parse::<IpAddr>().unwrap())
        );
    }

    #[test]
    fn a_randomized_mac_is_flagged_and_cannot_anchor_identity() {
        // Locally administered: first octet 0x1A -> bit 1 set.
        let bytes = record(
            L2_KIND_ARP_REPLY,
            4,
            L2_FLAG_LOCALLY_ADMINISTERED,
            [0x1a, 0x2b, 0x3c, 0x4d, 0x5e, 0x6f],
            v4(192, 168, 1, 55),
        );
        let obs = parse_l2_ring_record(&bytes).expect("record should decode");
        assert!(obs.randomized_mac);
        assert!(
            !obs.can_anchor_identity(&local_scope()),
            "a rotating MAC must not anchor a canonical device"
        );
        // Still recorded as presence -- the sighting is real.
        assert_eq!(obs.ip, Some("192.168.1.55".parse::<IpAddr>().unwrap()));
    }

    #[test]
    fn locally_administered_detection_covers_the_whole_boundary() {
        for first in [0x02u8, 0x06, 0x0a, 0x0e, 0x1a, 0xda, 0xfe] {
            let mac = MacAddress::new([first, 0, 0, 0, 0, 1]);
            assert!(
                mac.is_locally_administered(),
                "{mac} should be locally administered"
            );
        }
        // Real vendor OUIs: Proxmox/Realtek, Apple, Cisco, Intel.
        for first in [0xbcu8, 0x00, 0x3c, 0x8c] {
            let mac = MacAddress::new([first, 0x24, 0x11, 0, 0, 1]);
            assert!(
                !mac.is_locally_administered(),
                "{mac} is a burned-in address and must keep full identity weight"
            );
        }
    }

    #[test]
    fn an_arp_probe_records_presence_without_binding_an_address() {
        let bytes = record(
            L2_KIND_ARP_REQUEST,
            0,
            L2_FLAG_ARP_PROBE,
            [0xbc, 0x24, 0x11, 0x00, 0x00, 0x01],
            [0u8; 16],
        );
        let obs = parse_l2_ring_record(&bytes).expect("record should decode");
        assert!(obs.arp_probe);
        assert_eq!(obs.ip, None, "a probe claims no address yet");
        assert!(!obs.can_anchor_identity(&local_scope()));
    }

    #[test]
    fn gratuitous_arp_is_flagged() {
        let bytes = record(
            L2_KIND_ARP_REPLY,
            4,
            L2_FLAG_ARP_GRATUITOUS,
            [0xbc, 0x24, 0x11, 0x00, 0x00, 0x02],
            v4(10, 0, 0, 5),
        );
        let obs = parse_l2_ring_record(&bytes).expect("record should decode");
        assert!(obs.gratuitous);
    }

    #[test]
    fn rejects_a_group_source_address() {
        // Broadcast source: never a device identity.
        let bytes = record(
            L2_KIND_ARP_REPLY,
            4,
            0,
            [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            v4(192, 168, 1, 1),
        );
        assert!(parse_l2_ring_record(&bytes).is_none());
    }

    #[test]
    fn rejects_short_truncated_and_unknown_versions() {
        assert!(parse_l2_ring_record(&[]).is_none());
        assert!(parse_l2_ring_record(&[0u8; 20]).is_none());

        let mut bytes = record(
            L2_KIND_ARP_REPLY,
            4,
            0,
            [0xbc, 0, 0, 0, 0, 1],
            v4(1, 2, 3, 4),
        );
        bytes[0..2].copy_from_slice(&99u16.to_ne_bytes());
        assert!(
            parse_l2_ring_record(&bytes).is_none(),
            "an unknown wire version must be rejected, not misparsed"
        );

        let mut bytes = record(
            L2_KIND_ARP_REPLY,
            4,
            0,
            [0xbc, 0, 0, 0, 0, 1],
            v4(1, 2, 3, 4),
        );
        bytes[2..4].copy_from_slice(&77u16.to_ne_bytes());
        assert!(parse_l2_ring_record(&bytes).is_none());
    }

    #[test]
    fn an_off_segment_address_does_not_bind_to_the_forwarding_mac() {
        // Observed live: one MAC carrying three 192.168.2.x addresses while the
        // observer sat on 192.168.1.0/24. That MAC is the router's, and binding
        // it would attribute every remote host to the gateway.
        let bytes = record(
            L2_KIND_ARP_REPLY,
            4,
            0,
            [0xf4, 0x92, 0xbf, 0x75, 0xc7, 0x2b],
            v4(192, 168, 2, 44),
        );
        let obs = parse_l2_ring_record(&bytes).expect("record should decode");
        let scope = local_scope();
        assert!(obs.is_off_segment(&scope));
        assert!(
            !obs.can_anchor_identity(&scope),
            "a forwarded address must not bind to the router's MAC"
        );
    }

    #[test]
    fn an_on_segment_address_binds_normally() {
        let bytes = record(
            L2_KIND_ARP_REPLY,
            4,
            0,
            [0xd0, 0x21, 0xf9, 0xdc, 0x2e, 0x8c],
            v4(192, 168, 1, 131),
        );
        let obs = parse_l2_ring_record(&bytes).expect("record should decode");
        assert!(!obs.is_off_segment(&local_scope()));
        assert!(obs.can_anchor_identity(&local_scope()));
    }

    #[test]
    fn ipv6_link_local_is_always_on_segment() {
        // Link-local is by definition on this link, and NDP is overwhelmingly
        // link-local, so it must not be rejected for lacking a global prefix.
        let addr: [u8; 16] = "fe80::bc24:11ff:fef5:1c82"
            .parse::<Ipv6Addr>()
            .unwrap()
            .octets();
        let bytes = record(L2_KIND_IPV6_NDP, 6, 0, [0xbc, 0x24, 0x11, 0, 0, 1], addr);
        let obs = parse_l2_ring_record(&bytes).expect("record should decode");
        assert!(!obs.is_off_segment(&local_scope()));
    }

    #[test]
    fn an_empty_scope_never_anchors() {
        let bytes = record(
            L2_KIND_ARP_REPLY,
            4,
            0,
            [0xbc, 0x24, 0x11, 0, 0, 1],
            v4(10, 0, 0, 9),
        );
        let obs = parse_l2_ring_record(&bytes).expect("record should decode");
        assert!(
            !obs.can_anchor_identity(&SegmentScope::default()),
            "without knowing the segment we cannot claim a binding is on it"
        );
    }

    #[test]
    fn prefix_matching_handles_non_byte_aligned_masks() {
        let scope = SegmentScope::new(vec![("10.10.8.0".parse::<IpAddr>().unwrap(), 21)]);
        assert!(scope.contains("10.10.8.1".parse().unwrap()));
        assert!(scope.contains("10.10.15.254".parse().unwrap()));
        assert!(!scope.contains("10.10.16.1".parse().unwrap()));
    }

    #[test]
    fn the_watchdog_tolerates_a_healthy_rate() {
        // Measured healthy rate on a live segment was 0.37 observations/sec.
        let start = Instant::now();
        let mut w =
            CensusWatchdog::new(CENSUS_RATE_CEILING_PER_SEC, Duration::from_secs(10), start);
        for i in 0..60u64 {
            assert!(
                w.record(start + Duration::from_secs(i)),
                "a healthy rate must not trip the watchdog"
            );
        }
    }

    #[test]
    fn the_watchdog_trips_when_suppression_stops_suppressing() {
        // The real failure: ~38,000 observations/sec because every frame was
        // emitted. The census must shut down rather than degrade.
        let start = Instant::now();
        let mut w =
            CensusWatchdog::new(CENSUS_RATE_CEILING_PER_SEC, Duration::from_secs(10), start);
        let mut tripped = false;
        // 40,000/sec for slightly over the 10s interval, so the boundary where
        // the watchdog evaluates is actually crossed.
        for i in 0..440_000u64 {
            let now = start + Duration::from_micros(i * 25);
            if !w.record(now) {
                tripped = true;
                break;
            }
        }
        assert!(tripped, "a flood must trip the watchdog");
    }

    #[test]
    fn the_watchdog_does_not_trip_on_a_short_burst() {
        // A busy moment inside one interval must not kill the census; the
        // breach has to be sustained across the whole interval.
        let start = Instant::now();
        let mut w =
            CensusWatchdog::new(CENSUS_RATE_CEILING_PER_SEC, Duration::from_secs(10), start);
        for i in 0..500u64 {
            assert!(w.record(start + Duration::from_millis(i)));
        }
        // Then go quiet for the rest of the interval: 500 observations over
        // 10s is 50/sec, under the ceiling.
        assert!(w.record(start + Duration::from_secs(10)));
    }

    #[test]
    fn the_watchdog_evaluates_each_interval_independently() {
        let start = Instant::now();
        let mut w = CensusWatchdog::new(10, Duration::from_secs(10), start);
        // First interval healthy.
        assert!(w.record(start + Duration::from_secs(10)));
        // Second interval floods, running past the next boundary.
        let mut tripped = false;
        let base = start + Duration::from_secs(10);
        for i in 0..6_000u64 {
            if !w.record(base + Duration::from_millis(i * 2)) {
                tripped = true;
                break;
            }
        }
        assert!(tripped, "a later interval must still be able to trip it");
    }

    fn scope24() -> SegmentScope {
        SegmentScope::new(vec![("192.168.1.0".parse::<IpAddr>().unwrap(), 24)])
    }

    fn observation(mac: [u8; 6], ip: &str, observed_ns: u64) -> DeviceObservation {
        let v: std::net::Ipv4Addr = ip.parse().unwrap();
        let mut a = [0u8; 16];
        a[..4].copy_from_slice(&v.octets());
        let bytes = record(L2_KIND_ARP_REPLY, 4, 0, mac, a);
        let mut o = parse_l2_ring_record(&bytes).expect("decodes");
        o.observed_ns = observed_ns;
        o
    }

    const SEC: u64 = 1_000_000_000;

    fn entry(mac: [u8; 6], ip: Option<&str>, kind: ObservationKind) -> CensusEntry {
        CensusEntry {
            mac: MacAddress::new(mac),
            ip: ip.map(|v| v.parse().unwrap()),
            interface_index: 2,
            kind,
            first_seen_ns: 10 * SEC,
            last_seen_ns: 20 * SEC,
            randomized_mac: false,
            off_segment: false,
        }
    }

    #[test]
    fn snapshot_maps_every_kind_onto_a_distinct_wire_value() {
        // A numeric cast between the two enums would compile and silently
        // mistranslate the moment either side gains a variant. Pin the mapping.
        let kinds = [
            (ObservationKind::ArpRequest, WireKind::ArpRequest),
            (ObservationKind::ArpReply, WireKind::ArpReply),
            (ObservationKind::Ipv6Ndp, WireKind::Ipv6Ndp),
        ];
        for (internal, wire) in kinds {
            assert_eq!(
                wire_kind(internal),
                wire,
                "{internal:?} maps to the wrong wire kind"
            );
            assert_ne!(
                wire as i32,
                WireKind::Unspecified as i32,
                "{internal:?} must never serialise as UNSPECIFIED"
            );
        }
    }

    #[test]
    fn snapshot_converts_monotonic_entry_times_to_wall_clock() {
        // The table stores CLOCK_MONOTONIC; the wire carries wall clock. Ship
        // the raw value and every device appears to have been seen in 1970.
        let wall_now = 1_700_000_000 * SEC as i64;
        let snapshot = build_snapshot(
            &[entry(
                [2, 0, 0, 0, 0, 1],
                Some("192.168.1.10"),
                ObservationKind::ArpReply,
            )],
            "eth0",
            "eth0-1",
            30 * SEC,
            wall_now,
            0,
        );
        let observation = &snapshot.observations[0];
        // first seen 20s before "now", last seen 10s before.
        assert_eq!(observation.first_seen_unix_nano, wall_now - 20 * SEC as i64);
        assert_eq!(observation.last_seen_unix_nano, wall_now - 10 * SEC as i64);
        assert_eq!(snapshot.generated_at_unix_nano, wall_now);
    }

    #[test]
    fn snapshot_leaves_ip_empty_for_a_binding_without_one() {
        // An RFC 5227 probe has a MAC but no address yet. proto3 has no null,
        // so "" is the absence marker -- it must not become "None" or "0.0.0.0".
        let snapshot = build_snapshot(
            &[entry([2, 0, 0, 0, 0, 1], None, ObservationKind::ArpRequest)],
            "eth0",
            "eth0-1",
            30 * SEC,
            1_700_000_000 * SEC as i64,
            0,
        );
        assert_eq!(snapshot.observations[0].ip, "");
    }

    #[test]
    fn a_snapshot_that_fits_is_one_complete_chunk() {
        let snapshot = build_snapshot(
            &[entry(
                [2, 0, 0, 0, 0, 1],
                Some("192.168.1.10"),
                ObservationKind::ArpReply,
            )],
            "eth0",
            "eth0-1",
            30 * SEC,
            1_700_000_000 * SEC as i64,
            0,
        );
        let (chunks, dropped) = chunk_snapshot(snapshot, 4 * 1024 * 1024);
        assert_eq!(dropped, 0);
        assert_eq!(chunks.len(), 1);
        assert!(chunks[0].complete);
        assert_eq!(chunks[0].chunk_index, 0);
        assert_eq!(chunks[0].chunk_count, 1);
    }

    #[test]
    fn an_empty_snapshot_still_ships_one_complete_chunk() {
        // "No devices" is a real state for a COMPLETE snapshot. Swallowing it
        // would leave every previously reported binding alive downstream
        // forever, because absence is what retires a device.
        let snapshot = build_snapshot(
            &[],
            "eth0",
            "eth0-7",
            30 * SEC,
            1_700_000_000 * SEC as i64,
            0,
        );
        let (chunks, _) = chunk_snapshot(snapshot, 4 * 1024 * 1024);
        assert_eq!(chunks.len(), 1);
        assert!(chunks[0].observations.is_empty());
        assert!(chunks[0].complete);
        assert_eq!(chunks[0].chunk_count, 1);
    }

    fn many_entries(count: usize) -> Vec<CensusEntry> {
        (0..count)
            .map(|i| {
                let mac = [2, 0, 0, (i >> 16) as u8, (i >> 8) as u8, i as u8];
                let ip = format!("10.{}.{}.{}", (i >> 16) & 0xff, (i >> 8) & 0xff, i & 0xff);
                entry(mac, Some(&ip), ObservationKind::ArpReply)
            })
            .collect()
    }

    #[test]
    fn a_split_snapshot_keeps_every_observation_and_numbers_its_chunks() {
        let entries = many_entries(500);
        let snapshot = build_snapshot(
            &entries,
            "eth0",
            "eth0-3",
            30 * SEC,
            1_700_000_000 * SEC as i64,
            0,
        );
        // Small enough to force many chunks.
        let (chunks, dropped) = chunk_snapshot(snapshot, 512);
        assert_eq!(dropped, 0);
        assert!(
            chunks.len() > 1,
            "expected a split, got {} chunk(s)",
            chunks.len()
        );

        let total: usize = chunks.iter().map(|c| c.observations.len()).sum();
        assert_eq!(total, entries.len(), "the split lost observations");

        let count = chunks.len() as u32;
        for (index, chunk) in chunks.iter().enumerate() {
            // chunk_count must be right on EVERY chunk, not just the last: a
            // receiver cannot size or validate the set otherwise.
            assert_eq!(chunk.chunk_count, count);
            assert_eq!(chunk.chunk_index, index as u32);
            assert_eq!(chunk.snapshot_id, "eth0-3");
            assert_eq!(chunk.complete, index == chunks.len() - 1);
        }
    }

    #[test]
    fn every_chunk_still_fits_after_its_index_is_written_back() {
        // REGRESSION: chunk_index/chunk_count are rewritten AFTER the split, so
        // budgeting with the pre-split values (0 and 1 -- which proto3 omits or
        // encodes in a single byte) under-counts by several bytes per chunk and
        // lets a chunk cross the limit once the real values land. Measure the
        // FINAL encoded size, and force wide varints by demanding many chunks.
        const LIMIT: usize = 256;
        let snapshot = build_snapshot(
            &many_entries(400),
            "eth0",
            "eth0-4",
            30 * SEC,
            1_700_000_000 * SEC as i64,
            u32::MAX,
        );
        let (chunks, _) = chunk_snapshot(snapshot, LIMIT);
        assert!(
            chunks.len() > 128,
            "need multi-byte chunk indices to exercise this"
        );
        for chunk in &chunks {
            assert!(
                chunk.encoded_len() <= LIMIT,
                "chunk {} encodes to {} bytes, over the {} limit",
                chunk.chunk_index,
                chunk.encoded_len(),
                LIMIT
            );
        }
    }

    #[test]
    fn an_observation_too_large_for_any_chunk_is_dropped_not_emitted() {
        // Emitting it anyway would produce a frame the reader rejects, losing
        // the WHOLE snapshot. Losing one binding is the better failure.
        let snapshot = build_snapshot(
            &many_entries(3),
            "eth0",
            "eth0-5",
            30 * SEC,
            1_700_000_000 * SEC as i64,
            0,
        );
        // A limit below the per-observation size but above the base.
        let (chunks, dropped) = chunk_snapshot(snapshot, 40);
        assert_eq!(dropped, 3);
        assert_eq!(chunks.len(), 1);
        assert!(chunks[0].observations.is_empty());
        assert!(chunks[0].complete);
    }

    #[test]
    fn monotonic_is_converted_to_wall_clock() {
        // bpf_ktime_get_ns is CLOCK_MONOTONIC -- an arbitrary origin, not an
        // epoch. Sending it unconverted would stamp observations in 1970.
        let wall_now = 1_800_000_000 * SEC as i64;
        let mono_now = 4_242 * SEC;
        // Observed 10s ago on the monotonic clock.
        let got = wall_nanos_from_monotonic(mono_now - 10 * SEC, mono_now, wall_now);
        assert_eq!(got, wall_now - 10 * SEC as i64);
    }

    #[test]
    fn a_backwards_clock_stamps_the_observation_now_rather_than_in_the_future() {
        let wall_now = 1_800_000_000 * SEC as i64;
        // observed_ns ahead of "now" (clock jumped backwards)
        let got = wall_nanos_from_monotonic(5_000 * SEC, 4_000 * SEC, wall_now);
        assert_eq!(got, wall_now, "an impossible age must clamp to now");
    }

    #[test]
    fn an_absurd_age_does_not_wrap_into_the_future() {
        // `as i64` on a u64 age wraps: u64::MAX becomes -1, which would move the
        // timestamp FORWARD. A corrupt reading must degrade to "very old".
        let wall_now = 1_800_000_000 * SEC as i64;
        let got = wall_nanos_from_monotonic(0, u64::MAX, wall_now);
        assert!(
            got < wall_now,
            "an absurd age must not produce a timestamp at or after now"
        );
    }

    #[test]
    fn the_table_tracks_a_binding_and_refreshes_it() {
        let mut t = CensusTable::new(Duration::from_secs(300), 1024);
        let s = scope24();
        let mac = [0xbc, 0x24, 0x11, 0, 0, 1];
        assert!(
            t.observe(&observation(mac, "192.168.1.10", SEC), &s),
            "first sighting is new"
        );
        assert!(
            !t.observe(&observation(mac, "192.168.1.10", 9 * SEC), &s),
            "repeat is not new"
        );
        assert_eq!(t.len(), 1);
        let snap = t.snapshot();
        assert_eq!(snap[0].first_seen_ns, SEC, "first_seen must not move");
        assert_eq!(snap[0].last_seen_ns, 9 * SEC, "last_seen must advance");
    }

    #[test]
    fn distinct_bindings_are_distinct_entries() {
        let mut t = CensusTable::new(Duration::from_secs(300), 1024);
        let s = scope24();
        t.observe(&observation([0xbc, 0, 0, 0, 0, 1], "192.168.1.10", SEC), &s);
        t.observe(&observation([0xbc, 0, 0, 0, 0, 1], "192.168.1.11", SEC), &s);
        t.observe(&observation([0xbc, 0, 0, 0, 0, 2], "192.168.1.10", SEC), &s);
        assert_eq!(t.len(), 3);
    }

    #[test]
    fn expired_bindings_are_evicted_so_absence_means_something() {
        // present:false downstream must mean "this aged out", not "it was quiet
        // during one tick" -- that is why the table has a TTL at all.
        let mut t = CensusTable::new(Duration::from_secs(300), 1024);
        let s = scope24();
        t.observe(
            &observation([0xbc, 0, 0, 0, 0, 1], "192.168.1.10", 10 * SEC),
            &s,
        );
        t.observe(
            &observation([0xbc, 0, 0, 0, 0, 2], "192.168.1.11", 290 * SEC),
            &s,
        );

        assert_eq!(t.evict_expired(300 * SEC), 0, "nothing has aged out yet");
        assert_eq!(t.len(), 2);

        // 311s: the first binding is 301s old, the second is 21s old.
        assert_eq!(t.evict_expired(311 * SEC), 1);
        assert_eq!(t.len(), 1);
        assert_eq!(t.snapshot()[0].mac.octets()[5], 2);
    }

    #[test]
    fn the_table_is_bounded() {
        let mut t = CensusTable::new(Duration::from_secs(300), 4);
        let s = scope24();
        for i in 0..50u8 {
            t.observe(
                &observation([0xbc, 0, 0, 0, 0, i], "192.168.1.10", (i as u64 + 1) * SEC),
                &s,
            );
        }
        assert!(
            t.len() <= 4,
            "a segment larger than budgeted must not grow the table without bound"
        );
    }

    #[test]
    fn a_randomized_mac_is_classified_even_when_the_producer_omits_the_flag() {
        // Defence against a stale eBPF object: the classification gates whether
        // a MAC may anchor a device, so it is derived from the address itself,
        // not only from the flag the producer set.
        let bytes = record(
            L2_KIND_ARP_REPLY,
            4,
            0, // flag deliberately NOT set
            [0x1a, 0x2b, 0x3c, 0x4d, 0x5e, 0x6f],
            v4(192, 168, 1, 50),
        );
        let obs = parse_l2_ring_record(&bytes).expect("decodes");
        assert!(
            obs.randomized_mac,
            "a locally administered MAC is randomized regardless of the flag"
        );
        assert!(!obs.can_anchor_identity(&local_scope()));
    }

    #[test]
    fn a_snapshot_is_deterministic_and_carries_classification() {
        let mut t = CensusTable::new(Duration::from_secs(300), 1024);
        let s = scope24();
        // randomized MAC, on-segment
        t.observe(&observation([0x1a, 0, 0, 0, 0, 9], "192.168.1.50", SEC), &s);
        // burned-in MAC, OFF-segment (router-forwarded)
        t.observe(&observation([0xbc, 0, 0, 0, 0, 1], "192.168.2.44", SEC), &s);

        let a = t.snapshot();
        let b = t.snapshot();
        assert_eq!(a, b, "snapshots must be deterministic");

        let randomized = a.iter().find(|e| e.mac.octets()[0] == 0x1a).unwrap();
        assert!(randomized.randomized_mac);
        let off = a.iter().find(|e| e.mac.octets()[0] == 0xbc).unwrap();
        assert!(
            off.off_segment,
            "an off-segment address must stay marked in the snapshot"
        );
    }
}

#[cfg(target_os = "linux")]
pub mod runtime {
    use super::{
        CENSUS_RATE_CEILING_PER_SEC, CENSUS_WATCHDOG_INTERVAL, CensusTable, CensusWatchdog,
        DeviceObservation, SegmentScope, build_snapshot, parse_l2_ring_record,
    };
    use crate::proto::netprobe::DeviceCensusSnapshot;
    use anyhow::Result;
    use std::net::IpAddr;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::thread;
    use std::time::Duration;
    use std::time::{Instant, SystemTime, UNIX_EPOCH};
    use tokio::sync::broadcast;

    pub const L2_OBSERVATIONS_MAP: &str = "l2_observations";
    pub const L2_RING_DROPS_MAP: &str = "l2_ring_drops";
    const CENSUS_RING_IDLE_SLEEP: Duration = Duration::from_millis(50);

    /// How often the complete segment view is published.
    ///
    /// This is a whole-segment refresh, not an event stream, so the interval is
    /// the freshness bound on device presence rather than a sampling rate: a
    /// device that joins is visible within one interval, and one that leaves
    /// disappears within CENSUS_ENTRY_TTL. Two minutes keeps the ingest cost
    /// proportional to segment SIZE rather than to segment CHATTER, which is
    /// the whole point of holding state at the edge.
    const CENSUS_SNAPSHOT_INTERVAL: Duration = Duration::from_secs(120);

    /// How long a binding survives without being seen again.
    ///
    /// Must be comfortably longer than the snapshot interval, or a device that
    /// is merely quiet would flap out of and back into consecutive snapshots.
    /// The eBPF suppression window refreshes a live device every 60s, so 15
    /// minutes tolerates roughly fourteen consecutive missed refreshes.
    const CENSUS_ENTRY_TTL: Duration = Duration::from_secs(15 * 60);

    /// Upper bound on tracked bindings per interface.
    ///
    /// A /16 segment is larger than this; the table evicts the coldest binding
    /// rather than growing without bound, so the memory ceiling is fixed at
    /// roughly 4k * ~100B regardless of what it is pointed at.
    const CENSUS_TABLE_CAPACITY: usize = 4096;

    /// Running totals, exposed so the census can be observed without a
    /// downstream consumer wired up yet.
    #[derive(Debug, Default)]
    pub struct CensusCounters {
        pub observed: AtomicU64,
        pub randomized: AtomicU64,
        pub off_segment: AtomicU64,
        /// Set when the census shut itself down because suppression failed.
        pub shutdown: std::sync::atomic::AtomicBool,
        pub undecodable: AtomicU64,
        /// Bindings that were new to the table, i.e. genuinely new devices
        /// rather than refreshes of one already known.
        pub tracked: AtomicU64,
        pub snapshots_published: AtomicU64,
    }

    /// Build the observing interface's address scope from the kernel routing
    /// tables. On-link routes give the IPv4 prefixes directly; /proc/net/if_inet6
    /// gives the IPv6 ones.
    ///
    /// Falls back to an empty scope, which anchors nothing: without knowing the
    /// segment we record presence but never claim a binding is local.
    pub(super) fn segment_scope_for(interface: &str) -> SegmentScope {
        let mut prefixes = Vec::new();

        if let Ok(routes) = std::fs::read_to_string("/proc/net/route") {
            for line in routes.lines().skip(1) {
                let f: Vec<&str> = line.split_whitespace().collect();
                if f.len() < 8 || f[0] != interface {
                    continue;
                }
                // Columns are little-endian hex: 1 = destination, 7 = mask.
                let (Ok(dest), Ok(mask)) =
                    (u32::from_str_radix(f[1], 16), u32::from_str_radix(f[7], 16))
                else {
                    continue;
                };
                if mask == 0 {
                    // Default route: not a segment, it is everything else.
                    continue;
                }
                let network = std::net::Ipv4Addr::from(dest.swap_bytes());
                prefixes.push((IpAddr::V4(network), mask.count_ones() as u8));
            }
        }

        if let Ok(v6) = std::fs::read_to_string("/proc/net/if_inet6") {
            for line in v6.lines() {
                let f: Vec<&str> = line.split_whitespace().collect();
                if f.len() < 6 || f[5] != interface {
                    continue;
                }
                let (Ok(bytes), Ok(bits)) = (
                    (0..16)
                        .map(|i| u8::from_str_radix(&f[0][i * 2..i * 2 + 2], 16))
                        .collect::<Result<Vec<u8>, _>>(),
                    u8::from_str_radix(f[2], 16),
                ) else {
                    continue;
                };
                let mut octets = [0u8; 16];
                octets.copy_from_slice(&bytes);
                prefixes.push((IpAddr::V6(std::net::Ipv6Addr::from(octets)), bits));
            }
        }

        SegmentScope::new(prefixes)
    }

    struct CensusConsumer {
        interface_name: String,
        /// Distinguishes snapshots from THIS netprobe process.
        ///
        /// The agent buffers chunks keyed by snapshot_id until it has a
        /// complete set, so a plain counter is not safe: it restarts at 0 with
        /// the process, and a netprobe that dies mid-snapshot would leave the
        /// agent holding chunks whose id the next process immediately reuses,
        /// letting two different snapshots merge into one. Seeding with the
        /// process start time makes reuse require two starts in the same
        /// nanosecond on the same interface.
        snapshot_id_prefix: String,
        scope: SegmentScope,
        ring: aya::maps::RingBuf<aya::maps::MapData>,
        drops: Option<aya::maps::PerCpuArray<aya::maps::MapData, u64>>,
        counters: Arc<CensusCounters>,
        watchdog: CensusWatchdog,
        stop: Arc<AtomicBool>,
        table: CensusTable,
        snapshots: broadcast::Sender<DeviceCensusSnapshot>,
        last_snapshot: Instant,
        snapshot_seq: u64,
        drops_at_last_snapshot: u64,
    }

    // Maximum records drained per poll before returning to the loop that checks
    // the stop flag.
    //
    // Without a bound, a busy ring starves the shutdown check entirely: the
    // inner drain loop keeps finding records and never returns, so
    // Drop::join() blocks forever and systemd kills the unit on timeout. That
    // is exactly what happened on a live host before the ARP/NDP restriction
    // reduced the volume -- and the bound is still needed, because the fix for
    // a shutdown hang must not depend on the ring being quiet.
    const CENSUS_POLL_BUDGET: usize = 1024;

    impl CensusConsumer {
        fn poll_once(&mut self, stop: &AtomicBool) -> usize {
            let mut seen = 0usize;
            while seen < CENSUS_POLL_BUDGET && !stop.load(Ordering::Relaxed) {
                let Some(item) = self.ring.next() else {
                    break;
                };
                match parse_l2_ring_record(item.as_ref()) {
                    Some(observation) => {
                        seen += 1;
                        // There is no userspace suppression fallback by design.
                        // If the eBPF path stops suppressing, the census must
                        // stop -- degrading into a resource hog would cost more
                        // trust than the feature is worth.
                        if !self.watchdog.record(Instant::now()) {
                            log::error!(
                                "netprobe passive device census SHUTTING DOWN on {}: sustained \
                                 above {} observations/sec, which means in-kernel suppression is \
                                 not suppressing. The census is stopping rather than continuing \
                                 to consume resources; flow attribution is unaffected.",
                                self.interface_name,
                                CENSUS_RATE_CEILING_PER_SEC,
                            );
                            self.counters.shutdown.store(true, Ordering::SeqCst);
                            self.stop.store(true, Ordering::SeqCst);
                            return seen;
                        }
                        self.counters.observed.fetch_add(1, Ordering::Relaxed);
                        if observation.randomized_mac {
                            self.counters.randomized.fetch_add(1, Ordering::Relaxed);
                        }
                        if observation.is_off_segment(&self.scope) {
                            self.counters.off_segment.fetch_add(1, Ordering::Relaxed);
                        }
                        if self.table.observe(&observation, &self.scope) {
                            self.counters.tracked.fetch_add(1, Ordering::Relaxed);
                            log_observation(&self.interface_name, &self.scope, &observation);
                        }
                    }
                    None => {
                        self.counters.undecodable.fetch_add(1, Ordering::Relaxed);
                        // A record we cannot decode still consumed ring space;
                        // count it against the budget so a stream of malformed
                        // records cannot starve the stop check either.
                        seen += 1;
                    }
                }
            }
            seen
        }

        /// Publish the complete segment view if the interval has elapsed.
        ///
        /// Runs on the polling thread rather than a timer task so it cannot
        /// observe the table mid-update: the same thread owns both the drain
        /// and the publish, which is what makes a snapshot internally
        /// consistent without a lock.
        fn maybe_publish(&mut self, now: Instant) {
            if now.duration_since(self.last_snapshot) < CENSUS_SNAPSHOT_INTERVAL {
                return;
            }
            self.last_snapshot = now;
            self.publish_snapshot();
        }

        fn publish_snapshot(&mut self) {
            let monotonic_now_ns = monotonic_now_ns();
            let evicted = self.table.evict_expired(monotonic_now_ns);
            let entries = self.table.snapshot();

            self.snapshot_seq += 1;
            let snapshot_id = format!("{}-{}", self.snapshot_id_prefix, self.snapshot_seq);
            let dropped = self.dropped_since_last();

            let snapshot = build_snapshot(
                &entries,
                &self.interface_name,
                &snapshot_id,
                monotonic_now_ns,
                wall_now_ns(),
                dropped,
            );

            log::debug!(
                "census snapshot interface={} id={} devices={} evicted={} ring_drops={}",
                self.interface_name,
                snapshot_id,
                entries.len(),
                evicted,
                dropped,
            );

            // A send with no subscriber is the normal state whenever no agent
            // is connected. It is not an error and must not be logged as one:
            // the census keeps tracking the segment either way, and the next
            // snapshot is complete, so a reconnecting agent misses nothing.
            if self.snapshots.send(snapshot).is_ok() {
                self.counters
                    .snapshots_published
                    .fetch_add(1, Ordering::Relaxed);
            }
        }

        /// Ring-full drops since the previous snapshot.
        ///
        /// The eBPF counter is per-CPU and monotonic, so the value is summed
        /// across CPUs and differenced against the previous reading.
        fn dropped_since_last(&mut self) -> u32 {
            let Some(drops) = self.drops.as_ref() else {
                return 0;
            };
            let Ok(values) = drops.get(&0, 0) else {
                return 0;
            };
            let total: u64 = values.iter().copied().sum();
            let delta = total.saturating_sub(self.drops_at_last_snapshot);
            self.drops_at_last_snapshot = total;
            u32::try_from(delta).unwrap_or(u32::MAX)
        }
    }

    /// Shared with the mDNS collector rather than duplicated.
    ///
    /// Both must read the SAME clock as bpf_ktime_get_ns (CLOCK_MONOTONIC); a
    /// second copy that drifted to CLOCK_BOOTTIME would put every converted
    /// timestamp out by the suspend offset, and only on machines that suspend.
    pub fn monotonic_now_ns() -> u64 {
        let mut ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        // SAFETY: `ts` is a valid, writable timespec and CLOCK_MONOTONIC is a
        // valid clock id. This must match bpf_ktime_get_ns, which is also
        // CLOCK_MONOTONIC -- using a different clock here would make every
        // converted timestamp wrong by the boot-time offset.
        if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) } != 0 {
            return 0;
        }
        (ts.tv_sec as u64)
            .saturating_mul(1_000_000_000)
            .saturating_add(ts.tv_nsec as u64)
    }

    /// Shared with the mDNS collector; see `monotonic_now_ns`.
    pub fn wall_now_ns() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()
            .and_then(|d| i64::try_from(d.as_nanos()).ok())
            .unwrap_or(0)
    }

    fn log_observation(interface: &str, scope: &SegmentScope, observation: &DeviceObservation) {
        let ip = observation
            .ip
            .map(|ip| ip.to_string())
            .unwrap_or_else(|| "-".to_owned());
        log::info!(
            "census observation interface={} kind={} mac={} ip={} randomized={} probe={} gratuitous={} off_segment={} anchorable={}",
            interface,
            observation.kind.as_str(),
            observation.mac,
            ip,
            observation.randomized_mac,
            observation.arp_probe,
            observation.gratuitous,
            observation.is_off_segment(scope),
            observation.can_anchor_identity(scope),
        );
    }

    /// Owns the census polling thread. Dropping it stops the thread.
    pub struct DeviceCensusRuntime {
        stop: Arc<AtomicBool>,
        thread: Option<thread::JoinHandle<()>>,
    }

    impl DeviceCensusRuntime {
        pub fn start_from_ebpf(
            interface_name: impl Into<String>,
            ebpf: &mut aya::Ebpf,
            snapshots: broadcast::Sender<DeviceCensusSnapshot>,
        ) -> Result<Self> {
            let map = ebpf
                .take_map(L2_OBSERVATIONS_MAP)
                .ok_or_else(|| anyhow::anyhow!("{L2_OBSERVATIONS_MAP} map is missing"))?;
            // A missing drop counter degrades `dropped_since_last` to 0 rather
            // than failing the census: an older pinned object without the map
            // should still produce a usable segment view.
            let drops = match ebpf.take_map(L2_RING_DROPS_MAP) {
                Some(map) => match aya::maps::PerCpuArray::try_from(map) {
                    Ok(array) => Some(array),
                    Err(err) => {
                        log::warn!(
                            "netprobe census cannot read {L2_RING_DROPS_MAP} ({err}); snapshots will report 0 dropped observations"
                        );
                        None
                    }
                },
                None => {
                    log::warn!(
                        "netprobe census found no {L2_RING_DROPS_MAP} map; snapshots will report 0 dropped observations"
                    );
                    None
                }
            };
            let counters = Arc::new(CensusCounters::default());
            let interface_name = interface_name.into();
            let scope = segment_scope_for(&interface_name);
            if scope.is_empty() {
                log::warn!(
                    "netprobe census could not determine the segment for {interface_name}: observations will record presence but anchor no identity"
                );
            }
            let stop = Arc::new(AtomicBool::new(false));
            let snapshot_id_prefix = format!("{}-{}", interface_name, wall_now_ns());
            let mut consumer = CensusConsumer {
                interface_name,
                snapshot_id_prefix,
                scope,
                ring: aya::maps::RingBuf::try_from(map)?,
                drops,
                counters: Arc::clone(&counters),
                watchdog: CensusWatchdog::new(
                    CENSUS_RATE_CEILING_PER_SEC,
                    CENSUS_WATCHDOG_INTERVAL,
                    Instant::now(),
                ),
                stop: Arc::clone(&stop),
                table: CensusTable::new(CENSUS_ENTRY_TTL, CENSUS_TABLE_CAPACITY),
                snapshots,
                last_snapshot: Instant::now(),
                snapshot_seq: 0,
                drops_at_last_snapshot: 0,
            };
            let stop_worker = Arc::clone(&stop);
            let thread = thread::Builder::new()
                .name("netprobe-device-census".to_owned())
                .spawn(move || {
                    while !stop_worker.load(Ordering::Relaxed) {
                        if consumer.poll_once(&stop_worker) == 0 {
                            thread::sleep(CENSUS_RING_IDLE_SLEEP);
                        }
                        // Checked on every iteration, including the idle one:
                        // an empty segment must still publish, or a segment
                        // that goes quiet would never report its devices
                        // leaving.
                        consumer.maybe_publish(Instant::now());
                    }
                })?;

            Ok(Self {
                stop,
                thread: Some(thread),
            })
        }
    }

    impl Drop for DeviceCensusRuntime {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::SeqCst);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
    }
}

#[cfg(target_os = "linux")]
pub use runtime::DeviceCensusRuntime;
