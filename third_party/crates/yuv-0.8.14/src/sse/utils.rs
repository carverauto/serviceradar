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
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

#[inline(always)]
#[allow(dead_code)]
pub(crate) const fn shuffle(z: u32, y: u32, x: u32, w: u32) -> i32 {
    ((z << 6) | (y << 4) | (x << 2) | w) as i32
}

#[inline(always)]
pub(crate) unsafe fn sse_interleave_rgba(
    r: __m128i,
    g: __m128i,
    b: __m128i,
    a: __m128i,
) -> (__m128i, __m128i, __m128i, __m128i) {
    let rg_lo = _mm_unpacklo_epi8(r, g);
    let rg_hi = _mm_unpackhi_epi8(r, g);
    let ba_lo = _mm_unpacklo_epi8(b, a);
    let ba_hi = _mm_unpackhi_epi8(b, a);

    let rgba_0_lo = _mm_unpacklo_epi16(rg_lo, ba_lo);
    let rgba_0_hi = _mm_unpackhi_epi16(rg_lo, ba_lo);
    let rgba_1_lo = _mm_unpacklo_epi16(rg_hi, ba_hi);
    let rgba_1_hi = _mm_unpackhi_epi16(rg_hi, ba_hi);
    (rgba_0_lo, rgba_0_hi, rgba_1_lo, rgba_1_hi)
}

#[inline(always)]
pub(crate) unsafe fn sse_store_rgba(ptr: *mut u8, r: __m128i, g: __m128i, b: __m128i, a: __m128i) {
    let (row1, row2, row3, row4) = sse_interleave_rgba(r, g, b, a);
    _mm_storeu_si128(ptr as *mut __m128i, row1);
    _mm_storeu_si128(ptr.add(16) as *mut __m128i, row2);
    _mm_storeu_si128(ptr.add(32) as *mut __m128i, row3);
    _mm_storeu_si128(ptr.add(48) as *mut __m128i, row4);
}

#[inline(always)]
pub(crate) unsafe fn sse_deinterleave_rgba(
    rgba0: __m128i,
    rgba1: __m128i,
    rgba2: __m128i,
    rgba3: __m128i,
) -> (__m128i, __m128i, __m128i, __m128i) {
    let t0 = _mm_unpacklo_epi8(rgba0, rgba1); // r1 R1 g1 G1 b1 B1 a1 A1 r2 R2 g2 G2 b2 B2 a2 A2
    let t1 = _mm_unpackhi_epi8(rgba0, rgba1);
    let t2 = _mm_unpacklo_epi8(rgba2, rgba3); // r4 R4 g4 G4 b4 B4 a4 A4 r5 R5 g5 G5 b5 B5 a5 A5
    let t3 = _mm_unpackhi_epi8(rgba2, rgba3);

    let t4 = _mm_unpacklo_epi16(t0, t2); // r1 R1 r4 R4 g1 G1 G4 g4 G4 b1 B1 b4 B4 a1 A1 a4 A4
    let t5 = _mm_unpackhi_epi16(t0, t2);
    let t6 = _mm_unpacklo_epi16(t1, t3);
    let t7 = _mm_unpackhi_epi16(t1, t3);

    let l1 = _mm_unpacklo_epi32(t4, t6); // r1 R1 r4 R4 g1 G1 G4 g4 G4 b1 B1 b4 B4 a1 A1 a4 A4
    let l2 = _mm_unpackhi_epi32(t4, t6);
    let l3 = _mm_unpacklo_epi32(t5, t7);
    let l4 = _mm_unpackhi_epi32(t5, t7);

    #[rustfmt::skip]
    let shuffle = _mm_setr_epi8(0, 4, 8, 12,
                                        1, 5, 9, 13,
                                        2, 6, 10, 14,
                                        3, 7, 11, 15,
    );

    let r1 = _mm_shuffle_epi8(_mm_unpacklo_epi32(l1, l3), shuffle);
    let r2 = _mm_shuffle_epi8(_mm_unpackhi_epi32(l1, l3), shuffle);
    let r3 = _mm_shuffle_epi8(_mm_unpacklo_epi32(l2, l4), shuffle);
    let r4 = _mm_shuffle_epi8(_mm_unpackhi_epi32(l2, l4), shuffle);

    (r1, r2, r3, r4)
}

#[inline(always)]
pub(crate) unsafe fn sse_deinterleave_rgb(
    rgb0: __m128i,
    rgb1: __m128i,
    rgb2: __m128i,
) -> (__m128i, __m128i, __m128i) {
    #[rustfmt::skip]
    let idx = _mm_setr_epi8(0, 3, 6, 9,
                                    12, 15, 2, 5, 8,
                                    11, 14, 1, 4, 7,
                                    10, 13);

    let r6b5g5_0 = _mm_shuffle_epi8(rgb0, idx);
    let g6r5b5_1 = _mm_shuffle_epi8(rgb1, idx);
    let b6g5r5_2 = _mm_shuffle_epi8(rgb2, idx);

    #[rustfmt::skip]
    let mask010 = _mm_setr_epi8(0, 0, 0, 0,
                                        0, 0, -1, -1, -1,
                                        -1, -1, 0, 0, 0,
                                        0, 0);

    #[rustfmt::skip]
    let mask001 = _mm_setr_epi8(0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, 0,
                                    -1, -1, -1, -1, -1);

    let b2g2b1 = _mm_blendv_epi8(b6g5r5_2, g6r5b5_1, mask001);
    let b2b0b1 = _mm_blendv_epi8(b2g2b1, r6b5g5_0, mask010);

    let r0r1b1 = _mm_blendv_epi8(r6b5g5_0, g6r5b5_1, mask010);
    let r0r1r2 = _mm_blendv_epi8(r0r1b1, b6g5r5_2, mask001);

    let g1r1g0 = _mm_blendv_epi8(g6r5b5_1, r6b5g5_0, mask001);
    let g1g2g0 = _mm_blendv_epi8(g1r1g0, b6g5r5_2, mask010);

    let g0g1g2 = _mm_alignr_epi8::<11>(g1g2g0, g1g2g0);
    let b0b1b2 = _mm_alignr_epi8::<6>(b2b0b1, b2b0b1);

    (r0r1r2, g0g1g2, b0b1b2)
}

#[inline(always)]
pub(crate) unsafe fn sse_interleave_rgb(
    r: __m128i,
    g: __m128i,
    b: __m128i,
) -> (__m128i, __m128i, __m128i) {
    let sh_a = _mm_setr_epi8(0, 11, 6, 1, 12, 7, 2, 13, 8, 3, 14, 9, 4, 15, 10, 5);
    let sh_b = _mm_setr_epi8(5, 0, 11, 6, 1, 12, 7, 2, 13, 8, 3, 14, 9, 4, 15, 10);
    let sh_c = _mm_setr_epi8(10, 5, 0, 11, 6, 1, 12, 7, 2, 13, 8, 3, 14, 9, 4, 15);
    let a0 = _mm_shuffle_epi8(r, sh_a);
    let b0 = _mm_shuffle_epi8(g, sh_b);
    let c0 = _mm_shuffle_epi8(b, sh_c);

    let m0 = _mm_setr_epi8(0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0);
    let m1 = _mm_setr_epi8(0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0);
    let v0 = _mm_blendv_epi8(_mm_blendv_epi8(a0, b0, m1), c0, m0);
    let v1 = _mm_blendv_epi8(_mm_blendv_epi8(b0, c0, m1), a0, m0);
    let v2 = _mm_blendv_epi8(_mm_blendv_epi8(c0, a0, m1), b0, m0);
    (v0, v1, v2)
}

#[inline(always)]
pub(crate) unsafe fn _mm_deinterleave_x2_epi8(a: __m128i, b: __m128i) -> (__m128i, __m128i) {
    let t10 = _mm_unpacklo_epi8(a, b);
    let t11 = _mm_unpackhi_epi8(a, b);

    let t20 = _mm_unpacklo_epi8(t10, t11);
    let t21 = _mm_unpackhi_epi8(t10, t11);

    let t30 = _mm_unpacklo_epi8(t20, t21);
    let t31 = _mm_unpackhi_epi8(t20, t21);

    let av = _mm_unpacklo_epi8(t30, t31);
    let bv = _mm_unpackhi_epi8(t30, t31);
    (av, bv)
}

#[inline(always)]
pub(crate) unsafe fn _mm_deinterleave_x2_epi16(a: __m128i, b: __m128i) -> (__m128i, __m128i) {
    let v2 = _mm_unpacklo_epi16(a, b); // a0 a4 b0 b4 a1 a5 b1 b5
    let v3 = _mm_unpackhi_epi16(a, b); // a2 a6 b2 b6 a3 a7 b3 b7
    let v4 = _mm_unpacklo_epi16(v2, v3); // a0 a2 a4 a6 b0 b2 b4 b6
    let v5 = _mm_unpackhi_epi16(v2, v3); // a1 a3 a5 a7 b1 b3 b5 b7

    let av = _mm_unpacklo_epi16(v4, v5); // a0 a1 a2 a3 a4 a5 a6 a7
    let bv = _mm_unpackhi_epi16(v4, v5); // b0 b1 ab b3 b4 b5 b6 b7
    (av, bv)
}

#[inline(always)]
pub(crate) unsafe fn sse_store_rgb_u8(ptr: *mut u8, r: __m128i, g: __m128i, b: __m128i) {
    let (v0, v1, v2) = sse_interleave_rgb(r, g, b);
    _mm_storeu_si128(ptr as *mut __m128i, v0);
    _mm_storeu_si128(ptr.add(16) as *mut __m128i, v1);
    _mm_storeu_si128(ptr.add(32) as *mut __m128i, v2);
}

#[inline(always)]
pub(crate) unsafe fn _mm_havg_epu8(a: __m128i, b: __m128i) -> __m128i {
    let ones = _mm_set1_epi8(1);
    let ones_16 = _mm_set1_epi16(1);
    let sums_lo = _mm_maddubs_epi16(a, ones);
    let lo = _mm_srli_epi16::<1>(_mm_add_epi16(sums_lo, ones_16));
    let sums_hi = _mm_maddubs_epi16(b, ones);
    let hi = _mm_srli_epi16::<1>(_mm_add_epi16(sums_hi, ones_16));
    _mm_packus_epi16(lo, hi)
}

#[inline(always)]
pub(crate) unsafe fn sse_div_by255(v: __m128i) -> __m128i {
    let addition = _mm_set1_epi16(127);
    _mm_srli_epi16::<8>(_mm_add_epi16(
        _mm_add_epi16(v, addition),
        _mm_srli_epi16::<8>(v),
    ))
}

#[inline(always)]
pub(crate) unsafe fn _mm_havg_epi16_epi32(a: __m128i) -> __m128i {
    let sums = _mm_madd_epi16(a, _mm_set1_epi16(1));
    _mm_srli_epi32::<1>(_mm_add_epi32(sums, _mm_set1_epi32(1)))
}

#[inline(always)]
pub(crate) unsafe fn _mm_loadu_si128_x2(ptr: *const u8) -> (__m128i, __m128i) {
    (
        _mm_loadu_si128(ptr as *const __m128i),
        _mm_loadu_si128(ptr.add(16) as *const __m128i),
    )
}

#[allow(non_camel_case_types)]
#[derive(Copy, Clone)]
pub(crate) struct __mm128x4(pub __m128i, pub __m128i, pub __m128i, pub __m128i);

#[inline(always)]
pub(crate) unsafe fn _mm_combinel_epi8(a: __m128i, b: __m128i) -> __m128i {
    let a_low = _mm_castps_si128(_mm_movelh_ps(_mm_castsi128_ps(a), _mm_castsi128_ps(a)));
    let b_low = _mm_castps_si128(_mm_movelh_ps(_mm_castsi128_ps(b), _mm_castsi128_ps(b)));

    _mm_unpacklo_epi64(a_low, b_low)
}

#[inline(always)]
pub(crate) unsafe fn _mm_combineh_epi8(a: __m128i, b: __m128i) -> __m128i {
    let a_low = _mm_castps_si128(_mm_movehl_ps(_mm_castsi128_ps(a), _mm_castsi128_ps(a)));
    let b_low = _mm_castps_si128(_mm_movehl_ps(_mm_castsi128_ps(b), _mm_castsi128_ps(b)));

    _mm_unpacklo_epi64(a_low, b_low)
}

#[inline(always)]
pub(crate) unsafe fn _mm_storeu_si128_x4(ptr: *mut u8, vals: __mm128x4) {
    _mm_storeu_si128(ptr as *mut __m128i, vals.0);
    _mm_storeu_si128(ptr.add(16) as *mut __m128i, vals.1);
    _mm_storeu_si128(ptr.add(32) as *mut __m128i, vals.2);
    _mm_storeu_si128(ptr.add(48) as *mut __m128i, vals.3);
}

#[inline(always)]
pub(crate) unsafe fn _mm_getlow_epi8(a: __m128i) -> __m128i {
    _mm_castps_si128(_mm_movelh_ps(
        _mm_castsi128_ps(a),
        _mm_castsi128_ps(_mm_setzero_si128()),
    ))
}

#[inline(always)]
pub(crate) unsafe fn _mm_gethigh_epi8(a: __m128i) -> __m128i {
    _mm_srli_si128::<8>(a)
}

#[inline(always)]
pub(crate) unsafe fn _mm_deinterleave_rgba_epi16(
    rgba0: __m128i,
    rgba1: __m128i,
    rgba2: __m128i,
    rgba3: __m128i,
) -> (__m128i, __m128i, __m128i, __m128i) {
    let v0 = _mm_unpacklo_epi16(rgba0, rgba2); // a0 a4 b0 b4 ...
    let v1 = _mm_unpackhi_epi16(rgba0, rgba2); // a1 a5 b1 b5 ...
    let v2 = _mm_unpacklo_epi16(rgba1, rgba3); // a2 a6 b2 b6 ...
    let v3 = _mm_unpackhi_epi16(rgba1, rgba3); // a3 a7 b3 b7 ...

    let u0 = _mm_unpacklo_epi16(v0, v2); // a0 a2 a4 a6 ...
    let u1 = _mm_unpacklo_epi16(v1, v3); // a1 a3 a5 a7 ...
    let u2 = _mm_unpackhi_epi16(v0, v2); // c0 c2 c4 c6 ...
    let u3 = _mm_unpackhi_epi16(v1, v3); // c1 c3 c5 c7 ...

    let a = _mm_unpacklo_epi16(u0, u1);
    let b = _mm_unpackhi_epi16(u0, u1);
    let c = _mm_unpacklo_epi16(u2, u3);
    let d = _mm_unpackhi_epi16(u2, u3);
    (a, b, c, d)
}

#[inline(always)]
pub(crate) unsafe fn _mm_deinterleave_rgb_epi16(
    rgba0: __m128i,
    rgba1: __m128i,
    rgba2: __m128i,
) -> (__m128i, __m128i, __m128i) {
    let a0 = _mm_blend_epi16::<0x24>(_mm_blend_epi16::<0x92>(rgba0, rgba1), rgba2);
    let b0 = _mm_blend_epi16::<0x24>(_mm_blend_epi16::<0x92>(rgba2, rgba0), rgba1);
    let c0 = _mm_blend_epi16::<0x24>(_mm_blend_epi16::<0x92>(rgba1, rgba2), rgba0);

    let sh_a = _mm_setr_epi8(0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15, 4, 5, 10, 11);
    let sh_b = _mm_setr_epi8(2, 3, 8, 9, 14, 15, 4, 5, 10, 11, 0, 1, 6, 7, 12, 13);
    let sh_c = _mm_setr_epi8(4, 5, 10, 11, 0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15);
    let a0 = _mm_shuffle_epi8(a0, sh_a);
    let b0 = _mm_shuffle_epi8(b0, sh_b);
    let c0 = _mm_shuffle_epi8(c0, sh_c);
    (a0, b0, c0)
}

#[inline(always)]
pub(crate) unsafe fn _mm_interleave_epi16(a: __m128i, b: __m128i) -> (__m128i, __m128i) {
    let v0 = _mm_unpacklo_epi16(a, b);
    let v1 = _mm_unpackhi_epi16(a, b);
    (v0, v1)
}

#[inline(always)]
pub(crate) unsafe fn _mm_interleave_rgb_epi16(
    a: __m128i,
    b: __m128i,
    c: __m128i,
) -> (__m128i, __m128i, __m128i) {
    let sh_a = _mm_setr_epi8(0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15, 4, 5, 10, 11);
    let sh_b = _mm_setr_epi8(10, 11, 0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15, 4, 5);
    let sh_c = _mm_setr_epi8(4, 5, 10, 11, 0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15);
    let a0 = _mm_shuffle_epi8(a, sh_a);
    let b0 = _mm_shuffle_epi8(b, sh_b);
    let c0 = _mm_shuffle_epi8(c, sh_c);

    let v0 = _mm_blend_epi16::<0x24>(_mm_blend_epi16::<0x92>(a0, b0), c0);
    let v1 = _mm_blend_epi16::<0x24>(_mm_blend_epi16::<0x92>(c0, a0), b0);
    let v2 = _mm_blend_epi16::<0x24>(_mm_blend_epi16::<0x92>(b0, c0), a0);
    (v0, v1, v2)
}

#[inline(always)]
pub(crate) unsafe fn _mm_interleave_rgba_epi16(
    a: __m128i,
    b: __m128i,
    c: __m128i,
    d: __m128i,
) -> (__m128i, __m128i, __m128i, __m128i) {
    // a0 a1 a2 a3 ....
    // b0 b1 b2 b3 ....
    // c0 c1 c2 c3 ....
    // d0 d1 d2 d3 ....
    let u0 = _mm_unpacklo_epi16(a, c); // a0 c0 a1 c1 ...
    let u1 = _mm_unpackhi_epi16(a, c); // a4 c4 a5 c5 ...
    let u2 = _mm_unpacklo_epi16(b, d); // b0 d0 b1 d1 ...
    let u3 = _mm_unpackhi_epi16(b, d); // b4 d4 b5 d5 ...

    let v0 = _mm_unpacklo_epi16(u0, u2); // a0 b0 c0 d0 ...
    let v1 = _mm_unpackhi_epi16(u0, u2); // a2 b2 c2 d2 ...
    let v2 = _mm_unpacklo_epi16(u1, u3); // a4 b4 c4 d4 ...
    let v3 = _mm_unpackhi_epi16(u1, u3); // a6 b6 c6 d6 ...
    (v0, v1, v2, v3)
}

#[inline(always)]
pub(crate) unsafe fn _mm_load_deinterleave_rgb_for_yuv<const CHANS: u8>(
    ptr: *const u8,
) -> (__m128i, __m128i, __m128i) {
    let (r_values0, g_values0, b_values0);

    let source_channels: YuvSourceChannels = CHANS.into();

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let row_1 = _mm_loadu_si128(ptr as *const __m128i);
            let row_2 = _mm_loadu_si128(ptr.add(16) as *const __m128i);
            let row_3 = _mm_loadu_si128(ptr.add(32) as *const __m128i);

            let (it1, it2, it3) = sse_deinterleave_rgb(row_1, row_2, row_3);
            if source_channels == YuvSourceChannels::Rgb {
                r_values0 = it1;
                g_values0 = it2;
                b_values0 = it3;
            } else {
                r_values0 = it3;
                g_values0 = it2;
                b_values0 = it1;
            }
        }
        YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => {
            let row_1 = _mm_loadu_si128(ptr as *const __m128i);
            let row_2 = _mm_loadu_si128(ptr.add(16) as *const __m128i);
            let row_3 = _mm_loadu_si128(ptr.add(32) as *const __m128i);
            let row_4 = _mm_loadu_si128(ptr.add(48) as *const __m128i);

            let (it1, it2, it3, _) = sse_deinterleave_rgba(row_1, row_2, row_3, row_4);
            if source_channels == YuvSourceChannels::Rgba {
                r_values0 = it1;
                g_values0 = it2;
                b_values0 = it3;
            } else {
                r_values0 = it3;
                g_values0 = it2;
                b_values0 = it1;
            }
        }
    }
    (r_values0, g_values0, b_values0)
}

#[inline(always)]
pub(crate) unsafe fn _mm_load_deinterleave_rgbx<const CHANS: u8>(
    ptr: *const u8,
) -> (__m128i, __m128i, __m128i, __m128i) {
    let (r_values0, g_values0, b_values0, a_values0);

    let source_channels: YuvSourceChannels = CHANS.into();

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let row_1 = _mm_loadu_si128(ptr as *const __m128i);
            let row_2 = _mm_loadu_si128(ptr.add(16) as *const __m128i);
            let row_3 = _mm_loadu_si128(ptr.add(32) as *const __m128i);

            let (it1, it2, it3) = sse_deinterleave_rgb(row_1, row_2, row_3);
            if source_channels == YuvSourceChannels::Rgb {
                r_values0 = it1;
                g_values0 = it2;
                b_values0 = it3;
            } else {
                r_values0 = it3;
                g_values0 = it2;
                b_values0 = it1;
            }
            a_values0 = _mm_set1_epi8(255u8 as i8);
        }
        YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => {
            let row_1 = _mm_loadu_si128(ptr as *const __m128i);
            let row_2 = _mm_loadu_si128(ptr.add(16) as *const __m128i);
            let row_3 = _mm_loadu_si128(ptr.add(32) as *const __m128i);
            let row_4 = _mm_loadu_si128(ptr.add(48) as *const __m128i);

            let (it1, it2, it3, it4) = sse_deinterleave_rgba(row_1, row_2, row_3, row_4);
            if source_channels == YuvSourceChannels::Rgba {
                r_values0 = it1;
                g_values0 = it2;
                b_values0 = it3;
                a_values0 = it4;
            } else {
                r_values0 = it3;
                g_values0 = it2;
                b_values0 = it1;
                a_values0 = it4;
            }
        }
    }
    (r_values0, g_values0, b_values0, a_values0)
}

#[inline(always)]
pub(crate) unsafe fn _mm_load_deinterleave_half_rgb_for_yuv<const CHANS: u8>(
    ptr: *const u8,
) -> (__m128i, __m128i, __m128i) {
    let (r_values0, g_values0, b_values0);

    let source_channels: YuvSourceChannels = CHANS.into();

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let row_1 = _mm_loadu_si128(ptr as *const __m128i);
            let row_2 = _mm_loadu_si64(ptr.add(16));

            let (it1, it2, it3) = sse_deinterleave_rgb(row_1, row_2, _mm_setzero_si128());
            if source_channels == YuvSourceChannels::Rgb {
                r_values0 = it1;
                g_values0 = it2;
                b_values0 = it3;
            } else {
                r_values0 = it3;
                g_values0 = it2;
                b_values0 = it1;
            }
        }
        YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => {
            let row_1 = _mm_loadu_si128(ptr as *const __m128i);
            let row_2 = _mm_loadu_si128(ptr.add(16) as *const __m128i);

            let (it1, it2, it3, _) =
                sse_deinterleave_rgba(row_1, row_2, _mm_setzero_si128(), _mm_setzero_si128());
            if source_channels == YuvSourceChannels::Rgba {
                r_values0 = it1;
                g_values0 = it2;
                b_values0 = it3;
            } else {
                r_values0 = it3;
                g_values0 = it2;
                b_values0 = it1;
            }
        }
    }
    (r_values0, g_values0, b_values0)
}

#[inline(always)]
pub(crate) unsafe fn _mm_load_deinterleave_half_rgbx<const CHANS: u8>(
    ptr: *const u8,
) -> (__m128i, __m128i, __m128i, __m128i) {
    let (r_values0, g_values0, b_values0, a_values0);

    let source_channels: YuvSourceChannels = CHANS.into();

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let row_1 = _mm_loadu_si128(ptr as *const __m128i);
            let row_2 = _mm_loadu_si64(ptr.add(16));

            let (it1, it2, it3) = sse_deinterleave_rgb(row_1, row_2, _mm_setzero_si128());
            if source_channels == YuvSourceChannels::Rgb {
                r_values0 = it1;
                g_values0 = it2;
                b_values0 = it3;
            } else {
                r_values0 = it3;
                g_values0 = it2;
                b_values0 = it1;
            }
            a_values0 = _mm_set1_epi8(255u8 as i8);
        }
        YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => {
            let row_1 = _mm_loadu_si128(ptr as *const __m128i);
            let row_2 = _mm_loadu_si128(ptr.add(16) as *const __m128i);

            let (it1, it2, it3, it4) =
                sse_deinterleave_rgba(row_1, row_2, _mm_setzero_si128(), _mm_setzero_si128());
            if source_channels == YuvSourceChannels::Rgba {
                r_values0 = it1;
                g_values0 = it2;
                b_values0 = it3;
                a_values0 = it4;
            } else {
                r_values0 = it3;
                g_values0 = it2;
                b_values0 = it1;
                a_values0 = it4;
            }
        }
    }
    (r_values0, g_values0, b_values0, a_values0)
}

#[inline(always)]
pub(crate) unsafe fn _mm_load_deinterleave_rgb16_for_yuv<const CHANS: u8>(
    ptr: *const u16,
) -> (__m128i, __m128i, __m128i) {
    let r_values;
    let g_values;
    let b_values;

    let source_channels: YuvSourceChannels = CHANS.into();

    let row0 = _mm_loadu_si128(ptr as *const __m128i);
    let row1 = _mm_loadu_si128(ptr.add(8) as *const __m128i);
    let row2 = _mm_loadu_si128(ptr.add(16) as *const __m128i);

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let rgb_values = _mm_deinterleave_rgb_epi16(row0, row1, row2);
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
            let row3 = _mm_loadu_si128(ptr.add(24) as *const __m128i);
            let rgb_values = _mm_deinterleave_rgba_epi16(row0, row1, row2, row3);
            r_values = rgb_values.0;
            g_values = rgb_values.1;
            b_values = rgb_values.2;
        }
        YuvSourceChannels::Bgra => {
            let row3 = _mm_loadu_si128(ptr.add(24) as *const __m128i);
            let rgb_values = _mm_deinterleave_rgba_epi16(row0, row1, row2, row3);
            r_values = rgb_values.2;
            g_values = rgb_values.1;
            b_values = rgb_values.0;
        }
    }
    (r_values, g_values, b_values)
}

#[inline(always)]
pub(crate) unsafe fn _mm_store_interleave_rgb16_for_yuv<const CHANS: u8>(
    ptr: *mut u16,
    r: __m128i,
    g: __m128i,
    b: __m128i,
    a: __m128i,
) {
    let destination_channels: YuvSourceChannels = CHANS.into();

    match destination_channels {
        YuvSourceChannels::Rgb => {
            let dst_pack = _mm_interleave_rgb_epi16(r, g, b);
            _mm_storeu_si128(ptr as *mut __m128i, dst_pack.0);
            _mm_storeu_si128(ptr.add(8) as *mut __m128i, dst_pack.1);
            _mm_storeu_si128(ptr.add(16) as *mut __m128i, dst_pack.2);
        }
        YuvSourceChannels::Bgr => {
            let dst_pack = _mm_interleave_rgb_epi16(b, g, r);
            _mm_storeu_si128(ptr as *mut __m128i, dst_pack.0);
            _mm_storeu_si128(ptr.add(8) as *mut __m128i, dst_pack.1);
            _mm_storeu_si128(ptr.add(16) as *mut __m128i, dst_pack.2);
        }
        YuvSourceChannels::Rgba => {
            let dst_pack = _mm_interleave_rgba_epi16(r, g, b, a);
            _mm_storeu_si128(ptr as *mut __m128i, dst_pack.0);
            _mm_storeu_si128(ptr.add(8) as *mut __m128i, dst_pack.1);
            _mm_storeu_si128(ptr.add(16) as *mut __m128i, dst_pack.2);
            _mm_storeu_si128(ptr.add(24) as *mut __m128i, dst_pack.3);
        }
        YuvSourceChannels::Bgra => {
            let dst_pack = _mm_interleave_rgba_epi16(b, g, r, a);
            _mm_storeu_si128(ptr as *mut __m128i, dst_pack.0);
            _mm_storeu_si128(ptr.add(8) as *mut __m128i, dst_pack.1);
            _mm_storeu_si128(ptr.add(16) as *mut __m128i, dst_pack.2);
            _mm_storeu_si128(ptr.add(24) as *mut __m128i, dst_pack.3);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm_store_interleave_half_rgb16_for_yuv<const CHANS: u8>(
    ptr: *mut u16,
    r: __m128i,
    g: __m128i,
    b: __m128i,
    a: __m128i,
) {
    let destination_channels: YuvSourceChannels = CHANS.into();

    match destination_channels {
        YuvSourceChannels::Rgb => {
            let dst_pack = _mm_interleave_rgb_epi16(r, g, b);
            _mm_storeu_si128(ptr as *mut __m128i, dst_pack.0);
            _mm_storeu_si64(ptr.add(8) as *mut _, dst_pack.1);
        }
        YuvSourceChannels::Bgr => {
            let dst_pack = _mm_interleave_rgb_epi16(b, g, r);
            _mm_storeu_si128(ptr as *mut __m128i, dst_pack.0);
            _mm_storeu_si64(ptr.add(8) as *mut _, dst_pack.1);
        }
        YuvSourceChannels::Rgba => {
            let dst_pack = _mm_interleave_rgba_epi16(r, g, b, a);
            _mm_storeu_si128(ptr as *mut __m128i, dst_pack.0);
            _mm_storeu_si128(ptr.add(8) as *mut __m128i, dst_pack.1);
        }
        YuvSourceChannels::Bgra => {
            let dst_pack = _mm_interleave_rgba_epi16(b, g, r, a);
            _mm_storeu_si128(ptr as *mut __m128i, dst_pack.0);
            _mm_storeu_si128(ptr.add(8) as *mut __m128i, dst_pack.1);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm_store_interleave_rgb_for_yuv<const CHANS: u8>(
    ptr: *mut u8,
    r: __m128i,
    g: __m128i,
    b: __m128i,
    a: __m128i,
) {
    let destination_channels: YuvSourceChannels = CHANS.into();

    match destination_channels {
        YuvSourceChannels::Rgb => {
            sse_store_rgb_u8(ptr, r, g, b);
        }
        YuvSourceChannels::Bgr => {
            sse_store_rgb_u8(ptr, b, g, r);
        }
        YuvSourceChannels::Rgba => {
            sse_store_rgba(ptr, r, g, b, a);
        }
        YuvSourceChannels::Bgra => {
            sse_store_rgba(ptr, b, g, r, a);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm_store_interleave_half_rgb_for_yuv<const CN: u8>(
    ptr: *mut u8,
    r: __m128i,
    g: __m128i,
    b: __m128i,
    a: __m128i,
) {
    let destination_channels: YuvSourceChannels = CN.into();

    match destination_channels {
        YuvSourceChannels::Rgb => {
            let (v0, v1, _) = sse_interleave_rgb(r, g, b);
            _mm_storeu_si128(ptr as *mut __m128i, v0);
            _mm_storeu_si64(ptr.add(16), v1);
        }
        YuvSourceChannels::Bgr => {
            let (v0, v1, _) = sse_interleave_rgb(b, g, r);
            _mm_storeu_si128(ptr as *mut __m128i, v0);
            _mm_storeu_si64(ptr.add(16), v1);
        }
        YuvSourceChannels::Rgba => {
            let (row1, row2, _, _) = sse_interleave_rgba(r, g, b, a);
            _mm_storeu_si128(ptr as *mut __m128i, row1);
            _mm_storeu_si128(ptr.add(16) as *mut __m128i, row2);
        }
        YuvSourceChannels::Bgra => {
            let (row1, row2, _, _) = sse_interleave_rgba(b, g, r, a);
            _mm_storeu_si128(ptr as *mut __m128i, row1);
            _mm_storeu_si128(ptr.add(16) as *mut __m128i, row2);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm_to_msb_epi16<const BIT_DEPTH: usize>(a: __m128i) -> __m128i {
    if BIT_DEPTH == 10 {
        _mm_slli_epi16::<6>(a)
    } else if BIT_DEPTH == 12 {
        _mm_slli_epi16::<4>(a)
    } else if BIT_DEPTH == 14 {
        _mm_slli_epi16::<2>(a)
    } else {
        a
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm_from_msb_epi16<const BIT_DEPTH: usize>(a: __m128i) -> __m128i {
    if BIT_DEPTH == 10 {
        _mm_srli_epi16::<6>(a)
    } else if BIT_DEPTH == 12 {
        _mm_srli_epi16::<4>(a)
    } else if BIT_DEPTH == 14 {
        _mm_srli_epi16::<2>(a)
    } else {
        a
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm_store_shr_epi16_epi8<const BIT_DEPTH: usize>(a: __m128i) -> __m128i {
    if BIT_DEPTH == 10 {
        _mm_srai_epi16::<2>(a)
    } else if BIT_DEPTH == 12 {
        _mm_srai_epi16::<4>(a)
    } else if BIT_DEPTH == 14 {
        _mm_srai_epi16::<6>(a)
    } else if BIT_DEPTH == 16 {
        _mm_srai_epi16::<8>(a)
    } else {
        a
    }
}

#[inline(always)]
pub(crate) unsafe fn sse_pairwise_avg_epi8_j(a: __m128i, f: i8) -> __m128i {
    _mm_maddubs_epi16(a, _mm_set1_epi8(f))
}

#[inline(always)]
pub(crate) unsafe fn _mm_affine_dot<const PRECISION: i32>(
    acc: __m128i,
    r: __m128i,
    g: __m128i,
    b: __m128i,
    w0: __m128i,
    w1: __m128i,
) -> __m128i {
    let r_intl_g_lo = _mm_interleave_epi16(r, g);
    let unbpl = _mm_unpacklo_epi16(b, _mm_setzero_si128());
    let unbph = _mm_unpackhi_epi16(b, _mm_setzero_si128());

    let r0w0 = _mm_madd_epi16(r_intl_g_lo.0, w0);
    let b0w1 = _mm_madd_epi16(unbpl, w1);
    let r1w0 = _mm_madd_epi16(r_intl_g_lo.1, w0);
    let b1w1 = _mm_madd_epi16(unbph, w1);

    let y_l_l = _mm_add_epi32(acc, _mm_add_epi32(r0w0, b0w1));
    let y_l_h = _mm_add_epi32(acc, _mm_add_epi32(r1w0, b1w1));

    _mm_packus_epi32(
        _mm_srli_epi32::<PRECISION>(y_l_l),
        _mm_srli_epi32::<PRECISION>(y_l_h),
    )
}

#[inline(always)]
pub(crate) unsafe fn _mm_affine_uv_dot<const PRECISION: i32>(
    acc: __m128i,
    r0: __m128i,
    r1: __m128i,
    b0: __m128i,
    b1: __m128i,
    w0: __m128i,
    w1: __m128i,
) -> __m128i {
    let r0w0 = _mm_madd_epi16(r0, w0);
    let b0w1 = _mm_madd_epi16(b0, w1);
    let r1w0 = _mm_madd_epi16(r1, w0);
    let b1w1 = _mm_madd_epi16(b1, w1);

    let c0 = _mm_add_epi32(r0w0, b0w1);
    let c1 = _mm_add_epi32(r1w0, b1w1);

    let y_l_l = _mm_add_epi32(acc, c0);
    let y_l_h = _mm_add_epi32(acc, c1);

    _mm_packus_epi32(
        _mm_srli_epi32::<PRECISION>(y_l_l),
        _mm_srli_epi32::<PRECISION>(y_l_h),
    )
}

#[inline(always)]
pub(crate) unsafe fn _mm_affine_v_dot<const PRECISION: i32>(
    slope: __m128i,
    v0: __m128i,
    v1: __m128i,
    b0: __m128i,
    b1: __m128i,
    w0: __m128i,
    w1: __m128i,
) -> __m128i {
    let y_l_l = _mm_add_epi32(
        slope,
        _mm_add_epi32(_mm_madd_epi16(v0, w0), _mm_madd_epi16(b0, w1)),
    );
    let y_l_h = _mm_add_epi32(
        slope,
        _mm_add_epi32(_mm_madd_epi16(v1, w0), _mm_madd_epi16(b1, w1)),
    );
    _mm_packus_epi32(
        _mm_srli_epi32::<PRECISION>(y_l_l),
        _mm_srli_epi32::<PRECISION>(y_l_h),
    )
}

#[inline(always)]
pub(crate) unsafe fn _mm_affine_transform<const PRECISION: i32>(
    slope: __m128i,
    v0: __m128i,
    v1: __m128i,
    w0: __m128i,
    w1: __m128i,
) -> __m128i {
    let j = _mm_srli_epi32::<PRECISION>(_mm_add_epi32(
        slope,
        _mm_add_epi32(_mm_madd_epi16(v0, w0), _mm_madd_epi16(v1, w1)),
    ));
    _mm_packus_epi32(j, j)
}

#[inline(always)]
pub(crate) unsafe fn _mm_expand8_hi_to_10(v: __m128i) -> __m128i {
    _mm_srli_epi16::<6>(_mm_unpackhi_epi8(v, v))
}

#[inline(always)]
pub(crate) unsafe fn _mm_expand8_lo_to_10(v: __m128i) -> __m128i {
    _mm_srli_epi16::<6>(_mm_unpacklo_epi8(v, v))
}

#[inline(always)]
pub(crate) unsafe fn _xx_load_si64(ptr: *const u8) -> __m128i {
    _mm_loadl_epi64(ptr as *const _)
}

#[inline(always)]
pub(crate) unsafe fn _mm_expand_bp_by2<const BIT_DEPTH: usize>(v: __m128i) -> __m128i {
    if BIT_DEPTH == 10 {
        _mm_or_si128(_mm_slli_epi16::<2>(v), _mm_srli_epi16::<8>(v))
    } else if BIT_DEPTH == 12 {
        _mm_or_si128(_mm_slli_epi16::<2>(v), _mm_srli_epi16::<10>(v))
    } else {
        v
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm_set4r_epi(e0: i8, e1: i8, e2: i8, e3: i8) -> __m128i {
    _mm_setr_epi8(
        e0, e1, e2, e3, e0, e1, e2, e3, e0, e1, e2, e3, e0, e1, e2, e3,
    )
}

#[inline(always)]
pub(crate) unsafe fn _mm_mul_add_epi16(accumulator: __m128i, v0: __m128i, w0: __m128i) -> __m128i {
    _mm_add_epi32(accumulator, _mm_madd_epi16(v0, w0))
}

#[inline(always)]
pub(crate) unsafe fn _mm_mul_sub_epi16(accumulator: __m128i, v0: __m128i, w0: __m128i) -> __m128i {
    _mm_sub_epi32(accumulator, _mm_madd_epi16(v0, w0))
}
