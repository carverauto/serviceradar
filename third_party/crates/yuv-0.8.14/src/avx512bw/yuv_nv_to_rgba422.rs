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

use crate::avx512bw::avx512_setr::_v512_setr_epu8;
use crate::avx512bw::avx512_utils::{_mm512_expand8_unordered_to_10, avx512_store_rgba_for_yuv_u8};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvNVOrder, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is special path for a row of 4:2:2 to reuse variables instead of computing them
pub(crate) fn avx512_yuv_nv_to_rgba422<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const HAS_VBMI: bool,
>(
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
        if HAS_VBMI {
            avx512_yuv_nv_to_rgba_bmi_impl422::<UV_ORDER, DESTINATION_CHANNELS>(
                range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
            )
        } else {
            avx512_yuv_nv_to_rgba_def_impl422::<UV_ORDER, DESTINATION_CHANNELS>(
                range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
            )
        }
    }
}

#[target_feature(enable = "avx512bw", enable = "avx512f", enable = "avx512vbmi")]
unsafe fn avx512_yuv_nv_to_rgba_bmi_impl422<const UV_ORDER: u8, const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    uv_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    avx512_yuv_nv_to_rgba_impl422::<UV_ORDER, DESTINATION_CHANNELS, true>(
        range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512f")]
unsafe fn avx512_yuv_nv_to_rgba_def_impl422<const UV_ORDER: u8, const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    uv_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    avx512_yuv_nv_to_rgba_impl422::<UV_ORDER, DESTINATION_CHANNELS, false>(
        range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
    )
}

#[inline(always)]
unsafe fn avx512_yuv_nv_to_rgba_impl422<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const HAS_VBMI: bool,
>(
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

    let y_corr = _mm512_set1_epi8(range.bias_y as i8);
    let uv_corr = _mm512_set1_epi16(((range.bias_uv as i16) << 2) | ((range.bias_uv as i16) >> 6));
    let v_luma_coeff = _mm512_set1_epi16(transform.y_coef as i16);
    let v_cr_coeff = _mm512_set1_epi16(transform.cr_coef as i16);
    let v_cb_coeff = _mm512_set1_epi16(transform.cb_coef as i16);
    let v_g_coeff_1 = _mm512_set1_epi16(transform.g_coeff_1 as i16);
    let v_g_coeff_2 = _mm512_set1_epi16(transform.g_coeff_2 as i16);

    let sh_e = _v512_setr_epu8(
        0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14, 16, 16, 18, 18, 20, 20, 22, 22, 24,
        24, 26, 26, 28, 28, 30, 30, 32, 32, 34, 34, 36, 36, 38, 38, 40, 40, 42, 42, 44, 44, 46, 46,
        48, 48, 50, 50, 52, 52, 54, 54, 56, 56, 58, 58, 60, 60, 62, 62,
    );
    let sh_o = _v512_setr_epu8(
        1, 1, 3, 3, 5, 5, 7, 7, 9, 9, 11, 11, 13, 13, 15, 15, 17, 17, 19, 19, 21, 21, 23, 23, 25,
        25, 27, 27, 29, 29, 31, 31, 33, 33, 35, 35, 37, 37, 39, 39, 41, 41, 43, 43, 45, 45, 47, 47,
        49, 49, 51, 51, 53, 53, 55, 55, 57, 57, 59, 59, 61, 61, 63, 63,
    );

    while cx + 64 < width {
        let y_vl0 = _mm512_loadu_si512(y_ptr.add(cx) as *const _);
        let uv_values = _mm512_loadu_si512(uv_ptr.add(uv_x) as *const _);

        let y_values = _mm512_subs_epu8(y_vl0, y_corr);

        let sh_uu = _mm512_shuffle_epi8(uv_values, sh_e);
        let sh_vv = _mm512_shuffle_epi8(uv_values, sh_o);

        let ss_uu = _mm512_srli_epi16::<6>(sh_uu);
        let ss_vv = _mm512_srli_epi16::<6>(sh_vv);

        let mut u_values = _mm512_sub_epi16(ss_uu, uv_corr);
        let mut v_values = _mm512_sub_epi16(ss_vv, uv_corr);

        if order == YuvNVOrder::VU {
            std::mem::swap(&mut u_values, &mut v_values);
        }

        let g_c0 = _mm512_mulhrs_epi16(v_values, v_g_coeff_1);
        let g_c1 = _mm512_mulhrs_epi16(u_values, v_g_coeff_2);
        let v_u = _mm512_mulhrs_epi16(u_values, v_cb_coeff);
        let v_v = _mm512_mulhrs_epi16(v_values, v_cr_coeff);
        let v_g = _mm512_add_epi16(g_c0, g_c1);

        let (v_u_l, v_u_h) = (
            _mm512_unpacklo_epi16(v_u, v_u),
            _mm512_unpackhi_epi16(v_u, v_u),
        );

        let (v_v_l, v_v_h) = (
            _mm512_unpacklo_epi16(v_v, v_v),
            _mm512_unpackhi_epi16(v_v, v_v),
        );

        let (v_g_l, v_g_h) = (
            _mm512_unpacklo_epi16(v_g, v_g),
            _mm512_unpackhi_epi16(v_g, v_g),
        );

        let y10 = _mm512_expand8_unordered_to_10(y_values);

        let y_high = _mm512_mulhrs_epi16(y10.1, v_luma_coeff);

        let r_high = _mm512_add_epi16(y_high, v_v_h);
        let b_high = _mm512_add_epi16(y_high, v_u_h);
        let g_high = _mm512_sub_epi16(y_high, v_g_h);

        let y_low = _mm512_mulhrs_epi16(y10.0, v_luma_coeff);

        let r_low = _mm512_add_epi16(y_low, v_v_l);
        let b_low = _mm512_add_epi16(y_low, v_u_l);
        let g_low = _mm512_sub_epi16(y_low, v_g_l);

        let r_values = _mm512_packus_epi16(r_low, r_high);
        let g_values = _mm512_packus_epi16(g_low, g_high);
        let b_values = _mm512_packus_epi16(b_low, b_high);

        let dst_shift = cx * channels;

        let v_alpha = _mm512_set1_epi8(255u8 as i8);

        avx512_store_rgba_for_yuv_u8::<DESTINATION_CHANNELS, HAS_VBMI>(
            rgba_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 64;
        uv_x += 64;
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 64);

        let mut dst_buffer: [u8; 64 * 4] = [0; 64 * 4];
        let mut y_buffer0: [u8; 64] = [0; 64];
        let mut uv_buffer: [u8; 64 * 2] = [0; 64 * 2];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer0.as_mut_ptr(),
            diff,
        );

        let hv = diff.div_ceil(2) * 2;

        std::ptr::copy_nonoverlapping(
            uv_plane.get_unchecked(uv_x..).as_ptr(),
            uv_buffer.as_mut_ptr(),
            hv,
        );

        let y_vl0 = _mm512_loadu_si512(y_buffer0.as_ptr() as *const _);
        let uv_values = _mm512_loadu_si512(uv_buffer.as_ptr() as *const _);

        let y_values = _mm512_subs_epu8(y_vl0, y_corr);

        let sh_uu = _mm512_shuffle_epi8(uv_values, sh_e);
        let sh_vv = _mm512_shuffle_epi8(uv_values, sh_o);

        let ss_uu = _mm512_srli_epi16::<6>(sh_uu);
        let ss_vv = _mm512_srli_epi16::<6>(sh_vv);

        let mut u_values = _mm512_sub_epi16(ss_uu, uv_corr);
        let mut v_values = _mm512_sub_epi16(ss_vv, uv_corr);

        if order == YuvNVOrder::VU {
            std::mem::swap(&mut u_values, &mut v_values);
        }

        let g_c0 = _mm512_mulhrs_epi16(v_values, v_g_coeff_1);
        let g_c1 = _mm512_mulhrs_epi16(u_values, v_g_coeff_2);
        let v_u = _mm512_mulhrs_epi16(u_values, v_cb_coeff);
        let v_v = _mm512_mulhrs_epi16(v_values, v_cr_coeff);
        let v_g = _mm512_add_epi16(g_c0, g_c1);

        let (v_u_l, v_u_h) = (
            _mm512_unpacklo_epi16(v_u, v_u),
            _mm512_unpackhi_epi16(v_u, v_u),
        );

        let (v_v_l, v_v_h) = (
            _mm512_unpacklo_epi16(v_v, v_v),
            _mm512_unpackhi_epi16(v_v, v_v),
        );

        let (v_g_l, v_g_h) = (
            _mm512_unpacklo_epi16(v_g, v_g),
            _mm512_unpackhi_epi16(v_g, v_g),
        );

        let y10 = _mm512_expand8_unordered_to_10(y_values);

        let y_high = _mm512_mulhrs_epi16(y10.1, v_luma_coeff);

        let r_high = _mm512_add_epi16(y_high, v_v_h);
        let b_high = _mm512_add_epi16(y_high, v_u_h);
        let g_high = _mm512_sub_epi16(y_high, v_g_h);

        let y_low = _mm512_mulhrs_epi16(y10.0, v_luma_coeff);

        let r_low = _mm512_add_epi16(y_low, v_v_l);
        let b_low = _mm512_add_epi16(y_low, v_u_l);
        let g_low = _mm512_sub_epi16(y_low, v_g_l);

        let r_values = _mm512_packus_epi16(r_low, r_high);
        let g_values = _mm512_packus_epi16(g_low, g_high);
        let b_values = _mm512_packus_epi16(b_low, b_high);

        let v_alpha = _mm512_set1_epi8(255u8 as i8);

        avx512_store_rgba_for_yuv_u8::<DESTINATION_CHANNELS, HAS_VBMI>(
            dst_buffer.as_mut_ptr(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer.as_mut_ptr(),
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        uv_x += hv;
    }

    ProcessedOffset { cx, ux: uv_x }
}
