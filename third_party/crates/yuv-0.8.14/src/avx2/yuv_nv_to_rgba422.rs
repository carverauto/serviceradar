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

use crate::avx2::avx2_utils::*;
use crate::internals::ProcessedOffset;
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvNVOrder, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is an exceptional path for row 4:2:0 and 4:2:2 only.
pub(crate) fn avx2_yuv_nv_to_rgba_row422<const UV_ORDER: u8, const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    uv_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    unsafe {
        avx2_yuv_nv_to_rgba_row_impl422::<UV_ORDER, DESTINATION_CHANNELS>(
            range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
        )
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx2_yuv_nv_to_rgba_row_impl422<const UV_ORDER: u8, const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    uv_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let order: YuvNVOrder = UV_ORDER.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;
    let y_ptr = y_plane.as_ptr();
    let uv_ptr = uv_plane.as_ptr();
    let rgba_ptr = rgba.as_mut_ptr();

    let y_corr = _mm256_set1_epi8(range.bias_y as i8);
    let uv_corr = _mm256_set1_epi16(((range.bias_uv as i16) << 2) | ((range.bias_uv as i16) >> 6));
    let v_luma_coeff = _mm256_set1_epi16(transform.y_coef as i16);
    let v_cr_coeff = _mm256_set1_epi16(transform.cr_coef as i16);
    let v_cb_coeff = _mm256_set1_epi16(transform.cb_coef as i16);
    let v_g_coeff_1 = _mm256_set1_epi16(transform.g_coeff_1 as i16);
    let v_g_coeff_2 = _mm256_set1_epi16(transform.g_coeff_2 as i16);

    while cx + 32 <= width {
        let yvl0 = _mm256_loadu_si256(y_ptr.add(cx) as *const __m256i);
        let uv_values = _mm256_loadu_si256(uv_ptr.add(uv_x) as *const __m256i);

        let y_values = _mm256_subs_epu8(yvl0, y_corr);

        let sh_e = _mm256_setr_epi8(
            0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14, 0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10,
            10, 12, 12, 14, 14,
        );
        let sh_o = _mm256_setr_epi8(
            1, 1, 3, 3, 5, 5, 7, 7, 9, 9, 11, 11, 13, 13, 15, 15, 1, 1, 3, 3, 5, 5, 7, 7, 9, 9, 11,
            11, 13, 13, 15, 15,
        );

        let mut u_values = _mm256_sub_epi16(
            _mm256_srli_epi16::<6>(_mm256_shuffle_epi8(uv_values, sh_e)),
            uv_corr,
        );
        let mut v_values = _mm256_sub_epi16(
            _mm256_srli_epi16::<6>(_mm256_shuffle_epi8(uv_values, sh_o)),
            uv_corr,
        );

        if order == YuvNVOrder::VU {
            std::mem::swap(&mut u_values, &mut v_values);
        }

        let v_u = _mm256_mulhrs_epi16(u_values, v_cb_coeff);
        let v_v = _mm256_mulhrs_epi16(v_values, v_cr_coeff);
        let v_g = _mm256_add_epi16(
            _mm256_mulhrs_epi16(v_values, v_g_coeff_1),
            _mm256_mulhrs_epi16(u_values, v_g_coeff_2),
        );

        let (v_u_l, v_u_h) = (
            _mm256_unpacklo_epi16(v_u, v_u),
            _mm256_unpackhi_epi16(v_u, v_u),
        );

        let (v_v_l, v_v_h) = (
            _mm256_unpacklo_epi16(v_v, v_v),
            _mm256_unpackhi_epi16(v_v, v_v),
        );

        let (v_g_l, v_g_h) = (
            _mm256_unpacklo_epi16(v_g, v_g),
            _mm256_unpackhi_epi16(v_g, v_g),
        );

        let y10 = _mm256_expand8_unordered_to_10(y_values);

        let y_high = _mm256_mulhrs_epi16(y10.1, v_luma_coeff);

        let r_high = _mm256_add_epi16(y_high, v_v_h);
        let b_high = _mm256_add_epi16(y_high, v_u_h);
        let g_high = _mm256_sub_epi16(y_high, v_g_h);

        let y_low = _mm256_mulhrs_epi16(y10.0, v_luma_coeff);

        let r_low = _mm256_add_epi16(y_low, v_v_l);
        let b_low = _mm256_add_epi16(y_low, v_u_l);
        let g_low = _mm256_sub_epi16(y_low, v_g_l);

        let r_values = _mm256_packus_epi16(r_low, r_high);
        let g_values = _mm256_packus_epi16(g_low, g_high);
        let b_values = _mm256_packus_epi16(b_low, b_high);

        let dst_shift = cx * channels;

        let v_alpha = _mm256_set1_epi8(255u8 as i8);

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 32;
        uv_x += 32;
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 32);

        let mut dst_buffer: [u8; 32 * 4] = [0; 32 * 4];
        let mut y_buffer0: [u8; 32] = [0; 32];
        let mut uv_buffer: [u8; 32 * 2] = [0; 32 * 2];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer0.as_mut_ptr().cast(),
            diff,
        );

        let hv = diff.div_ceil(2) * 2;

        std::ptr::copy_nonoverlapping(
            uv_plane.get_unchecked(uv_x..).as_ptr(),
            uv_buffer.as_mut_ptr().cast(),
            hv,
        );

        let yvl0 = _mm256_loadu_si256(y_buffer0.as_ptr() as *const __m256i);
        let uv_values = _mm256_loadu_si256(uv_buffer.as_ptr() as *const __m256i);

        let y_values = _mm256_subs_epu8(yvl0, y_corr);

        let sh_e = _mm256_setr_epi8(
            0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14, 0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10,
            10, 12, 12, 14, 14,
        );
        let sh_o = _mm256_setr_epi8(
            1, 1, 3, 3, 5, 5, 7, 7, 9, 9, 11, 11, 13, 13, 15, 15, 1, 1, 3, 3, 5, 5, 7, 7, 9, 9, 11,
            11, 13, 13, 15, 15,
        );

        let mut u_values = _mm256_sub_epi16(
            _mm256_srli_epi16::<6>(_mm256_shuffle_epi8(uv_values, sh_e)),
            uv_corr,
        );
        let mut v_values = _mm256_sub_epi16(
            _mm256_srli_epi16::<6>(_mm256_shuffle_epi8(uv_values, sh_o)),
            uv_corr,
        );

        if order == YuvNVOrder::VU {
            std::mem::swap(&mut u_values, &mut v_values);
        }

        let v_u = _mm256_mulhrs_epi16(u_values, v_cb_coeff);
        let v_v = _mm256_mulhrs_epi16(v_values, v_cr_coeff);
        let v_g = _mm256_add_epi16(
            _mm256_mulhrs_epi16(v_values, v_g_coeff_1),
            _mm256_mulhrs_epi16(u_values, v_g_coeff_2),
        );

        let (v_u_l, v_u_h) = (
            _mm256_unpacklo_epi16(v_u, v_u),
            _mm256_unpackhi_epi16(v_u, v_u),
        );

        let (v_v_l, v_v_h) = (
            _mm256_unpacklo_epi16(v_v, v_v),
            _mm256_unpackhi_epi16(v_v, v_v),
        );

        let (v_g_l, v_g_h) = (
            _mm256_unpacklo_epi16(v_g, v_g),
            _mm256_unpackhi_epi16(v_g, v_g),
        );

        let y10 = _mm256_expand8_unordered_to_10(y_values);

        let y_high = _mm256_mulhrs_epi16(y10.1, v_luma_coeff);

        let r_high = _mm256_add_epi16(y_high, v_v_h);
        let b_high = _mm256_add_epi16(y_high, v_u_h);
        let g_high = _mm256_sub_epi16(y_high, v_g_h);

        let y_low = _mm256_mulhrs_epi16(y10.0, v_luma_coeff);

        let r_low = _mm256_add_epi16(y_low, v_v_l);
        let b_low = _mm256_add_epi16(y_low, v_u_l);
        let g_low = _mm256_sub_epi16(y_low, v_g_l);

        let r_values = _mm256_packus_epi16(r_low, r_high);
        let g_values = _mm256_packus_epi16(g_low, g_high);
        let b_values = _mm256_packus_epi16(b_low, b_high);

        let v_alpha = _mm256_set1_epi8(255u8 as i8);

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr().cast(),
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        uv_x += hv;
    }

    ProcessedOffset { cx, ux: uv_x }
}
