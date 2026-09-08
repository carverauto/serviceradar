//! A classic BPF interpreter, used to compare our compiler against libpcap.
//!
//! This exists for one job: run our compiled program and libpcap's compilation
//! of the same expression over the same packet, and check they agree. The
//! kernel is the real interpreter in production, but it can only filter live
//! traffic — it cannot be shown a crafted non-first IPv4 fragment on demand,
//! and those crafted packets are exactly where a compiler bug hides.
//!
//! It is deliberately small and deliberately strict. The failure mode the
//! survey called out is an interpreter that does not model ancillary loads:
//! `ldh [-4092]` would then read packet bytes at offset `0xfffff004`, fall out
//! of bounds, and return 0 — making `inbound` appear to reject everything and
//! `outbound` appear to accept everything, with no error anywhere. So
//! [`Packet`] carries an explicit ancillary map and any unmodelled ancillary
//! offset is an error rather than a silent read.

use super::bpf::{
    BPF_ABS, BPF_ALU, BPF_AND, BPF_B, BPF_H, BPF_IND, BPF_JEQ, BPF_JGE, BPF_JGT, BPF_JMP, BPF_JSET,
    BPF_LD, BPF_LDX, BPF_MSH, BPF_RET, BPF_W, Instruction, SKF_AD_OFF, SKF_AD_PKTTYPE,
};

/// A packet as the kernel would present it to a filter.
#[derive(Debug, Clone)]
pub struct Packet {
    /// Full Ethernet frame.
    pub bytes: Vec<u8>,
    /// `sll_pkttype`, read by ancillary `SKF_AD_PKTTYPE` loads.
    pub pkttype: u32,
}

impl Packet {
    pub fn new(bytes: Vec<u8>, pkttype: u32) -> Self {
        Self { bytes, pkttype }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum InterpError {
    /// An ancillary offset this interpreter does not model. Never silently
    /// treated as a packet read.
    UnmodelledAncillary(i32),
    /// The program ran past its end without returning.
    RanOffEnd,
    /// More steps than instructions, which means a loop; cBPF cannot loop, so
    /// this indicates a malformed program rather than a slow one.
    StepLimit,
}

/// Run `program` over `packet`, returning the accepted byte count (0 = reject).
///
/// Out-of-bounds packet reads return 0 from the program, which is what the
/// kernel does: a filter reading past the end of a short packet drops it. That
/// behaviour is load-bearing — it is why a mis-computed offset produces an
/// empty capture rather than an error.
pub fn run(program: &[Instruction], packet: &Packet) -> Result<u32, InterpError> {
    let mut a: u32 = 0;
    let mut x: u32 = 0;
    let mut pc: usize = 0;
    let mut steps = 0usize;
    let data = &packet.bytes;

    loop {
        steps += 1;
        if steps > program.len() + 1 {
            return Err(InterpError::StepLimit);
        }
        let insn = *program.get(pc).ok_or(InterpError::RanOffEnd)?;
        pc += 1;

        let class = insn.code & 0x07;
        match class {
            BPF_RET => return Ok(insn.k),

            BPF_LD => {
                let mode = insn.code & 0xe0;
                let size = insn.code & 0x18;
                let offset: i64 = match mode {
                    BPF_ABS => i64::from(insn.k as i32),
                    BPF_IND => i64::from(insn.k) + i64::from(x),
                    _ => return Err(InterpError::UnmodelledAncillary(insn.k as i32)),
                };

                // Ancillary loads live below zero; the kernel routes them to
                // metadata rather than packet bytes.
                if offset < 0 {
                    let ancillary = offset - i64::from(SKF_AD_OFF);
                    if ancillary == i64::from(SKF_AD_PKTTYPE) {
                        a = packet.pkttype;
                        continue;
                    }
                    return Err(InterpError::UnmodelledAncillary(offset as i32));
                }

                let off = offset as usize;
                a = match size {
                    BPF_W => match read_slice(data, off, 4) {
                        Some(b) => u32::from_be_bytes([b[0], b[1], b[2], b[3]]),
                        None => return Ok(0),
                    },
                    BPF_H => match read_slice(data, off, 2) {
                        Some(b) => u32::from(u16::from_be_bytes([b[0], b[1]])),
                        None => return Ok(0),
                    },
                    BPF_B => match read_slice(data, off, 1) {
                        Some(b) => u32::from(b[0]),
                        None => return Ok(0),
                    },
                    _ => return Ok(0),
                };
            }

            BPF_LDX => {
                // The only LDX form the compiler emits is BPF_MSH, which loads
                // 4 * (packet[k] & 0xf) — the IPv4 header length.
                if insn.code & 0xe0 == BPF_MSH {
                    let off = insn.k as usize;
                    match read_slice(data, off, 1) {
                        Some(b) => x = u32::from(b[0] & 0x0f) * 4,
                        None => return Ok(0),
                    }
                } else {
                    return Ok(0);
                }
            }

            BPF_ALU => {
                if insn.code & 0xf0 == BPF_AND {
                    a &= insn.k;
                } else {
                    return Ok(0);
                }
            }

            BPF_JMP => {
                let op = insn.code & 0xf0;
                let taken = match op {
                    BPF_JEQ => a == insn.k,
                    BPF_JGT => a > insn.k,
                    BPF_JGE => a >= insn.k,
                    BPF_JSET => (a & insn.k) != 0,
                    // BPF_JA is an unconditional jump using k as the offset.
                    _ => {
                        pc += insn.k as usize;
                        continue;
                    }
                };
                pc += if taken {
                    insn.jt as usize
                } else {
                    insn.jf as usize
                };
            }

            _ => return Ok(0),
        }
    }
}

fn read_slice(data: &[u8], off: usize, len: usize) -> Option<&[u8]> {
    data.get(off..off.checked_add(len)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capture::bpf::PACKET_OUTGOING;

    fn pkt(bytes: Vec<u8>) -> Packet {
        Packet::new(bytes, 0)
    }

    #[test]
    fn accept_and_reject_return_their_k() {
        assert_eq!(
            run(&[Instruction::accept(262_144)], &pkt(vec![])),
            Ok(262_144)
        );
        assert_eq!(run(&[Instruction::reject()], &pkt(vec![])), Ok(0));
    }

    #[test]
    fn out_of_bounds_read_drops_the_packet_rather_than_erroring() {
        // This mirrors the kernel: a filter reading past a short packet
        // returns 0. It is why a mis-computed offset yields an empty capture
        // instead of a loud failure.
        let program = [
            Instruction::new(BPF_LD | BPF_H | BPF_ABS, 0, 0, 100),
            Instruction::accept(262_144),
        ];
        assert_eq!(run(&program, &pkt(vec![0u8; 14])), Ok(0));
    }

    #[test]
    fn unmodelled_ancillary_offsets_are_an_error_not_a_silent_read() {
        // The trap: without this, `ldh [-4092]` reads packet bytes at
        // 0xfffff004, returns 0, and `inbound`/`outbound` silently invert.
        let program = [
            Instruction::new(BPF_LD | BPF_H | BPF_ABS, 0, 0, (SKF_AD_OFF + 999) as u32),
            Instruction::accept(262_144),
        ];
        assert_eq!(
            run(&program, &pkt(vec![0u8; 64])),
            Err(InterpError::UnmodelledAncillary(SKF_AD_OFF + 999))
        );
    }

    #[test]
    fn packet_type_ancillary_load_reads_the_metadata() {
        let program = [
            Instruction::new(
                BPF_LD | BPF_H | BPF_ABS,
                0,
                0,
                (SKF_AD_OFF + SKF_AD_PKTTYPE) as u32,
            ),
            Instruction::new(BPF_JMP | BPF_JEQ, 0, 1, PACKET_OUTGOING),
            Instruction::accept(262_144),
            Instruction::reject(),
        ];
        assert_eq!(run(&program, &Packet::new(vec![0u8; 64], 4)), Ok(262_144));
        assert_eq!(run(&program, &Packet::new(vec![0u8; 64], 0)), Ok(0));
    }

    #[test]
    fn msh_loads_four_times_the_low_nibble() {
        // 0x46 -> ihl 6 -> 24 bytes of IPv4 header.
        let mut frame = vec![0u8; 64];
        frame[14] = 0x46;
        let program = [
            Instruction::new(BPF_LDX | BPF_B | BPF_MSH, 0, 0, 14),
            Instruction::new(BPF_LD | BPF_W | BPF_IND, 0, 0, 0),
            Instruction::accept(262_144),
        ];
        // Reading at X + 0 = 24 must succeed on a 64-byte frame.
        assert_eq!(run(&program, &pkt(frame)), Ok(262_144));
    }

    #[test]
    fn a_program_that_never_returns_is_an_error() {
        let program = [Instruction::new(BPF_LD | BPF_H | BPF_ABS, 0, 0, 0)];
        assert_eq!(
            run(&program, &pkt(vec![0u8; 64])),
            Err(InterpError::RanOffEnd)
        );
    }
}
