//go:build linux && arm64
// +build linux,arm64

#include "textflag.h"

// sumBE16Ptr computes the (unfolded) one's‑complement sum of 16‑bit big‑endian
// words over [p, p+n). If n is odd, the final byte is treated as the high‑order byte.
// Scalar AArch64 version (portable on all cores); NEON can be added later.
//
// Go signature:
//   func sumBE16Ptr(p *byte, n int) uint32
TEXT ·sumBE16Ptr(SB), NOSPLIT, $0-24
    // Args
    MOVD p+0(FP), R0      // R0 = p
    MOVD n+8(FP), R1      // R1 = n

    // 64-bit accumulator
    MOVD $0, R2

    // words = n/2
    MOVD R1, R3
    LSR  $1, R3, R3
    CBZ  R3, odds

loop:
    MOVHU (R0), R4        // load little-endian uint16
    REV16W R4, R4         // swap bytes to big-endian numeric
    ADD   R4, R2, R2
    ADD   $2, R0, R0
    SUBS  $1, R3, R3
    BNE   loop

odds:
    // if n is odd, add last byte as high-order byte
    AND   $1, R1, R4
    CBZ   R4, done
    MOVBU (R0), R4
    LSL   $8, R4, R4
    ADD   R4, R2, R2

done:
    MOVW  R2, ret+16(FP)
    RET
