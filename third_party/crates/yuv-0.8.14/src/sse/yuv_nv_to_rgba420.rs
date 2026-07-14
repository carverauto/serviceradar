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

use crate::internals::ProcessedOffset;
use crate::sse::{
    _mm_deinterleave_x2_epi8, _mm_expand8_hi_to_10, _mm_expand8_lo_to_10,
    _mm_store_interleave_half_rgb_for_yuv, _mm_store_interleave_rgb_for_yuv,
};
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvNVOrder, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is an exceptional path for doubled row with 4:2:0 subsampling only.
pub(crate) fn sse_yuv_nv_to_rgba420<const UV_ORDER: u8, const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane0: &[u8],
    y_plane1: &[u8],
    uv_plane: &[u8],
    rgba0: &mut [u8],
    rgba1: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    unsafe {
        sse_yuv_nv_to_rgba_impl420::<UV_ORDER, DESTINATION_CHANNELS>(
            range, transform, y_plane0, y_plane1, uv_plane, rgba0, rgba1, start_cx, start_ux, width,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_yuv_nv_to_rgba_impl420<const UV_ORDER: u8, const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane0: &[u8],
    y_plane1: &[u8],
    uv_plane: &[u8],
    rgba0: &mut [u8],
    rgba1: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let order: YuvNVOrder = UV_ORDER.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    let uv_ptr = uv_plane.as_ptr();

    let y_corr = _mm_set1_epi8(range.bias_y as i8);
    let uv_corr = _mm_set1_epi16(((range.bias_uv as i16) << 2) | ((range.bias_uv as i16) >> 6));
    let v_luma_coeff = _mm_set1_epi16(transform.y_coef as i16);
    let v_cr_coeff = _mm_set1_epi16(transform.cr_coef as i16);
    let v_cb_coeff = _mm_set1_epi16(transform.cb_coef as i16);
    let v_g_coeff_1 = _mm_set1_epi16(transform.g_coeff_1 as i16);
    let v_g_coeff_2 = _mm_set1_epi16(transform.g_coeff_2 as i16);

    let zeros = _mm_setzero_si128();

    let distribute_shuffle = _mm_setr_epi8(0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7);

    while cx + 16 < width {
        let y_vl0 = _mm_loadu_si128(y_plane0.get_unchecked(cx..).as_ptr() as *const __m128i);
        let y_vl1 = _mm_loadu_si128(y_plane1.get_unchecked(cx..).as_ptr() as *const __m128i);
        let uv_values_ = _mm_loadu_si128(uv_ptr.add(uv_x) as *const __m128i);
        let y_values0 = _mm_subs_epu8(y_vl0, y_corr);
        let y_values1 = _mm_subs_epu8(y_vl1, y_corr);

        let sh_e = _mm_setr_epi8(0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14);
        let sh_o = _mm_setr_epi8(1, 1, 3, 3, 5, 5, 7, 7, 9, 9, 11, 11, 13, 13, 15, 15);

        let mut u = _mm_shuffle_epi8(uv_values_, sh_e);
        let mut v = _mm_shuffle_epi8(uv_values_, sh_o);

        u = _mm_srli_epi16::<6>(u);
        v = _mm_srli_epi16::<6>(v);

        u = _mm_sub_epi16(u, uv_corr);
        v = _mm_sub_epi16(v, uv_corr);

        if order == YuvNVOrder::VU {
            std::mem::swap(&mut u, &mut v);
        }

        let v_u = _mm_mulhrs_epi16(u, v_cb_coeff);
        let v_v = _mm_mulhrs_epi16(v, v_cr_coeff);

        let v_g = _mm_add_epi16(
            _mm_mulhrs_epi16(v, v_g_coeff_1),
            _mm_mulhrs_epi16(u, v_g_coeff_2),
        );

        let (v_u_l, v_u_h) = (_mm_unpacklo_epi16(v_u, v_u), _mm_unpackhi_epi16(v_u, v_u));

        let (v_v_l, v_v_h) = (_mm_unpacklo_epi16(v_v, v_v), _mm_unpackhi_epi16(v_v, v_v));

        let (v_g_l, v_g_h) = (_mm_unpacklo_epi16(v_g, v_g), _mm_unpackhi_epi16(v_g, v_g));

        let y_high0 = _mm_mulhrs_epi16(_mm_expand8_hi_to_10(y_values0), v_luma_coeff);
        let y_high1 = _mm_mulhrs_epi16(_mm_expand8_hi_to_10(y_values1), v_luma_coeff);

        let r_high0 = _mm_add_epi16(y_high0, v_v_h);
        let b_high0 = _mm_add_epi16(y_high0, v_u_h);
        let g_high0 = _mm_sub_epi16(y_high0, v_g_h);

        let r_high1 = _mm_add_epi16(y_high1, v_v_h);
        let b_high1 = _mm_add_epi16(y_high1, v_u_h);
        let g_high1 = _mm_sub_epi16(y_high1, v_g_h);

        let y_low0 = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values0), v_luma_coeff);
        let y_low1 = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values1), v_luma_coeff);

        let r_low0 = _mm_add_epi16(y_low0, v_v_l);
        let b_low0 = _mm_add_epi16(y_low0, v_u_l);
        let g_low0 = _mm_sub_epi16(y_low0, v_g_l);

        let r_low1 = _mm_add_epi16(y_low1, v_v_l);
        let b_low1 = _mm_add_epi16(y_low1, v_u_l);
        let g_low1 = _mm_sub_epi16(y_low1, v_g_l);

        let r_values0 = _mm_packus_epi16(r_low0, r_high0);
        let g_values0 = _mm_packus_epi16(g_low0, g_high0);
        let b_values0 = _mm_packus_epi16(b_low0, b_high0);

        let r_values1 = _mm_packus_epi16(r_low1, r_high1);
        let g_values1 = _mm_packus_epi16(g_low1, g_high1);
        let b_values1 = _mm_packus_epi16(b_low1, b_high1);

        let dst_shift = cx * channels;

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );
        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values1,
            g_values1,
            b_values1,
            v_alpha,
        );

        cx += 16;
        uv_x += 16;
    }

    while cx + 8 < width {
        let y_vl0 = _mm_loadu_si64(y_plane0.get_unchecked(cx..).as_ptr());
        let y_vl1 = _mm_loadu_si64(y_plane1.get_unchecked(cx..).as_ptr());

        let (u_low_u16, v_low_u16);

        let uv_values_ = _mm_loadu_si64(uv_ptr.add(uv_x));

        let y_values0 = _mm_subs_epi8(y_vl0, y_corr);
        let y_values1 = _mm_subs_epi8(y_vl1, y_corr);
        let (mut u, mut v) = _mm_deinterleave_x2_epi8(uv_values_, zeros);

        if order == YuvNVOrder::VU {
            std::mem::swap(&mut u, &mut v);
        }

        u = _mm_shuffle_epi8(u, distribute_shuffle);
        v = _mm_shuffle_epi8(v, distribute_shuffle);

        u = _mm_unpacklo_epi8(u, u);
        v = _mm_unpacklo_epi8(v, v);

        u_low_u16 = _mm_srli_epi16::<6>(u);
        v_low_u16 = _mm_srli_epi16::<6>(v);

        let u_low = _mm_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm_sub_epi16(v_low_u16, uv_corr);
        let y_low0 = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values0), v_luma_coeff);
        let y_low1 = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values1), v_luma_coeff);

        let g_coeff_lo = _mm_add_epi16(
            _mm_mulhrs_epi16(v_low, v_g_coeff_1),
            _mm_mulhrs_epi16(u_low, v_g_coeff_2),
        );

        let v_cr_lo = _mm_mulhrs_epi16(v_low, v_cr_coeff);
        let v_cb_lo = _mm_mulhrs_epi16(u_low, v_cr_coeff);

        let r_low0 = _mm_add_epi16(y_low0, v_cr_lo);
        let b_low0 = _mm_add_epi16(y_low0, v_cb_lo);
        let g_low0 = _mm_sub_epi16(y_low0, g_coeff_lo);

        let r_low1 = _mm_add_epi16(y_low1, v_cr_lo);
        let b_low1 = _mm_add_epi16(y_low1, v_cb_lo);
        let g_low1 = _mm_sub_epi16(y_low1, g_coeff_lo);

        let r_values0 = _mm_packus_epi16(r_low0, zeros);
        let g_values0 = _mm_packus_epi16(g_low0, zeros);
        let b_values0 = _mm_packus_epi16(b_low0, zeros);

        let r_values1 = _mm_packus_epi16(r_low1, zeros);
        let g_values1 = _mm_packus_epi16(g_low1, zeros);
        let b_values1 = _mm_packus_epi16(b_low1, zeros);

        let dst_shift = cx * channels;
        let dst_ptr0 = rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr();
        let dst_ptr1 = rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr();

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_half_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_ptr0, r_values0, g_values0, b_values0, v_alpha,
        );
        _mm_store_interleave_half_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_ptr1, r_values1, g_values1, b_values1, v_alpha,
        );

        cx += 8;
        uv_x += 8;
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 8);

        let mut dst_buffer0: [u8; 8 * 4] = [0; 8 * 4];
        let mut dst_buffer1: [u8; 8 * 4] = [0; 8 * 4];
        let mut y_buffer0: [u8; 8] = [0; 8];
        let mut y_buffer1: [u8; 8] = [0; 8];
        let mut uv_buffer: [u8; 8 * 2] = [0; 8 * 2];

        std::ptr::copy_nonoverlapping(
            y_plane0.get_unchecked(cx..).as_ptr(),
            y_buffer0.as_mut_ptr().cast(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            y_plane1.get_unchecked(cx..).as_ptr(),
            y_buffer1.as_mut_ptr().cast(),
            diff,
        );

        let hv = diff.div_ceil(2) * 2;

        std::ptr::copy_nonoverlapping(
            uv_plane.get_unchecked(uv_x..).as_ptr(),
            uv_buffer.as_mut_ptr().cast(),
            hv,
        );

        let y_vl0 = _mm_loadu_si64(y_buffer0.as_ptr().cast());
        let y_vl1 = _mm_loadu_si64(y_buffer1.as_ptr().cast());

        let (u_low_u16, v_low_u16);

        let uv_values_ = _mm_loadu_si64(uv_buffer.as_ptr().cast());

        let y_values0 = _mm_subs_epi8(y_vl0, y_corr);
        let y_values1 = _mm_subs_epi8(y_vl1, y_corr);
        let (mut u, mut v) = _mm_deinterleave_x2_epi8(uv_values_, zeros);

        if order == YuvNVOrder::VU {
            std::mem::swap(&mut u, &mut v);
        }

        u = _mm_shuffle_epi8(u, distribute_shuffle);
        v = _mm_shuffle_epi8(v, distribute_shuffle);

        u = _mm_unpacklo_epi8(u, u);
        v = _mm_unpacklo_epi8(v, v);

        u_low_u16 = _mm_srli_epi16::<6>(u);
        v_low_u16 = _mm_srli_epi16::<6>(v);

        let u_low = _mm_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm_sub_epi16(v_low_u16, uv_corr);
        let y_low0 = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values0), v_luma_coeff);
        let y_low1 = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values1), v_luma_coeff);

        let g_coeff_lo = _mm_add_epi16(
            _mm_mulhrs_epi16(v_low, v_g_coeff_1),
            _mm_mulhrs_epi16(u_low, v_g_coeff_2),
        );

        let v_cr_lo = _mm_mulhrs_epi16(v_low, v_cr_coeff);
        let v_cb_lo = _mm_mulhrs_epi16(u_low, v_cr_coeff);

        let r_low0 = _mm_add_epi16(y_low0, v_cr_lo);
        let b_low0 = _mm_add_epi16(y_low0, v_cb_lo);
        let g_low0 = _mm_sub_epi16(y_low0, g_coeff_lo);

        let r_low1 = _mm_add_epi16(y_low1, v_cr_lo);
        let b_low1 = _mm_add_epi16(y_low1, v_cb_lo);
        let g_low1 = _mm_sub_epi16(y_low1, g_coeff_lo);

        let r_values0 = _mm_packus_epi16(r_low0, zeros);
        let g_values0 = _mm_packus_epi16(g_low0, zeros);
        let b_values0 = _mm_packus_epi16(b_low0, zeros);

        let r_values1 = _mm_packus_epi16(r_low1, zeros);
        let g_values1 = _mm_packus_epi16(g_low1, zeros);
        let b_values1 = _mm_packus_epi16(b_low1, zeros);

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_half_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer0.as_mut_ptr().cast(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );
        _mm_store_interleave_half_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer1.as_mut_ptr().cast(),
            r_values1,
            g_values1,
            b_values1,
            v_alpha,
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer0.as_ptr().cast(),
            rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        std::ptr::copy_nonoverlapping(
            dst_buffer1.as_ptr().cast(),
            rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        uv_x += hv;
    }

    ProcessedOffset { cx, ux: uv_x }
}
