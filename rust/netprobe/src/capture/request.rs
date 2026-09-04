//! Turning a wire `StartRemoteCapture` into something that can be run.
//!
//! Every rule that decides whether a capture is allowed to happen at all lives
//! here, in one pure function with no ring, no socket and no clock, so each rule
//! is testable on its own and none of them can be reached accidentally by a code
//! path that forgot to call the others.
//!
//! # Every default is closed
//!
//! Three fields would otherwise fail *open*, and proto3 makes that easy: an
//! absent field is indistinguishable from a zero one, so a field dropped by a
//! buggy caller, a truncated frame or a version skew arrives as `""`, `0` or an
//! empty list. If those meant "no restriction", the broadest possible capture
//! would be exactly what a malformed request produces:
//!
//! * **No attribution** is refused rather than treated as anonymous. A capture
//!   that reaches netprobe without a core-issued session id and actor bypassed
//!   the control plane, and the host must not perform it (`design.md` D8.7).
//! * **No filter** is refused rather than treated as "capture everything". To
//!   capture everything a client sends the accept-all cBPF program, which is
//!   one instruction and is exactly what libpcap compiles for an empty
//!   expression -- so saying it is easy, and saying it by accident is not.
//! * **No interface** is refused rather than defaulting to any.
//!
//! `snaplen` is the deliberate exception: 0 means unlimited, because that is
//! libpcap's own meaning for it and a client that omits it is not asking for a
//! zero-byte capture. It is bounded by `MAX_SNAPLEN` regardless.

use serviceradar_afpacket::Direction;

use super::{
    bpf::{Instruction, MAX_SNAPLEN, Program, ProgramError},
    filter::{self, FilterError},
    session::Limits,
};
use crate::{
    config::{self, AllowlistError},
    proto::netprobe::{CaptureDirection, StartRemoteCapture, start_remote_capture},
};

/// v1 runs one interface per session.
///
/// Not an arbitrary limit: each interface is its own ring, its own poll and its
/// own `PACKET_STATISTICS` reading, and one session's caps have to hold across
/// all of them. RPCAP -- the front door this exists for -- attaches to a single
/// interface at a time and lists the rest through `FINDALLIF`, so nothing on the
/// roadmap needs more. Rejecting is honest; silently capturing only the first
/// would not be.
pub const MAX_INTERFACES_PER_SESSION: usize = 1;

/// Why a capture request was refused.
///
/// Each variant carries a stable `code` for the `ErrorFrame`, because the
/// operator action differs per reason and a single `invalid_argument` would
/// force them to read logs to find out which.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum Rejection {
    #[error(
        "capture request carries no {missing}; a session must be issued by serviceradar-core, so netprobe will not start one for a client that bypassed the control plane"
    )]
    Unattributed { missing: &'static str },

    #[error("capture request names no interface")]
    NoInterface,

    #[error(
        "capture request names {count} interfaces; this netprobe captures {MAX_INTERFACES_PER_SESSION} per session"
    )]
    TooManyInterfaces { count: usize },

    #[error(transparent)]
    Interface(#[from] AllowlistError),

    #[error(
        "capture request sets no filter; send the accept-all program (a single `ret <snaplen>`, what libpcap compiles for an empty expression) to capture unfiltered"
    )]
    NoFilter,

    #[error(transparent)]
    Filter(#[from] FilterError),

    #[error(transparent)]
    Program(#[from] ProgramError),

    #[error("capture snaplen {0} exceeds the maximum of {MAX_SNAPLEN}")]
    SnaplenTooLarge(u32),
}

impl Rejection {
    /// A stable, greppable identifier for the `ErrorFrame`.
    ///
    /// Separate from the message on purpose: the message names the offending
    /// value and will change as the compiler learns more constructs, while a
    /// caller matching on the reason must not break when it does.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Unattributed { .. } => "capture_unattributed",
            Self::NoInterface | Self::TooManyInterfaces { .. } => "capture_interface_count",
            Self::Interface(_) => "capture_interface_denied",
            Self::NoFilter => "capture_no_filter",
            Self::Filter(_) | Self::Program(_) => "capture_filter_invalid",
            Self::SnaplenTooLarge(_) => "capture_snaplen_invalid",
        }
    }
}

/// A request that has passed every check, with nothing left to decide.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedRequest {
    pub session_id: String,
    /// Who core says asked for this. Recorded on the host, never used for
    /// authorization -- that already happened upstream.
    pub actor: String,
    pub interfaces: Vec<String>,
    pub program: Program,
    /// Already resolved: 0 has become [`MAX_SNAPLEN`], so nothing downstream
    /// has to remember what 0 meant.
    pub snaplen: u32,
    pub limits: Limits,
    pub direction: DirectionFilter,
    pub promiscuous: bool,
}

/// Which directions a session keeps.
///
/// Applied to the frame after the kernel filter rather than compiled into it,
/// and that is not laziness: a client may send a *precompiled* program, and this
/// process has no safe way to graft a `PACKET_OUTGOING` test onto an arbitrary
/// cBPF program whose jump offsets it did not choose. Testing the ring header's
/// `sll_pkttype` in userspace gives the same answer for both filter forms, with
/// one implementation instead of two.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirectionFilter {
    Both,
    Ingress,
    Egress,
}

impl DirectionFilter {
    /// Unspecified means both. AF_PACKET delivers transmitted frames too, so
    /// "both" is what a socket does when nobody narrows it.
    fn from_wire(direction: CaptureDirection) -> Self {
        match direction {
            CaptureDirection::Ingress => Self::Ingress,
            CaptureDirection::Egress => Self::Egress,
            CaptureDirection::Both | CaptureDirection::Unspecified => Self::Both,
        }
    }

    pub fn keeps(self, direction: Direction) -> bool {
        match self {
            Self::Both => true,
            Self::Ingress => direction == Direction::Inbound,
            Self::Egress => direction == Direction::Outbound,
        }
    }
}

/// Validate a request against the operator's allowlist.
///
/// Order matters for the operator, not for correctness: attribution is checked
/// first so a request that should never have reached the host is refused before
/// its contents are parsed or its interface names are echoed back.
pub fn validate(
    request: &StartRemoteCapture,
    allowlist: &[String],
) -> Result<ValidatedRequest, Rejection> {
    if request.session_id.trim().is_empty() {
        return Err(Rejection::Unattributed {
            missing: "session id",
        });
    }
    if request.actor.trim().is_empty() {
        return Err(Rejection::Unattributed { missing: "actor" });
    }

    if request.interfaces.is_empty() {
        return Err(Rejection::NoInterface);
    }
    if request.interfaces.len() > MAX_INTERFACES_PER_SESSION {
        return Err(Rejection::TooManyInterfaces {
            count: request.interfaces.len(),
        });
    }
    for interface in &request.interfaces {
        config::validate_interface(allowlist, interface)?;
    }

    if request.snaplen > MAX_SNAPLEN {
        return Err(Rejection::SnaplenTooLarge(request.snaplen));
    }
    let snaplen = if request.snaplen == 0 {
        MAX_SNAPLEN
    } else {
        request.snaplen
    };

    let program = match request.filter.as_ref() {
        Some(start_remote_capture::Filter::FilterExpression(expression)) => {
            filter::compile(expression, snaplen)?
        }
        Some(start_remote_capture::Filter::FilterBpf(bpf)) => {
            let instructions = bpf
                .instructions
                .iter()
                .map(|insn| Instruction::try_from_wire(insn.code, insn.jt, insn.jf, insn.k))
                .collect::<Result<Vec<_>, _>>()?;
            Program::new(instructions)?
        }
        None => return Err(Rejection::NoFilter),
    };

    Ok(ValidatedRequest {
        session_id: request.session_id.clone(),
        actor: request.actor.clone(),
        interfaces: request.interfaces.clone(),
        program,
        snaplen,
        limits: Limits::from_wire(request.duration_s, request.byte_cap),
        direction: DirectionFilter::from_wire(request.direction()),
        promiscuous: request.promiscuous,
    })
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::proto::netprobe::{BpfInstruction, BpfProgram};

    fn allowlist() -> Vec<String> {
        vec!["eth0".to_string(), "eth1".to_string()]
    }

    /// The accept-all program libpcap compiles for an empty expression:
    /// `tcpdump -dd ''` is a single `ret #262144`.
    fn accept_all() -> start_remote_capture::Filter {
        start_remote_capture::Filter::FilterBpf(BpfProgram {
            instructions: vec![BpfInstruction {
                code: 0x06,
                jt: 0,
                jf: 0,
                k: i64::from(MAX_SNAPLEN),
            }],
        })
    }

    fn valid() -> StartRemoteCapture {
        StartRemoteCapture {
            session_id: "01JQ0000000000000000000000".to_string(),
            actor: "operator@example.com".to_string(),
            interfaces: vec!["eth0".to_string()],
            filter: Some(start_remote_capture::Filter::FilterExpression(
                "tcp port 22".to_string(),
            )),
            snaplen: 262,
            duration_s: 30,
            byte_cap: 1_048_576,
            direction: CaptureDirection::Both as i32,
            promiscuous: false,
        }
    }

    #[test]
    fn a_well_formed_request_is_accepted_whole() {
        let validated = validate(&valid(), &allowlist()).expect("accepted");
        assert_eq!(validated.session_id, "01JQ0000000000000000000000");
        assert_eq!(validated.actor, "operator@example.com");
        assert_eq!(validated.interfaces, vec!["eth0".to_string()]);
        assert_eq!(validated.snaplen, 262);
        assert_eq!(validated.limits.duration, Some(Duration::from_secs(30)));
        assert_eq!(validated.limits.byte_cap, Some(1_048_576));
        assert_eq!(validated.direction, DirectionFilter::Both);
        assert!(!validated.program.is_empty(), "the filter was compiled");
    }

    #[test]
    fn a_request_with_no_session_id_is_refused() {
        // D8.7: this is what stops a capture being started by something local
        // to the host that holds the socket but never went through core.
        let mut request = valid();
        request.session_id = String::new();
        let err = validate(&request, &allowlist()).unwrap_err();
        assert_eq!(
            err,
            Rejection::Unattributed {
                missing: "session id"
            }
        );
        assert_eq!(err.code(), "capture_unattributed");
    }

    #[test]
    fn a_request_with_no_actor_is_refused() {
        let mut request = valid();
        request.actor = String::new();
        assert_eq!(
            validate(&request, &allowlist()).unwrap_err(),
            Rejection::Unattributed { missing: "actor" }
        );
    }

    #[test]
    fn whitespace_does_not_count_as_attribution() {
        // Otherwise " " satisfies the check and the audit record says nothing,
        // which is worse than a refusal because it looks attributed.
        let mut request = valid();
        request.actor = "   ".to_string();
        assert!(matches!(
            validate(&request, &allowlist()).unwrap_err(),
            Rejection::Unattributed { .. }
        ));
    }

    #[test]
    fn an_interface_outside_the_allowlist_is_refused() {
        let mut request = valid();
        request.interfaces = vec!["eth9".to_string()];
        let err = validate(&request, &allowlist()).unwrap_err();
        assert_eq!(err.code(), "capture_interface_denied");
        assert!(format!("{err}").contains("eth9"));
    }

    #[test]
    fn any_and_wildcards_are_refused_even_when_the_allowlist_is_wrong() {
        // `validate_interface` rejects these before consulting the allowlist,
        // so an operator who put `any` in the config still cannot capture on
        // every interface at once.
        for name in ["any", "eth*"] {
            let mut request = valid();
            request.interfaces = vec![name.to_string()];
            let mut list = allowlist();
            list.push(name.to_string());
            assert!(
                validate(&request, &list).is_err(),
                "{name} must be refused even when allowlisted"
            );
        }
    }

    #[test]
    fn no_interface_and_too_many_interfaces_are_both_refused() {
        let mut request = valid();
        request.interfaces = Vec::new();
        assert_eq!(
            validate(&request, &allowlist()).unwrap_err(),
            Rejection::NoInterface
        );

        let mut request = valid();
        request.interfaces = vec!["eth0".to_string(), "eth1".to_string()];
        assert_eq!(
            validate(&request, &allowlist()).unwrap_err(),
            Rejection::TooManyInterfaces { count: 2 }
        );
    }

    #[test]
    fn an_unset_filter_is_refused_rather_than_capturing_everything() {
        // The fail-open case: proto3 cannot distinguish an omitted oneof from a
        // dropped one, so treating "unset" as "no restriction" would make the
        // broadest capture the thing a malformed request produces.
        let mut request = valid();
        request.filter = None;
        let err = validate(&request, &allowlist()).unwrap_err();
        assert_eq!(err, Rejection::NoFilter);
        assert!(
            format!("{err}").contains("ret <snaplen>"),
            "the refusal must say how to capture unfiltered on purpose: {err}"
        );
    }

    #[test]
    fn capturing_everything_on_purpose_is_accepted() {
        let mut request = valid();
        request.filter = Some(accept_all());
        let validated = validate(&request, &allowlist()).expect("accept-all is a valid filter");
        assert_eq!(validated.program.len(), 1);
    }

    #[test]
    fn an_uncompilable_expression_is_refused_before_the_session_starts() {
        let mut request = valid();
        request.filter = Some(start_remote_capture::Filter::FilterExpression(
            "tcp port ssh".to_string(),
        ));
        let err = validate(&request, &allowlist()).unwrap_err();
        assert_eq!(err.code(), "capture_filter_invalid");
    }

    #[test]
    fn an_empty_precompiled_program_is_refused() {
        // Distinct from an unset filter: the client sent a program and it
        // cannot be attached. The kernel would answer EINVAL with nothing to
        // say which of a dozen causes it was.
        let mut request = valid();
        request.filter = Some(start_remote_capture::Filter::FilterBpf(BpfProgram {
            instructions: Vec::new(),
        }));
        assert_eq!(
            validate(&request, &allowlist()).unwrap_err(),
            Rejection::Program(ProgramError::Empty)
        );
    }

    #[test]
    fn a_precompiled_instruction_field_that_cannot_fit_is_refused_not_truncated() {
        // `jt = 300` cast with `as u8` becomes 44: a valid program that jumps
        // somewhere the client never asked for, over packets the operator is
        // recording.
        let mut request = valid();
        request.filter = Some(start_remote_capture::Filter::FilterBpf(BpfProgram {
            instructions: vec![BpfInstruction {
                code: 0x15,
                jt: 300,
                jf: 0,
                k: 6,
            }],
        }));
        assert_eq!(
            validate(&request, &allowlist()).unwrap_err(),
            Rejection::Program(ProgramError::FieldOutOfRange {
                field: "jt",
                value: 300
            })
        );
    }

    #[test]
    fn snaplen_zero_means_unlimited_and_an_oversized_one_is_refused() {
        // 0 is the proto3 default, so it is what an unset field sends. libpcap
        // spells "unlimited" as MAX_SNAPLEN; clamping to 1 instead declares
        // every packet one byte long and decodes as zero packets while exiting
        // 0.
        let mut request = valid();
        request.snaplen = 0;
        assert_eq!(
            validate(&request, &allowlist()).unwrap().snaplen,
            MAX_SNAPLEN
        );

        let mut request = valid();
        request.snaplen = MAX_SNAPLEN + 1;
        assert_eq!(
            validate(&request, &allowlist()).unwrap_err(),
            Rejection::SnaplenTooLarge(MAX_SNAPLEN + 1)
        );
    }

    #[test]
    fn the_compiled_filter_returns_the_resolved_snaplen_not_the_wire_zero() {
        // The accept instruction's `k` IS the snaplen, so compiling against the
        // raw 0 would attach a filter that accepts zero bytes of every match --
        // a capture that runs, reports success and contains nothing.
        let mut request = valid();
        request.snaplen = 0;
        let validated = validate(&request, &allowlist()).unwrap();
        let accepts: Vec<_> = validated
            .program
            .instructions()
            .iter()
            .filter(|insn| insn.code == 0x06 && insn.k != 0)
            .collect();
        assert!(!accepts.is_empty(), "the program must accept something");
        assert!(
            accepts.iter().all(|insn| insn.k == MAX_SNAPLEN),
            "every accept must carry the resolved snaplen: {accepts:?}"
        );
    }

    #[test]
    fn direction_unspecified_means_both() {
        let mut request = valid();
        request.direction = CaptureDirection::Unspecified as i32;
        assert_eq!(
            validate(&request, &allowlist()).unwrap().direction,
            DirectionFilter::Both
        );
    }

    #[test]
    fn direction_narrows_which_frames_are_kept() {
        assert!(DirectionFilter::Both.keeps(Direction::Inbound));
        assert!(DirectionFilter::Both.keeps(Direction::Outbound));

        assert!(DirectionFilter::Ingress.keeps(Direction::Inbound));
        assert!(!DirectionFilter::Ingress.keeps(Direction::Outbound));

        assert!(!DirectionFilter::Egress.keeps(Direction::Inbound));
        assert!(DirectionFilter::Egress.keeps(Direction::Outbound));
    }

    #[test]
    fn attribution_is_checked_before_anything_else_in_the_request() {
        // An unattributed request must be refused for being unattributed, not
        // for whichever of its other fields happens to also be wrong -- the
        // operator response to the two is completely different.
        let request = StartRemoteCapture {
            session_id: String::new(),
            actor: String::new(),
            interfaces: vec!["eth9".to_string()],
            filter: None,
            snaplen: MAX_SNAPLEN + 1,
            ..Default::default()
        };
        assert!(matches!(
            validate(&request, &allowlist()).unwrap_err(),
            Rejection::Unattributed { .. }
        ));
    }
}
