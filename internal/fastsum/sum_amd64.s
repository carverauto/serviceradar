//go:build linux && amd64
// +build linux,amd64

#include "textflag.h"

// sumBE16Ptr computes the (unfolded) one's-complement sum of 16-bit big-endian
// words over [p, p+n). Odd last byte (if any) is treated as high byte.
// Returns a 32-bit partial sum (caller folds + inverts).
//
// Go signature:
//   func sumBE16Ptr(p *byte, n int) uint32
TEXT ·sumBE16Ptr(SB), NOSPLIT, $0-24
    // Load args
    MOVQ p+0(FP), SI      // SI = p
    MOVQ n+8(FP), CX      // CX = n

    XORQ AX, AX           // AX = running sum (64-bit to reduce carry pressure)

    // words = n/2
    MOVQ CX, R9
    SHRQ $1, R9
    TESTQ R9, R9
    JE   odds

loop:
    // Read 16-bit little-endian then rotate to big-endian numeric (swap bytes)
    MOVWQZX (SI), R8      // R8 = uint16(b0 | b1<<8)
    ROLW    $8, R8        // R8 = (b0<<8 | b1)
    ADDQ    R8, AX
    LEAQ    2(SI), SI
    DECQ    R9
    JNE     loop

odds:
    // If length is odd, add the last byte as high-order byte
    TESTQ   $1, CX
    JZ      done
    MOVBLZX (SI), R8
    SHLQ    $8, R8        // (b_last << 8)
    ADDQ    R8, AX

done:
    MOVL AX, ret+16(FP)   // return low 32 bits
    RET
