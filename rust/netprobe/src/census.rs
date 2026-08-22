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
        randomized_mac: flags & L2_FLAG_LOCALLY_ADMINISTERED != 0,
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
}

#[cfg(target_os = "linux")]
mod runtime {
    use super::{
        CENSUS_RATE_CEILING_PER_SEC, CENSUS_WATCHDOG_INTERVAL, CensusWatchdog, DeviceObservation,
        SegmentScope, parse_l2_ring_record,
    };
    use anyhow::Result;
    use std::net::IpAddr;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::thread;
    use std::time::Duration;
    use std::time::Instant;

    pub const L2_OBSERVATIONS_MAP: &str = "l2_observations";
    const CENSUS_RING_IDLE_SLEEP: Duration = Duration::from_millis(50);

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
    }

    impl CensusCounters {
        pub fn snapshot(&self) -> (u64, u64, u64) {
            (
                self.observed.load(Ordering::Relaxed),
                self.randomized.load(Ordering::Relaxed),
                self.undecodable.load(Ordering::Relaxed),
            )
        }
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
        scope: SegmentScope,
        ring: aya::maps::RingBuf<aya::maps::MapData>,
        counters: Arc<CensusCounters>,
        watchdog: CensusWatchdog,
        stop: Arc<AtomicBool>,
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
                        log_observation(&self.interface_name, &self.scope, &observation);
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
        counters: Arc<CensusCounters>,
    }

    impl DeviceCensusRuntime {
        pub fn start_from_ebpf(
            interface_name: impl Into<String>,
            ebpf: &mut aya::Ebpf,
        ) -> Result<Self> {
            let map = ebpf
                .take_map(L2_OBSERVATIONS_MAP)
                .ok_or_else(|| anyhow::anyhow!("{L2_OBSERVATIONS_MAP} map is missing"))?;
            let counters = Arc::new(CensusCounters::default());
            let interface_name = interface_name.into();
            let scope = segment_scope_for(&interface_name);
            if scope.is_empty() {
                log::warn!(
                    "netprobe census could not determine the segment for {interface_name}: observations will record presence but anchor no identity"
                );
            }
            let stop = Arc::new(AtomicBool::new(false));
            let mut consumer = CensusConsumer {
                interface_name,
                scope,
                ring: aya::maps::RingBuf::try_from(map)?,
                counters: Arc::clone(&counters),
                watchdog: CensusWatchdog::new(
                    CENSUS_RATE_CEILING_PER_SEC,
                    CENSUS_WATCHDOG_INTERVAL,
                    Instant::now(),
                ),
                stop: Arc::clone(&stop),
            };
            let stop_worker = Arc::clone(&stop);
            let thread = thread::Builder::new()
                .name("netprobe-device-census".to_owned())
                .spawn(move || {
                    while !stop_worker.load(Ordering::Relaxed) {
                        if consumer.poll_once(&stop_worker) == 0 {
                            thread::sleep(CENSUS_RING_IDLE_SLEEP);
                        }
                    }
                })?;

            Ok(Self {
                stop,
                thread: Some(thread),
                counters,
            })
        }

        pub fn counters(&self) -> Arc<CensusCounters> {
            Arc::clone(&self.counters)
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
pub use runtime::{CensusCounters, DeviceCensusRuntime, L2_OBSERVATIONS_MAP};
