//go:build linux && arm64 && neon
// +build linux,arm64,neon

#include "textflag.h"

// NEON-optimized arm64 implementation of sumBE16Ptr.
// Processes 16 bytes per iteration with byte-swap + pairwise widening add,
// then reduces 4x32-bit lanes into a scalar and accumulates in a GPR.
//
// Go signature:
//   func sumBE16Ptr(p *byte, n int) uint32
TEXT ·sumBE16Ptr(SB), NOSPLIT, $0-24
    // Args
    MOVD p+0(FP), R0      // R0 = p
    MOVD n+8(FP), R1      // R1 = n

    // 64-bit accumulator
    MOVD $0, R2

    // blocks = n / 16
    MOVD R1, R4
    LSR  $4, R4, R4
    CBZ  R4, tail

    MOVD $16, R3

loop16:
    // Load 16B and advance pointer
    VLD1.P (R0)(R3), [V0.B16]
    // Swap bytes within 16-bit lanes
    VREV16 V0.B16, V0.B16
    // Pairwise add 8x16 -> 4x32: v1.4s = uaddlp(v0.8h)
    VUADDLP V1.S4, V0.H8

    // Reduce 4x32 to scalar via GPRs
    VMOV V1.S[0], R5
    VMOV V1.S[1], R6
    ADD  R6, R5, R5
    VMOV V1.S[2], R6
    ADD  R6, R5, R5
    VMOV V1.S[3], R6
    ADD  R6, R5, R5
    ADD  R5, R2, R2

    SUBS $1, R4, R4
    BNE  loop16

tail:
    // rem = n & 15 (pointer already advanced by loop)
    AND  $15, R1, R6

    // words = rem / 2
    LSR  $1, R6, R7
    CBZ  R7, odd

wloop:
    MOVHU (R0), R8
    REV16W R8, R8
    ADD    R8, R2, R2
    ADD    $2, R0, R0
    SUBS   $1, R7, R7
    BNE    wloop

odd:
    AND    $1, R6, R9
    CBZ    R9, done
    MOVBU  (R0), R10
    LSL    $8, R10, R10
    ADD    R10, R2, R2

done:
    MOVW  R2, ret+16(FP)
    RET

