//! The loop that turns a ring into a pcapng stream.
//!
//! Everything here is about *when to stop*, which is the part a real ring makes
//! impossible to test: reproducing "a cap fired mid-block", "the client vanished
//! between two frames" or "the ring went quiet for a minute" against live
//! traffic means either sleeping for the real durations or asserting nothing.
//!
//! So the loop reads through [`FrameSource`] and takes its clock and its stop
//! signal as parameters. `Ring` implements the trait in one line; the tests
//! drive a scripted fake and assert the exact frame at which each rule takes
//! effect.
//!
//! # The two stop paths are not symmetric
//!
//! * A **cancel** — the client went away, or upstream asked to stop — keeps
//!   encoding while the loop drains for one `tp_retire_blk_tov`. Frames the
//!   kernel already counted are sitting in a partially filled block, and
//!   stopping the instant the request arrives silently truncates the capture by
//!   up to that timeout.
//! * A **cap** stops at once and encodes nothing further. Refusing everything
//!   past the operator's limit is the entire point, so there is nothing to
//!   drain for.
//!
//! # A stop signal is checked more often than frames arrive
//!
//! Teardown latency is bounded by the poll timeout, not by traffic. A capture
//! on a silent interface still notices a disconnect in one
//! [`RunConfig::poll_interval`] — otherwise a session on an idle interface
//! holds its ring open indefinitely after its client is gone, which is the
//! shape task 2.5 exists to prevent.

use std::time::Duration;

use serviceradar_afpacket::{Frame as RingFrame, Ring, Stats};

use super::{
    pcapng::Frame as PcapngFrame,
    request::{DirectionFilter, ValidatedRequest},
    session::{CaptureSession, Offered},
};
use crate::proto::netprobe::CaptureTerminationReason;

/// Where the loop reads frames from.
///
/// A trait so the stop rules can be tested. Mirrors [`Ring`]'s three methods
/// exactly rather than inventing an abstraction: anything richer here would be
/// a second thing to keep in sync with the ring.
pub trait FrameSource {
    /// Sleep until frames are ready or `timeout` elapses. `false` means the
    /// timeout or a signal, both of which mean "check the stop signal".
    fn wait(&self, timeout: Duration) -> bool;

    /// Hand every frame in the next ready block to `visit`, or return `None`
    /// when no block is ready.
    fn drain_block(&mut self, visit: &mut dyn FnMut(RingFrame<'_>)) -> Option<usize>;

    /// Fold the kernel's counters into the session totals. Resets the kernel
    /// side, so it has exactly one caller.
    fn refresh_stats(&mut self) -> Stats;
}

impl FrameSource for Ring {
    fn wait(&self, timeout: Duration) -> bool {
        Ring::wait(self, timeout)
    }

    fn drain_block(&mut self, visit: &mut dyn FnMut(RingFrame<'_>)) -> Option<usize> {
        Ring::drain_block(self, visit)
    }

    fn refresh_stats(&mut self) -> Stats {
        // A failed statistics read must not end a capture that is otherwise
        // working. The last good totals are returned instead, and the session's
        // completeness flag is what tells an operator the numbers are suspect.
        Ring::refresh_stats(self).unwrap_or_else(|err| {
            log::warn!("capture: PACKET_STATISTICS read failed: {err}");
            Ring::stats(self)
        })
    }
}

/// Timing knobs, separated from the request so a test can shrink them.
#[derive(Debug, Clone, Copy)]
pub struct RunConfig {
    /// How long a quiet poll blocks, and therefore the worst-case delay
    /// between a stop being signalled and the loop noticing it.
    pub poll_interval: Duration,
    /// How long to keep draining after a cancel. Should be at least the ring's
    /// `retire_timeout_ms`, which is how long the kernel may sit on a
    /// partially filled block.
    pub drain_grace: Duration,
}

impl Default for RunConfig {
    fn default() -> Self {
        Self {
            // Well inside the 5 s teardown budget, and cheap: a quiet interface
            // wakes four times a second to check one atomic.
            poll_interval: Duration::from_millis(250),
            // The default `RingConfig::retire_timeout_ms`.
            drain_grace: Duration::from_millis(100),
        }
    }
}

/// Why the caller wants the loop to stop.
///
/// Returned by the stop signal rather than assumed, because "the client hung
/// up" and "an operator pressed stop" are different lines in an audit trail and
/// the loop cannot tell them apart.
pub type StopSignal<'a> = dyn Fn() -> Option<CaptureTerminationReason> + 'a;

/// Receives encoded pcapng bytes. Returning `false` means the far side is gone,
/// which ends the session as an agent disconnect.
pub type BlockSink<'a> = dyn FnMut(Vec<u8>) -> bool + 'a;

/// Reports elapsed time since the session began.
pub type Clock<'a> = dyn Fn() -> Duration + 'a;

/// Run one capture session to completion.
///
/// `header` from [`CaptureSession::begin`] must already have been sent; this
/// takes the session after that, so the caller can fail the request before any
/// bytes reach the wire.
pub fn run<S: FrameSource + ?Sized>(
    source: &mut S,
    mut session: CaptureSession,
    request: &ValidatedRequest,
    config: RunConfig,
    clock: &Clock<'_>,
    stop: &StopSignal<'_>,
    sink: &mut BlockSink<'_>,
) -> (CaptureTerminationReason, Stats, CaptureSession) {
    let direction: DirectionFilter = request.direction;
    let mut reason = CaptureTerminationReason::ClientCancel;
    // Set once a stop is requested; the loop then drains for `drain_grace`
    // rather than returning, so frames already counted by the kernel are not
    // silently discarded.
    let mut draining_until: Option<Duration> = None;

    loop {
        if session.is_closed() {
            // A cap. Nothing past it may be emitted, so there is nothing to
            // drain for -- see the module docs.
            break;
        }

        if draining_until.is_none()
            && let Some(requested) = stop()
        {
            reason = requested;
            draining_until = Some(clock() + config.drain_grace);
        }

        if let Some(deadline) = draining_until
            && clock() >= deadline
        {
            break;
        }

        // While draining, poll briefly: the grace period is the budget, and
        // sleeping a full interval inside it would spend most of the budget
        // asleep.
        let timeout = if draining_until.is_some() {
            config.drain_grace.min(config.poll_interval) / 4
        } else {
            config.poll_interval
        };
        if !source.wait(timeout) {
            continue;
        }

        let mut encoded: Vec<Vec<u8>> = Vec::new();
        let mut hit_cap = false;
        source.drain_block(&mut |frame| {
            if hit_cap || !direction.keeps(frame.direction) {
                return;
            }
            match session.offer(
                PcapngFrame {
                    // v1 is one interface per session, so every frame belongs
                    // to the single IDB written by `begin`.
                    interface_id: 0,
                    timestamp_ns: frame.timestamp_ns,
                    data: frame.data,
                    original_len: frame.original_len,
                },
                clock(),
            ) {
                Offered::Encoded(block) => encoded.push(block),
                // The encoder refused one frame -- see `Offered::Refused`. The
                // session continues; the count mismatch is what surfaces it.
                Offered::Refused => {}
                Offered::Closed => hit_cap = true,
            }
        });

        for block in encoded {
            if !sink(block) {
                // The consumer is gone. Stop now rather than draining: there is
                // nowhere left to put what we would drain.
                let stats = source.refresh_stats();
                return (CaptureTerminationReason::AgentDisconnect, stats, session);
            }
        }
    }

    let stats = source.refresh_stats();
    (reason, stats, session)
}

#[cfg(test)]
mod tests {
    use std::{
        cell::{Cell, RefCell},
        collections::VecDeque,
        rc::Rc,
        time::Duration,
    };

    use serviceradar_afpacket::Direction;

    use super::*;
    use crate::capture::{
        bpf::{Instruction, MAX_SNAPLEN, Program},
        session::Limits,
    };

    const MS: Duration = Duration::from_millis(1);

    /// A clock the ring advances, not the observer.
    ///
    /// The distinction matters: the loop reads the clock several times per
    /// iteration, so a clock that ticked on every *read* would let the number
    /// of reads decide when a cap fires -- an implementation detail dictating a
    /// test outcome. Here time passes when a poll blocks and when frames
    /// arrive, which is what happens on a real host.
    #[derive(Default)]
    struct TestClock(Cell<Duration>);

    impl TestClock {
        fn now(&self) -> Duration {
            self.0.get()
        }

        fn advance(&self, by: Duration) {
            self.0.set(self.0.get() + by);
        }
    }

    /// One scripted step of the fake ring.
    #[derive(Clone, Copy)]
    enum Step {
        /// A block of this many 64-byte frames, all inbound.
        Block(usize),
        /// A block whose frames all travel this way.
        Directed(usize, Direction),
        /// One poll during which no block was ready.
        Quiet,
    }

    type Script = Rc<RefCell<VecDeque<Step>>>;

    /// A ring whose contents and timing the test writes down.
    ///
    /// The script is shared with the test rather than owned, because the stop
    /// signal has to be able to fire when it runs out: a real ring never
    /// empties, so a loop that ended only when its source did would be
    /// exercising something that cannot happen in production.
    struct FakeSource {
        script: Script,
        clock: Rc<TestClock>,
        /// How long a poll takes. Nonzero so a quiet source still reaches a
        /// deadline.
        poll_advance: Duration,
        /// How long each frame takes to arrive. Zero unless a test is about
        /// the duration cap.
        frame_advance: Duration,
        /// Frames the "kernel" delivered, including ones the session refused.
        delivered: Cell<u64>,
        dropped: u64,
        polls: Cell<usize>,
    }

    impl FakeSource {
        fn new(steps: Vec<Step>) -> (Self, Script, Rc<TestClock>) {
            let script: Script = Rc::new(RefCell::new(steps.into()));
            let clock = Rc::new(TestClock::default());
            (
                Self {
                    script: Rc::clone(&script),
                    clock: Rc::clone(&clock),
                    poll_advance: MS,
                    frame_advance: Duration::ZERO,
                    delivered: Cell::new(0),
                    dropped: 0,
                    polls: Cell::new(0),
                },
                script,
                clock,
            )
        }

        fn script_len(&self) -> usize {
            self.script.borrow().len()
        }
    }

    impl FrameSource for FakeSource {
        fn wait(&self, _timeout: Duration) -> bool {
            self.polls.set(self.polls.get() + 1);
            self.clock.advance(self.poll_advance);
            // A quiet step is CONSUMED here. A `wait` that reported "not ready"
            // without removing it would make every quiet-source test spin
            // forever instead of failing, and a hanging test reports nothing.
            let mut script = self.script.borrow_mut();
            match script.front() {
                Some(Step::Quiet) => {
                    script.pop_front();
                    false
                }
                Some(_) => true,
                None => false,
            }
        }

        fn drain_block(&mut self, visit: &mut dyn FnMut(RingFrame<'_>)) -> Option<usize> {
            let step = self.script.borrow_mut().pop_front()?;
            let (count, direction) = match step {
                Step::Block(n) => (n, Direction::Inbound),
                Step::Directed(n, d) => (n, d),
                Step::Quiet => return None,
            };
            let data = [0u8; 64];
            for i in 0..count {
                self.clock.advance(self.frame_advance);
                // Counted before `visit`, because the kernel counts a frame it
                // delivered whether or not the session keeps it.
                self.delivered.set(self.delivered.get() + 1);
                visit(RingFrame {
                    data: &data,
                    original_len: 64,
                    timestamp_ns: 1_700_000_000_000_000_000 + i as u64,
                    direction,
                    ifindex: 1,
                });
            }
            Some(count)
        }

        fn refresh_stats(&mut self) -> Stats {
            Stats {
                captured: self.delivered.get(),
                dropped: self.dropped,
                malformed: 0,
            }
        }
    }

    fn request(direction: DirectionFilter) -> ValidatedRequest {
        ValidatedRequest {
            session_id: "01JQ0000000000000000000000".into(),
            actor: "operator@example.com".into(),
            interfaces: vec!["eth0".into()],
            program: Program::new(vec![Instruction::accept(MAX_SNAPLEN)]).unwrap(),
            snaplen: MAX_SNAPLEN,
            limits: Limits::default(),
            direction,
            promiscuous: false,
        }
    }

    fn config() -> RunConfig {
        RunConfig {
            poll_interval: MS,
            drain_grace: 4 * MS,
        }
    }

    fn session(limits: Limits) -> CaptureSession {
        CaptureSession::begin(vec!["eth0".into()], MAX_SNAPLEN, limits).0
    }

    /// Stops once the script is exhausted, standing in for the upstream cancel
    /// that ends a real session.
    fn stop_when_drained(script: &Script) -> impl Fn() -> Option<CaptureTerminationReason> + '_ {
        move || {
            script
                .borrow()
                .is_empty()
                .then_some(CaptureTerminationReason::ClientCancel)
        }
    }

    fn never_stop() -> Option<CaptureTerminationReason> {
        None
    }

    #[test]
    fn every_frame_in_a_block_is_encoded() {
        let (mut source, script, clock) = FakeSource::new(vec![Step::Block(3), Step::Block(2)]);
        let mut blocks: Vec<Vec<u8>> = Vec::new();

        let (reason, stats, session) = run(
            &mut source,
            session(Limits::default()),
            &request(DirectionFilter::Both),
            config(),
            &|| clock.now(),
            &stop_when_drained(&script),
            &mut |block| {
                blocks.push(block);
                true
            },
        );

        assert_eq!(blocks.len(), 5, "one EPB per frame");
        assert_eq!(reason, CaptureTerminationReason::ClientCancel);
        let termination = session.finish(reason, stats);
        assert_eq!(termination.packets_captured, 5);
        assert!(termination.complete, "counts agree and nothing dropped");
    }

    #[test]
    fn a_direction_filter_drops_frames_the_kernel_still_counted() {
        // The mismatch is the point: the kernel delivered 4, the session kept
        // 2, and `complete` must say so rather than presenting a clean capture
        // of half the traffic.
        let (mut source, script, clock) = FakeSource::new(vec![
            Step::Directed(2, Direction::Inbound),
            Step::Directed(2, Direction::Outbound),
        ]);
        let mut count = 0usize;

        let (reason, stats, session) = run(
            &mut source,
            session(Limits::default()),
            &request(DirectionFilter::Ingress),
            config(),
            &|| clock.now(),
            &stop_when_drained(&script),
            &mut |_| {
                count += 1;
                true
            },
        );

        assert_eq!(count, 2, "only inbound frames were encoded");
        assert_eq!(stats.captured, 4, "the kernel counted all four");
        assert!(!session.finish(reason, stats).complete);
    }

    #[test]
    fn a_cap_stops_the_loop_without_draining_further() {
        // 60 bytes of header plus room for a couple of packets. The script has
        // far more waiting; none of it may be emitted.
        let (mut source, script, clock) = FakeSource::new(vec![Step::Block(4), Step::Block(100)]);
        let mut count = 0usize;

        let (reason, stats, session) = run(
            &mut source,
            session(Limits {
                byte_cap: Some(60 + 200),
                ..Default::default()
            }),
            &request(DirectionFilter::Both),
            config(),
            &|| clock.now(),
            &stop_when_drained(&script),
            &mut |_| {
                count += 1;
                true
            },
        );

        assert!(
            count > 0 && count < 4,
            "the cap bounded the output inside the first block: {count}"
        );
        assert_eq!(source.script_len(), 1, "the second block was never drained");
        // The loop reports the reason it was given; `finish` substitutes the
        // cap that actually stopped the session.
        assert_eq!(
            session.finish(reason, stats).reason,
            CaptureTerminationReason::ByteCap
        );
    }

    #[test]
    fn a_cancel_keeps_encoding_through_the_drain_grace() {
        // The failure this guards: stopping the instant a cancel arrives
        // discards frames the kernel already counted and already delivered,
        // truncating the capture by up to one retire timeout with no error.
        let (mut source, _script, clock) = FakeSource::new(vec![Step::Block(2), Step::Block(3)]);
        let mut count = 0usize;

        let (reason, _, _) = run(
            &mut source,
            session(Limits::default()),
            &request(DirectionFilter::Both),
            config(),
            &|| clock.now(),
            // Cancelled from the very first check, before any frame is read.
            &|| Some(CaptureTerminationReason::ClientCancel),
            &mut |_| {
                count += 1;
                true
            },
        );

        assert_eq!(
            count, 5,
            "both blocks were drained and encoded after the cancel"
        );
        assert_eq!(reason, CaptureTerminationReason::ClientCancel);
    }

    #[test]
    fn the_drain_grace_ends_even_on_a_source_that_never_goes_quiet() {
        // Otherwise a busy interface holds its ring open indefinitely after its
        // client is gone -- the failure task 2.5 names, and one that gets worse
        // the more traffic there is.
        let (mut source, _script, clock) =
            FakeSource::new((0..1_000).map(|_| Step::Block(1)).collect());
        let mut count = 0usize;

        let (reason, _, _) = run(
            &mut source,
            session(Limits::default()),
            &request(DirectionFilter::Both),
            config(),
            &|| clock.now(),
            &|| Some(CaptureTerminationReason::ClientCancel),
            &mut |_| {
                count += 1;
                true
            },
        );

        assert!(
            count < 1_000,
            "the grace period must end the loop, not the script running dry: {count}"
        );
        assert_eq!(reason, CaptureTerminationReason::ClientCancel);
    }

    #[test]
    fn a_quiet_interface_still_notices_a_stop() {
        // A capture with no traffic must not hold its ring until traffic
        // happens to arrive. The stop signal is checked every poll, so a silent
        // source ends on schedule rather than on the next packet.
        let (mut source, _script, clock) = FakeSource::new(vec![Step::Quiet; 64]);
        let consulted = Cell::new(0usize);

        let (reason, _, _) = run(
            &mut source,
            session(Limits::default()),
            &request(DirectionFilter::Both),
            config(),
            &|| clock.now(),
            &|| {
                consulted.set(consulted.get() + 1);
                Some(CaptureTerminationReason::AgentDisconnect)
            },
            &mut |_| true,
        );

        assert_eq!(reason, CaptureTerminationReason::AgentDisconnect);
        assert!(consulted.get() > 0, "the stop signal was consulted");
        assert!(
            source.polls.get() > 0,
            "the loop slept on the source rather than spinning"
        );
        assert!(
            source.script_len() > 0,
            "the loop stopped on its deadline, not by running the script dry"
        );
    }

    #[test]
    fn a_vanished_consumer_ends_the_session_as_a_disconnect() {
        // Distinct from a cancel: nobody asked to stop, there is simply nowhere
        // left to put the bytes. Draining further would encode into a void.
        let (mut source, _script, clock) = FakeSource::new(vec![Step::Block(2), Step::Block(50)]);

        let (reason, _, _) = run(
            &mut source,
            session(Limits::default()),
            &request(DirectionFilter::Both),
            config(),
            &|| clock.now(),
            &never_stop,
            &mut |_| false,
        );

        assert_eq!(reason, CaptureTerminationReason::AgentDisconnect);
        assert_eq!(
            source.script_len(),
            1,
            "the loop stopped instead of draining into a closed sink"
        );
    }

    #[test]
    fn the_duration_cap_ends_the_loop_on_the_frame_that_crosses_it() {
        // Not at the block boundary: a 100-frame block with a cap 9 frames in
        // must emit 8, or the operator's limit is whatever the ring geometry
        // happens to be.
        let (mut source, script, clock) = FakeSource::new(vec![Step::Block(100), Step::Block(100)]);
        source.frame_advance = MS;
        let mut count = 0usize;

        let (reason, stats, session) = run(
            &mut source,
            session(Limits {
                duration: Some(10 * MS),
                ..Default::default()
            }),
            &request(DirectionFilter::Both),
            config(),
            &|| clock.now(),
            &stop_when_drained(&script),
            &mut |_| {
                count += 1;
                true
            },
        );

        // One poll (1 ms) then one frame per millisecond: the ninth frame is
        // offered at exactly 10 ms and is the first refused.
        assert_eq!(count, 8, "the cap fired mid-block, on the crossing frame");
        assert_eq!(source.script_len(), 1, "the second block was never drained");
        let termination = session.finish(reason, stats);
        assert_eq!(termination.reason, CaptureTerminationReason::DurationCap);
        assert!(
            termination.complete,
            "a capped session with no drops is complete"
        );
    }

    #[test]
    fn a_session_that_dropped_packets_never_reports_complete() {
        // The ring overran. No syscall fails and nothing errors; this flag is
        // the only evidence.
        let (mut source, script, clock) = FakeSource::new(vec![Step::Block(4)]);
        source.dropped = 17;

        let (reason, stats, session) = run(
            &mut source,
            session(Limits::default()),
            &request(DirectionFilter::Both),
            config(),
            &|| clock.now(),
            &stop_when_drained(&script),
            &mut |_| true,
        );

        let termination = session.finish(reason, stats);
        assert_eq!(termination.packets_dropped, 17);
        assert!(!termination.complete);
    }
}
