//! `AF_PACKET` capture with a `PACKET_MMAP` (TPACKET_V3) ring.
//!
//! Shared by `serviceradar-netprobe`'s remote capture engine and
//! `serviceradar-fieldsurvey-sidekick`, which each grew their own ring walker
//! before this crate existed.
//!
//! # Why the API is shaped like this
//!
//! Every trap in the AF_PACKET setup sequence fails *silently*, so this crate
//! removes the opportunity to hit them rather than documenting them and hoping.
//! Each of the following was measured on Linux 6.8, not assumed:
//!
//! * **`PACKET_VERSION` must be set before `PACKET_RX_RING`.** Setting the ring
//!   first returns success and quietly builds a **TPACKET_V1** ring, whose block
//!   status never reads `TP_STATUS_USER`. The capture then polls forever,
//!   delivers zero packets and reports no error — indistinguishable from an idle
//!   interface. There is no way to call these out of order here: [`Socket::activate`]
//!   performs the whole sequence, and reads the version *back* before mapping.
//! * **The ring must not be armed before `bind`.** A ring created while the
//!   socket is unbound fills with frames from *other* interfaces, which for a
//!   per-interface capture session is an authorization bypass that produces a
//!   plausible-looking result. [`Socket::open`] therefore creates the socket at
//!   protocol 0, so nothing is delivered until [`Socket::activate`] binds it.
//! * **`getsockopt(PACKET_STATISTICS)` RESETS its counters**, and `tp_packets`
//!   *includes* `tp_drops`. Two callers reading it independently each see part
//!   of the truth and the session reports zero drops for a capture that dropped
//!   everything. The syscall is private to this crate and reachable only through
//!   [`Ring::stats`], which accumulates into monotonic per-session totals.
//!
//! # Privilege
//!
//! Only `socket(AF_PACKET, ...)` requires `CAP_NET_RAW`. Everything else —
//! setting the version, attaching a filter, arming the ring, mapping it and
//! binding — was measured to succeed on a descriptor opened beforehand and
//! carried across a `setuid` that zeroes every capability.
//!
//! That split is why [`Socket::open`] and [`Socket::activate`] are separate
//! calls: a process that drops privileges after start-up opens its sockets
//! while privileged and configures them later.
//!
//! # Non-Linux
//!
//! Every constructor returns [`Error::Unsupported`]. It deliberately does not
//! return an empty success: a capture path that yields zero packets while
//! reporting success is the failure this codebase keeps re-learning.

#![deny(missing_debug_implementations)]

use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("AF_PACKET capture is only supported on Linux")]
    Unsupported,

    #[error("failed to open an AF_PACKET socket for {interface}: {source}")]
    Open {
        interface: String,
        #[source]
        source: std::io::Error,
    },

    #[error("interface {0} does not exist")]
    UnknownInterface(String),

    #[error("failed to {operation} on the capture socket: {source}")]
    Configure {
        operation: &'static str,
        #[source]
        source: std::io::Error,
    },

    /// The kernel accepted `PACKET_VERSION` but reports a different version.
    ///
    /// Treated as fatal rather than logged: continuing would walk a V1 ring
    /// with V3 offsets and silently capture nothing.
    #[error(
        "kernel reports TPACKET version {got} after requesting v3; refusing to map a ring whose layout is unknown"
    )]
    VersionMismatch { got: i32 },

    #[error("capture ring geometry is invalid: {0}")]
    Geometry(&'static str),
}

/// Ring geometry.
///
/// The kernel enforces relationships between these that it reports only as
/// `EINVAL`, so [`RingConfig::validate`] checks them first and says which one
/// was violated.
#[derive(Debug, Clone, Copy)]
pub struct RingConfig {
    /// Bytes per block. Must be a multiple of the page size and a power of two.
    pub block_size: u32,
    /// Number of blocks. `block_size * block_count` is the mapped length.
    pub block_count: u32,
    /// Bytes per frame. Must divide `block_size`.
    pub frame_size: u32,
    /// How long the kernel holds a partially filled block before handing it to
    /// userspace, in milliseconds.
    ///
    /// This is also the maximum time a session's last packets can sit unread,
    /// so a capture that stops must drain for at least this long before
    /// declaring itself complete, or it truncates silently.
    pub retire_timeout_ms: u32,
}

impl Default for RingConfig {
    fn default() -> Self {
        // 128 KiB blocks x 8 = 1 MiB mapped, 2 KiB frames. The 100 ms retire
        // timeout matches the existing fieldsurvey-sidekick ring and bounds how
        // long a stopping session must drain.
        Self {
            block_size: 1 << 17,
            block_count: 8,
            frame_size: 1 << 11,
            retire_timeout_ms: 100,
        }
    }
}

impl RingConfig {
    pub fn validate(&self) -> Result<(), Error> {
        if self.block_size == 0 || !self.block_size.is_power_of_two() {
            return Err(Error::Geometry("block_size must be a power of two"));
        }
        if self.frame_size == 0 || !self.frame_size.is_power_of_two() {
            return Err(Error::Geometry("frame_size must be a power of two"));
        }
        if self.frame_size > self.block_size {
            return Err(Error::Geometry("frame_size must not exceed block_size"));
        }
        if !self.block_size.is_multiple_of(self.frame_size) {
            return Err(Error::Geometry(
                "block_size must be a multiple of frame_size",
            ));
        }
        if self.block_count == 0 {
            return Err(Error::Geometry("block_count must be non-zero"));
        }
        // The kernel requires the block size to be a multiple of the page size.
        // The doc comment claimed this and nothing enforced it, so a geometry
        // valid on a 4 KiB host would fail with a bare EINVAL on a 16 KiB one.
        #[cfg(target_os = "linux")]
        {
            // SAFETY: sysconf with a constant name has no preconditions.
            let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
            if page > 0 {
                let page = page as u32;
                if !self.block_size.is_multiple_of(page) {
                    return Err(Error::Geometry(
                        "block_size must be a multiple of the page size",
                    ));
                }
            }
        }
        if self.block_size.checked_mul(self.block_count).is_none() {
            return Err(Error::Geometry("block_size * block_count overflows"));
        }
        Ok(())
    }

    pub fn mapped_len(&self) -> usize {
        self.block_size as usize * self.block_count as usize
    }
}

/// Cumulative, monotonic counters for one capture session.
///
/// Built by accumulating each `PACKET_STATISTICS` read, because that syscall
/// resets the kernel's counters. `captured` is derived rather than taken from
/// `tp_packets`, which includes drops.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    /// Frames the kernel handed to this socket, excluding drops.
    pub captured: u64,
    /// Frames dropped because the ring was full.
    pub dropped: u64,
    /// Frames whose ring offsets did not fit inside their block.
    ///
    /// Excluded from [`Stats::is_complete`]: a session that saw an impossible
    /// descriptor lost data, and reporting it as clean is the failure this
    /// crate exists to avoid.
    pub malformed: u64,
}

impl Stats {
    /// Fold one raw `tpacket_stats_v3` reading into the running totals.
    ///
    /// `tp_packets` includes `tp_drops`, so reporting it as "captured" makes a
    /// session that delivered 6 frames out of 12000 present as having captured
    /// all 12000.
    // Called from the Linux ring; the non-Linux path has no statistics to
    // fold, which is the same shape as kernel.rs and config.rs in netprobe.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub(crate) fn accumulate(&mut self, tp_packets: u32, tp_drops: u32) {
        self.dropped += u64::from(tp_drops);
        self.captured += u64::from(tp_packets.saturating_sub(tp_drops));
    }

    /// Whether this session lost packets. A session that dropped anything is
    /// not a complete capture and must not be presented as one.
    pub fn is_complete(&self) -> bool {
        self.dropped == 0 && self.malformed == 0
    }
}

/// Which direction a frame travelled, from `sll_pkttype`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Received by this host.
    Inbound,
    /// Transmitted by this host (`PACKET_OUTGOING`).
    Outbound,
}

/// One captured frame, borrowed from the ring.
#[derive(Debug)]
pub struct Frame<'a> {
    /// Frame bytes, truncated to the snaplen the filter requested.
    pub data: &'a [u8],
    /// Length on the wire, which exceeds `data.len()` when truncated.
    pub original_len: u32,
    /// Wall-clock nanoseconds since the Unix epoch, from the ring header.
    pub timestamp_ns: u64,
    pub direction: Direction,
    /// The interface the frame arrived on. Compared against the session's
    /// interface by callers that must prove no other interface leaked in.
    pub ifindex: u32,
}

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
pub use linux::{ActivateError, Ring, Socket};

#[cfg(not(target_os = "linux"))]
mod unsupported;

#[cfg(not(target_os = "linux"))]
pub use unsupported::{ActivateError, Ring, Socket};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_geometry_is_valid() {
        RingConfig::default().validate().expect("default is valid");
        assert_eq!(RingConfig::default().mapped_len(), 1 << 20);
    }

    #[test]
    fn invalid_geometry_names_the_violated_rule() {
        let cases: [(RingConfig, &str); 4] = [
            (
                RingConfig {
                    block_size: 3000,
                    ..Default::default()
                },
                "block_size must be a power of two",
            ),
            (
                RingConfig {
                    frame_size: 1 << 18,
                    ..Default::default()
                },
                "frame_size must not exceed block_size",
            ),
            (
                RingConfig {
                    block_count: 0,
                    ..Default::default()
                },
                "block_count must be non-zero",
            ),
            (
                RingConfig {
                    frame_size: 3,
                    ..Default::default()
                },
                "frame_size must be a power of two",
            ),
        ];
        for (config, expected) in cases {
            match config.validate() {
                Err(Error::Geometry(msg)) => assert_eq!(msg, expected),
                other => panic!("expected {expected:?}, got {other:?}"),
            }
        }
    }

    #[test]
    fn captured_excludes_drops_because_tp_packets_includes_them() {
        // The trap: reporting tp_packets as "captured" makes a session that
        // delivered 6 of 12000 frames look like it captured all 12000.
        let mut stats = Stats::default();
        stats.accumulate(12_000, 11_994);
        assert_eq!(stats.captured, 6);
        assert_eq!(stats.dropped, 11_994);
        assert!(!stats.is_complete());
    }

    #[test]
    fn statistics_accumulate_because_the_syscall_resets_them() {
        // Each reading is a delta since the previous read, so totals must be
        // summed. A caller that overwrote instead would report only the last
        // interval and lose every earlier drop.
        let mut stats = Stats::default();
        stats.accumulate(10, 1);
        stats.accumulate(10, 2);
        stats.accumulate(10, 0);
        assert_eq!(stats.captured, 27);
        assert_eq!(stats.dropped, 3);
    }

    #[test]
    fn a_clean_session_is_complete() {
        let mut stats = Stats::default();
        stats.accumulate(500, 0);
        assert!(stats.is_complete());
        assert_eq!(stats.captured, 500);
    }
}
