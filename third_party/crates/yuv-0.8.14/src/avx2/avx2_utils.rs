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
pub(crate) const fn shuffle(z: u32, y: u32, x: u32, w: u32) -> i32 {
    ((z << 6) | (y << 4) | (x << 2) | w) as i32
}

#[inline(always)]
pub(crate) unsafe fn avx2_pack_u16(s_1: __m256i, s_2: __m256i) -> __m256i {
    let packed = _mm256_packus_epi16(s_1, s_2);
    const MASK: i32 = shuffle(3, 1, 2, 0);
    _mm256_permute4x64_epi64::<MASK>(packed)
}

#[inline(always)]
pub(crate) unsafe fn avx2_pack_u32(s_1: __m256i, s_2: __m256i) -> __m256i {
    let packed = _mm256_packus_epi32(s_1, s_2);
    const MASK: i32 = shuffle(3, 1, 2, 0);
    _mm256_permute4x64_epi64::<MASK>(packed)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_havg_epi16_epi32(a: __m256i) -> __m256i {
    let sums = _mm256_madd_epi16(a, _mm256_set1_epi16(1));
    _mm256_srli_epi32::<1>(_mm256_add_epi32(sums, _mm256_set1_epi32(1)))
}

#[inline(always)]
pub(crate) unsafe fn _mm256_rphadd_epi32_epi16(a: __m256i) -> __m256i {
    let sh1 = _mm256_setr_epi8(
        0, 1, 4, 5, 8, 9, 12, 13, 2, 3, 6, 7, 10, 11, 14, 15, 0, 1, 4, 5, 8, 9, 12, 13, 2, 3, 6, 7,
        10, 11, 14, 15,
    );
    let shuffled = _mm256_shuffle_epi8(a, sh1);
    let a0 = _mm256_unpacklo_epi16(shuffled, _mm256_setzero_si256());
    let a1 = _mm256_unpackhi_epi16(shuffled, _mm256_setzero_si256());
    _mm256_srli_epi32::<1>(_mm256_add_epi32(
        _mm256_add_epi32(a0, a1),
        _mm256_set1_epi32(1),
    ))
}

#[inline(always)]
pub(crate) unsafe fn _mm256_interleave_epi8(a: __m256i, b: __m256i) -> (__m256i, __m256i) {
    let xy_l = _mm256_unpacklo_epi8(a, b);
    let xy_h = _mm256_unpackhi_epi8(a, b);

    let xy0 = _mm256_permute2x128_si256::<32>(xy_l, xy_h);
    let xy1 = _mm256_permute2x128_si256::<49>(xy_l, xy_h);
    (xy0, xy1)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_deinterleave_rgba_epi8(
    rgba0: __m256i,
    rgba1: __m256i,
    rgba2: __m256i,
    rgba3: __m256i,
) -> (__m256i, __m256i, __m256i, __m256i) {
    #[rustfmt::skip]
    let sh = _mm256_setr_epi8(
        0, 4, 8, 12, 1, 5,
        9, 13, 2, 6, 10, 14,
        3, 7, 11, 15, 0, 4,
        8, 12, 1, 5, 9, 13,
        2, 6, 10, 14, 3, 7,
        11, 15,
    );

    let p0 = _mm256_shuffle_epi8(rgba0, sh);
    let p1 = _mm256_shuffle_epi8(rgba1, sh);
    let p2 = _mm256_shuffle_epi8(rgba2, sh);
    let p3 = _mm256_shuffle_epi8(rgba3, sh);

    let p01l = _mm256_unpacklo_epi32(p0, p1);
    let p01h = _mm256_unpackhi_epi32(p0, p1);
    let p23l = _mm256_unpacklo_epi32(p2, p3);
    let p23h = _mm256_unpackhi_epi32(p2, p3);

    let pll = _mm256_permute2x128_si256::<32>(p01l, p23l);
    let plh = _mm256_permute2x128_si256::<49>(p01l, p23l);
    let phl = _mm256_permute2x128_si256::<32>(p01h, p23h);
    let phh = _mm256_permute2x128_si256::<49>(p01h, p23h);

    let b0 = _mm256_unpacklo_epi32(pll, plh);
    let g0 = _mm256_unpackhi_epi32(pll, plh);
    let r0 = _mm256_unpacklo_epi32(phl, phh);
    let a0 = _mm256_unpackhi_epi32(phl, phh);

    (b0, g0, r0, a0)
}

#[inline(always)]
pub(crate) unsafe fn avx2_store_u8_rgb(ptr: *mut u8, r: __m256i, g: __m256i, b: __m256i) {
    let (rgb1, rgb2, rgb3) = avx2_interleave_rgb(r, g, b);

    _mm256_storeu_si256(ptr as *mut __m256i, rgb1);
    _mm256_storeu_si256(ptr.add(32) as *mut __m256i, rgb2);
    _mm256_storeu_si256(ptr.add(64) as *mut __m256i, rgb3);
}

#[inline(always)]
pub(crate) unsafe fn _mm256_interleave_rgba(
    r: __m256i,
    g: __m256i,
    b: __m256i,
    a: __m256i,
) -> (__m256i, __m256i, __m256i, __m256i) {
    let bg0 = _mm256_unpacklo_epi8(r, g);
    let bg1 = _mm256_unpackhi_epi8(r, g);
    let ra0 = _mm256_unpacklo_epi8(b, a);
    let ra1 = _mm256_unpackhi_epi8(b, a);

    let rgba0_ = _mm256_unpacklo_epi16(bg0, ra0);
    let rgba1_ = _mm256_unpackhi_epi16(bg0, ra0);
    let rgba2_ = _mm256_unpacklo_epi16(bg1, ra1);
    let rgba3_ = _mm256_unpackhi_epi16(bg1, ra1);

    let rgba0 = _mm256_permute2x128_si256::<32>(rgba0_, rgba1_);
    let rgba2 = _mm256_permute2x128_si256::<49>(rgba0_, rgba1_);
    let rgba1 = _mm256_permute2x128_si256::<32>(rgba2_, rgba3_);
    let rgba3 = _mm256_permute2x128_si256::<49>(rgba2_, rgba3_);
    (rgba0, rgba1, rgba2, rgba3)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_store_interleaved_epi8(
    ptr: *mut u8,
    r: __m256i,
    g: __m256i,
    b: __m256i,
    a: __m256i,
) {
    let bg0 = _mm256_unpacklo_epi8(r, g);
    let bg1 = _mm256_unpackhi_epi8(r, g);
    let ra0 = _mm256_unpacklo_epi8(b, a);
    let ra1 = _mm256_unpackhi_epi8(b, a);

    let rgba0_ = _mm256_unpacklo_epi16(bg0, ra0);
    let rgba1_ = _mm256_unpackhi_epi16(bg0, ra0);
    let rgba2_ = _mm256_unpacklo_epi16(bg1, ra1);
    let rgba3_ = _mm256_unpackhi_epi16(bg1, ra1);

    let rgba0 = _mm256_permute2x128_si256::<32>(rgba0_, rgba1_);
    let rgba2 = _mm256_permute2x128_si256::<49>(rgba0_, rgba1_);
    let rgba1 = _mm256_permute2x128_si256::<32>(rgba2_, rgba3_);
    let rgba3 = _mm256_permute2x128_si256::<49>(rgba2_, rgba3_);

    _mm256_storeu_si256(ptr as *mut __m256i, rgba0);
    _mm256_storeu_si256(ptr.add(32) as *mut __m256i, rgba1);
    _mm256_storeu_si256(ptr.add(64) as *mut __m256i, rgba2);
    _mm256_storeu_si256(ptr.add(96) as *mut __m256i, rgba3);
}

#[inline(always)]
pub(crate) unsafe fn avx2_interleave_odd(x: __m256i) -> __m256i {
    #[rustfmt::skip]
    let shuffle = _mm256_setr_epi8(1, 1, 3, 3,
                                   5, 5, 7, 7,
                                   9, 9, 11, 11,
                                   13, 13, 15, 15,
                                   17, 17, 19, 19,
                                   21, 21, 23, 23,
                                   25, 25, 27, 27,
                                   29, 29, 31, 31);
    _mm256_shuffle_epi8(x, shuffle)
}

#[inline(always)]
pub(crate) unsafe fn avx2_interleave_even(x: __m256i) -> __m256i {
    #[rustfmt::skip]
    let shuffle = _mm256_setr_epi8(0, 0, 2, 2,
                                   4, 4, 6, 6,
                                   8, 8, 10, 10,
                                   12, 12, 14, 14,
                                   16, 16, 18, 18,
                                   20, 20, 22, 22,
                                   24, 24, 26, 26,
                                   28, 28, 30, 30);
    _mm256_shuffle_epi8(x, shuffle)
}

#[inline(always)]
pub(crate) unsafe fn avx2_interleave_rgb(
    r: __m256i,
    g: __m256i,
    b: __m256i,
) -> (__m256i, __m256i, __m256i) {
    let sh_b = _mm256_setr_epi8(
        0, 11, 6, 1, 12, 7, 2, 13, 8, 3, 14, 9, 4, 15, 10, 5, 0, 11, 6, 1, 12, 7, 2, 13, 8, 3, 14,
        9, 4, 15, 10, 5,
    );
    let sh_g = _mm256_setr_epi8(
        5, 0, 11, 6, 1, 12, 7, 2, 13, 8, 3, 14, 9, 4, 15, 10, 5, 0, 11, 6, 1, 12, 7, 2, 13, 8, 3,
        14, 9, 4, 15, 10,
    );
    let sh_r = _mm256_setr_epi8(
        10, 5, 0, 11, 6, 1, 12, 7, 2, 13, 8, 3, 14, 9, 4, 15, 10, 5, 0, 11, 6, 1, 12, 7, 2, 13, 8,
        3, 14, 9, 4, 15,
    );

    let b0 = _mm256_shuffle_epi8(r, sh_b);
    let g0 = _mm256_shuffle_epi8(g, sh_g);
    let r0 = _mm256_shuffle_epi8(b, sh_r);

    let m0 = _mm256_setr_epi8(
        0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1,
        0, 0, -1, 0, 0,
    );
    let m1 = _mm256_setr_epi8(
        0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0,
        -1, 0, 0, -1, 0,
    );

    let p0 = _mm256_blendv_epi8(_mm256_blendv_epi8(b0, g0, m0), r0, m1);
    let p1 = _mm256_blendv_epi8(_mm256_blendv_epi8(g0, r0, m0), b0, m1);
    let p2 = _mm256_blendv_epi8(_mm256_blendv_epi8(r0, b0, m0), g0, m1);

    let bgr0 = _mm256_permute2x128_si256::<32>(p0, p1);
    let bgr1 = _mm256_permute2x128_si256::<48>(p2, p0);
    let bgr2 = _mm256_permute2x128_si256::<49>(p1, p2);

    (bgr0, bgr1, bgr2)
}

#[inline(always)]
pub(crate) unsafe fn avx2_deinterleave_rgb(
    rgb0: __m256i,
    rgb1: __m256i,
    rgb2: __m256i,
) -> (__m256i, __m256i, __m256i) {
    let s02_low = _mm256_permute2x128_si256::<32>(rgb0, rgb2);
    let s02_high = _mm256_permute2x128_si256::<49>(rgb0, rgb2);

    #[rustfmt::skip]
    let m0 = _mm256_setr_epi8(
        0, 0, -1, 0, 0,
        -1, 0, 0, -1, 0,
        0, -1, 0, 0, -1,
        0, 0, -1, 0, 0,
        -1, 0, 0, -1, 0,
        0, -1, 0, 0, -1,
        0, 0,
    );

    #[rustfmt::skip]
    let m1 = _mm256_setr_epi8(
        0, -1, 0, 0, -1,
        0, 0, -1, 0, 0,
        -1, 0, 0, -1, 0,
        0, -1, 0, 0, -1,
        0, 0, -1, 0, 0,
        -1, 0, 0, -1, 0,
        0, -1,
    );

    let b0 = _mm256_blendv_epi8(_mm256_blendv_epi8(s02_low, s02_high, m0), rgb1, m1);
    let g0 = _mm256_blendv_epi8(_mm256_blendv_epi8(s02_high, s02_low, m1), rgb1, m0);
    let r0 = _mm256_blendv_epi8(_mm256_blendv_epi8(rgb1, s02_low, m0), s02_high, m1);

    #[rustfmt::skip]
    let sh_b = _mm256_setr_epi8(
        0, 3, 6, 9, 12,
        15, 2, 5, 8, 11,
        14, 1, 4, 7, 10,
        13, 0, 3, 6, 9,
        12, 15, 2, 5, 8,
        11, 14, 1, 4, 7,
        10, 13,
    );

    #[rustfmt::skip]
    let sh_g = _mm256_setr_epi8(
        1, 4, 7, 10, 13,
        0, 3, 6, 9, 12,
        15, 2, 5, 8, 11,
        14, 1, 4, 7, 10,
        13, 0, 3, 6, 9,
        12, 15, 2, 5, 8,
        11, 14,
    );

    #[rustfmt::skip]
    let sh_r = _mm256_setr_epi8(
        2, 5, 8, 11, 14,
        1, 4, 7, 10, 13,
        0, 3, 6, 9, 12,
        15, 2, 5, 8, 11,
        14, 1, 4, 7, 10,
        13, 0, 3, 6, 9,
        12, 15,
    );
    let b0 = _mm256_shuffle_epi8(b0, sh_b);
    let g0 = _mm256_shuffle_epi8(g0, sh_g);
    let r0 = _mm256_shuffle_epi8(r0, sh_r);
    (b0, g0, r0)
}

// #[inline(always)]
// #[target_feature(enable = "avx2")]
// pub(crate) unsafe fn avx2_reshuffle_odd(v: __m256i) -> __m256i {
//     const MASK: i32 = shuffle(3, 1, 2, 0);
//     _mm256_permute4x64_epi64::<MASK>(v)
// }

#[inline(always)]
pub(crate) unsafe fn avx_pairwise_avg_epi16(a: __m256i, b: __m256i) -> __m256i {
    let sums = _mm256_hadd_epi16(a, b);
    _mm256_srli_epi16::<1>(_mm256_add_epi16(sums, _mm256_set1_epi16(1)))
}

#[inline(always)]
pub(crate) unsafe fn avx_pairwise_avg_epi16_epi8_j(a: __m256i, f: i8) -> __m256i {
    _mm256_maddubs_epi16(a, _mm256_set1_epi8(f))
}

// #[inline(always)]
// pub(crate) unsafe fn avx2_div_by255(v: __m256i) -> __m256i {
//     let addition = _mm256_set1_epi16(127);
//     _mm256_srli_epi16::<8>(_mm256_add_epi16(
//         _mm256_add_epi16(v, addition),
//         _mm256_srli_epi16::<8>(v),
//     ))
// }

#[inline(always)]
pub(crate) unsafe fn avx2_div_by255_x2(l: __m256i, v: __m256i) -> (__m256i, __m256i) {
    let addition = _mm256_set1_epi16(127);

    let k0 = _mm256_add_epi16(l, addition);
    let k1 = _mm256_add_epi16(v, addition);

    let j0 = _mm256_srli_epi16::<8>(k0);
    let j1 = _mm256_srli_epi16::<8>(k1);

    let kv0 = _mm256_add_epi16(l, j0);
    let kv1 = _mm256_add_epi16(v, j1);

    (_mm256_srli_epi16::<8>(kv0), _mm256_srli_epi16::<8>(kv1))
}

#[inline(always)]
pub(crate) unsafe fn _mm256_deinterleave_x2_epi8(a: __m256i, b: __m256i) -> (__m256i, __m256i) {
    let sh = _mm256_setr_epi8(
        0, 2, 4, 6, 8, 10, 12, 14, 1, 3, 5, 7, 9, 11, 13, 15, 0, 2, 4, 6, 8, 10, 12, 14, 1, 3, 5,
        7, 9, 11, 13, 15,
    );
    let p0 = _mm256_shuffle_epi8(a, sh);
    let p1 = _mm256_shuffle_epi8(b, sh);
    let pl = _mm256_permute2x128_si256::<32>(p0, p1);
    let ph = _mm256_permute2x128_si256::<49>(p0, p1);
    let a0 = _mm256_unpacklo_epi64(pl, ph);
    let b0 = _mm256_unpackhi_epi64(pl, ph);
    (a0, b0)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_interleave_x2_epi8(a: __m256i, b: __m256i) -> (__m256i, __m256i) {
    let xy_l = _mm256_unpacklo_epi8(a, b);
    let xy_h = _mm256_unpackhi_epi8(a, b);

    let xy0 = _mm256_permute2x128_si256::<32>(xy_l, xy_h);
    let xy1 = _mm256_permute2x128_si256::<49>(xy_l, xy_h);
    (xy0, xy1)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_interleave_rgba_epi16(
    a: __m256i,
    b: __m256i,
    c: __m256i,
    d: __m256i,
) -> (__m256i, __m256i, __m256i, __m256i) {
    let bg0 = _mm256_unpacklo_epi16(a, b);
    let bg1 = _mm256_unpackhi_epi16(a, b);
    let ra0 = _mm256_unpacklo_epi16(c, d);
    let ra1 = _mm256_unpackhi_epi16(c, d);

    let bgra0_ = _mm256_unpacklo_epi32(bg0, ra0);
    let bgra1_ = _mm256_unpackhi_epi32(bg0, ra0);
    let bgra2_ = _mm256_unpacklo_epi32(bg1, ra1);
    let bgra3_ = _mm256_unpackhi_epi32(bg1, ra1);

    let bgra0 = _mm256_permute2x128_si256::<32>(bgra0_, bgra1_);
    let bgra2 = _mm256_permute2x128_si256::<49>(bgra0_, bgra1_);
    let bgra1 = _mm256_permute2x128_si256::<32>(bgra2_, bgra3_);
    let bgra3 = _mm256_permute2x128_si256::<49>(bgra2_, bgra3_);
    (bgra0, bgra1, bgra2, bgra3)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_interleave_rgb_epi16(
    a: __m256i,
    b: __m256i,
    c: __m256i,
) -> (__m256i, __m256i, __m256i) {
    let sh_b = _mm256_setr_epi8(
        0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15, 4, 5, 10, 11, 0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14,
        15, 4, 5, 10, 11,
    );
    let sh_g = _mm256_setr_epi8(
        10, 11, 0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15, 4, 5, 10, 11, 0, 1, 6, 7, 12, 13, 2, 3, 8,
        9, 14, 15, 4, 5,
    );
    let sh_r = _mm256_setr_epi8(
        4, 5, 10, 11, 0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15, 4, 5, 10, 11, 0, 1, 6, 7, 12, 13, 2,
        3, 8, 9, 14, 15,
    );

    let b0 = _mm256_shuffle_epi8(a, sh_b);
    let g0 = _mm256_shuffle_epi8(b, sh_g);
    let r0 = _mm256_shuffle_epi8(c, sh_r);

    let m0 = _mm256_setr_epi8(
        0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1,
        -1, 0, 0, 0, 0,
    );
    let m1 = _mm256_setr_epi8(
        0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0,
        -1, -1, 0, 0,
    );

    let p0 = _mm256_blendv_epi8(_mm256_blendv_epi8(b0, g0, m0), r0, m1);
    let p1 = _mm256_blendv_epi8(_mm256_blendv_epi8(g0, r0, m0), b0, m1);
    let p2 = _mm256_blendv_epi8(_mm256_blendv_epi8(r0, b0, m0), g0, m1);

    let bgr0 = _mm256_permute2x128_si256::<32>(p0, p2);
    let bgr2 = _mm256_permute2x128_si256::<49>(p0, p2);
    (bgr0, p1, bgr2)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_havg_epu8(a: __m256i, b: __m256i) -> __m256i {
    let ones = _mm256_set1_epi8(1);
    let sums_lo = _mm256_maddubs_epi16(a, ones);
    let ones_16 = _mm256_set1_epi16(1);
    let lo = _mm256_srli_epi16::<1>(_mm256_add_epi16(sums_lo, ones_16));
    let sums_hi = _mm256_maddubs_epi16(b, ones);
    let hi = _mm256_srli_epi16::<1>(_mm256_add_epi16(sums_hi, ones_16));
    avx_pairwise_avg_epi16(lo, hi)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_load_deinterleave_rgb_for_yuv<const ORIGINS: u8>(
    ptr: *const u8,
) -> (__m256i, __m256i, __m256i) {
    let source_channels: YuvSourceChannels = ORIGINS.into();

    let (r_values, g_values, b_values);

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let row_1 = _mm256_loadu_si256(ptr as *const __m256i);
            let row_2 = _mm256_loadu_si256(ptr.add(32) as *const __m256i);
            let row_3 = _mm256_loadu_si256(ptr.add(64) as *const __m256i);

            let (it1, it2, it3) = avx2_deinterleave_rgb(row_1, row_2, row_3);
            if source_channels == YuvSourceChannels::Rgb {
                r_values = it1;
                g_values = it2;
                b_values = it3;
            } else {
                r_values = it3;
                g_values = it2;
                b_values = it1;
            }
        }
        YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => {
            let row_1 = _mm256_loadu_si256(ptr as *const __m256i);
            let row_2 = _mm256_loadu_si256(ptr.add(32) as *const __m256i);
            let row_3 = _mm256_loadu_si256(ptr.add(64) as *const __m256i);
            let row_4 = _mm256_loadu_si256(ptr.add(96) as *const __m256i);

            let (it1, it2, it3, _) = _mm256_deinterleave_rgba_epi8(row_1, row_2, row_3, row_4);
            if source_channels == YuvSourceChannels::Rgba {
                r_values = it1;
                g_values = it2;
                b_values = it3;
            } else {
                r_values = it3;
                g_values = it2;
                b_values = it1;
            }
        }
    }

    (r_values, g_values, b_values)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_load_deinterleave_rgb<const ORIGINS: u8>(
    ptr: *const u8,
) -> (__m256i, __m256i, __m256i, __m256i) {
    let source_channels: YuvSourceChannels = ORIGINS.into();

    let (r_values, g_values, b_values, a_values);

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let row_1 = _mm256_loadu_si256(ptr as *const __m256i);
            let row_2 = _mm256_loadu_si256(ptr.add(32) as *const __m256i);
            let row_3 = _mm256_loadu_si256(ptr.add(64) as *const __m256i);

            let (it1, it2, it3) = avx2_deinterleave_rgb(row_1, row_2, row_3);
            if source_channels == YuvSourceChannels::Rgb {
                r_values = it1;
                g_values = it2;
                b_values = it3;
            } else {
                r_values = it3;
                g_values = it2;
                b_values = it1;
            }
            a_values = _mm256_set1_epi8(255u8 as i8);
        }
        YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => {
            let row_1 = _mm256_loadu_si256(ptr as *const __m256i);
            let row_2 = _mm256_loadu_si256(ptr.add(32) as *const __m256i);
            let row_3 = _mm256_loadu_si256(ptr.add(64) as *const __m256i);
            let row_4 = _mm256_loadu_si256(ptr.add(96) as *const __m256i);

            let (it1, it2, it3, it4) = _mm256_deinterleave_rgba_epi8(row_1, row_2, row_3, row_4);
            if source_channels == YuvSourceChannels::Rgba {
                r_values = it1;
                g_values = it2;
                b_values = it3;
                a_values = it4;
            } else {
                r_values = it3;
                g_values = it2;
                b_values = it1;
                a_values = it4;
            }
        }
    }

    (r_values, g_values, b_values, a_values)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_load_deinterleave_half_rgb_for_yuv<const ORIGINS: u8>(
    ptr: *const u8,
) -> (__m256i, __m256i, __m256i) {
    let source_channels: YuvSourceChannels = ORIGINS.into();

    let (r_values, g_values, b_values);

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let row_1 = _mm256_loadu_si256(ptr as *const __m256i);
            let row_2 = _mm_loadu_si128(ptr.add(32) as *const __m128i);

            let (it1, it2, it3) =
                avx2_deinterleave_rgb(row_1, _mm256_castsi128_si256(row_2), _mm256_setzero_si256());
            if source_channels == YuvSourceChannels::Rgb {
                r_values = it1;
                g_values = it2;
                b_values = it3;
            } else {
                r_values = it3;
                g_values = it2;
                b_values = it1;
            }
        }
        YuvSourceChannels::Rgba | YuvSourceChannels::Bgra => {
            let row_1 = _mm256_loadu_si256(ptr as *const __m256i);
            let row_2 = _mm256_loadu_si256(ptr.add(32) as *const __m256i);

            let (it1, it2, it3, _) = _mm256_deinterleave_rgba_epi8(
                row_1,
                row_2,
                _mm256_setzero_si256(),
                _mm256_setzero_si256(),
            );
            if source_channels == YuvSourceChannels::Rgba {
                r_values = it1;
                g_values = it2;
                b_values = it3;
            } else {
                r_values = it3;
                g_values = it2;
                b_values = it1;
            }
        }
    }

    (r_values, g_values, b_values)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_store_interleave_rgb16_for_yuv<const ORIGINS: u8>(
    ptr: *mut u16,
    r: __m256i,
    g: __m256i,
    b: __m256i,
    a: __m256i,
) {
    let destination_channels: YuvSourceChannels = ORIGINS.into();

    match destination_channels {
        YuvSourceChannels::Rgb => {
            let dst_pack = _mm256_interleave_rgb_epi16(r, g, b);
            _mm256_storeu_si256(ptr as *mut __m256i, dst_pack.0);
            _mm256_storeu_si256(ptr.add(16) as *mut __m256i, dst_pack.1);
            _mm256_storeu_si256(ptr.add(32) as *mut __m256i, dst_pack.2);
        }
        YuvSourceChannels::Bgr => {
            let dst_pack = _mm256_interleave_rgb_epi16(b, g, r);
            _mm256_storeu_si256(ptr as *mut __m256i, dst_pack.0);
            _mm256_storeu_si256(ptr.add(16) as *mut __m256i, dst_pack.1);
            _mm256_storeu_si256(ptr.add(32) as *mut __m256i, dst_pack.2);
        }
        YuvSourceChannels::Rgba => {
            let dst_pack = _mm256_interleave_rgba_epi16(r, g, b, a);
            _mm256_storeu_si256(ptr as *mut __m256i, dst_pack.0);
            _mm256_storeu_si256(ptr.add(16) as *mut __m256i, dst_pack.1);
            _mm256_storeu_si256(ptr.add(32) as *mut __m256i, dst_pack.2);
            _mm256_storeu_si256(ptr.add(48) as *mut __m256i, dst_pack.3);
        }
        YuvSourceChannels::Bgra => {
            let dst_pack = _mm256_interleave_rgba_epi16(b, g, r, a);
            _mm256_storeu_si256(ptr as *mut __m256i, dst_pack.0);
            _mm256_storeu_si256(ptr.add(16) as *mut __m256i, dst_pack.1);
            _mm256_storeu_si256(ptr.add(32) as *mut __m256i, dst_pack.2);
            _mm256_storeu_si256(ptr.add(48) as *mut __m256i, dst_pack.3);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm256_store_interleave_rgb_half_for_yuv<const ORIGINS: u8>(
    ptr: *mut u8,
    r: __m256i,
    g: __m256i,
    b: __m256i,
    a: __m256i,
) {
    let destination_channels: YuvSourceChannels = ORIGINS.into();

    match destination_channels {
        YuvSourceChannels::Rgb => {
            let dst_pack = avx2_interleave_rgb(r, g, b);
            _mm256_storeu_si256(ptr as *mut __m256i, dst_pack.0);
            _mm_storeu_si128(
                ptr.add(32) as *mut __m128i,
                _mm256_castsi256_si128(dst_pack.1),
            );
        }
        YuvSourceChannels::Bgr => {
            let dst_pack = avx2_interleave_rgb(b, g, r);
            _mm256_storeu_si256(ptr as *mut __m256i, dst_pack.0);
            _mm_storeu_si128(
                ptr.add(32) as *mut __m128i,
                _mm256_castsi256_si128(dst_pack.1),
            );
        }
        YuvSourceChannels::Rgba => {
            let dst_pack = _mm256_interleave_rgba(r, g, b, a);
            _mm256_storeu_si256(ptr as *mut __m256i, dst_pack.0);
            _mm256_storeu_si256(ptr.add(32) as *mut __m256i, dst_pack.1);
        }
        YuvSourceChannels::Bgra => {
            let dst_pack = _mm256_interleave_rgba(b, g, r, a);
            _mm256_storeu_si256(ptr as *mut __m256i, dst_pack.0);
            _mm256_storeu_si256(ptr.add(32) as *mut __m256i, dst_pack.1);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm256_store_interleave_rgb_for_yuv<const ORIGINS: u8>(
    ptr: *mut u8,
    r: __m256i,
    g: __m256i,
    b: __m256i,
    a: __m256i,
) {
    let destination_channels: YuvSourceChannels = ORIGINS.into();

    match destination_channels {
        YuvSourceChannels::Rgb => {
            avx2_store_u8_rgb(ptr, r, g, b);
        }
        YuvSourceChannels::Bgr => {
            avx2_store_u8_rgb(ptr, b, g, r);
        }
        YuvSourceChannels::Rgba => {
            _mm256_store_interleaved_epi8(ptr, r, g, b, a);
        }
        YuvSourceChannels::Bgra => {
            _mm256_store_interleaved_epi8(ptr, b, g, r, a);
        }
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm256_deinterleave_rgba_epi16(
    a: __m256i,
    b: __m256i,
    c: __m256i,
    d: __m256i,
) -> (__m256i, __m256i, __m256i, __m256i) {
    let sh = _mm256_setr_epi8(
        0, 1, 8, 9, 2, 3, 10, 11, 4, 5, 12, 13, 6, 7, 14, 15, 0, 1, 8, 9, 2, 3, 10, 11, 4, 5, 12,
        13, 6, 7, 14, 15,
    );
    let p0 = _mm256_shuffle_epi8(a, sh);
    let p1 = _mm256_shuffle_epi8(b, sh);
    let p2 = _mm256_shuffle_epi8(c, sh);
    let p3 = _mm256_shuffle_epi8(d, sh);

    let p01l = _mm256_unpacklo_epi32(p0, p1);
    let p01h = _mm256_unpackhi_epi32(p0, p1);
    let p23l = _mm256_unpacklo_epi32(p2, p3);
    let p23h = _mm256_unpackhi_epi32(p2, p3);

    let pll = _mm256_permute2x128_si256::<32>(p01l, p23l);
    let plh = _mm256_permute2x128_si256::<49>(p01l, p23l);
    let phl = _mm256_permute2x128_si256::<32>(p01h, p23h);
    let phh = _mm256_permute2x128_si256::<49>(p01h, p23h);

    let b0 = _mm256_unpacklo_epi32(pll, plh);
    let g0 = _mm256_unpackhi_epi32(pll, plh);
    let r0 = _mm256_unpacklo_epi32(phl, phh);
    let a0 = _mm256_unpackhi_epi32(phl, phh);
    (b0, g0, r0, a0)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_deinterleave_rgb_epi16(
    a: __m256i,
    b: __m256i,
    c: __m256i,
) -> (__m256i, __m256i, __m256i) {
    let s02_low = _mm256_permute2x128_si256::<32>(a, c);
    let s02_high = _mm256_permute2x128_si256::<49>(a, c);

    let m0 = _mm256_setr_epi8(
        0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1,
        -1, 0, 0, 0, 0,
    );
    let m1 = _mm256_setr_epi8(
        0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0, -1, -1, 0, 0, 0, 0,
        -1, -1, 0, 0,
    );
    let b0 = _mm256_blendv_epi8(_mm256_blendv_epi8(s02_low, s02_high, m0), b, m1);
    let g0 = _mm256_blendv_epi8(_mm256_blendv_epi8(b, s02_low, m0), s02_high, m1);
    let r0 = _mm256_blendv_epi8(_mm256_blendv_epi8(s02_high, s02_low, m1), b, m0);
    let sh_b = _mm256_setr_epi8(
        0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15, 4, 5, 10, 11, 0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14,
        15, 4, 5, 10, 11,
    );
    let sh_g = _mm256_setr_epi8(
        2, 3, 8, 9, 14, 15, 4, 5, 10, 11, 0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15, 4, 5, 10, 11, 0,
        1, 6, 7, 12, 13,
    );
    let sh_r = _mm256_setr_epi8(
        4, 5, 10, 11, 0, 1, 6, 7, 12, 13, 2, 3, 8, 9, 14, 15, 4, 5, 10, 11, 0, 1, 6, 7, 12, 13, 2,
        3, 8, 9, 14, 15,
    );
    let b0 = _mm256_shuffle_epi8(b0, sh_b);
    let g0 = _mm256_shuffle_epi8(g0, sh_g);
    let r0 = _mm256_shuffle_epi8(r0, sh_r);
    (b0, g0, r0)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_load_deinterleave_rgb16_for_yuv<const CHANS: u8>(
    ptr: *const u16,
) -> (__m256i, __m256i, __m256i) {
    let r_values;
    let g_values;
    let b_values;

    let source_channels: YuvSourceChannels = CHANS.into();

    let row0 = _mm256_loadu_si256(ptr as *const __m256i);
    let row1 = _mm256_loadu_si256(ptr.add(16) as *const __m256i);
    let row2 = _mm256_loadu_si256(ptr.add(32) as *const __m256i);

    match source_channels {
        YuvSourceChannels::Rgb | YuvSourceChannels::Bgr => {
            let rgb_values = _mm256_deinterleave_rgb_epi16(row0, row1, row2);
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
            let row3 = _mm256_loadu_si256(ptr.add(48) as *const __m256i);
            let rgb_values = _mm256_deinterleave_rgba_epi16(row0, row1, row2, row3);
            r_values = rgb_values.0;
            g_values = rgb_values.1;
            b_values = rgb_values.2;
        }
        YuvSourceChannels::Bgra => {
            let row3 = _mm256_loadu_si256(ptr.add(48) as *const __m256i);
            let rgb_values = _mm256_deinterleave_rgba_epi16(row0, row1, row2, row3);
            r_values = rgb_values.2;
            g_values = rgb_values.1;
            b_values = rgb_values.0;
        }
    }
    (r_values, g_values, b_values)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_interleave_epi16(x: __m256i, y: __m256i) -> (__m256i, __m256i) {
    let xy_l = _mm256_unpacklo_epi16(x, y);
    let xy_h = _mm256_unpackhi_epi16(x, y);

    let xy0 = _mm256_permute2x128_si256::<32>(xy_l, xy_h);
    let xy1 = _mm256_permute2x128_si256::<49>(xy_l, xy_h);
    (xy0, xy1)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_from_msb_epi16<const BIT_DEPTH: usize>(a: __m256i) -> __m256i {
    if BIT_DEPTH == 10 {
        _mm256_srli_epi16::<6>(a)
    } else if BIT_DEPTH == 12 {
        _mm256_srli_epi16::<4>(a)
    } else if BIT_DEPTH == 14 {
        _mm256_srli_epi16::<2>(a)
    } else {
        a
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm256_to_msb_epi16<const BIT_DEPTH: usize>(a: __m256i) -> __m256i {
    if BIT_DEPTH == 10 {
        _mm256_slli_epi16::<6>(a)
    } else if BIT_DEPTH == 12 {
        _mm256_slli_epi16::<4>(a)
    } else if BIT_DEPTH == 14 {
        _mm256_slli_epi16::<2>(a)
    } else {
        a
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm256_store_shr_epi16_epi8<const BIT_DEPTH: usize>(a: __m256i) -> __m256i {
    if BIT_DEPTH == 10 {
        _mm256_srai_epi16::<2>(a)
    } else if BIT_DEPTH == 12 {
        _mm256_srai_epi16::<4>(a)
    } else if BIT_DEPTH == 14 {
        _mm256_srai_epi16::<6>(a)
    } else if BIT_DEPTH == 16 {
        _mm256_srai_epi16::<8>(a)
    } else {
        a
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm256_affine_transform<const PRECISION: i32, const HAS_DOT: bool>(
    slope: __m256i,
    v0: __m256i,
    v1: __m256i,
    w0: __m256i,
    w1: __m256i,
) -> __m256i {
    #[cfg(feature = "nightly_avx512")]
    {
        if HAS_DOT {
            let j = _mm256_srli_epi32::<PRECISION>(_mm256_dpwssd_avx_epi32(
                _mm256_dpwssd_avx_epi32(slope, v0, w0),
                v1,
                w1,
            ));
            avx2_pack_u32(j, j)
        } else {
            let v0w0 = _mm256_madd_epi16(v0, w0);
            let v1w1 = _mm256_madd_epi16(v1, w1);
            let j = _mm256_srli_epi32::<PRECISION>(_mm256_add_epi32(
                slope,
                _mm256_add_epi32(v0w0, v1w1),
            ));
            avx2_pack_u32(j, j)
        }
    }
    #[cfg(not(feature = "nightly_avx512"))]
    {
        let v0w0 = _mm256_madd_epi16(v0, w0);
        let v1w1 = _mm256_madd_epi16(v1, w1);
        let j =
            _mm256_srli_epi32::<PRECISION>(_mm256_add_epi32(slope, _mm256_add_epi32(v0w0, v1w1)));
        crate::avx2::avx2_utils::avx2_pack_u32(j, j)
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm256_affine_v_dot<const PRECISION: i32>(
    slope: __m256i,
    v0: __m256i,
    v1: __m256i,
    b0: __m256i,
    b1: __m256i,
    w0: __m256i,
    w1: __m256i,
) -> __m256i {
    let y_l_l = _mm256_add_epi32(
        slope,
        _mm256_add_epi32(_mm256_madd_epi16(v0, w0), _mm256_madd_epi16(b0, w1)),
    );
    let y_l_h = _mm256_add_epi32(
        slope,
        _mm256_add_epi32(_mm256_madd_epi16(v1, w0), _mm256_madd_epi16(b1, w1)),
    );
    avx2_pack_u32(
        _mm256_srli_epi32::<PRECISION>(y_l_l),
        _mm256_srli_epi32::<PRECISION>(y_l_h),
    )
}

#[inline(always)]
pub(crate) unsafe fn _mm256_affine_uv_dot<const PRECISION: i32, const HAS_DOT: bool>(
    accumulator: __m256i,
    v0: __m256i,
    v1: __m256i,
    b0: __m256i,
    b1: __m256i,
    w0: __m256i,
    w1: __m256i,
) -> __m256i {
    #[cfg(feature = "nightly_avx512")]
    {
        if HAS_DOT {
            let j0 = _mm256_dpwssd_avx_epi32(accumulator, v0, w0);
            let j1 = _mm256_dpwssd_avx_epi32(accumulator, v1, w0);
            let y_l_l = _mm256_dpwssd_avx_epi32(j0, b0, w1);
            let y_l_h = _mm256_dpwssd_avx_epi32(j1, b1, w1);
            _mm256_packus_epi32(
                _mm256_srli_epi32::<PRECISION>(y_l_l),
                _mm256_srli_epi32::<PRECISION>(y_l_h),
            )
        } else {
            let v0w0 = _mm256_madd_epi16(v0, w0);
            let v1w0 = _mm256_madd_epi16(v1, w0);
            let b0w1 = _mm256_madd_epi16(b0, w1);
            let b1w1 = _mm256_madd_epi16(b1, w1);

            let j0 = _mm256_add_epi32(v0w0, b0w1);
            let j1 = _mm256_add_epi32(v1w0, b1w1);

            let y_l_l = _mm256_add_epi32(accumulator, j0);
            let y_l_h = _mm256_add_epi32(accumulator, j1);
            _mm256_packus_epi32(
                _mm256_srli_epi32::<PRECISION>(y_l_l),
                _mm256_srli_epi32::<PRECISION>(y_l_h),
            )
        }
    }
    #[cfg(not(feature = "nightly_avx512"))]
    {
        let v0w0 = _mm256_madd_epi16(v0, w0);
        let v1w0 = _mm256_madd_epi16(v1, w0);
        let b0w1 = _mm256_madd_epi16(b0, w1);
        let b1w1 = _mm256_madd_epi16(b1, w1);

        let j0 = _mm256_add_epi32(v0w0, b0w1);
        let j1 = _mm256_add_epi32(v1w0, b1w1);

        let y_l_l = _mm256_add_epi32(accumulator, j0);
        let y_l_h = _mm256_add_epi32(accumulator, j1);
        _mm256_packus_epi32(
            _mm256_srli_epi32::<PRECISION>(y_l_l),
            _mm256_srli_epi32::<PRECISION>(y_l_h),
        )
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm256_double_affine_uv_dot<const PRECISION: i32>(
    accumulator: __m256i,
    v0: __m256i,
    v1: __m256i,
    v2: __m256i,
    v3: __m256i,
    b0: __m256i,
    b1: __m256i,
    b2: __m256i,
    b3: __m256i,
    w0: __m256i,
    w1: __m256i,
) -> (__m256i, __m256i) {
    let v0w0 = _mm256_madd_epi16(v0, w0);
    let v1w0 = _mm256_madd_epi16(v1, w0);
    let b0w1 = _mm256_madd_epi16(b0, w1);
    let b1w1 = _mm256_madd_epi16(b1, w1);

    let v2w0 = _mm256_madd_epi16(v2, w0);
    let v3w0 = _mm256_madd_epi16(v3, w0);
    let b2w1 = _mm256_madd_epi16(b2, w1);
    let b3w1 = _mm256_madd_epi16(b3, w1);

    let j0 = _mm256_add_epi32(v0w0, b0w1);
    let j1 = _mm256_add_epi32(v1w0, b1w1);

    let j2 = _mm256_add_epi32(v2w0, b2w1);
    let j3 = _mm256_add_epi32(v3w0, b3w1);

    let y0_l_l = _mm256_add_epi32(accumulator, j0);
    let y0_l_h = _mm256_add_epi32(accumulator, j1);

    let y1_l_l = _mm256_add_epi32(accumulator, j2);
    let y1_l_h = _mm256_add_epi32(accumulator, j3);

    let m0 = _mm256_srai_epi32::<PRECISION>(y0_l_l);
    let m1 = _mm256_srai_epi32::<PRECISION>(y0_l_h);
    let m2 = _mm256_srai_epi32::<PRECISION>(y1_l_l);
    let m3 = _mm256_srai_epi32::<PRECISION>(y1_l_h);
    (_mm256_packs_epi32(m0, m1), _mm256_packs_epi32(m2, m3))
}

#[inline(always)]
pub(crate) unsafe fn _mm256_double_affine_uv_s_dot<const PRECISION: i32>(
    v0: __m256i,
    v1: __m256i,
    v2: __m256i,
    v3: __m256i,
    b0: __m256i,
    b1: __m256i,
    b2: __m256i,
    b3: __m256i,
    w0: __m256i,
    w1: __m256i,
) -> (__m256i, __m256i) {
    let v0w0 = _mm256_madd_epi16(v0, w0);
    let v1w0 = _mm256_madd_epi16(v1, w0);
    let b0w1 = _mm256_madd_epi16(b0, w1);
    let b1w1 = _mm256_madd_epi16(b1, w1);

    let v2w0 = _mm256_madd_epi16(v2, w0);
    let v3w0 = _mm256_madd_epi16(v3, w0);
    let b2w1 = _mm256_madd_epi16(b2, w1);
    let b3w1 = _mm256_madd_epi16(b3, w1);

    let j0 = _mm256_add_epi32(v0w0, b0w1);
    let j1 = _mm256_add_epi32(v1w0, b1w1);

    let j2 = _mm256_add_epi32(v2w0, b2w1);
    let j3 = _mm256_add_epi32(v3w0, b3w1);

    let m0 = _mm256_srai_epi32::<PRECISION>(j0);
    let m1 = _mm256_srai_epi32::<PRECISION>(j1);
    let m2 = _mm256_srai_epi32::<PRECISION>(j2);
    let m3 = _mm256_srai_epi32::<PRECISION>(j3);
    (_mm256_packs_epi32(m0, m1), _mm256_packs_epi32(m2, m3))
}

#[inline(always)]
pub(crate) unsafe fn _mm256_mul_add_epi16<const HAS_DOT: bool>(
    accumulator: __m256i,
    v0: __m256i,
    w0: __m256i,
) -> __m256i {
    #[cfg(feature = "nightly_avx512")]
    if HAS_DOT {
        _mm256_dpwssd_avx_epi32(accumulator, v0, w0)
    } else {
        _mm256_add_epi32(accumulator, _mm256_madd_epi16(v0, w0))
    }
    #[cfg(not(feature = "nightly_avx512"))]
    _mm256_add_epi32(accumulator, _mm256_madd_epi16(v0, w0))
}

#[inline(always)]
pub(crate) unsafe fn _mm256_mul_sub_epi16(
    accumulator: __m256i,
    v0: __m256i,
    w0: __m256i,
) -> __m256i {
    _mm256_sub_epi32(accumulator, _mm256_madd_epi16(v0, w0))
}

#[inline(always)]
pub(crate) unsafe fn _mm256_affine_dot<const PRECISION: i32, const HAS_DOT: bool>(
    accumulator: __m256i,
    v0: __m256i,
    v1: __m256i,
    b0: __m256i,
    b1: __m256i,
    w0: __m256i,
    w1: __m256i,
) -> __m256i {
    #[cfg(feature = "nightly_avx512")]
    {
        if HAS_DOT {
            let j0 = _mm256_dpwssd_avx_epi32(accumulator, v0, w0);
            let j1 = _mm256_dpwssd_avx_epi32(accumulator, v1, w0);
            let y_l_l = _mm256_dpwssd_avx_epi32(j0, b0, w1);
            let y_l_h = _mm256_dpwssd_avx_epi32(j1, b1, w1);
            avx2_pack_u32(
                _mm256_srli_epi32::<PRECISION>(y_l_l),
                _mm256_srli_epi32::<PRECISION>(y_l_h),
            )
        } else {
            let v0w0 = _mm256_madd_epi16(v0, w0);
            let v1w0 = _mm256_madd_epi16(v1, w0);
            let b0w1 = _mm256_madd_epi16(b0, w1);
            let b1w1 = _mm256_madd_epi16(b1, w1);

            let j0 = _mm256_add_epi32(v0w0, b0w1);
            let j1 = _mm256_add_epi32(v1w0, b1w1);

            let y_l_l = _mm256_add_epi32(accumulator, j0);
            let y_l_h = _mm256_add_epi32(accumulator, j1);
            avx2_pack_u32(
                _mm256_srli_epi32::<PRECISION>(y_l_l),
                _mm256_srli_epi32::<PRECISION>(y_l_h),
            )
        }
    }
    #[cfg(not(feature = "nightly_avx512"))]
    {
        let v0w0 = _mm256_madd_epi16(v0, w0);
        let v1w0 = _mm256_madd_epi16(v1, w0);
        let b0w1 = _mm256_madd_epi16(b0, w1);
        let b1w1 = _mm256_madd_epi16(b1, w1);

        let j0 = _mm256_add_epi32(v0w0, b0w1);
        let j1 = _mm256_add_epi32(v1w0, b1w1);

        let y_l_l = _mm256_add_epi32(accumulator, j0);
        let y_l_h = _mm256_add_epi32(accumulator, j1);
        avx2_pack_u32(
            _mm256_srli_epi32::<PRECISION>(y_l_l),
            _mm256_srli_epi32::<PRECISION>(y_l_h),
        )
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm256_expand8_to_10(v: __m256i) -> (__m256i, __m256i) {
    let (v0, v1) = _mm256_interleave_epi8(v, v);
    (_mm256_srli_epi16::<6>(v0), _mm256_srli_epi16::<6>(v1))
}

#[inline(always)]
pub(crate) unsafe fn _mm256_expand8_unordered_to_10(v: __m256i) -> (__m256i, __m256i) {
    let v0 = _mm256_unpacklo_epi8(v, v);
    let v1 = _mm256_unpackhi_epi8(v, v);
    (_mm256_srli_epi16::<6>(v0), _mm256_srli_epi16::<6>(v1))
}

#[inline(always)]
pub(crate) unsafe fn _mm256_expand_bp_by2<const BIT_DEPTH: usize>(v: __m256i) -> __m256i {
    if BIT_DEPTH == 10 {
        _mm256_or_si256(_mm256_slli_epi16::<2>(v), _mm256_srli_epi16::<8>(v))
    } else if BIT_DEPTH == 12 {
        _mm256_or_si256(_mm256_slli_epi16::<2>(v), _mm256_srli_epi16::<10>(v))
    } else {
        v
    }
}

#[inline(always)]
pub(crate) unsafe fn _mm256_sqrdmlah_dot<const A_E: i32>(
    r_low: __m256i,
    r_high: __m256i,
    g_low: __m256i,
    g_high: __m256i,
    b_low: __m256i,
    b_high: __m256i,
    y_bias: __m256i,
    v_yr: __m256i,
    v_yg: __m256i,
    v_yb: __m256i,
) -> __m256i {
    let y0_l_r = _mm256_mulhrs_epi16(r_low, v_yr);
    let y0_h_r = _mm256_mulhrs_epi16(r_high, v_yr);
    let y0_l_g = _mm256_mulhrs_epi16(g_low, v_yg);
    let y0_h_g = _mm256_mulhrs_epi16(g_high, v_yg);
    let y0_l_b = _mm256_mulhrs_epi16(b_low, v_yb);
    let y0_h_b = _mm256_mulhrs_epi16(b_high, v_yb);

    let y0_l_s = _mm256_add_epi16(y0_l_r, y0_l_g);
    let y0_h_s = _mm256_add_epi16(y0_h_r, y0_h_g);

    let y0_l_k = _mm256_add_epi16(y0_l_s, y0_l_b);
    let y0_h_k = _mm256_add_epi16(y0_h_s, y0_h_b);

    let y0_l_m = _mm256_add_epi16(y_bias, y0_l_k);
    let y0_h_m = _mm256_add_epi16(y_bias, y0_h_k);

    let y0_l = _mm256_srli_epi16::<A_E>(y0_l_m);
    let y0_h = _mm256_srli_epi16::<A_E>(y0_h_m);

    _mm256_packus_epi16(y0_l, y0_h)
}

#[inline(always)]
pub(crate) unsafe fn _mm256_set4r_epi8(e00: i8, e01: i8, e02: i8, e03: i8) -> __m256i {
    _mm256_setr_epi8(
        e00, e01, e02, e03, e00, e01, e02, e03, e00, e01, e02, e03, e00, e01, e02, e03, e00, e01,
        e02, e03, e00, e01, e02, e03, e00, e01, e02, e03, e00, e01, e02, e03,
    )
}

#[inline(always)]
pub(crate) unsafe fn _mm256_expand_rgb_to_rgba(
    m0: __m256i,
    m1: __m256i,
    m2: __m256i,
) -> (__m256i, __m256i, __m256i, __m256i) {
    let shuffle_0 = _mm256_setr_epi32(0, 1, 2, 3, 3, 4, 5, 6);
    let shuffle_1 = _mm256_setr_epi32(6, 7, 0, 0, 0, 0, 0, 0);
    let shuffle_1_0 = _mm256_setr_epi32(0, 0, 0, 1, 1, 2, 3, 4);
    let shuffle_2 = _mm256_setr_epi32(4, 5, 6, 7, 7, 0, 0, 0);
    let shuffle_2_1 = _mm256_setr_epi32(0, 0, 0, 0, 0, 0, 1, 2);
    let blend_v1_mask = _mm256_setr_epi8(
        0, 0, 0, 0, 0, 0, 0, 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1, -1, -1, -1,
    );
    let rgb_shuffle = _mm256_setr_epi8(
        0, 1, 2, -1, 3, 4, 5, -1, 6, 7, 8, -1, 9, 10, 11, -1, 0, 1, 2, -1, 3, 4, 5, -1, 6, 7, 8,
        -1, 9, 10, 11, -1,
    );

    let blend_v2_mask = _mm256_setr_epi8(
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, -1, -1, -1, -1, -1, -1, -1,
        -1, -1, -1, -1,
    );

    let shuffle_3 = _mm256_setr_epi32(2, 3, 4, 5, 5, 6, 7, 0);

    let permuted0 = _mm256_permutevar8x32_epi32(m0, shuffle_0);
    let permuted1 = _mm256_permutevar8x32_epi32(m0, shuffle_1);
    let permuted1_0 = _mm256_permutevar8x32_epi32(m1, shuffle_1_0);
    let permuted2 = _mm256_permutevar8x32_epi32(m1, shuffle_2);
    let permuted2_0 = _mm256_permutevar8x32_epi32(m2, shuffle_2_1);

    let v0 = _mm256_shuffle_epi8(permuted0, rgb_shuffle);

    let n1 = _mm256_blendv_epi8(permuted1, permuted1_0, blend_v1_mask);
    let v1 = _mm256_shuffle_epi8(n1, rgb_shuffle);

    let n2 = _mm256_blendv_epi8(permuted2, permuted2_0, blend_v2_mask);
    let v2 = _mm256_shuffle_epi8(n2, rgb_shuffle);

    let n3 = _mm256_permutevar8x32_epi32(m2, shuffle_3);
    let v3 = _mm256_shuffle_epi8(n3, rgb_shuffle);

    (v0, v1, v2, v3)
}

#[inline(always)]
pub(crate) unsafe fn _avx_from_msb_epi16<const BIT_DEPTH: usize>(a: __m128i) -> __m128i {
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
pub(crate) unsafe fn sse_store_rgb_u8(ptr: *mut u8, r: __m128i, g: __m128i, b: __m128i) {
    let (v0, v1, v2) = sse_interleave_rgb(r, g, b);
    _mm_storeu_si128(ptr as *mut __m128i, v0);
    _mm_storeu_si128(ptr.add(16) as *mut __m128i, v1);
    _mm_storeu_si128(ptr.add(32) as *mut __m128i, v2);
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
