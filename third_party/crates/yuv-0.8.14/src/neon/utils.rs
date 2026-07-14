/*
 * Copyright (c) Radzivon Bartoshyk, 10/2024. All rights reserved.
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

use crate::yuv_support::YuvSourceChannels;
use crate::{YuvBytesPacking, YuvEndianness};
use std::arch::aarch64::*;

#[inline(always)]
#[cfg(feature = "professional_mode")]
pub(crate) unsafe fn vqddotl_laneq_s16<const PRECISION: i32, const LANE: i32>(
    acc: (int32x4_t, int32x4_t),
    v0: int16x8_t,
    c0: int16x8_t,
) -> int16x8_t {
    let hi = vqdmlal_high_laneq_s16::<LANE>(acc.1, v0, c0);
    let lo = vqdmlal_laneq_s16::<LANE>(acc.0, vget_low_s16(v0), c0);
    vcombine_s16(vshrn_n_s32::<PRECISION>(lo), vshrn_n_s32::<PRECISION>(hi))
}

#[inline(always)]
#[cfg(feature = "professional_mode")]
pub(crate) unsafe fn vqddotl_overflow_laneq_s16<
    const PRECISION: i32,
    const LANE0: i32,
    const LANE1: i32,
>(
    acc: (int32x4_t, int32x4_t),
    v0: int16x8_t,
    c0: int16x8_t,
) -> int16x8_t {
    let mut hi = vqdmlal_high_laneq_s16::<LANE0>(acc.1, v0, c0);
    let mut lo = vqdmlal_laneq_s16::<LANE0>(acc.0, vget_low_s16(v0), c0);
    hi = vqdmlal_high_laneq_s16::<LANE1>(hi, v0, c0);
    lo = vqdmlal_laneq_s16::<LANE1>(lo, vget_low_s16(v0), c0);
    vcombine_s16(vshrn_n_s32::<PRECISION>(lo), vshrn_n_s32::<PRECISION>(hi))
}

// #[inline(always)]
// pub(crate) unsafe fn vdotl_laneq_s16<const PRECISION: i32, const LANE: i32>(
//     acc: (int32x4_t, int32x4_t),
//     v0: int16x8_t,
//     c0: int16x8_t,
// ) -> int16x8_t {
//     let hi = vmlal_high_laneq_s16::<LANE>(acc.1, v0, c0);
//     let lo = vmlal_laneq_s16::<LANE>(acc.0, vget_low_s16(v0), c0);
//     vcombine_s16(vrshrn_n_s32::<PRECISION>(lo), vrshrn_n_s32::<PRECISION>(hi))
// }

// #[inline(always)]
// pub(crate) unsafe fn vdotl_laneq_s16_x2<
//     const PRECISION: i32,
//     const LANE0: i32,
//     const LANE1: i32,
// >(
//     acc: (int32x4_t, int32x4_t),
//     v0: int16x8_t,
//     v1: int16x8_t,
//     c0: int16x8_t,
// ) -> int16x8_t {
//     let mut hi = vmlal_high_laneq_s16::<LANE0>(acc.1, v0, c0);
//     let mut lo = vmlal_laneq_s16::<LANE0>(acc.0, vget_low_s16(v0), c0);
//     hi = vmlal_high_laneq_s16::<LANE1>(hi, v1, c0);
//     lo = vmlal_laneq_s16::<LANE1>(lo, vget_low_s16(v1), c0);
//     vcombine_s16(vrshrn_n_s32::<PRECISION>(lo), vrshrn_n_s32::<PRECISION>(hi))
// }

#[inline(always)]
pub(crate) unsafe fn vdotl_laneq_s16_x3<
    const PRECISION: i32,
    const LANE0: i32,
    const LANE1: i32,
    const LANE2: i32,
>(
    base: int32x4_t,
    v0: int16x8_t,
    v1: int16x8_t,
    v2: int16x8_t,
    c0: int16x8_t,
) -> int16x8_t {
    let mut hi = vmlal_high_laneq_s16::<LANE0>(base, v0, c0);
    let mut lo = vmlal_laneq_s16::<LANE0>(base, vget_low_s16(v0), c0);
    hi = vmlal_high_laneq_s16::<LANE1>(hi, v1, c0);
    lo = vmlal_laneq_s16::<LANE1>(lo, vget_low_s16(v1), c0);
    hi = vmlal_high_laneq_s16::<LANE2>(hi, v2, c0);
    lo = vmlal_laneq_s16::<LANE2>(lo, vget_low_s16(v2), c0);
    vcombine_s16(vshrn_n_s32::<PRECISION>(lo), vshrn_n_s32::<PRECISION>(hi))
}

#[inline(always)]
#[cfg(feature = "professional_mode")]
pub(crate) unsafe fn vqddotl_laneq_s16_x3<
    const PRECISION: i32,
    const LANE0: i32,
    const LANE1: i32,
    const LANE2: i32,
>(
    base: int32x4_t,
    v0: int16x8_t,
    v1: int16x8_t,
    v2: int16x8_t,
    c0: int16x8_t,
) -> int16x8_t {
    let mut hi = vqdmlal_high_laneq_s16::<LANE0>(base, v0, c0);
    let mut lo = vqdmlal_laneq_s16::<LANE0>(base, vget_low_s16(v0), c0);
    hi = vqdmlal_high_laneq_s16::<LANE1>(hi, v1, c0);
    lo = vqdmlal_laneq_s16::<LANE1>(lo, vget_low_s16(v1), c0);
    hi = vqdmlal_high_laneq_s16::<LANE2>(hi, v2, c0);
    lo = vqdmlal_laneq_s16::<LANE2>(lo, vget_low_s16(v2), c0);
    vcombine_s16(vshrn_n_s32::<PRECISION>(lo), vshrn_n_s32::<PRECISION>(hi))
}

#[inline(always)]
pub(crate) unsafe fn vdotl_laneq_u16_x3<
    const PRECISION: i32,
    const LANE0: i32,
    const LANE1: i32,
    const LANE2: i32,
>(
    base: uint32x4_t,
    v0: uint16x8_t,
    v1: uint16x8_t,
    v2: uint16x8_t,
    c0: uint16x8_t,
) -> uint16x8_t {
    let mut hi = vmlal_high_laneq_u16::<LANE0>(base, v0, c0);
    let mut lo = vmlal_laneq_u16::<LANE0>(base, vget_low_u16(v0), c0);
    hi = vmlal_high_laneq_u16::<LANE1>(hi, v1, c0);
    lo = vmlal_laneq_u16::<LANE1>(lo, vget_low_u16(v1), c0);
    hi = vmlal_high_laneq_u16::<LANE2>(hi, v2, c0);
    lo = vmlal_laneq_u16::<LANE2>(lo, vget_low_u16(v2), c0);
    vcombine_u16(vshrn_n_u32::<PRECISION>(lo), vshrn_n_u32::<PRECISION>(hi))
}

// #[inline(always)]
// pub(crate) unsafe fn vraddn_dot<const PRECISION: i32>(
//     acc: (int32x4_t, int32x4_t),
//     w: (int32x4_t, int32x4_t),
// ) -> int16x8_t {
//     vcombine_s16(
//         vrshrn_n_s32::<PRECISION>(vaddq_s32(acc.0, w.0)),
//         vrshrn_n_s32::<PRECISION>(vaddq_s32(acc.1, w.1)),
//     )
// }

#[inline(always)]
#[cfg(feature = "professional_mode")]
pub(crate) unsafe fn vaddn_dot<const PRECISION: i32>(
    acc: (int32x4_t, int32x4_t),
    w: (int32x4_t, int32x4_t),
) -> int16x8_t {
    vcombine_s16(
        vshrn_n_s32::<PRECISION>(vaddq_s32(acc.0, w.0)),
        vshrn_n_s32::<PRECISION>(vaddq_s32(acc.1, w.1)),
    )
}

// #[inline(always)]
// pub(crate) unsafe fn vweight_laneq_x2<const LANE0: i32, const LANE1: i32>(
//     v0: int16x8_t,
//     v1: int16x8_t,
//     c1: int16x8_t,
// ) -> (int32x4_t, int32x4_t) {
//     let mut lo = vmull_laneq_s16::<LANE0>(vget_low_s16(v0), c1);
//     let mut hi = vmull_high_laneq_s16::<LANE0>(v0, c1);
//     lo = vmlal_laneq_s16::<LANE1>(lo, vget_low_s16(v1), c1);
//     hi = vmlal_high_laneq_s16::<LANE1>(hi, v1, c1);
//     (lo, hi)
// }

#[inline(always)]
#[cfg(feature = "professional_mode")]
pub(crate) unsafe fn vqdweight_laneq_x2<const LANE0: i32, const LANE1: i32>(
    v0: int16x8_t,
    v1: int16x8_t,
    c1: int16x8_t,
) -> (int32x4_t, int32x4_t) {
    let mut lo = vqdmull_laneq_s16::<LANE0>(vget_low_s16(v0), c1);
    let mut hi = vqdmull_high_laneq_s16::<LANE0>(v0, c1);
    lo = vqdmlal_laneq_s16::<LANE1>(lo, vget_low_s16(v1), c1);
    hi = vqdmlal_high_laneq_s16::<LANE1>(hi, v1, c1);
    (lo, hi)
}

// #[inline(always)]
// pub(crate) unsafe fn vmullq_laneq_s16<const LANE: i32>(
//     v: int16x8_t,
//     q: int16x8_t,
// ) -> (int32x4_t, int32x4_t) {
//     (
//         vmull_laneq_s16::<LANE>(vget_low_s16(v), q),
//         vmull_high_laneq_s16::<LANE>(v, q),
//     )
// }

#[inline(always)]
#[cfg(feature = "professional_mode")]
pub(crate) unsafe fn vqdmalq_laneq_s16<const LANE: i32>(
    a: int32x4_t,
    v: int16x8_t,
    q: int16x8_t,
) -> (int32x4_t, int32x4_t) {
    (
        vqdmlal_laneq_s16::<LANE>(a, vget_low_s16(v), q),
        vqdmlal_high_laneq_s16::<LANE>(a, v, q),
    )
}

#[inline(always)]
pub(crate) unsafe fn vmullnq_s16<const PRECISION: i32>(v: uint16x8_t, q: uint16x8_t) -> uint16x8_t {
    let hi = vmull_high_u16(q, v);
    let lo = vmull_u16(vget_low_u16(q), vget_low_u16(v));
    vcombine_u16(vrshrn_n_u32::<PRECISION>(lo), vrshrn_n_u32::<PRECISION>(hi))
}

// #[inline(always)]
// pub(crate) unsafe fn neon_div_by_255(v: uint16x8_t) -> uint8x8_t {
//     let addition = vdupq_n_u16(127);
//     vqshrn_n_u16::<8>(vrsraq_n_u16::<8>(vaddq_u16(v, addition), v))
// }

#[inline(always)]
pub(crate) unsafe fn neon_premultiply_alpha(v: uint8x16_t, a_values: uint8x16_t) -> uint8x16_t {
    let acc_hi = vmull_high_u8(v, a_values);
    let acc_lo = vmull_u8(vget_low_u8(v), vget_low_u8(a_values));
    let addition = vdupq_n_u16(127);
    let jh = vaddq_u16(acc_hi, addition);
    let jl = vaddq_u16(acc_lo, addition);

    let bh = vrsraq_n_u16::<8>(jh, acc_hi);
    let bl = vrsraq_n_u16::<8>(jl, acc_lo);

    let hi = vqshrn_n_u16::<8>(bh);
    let lo = vqshrn_n_u16::<8>(bl);
    vcombine_u8(lo, hi)
}

#[inline(always)]
pub(crate) unsafe fn vld_s16_endian<
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
>(
    ptr: *const u16,
) -> int16x4_t {
    let _endianness: YuvEndianness = ENDIANNESS.into();
    let bytes_position: YuvBytesPacking = BYTES_POSITION.into();
    let mut v = vld1_u16(ptr);
    #[cfg(all(feature = "big_endian", target_endian = "little"))]
    if _endianness == YuvEndianness::BigEndian {
        v = vreinterpret_u16_u8(vrev16_u8(vreinterpret_u8_u16(v)));
    }
    if bytes_position == YuvBytesPacking::MostSignificantBytes {
        if BIT_DEPTH == 10 {
            v = vshr_n_u16::<6>(v);
        } else if BIT_DEPTH == 12 {
            v = vshr_n_u16::<4>(v);
        } else if BIT_DEPTH == 14 {
            v = vshr_n_u16::<2>(v);
        }
    }
    vreinterpret_s16_u16(v)
}

#[inline(always)]
pub(crate) unsafe fn vldq_s16_endian<
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
>(
    ptr: *const u16,
) -> int16x8_t {
    let _endianness: YuvEndianness = ENDIANNESS.into();
    let bytes_position: YuvBytesPacking = BYTES_POSITION.into();
    let mut v = vld1q_u16(ptr);
    #[cfg(all(feature = "big_endian", target_endian = "little"))]
    if _endianness == YuvEndianness::BigEndian {
        v = vreinterpretq_u16_u8(vrev16q_u8(vreinterpretq_u8_u16(v)));
    }
    if bytes_position == YuvBytesPacking::MostSignificantBytes {
        if BIT_DEPTH == 10 {
            v = vshrq_n_u16::<6>(v);
        } else if BIT_DEPTH == 12 {
            v = vshrq_n_u16::<4>(v);
        } else if BIT_DEPTH == 14 {
            v = vshrq_n_u16::<2>(v);
        }
    }
    vreinterpretq_s16_u16(v)
}

#[inline(always)]
pub(crate) unsafe fn xvld1q_u8_x2(src: *const u8) -> uint8x16x2_t {
    uint8x16x2_t(vld1q_u8(src), vld1q_u8(src.add(16)))
}

#[inline(always)]
pub(crate) unsafe fn xvst1q_u8_x2(ptr: *mut u8, b: uint8x16x2_t) {
    vst1q_u8(ptr, b.0);
    vst1q_u8(ptr.add(16), b.1);
}

#[inline(always)]
pub(crate) unsafe fn neon_vld_rgb_for_yuv<const ORIGINS: u8>(
    ptr: *const u8,
) -> (uint8x16_t, uint8x16_t, uint8x16_t) {
    let source_channels: YuvSourceChannels = ORIGINS.into();
    let r_values_u8: uint8x16_t;
    let g_values_u8: uint8x16_t;
    let b_values_u8: uint8x16_t;

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let rgb_values = vld3q_u8(ptr);
            if source_channels == YuvSourceChannels::Rgb {
                r_values_u8 = rgb_values.0;
                g_values_u8 = rgb_values.1;
                b_values_u8 = rgb_values.2;
            } else {
                r_values_u8 = rgb_values.2;
                g_values_u8 = rgb_values.1;
                b_values_u8 = rgb_values.0;
            }
        }
        YuvSourceChannels::Rgba => {
            let rgb_values = vld4q_u8(ptr);
            r_values_u8 = rgb_values.0;
            g_values_u8 = rgb_values.1;
            b_values_u8 = rgb_values.2;
        }
        YuvSourceChannels::Bgra => {
            let rgb_values = vld4q_u8(ptr);
            r_values_u8 = rgb_values.2;
            g_values_u8 = rgb_values.1;
            b_values_u8 = rgb_values.0;
        }
    }
    (r_values_u8, g_values_u8, b_values_u8)
}

#[inline(always)]
pub(crate) unsafe fn neon_vld_rgb<const ORIGINS: u8>(
    ptr: *const u8,
) -> (uint8x16_t, uint8x16_t, uint8x16_t, uint8x16_t) {
    let source_channels: YuvSourceChannels = ORIGINS.into();
    let r_values_u8: uint8x16_t;
    let g_values_u8: uint8x16_t;
    let b_values_u8: uint8x16_t;
    let a_vals: uint8x16_t;

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let rgb_values = vld3q_u8(ptr);
            if source_channels == YuvSourceChannels::Rgb {
                r_values_u8 = rgb_values.0;
                g_values_u8 = rgb_values.1;
                b_values_u8 = rgb_values.2;
            } else {
                r_values_u8 = rgb_values.2;
                g_values_u8 = rgb_values.1;
                b_values_u8 = rgb_values.0;
            }
            a_vals = vdupq_n_u8(255);
        }
        YuvSourceChannels::Rgba => {
            let rgb_values = vld4q_u8(ptr);
            r_values_u8 = rgb_values.0;
            g_values_u8 = rgb_values.1;
            b_values_u8 = rgb_values.2;
            a_vals = rgb_values.3;
        }
        YuvSourceChannels::Bgra => {
            let rgb_values = vld4q_u8(ptr);
            r_values_u8 = rgb_values.2;
            g_values_u8 = rgb_values.1;
            b_values_u8 = rgb_values.0;
            a_vals = rgb_values.3;
        }
    }
    (r_values_u8, g_values_u8, b_values_u8, a_vals)
}

#[inline(always)]
pub(crate) unsafe fn neon_vld_h_rgb_for_yuv<const ORIGINS: u8>(
    ptr: *const u8,
) -> (uint8x8_t, uint8x8_t, uint8x8_t) {
    let source_channels: YuvSourceChannels = ORIGINS.into();
    let r_values_u8: uint8x8_t;
    let g_values_u8: uint8x8_t;
    let b_values_u8: uint8x8_t;

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let rgb_values = vld3_u8(ptr);
            if source_channels == YuvSourceChannels::Rgb {
                r_values_u8 = rgb_values.0;
                g_values_u8 = rgb_values.1;
                b_values_u8 = rgb_values.2;
            } else {
                r_values_u8 = rgb_values.2;
                g_values_u8 = rgb_values.1;
                b_values_u8 = rgb_values.0;
            }
        }
        YuvSourceChannels::Rgba => {
            let rgb_values = vld4_u8(ptr);
            r_values_u8 = rgb_values.0;
            g_values_u8 = rgb_values.1;
            b_values_u8 = rgb_values.2;
        }
        YuvSourceChannels::Bgra => {
            let rgb_values = vld4_u8(ptr);
            r_values_u8 = rgb_values.2;
            g_values_u8 = rgb_values.1;
            b_values_u8 = rgb_values.0;
        }
    }
    (r_values_u8, g_values_u8, b_values_u8)
}

#[inline(always)]
pub(crate) unsafe fn neon_vld_h_rgb<const ORIGINS: u8>(
    ptr: *const u8,
) -> (uint8x8_t, uint8x8_t, uint8x8_t, uint8x8_t) {
    let source_channels: YuvSourceChannels = ORIGINS.into();
    let r_values_u8: uint8x8_t;
    let g_values_u8: uint8x8_t;
    let b_values_u8: uint8x8_t;
    let a_vals: uint8x8_t;

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let rgb_values = vld3_u8(ptr);
            if source_channels == YuvSourceChannels::Rgb {
                r_values_u8 = rgb_values.0;
                g_values_u8 = rgb_values.1;
                b_values_u8 = rgb_values.2;
            } else {
                r_values_u8 = rgb_values.2;
                g_values_u8 = rgb_values.1;
                b_values_u8 = rgb_values.0;
            }
            a_vals = vdup_n_u8(0);
        }
        YuvSourceChannels::Rgba => {
            let rgb_values = vld4_u8(ptr);
            r_values_u8 = rgb_values.0;
            g_values_u8 = rgb_values.1;
            b_values_u8 = rgb_values.2;
            a_vals = rgb_values.3;
        }
        YuvSourceChannels::Bgra => {
            let rgb_values = vld4_u8(ptr);
            r_values_u8 = rgb_values.2;
            g_values_u8 = rgb_values.1;
            b_values_u8 = rgb_values.0;
            a_vals = rgb_values.3;
        }
    }
    (r_values_u8, g_values_u8, b_values_u8, a_vals)
}

#[inline(always)]
pub(crate) unsafe fn neon_vld_rgb16_for_yuv<const ORIGINS: u8>(
    ptr: *const u16,
) -> (uint16x8_t, uint16x8_t, uint16x8_t) {
    let source_channels: YuvSourceChannels = ORIGINS.into();
    let r_values;
    let g_values;
    let b_values;

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let rgb_values = vld3q_u16(ptr);
            if source_channels == YuvSourceChannels::Rgb {
                r_values = rgb_values.0;
                g_values = rgb_values.1;
                b_values = rgb_values.2;
            } else {
                r_values = rgb_values.2;
                g_values = rgb_values.1;
                b_values = rgb_values.0;
            }
        }
        YuvSourceChannels::Rgba => {
            let rgb_values = vld4q_u16(ptr);
            r_values = rgb_values.0;
            g_values = rgb_values.1;
            b_values = rgb_values.2;
        }
        YuvSourceChannels::Bgra => {
            let rgb_values = vld4q_u16(ptr);
            r_values = rgb_values.2;
            g_values = rgb_values.1;
            b_values = rgb_values.0;
        }
    }
    (r_values, g_values, b_values)
}

#[inline(always)]
pub(crate) unsafe fn neon_store_rgb16<const ORIGINS: u8>(
    ptr: *mut u16,
    r_values: uint16x8_t,
    g_values: uint16x8_t,
    b_values: uint16x8_t,
    v_max_colors: uint16x8_t,
) {
    let destination_channels: YuvSourceChannels = ORIGINS.into();
    match destination_channels {
        YuvSourceChannels::Rgb => {
            let dst_pack = uint16x8x3_t(r_values, g_values, b_values);
            vst3q_u16(ptr, dst_pack);
        }
        YuvSourceChannels::Bgr => {
            let dst_pack = uint16x8x3_t(b_values, g_values, r_values);
            vst3q_u16(ptr, dst_pack);
        }
        YuvSourceChannels::Rgba => {
            let dst_pack = uint16x8x4_t(r_values, g_values, b_values, v_max_colors);
            vst4q_u16(ptr, dst_pack);
        }
        YuvSourceChannels::Bgra => {
            let dst_pack = uint16x8x4_t(b_values, g_values, r_values, v_max_colors);
            vst4q_u16(ptr, dst_pack);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn neon_store_half_rgb16<const ORIGINS: u8>(
    ptr: *mut u16,
    r_values: uint16x4_t,
    g_values: uint16x4_t,
    b_values: uint16x4_t,
    v_max_colors: uint16x4_t,
) {
    let destination_channels: YuvSourceChannels = ORIGINS.into();
    match destination_channels {
        YuvSourceChannels::Rgb => {
            let dst_pack = uint16x4x3_t(r_values, g_values, b_values);
            vst3_u16(ptr, dst_pack);
        }
        YuvSourceChannels::Bgr => {
            let dst_pack = uint16x4x3_t(b_values, g_values, r_values);
            vst3_u16(ptr, dst_pack);
        }
        YuvSourceChannels::Rgba => {
            let dst_pack = uint16x4x4_t(r_values, g_values, b_values, v_max_colors);
            vst4_u16(ptr, dst_pack);
        }
        YuvSourceChannels::Bgra => {
            let dst_pack = uint16x4x4_t(b_values, g_values, r_values, v_max_colors);
            vst4_u16(ptr, dst_pack);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn neon_store_rgb8<const ORIGINS: u8>(
    ptr: *mut u8,
    r_values: uint8x16_t,
    g_values: uint8x16_t,
    b_values: uint8x16_t,
    v_max_colors: uint8x16_t,
) {
    let destination_channels: YuvSourceChannels = ORIGINS.into();
    match destination_channels {
        YuvSourceChannels::Rgb => {
            let dst_pack: uint8x16x3_t = uint8x16x3_t(r_values, g_values, b_values);
            vst3q_u8(ptr, dst_pack);
        }
        YuvSourceChannels::Bgr => {
            let dst_pack: uint8x16x3_t = uint8x16x3_t(b_values, g_values, r_values);
            vst3q_u8(ptr, dst_pack);
        }
        YuvSourceChannels::Rgba => {
            let dst_pack: uint8x16x4_t = uint8x16x4_t(r_values, g_values, b_values, v_max_colors);
            vst4q_u8(ptr, dst_pack);
        }
        YuvSourceChannels::Bgra => {
            let dst_pack: uint8x16x4_t = uint8x16x4_t(b_values, g_values, r_values, v_max_colors);
            vst4q_u8(ptr, dst_pack);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn neon_store_half_rgb8<const ORIGINS: u8>(
    ptr: *mut u8,
    r_values: uint8x8_t,
    g_values: uint8x8_t,
    b_values: uint8x8_t,
    v_max_colors: uint8x8_t,
) {
    let destination_channels: YuvSourceChannels = ORIGINS.into();
    match destination_channels {
        YuvSourceChannels::Rgb => {
            let dst_pack: uint8x8x3_t = uint8x8x3_t(r_values, g_values, b_values);
            vst3_u8(ptr, dst_pack);
        }
        YuvSourceChannels::Bgr => {
            let dst_pack: uint8x8x3_t = uint8x8x3_t(b_values, g_values, r_values);
            vst3_u8(ptr, dst_pack);
        }
        YuvSourceChannels::Rgba => {
            let dst_pack: uint8x8x4_t = uint8x8x4_t(r_values, g_values, b_values, v_max_colors);
            vst4_u8(ptr, dst_pack);
        }
        YuvSourceChannels::Bgra => {
            let dst_pack: uint8x8x4_t = uint8x8x4_t(b_values, g_values, r_values, v_max_colors);
            vst4_u8(ptr, dst_pack);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn vtomsb_u16<const BIT_DEPTH: usize>(a: uint16x4_t) -> uint16x4_t {
    if BIT_DEPTH == 10 {
        vshl_n_u16::<6>(a)
    } else if BIT_DEPTH == 12 {
        vshl_n_u16::<4>(a)
    } else if BIT_DEPTH == 14 {
        vshl_n_u16::<2>(a)
    } else {
        a
    }
}

#[inline(always)]
pub(crate) unsafe fn vtomsbq_u16<const BIT_DEPTH: usize>(a: uint16x8_t) -> uint16x8_t {
    if BIT_DEPTH == 10 {
        vshlq_n_u16::<6>(a)
    } else if BIT_DEPTH == 12 {
        vshlq_n_u16::<4>(a)
    } else if BIT_DEPTH == 14 {
        vshlq_n_u16::<2>(a)
    } else {
        a
    }
}

#[inline(always)]
pub(crate) unsafe fn vfrommsb_u16<const BIT_DEPTH: usize>(a: uint16x4_t) -> uint16x4_t {
    if BIT_DEPTH == 10 {
        vshr_n_u16::<6>(a)
    } else if BIT_DEPTH == 12 {
        vshr_n_u16::<4>(a)
    } else if BIT_DEPTH == 14 {
        vshr_n_u16::<2>(a)
    } else {
        a
    }
}

#[inline(always)]
pub(crate) unsafe fn vfrommsbq_u16<const BIT_DEPTH: usize>(a: uint16x8_t) -> uint16x8_t {
    if BIT_DEPTH == 10 {
        vshrq_n_u16::<6>(a)
    } else if BIT_DEPTH == 12 {
        vshrq_n_u16::<4>(a)
    } else if BIT_DEPTH == 14 {
        vshrq_n_u16::<2>(a)
    } else {
        a
    }
}

#[inline(always)]
pub(crate) unsafe fn vpackq_n_shift16<const BIT_DEPTH: usize>(a: uint16x8_t) -> uint8x8_t {
    if BIT_DEPTH == 10 {
        vqshrn_n_u16::<2>(a)
    } else if BIT_DEPTH == 12 {
        vqshrn_n_u16::<4>(a)
    } else if BIT_DEPTH == 14 {
        vqshrn_n_u16::<6>(a)
    } else if BIT_DEPTH == 16 {
        vqshrn_n_u16::<8>(a)
    } else {
        vqmovn_u16(a)
    }
}

#[inline(always)]
pub(crate) unsafe fn vpackuq_n_shift16<const BIT_DEPTH: usize>(a: int16x8_t) -> uint8x8_t {
    if BIT_DEPTH == 10 {
        vqshrun_n_s16::<2>(a)
    } else if BIT_DEPTH == 12 {
        vqshrun_n_s16::<4>(a)
    } else if BIT_DEPTH == 14 {
        vqshrun_n_s16::<6>(a)
    } else if BIT_DEPTH == 16 {
        vqshrun_n_s16::<8>(a)
    } else {
        vqmovun_s16(a)
    }
}

/// Expands exactly 8 bit to 10
#[inline(always)]
pub(crate) unsafe fn vexpand8_to_10(a: uint8x8_t) -> uint16x8_t {
    let k = vcombine_u8(a, a);
    vrshrq_n_u16::<6>(vreinterpretq_u16_u8(vzip1q_u8(k, k)))
}

/// Expands exactly 8 bit to 10
#[inline(always)]
pub(crate) unsafe fn vexpand_high_8_to_10(a: uint8x16_t) -> uint16x8_t {
    vrshrq_n_u16::<6>(vreinterpretq_u16_u8(vzip2q_u8(a, a)))
}

#[cfg(feature = "rdm")]
#[inline(always)]
pub(crate) unsafe fn vexpand_high_bp_by_2<const BIT_DEPTH: usize>(v: int16x8_t) -> int16x8_t {
    vreinterpretq_s16_u16(vexpandu_high_bp_by_2::<BIT_DEPTH>(vreinterpretq_u16_s16(v)))
}

#[cfg(feature = "rdm")]
#[inline(always)]
pub(crate) unsafe fn vexpandu_high_bp_by_2<const BIT_DEPTH: usize>(v: uint16x8_t) -> uint16x8_t {
    if BIT_DEPTH == 10 {
        vorrq_u16(vshlq_n_u16::<2>(v), vshrq_n_u16::<8>(v))
    } else if BIT_DEPTH == 12 {
        vorrq_u16(vshlq_n_u16::<2>(v), vshrq_n_u16::<10>(v))
    } else {
        v
    }
}

#[inline]
#[target_feature(enable = "rdm")]
pub(crate) unsafe fn xqdmlahq_laneq_s16<const LANE: i32, const R: bool>(
    a: int16x8_t,
    b: int16x8_t,
    c: int16x8_t,
) -> int16x8_t {
    if R {
        vqrdmlahq_laneq_s16::<LANE>(a, b, c)
    } else {
        vaddq_s16(a, vqdmulhq_laneq_s16::<LANE>(b, c))
    }
}

#[inline(always)]
pub(crate) unsafe fn xqdmulhq_laneq_s16<const LANE: i32, const R: bool>(
    a: int16x8_t,
    b: int16x8_t,
) -> int16x8_t {
    if R {
        vqrdmulhq_laneq_s16::<LANE>(a, b)
    } else {
        vqdmulhq_laneq_s16::<LANE>(a, b)
    }
}

#[inline(always)]
pub(crate) unsafe fn xqdmulhq_n_s16<const R: bool>(a: int16x8_t, b: i16) -> int16x8_t {
    if R {
        vqrdmulhq_n_s16(a, b)
    } else {
        vqdmulhq_n_s16(a, b)
    }
}

#[inline(always)]
pub(crate) fn xvld1_4u8(ptr: *const u8) -> uint8x8_t {
    unsafe { vreinterpret_u8_u32(vld1_lane_u32::<0>(ptr.cast(), vdup_n_u32(0))) }
}

#[inline(always)]
pub(crate) fn xvld1_2u16(ptr: *const u16) -> uint16x4_t {
    unsafe { vreinterpret_u16_u32(vld1_lane_u32::<0>(ptr.cast(), vdup_n_u32(0))) }
}
