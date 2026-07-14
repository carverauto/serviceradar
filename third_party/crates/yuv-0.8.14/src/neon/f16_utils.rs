#![allow(dead_code)]
/*
 * Copyright (c) Radzivon Bartoshyk. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1.  Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * 2.  Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3.  Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

use core::f16;
use std::arch::aarch64::*;
use std::arch::asm;

/// Provides basic support for f16
#[allow(unused)]
macro_rules! static_assert {
    ($e:expr) => {
        const {
            assert!($e);
        }
    };
    ($e:expr, $msg:expr) => {
        const {
            assert!($e, $msg);
        }
    };
}

#[allow(unused_macros)]
macro_rules! static_assert_uimm_bits {
    ($imm:ident, $bits:expr) => {
        // `0 <= $imm` produces a warning if the immediate has an unsigned type
        #[allow(unused_comparisons)]
        {
            static_assert!(
                0 <= $imm && $imm < (1 << $bits),
                concat!(
                    stringify!($imm),
                    " doesn't fit in ",
                    stringify!($bits),
                    " bits",
                )
            )
        }
    };
}

#[derive(Debug, Clone, Copy)]
#[allow(non_camel_case_types)]
#[allow(dead_code)]
pub(crate) struct x_float16x4_t(pub(crate) uint16x4_t);

#[derive(Debug, Clone, Copy)]
#[allow(non_camel_case_types)]
#[allow(dead_code)]
pub(crate) struct x_float16x8_t(pub(crate) uint16x8_t);

#[derive(Debug, Clone, Copy)]
#[allow(non_camel_case_types)]
pub(crate) struct x_float16x8x2_t(pub(crate) x_float16x8_t, pub(crate) x_float16x8_t);

#[derive(Debug, Clone, Copy)]
#[allow(non_camel_case_types)]
pub(crate) struct x_float16x8x4_t(
    pub(crate) x_float16x8_t,
    pub(crate) x_float16x8_t,
    pub(crate) x_float16x8_t,
    pub(crate) x_float16x8_t,
);

#[inline]
pub(crate) unsafe fn xvld_f16(ptr: *const f16) -> x_float16x4_t {
    let store: uint16x4_t = vld1_u16(ptr as *const _);
    std::mem::transmute(store)
}

#[inline]
pub(crate) unsafe fn xvldq_f16(ptr: *const f16) -> x_float16x8_t {
    let store: uint16x8_t = vld1q_u16(ptr as *const _);
    std::mem::transmute(store)
}

#[inline]
pub(crate) unsafe fn xvldq_f16_x2(ptr: *const f16) -> x_float16x8x2_t {
    let ptr_u16 = ptr as *const u16;
    x_float16x8x2_t(
        xreinterpretq_f16_u16(vld1q_u16(ptr_u16)),
        xreinterpretq_f16_u16(vld1q_u16(ptr_u16.add(8))),
    )
}

#[inline]
pub(crate) unsafe fn xvldq_f16_x4(ptr: *const f16) -> x_float16x8x4_t {
    let ptr_u16 = ptr as *const u16;
    x_float16x8x4_t(
        xreinterpretq_f16_u16(vld1q_u16(ptr_u16)),
        xreinterpretq_f16_u16(vld1q_u16(ptr_u16.add(8))),
        xreinterpretq_f16_u16(vld1q_u16(ptr_u16.add(16))),
        xreinterpretq_f16_u16(vld1q_u16(ptr_u16.add(24))),
    )
}

#[inline]
pub(crate) unsafe fn xvget_low_f16(x: x_float16x8_t) -> x_float16x4_t {
    std::mem::transmute::<uint16x4_t, x_float16x4_t>(vget_low_u16(std::mem::transmute::<
        x_float16x8_t,
        uint16x8_t,
    >(x)))
}

#[inline]
pub(crate) unsafe fn xvget_high_f16(x: x_float16x8_t) -> x_float16x4_t {
    std::mem::transmute::<uint16x4_t, x_float16x4_t>(vget_high_u16(std::mem::transmute::<
        x_float16x8_t,
        uint16x8_t,
    >(x)))
}

#[inline]
pub(crate) unsafe fn xcombine_f16(low: x_float16x4_t, high: x_float16x4_t) -> x_float16x8_t {
    std::mem::transmute::<uint16x8_t, x_float16x8_t>(vcombine_u16(
        std::mem::transmute::<x_float16x4_t, uint16x4_t>(low),
        std::mem::transmute::<x_float16x4_t, uint16x4_t>(high),
    ))
}

#[inline]
pub(crate) unsafe fn xreinterpret_u16_f16(x: x_float16x4_t) -> uint16x4_t {
    std::mem::transmute(x)
}

#[inline]
pub(crate) unsafe fn xreinterpretq_u16_f16(x: x_float16x8_t) -> uint16x8_t {
    std::mem::transmute(x)
}

#[inline]
pub(crate) unsafe fn xreinterpret_f16_u16(x: uint16x4_t) -> x_float16x4_t {
    std::mem::transmute(x)
}

#[inline]
pub(crate) unsafe fn xreinterpretq_f16_u16(x: uint16x8_t) -> x_float16x8_t {
    std::mem::transmute(x)
}

/// Sets register to f16 zero
#[inline(always)]
pub(super) unsafe fn xvzerosq_f16() -> x_float16x8_t {
    xreinterpretq_f16_u16(vdupq_n_u16(0))
}

/// Sets register to f16 zero
#[inline(always)]
pub(super) unsafe fn xvzeros_f16() -> x_float16x4_t {
    xreinterpret_f16_u16(vdup_n_u16(0))
}

#[inline]
pub(crate) unsafe fn xvcvt_f32_f16(x: x_float16x4_t) -> float32x4_t {
    let src: uint16x4_t = xreinterpret_u16_f16(x);
    let dst: float32x4_t;
    asm!(
    "fcvtl {0:v}.4s, {1:v}.4h",
    out(vreg) dst,
    in(vreg) src,
    options(pure, nomem, nostack));
    dst
}

#[inline]
pub(super) unsafe fn xvcvt_f16_f32(v: float32x4_t) -> x_float16x4_t {
    let result: uint16x4_t;
    asm!(
    "fcvtn {0:v}.4h, {1:v}.4s",
    out(vreg) result,
    in(vreg) v,
    options(pure, nomem, nostack));
    xreinterpret_f16_u16(result)
}

/// This instruction converts each element in a vector from fixed-point to floating-point
/// using the rounding mode that is specified by the FPCR, and writes the result
/// to the SIMD&FP destination register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vcvtq_f16_u16)
#[inline]
#[target_feature(enable = "fp16")]
pub(super) unsafe fn xvcvtq_f16_u16(v: uint16x8_t) -> x_float16x8_t {
    let result: uint16x8_t;
    asm!(
    "ucvtf {0:v}.8h, {1:v}.8h",
    out(vreg) result,
    in(vreg) v,
    options(pure, nomem, nostack));
    xreinterpretq_f16_u16(result)
}

/// This instruction converts each element in a vector from fixed-point to floating-point
/// using the rounding mode that is specified by the FPCR, and writes the result
/// to the SIMD&FP destination register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vcvt_f16_u16)
#[inline]
#[target_feature(enable = "fp16")]
pub(super) unsafe fn xvcvt_f16_u16(v: uint16x4_t) -> x_float16x4_t {
    let result: uint16x4_t;
    asm!(
    "ucvtf {0:v}.4h, {1:v}.4h",
    out(vreg) result,
    in(vreg) v,
    options(pure, nomem, nostack));
    xreinterpret_f16_u16(result)
}

/// Floating-point Convert to Unsigned integer, rounding to nearest with ties to Away (vector).
/// This instruction converts each element in a vector from a floating-point value to an unsigned
/// integer value using the Round to Nearest with Ties to Away rounding mode and writes the result
/// to the SIMD&FP destination register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vcvtaq_u16_f16)
#[inline]
#[target_feature(enable = "fp16")]
pub(super) unsafe fn xvcvtaq_u16_f16(v: x_float16x8_t) -> uint16x8_t {
    let result: uint16x8_t;
    asm!(
    "fcvtau {0:v}.8h, {1:v}.8h",
    out(vreg) result,
    in(vreg) xreinterpretq_u16_f16(v),
    options(pure, nomem, nostack));
    result
}

/// Floating-point Convert to Unsigned integer, rounding to nearest with ties to Away (vector).
/// This instruction converts each element in a vector from a floating-point value to an unsigned
/// integer value using the Round to Nearest with Ties to Away rounding mode and writes the result
/// to the SIMD&FP destination register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vcvta_u16_f16)
#[inline]
#[target_feature(enable = "fp16")]
pub(super) unsafe fn xvcvta_u16_f16(v: x_float16x4_t) -> uint16x4_t {
    let result: uint16x4_t;
    asm!(
    "fcvtau {0:v}.4h, {1:v}.4h",
    out(vreg) result,
    in(vreg) xreinterpret_u16_f16(v),
    options(pure, nomem, nostack));
    result
}

/// Floating-point Reciprocal Estimate.
/// This instruction finds an approximate reciprocal estimate for each vector element
/// in the source SIMD&FP register, places the result in a vector,
/// and writes the vector to the destination SIMD&FP register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vrecpeq_f16)
#[inline]
#[target_feature(enable = "fp16")]
pub(super) unsafe fn xvrecpeq_f16(v: x_float16x8_t) -> x_float16x8_t {
    let result: uint16x8_t;
    asm!(
    "frecpe {0:v}.8h, {1:v}.8h",
    out(vreg) result,
    in(vreg) xreinterpretq_u16_f16(v),
    options(pure, nomem, nostack));
    xreinterpretq_f16_u16(result)
}

// #[inline]
// pub(super) unsafe fn xvadd_f16(v1: x_float16x4_t, v2: x_float16x4_t) -> x_float16x4_t {
//     let result: uint16x4_t;
//     asm!(
//     "fadd {0:v}.4h, {1:v}.4h, {2:v}.4h",
//     out(vreg) result,
//     in(vreg) xreinterpret_u16_f16(v1),
//     in(vreg) xreinterpret_u16_f16(v2),
//     options(pure, nomem, nostack)
//     );
//     xreinterpret_f16_u16(result)
// }

// #[inline]
// pub(super) unsafe fn xvaddq_f16(v1: x_float16x8_t, v2: x_float16x8_t) -> x_float16x8_t {
//     let result: uint16x8_t;
//     asm!(
//     "fadd {0:v}.8h, {1:v}.8h, {2:v}.8h",
//     out(vreg) result,
//     in(vreg) xreinterpretq_u16_f16(v1),
//     in(vreg) xreinterpretq_u16_f16(v2),
//     options(pure, nomem, nostack)
//     );
//     xreinterpretq_f16_u16(result)
// }

#[inline]
pub(super) unsafe fn xvcombine_f16(v1: x_float16x4_t, v2: x_float16x4_t) -> x_float16x8_t {
    xreinterpretq_f16_u16(vcombine_u16(
        xreinterpret_u16_f16(v1),
        xreinterpret_u16_f16(v2),
    ))
}

// #[inline]
// pub(super) unsafe fn xvmul_f16(v1: x_float16x4_t, v2: x_float16x4_t) -> x_float16x4_t {
//     let result: uint16x4_t;
//     asm!(
//     "fmul {0:v}.4h, {1:v}.4h, {2:v}.4h",
//     out(vreg) result,
//     in(vreg) xreinterpret_u16_f16(v1),
//     in(vreg) xreinterpret_u16_f16(v2),
//     options(pure, nomem, nostack)
//     );
//     xreinterpret_f16_u16(result)
// }

/// Floating-point fused Multiply-Add to accumulator (vector).
/// This instruction multiplies corresponding floating-point values in the vectors
/// in the two source SIMD&FP registers, adds the product to the corresponding vector element
/// of the destination SIMD&FP register, and writes the result to the destination SIMD&FP register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vfma_f16)
#[target_feature(enable = "fp16")]
#[inline]
pub(super) unsafe fn xvfmla_f16(
    a: x_float16x4_t,
    b: x_float16x4_t,
    c: x_float16x4_t,
) -> x_float16x4_t {
    let mut result: uint16x4_t = xreinterpret_u16_f16(a);
    asm!(
    "fmla {0:v}.4h, {1:v}.4h, {2:v}.4h",
    inout(vreg) result,
    in(vreg) xreinterpret_u16_f16(b),
    in(vreg) xreinterpret_u16_f16(c),
    options(pure, nomem, nostack)
    );
    xreinterpret_f16_u16(result)
}

/// Floating-point fused Multiply-Add to accumulator (vector).
/// This instruction multiplies corresponding floating-point values in the vectors
/// in the two source SIMD&FP registers, adds the product to the corresponding
/// vector element of the destination SIMD&FP register,
/// and writes the result to the destination SIMD&FP register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vfma_laneq_f16)
#[target_feature(enable = "fp16")]
#[inline]
pub(super) unsafe fn xvfmla_laneq_f16<const LANE: i32>(
    a: x_float16x4_t,
    b: x_float16x4_t,
    c: x_float16x8_t,
) -> x_float16x4_t {
    static_assert_uimm_bits!(LANE, 3);
    let mut result: uint16x4_t = xreinterpret_u16_f16(a);

    if LANE == 0 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.h[0]",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) xreinterpretq_u16_f16(c),
        options(pure, nomem, nostack)
        );
    } else if LANE == 1 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.h[1]",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) xreinterpretq_u16_f16(c),
        options(pure, nomem, nostack)
        );
    } else if LANE == 2 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.h[2]",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) xreinterpretq_u16_f16(c),
        options(pure, nomem, nostack)
        );
    } else if LANE == 3 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.h[3]",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) xreinterpretq_u16_f16(c),
        options(pure, nomem, nostack)
        );
    } else if LANE == 4 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.h[4]",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) xreinterpretq_u16_f16(c),
        options(pure, nomem, nostack)
        );
    } else if LANE == 5 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.h[5]",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) xreinterpretq_u16_f16(c),
        options(pure, nomem, nostack)
        );
    } else if LANE == 6 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.h[6]",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) xreinterpretq_u16_f16(c),
        options(pure, nomem, nostack)
        );
    } else if LANE == 7 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.h[7]",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) xreinterpretq_u16_f16(c),
        options(pure, nomem, nostack)
        );
    }
    xreinterpret_f16_u16(result)
}

/// Floating-point fused Multiply-Add to accumulator (vector).
/// This instruction multiplies corresponding floating-point values in the vectors
/// in the two source SIMD&FP registers, adds the product to the corresponding
/// vector element of the destination SIMD&FP register,
/// and writes the result to the destination SIMD&FP register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vfma_lane_f16)
#[target_feature(enable = "fp16")]
#[inline]
pub(super) unsafe fn xvfmla_lane_f16<const LANE: i32>(
    a: x_float16x4_t,
    b: x_float16x4_t,
    c: x_float16x4_t,
) -> x_float16x4_t {
    static_assert_uimm_bits!(LANE, 2);
    let mut result: uint16x4_t = xreinterpret_u16_f16(a);
    let lanes: uint16x8_t = vdupq_n_u16(vget_lane_u16::<LANE>(xreinterpret_u16_f16(c)));

    if LANE == 0 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.4h",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) lanes,
        options(pure, nomem, nostack)
        );
    } else if LANE == 1 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.4h",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) lanes,
        options(pure, nomem, nostack)
        );
    } else if LANE == 2 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.4h",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) lanes,
        options(pure, nomem, nostack)
        );
    } else if LANE == 3 {
        asm!(
        "fmla {0:v}.4h, {1:v}.4h, {2:v}.4h",
        inout(vreg) result,
        in(vreg) xreinterpret_u16_f16(b),
        in(vreg) lanes,
        options(pure, nomem, nostack)
        );
    }
    xreinterpret_f16_u16(result)
}

/// Floating-point fused Multiply-Add to accumulator (vector).
/// This instruction multiplies corresponding floating-point values in the vectors
/// in the two source SIMD&FP registers, adds the product to the corresponding
/// vector element of the destination SIMD&FP register,
/// and writes the result to the destination SIMD&FP register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vfmaq_lane_f16)
#[target_feature(enable = "fp16")]
#[inline]
pub(super) unsafe fn xvfmlaq_lane_f16<const LANE: i32>(
    a: x_float16x8_t,
    b: x_float16x8_t,
    c: x_float16x4_t,
) -> x_float16x8_t {
    static_assert_uimm_bits!(LANE, 2);
    let mut result: uint16x8_t = xreinterpretq_u16_f16(a);

    if LANE == 0 {
        asm!(
        "fmla {0:v}.8h, {1:v}.8h, {2:v}.h[0]",
        inout(vreg) result,
        in(vreg) xreinterpretq_u16_f16(b),
        in(vreg) xreinterpret_u16_f16(c),
        options(pure, nomem, nostack)
        );
    } else if LANE == 1 {
        asm!(
        "fmla {0:v}.8h, {1:v}.8h, {2:v}.h[1]",
        inout(vreg) result,
        in(vreg) xreinterpretq_u16_f16(b),
        in(vreg) xreinterpret_u16_f16(c),
        options(pure, nomem, nostack)
        );
    } else if LANE == 2 {
        asm!(
        "fmla {0:v}.8h, {1:v}.8h, {2:v}.h[2]",
        inout(vreg) result,
        in(vreg) xreinterpretq_u16_f16(b),
        in(vreg) xreinterpret_u16_f16(c),
        options(pure, nomem, nostack)
        );
    } else if LANE == 3 {
        asm!(
        "fmla {0:v}.8h, {1:v}.8h, {2:v}.h[3]",
        inout(vreg) result,
        in(vreg) xreinterpretq_u16_f16(b),
        in(vreg) xreinterpret_u16_f16(c),
        options(pure, nomem, nostack)
        );
    }
    xreinterpretq_f16_u16(result)
}

/// Floating-point fused Multiply-Add to accumulator (vector).
/// This instruction multiplies corresponding floating-point values in the vectors
/// in the two source SIMD&FP registers, adds the product to the corresponding
/// vector element of the destination SIMD&FP register,
/// and writes the result to the destination SIMD&FP register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vfmaq_f16)
#[target_feature(enable = "fp16")]
#[inline]
pub(super) unsafe fn xvfmlaq_f16(
    a: x_float16x8_t,
    b: x_float16x8_t,
    c: x_float16x8_t,
) -> x_float16x8_t {
    let mut result: uint16x8_t = xreinterpretq_u16_f16(a);
    asm!(
    "fmla {0:v}.8h, {1:v}.8h, {2:v}.8h",
    inout(vreg) result,
    in(vreg) xreinterpretq_u16_f16(b),
    in(vreg) xreinterpretq_u16_f16(c),
    options(pure, nomem, nostack)
    );
    xreinterpretq_f16_u16(result)
}

/// Floating-point Multiply (vector).
/// This instruction multiplies corresponding floating-point values in the vectors in the two
/// source SIMD&FP registers,
/// places the result in a vector, and writes the vector to the destination SIMD&FP register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vmulq_f16)
#[target_feature(enable = "fp16")]
#[inline]
pub(super) unsafe fn xvmulq_f16(v1: x_float16x8_t, v2: x_float16x8_t) -> x_float16x8_t {
    let result: uint16x8_t;
    asm!(
    "fmul {0:v}.8h, {1:v}.8h, {2:v}.8h",
    out(vreg) result,
    in(vreg) xreinterpretq_u16_f16(v1),
    in(vreg) xreinterpretq_u16_f16(v2),
    options(pure, nomem, nostack)
    );
    xreinterpretq_f16_u16(result)
}

/// Floating-point Multiply (vector).
/// This instruction multiplies corresponding floating-point values in the vectors
/// in the two source SIMD&FP registers, places the result in a vector,
/// and writes the vector to the destination SIMD&FP register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vmul_f16)
#[target_feature(enable = "fp16")]
#[inline]
pub(super) unsafe fn xvmul_f16(v1: x_float16x4_t, v2: x_float16x4_t) -> x_float16x4_t {
    let result: uint16x4_t;
    asm!(
    "fmul {0:v}.4h, {1:v}.4h, {2:v}.4h",
    out(vreg) result,
    in(vreg) xreinterpret_u16_f16(v1),
    in(vreg) xreinterpret_u16_f16(v2),
    options(pure, nomem, nostack)
    );
    xreinterpret_f16_u16(result)
}

/// Floating-point Divide (vector).
/// This instruction divides the floating-point values in the elements
/// in the first source SIMD&FP register, by the floating-point values
/// in the corresponding elements in the second source SIMD&FP register,
/// places the results in a vector, and writes the vector to the destination SIMD&FP register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vdivq_f16)
#[target_feature(enable = "fp16")]
#[inline]
pub(super) unsafe fn xvdivq_f16(v1: x_float16x8_t, v2: x_float16x8_t) -> x_float16x8_t {
    let result: uint16x8_t;
    asm!(
    "fdiv {0:v}.8h, {1:v}.8h, {2:v}.8h",
    out(vreg) result,
    in(vreg) xreinterpretq_u16_f16(v1),
    in(vreg) xreinterpretq_u16_f16(v2),
    options(pure, nomem, nostack)
    );
    xreinterpretq_f16_u16(result)
}

/// Bitwise Select.
/// This instruction sets each bit in the destination SIMD&FP register
/// to the corresponding bit from the first source SIMD&FP register when the
/// original destination bit was 1, otherwise from the second source SIMD&FP register.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vbslq_f16)
#[target_feature(enable = "fp16")]
#[inline]
pub(super) unsafe fn xvbslq_f16(
    a: uint16x8_t,
    b: x_float16x8_t,
    c: x_float16x8_t,
) -> x_float16x8_t {
    let mut result: uint16x8_t = a;
    asm!(
    "bsl {0:v}.16b, {1:v}.16b, {2:v}.16b",
    inout(vreg) result,
    in(vreg) xreinterpretq_u16_f16(b),
    in(vreg) xreinterpretq_u16_f16(c),
    options(pure, nomem, nostack)
    );
    xreinterpretq_f16_u16(result)
}

#[inline]
pub(crate) unsafe fn xvst_f16(ptr: *mut f16, x: x_float16x4_t) {
    vst1_u16(ptr as *mut u16, xreinterpret_u16_f16(x))
}

#[inline]
pub(crate) unsafe fn xvstq_f16(ptr: *mut f16, x: x_float16x8_t) {
    vst1q_u16(ptr as *mut u16, xreinterpretq_u16_f16(x))
}

#[inline]
pub(crate) unsafe fn xvstq_f16_x2(ptr: *mut f16, x: x_float16x8x2_t) {
    let ptr_u16 = ptr as *mut u16;
    vst1q_u16(ptr_u16, xreinterpretq_u16_f16(x.0));
    vst1q_u16(ptr_u16.add(8), xreinterpretq_u16_f16(x.1));
}

#[inline]
pub(crate) unsafe fn xvstq_f16_x4(ptr: *const f16, x: x_float16x8x4_t) {
    let ptr_u16 = ptr as *mut u16;
    vst1q_u16(ptr_u16, xreinterpretq_u16_f16(x.0));
    vst1q_u16(ptr_u16.add(8), xreinterpretq_u16_f16(x.1));
    vst1q_u16(ptr_u16.add(16), xreinterpretq_u16_f16(x.2));
    vst1q_u16(ptr_u16.add(24), xreinterpretq_u16_f16(x.3));
}

#[inline]
pub(crate) unsafe fn xvdup_lane_f16<const N: i32>(a: x_float16x4_t) -> x_float16x4_t {
    xreinterpret_f16_u16(vdup_lane_u16::<N>(xreinterpret_u16_f16(a)))
}

#[inline]
pub(crate) unsafe fn xvdup_laneq_f16<const N: i32>(a: x_float16x8_t) -> x_float16x4_t {
    xreinterpret_f16_u16(vdup_laneq_u16::<N>(xreinterpretq_u16_f16(a)))
}

#[inline]
pub(crate) unsafe fn xvld1q_lane_f16<const LANE: i32>(
    ptr: *const f16,
    src: x_float16x8_t,
) -> x_float16x8_t {
    xreinterpretq_f16_u16(vld1q_lane_u16::<LANE>(
        ptr as *const u16,
        xreinterpretq_u16_f16(src),
    ))
}

#[inline]
pub(crate) unsafe fn xvsetq_lane_f16<const LANE: i32>(v: f16, r: x_float16x8_t) -> x_float16x8_t {
    xreinterpretq_f16_u16(vsetq_lane_u16::<LANE>(
        v.to_bits(),
        xreinterpretq_u16_f16(r),
    ))
}

/// Floating-point Compare Equal to zero (vector).
/// This instruction reads each floating-point value in the source SIMD&FP register
/// and if the value is equal to zero sets every bit of the corresponding vector element
/// in the destination SIMD&FP register to one, otherwise sets every bit of the
/// corresponding vector element in the destination SIMD&FP register to zero.
///
/// [Arm's documentation](https://developer.arm.com/architectures/instruction-sets/intrinsics/vceqzq_f16)
#[target_feature(enable = "fp16")]
#[inline]
pub(crate) unsafe fn xvceqzq_f16(a: x_float16x8_t) -> uint16x8_t {
    let mut result: uint16x8_t;
    asm!(
    "fcmeq {0:v}.8h, {1:v}.8h, #0",
    out(vreg) result,
    in(vreg) xreinterpretq_u16_f16(a),
    options(pure, nomem, nostack)
    );
    result
}
