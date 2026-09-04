//! One capture session: caps, counters, and the terminal block.
//!
//! The session owns the pcapng [`Encoder`](super::pcapng::Encoder) and the
//! accounting, but NOT the ring. Frames are offered to it. That split is
//! deliberate: the ring is Linux-only and needs a real interface, while every
//! rule worth getting wrong here — when a cap fires, what the terminal block
//! says, whether the counts agree — is pure logic that must be testable
//! without root, a NIC, or a sleep.
//!
//! # The clock is a parameter
//!
//! [`CaptureSession::offer`] takes the elapsed time rather than reading it.
//! A duration cap tested against a real clock either sleeps for the cap (slow,
//! and flaky under load — this repository has a p99 test that fails at load
//! average 130) or shrinks the cap until the test proves nothing. Passing
//! elapsed time in makes "at the cap" and "one nanosecond past it" exact.
//!
//! # Why a stopping session keeps draining
//!
//! TPACKET_V3 hands userspace a block only when it is full or when
//! `tp_retire_blk_tov` expires. Frames the kernel has already counted in
//! `tp_packets` can therefore be sitting in a partially filled block at the
//! moment a session is told to stop. Emitting the terminal block immediately
//! truncates the capture by up to that timeout, and nothing errors: the file
//! just ends early and `packets_captured` disagrees with the kernel's count.
//! So a session being CANCELLED keeps accepting frames while the caller drains
//! for one retire timeout, and only then calls [`CaptureSession::finish`].
//!
//! A session ended by a CAP is the opposite case and is not drained for output:
//! refusing everything past the cap is the point, so the frames the kernel
//! delivered into the block being walked are counted by it and dropped by us.
//! [`CaptureSession::finish`] excludes a capped session from the count
//! cross-check for exactly that reason.

use std::time::Duration;

use serviceradar_afpacket::Stats;

use super::pcapng::{Encoder, Frame};
use crate::proto::netprobe::CaptureTerminationReason;

/// Hard bounds on a session. Both are optional; a session with neither runs
/// until the caller stops it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Limits {
    /// Wall-clock ceiling. `None` means no duration cap.
    pub duration: Option<Duration>,
    /// Ceiling on emitted pcapng bytes, counting the header. `None` means no
    /// byte cap.
    ///
    /// Counted on ENCODED output rather than captured packet bytes, because
    /// that is what the operator's transport actually carries and what the
    /// terminal block reports.
    pub byte_cap: Option<u64>,
}

impl Limits {
    /// Build from the proto's zero-means-unset integers.
    pub fn from_wire(duration_s: u32, byte_cap: u64) -> Self {
        Self {
            duration: (duration_s > 0).then(|| Duration::from_secs(u64::from(duration_s))),
            byte_cap: (byte_cap > 0).then_some(byte_cap),
        }
    }
}

/// What `offer` did with a frame.
#[derive(Debug, PartialEq, Eq)]
pub enum Offered {
    /// Encoded; send these bytes.
    Encoded(Vec<u8>),
    /// The encoder refused the frame — a zero-length frame, an
    /// `original_len` below the captured length, an unknown interface id, or
    /// one longer than the declared snaplen. Refusing beats emitting, because
    /// each of those makes a reader drop packets or abort while exiting 0.
    Refused,
    /// A cap had already fired. The session is closed to new frames.
    Closed,
}

/// The terminal block's contents, for the caller to put on the wire.
#[derive(Debug, PartialEq, Eq)]
pub struct Termination {
    pub reason: CaptureTerminationReason,
    /// Enhanced Packet Blocks actually encoded.
    pub packets_captured: u64,
    /// Frames the kernel dropped, plus any it described impossibly.
    pub packets_dropped: u64,
    pub bytes_streamed: u64,
    /// True when the session delivered every frame the kernel counted.
    ///
    /// Derived by comparing our own EPB count against the kernel's
    /// `tp_packets - tp_drops`. A disagreement means frames were lost between
    /// the ring and the encoder — silently, since neither counter alone shows
    /// it.
    pub complete: bool,
}

#[derive(Debug)]
pub struct CaptureSession {
    encoder: Encoder,
    limits: Limits,
    packets_captured: u64,
    bytes_streamed: u64,
    closed: Option<CaptureTerminationReason>,
}

impl CaptureSession {
    /// Start a session, returning the pcapng header bytes to send first.
    ///
    /// The header counts toward `byte_cap`: a cap smaller than the header
    /// closes the session immediately rather than emitting a file whose own
    /// preamble already exceeds what the operator allowed.
    pub fn begin(interfaces: Vec<String>, snaplen: u32, limits: Limits) -> (Self, Vec<u8>) {
        let mut encoder = Encoder::new(interfaces, snaplen);
        let header = encoder.begin();

        let mut session = Self {
            encoder,
            limits,
            packets_captured: 0,
            bytes_streamed: header.len() as u64,
            closed: None,
        };
        if session.byte_cap_reached() {
            session.closed = Some(CaptureTerminationReason::ByteCap);
        }
        (session, header)
    }

    /// Offer one captured frame.
    ///
    /// `elapsed` is the time since the session started. Caps are evaluated
    /// BEFORE encoding, so a session never emits a block that carries it past
    /// a limit the operator set.
    pub fn offer(&mut self, frame: Frame<'_>, elapsed: Duration) -> Offered {
        if self.closed.is_some() {
            return Offered::Closed;
        }
        if self.duration_reached(elapsed) {
            self.closed = Some(CaptureTerminationReason::DurationCap);
            return Offered::Closed;
        }

        let Some(block) = self.encoder.packet(frame) else {
            return Offered::Refused;
        };

        self.packets_captured += 1;
        self.bytes_streamed += block.len() as u64;
        if self.byte_cap_reached() {
            self.closed = Some(CaptureTerminationReason::ByteCap);
        }
        Offered::Encoded(block)
    }

    /// Whether a cap has closed the session to new frames.
    ///
    /// A closed session is still drainable: the caller should keep draining
    /// for at least `tp_retire_blk_tov` so frames the kernel already counted
    /// are not silently lost, then call [`CaptureSession::finish`].
    pub fn is_closed(&self) -> bool {
        self.closed.is_some()
    }

    /// Close the session and describe the terminal block.
    ///
    /// A cap that already fired wins over `reason`: a session stopped by its
    /// byte cap and then cancelled by a disconnecting client terminated
    /// because of the cap, and reporting the disconnect would misattribute it.
    pub fn finish(self, reason: CaptureTerminationReason, stats: Stats) -> Termination {
        let reason = self.closed.unwrap_or(reason);
        // `stats.captured` is the kernel's tp_packets minus tp_drops; ours is
        // the number of EPBs written. They should agree, and a mismatch is
        // itself data loss worth surfacing.
        //
        // EXCEPT when a cap ended the session, where they are expected to
        // disagree and by an amount nobody controls. The kernel keeps
        // delivering into the block being walked at the moment the cap trips,
        // and those frames are counted by it and refused by us -- deliberately,
        // since the whole point of a cap is that nothing past it is emitted.
        // Whether the numbers happen to line up depends on where in a block the
        // cap fell, so comparing them would make `complete` a coin flip on
        // every capped capture. A signal that fires at random is not a signal,
        // and this one exists to mean "frames vanished between the ring and the
        // encoder". Drops still count against a capped session.
        let counts_are_comparable = !matches!(
            reason,
            CaptureTerminationReason::DurationCap | CaptureTerminationReason::ByteCap
        );
        let complete = stats.is_complete()
            && (!counts_are_comparable || stats.captured == self.packets_captured);

        Termination {
            reason,
            packets_captured: self.packets_captured,
            packets_dropped: stats.dropped + stats.malformed,
            bytes_streamed: self.bytes_streamed,
            complete,
        }
    }

    fn duration_reached(&self, elapsed: Duration) -> bool {
        self.limits.duration.is_some_and(|cap| elapsed >= cap)
    }

    fn byte_cap_reached(&self) -> bool {
        self.limits
            .byte_cap
            .is_some_and(|cap| self.bytes_streamed >= cap)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const IFACE: &str = "eth0";

    fn session(limits: Limits) -> (CaptureSession, Vec<u8>) {
        CaptureSession::begin(vec![IFACE.to_string()], 65_535, limits)
    }

    fn frame(data: &[u8]) -> Frame<'_> {
        Frame {
            interface_id: 0,
            timestamp_ns: 1_700_000_000_000_000_000,
            data,
            original_len: data.len() as u32,
        }
    }

    /// Built by literal rather than through `accumulate`, which is
    /// `pub(crate)` in afpacket precisely so callers cannot double-count a
    /// reading. The fields are public, so a test needs no wider API.
    fn clean_stats(captured: u64) -> Stats {
        Stats {
            captured,
            dropped: 0,
            malformed: 0,
        }
    }

    #[test]
    fn a_session_with_no_limits_keeps_accepting() {
        let (mut s, header) = session(Limits::default());
        assert!(!header.is_empty(), "the header is emitted up front");

        for _ in 0..64 {
            assert!(matches!(
                s.offer(frame(&[0u8; 64]), Duration::from_secs(3_600)),
                Offered::Encoded(_)
            ));
        }
        assert!(!s.is_closed());
    }

    #[test]
    fn the_duration_cap_fires_exactly_at_the_boundary() {
        // Testable to the nanosecond because elapsed time is a parameter. A
        // real clock would force either a slow test or a cap so small the
        // assertion proves nothing.
        let limits = Limits {
            duration: Some(Duration::from_secs(30)),
            ..Default::default()
        };
        let (mut s, _) = session(limits);

        assert!(matches!(
            s.offer(frame(&[0u8; 64]), Duration::from_millis(29_999)),
            Offered::Encoded(_)
        ));
        assert!(!s.is_closed(), "one millisecond short of the cap");

        assert_eq!(
            s.offer(frame(&[0u8; 64]), Duration::from_secs(30)),
            Offered::Closed,
            "at the cap, not merely past it"
        );
        assert!(s.is_closed());
    }

    #[test]
    fn the_byte_cap_fires_and_the_reason_survives_a_later_cancel() {
        // SHB (28) + one IDB (32) = 60 bytes of header, then a couple of
        // packets' worth of headroom.
        let (mut s, header) = session(Limits {
            byte_cap: Some(60 + 200),
            ..Default::default()
        });
        assert_eq!(
            header.len(),
            60,
            "header layout the cap is measured against"
        );

        let mut packets = 0u64;
        while !s.is_closed() {
            match s.offer(frame(&[0u8; 64]), Duration::ZERO) {
                Offered::Encoded(_) => packets += 1,
                other => panic!("unexpected {other:?}"),
            }
        }
        assert!(packets > 0, "the cap must allow at least one packet");

        // A client cancel arriving after the cap must not overwrite why the
        // session actually stopped.
        let t = s.finish(CaptureTerminationReason::ClientCancel, clean_stats(packets));
        assert_eq!(t.reason, CaptureTerminationReason::ByteCap);
        assert_eq!(t.packets_captured, packets);
        assert!(t.bytes_streamed >= 60 + 200, "the cap fires at or past it");
        assert!(t.complete, "no drops and the counts agree");
    }

    #[test]
    fn a_byte_cap_below_the_header_closes_immediately() {
        // Otherwise the session emits a file whose own preamble already
        // exceeds what the operator allowed.
        let (s, header) = session(Limits {
            byte_cap: Some(4),
            ..Default::default()
        });
        assert!(!header.is_empty(), "the header is still returned");
        assert!(s.is_closed());
        let t = s.finish(CaptureTerminationReason::ClientCancel, Stats::default());
        assert_eq!(t.reason, CaptureTerminationReason::ByteCap);
    }

    #[test]
    fn a_closed_session_refuses_further_frames() {
        let (mut s, _) = session(Limits {
            duration: Some(Duration::from_secs(1)),
            ..Default::default()
        });
        assert_eq!(
            s.offer(frame(&[0u8; 64]), Duration::from_secs(1)),
            Offered::Closed
        );
        assert_eq!(
            s.offer(frame(&[0u8; 64]), Duration::ZERO),
            Offered::Closed,
            "a cap does not un-fire when a later frame reports less elapsed time"
        );
    }

    #[test]
    fn an_unencodable_frame_is_refused_without_closing_the_session() {
        let (mut s, _) = session(Limits::default());

        // original_len below the captured length: a reader drops this packet
        // while exiting 0, so it must never be written.
        let data = [0u8; 40];
        let bad = Frame {
            interface_id: 0,
            timestamp_ns: 1,
            data: &data,
            original_len: 39,
        };
        assert_eq!(s.offer(bad, Duration::ZERO), Offered::Refused);
        assert!(!s.is_closed(), "one bad frame does not end the session");

        // ...and a good frame still works afterwards.
        assert!(matches!(
            s.offer(frame(&[0u8; 64]), Duration::ZERO),
            Offered::Encoded(_)
        ));
    }

    #[test]
    fn completeness_requires_our_count_to_match_the_kernels() {
        let (mut s, _) = session(Limits::default());
        for _ in 0..3 {
            assert!(matches!(
                s.offer(frame(&[0u8; 64]), Duration::ZERO),
                Offered::Encoded(_)
            ));
        }

        // Agreement: 3 encoded, kernel saw 3 with no drops.
        let mut agreeing = CaptureSession::begin(vec![IFACE.into()], 65_535, Limits::default()).0;
        for _ in 0..3 {
            let _ = agreeing.offer(frame(&[0u8; 64]), Duration::ZERO);
        }
        let t = agreeing.finish(CaptureTerminationReason::ClientCancel, clean_stats(3));
        assert!(t.complete);
        assert_eq!(t.packets_captured, 3);

        // Disagreement: the kernel counted 5 delivered, we wrote 3. Nothing
        // errored; two frames vanished between the ring and the encoder.
        let t = s.finish(CaptureTerminationReason::ClientCancel, clean_stats(5));
        assert!(
            !t.complete,
            "a count mismatch is data loss and must not report complete"
        );
    }

    #[test]
    fn a_capped_session_is_not_judged_by_a_count_it_does_not_control() {
        // The kernel keeps filling the block being walked when a cap trips, so
        // its count runs ahead of ours by however many frames happened to be in
        // flight. Comparing them makes `complete` depend on where in a block the
        // cap fell -- a coin flip on every capped capture, which would train an
        // operator to ignore the flag that exists to mean "frames vanished".
        let (mut s, _) = session(Limits {
            byte_cap: Some(60 + 200),
            ..Default::default()
        });
        let mut packets = 0u64;
        while !s.is_closed() {
            if let Offered::Encoded(_) = s.offer(frame(&[0u8; 64]), Duration::ZERO) {
                packets += 1;
            }
        }

        let t = s.finish(
            CaptureTerminationReason::ClientCancel,
            clean_stats(packets + 37),
        );
        assert_eq!(t.reason, CaptureTerminationReason::ByteCap);
        assert!(
            t.complete,
            "a capped session with no drops is a complete capture of what was allowed"
        );

        // Drops still count, because those are real loss rather than the cap
        // doing its job.
        let (mut s, _) = session(Limits {
            byte_cap: Some(60 + 200),
            ..Default::default()
        });
        while !s.is_closed() {
            let _ = s.offer(frame(&[0u8; 64]), Duration::ZERO);
        }
        let t = s.finish(
            CaptureTerminationReason::ClientCancel,
            Stats {
                captured: packets,
                dropped: 9,
                malformed: 0,
            },
        );
        assert!(
            !t.complete,
            "a capped session that dropped packets is not complete"
        );
        assert_eq!(t.packets_dropped, 9);
    }

    #[test]
    fn drops_and_malformed_frames_both_count_against_completeness() {
        let (mut s, _) = session(Limits::default());
        let _ = s.offer(frame(&[0u8; 64]), Duration::ZERO);

        // The kernel delivered 1 and dropped 3.
        let stats = Stats {
            captured: 1,
            dropped: 3,
            malformed: 0,
        };
        let t = s.finish(CaptureTerminationReason::ClientCancel, stats);
        assert_eq!(t.packets_dropped, 3);
        assert!(
            !t.complete,
            "a session that dropped packets is not complete"
        );
    }

    #[test]
    fn limits_read_the_proto_zero_as_unset() {
        // 0 is the proto3 default, so it is what an unset field sends. Reading
        // it as a zero cap would end every session before its first frame.
        let none = Limits::from_wire(0, 0);
        assert!(none.duration.is_none() && none.byte_cap.is_none());

        let both = Limits::from_wire(30, 1_048_576);
        assert_eq!(both.duration, Some(Duration::from_secs(30)));
        assert_eq!(both.byte_cap, Some(1_048_576));
    }
}
