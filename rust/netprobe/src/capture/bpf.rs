//! Classic BPF (cBPF) instruction encoding shared by both capture filter front
//! doors.
//!
//! Remote capture accepts a filter two ways and both end at the same
//! `SO_ATTACH_FILTER` call, so there is exactly one filter representation in
//! this crate:
//!
//! * an RPCAP client (Wireshark) sends a program its own libpcap already
//!   compiled, carried verbatim in `StartRemoteCapture.filter_bpf`;
//! * the control plane sends an expression string, which [`super::filter`]
//!   compiles into the same instruction type.
//!
//! Constants are transcribed from `/usr/include/linux/bpf_common.h` and
//! `/usr/include/linux/filter.h` on Linux 6.8 rather than from memory, and the
//! layout of [`Instruction`] mirrors `struct sock_filter` exactly:
//!
//! ```c
//! struct sock_filter { __u16 code; __u8 jt; __u8 jf; __u32 k; };  /* 8 bytes */
//! ```
//!
//! The kernel verifies a program at attach time and rejects a malformed one,
//! so this module deliberately does NOT re-implement the verifier. It checks
//! only what the kernel cannot tell us apart: every rejection the kernel makes
//! is `EINVAL` with no distinguishing code, so a program refused here gets a
//! named reason the operator can act on, instead of a bare errno.

use std::fmt;

use thiserror::Error;

// Instruction classes (bpf_common.h).
pub const BPF_LD: u16 = 0x00;
pub const BPF_LDX: u16 = 0x01;
pub const BPF_ALU: u16 = 0x04;
pub const BPF_JMP: u16 = 0x05;
pub const BPF_RET: u16 = 0x06;
pub const BPF_MISC: u16 = 0x07;

// Load/store width.
pub const BPF_W: u16 = 0x00;
pub const BPF_H: u16 = 0x08;
pub const BPF_B: u16 = 0x10;

// Addressing modes.
pub const BPF_ABS: u16 = 0x20;
/// Indexed load: reads at `X + k`, which is how a port is read past a variable
/// length IPv4 header.
pub const BPF_IND: u16 = 0x40;
pub const BPF_MSH: u16 = 0xa0;

// ALU operations.
pub const BPF_AND: u16 = 0x50;

// Jump operations.
pub const BPF_JA: u16 = 0x00;
pub const BPF_JEQ: u16 = 0x10;
pub const BPF_JGT: u16 = 0x20;
pub const BPF_JGE: u16 = 0x30;
/// Bit test. Used for the IPv4 fragment guard.
pub const BPF_JSET: u16 = 0x40;

// Operand source.
pub const BPF_K: u16 = 0x00;

/// `BPF_MAXINSNS` from `bpf_common.h:53`. Measured against a real socket: 4096
/// instructions attach, 4097 is rejected with `EINVAL`.
pub const MAX_INSNS: usize = 4096;

/// Offset base for ancillary loads (`filter.h:66`). A load at
/// `SKF_AD_OFF + SKF_AD_PKTTYPE` reads the packet type rather than packet
/// bytes, which is how `inbound`/`outbound` are expressed.
pub const SKF_AD_OFF: i32 = -0x1000;
pub const SKF_AD_PKTTYPE: i32 = 4;

/// `PACKET_OUTGOING` from `linux/if_packet.h`. The value an ancillary
/// `SKF_AD_PKTTYPE` load is compared against to select transmitted frames.
pub const PACKET_OUTGOING: u32 = 4;

/// libpcap's substitute for "no limit". `tcpdump -s 0` and `-s 262144` compile
/// to the same `ret #262144`, and libpcap hard-errors on a captured length
/// above it, so this is a ceiling rather than a default.
pub const MAX_SNAPLEN: u32 = 262_144;

/// One `struct sock_filter`.
///
/// `code`, `jt` and `jf` are narrower on the wire than the proto can express
/// (proto3 has no integer smaller than `uint32`), so [`Instruction::try_from_wire`]
/// is the only way to build one from a client-supplied program.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Instruction {
    pub code: u16,
    pub jt: u8,
    pub jf: u8,
    pub k: u32,
}

impl fmt::Debug for Instruction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Mirrors `tcpdump -dd` output so a failing assertion can be pasted
        // straight into a comparison with tcpdump.
        write!(
            f,
            "{{ 0x{:x}, {}, {}, 0x{:08x} }}",
            self.code, self.jt, self.jf, self.k
        )
    }
}

impl Instruction {
    pub const fn new(code: u16, jt: u8, jf: u8, k: u32) -> Self {
        Self { code, jt, jf, k }
    }

    /// Accept `n` bytes of the packet. `n` is the snaplen: the kernel copies
    /// at most this many bytes of a matching frame.
    pub const fn accept(snaplen: u32) -> Self {
        Self::new(BPF_RET | BPF_K, 0, 0, snaplen)
    }

    /// Reject the packet.
    pub const fn reject() -> Self {
        Self::new(BPF_RET | BPF_K, 0, 0, 0)
    }

    /// Build from the proto's widened integers, rejecting values that cannot
    /// be represented in `struct sock_filter`.
    ///
    /// Without this, a client sending `jt = 300` would have it silently
    /// truncated to 44 by an `as u8` cast, producing a valid program that
    /// jumps somewhere the client never asked for.
    pub fn try_from_wire(code: u32, jt: u32, jf: u32, k: i64) -> Result<Self, ProgramError> {
        let code = u16::try_from(code).map_err(|_| ProgramError::FieldOutOfRange {
            field: "code",
            value: i64::from(code),
        })?;
        let jt = u8::try_from(jt).map_err(|_| ProgramError::FieldOutOfRange {
            field: "jt",
            value: i64::from(jt),
        })?;
        let jf = u8::try_from(jf).map_err(|_| ProgramError::FieldOutOfRange {
            field: "jf",
            value: i64::from(jf),
        })?;
        let k = u32::try_from(k).map_err(|_| ProgramError::FieldOutOfRange {
            field: "k",
            value: k,
        })?;
        Ok(Self::new(code, jt, jf, k))
    }
}

/// Why a client-supplied program was refused before it reached the kernel.
///
/// Every kernel rejection is `EINVAL` with nothing to distinguish it, so these
/// exist to give the operator a reason rather than an errno.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProgramError {
    #[error("capture filter program is empty")]
    Empty,

    #[error(
        "capture filter program has {count} instructions, more than the kernel maximum of {MAX_INSNS}"
    )]
    TooLong { count: usize },

    #[error(
        "capture filter instruction field `{field}` is {value}, which does not fit struct sock_filter"
    )]
    FieldOutOfRange { field: &'static str, value: i64 },
}

/// A validated cBPF program, ready to attach.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Program {
    instructions: Vec<Instruction>,
}

impl Program {
    /// Wrap instructions this crate generated. The compiler is trusted to
    /// produce a well-formed program; the kernel is still the final verifier.
    pub fn new(instructions: Vec<Instruction>) -> Result<Self, ProgramError> {
        if instructions.is_empty() {
            return Err(ProgramError::Empty);
        }
        if instructions.len() > MAX_INSNS {
            return Err(ProgramError::TooLong {
                count: instructions.len(),
            });
        }
        Ok(Self { instructions })
    }

    pub fn instructions(&self) -> &[Instruction] {
        &self.instructions
    }

    pub fn len(&self) -> usize {
        self.instructions.len()
    }

    pub fn is_empty(&self) -> bool {
        self.instructions.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accept_encodes_snaplen_as_the_return_value() {
        // Verified against `tcpdump -s 96 -dd icmp`, whose final pair is
        // { 0x6, 0, 0, 0x00000060 } / { 0x6, 0, 0, 0x00000000 }.
        assert_eq!(Instruction::accept(96), Instruction::new(0x06, 0, 0, 96));
        assert_eq!(Instruction::reject(), Instruction::new(0x06, 0, 0, 0));
    }

    #[test]
    fn max_snaplen_matches_what_tcpdump_substitutes_for_unlimited() {
        // `tcpdump -s 0` and `-s 262144` both compile to ret #0x00040000.
        assert_eq!(MAX_SNAPLEN, 0x0004_0000);
    }

    #[test]
    fn ancillary_packet_type_offset_matches_tcpdump() {
        // `tcpdump -dd outbound` loads from 0xfffff004, which as an i32 is
        // SKF_AD_OFF + SKF_AD_PKTTYPE.
        let offset = SKF_AD_OFF + SKF_AD_PKTTYPE;
        assert_eq!(offset, -4092);
        assert_eq!(offset as u32, 0xffff_f004);
    }

    #[test]
    fn out_of_range_wire_fields_are_named_not_truncated() {
        // The bug this prevents: `jt: 300 as u8` is 44, a valid jump to
        // somewhere the client never asked for.
        assert_eq!(
            Instruction::try_from_wire(0x15, 300, 0, 0),
            Err(ProgramError::FieldOutOfRange {
                field: "jt",
                value: 300
            })
        );
        assert_eq!(
            Instruction::try_from_wire(0x1_0000, 0, 0, 0),
            Err(ProgramError::FieldOutOfRange {
                field: "code",
                value: 0x1_0000
            })
        );
        assert_eq!(
            Instruction::try_from_wire(0x15, 0, 0, -1),
            Err(ProgramError::FieldOutOfRange {
                field: "k",
                value: -1
            })
        );
    }

    #[test]
    fn in_range_wire_fields_round_trip() {
        assert_eq!(
            Instruction::try_from_wire(0x15, 0, 3, 0xc000_0201),
            Ok(Instruction::new(0x15, 0, 3, 0xc000_0201))
        );
    }

    #[test]
    fn program_rejects_empty_and_oversized() {
        assert_eq!(Program::new(Vec::new()), Err(ProgramError::Empty));

        // 4096 attaches on a real socket; 4097 is EINVAL.
        let ok = vec![Instruction::accept(MAX_SNAPLEN); MAX_INSNS];
        assert!(Program::new(ok).is_ok());

        let too_long = vec![Instruction::accept(MAX_SNAPLEN); MAX_INSNS + 1];
        assert_eq!(
            Program::new(too_long),
            Err(ProgramError::TooLong {
                count: MAX_INSNS + 1
            })
        );
    }

    #[test]
    fn debug_format_matches_tcpdump_dd_so_failures_can_be_diffed() {
        assert_eq!(
            format!("{:?}", Instruction::new(0x15, 0, 3, 0xc000_0201)),
            "{ 0x15, 0, 3, 0xc0000201 }"
        );
    }
}
