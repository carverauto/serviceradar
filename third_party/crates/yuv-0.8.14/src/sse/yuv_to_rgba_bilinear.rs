/*
 * Copyright (c) Radzivon Bartoshyk, 6/2025. All rights reserved.
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
use crate::sse::{_mm_store_interleave_half_rgb_for_yuv, _mm_store_interleave_rgb_for_yuv};
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_bilinear_interpolate_1_row_rgba<const DESTINATION_CHANNELS: u8, const Q: i32>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba: &mut [u8],
    width: u32,
) {
    unsafe {
        sse_bilinear_interpolate_1_row_rgba_impl::<DESTINATION_CHANNELS, Q>(
            range, transform, y_plane, u_plane, v_plane, rgba, width,
        );
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_bilinear_interpolate_1_row_rgba_impl<const DESTINATION_CHANNELS: u8, const Q: i32>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba: &mut [u8],
    width: u32,
) {
    unsafe {
        let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
        let channels = dst_chans.get_channels_count();

        let mut x = 0usize;
        let mut cx = 0usize;

        let y_coef = transform.y_coef.to_ne_bytes();
        let cr_coef = transform.cr_coef.to_ne_bytes();
        let cb_coef = transform.cb_coef.to_ne_bytes();
        let g_coef1 = (-transform.g_coeff_1).to_ne_bytes();
        let g_coef2 = (-transform.g_coeff_2).to_ne_bytes();

        let y_corr = _mm_set1_epi8(range.bias_y as i8);
        let uv_corr = _mm_set1_epi16(range.bias_uv as i16);
        let v_alpha = _mm_set1_epi8(255u8 as i8);
        let r_coef = _mm_set1_epi32(i32::from_ne_bytes([
            y_coef[0], y_coef[1], cr_coef[0], cr_coef[1],
        ]));
        let b_coef = _mm_set1_epi32(i32::from_ne_bytes([
            y_coef[0], y_coef[1], cb_coef[0], cb_coef[1],
        ]));
        let g_coef = _mm_set1_epi32(i32::from_ne_bytes([
            g_coef1[0], g_coef1[1], g_coef2[0], g_coef2[1],
        ]));
        let y_coef = _mm_set1_epi16(transform.y_coef);

        let inter_row01 = _mm_set1_epi16(i16::from_ne_bytes([3, 1]));
        let inter_row10 = _mm_set1_epi16(i16::from_ne_bytes([1, 3]));
        let inter_rnd = _mm_set1_epi16(2);
        let rnd = _mm_set1_epi32(1 << (Q - 1));

        while x + 17 < width as usize {
            let mut y_value = _mm_loadu_si128(y_plane.get_unchecked(x..).as_ptr().cast());
            let u_value0 = _mm_loadu_si64(u_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value1 = _mm_loadu_si64(u_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value0 = _mm_loadu_si64(v_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value1 = _mm_loadu_si64(v_plane.get_unchecked(cx + 1..).as_ptr().cast());

            y_value = _mm_subs_epu8(y_value, y_corr);

            let packed_uu01 = _mm_unpacklo_epi8(u_value0, u_value1);
            let packed_vv01 = _mm_unpacklo_epi8(v_value0, v_value1);

            let mut uu01 = _mm_maddubs_epi16(packed_uu01, inter_row01);
            let mut vv01 = _mm_maddubs_epi16(packed_vv01, inter_row01);
            let mut uu10 = _mm_maddubs_epi16(packed_uu01, inter_row10);
            let mut vv10 = _mm_maddubs_epi16(packed_vv01, inter_row10);

            let y_lo = _mm_unpacklo_epi8(y_value, _mm_setzero_si128());
            let y_hi = _mm_unpackhi_epi8(y_value, _mm_setzero_si128());

            uu01 = _mm_add_epi16(uu01, inter_rnd);
            vv01 = _mm_add_epi16(vv01, inter_rnd);

            uu01 = _mm_srli_epi16::<2>(uu01);
            vv01 = _mm_srli_epi16::<2>(vv01);

            uu10 = _mm_add_epi16(uu10, inter_rnd);
            vv10 = _mm_add_epi16(vv10, inter_rnd);

            uu10 = _mm_srli_epi16::<2>(uu10);
            vv10 = _mm_srli_epi16::<2>(vv10);

            uu01 = _mm_sub_epi16(uu01, uv_corr);
            vv01 = _mm_sub_epi16(vv01, uv_corr);
            uu10 = _mm_sub_epi16(uu10, uv_corr);
            vv10 = _mm_sub_epi16(vv10, uv_corr);

            let intl_uu_lo = _mm_unpacklo_epi16(uu01, uu10);
            let intl_uu_hi = _mm_unpackhi_epi16(uu01, uu10);
            let intl_vv_lo = _mm_unpacklo_epi16(vv01, vv10);
            let intl_vv_hi = _mm_unpackhi_epi16(vv01, vv10);

            let mut r0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_vv_lo), r_coef);
            let mut r1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_vv_lo), r_coef);
            let mut r2 = _mm_madd_epi16(_mm_unpacklo_epi16(y_hi, intl_vv_hi), r_coef);
            let mut r3 = _mm_madd_epi16(_mm_unpackhi_epi16(y_hi, intl_vv_hi), r_coef);

            r0 = _mm_add_epi32(r0, rnd);
            r1 = _mm_add_epi32(r1, rnd);
            r2 = _mm_add_epi32(r2, rnd);
            r3 = _mm_add_epi32(r3, rnd);

            r0 = _mm_srai_epi32::<Q>(r0);
            r1 = _mm_srai_epi32::<Q>(r1);
            r2 = _mm_srai_epi32::<Q>(r2);
            r3 = _mm_srai_epi32::<Q>(r3);

            let r01 = _mm_packus_epi32(r0, r1);
            let r23 = _mm_packus_epi32(r2, r3);
            let r0123 = _mm_packus_epi16(r01, r23);

            let mut b0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_uu_lo), b_coef);
            let mut b1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_uu_lo), b_coef);
            let mut b2 = _mm_madd_epi16(_mm_unpacklo_epi16(y_hi, intl_uu_hi), b_coef);
            let mut b3 = _mm_madd_epi16(_mm_unpackhi_epi16(y_hi, intl_uu_hi), b_coef);

            b0 = _mm_add_epi32(b0, rnd);
            b1 = _mm_add_epi32(b1, rnd);
            b2 = _mm_add_epi32(b2, rnd);
            b3 = _mm_add_epi32(b3, rnd);

            b0 = _mm_srai_epi32::<Q>(b0);
            b1 = _mm_srai_epi32::<Q>(b1);
            b2 = _mm_srai_epi32::<Q>(b2);
            b3 = _mm_srai_epi32::<Q>(b3);

            let b01 = _mm_packus_epi32(b0, b1);
            let b23 = _mm_packus_epi32(b2, b3);
            let b0123 = _mm_packus_epi16(b01, b23);

            let y_lo0_mul = _mm_mullo_epi16(y_lo, y_coef);
            let y_lo1_mul = _mm_mulhi_epi16(y_lo, y_coef);
            let y_hi0_mul = _mm_mullo_epi16(y_hi, y_coef);
            let y_hi1_mul = _mm_mulhi_epi16(y_hi, y_coef);

            let mut g0 = _mm_madd_epi16(_mm_unpacklo_epi16(intl_vv_lo, intl_uu_lo), g_coef);
            let mut g1 = _mm_madd_epi16(_mm_unpackhi_epi16(intl_vv_lo, intl_uu_lo), g_coef);
            let mut g2 = _mm_madd_epi16(_mm_unpacklo_epi16(intl_vv_hi, intl_uu_hi), g_coef);
            let mut g3 = _mm_madd_epi16(_mm_unpackhi_epi16(intl_vv_hi, intl_uu_hi), g_coef);

            g0 = _mm_add_epi32(g0, _mm_unpacklo_epi16(y_lo0_mul, y_lo1_mul));
            g1 = _mm_add_epi32(g1, _mm_unpackhi_epi16(y_lo0_mul, y_lo1_mul));
            g2 = _mm_add_epi32(g2, _mm_unpacklo_epi16(y_hi0_mul, y_hi1_mul));
            g3 = _mm_add_epi32(g3, _mm_unpackhi_epi16(y_hi0_mul, y_hi1_mul));

            g0 = _mm_add_epi32(g0, rnd);
            g1 = _mm_add_epi32(g1, rnd);
            g2 = _mm_add_epi32(g2, rnd);
            g3 = _mm_add_epi32(g3, rnd);

            g0 = _mm_srai_epi32::<Q>(g0);
            g1 = _mm_srai_epi32::<Q>(g1);
            g2 = _mm_srai_epi32::<Q>(g2);
            g3 = _mm_srai_epi32::<Q>(g3);

            let g01 = _mm_packus_epi32(g0, g1);
            let g23 = _mm_packus_epi32(g2, g3);
            let g0123 = _mm_packus_epi16(g01, g23);

            let dst_shift = x * channels;

            _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr().cast(),
                r0123,
                g0123,
                b0123,
                v_alpha,
            );

            x += 16;
            cx += 8;
        }

        while x + 9 < width as usize {
            let mut y_value = _mm_loadu_si64(y_plane.get_unchecked(x..).as_ptr().cast());
            let u_value0 = _mm_loadu_si32(u_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value1 = _mm_loadu_si32(u_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value0 = _mm_loadu_si32(v_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value1 = _mm_loadu_si32(v_plane.get_unchecked(cx + 1..).as_ptr().cast());

            y_value = _mm_subs_epu8(y_value, y_corr);

            let packed_uu01 = _mm_unpacklo_epi8(u_value0, u_value1);
            let packed_vv01 = _mm_unpacklo_epi8(v_value0, v_value1);

            let mut uu01 = _mm_maddubs_epi16(packed_uu01, inter_row01);
            let mut vv01 = _mm_maddubs_epi16(packed_vv01, inter_row01);
            let mut uu10 = _mm_maddubs_epi16(packed_uu01, inter_row10);
            let mut vv10 = _mm_maddubs_epi16(packed_vv01, inter_row10);

            let y_lo = _mm_unpacklo_epi8(y_value, _mm_setzero_si128());

            uu01 = _mm_add_epi16(uu01, inter_rnd);
            vv01 = _mm_add_epi16(vv01, inter_rnd);

            uu01 = _mm_srli_epi16::<2>(uu01);
            vv01 = _mm_srli_epi16::<2>(vv01);

            uu10 = _mm_add_epi16(uu10, inter_rnd);
            vv10 = _mm_add_epi16(vv10, inter_rnd);

            uu10 = _mm_srli_epi16::<2>(uu10);
            vv10 = _mm_srli_epi16::<2>(vv10);

            uu01 = _mm_sub_epi16(uu01, uv_corr);
            vv01 = _mm_sub_epi16(vv01, uv_corr);
            uu10 = _mm_sub_epi16(uu10, uv_corr);
            vv10 = _mm_sub_epi16(vv10, uv_corr);

            let intl_uu_lo = _mm_unpacklo_epi16(uu01, uu10);
            let intl_vv_lo = _mm_unpacklo_epi16(vv01, vv10);

            let mut r0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_vv_lo), r_coef);
            let mut r1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_vv_lo), r_coef);

            r0 = _mm_add_epi32(r0, rnd);
            r1 = _mm_add_epi32(r1, rnd);

            r0 = _mm_srai_epi32::<Q>(r0);
            r1 = _mm_srai_epi32::<Q>(r1);

            let r01 = _mm_packus_epi32(r0, r1);
            let r0123 = _mm_packus_epi16(r01, _mm_setzero_si128());

            let mut b0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_uu_lo), b_coef);
            let mut b1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_uu_lo), b_coef);

            b0 = _mm_add_epi32(b0, rnd);
            b1 = _mm_add_epi32(b1, rnd);

            b0 = _mm_srai_epi32::<Q>(b0);
            b1 = _mm_srai_epi32::<Q>(b1);

            let b01 = _mm_packus_epi32(b0, b1);
            let b0123 = _mm_packus_epi16(b01, _mm_setzero_si128());

            let y_lo0_mul = _mm_mullo_epi16(y_lo, y_coef);
            let y_lo1_mul = _mm_mulhi_epi16(y_lo, y_coef);

            let mut g0 = _mm_madd_epi16(_mm_unpacklo_epi16(intl_vv_lo, intl_uu_lo), g_coef);
            let mut g1 = _mm_madd_epi16(_mm_unpackhi_epi16(intl_vv_lo, intl_uu_lo), g_coef);

            g0 = _mm_add_epi32(g0, _mm_unpacklo_epi16(y_lo0_mul, y_lo1_mul));
            g1 = _mm_add_epi32(g1, _mm_unpackhi_epi16(y_lo0_mul, y_lo1_mul));

            g0 = _mm_add_epi32(g0, rnd);
            g1 = _mm_add_epi32(g1, rnd);

            g0 = _mm_srai_epi32::<Q>(g0);
            g1 = _mm_srai_epi32::<Q>(g1);

            let g01 = _mm_packus_epi32(g0, g1);
            let g0123 = _mm_packus_epi16(g01, _mm_setzero_si128());

            let dst_shift = x * channels;

            _mm_store_interleave_half_rgb_for_yuv::<DESTINATION_CHANNELS>(
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr().cast(),
                r0123,
                g0123,
                b0123,
                v_alpha,
            );

            x += 8;
            cx += 4;
        }

        if x < width as usize {
            let mut y_store: [u8; 17] = [0; 17];
            let mut u_store: [u8; 17] = [0; 17];
            let mut v_store: [u8; 17] = [0; 17];
            let mut rgba_store: [u8; 16 * 4] = [0; 16 * 4];

            let diff = width as usize - x;
            assert!(diff <= 16);

            std::ptr::copy_nonoverlapping(
                y_plane.get_unchecked(x..).as_ptr(),
                y_store.as_mut_ptr().cast(),
                diff,
            );

            let ux_diff = diff.div_ceil(2);

            std::ptr::copy_nonoverlapping(
                u_plane.get_unchecked(cx..).as_ptr(),
                u_store.as_mut_ptr().cast(),
                ux_diff,
            );

            u_store[ux_diff] = *u_plane.last().unwrap();
            v_store[ux_diff] = *v_plane.last().unwrap();

            std::ptr::copy_nonoverlapping(
                v_plane.get_unchecked(cx..).as_ptr(),
                v_store.as_mut_ptr().cast(),
                ux_diff,
            );

            let mut y_value = _mm_loadu_si128(y_store.as_ptr().cast());
            let u_value0 = _mm_loadu_si64(u_store.as_ptr().cast());
            let u_value1 = _mm_loadu_si64(u_store.get_unchecked(1..).as_ptr().cast());
            let v_value0 = _mm_loadu_si64(v_store.as_ptr().cast());
            let v_value1 = _mm_loadu_si64(v_store.get_unchecked(1..).as_ptr().cast());

            y_value = _mm_subs_epu8(y_value, y_corr);

            let packed_uu01 = _mm_unpacklo_epi8(u_value0, u_value1);
            let packed_vv01 = _mm_unpacklo_epi8(v_value0, v_value1);

            let mut uu01 = _mm_maddubs_epi16(packed_uu01, inter_row01);
            let mut vv01 = _mm_maddubs_epi16(packed_vv01, inter_row01);
            let mut uu10 = _mm_maddubs_epi16(packed_uu01, inter_row10);
            let mut vv10 = _mm_maddubs_epi16(packed_vv01, inter_row10);

            let y_lo = _mm_unpacklo_epi8(y_value, _mm_setzero_si128());
            let y_hi = _mm_unpackhi_epi8(y_value, _mm_setzero_si128());

            uu01 = _mm_add_epi16(uu01, inter_rnd);
            vv01 = _mm_add_epi16(vv01, inter_rnd);

            uu01 = _mm_srli_epi16::<2>(uu01);
            vv01 = _mm_srli_epi16::<2>(vv01);

            uu10 = _mm_add_epi16(uu10, inter_rnd);
            vv10 = _mm_add_epi16(vv10, inter_rnd);

            uu10 = _mm_srli_epi16::<2>(uu10);
            vv10 = _mm_srli_epi16::<2>(vv10);

            uu01 = _mm_sub_epi16(uu01, uv_corr);
            vv01 = _mm_sub_epi16(vv01, uv_corr);
            uu10 = _mm_sub_epi16(uu10, uv_corr);
            vv10 = _mm_sub_epi16(vv10, uv_corr);

            let intl_uu_lo = _mm_unpacklo_epi16(uu01, uu10);
            let intl_uu_hi = _mm_unpackhi_epi16(uu01, uu10);
            let intl_vv_lo = _mm_unpacklo_epi16(vv01, vv10);
            let intl_vv_hi = _mm_unpackhi_epi16(vv01, vv10);

            let mut r0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_vv_lo), r_coef);
            let mut r1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_vv_lo), r_coef);
            let mut r2 = _mm_madd_epi16(_mm_unpacklo_epi16(y_hi, intl_vv_hi), r_coef);
            let mut r3 = _mm_madd_epi16(_mm_unpackhi_epi16(y_hi, intl_vv_hi), r_coef);

            r0 = _mm_add_epi32(r0, rnd);
            r1 = _mm_add_epi32(r1, rnd);
            r2 = _mm_add_epi32(r2, rnd);
            r3 = _mm_add_epi32(r3, rnd);

            r0 = _mm_srai_epi32::<Q>(r0);
            r1 = _mm_srai_epi32::<Q>(r1);
            r2 = _mm_srai_epi32::<Q>(r2);
            r3 = _mm_srai_epi32::<Q>(r3);

            let r01 = _mm_packus_epi32(r0, r1);
            let r23 = _mm_packus_epi32(r2, r3);
            let r0123 = _mm_packus_epi16(r01, r23);

            let mut b0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_uu_lo), b_coef);
            let mut b1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_uu_lo), b_coef);
            let mut b2 = _mm_madd_epi16(_mm_unpacklo_epi16(y_hi, intl_uu_hi), b_coef);
            let mut b3 = _mm_madd_epi16(_mm_unpackhi_epi16(y_hi, intl_uu_hi), b_coef);

            b0 = _mm_add_epi32(b0, rnd);
            b1 = _mm_add_epi32(b1, rnd);
            b2 = _mm_add_epi32(b2, rnd);
            b3 = _mm_add_epi32(b3, rnd);

            b0 = _mm_srai_epi32::<Q>(b0);
            b1 = _mm_srai_epi32::<Q>(b1);
            b2 = _mm_srai_epi32::<Q>(b2);
            b3 = _mm_srai_epi32::<Q>(b3);

            let b01 = _mm_packus_epi32(b0, b1);
            let b23 = _mm_packus_epi32(b2, b3);
            let b0123 = _mm_packus_epi16(b01, b23);

            let y_lo0_mul = _mm_mullo_epi16(y_lo, y_coef);
            let y_lo1_mul = _mm_mulhi_epi16(y_lo, y_coef);
            let y_hi0_mul = _mm_mullo_epi16(y_hi, y_coef);
            let y_hi1_mul = _mm_mulhi_epi16(y_hi, y_coef);

            let mut g0 = _mm_madd_epi16(_mm_unpacklo_epi16(intl_vv_lo, intl_uu_lo), g_coef);
            let mut g1 = _mm_madd_epi16(_mm_unpackhi_epi16(intl_vv_lo, intl_uu_lo), g_coef);
            let mut g2 = _mm_madd_epi16(_mm_unpacklo_epi16(intl_vv_hi, intl_uu_hi), g_coef);
            let mut g3 = _mm_madd_epi16(_mm_unpackhi_epi16(intl_vv_hi, intl_uu_hi), g_coef);

            g0 = _mm_add_epi32(g0, _mm_unpacklo_epi16(y_lo0_mul, y_lo1_mul));
            g1 = _mm_add_epi32(g1, _mm_unpackhi_epi16(y_lo0_mul, y_lo1_mul));
            g2 = _mm_add_epi32(g2, _mm_unpacklo_epi16(y_hi0_mul, y_hi1_mul));
            g3 = _mm_add_epi32(g3, _mm_unpackhi_epi16(y_hi0_mul, y_hi1_mul));

            g0 = _mm_add_epi32(g0, rnd);
            g1 = _mm_add_epi32(g1, rnd);
            g2 = _mm_add_epi32(g2, rnd);
            g3 = _mm_add_epi32(g3, rnd);

            g0 = _mm_srai_epi32::<Q>(g0);
            g1 = _mm_srai_epi32::<Q>(g1);
            g2 = _mm_srai_epi32::<Q>(g2);
            g3 = _mm_srai_epi32::<Q>(g3);

            let g01 = _mm_packus_epi32(g0, g1);
            let g23 = _mm_packus_epi32(g2, g3);
            let g0123 = _mm_packus_epi16(g01, g23);

            _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
                rgba_store.as_mut_ptr().cast(),
                r0123,
                g0123,
                b0123,
                v_alpha,
            );

            let dst_shift = x * channels;
            std::ptr::copy_nonoverlapping(
                rgba_store.as_mut_ptr().cast(),
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
                diff * channels,
            );
        }
    }
}

pub(crate) fn sse_bilinear_interpolate_2_rows_rgba<const DESTINATION_CHANNELS: u8, const Q: i32>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u8],
    u0_plane: &[u8],
    u1_plane: &[u8],
    v0_plane: &[u8],
    v1_plane: &[u8],
    rgba: &mut [u8],
    width: u32,
) {
    unsafe {
        sse_bilinear_interpolate_2_rows_rgba_impl::<DESTINATION_CHANNELS, Q>(
            range, transform, y_plane, u0_plane, u1_plane, v0_plane, v1_plane, rgba, width,
        );
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_bilinear_interpolate_2_rows_rgba_impl<
    const DESTINATION_CHANNELS: u8,
    const Q: i32,
>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u8],
    u0_plane: &[u8],
    u1_plane: &[u8],
    v0_plane: &[u8],
    v1_plane: &[u8],
    rgba: &mut [u8],
    width: u32,
) {
    unsafe {
        let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
        let channels = dst_chans.get_channels_count();

        let mut x = 0usize;
        let mut cx = 0usize;

        let y_coef = transform.y_coef.to_ne_bytes();
        let cr_coef = transform.cr_coef.to_ne_bytes();
        let cb_coef = transform.cb_coef.to_ne_bytes();
        let g_coef1 = (-transform.g_coeff_1).to_ne_bytes();
        let g_coef2 = (-transform.g_coeff_2).to_ne_bytes();

        let y_corr = _mm_set1_epi8(range.bias_y as i8);
        let uv_corr = _mm_set1_epi16(range.bias_uv as i16);
        let v_alpha = _mm_set1_epi8(255u8 as i8);
        let r_coef = _mm_set1_epi32(i32::from_ne_bytes([
            y_coef[0], y_coef[1], cr_coef[0], cr_coef[1],
        ]));
        let b_coef = _mm_set1_epi32(i32::from_ne_bytes([
            y_coef[0], y_coef[1], cb_coef[0], cb_coef[1],
        ]));
        let g_coef = _mm_set1_epi32(i32::from_ne_bytes([
            g_coef1[0], g_coef1[1], g_coef2[0], g_coef2[1],
        ]));
        let y_coef = _mm_set1_epi16(transform.y_coef);

        let inter_row01 = _mm_set1_epi16(i16::from_ne_bytes([9, 3]));
        let inter_row23 = _mm_set1_epi16(i16::from_ne_bytes([3, 1]));
        let inter_row32 = _mm_set1_epi16(i16::from_ne_bytes([1, 3]));
        let inter_row_far = _mm_set1_epi16(i16::from_ne_bytes([3, 9]));
        let inter_rnd = _mm_set1_epi16(1 << 3);
        let rnd = _mm_set1_epi32(1 << (Q - 1));

        while x + 17 < width as usize {
            let mut y_value = _mm_loadu_si128(y_plane.get_unchecked(x..).as_ptr().cast());

            let u_value_x0_y0 = _mm_loadu_si64(u0_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value_x1_y0 = _mm_loadu_si64(u0_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value_x0_y0 = _mm_loadu_si64(v0_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value_x1_y0 = _mm_loadu_si64(v0_plane.get_unchecked(cx + 1..).as_ptr().cast());

            let u_value_x0_y1 = _mm_loadu_si64(u1_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value_x1_y1 = _mm_loadu_si64(u1_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value_x0_y1 = _mm_loadu_si64(v1_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value_x1_y1 = _mm_loadu_si64(v1_plane.get_unchecked(cx + 1..).as_ptr().cast());

            y_value = _mm_subs_epu8(y_value, y_corr);

            let packed_u0_y0 = _mm_unpacklo_epi8(u_value_x0_y0, u_value_x1_y0);
            let packed_v0_y0 = _mm_unpacklo_epi8(v_value_x0_y0, v_value_x1_y0);
            let packed_u0_y1 = _mm_unpacklo_epi8(u_value_x0_y1, u_value_x1_y1);
            let packed_v0_y1 = _mm_unpacklo_epi8(v_value_x0_y1, v_value_x1_y1);

            let mut uu01 = _mm_maddubs_epi16(packed_u0_y0, inter_row01);
            let mut vv01 = _mm_maddubs_epi16(packed_v0_y0, inter_row01);

            let mut uu10 = _mm_maddubs_epi16(packed_u0_y0, inter_row_far);
            let mut vv10 = _mm_maddubs_epi16(
                _mm_unpacklo_epi8(v_value_x0_y0, v_value_x1_y0),
                inter_row_far,
            );

            let y_lo = _mm_unpacklo_epi8(y_value, _mm_setzero_si128());
            let y_hi = _mm_unpackhi_epi8(y_value, _mm_setzero_si128());

            uu01 = _mm_add_epi16(uu01, _mm_maddubs_epi16(packed_u0_y1, inter_row23));
            vv01 = _mm_add_epi16(vv01, _mm_maddubs_epi16(packed_v0_y1, inter_row23));

            uu10 = _mm_add_epi16(uu10, _mm_maddubs_epi16(packed_u0_y1, inter_row32));
            vv10 = _mm_add_epi16(vv10, _mm_maddubs_epi16(packed_v0_y1, inter_row32));

            uu01 = _mm_add_epi16(uu01, inter_rnd);
            vv01 = _mm_add_epi16(vv01, inter_rnd);
            uu10 = _mm_add_epi16(uu10, inter_rnd);
            vv10 = _mm_add_epi16(vv10, inter_rnd);

            uu01 = _mm_srli_epi16::<4>(uu01);
            vv01 = _mm_srli_epi16::<4>(vv01);
            uu10 = _mm_srli_epi16::<4>(uu10);
            vv10 = _mm_srli_epi16::<4>(vv10);

            uu01 = _mm_sub_epi16(uu01, uv_corr);
            vv01 = _mm_sub_epi16(vv01, uv_corr);
            uu10 = _mm_sub_epi16(uu10, uv_corr);
            vv10 = _mm_sub_epi16(vv10, uv_corr);

            let intl_uu_lo = _mm_unpacklo_epi16(uu01, uu10);
            let intl_uu_hi = _mm_unpackhi_epi16(uu01, uu10);
            let intl_vv_lo = _mm_unpacklo_epi16(vv01, vv10);
            let intl_vv_hi = _mm_unpackhi_epi16(vv01, vv10);

            let mut r0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_vv_lo), r_coef);
            let mut r1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_vv_lo), r_coef);
            let mut r2 = _mm_madd_epi16(_mm_unpacklo_epi16(y_hi, intl_vv_hi), r_coef);
            let mut r3 = _mm_madd_epi16(_mm_unpackhi_epi16(y_hi, intl_vv_hi), r_coef);

            r0 = _mm_add_epi32(r0, rnd);
            r1 = _mm_add_epi32(r1, rnd);
            r2 = _mm_add_epi32(r2, rnd);
            r3 = _mm_add_epi32(r3, rnd);

            r0 = _mm_srai_epi32::<Q>(r0);
            r1 = _mm_srai_epi32::<Q>(r1);
            r2 = _mm_srai_epi32::<Q>(r2);
            r3 = _mm_srai_epi32::<Q>(r3);

            let r01 = _mm_packus_epi32(r0, r1);
            let r23 = _mm_packus_epi32(r2, r3);
            let r0123 = _mm_packus_epi16(r01, r23);

            let mut b0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_uu_lo), b_coef);
            let mut b1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_uu_lo), b_coef);
            let mut b2 = _mm_madd_epi16(_mm_unpacklo_epi16(y_hi, intl_uu_hi), b_coef);
            let mut b3 = _mm_madd_epi16(_mm_unpackhi_epi16(y_hi, intl_uu_hi), b_coef);

            b0 = _mm_add_epi32(b0, rnd);
            b1 = _mm_add_epi32(b1, rnd);
            b2 = _mm_add_epi32(b2, rnd);
            b3 = _mm_add_epi32(b3, rnd);

            b0 = _mm_srai_epi32::<Q>(b0);
            b1 = _mm_srai_epi32::<Q>(b1);
            b2 = _mm_srai_epi32::<Q>(b2);
            b3 = _mm_srai_epi32::<Q>(b3);

            let b01 = _mm_packus_epi32(b0, b1);
            let b23 = _mm_packus_epi32(b2, b3);
            let b0123 = _mm_packus_epi16(b01, b23);

            let y_lo0_mul = _mm_mullo_epi16(y_lo, y_coef);
            let y_lo1_mul = _mm_mulhi_epi16(y_lo, y_coef);
            let y_hi0_mul = _mm_mullo_epi16(y_hi, y_coef);
            let y_hi1_mul = _mm_mulhi_epi16(y_hi, y_coef);

            let mut g0 = _mm_madd_epi16(_mm_unpacklo_epi16(intl_vv_lo, intl_uu_lo), g_coef);
            let mut g1 = _mm_madd_epi16(_mm_unpackhi_epi16(intl_vv_lo, intl_uu_lo), g_coef);
            let mut g2 = _mm_madd_epi16(_mm_unpacklo_epi16(intl_vv_hi, intl_uu_hi), g_coef);
            let mut g3 = _mm_madd_epi16(_mm_unpackhi_epi16(intl_vv_hi, intl_uu_hi), g_coef);

            g0 = _mm_add_epi32(g0, _mm_unpacklo_epi16(y_lo0_mul, y_lo1_mul));
            g1 = _mm_add_epi32(g1, _mm_unpackhi_epi16(y_lo0_mul, y_lo1_mul));
            g2 = _mm_add_epi32(g2, _mm_unpacklo_epi16(y_hi0_mul, y_hi1_mul));
            g3 = _mm_add_epi32(g3, _mm_unpackhi_epi16(y_hi0_mul, y_hi1_mul));

            g0 = _mm_add_epi32(g0, rnd);
            g1 = _mm_add_epi32(g1, rnd);
            g2 = _mm_add_epi32(g2, rnd);
            g3 = _mm_add_epi32(g3, rnd);

            g0 = _mm_srai_epi32::<Q>(g0);
            g1 = _mm_srai_epi32::<Q>(g1);
            g2 = _mm_srai_epi32::<Q>(g2);
            g3 = _mm_srai_epi32::<Q>(g3);

            let g01 = _mm_packus_epi32(g0, g1);
            let g23 = _mm_packus_epi32(g2, g3);
            let g0123 = _mm_packus_epi16(g01, g23);

            let dst_shift = x * channels;

            _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr().cast(),
                r0123,
                g0123,
                b0123,
                v_alpha,
            );

            x += 16;
            cx += 8;
        }

        while x + 9 < width as usize {
            let mut y_value = _mm_loadu_si64(y_plane.get_unchecked(x..).as_ptr().cast());

            let u_value_x0_y0 = _mm_loadu_si32(u0_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value_x1_y0 = _mm_loadu_si32(u0_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value_x0_y0 = _mm_loadu_si32(v0_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value_x1_y0 = _mm_loadu_si32(v0_plane.get_unchecked(cx + 1..).as_ptr().cast());

            let u_value_x0_y1 = _mm_loadu_si32(u1_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value_x1_y1 = _mm_loadu_si32(u1_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value_x0_y1 = _mm_loadu_si32(v1_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value_x1_y1 = _mm_loadu_si32(v1_plane.get_unchecked(cx + 1..).as_ptr().cast());

            y_value = _mm_subs_epu8(y_value, y_corr);

            let packed_u0_y0 = _mm_unpacklo_epi8(u_value_x0_y0, u_value_x1_y0);
            let packed_v0_y0 = _mm_unpacklo_epi8(v_value_x0_y0, v_value_x1_y0);
            let packed_u0_y1 = _mm_unpacklo_epi8(u_value_x0_y1, u_value_x1_y1);
            let packed_v0_y1 = _mm_unpacklo_epi8(v_value_x0_y1, v_value_x1_y1);

            let mut uu01 = _mm_maddubs_epi16(packed_u0_y0, inter_row01);
            let mut vv01 = _mm_maddubs_epi16(packed_v0_y0, inter_row01);

            let mut uu10 = _mm_maddubs_epi16(packed_u0_y0, inter_row_far);
            let mut vv10 = _mm_maddubs_epi16(
                _mm_unpacklo_epi8(v_value_x0_y0, v_value_x1_y0),
                inter_row_far,
            );

            let y_lo = _mm_unpacklo_epi8(y_value, _mm_setzero_si128());

            uu01 = _mm_add_epi16(uu01, _mm_maddubs_epi16(packed_u0_y1, inter_row23));
            vv01 = _mm_add_epi16(vv01, _mm_maddubs_epi16(packed_v0_y1, inter_row23));

            uu10 = _mm_add_epi16(uu10, _mm_maddubs_epi16(packed_u0_y1, inter_row32));
            vv10 = _mm_add_epi16(vv10, _mm_maddubs_epi16(packed_v0_y1, inter_row32));

            uu01 = _mm_add_epi16(uu01, inter_rnd);
            vv01 = _mm_add_epi16(vv01, inter_rnd);
            uu10 = _mm_add_epi16(uu10, inter_rnd);
            vv10 = _mm_add_epi16(vv10, inter_rnd);

            uu01 = _mm_srli_epi16::<4>(uu01);
            vv01 = _mm_srli_epi16::<4>(vv01);
            uu10 = _mm_srli_epi16::<4>(uu10);
            vv10 = _mm_srli_epi16::<4>(vv10);

            uu01 = _mm_sub_epi16(uu01, uv_corr);
            vv01 = _mm_sub_epi16(vv01, uv_corr);
            uu10 = _mm_sub_epi16(uu10, uv_corr);
            vv10 = _mm_sub_epi16(vv10, uv_corr);

            let intl_uu_lo = _mm_unpacklo_epi16(uu01, uu10);
            let intl_vv_lo = _mm_unpacklo_epi16(vv01, vv10);

            let mut r0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_vv_lo), r_coef);
            let mut r1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_vv_lo), r_coef);

            r0 = _mm_add_epi32(r0, rnd);
            r1 = _mm_add_epi32(r1, rnd);

            r0 = _mm_srai_epi32::<Q>(r0);
            r1 = _mm_srai_epi32::<Q>(r1);

            let r01 = _mm_packus_epi32(r0, r1);
            let r0123 = _mm_packus_epi16(r01, _mm_setzero_si128());

            let mut b0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_uu_lo), b_coef);
            let mut b1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_uu_lo), b_coef);

            b0 = _mm_add_epi32(b0, rnd);
            b1 = _mm_add_epi32(b1, rnd);

            b0 = _mm_srai_epi32::<Q>(b0);
            b1 = _mm_srai_epi32::<Q>(b1);

            let b01 = _mm_packus_epi32(b0, b1);
            let b0123 = _mm_packus_epi16(b01, _mm_setzero_si128());

            let y_lo0_mul = _mm_mullo_epi16(y_lo, y_coef);
            let y_lo1_mul = _mm_mulhi_epi16(y_lo, y_coef);

            let mut g0 = _mm_madd_epi16(_mm_unpacklo_epi16(intl_vv_lo, intl_uu_lo), g_coef);
            let mut g1 = _mm_madd_epi16(_mm_unpackhi_epi16(intl_vv_lo, intl_uu_lo), g_coef);

            g0 = _mm_add_epi32(g0, _mm_unpacklo_epi16(y_lo0_mul, y_lo1_mul));
            g1 = _mm_add_epi32(g1, _mm_unpackhi_epi16(y_lo0_mul, y_lo1_mul));

            g0 = _mm_add_epi32(g0, rnd);
            g1 = _mm_add_epi32(g1, rnd);

            g0 = _mm_srai_epi32::<Q>(g0);
            g1 = _mm_srai_epi32::<Q>(g1);

            let g01 = _mm_packus_epi32(g0, g1);
            let g0123 = _mm_packus_epi16(g01, _mm_setzero_si128());

            let dst_shift = x * channels;

            _mm_store_interleave_half_rgb_for_yuv::<DESTINATION_CHANNELS>(
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr().cast(),
                r0123,
                g0123,
                b0123,
                v_alpha,
            );

            x += 8;
            cx += 4;
        }

        if x < width as usize {
            let mut y_store: [u8; 17] = [0; 17];
            let mut u0_store: [u8; 17] = [0; 17];
            let mut u1_store: [u8; 17] = [0; 17];
            let mut v0_store: [u8; 17] = [0; 17];
            let mut v1_store: [u8; 17] = [0; 17];
            let mut rgba_store: [u8; 16 * 4] = [0; 16 * 4];

            let diff = width as usize - x;
            assert!(diff <= 16);

            std::ptr::copy_nonoverlapping(
                y_plane.get_unchecked(x..).as_ptr(),
                y_store.as_mut_ptr().cast(),
                diff,
            );

            let ux_diff = diff.div_ceil(2);

            std::ptr::copy_nonoverlapping(
                u0_plane.get_unchecked(cx..).as_ptr(),
                u0_store.as_mut_ptr().cast(),
                ux_diff,
            );

            std::ptr::copy_nonoverlapping(
                u1_plane.get_unchecked(cx..).as_ptr(),
                u1_store.as_mut_ptr().cast(),
                ux_diff,
            );

            u0_store[ux_diff] = *u0_plane.last().unwrap();
            u1_store[ux_diff] = *u1_plane.last().unwrap();

            std::ptr::copy_nonoverlapping(
                v0_plane.get_unchecked(cx..).as_ptr(),
                v0_store.as_mut_ptr().cast(),
                ux_diff,
            );

            std::ptr::copy_nonoverlapping(
                v1_plane.get_unchecked(cx..).as_ptr(),
                v1_store.as_mut_ptr().cast(),
                ux_diff,
            );

            v0_store[ux_diff] = *v0_plane.last().unwrap();
            v1_store[ux_diff] = *v1_plane.last().unwrap();

            let mut y_value = _mm_loadu_si128(y_store.as_ptr().cast());

            let u_value_x0_y0 = _mm_loadu_si64(u0_store.as_ptr().cast());
            let u_value_x1_y0 = _mm_loadu_si64(u0_store.get_unchecked(1..).as_ptr().cast());
            let v_value_x0_y0 = _mm_loadu_si64(v0_store.as_ptr().cast());
            let v_value_x1_y0 = _mm_loadu_si64(v0_store.get_unchecked(1..).as_ptr().cast());

            let u_value_x0_y1 = _mm_loadu_si64(u1_store.as_ptr().cast());
            let u_value_x1_y1 = _mm_loadu_si64(u1_store.get_unchecked(1..).as_ptr().cast());
            let v_value_x0_y1 = _mm_loadu_si64(v1_store.as_ptr().cast());
            let v_value_x1_y1 = _mm_loadu_si64(v1_store.get_unchecked(1..).as_ptr().cast());

            y_value = _mm_subs_epu8(y_value, y_corr);

            let packed_u0_y0 = _mm_unpacklo_epi8(u_value_x0_y0, u_value_x1_y0);
            let packed_v0_y0 = _mm_unpacklo_epi8(v_value_x0_y0, v_value_x1_y0);
            let packed_u0_y1 = _mm_unpacklo_epi8(u_value_x0_y1, u_value_x1_y1);
            let packed_v0_y1 = _mm_unpacklo_epi8(v_value_x0_y1, v_value_x1_y1);

            let mut uu01 = _mm_maddubs_epi16(packed_u0_y0, inter_row01);
            let mut vv01 = _mm_maddubs_epi16(packed_v0_y0, inter_row01);

            let mut uu10 = _mm_maddubs_epi16(packed_u0_y0, inter_row_far);
            let mut vv10 = _mm_maddubs_epi16(
                _mm_unpacklo_epi8(v_value_x0_y0, v_value_x1_y0),
                inter_row_far,
            );

            let y_lo = _mm_unpacklo_epi8(y_value, _mm_setzero_si128());
            let y_hi = _mm_unpackhi_epi8(y_value, _mm_setzero_si128());

            uu01 = _mm_add_epi16(uu01, _mm_maddubs_epi16(packed_u0_y1, inter_row23));
            vv01 = _mm_add_epi16(vv01, _mm_maddubs_epi16(packed_v0_y1, inter_row23));

            uu10 = _mm_add_epi16(uu10, _mm_maddubs_epi16(packed_u0_y1, inter_row32));
            vv10 = _mm_add_epi16(vv10, _mm_maddubs_epi16(packed_v0_y1, inter_row32));

            uu01 = _mm_add_epi16(uu01, inter_rnd);
            vv01 = _mm_add_epi16(vv01, inter_rnd);
            uu10 = _mm_add_epi16(uu10, inter_rnd);
            vv10 = _mm_add_epi16(vv10, inter_rnd);

            uu01 = _mm_srli_epi16::<4>(uu01);
            vv01 = _mm_srli_epi16::<4>(vv01);
            uu10 = _mm_srli_epi16::<4>(uu10);
            vv10 = _mm_srli_epi16::<4>(vv10);

            uu01 = _mm_sub_epi16(uu01, uv_corr);
            vv01 = _mm_sub_epi16(vv01, uv_corr);
            uu10 = _mm_sub_epi16(uu10, uv_corr);
            vv10 = _mm_sub_epi16(vv10, uv_corr);

            let intl_uu_lo = _mm_unpacklo_epi16(uu01, uu10);
            let intl_uu_hi = _mm_unpackhi_epi16(uu01, uu10);
            let intl_vv_lo = _mm_unpacklo_epi16(vv01, vv10);
            let intl_vv_hi = _mm_unpackhi_epi16(vv01, vv10);

            let mut r0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_vv_lo), r_coef);
            let mut r1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_vv_lo), r_coef);
            let mut r2 = _mm_madd_epi16(_mm_unpacklo_epi16(y_hi, intl_vv_hi), r_coef);
            let mut r3 = _mm_madd_epi16(_mm_unpackhi_epi16(y_hi, intl_vv_hi), r_coef);

            r0 = _mm_add_epi32(r0, rnd);
            r1 = _mm_add_epi32(r1, rnd);
            r2 = _mm_add_epi32(r2, rnd);
            r3 = _mm_add_epi32(r3, rnd);

            r0 = _mm_srai_epi32::<Q>(r0);
            r1 = _mm_srai_epi32::<Q>(r1);
            r2 = _mm_srai_epi32::<Q>(r2);
            r3 = _mm_srai_epi32::<Q>(r3);

            let r01 = _mm_packus_epi32(r0, r1);
            let r23 = _mm_packus_epi32(r2, r3);
            let r0123 = _mm_packus_epi16(r01, r23);

            let mut b0 = _mm_madd_epi16(_mm_unpacklo_epi16(y_lo, intl_uu_lo), b_coef);
            let mut b1 = _mm_madd_epi16(_mm_unpackhi_epi16(y_lo, intl_uu_lo), b_coef);
            let mut b2 = _mm_madd_epi16(_mm_unpacklo_epi16(y_hi, intl_uu_hi), b_coef);
            let mut b3 = _mm_madd_epi16(_mm_unpackhi_epi16(y_hi, intl_uu_hi), b_coef);

            b0 = _mm_add_epi32(b0, rnd);
            b1 = _mm_add_epi32(b1, rnd);
            b2 = _mm_add_epi32(b2, rnd);
            b3 = _mm_add_epi32(b3, rnd);

            b0 = _mm_srai_epi32::<Q>(b0);
            b1 = _mm_srai_epi32::<Q>(b1);
            b2 = _mm_srai_epi32::<Q>(b2);
            b3 = _mm_srai_epi32::<Q>(b3);

            let b01 = _mm_packus_epi32(b0, b1);
            let b23 = _mm_packus_epi32(b2, b3);
            let b0123 = _mm_packus_epi16(b01, b23);

            let y_lo0_mul = _mm_mullo_epi16(y_lo, y_coef);
            let y_lo1_mul = _mm_mulhi_epi16(y_lo, y_coef);
            let y_hi0_mul = _mm_mullo_epi16(y_hi, y_coef);
            let y_hi1_mul = _mm_mulhi_epi16(y_hi, y_coef);

            let mut g0 = _mm_madd_epi16(_mm_unpacklo_epi16(intl_vv_lo, intl_uu_lo), g_coef);
            let mut g1 = _mm_madd_epi16(_mm_unpackhi_epi16(intl_vv_lo, intl_uu_lo), g_coef);
            let mut g2 = _mm_madd_epi16(_mm_unpacklo_epi16(intl_vv_hi, intl_uu_hi), g_coef);
            let mut g3 = _mm_madd_epi16(_mm_unpackhi_epi16(intl_vv_hi, intl_uu_hi), g_coef);

            g0 = _mm_add_epi32(g0, _mm_unpacklo_epi16(y_lo0_mul, y_lo1_mul));
            g1 = _mm_add_epi32(g1, _mm_unpackhi_epi16(y_lo0_mul, y_lo1_mul));
            g2 = _mm_add_epi32(g2, _mm_unpacklo_epi16(y_hi0_mul, y_hi1_mul));
            g3 = _mm_add_epi32(g3, _mm_unpackhi_epi16(y_hi0_mul, y_hi1_mul));

            g0 = _mm_add_epi32(g0, rnd);
            g1 = _mm_add_epi32(g1, rnd);
            g2 = _mm_add_epi32(g2, rnd);
            g3 = _mm_add_epi32(g3, rnd);

            g0 = _mm_srai_epi32::<Q>(g0);
            g1 = _mm_srai_epi32::<Q>(g1);
            g2 = _mm_srai_epi32::<Q>(g2);
            g3 = _mm_srai_epi32::<Q>(g3);

            let g01 = _mm_packus_epi32(g0, g1);
            let g23 = _mm_packus_epi32(g2, g3);
            let g0123 = _mm_packus_epi16(g01, g23);

            _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
                rgba_store.as_mut_ptr().cast(),
                r0123,
                g0123,
                b0123,
                v_alpha,
            );

            let dst_shift = x * channels;

            std::ptr::copy_nonoverlapping(
                rgba_store.as_ptr().cast(),
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
                diff * channels,
            );
        }
    }
}
