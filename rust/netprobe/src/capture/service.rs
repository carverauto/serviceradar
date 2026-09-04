//! Session lifecycle: who may start one, how many run at once, and where the
//! descriptor goes afterwards.
//!
//! [`runner`](super::runner) knows when a session stops; this knows what a
//! session *costs*. The two concerns are separated because the expensive ones
//! here — a pre-opened descriptor, the single session slot — are exactly the
//! resources that leak when a stop path is missed, and a leak is invisible
//! until the next capture is refused for a reason that makes no sense.
//!
//! # The descriptor comes back on every path a session can take
//!
//! A capture descriptor is opened once, while privileged, and cannot be
//! reopened after netprobe drops to its runtime user (see [`super`]). So every
//! ordinary exit — a clean stop, a cap, a client disconnect, a rejected
//! request, a ring that refuses the filter, a thread that will not spawn — has
//! to return it, or that interface is dead until netprobe restarts.
//!
//! The two resources are owned separately and released in a fixed order.
//! `SlotClaim` frees the concurrency slot on drop, so a start that fails
//! *after* claiming it does not leak the slot; `SessionGuard` restores the
//! descriptor explicitly and holds the claim, so the slot is never free while
//! its descriptor is still out.
//!
//! What this does NOT recover is a descriptor consumed by a panicking capture
//! thread: that frame owns the ring, and unwinding closes it. Claiming
//! otherwise would be worse than the gap, so the guard says so in the log
//! instead — without that line the only symptom is a `capture_session_active`
//! refusal naming an interface with no session on it.

use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicU8, Ordering},
    },
    time::{Duration, Instant},
};

use serviceradar_afpacket::{Ring, RingConfig, Socket};

use super::{
    CaptureError, CaptureHandles,
    request::{self, Rejection, ValidatedRequest},
    runner::{self, FrameSource, RunConfig},
    session::CaptureSession,
};
use crate::proto::netprobe::{CaptureTerminationReason, PcapngBlock, StartRemoteCapture};

/// Why a session could not be started, beyond the request being invalid.
#[derive(Debug, thiserror::Error)]
pub enum StartError {
    #[error(transparent)]
    Rejected(#[from] Rejection),

    #[error(transparent)]
    Descriptor(#[from] CaptureError),

    /// v1 runs one capture per netprobe instance.
    #[error(
        "a capture session is already running on this netprobe ({0}); v1 runs one at a time, so wait for it to end or stop it"
    )]
    AlreadyCapturing(String),

    #[error("failed to arm the capture ring on {interface}: {source}")]
    Activate {
        interface: String,
        #[source]
        source: anyhow::Error,
    },
}

impl StartError {
    /// A stable, greppable identifier for the `ErrorFrame`.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Rejected(rejection) => rejection.code(),
            Self::Descriptor(CaptureError::NotAllowlisted(_)) => "capture_interface_denied",
            Self::Descriptor(CaptureError::NotPreOpened(_)) => "capture_restart_required",
            Self::Descriptor(CaptureError::AlreadyInUse(_)) | Self::AlreadyCapturing(_) => {
                "capture_session_active"
            }
            Self::Activate { .. } => "capture_ring_failed",
        }
    }
}

/// Turns a pre-opened descriptor into something the runner can read.
///
/// A trait for the same reason [`super::CaptureOpener`] is one: the session
/// rules worth testing — the concurrency cap, the descriptor coming back on
/// every exit path — need neither a NIC nor root, and a test that needs both
/// runs nowhere.
pub trait RingActivator: Send + Sync + 'static {
    type Handle: Send + 'static;
    type Source: FrameSource + Send + 'static;

    /// Attach the filter, arm the ring and bind.
    ///
    /// On failure the descriptor comes BACK in the error, because it was opened
    /// while privileged and cannot be reopened: consuming it on a bad filter
    /// would disable capture on that interface for the life of the process.
    fn activate(
        &self,
        handle: Self::Handle,
        request: &ValidatedRequest,
    ) -> Result<Self::Source, (Self::Handle, anyhow::Error)>;

    /// Tear the ring down, recovering the descriptor.
    fn release(&self, source: Self::Source) -> Self::Handle;
}

/// The production activator.
#[derive(Debug, Default)]
pub struct AfPacketActivator {
    pub ring: RingConfig,
}

impl RingActivator for AfPacketActivator {
    type Handle = Socket;
    type Source = Ring;

    fn activate(
        &self,
        handle: Socket,
        request: &ValidatedRequest,
    ) -> Result<Ring, (Socket, anyhow::Error)> {
        let filter: Vec<(u16, u8, u8, u32)> = request
            .program
            .instructions()
            .iter()
            .map(|insn| (insn.code, insn.jt, insn.jf, insn.k))
            .collect();

        handle.activate(self.ring, &filter).map_err(|err| {
            // `ActivateError` carries the descriptor back deliberately; see
            // the trait's doc.
            let message = anyhow::anyhow!("{}", err.error);
            (err.socket, message)
        })
    }

    fn release(&self, source: Ring) -> Socket {
        source.into_socket()
    }
}

/// Cancellation, shared with the capture thread.
///
/// An atomic rather than a channel because the capture thread checks it on
/// every poll and must never block doing so: a stop signal that could itself
/// wait is a stop signal that can be delayed by the thing it is stopping.
#[derive(Debug, Default)]
pub struct Cancel(AtomicU8);

impl Cancel {
    /// `CaptureTerminationReason::Unspecified` is 0, which is also the initial
    /// value, so "not cancelled" and "cancelled for no stated reason" cannot
    /// collide.
    pub fn request(&self, reason: CaptureTerminationReason) {
        let code = u8::try_from(i32::from(reason)).unwrap_or(0);
        // Only the first cancel wins: a client that disconnects during an
        // operator-initiated stop did not cause the stop.
        let _ = self
            .0
            .compare_exchange(0, code, Ordering::Release, Ordering::Relaxed);
    }

    pub fn requested(&self) -> Option<CaptureTerminationReason> {
        match self.0.load(Ordering::Acquire) {
            0 => None,
            code => Some(
                CaptureTerminationReason::try_from(i32::from(code))
                    .unwrap_or(CaptureTerminationReason::ClientCancel),
            ),
        }
    }
}

/// What a caller gets when a session starts.
#[derive(Debug)]
pub struct StartedSession {
    pub session_id: String,
    /// The pcapng header, already encoded. Sent before any packet block.
    pub header: PcapngBlock,
    /// Stop the session. Dropping this also stops it, so a caller that loses
    /// track of a session does not leave it running.
    pub cancel: Arc<Cancel>,
}

impl Drop for StartedSession {
    fn drop(&mut self) {
        self.cancel
            .request(CaptureTerminationReason::AgentDisconnect);
    }
}

/// Starts and accounts for capture sessions.
pub struct CaptureService<A: RingActivator> {
    handles: Arc<Mutex<CaptureHandles<A::Handle>>>,
    activator: Arc<A>,
    /// The interface of the running session, or `None`. This is the v1
    /// concurrency cap, and it is deliberately coarser than
    /// [`CaptureHandles::take`]'s per-interface exclusion: two sessions on two
    /// different interfaces would each want a ring, a poll and a share of the
    /// IPC socket's write budget, and nothing upstream asks for that yet.
    active: Arc<Mutex<Option<String>>>,
    run: RunConfig,
}

impl<A: RingActivator> CaptureService<A> {
    pub fn new(handles: Arc<Mutex<CaptureHandles<A::Handle>>>, activator: A) -> Self {
        Self {
            handles,
            activator: Arc::new(activator),
            active: Arc::new(Mutex::new(None)),
            run: RunConfig::default(),
        }
    }

    #[cfg(test)]
    fn with_run_config(mut self, run: RunConfig) -> Self {
        self.run = run;
        self
    }

    /// Whether a session is running, for the add-on status surface.
    pub fn active_interface(&self) -> Option<String> {
        self.active.lock().expect("capture slot").clone()
    }

    /// Validate, claim the resources, arm the ring and spawn the capture.
    ///
    /// Blocks are sent to `sink` from a dedicated OS thread: the ring poll is a
    /// blocking syscall, and running it on the async runtime would stall every
    /// other IPC client behind one quiet interface.
    pub fn start<S>(
        &self,
        request: &StartRemoteCapture,
        sink: S,
    ) -> Result<StartedSession, StartError>
    where
        S: BlockSender + Send + 'static,
    {
        let allowlist = self
            .handles
            .lock()
            .expect("capture handles")
            .allowlist()
            .to_vec();
        let validated = request::validate(request, &allowlist)?;
        let interface = validated.interfaces[0].clone();

        // Claimed BEFORE the descriptor, so a refused second session leaves the
        // first one's descriptor untouched.
        let claim = SlotClaim::acquire(&self.active, &interface)?;

        let handle = self
            .handles
            .lock()
            .expect("capture handles")
            .take(&interface)?;

        let source = match self.activator.activate(handle, &validated) {
            Ok(source) => source,
            Err((handle, source_err)) => {
                // The descriptor goes back before the error does, and the slot
                // is released by `claim` going out of scope with it. Every
                // early return past this point owns a descriptor that cannot be
                // reopened.
                self.handles
                    .lock()
                    .expect("capture handles")
                    .restore(&interface, handle);
                drop(claim);
                return Err(StartError::Activate {
                    interface,
                    source: source_err,
                });
            }
        };

        let (session, header) = CaptureSession::begin(
            validated.interfaces.clone(),
            validated.snaplen,
            validated.limits,
        );

        let cancel = Arc::new(Cancel::default());
        let guard = SessionGuard::<A> {
            handles: Arc::clone(&self.handles),
            interface: interface.clone(),
            restored: false,
            _claim: claim,
        };

        let thread = CaptureThread {
            activator: Arc::clone(&self.activator),
            cancel: Arc::clone(&cancel),
            run: self.run,
            validated,
            session,
            source,
            guard,
            sink,
        };

        let session_id = request.session_id.clone();
        // Named so a `ps -T` or a thread dump on the captured host says which
        // session is holding the ring. Truncated because Linux caps a thread
        // name at 15 bytes and silently refuses a longer one.
        let thread_name = format!("capture-{}", &session_id[..session_id.len().min(7)]);
        std::thread::Builder::new()
            .name(thread_name)
            .spawn(move || thread.run())
            .map_err(|err| StartError::Activate {
                interface,
                source: anyhow::anyhow!("failed to spawn the capture thread: {err}"),
            })?;

        Ok(StartedSession {
            session_id: session_id.clone(),
            header: PcapngBlock {
                session_id,
                bytes: header,
                ..Default::default()
            },
            cancel,
        })
    }
}

/// Where encoded blocks go. A trait rather than a channel type so the service
/// does not care whether the far side is async, and so a test can observe the
/// stream without one.
pub trait BlockSender {
    /// Returns `false` when the far side is gone, which ends the session as an
    /// agent disconnect.
    fn send(&mut self, block: PcapngBlock) -> bool;
}

/// Holds the single session slot, and releases it on drop.
///
/// The release lives HERE rather than in `SessionGuard` because a start can
/// fail after the slot is claimed and before a guard exists -- a ring that
/// refuses the filter, a thread that will not spawn. A claim released only by
/// the guard leaks the slot on exactly those paths, and the symptom is every
/// later capture refused as "already running" against a session that never
/// started.
struct SlotClaim {
    active: Arc<Mutex<Option<String>>>,
}

impl SlotClaim {
    fn acquire(active: &Arc<Mutex<Option<String>>>, interface: &str) -> Result<Self, StartError> {
        let mut slot = active.lock().expect("capture slot");
        if let Some(running) = slot.as_ref() {
            return Err(StartError::AlreadyCapturing(running.clone()));
        }
        *slot = Some(interface.to_string());
        Ok(Self {
            active: Arc::clone(active),
        })
    }
}

impl Drop for SlotClaim {
    fn drop(&mut self) {
        *self.active.lock().expect("capture slot") = None;
    }
}

/// Owns the session's two scarce resources for its lifetime.
///
/// Holding the slot claim here is what makes the ordering right: the
/// descriptor is restored explicitly, and only then does the guard drop and
/// free the slot. The reverse order would let a caller that saw the slot open
/// start a session and be refused with `AlreadyInUse` on a descriptor that was
/// about to come back.
struct SessionGuard<A: RingActivator> {
    handles: Arc<Mutex<CaptureHandles<A::Handle>>>,
    interface: String,
    restored: bool,
    /// Dropped after `restored` is set, releasing the slot.
    _claim: SlotClaim,
}

impl<A: RingActivator> SessionGuard<A> {
    /// Hand the descriptor back. Must happen before the guard drops.
    fn restore(&mut self, handle: A::Handle) {
        self.handles
            .lock()
            .expect("capture handles")
            .restore(&self.interface, handle);
        self.restored = true;
    }
}

impl<A: RingActivator> Drop for SessionGuard<A> {
    fn drop(&mut self) {
        if !self.restored {
            // Reached only if the capture thread died in a way that consumed
            // the descriptor. It cannot be reopened after the privilege drop,
            // so capture on this interface is over until netprobe restarts --
            // and without this line the only symptom would be a
            // `capture_session_active` on an interface with no session.
            log::error!(
                "capture on {} is unavailable until netprobe restarts: its pre-opened descriptor was not returned",
                self.interface
            );
        }
    }
}

/// Everything the capture thread owns.
struct CaptureThread<A: RingActivator, S: BlockSender> {
    activator: Arc<A>,
    cancel: Arc<Cancel>,
    run: RunConfig,
    validated: ValidatedRequest,
    session: CaptureSession,
    source: A::Source,
    guard: SessionGuard<A>,
    sink: S,
}

impl<A: RingActivator, S: BlockSender> CaptureThread<A, S> {
    fn run(mut self) {
        let session_id = self.validated.session_id.clone();
        let interface = self.validated.interfaces[0].clone();

        // The host's own record, independent of anything the control plane
        // stores (design.md D8.6). If core is compromised or its rows are
        // altered, this line still exists on the machine that was captured.
        log::info!(
            "capture session {session_id} started: interface={interface} actor={} snaplen={} filter_insns={} duration_s={:?} byte_cap={:?}",
            self.validated.actor,
            self.validated.snaplen,
            self.validated.program.len(),
            self.validated.limits.duration.map(|d| d.as_secs()),
            self.validated.limits.byte_cap,
        );

        let started = Instant::now();
        let cancel = Arc::clone(&self.cancel);
        let sink = &mut self.sink;
        let sid = session_id.clone();

        let (reason, stats, session) = runner::run(
            &mut self.source,
            self.session,
            &self.validated,
            self.run,
            &|| started.elapsed(),
            &|| cancel.requested(),
            &mut |bytes| {
                sink.send(PcapngBlock {
                    session_id: sid.clone(),
                    bytes,
                    ..Default::default()
                })
            },
        );

        let termination = session.finish(reason, stats);

        // The terminal block carries the counters, so a client that saw only
        // the stream still learns whether it is holding a complete capture.
        // Sent on a best-effort basis: the usual reason it fails is that the
        // client is the thing that ended the session.
        let delivered = self.sink.send(PcapngBlock {
            session_id: session_id.clone(),
            bytes: Vec::new(),
            r#final: true,
            termination_reason: termination.reason.into(),
            packets_captured: termination.packets_captured,
            packets_dropped: termination.packets_dropped,
            bytes_streamed: termination.bytes_streamed,
        });

        log::info!(
            "capture session {session_id} stopped: interface={interface} actor={} reason={:?} packets={} dropped={} bytes={} complete={} terminal_block_delivered={delivered}",
            self.validated.actor,
            termination.reason,
            termination.packets_captured,
            termination.packets_dropped,
            termination.bytes_streamed,
            termination.complete,
        );

        if !termination.complete {
            // Loud on purpose. A capture missing packets that presents as a
            // capture is the failure mode this whole path is built to avoid,
            // and an operator reading pcapng in Wireshark cannot see it.
            log::warn!(
                "capture session {session_id} is INCOMPLETE: {} packets dropped by the ring or lost before encoding; the pcapng stream is not a full record of what crossed {interface}",
                termination.packets_dropped
            );
        }

        let handle = self.activator.release(self.source);
        self.guard.restore(handle);
    }
}

/// The runner's default poll cadence, exposed so the IPC layer can state its
/// teardown budget in the same units.
pub const DEFAULT_TEARDOWN_BOUND: Duration = Duration::from_millis(250);

#[cfg(test)]
mod tests {
    use std::sync::mpsc;

    use super::*;
    use crate::{
        capture::{open_allowlisted_interfaces, runner::FrameSource},
        config::Config,
        proto::netprobe::{BpfInstruction, BpfProgram, start_remote_capture},
    };
    use serviceradar_afpacket::{Frame as RingFrame, Stats};

    /// A descriptor stand-in that remembers which interface it belongs to, so a
    /// test proves the RIGHT descriptor came back rather than merely that one
    /// did.
    #[derive(Debug, PartialEq, Eq)]
    struct FakeHandle(String);

    struct FakeOpener;

    impl crate::capture::CaptureOpener for FakeOpener {
        type Handle = FakeHandle;

        fn open(&self, interface: &str) -> anyhow::Result<FakeHandle> {
            Ok(FakeHandle(interface.to_string()))
        }
    }

    /// A source that yields nothing and relies on the stop signal, so a service
    /// test is about lifecycle rather than packets.
    struct QuietSource(FakeHandle);

    impl FrameSource for QuietSource {
        fn wait(&self, _timeout: Duration) -> bool {
            false
        }

        fn drain_block(&mut self, _visit: &mut dyn FnMut(RingFrame<'_>)) -> Option<usize> {
            None
        }

        fn refresh_stats(&mut self) -> Stats {
            Stats::default()
        }
    }

    #[derive(Default)]
    struct FakeActivator {
        /// When set, every activation fails -- the bad-filter case, where the
        /// descriptor must survive.
        fail: bool,
    }

    impl RingActivator for FakeActivator {
        type Handle = FakeHandle;
        type Source = QuietSource;

        fn activate(
            &self,
            handle: FakeHandle,
            _request: &ValidatedRequest,
        ) -> Result<QuietSource, (FakeHandle, anyhow::Error)> {
            if self.fail {
                return Err((handle, anyhow::anyhow!("the kernel refused the filter")));
            }
            Ok(QuietSource(handle))
        }

        fn release(&self, source: QuietSource) -> FakeHandle {
            source.0
        }
    }

    struct ChannelSink(mpsc::Sender<PcapngBlock>);

    impl BlockSender for ChannelSink {
        fn send(&mut self, block: PcapngBlock) -> bool {
            self.0.send(block).is_ok()
        }
    }

    fn service(fail: bool) -> CaptureService<FakeActivator> {
        let config = Config {
            enabled: true,
            capture_interfaces: vec!["eth0".to_string(), "eth1".to_string()],
            ..Default::default()
        };
        let handles = open_allowlisted_interfaces(&config, &FakeOpener).unwrap();
        CaptureService::new(Arc::new(Mutex::new(handles)), FakeActivator { fail }).with_run_config(
            RunConfig {
                poll_interval: Duration::from_millis(1),
                drain_grace: Duration::from_millis(1),
            },
        )
    }

    fn request(interface: &str) -> StartRemoteCapture {
        StartRemoteCapture {
            session_id: "01JQ0000000000000000000000".to_string(),
            actor: "operator@example.com".to_string(),
            interfaces: vec![interface.to_string()],
            filter: Some(start_remote_capture::Filter::FilterBpf(BpfProgram {
                instructions: vec![BpfInstruction {
                    code: 0x06,
                    jt: 0,
                    jf: 0,
                    k: 262_144,
                }],
            })),
            ..Default::default()
        }
    }

    /// Waits for the capture thread to release the slot. Bounded so a
    /// regression fails rather than hangs.
    fn wait_for_idle(service: &CaptureService<FakeActivator>) {
        for _ in 0..500 {
            if service.active_interface().is_none() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("the capture session never released its slot");
    }

    #[test]
    fn a_session_streams_a_header_then_a_terminal_block() {
        let service = service(false);
        let (tx, rx) = mpsc::channel();

        let started = service.start(&request("eth0"), ChannelSink(tx)).unwrap();
        assert!(
            !started.header.bytes.is_empty(),
            "the pcapng header is sent"
        );
        assert!(!started.header.r#final);
        assert_eq!(service.active_interface().as_deref(), Some("eth0"));

        started
            .cancel
            .request(CaptureTerminationReason::ClientCancel);
        let terminal = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(terminal.r#final, "the last block is marked final");
        assert_eq!(
            terminal.termination_reason,
            i32::from(CaptureTerminationReason::ClientCancel)
        );
        assert_eq!(terminal.session_id, "01JQ0000000000000000000000");

        wait_for_idle(&service);
    }

    #[test]
    fn a_second_session_is_refused_while_the_first_runs() {
        // v1 runs one capture per instance. The refusal names the interface
        // that is busy, because "try again" is not an operator action.
        let service = service(false);
        let (tx, _rx) = mpsc::channel();
        let started = service.start(&request("eth0"), ChannelSink(tx)).unwrap();

        let (tx2, _rx2) = mpsc::channel();
        let err = service
            .start(&request("eth1"), ChannelSink(tx2))
            .expect_err("a second session must be refused");
        assert_eq!(err.code(), "capture_session_active");
        assert!(format!("{err}").contains("eth0"));

        started
            .cancel
            .request(CaptureTerminationReason::ClientCancel);
        wait_for_idle(&service);
    }

    #[test]
    fn the_slot_and_the_descriptor_are_both_free_after_a_session_ends() {
        // The leak this guards is silent: the slot stays claimed, and every
        // later capture is refused as "already running" against a session that
        // ended minutes ago.
        let service = service(false);
        let (tx, rx) = mpsc::channel();
        let started = service.start(&request("eth0"), ChannelSink(tx)).unwrap();
        started
            .cancel
            .request(CaptureTerminationReason::ClientCancel);
        let _ = rx.recv_timeout(Duration::from_secs(5));
        wait_for_idle(&service);

        // Both resources are provably reusable: a second session on the SAME
        // interface needs the same descriptor back.
        let (tx2, _rx2) = mpsc::channel();
        let second = service
            .start(&request("eth0"), ChannelSink(tx2))
            .expect("the descriptor and the slot both came back");
        second
            .cancel
            .request(CaptureTerminationReason::ClientCancel);
        wait_for_idle(&service);
    }

    #[test]
    fn a_failed_ring_activation_returns_the_descriptor() {
        // The descriptor was opened while privileged and cannot be reopened, so
        // consuming it on a bad filter would disable capture on that interface
        // until netprobe restarts -- from a request the operator could simply
        // retype.
        let service = service(true);
        let (tx, _rx) = mpsc::channel();
        let err = service
            .start(&request("eth0"), ChannelSink(tx))
            .expect_err("activation was set to fail");
        assert_eq!(err.code(), "capture_ring_failed");

        assert!(
            service.active_interface().is_none(),
            "a failed start must not hold the session slot"
        );
        // Proof the descriptor came back rather than being lost: taking it
        // again succeeds, and would be `AlreadyInUse` if it had not.
        let taken = service
            .handles
            .lock()
            .unwrap()
            .take("eth0")
            .expect("the descriptor survived the failed activation");
        assert_eq!(taken, FakeHandle("eth0".to_string()));
    }

    #[test]
    fn an_invalid_request_never_reaches_a_descriptor() {
        // Ordering matters: validating after claiming would let a malformed
        // request take a descriptor out of service for the duration of its own
        // rejection.
        let service = service(false);
        let mut bad = request("eth0");
        bad.session_id = String::new();

        let (tx, _rx) = mpsc::channel();
        let err = service
            .start(&bad, ChannelSink(tx))
            .expect_err("an unattributed request is refused");
        assert_eq!(err.code(), "capture_unattributed");
        assert!(service.active_interface().is_none());
        assert!(
            service.handles.lock().unwrap().take("eth0").is_ok(),
            "the descriptor was never taken"
        );
    }

    #[test]
    fn an_interface_outside_the_allowlist_is_refused_before_the_slot_is_claimed() {
        let service = service(false);
        let (tx, _rx) = mpsc::channel();
        let err = service
            .start(&request("eth9"), ChannelSink(tx))
            .expect_err("eth9 is not allowlisted");
        assert_eq!(err.code(), "capture_interface_denied");
        assert!(service.active_interface().is_none());
    }

    #[test]
    fn dropping_the_session_handle_stops_the_capture() {
        // A caller that loses track of a session must not leave a ring armed
        // and an interface unavailable. There is no code path that "forgets"
        // to cancel, because the cancel is in `Drop`.
        let service = service(false);
        let (tx, rx) = mpsc::channel();
        drop(service.start(&request("eth0"), ChannelSink(tx)).unwrap());

        let terminal = rx
            .recv_timeout(Duration::from_secs(5))
            .expect("the session ended on its own");
        assert!(terminal.r#final);
        assert_eq!(
            terminal.termination_reason,
            i32::from(CaptureTerminationReason::AgentDisconnect)
        );
        wait_for_idle(&service);
    }

    #[test]
    fn only_the_first_cancel_reason_is_recorded() {
        // A client disconnecting during an operator-initiated stop did not
        // cause the stop, and an audit trail that says it did is wrong about
        // who ended a capture.
        let cancel = Cancel::default();
        assert_eq!(cancel.requested(), None);

        cancel.request(CaptureTerminationReason::DurationCap);
        cancel.request(CaptureTerminationReason::AgentDisconnect);
        assert_eq!(
            cancel.requested(),
            Some(CaptureTerminationReason::DurationCap)
        );
    }
}
