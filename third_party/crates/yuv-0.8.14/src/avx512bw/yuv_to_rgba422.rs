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

use crate::avx512bw::avx512_utils::{
    _mm512_expand8_unordered_to_10, avx512_store_rgba_for_yuv_u8, avx512_zip_u_epi16,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is special path for halved chroma Row to reuse variables instead of computing them
pub(crate) fn avx512_yuv_to_rgba422<const DESTINATION_CHANNELS: u8, const HAS_VBMI: bool>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    unsafe {
        if HAS_VBMI {
            avx512_yuv_to_rgba_bmi_impl422::<DESTINATION_CHANNELS>(
                range, transform, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
            )
        } else {
            avx512_yuv_to_rgba_def_impl422::<DESTINATION_CHANNELS>(
                range, transform, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
            )
        }
    }
}

#[target_feature(enable = "avx512bw", enable = "avx512f", enable = "avx512vbmi")]
unsafe fn avx512_yuv_to_rgba_bmi_impl422<const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    avx512_yuv_to_rgba_impl422::<DESTINATION_CHANNELS, true>(
        range, transform, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512f")]
unsafe fn avx512_yuv_to_rgba_def_impl422<const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    avx512_yuv_to_rgba_impl422::<DESTINATION_CHANNELS, false>(
        range, transform, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
    )
}

#[inline(always)]
unsafe fn avx512_yuv_to_rgba_impl422<const DESTINATION_CHANNELS: u8, const HAS_VBMI: bool>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;
    let y_ptr = y_plane.as_ptr();
    let u_ptr = u_plane.as_ptr();
    let v_ptr = v_plane.as_ptr();
    let rgba_ptr = rgba.as_mut_ptr();

    let y_corr = _mm512_set1_epi8(range.bias_y as i8);
    let uv_corr = _mm512_set1_epi16(((range.bias_uv as i16) << 2) | ((range.bias_uv as i16) >> 6));
    let v_luma_coeff = _mm512_set1_epi16(transform.y_coef as i16);
    let v_cr_coeff = _mm512_set1_epi16(transform.cr_coef as i16);
    let v_cb_coeff = _mm512_set1_epi16(transform.cb_coef as i16);
    let v_g_coeff_1 = _mm512_set1_epi16(transform.g_coeff_1 as i16);
    let v_g_coeff_2 = _mm512_set1_epi16(transform.g_coeff_2 as i16);

    let uv_mask = _mm512_setr_epi64(0, 0, 1, 0, 2, 0, 3, 0);

    while cx + 64 < width {
        let y_vl0 = _mm512_loadu_si512(y_ptr.add(cx) as *const _);

        let u_values = _mm256_loadu_si256(u_ptr.add(uv_x) as *const __m256i);
        let v_values = _mm256_loadu_si256(v_ptr.add(uv_x) as *const __m256i);

        let y_values = _mm512_subs_epu8(y_vl0, y_corr);

        let mut lu = _mm512_permutexvar_epi64(uv_mask, _mm512_castsi256_si512(u_values));
        let mut lv = _mm512_permutexvar_epi64(uv_mask, _mm512_castsi256_si512(v_values));

        lu = _mm512_unpacklo_epi8(lu, lu);
        lv = _mm512_unpacklo_epi8(lv, lv);

        lu = _mm512_srli_epi16::<6>(lu);
        lv = _mm512_srli_epi16::<6>(lv);

        lu = _mm512_sub_epi16(lu, uv_corr);
        lv = _mm512_sub_epi16(lv, uv_corr);

        let v_cr_c = _mm512_mulhrs_epi16(lv, v_cr_coeff);
        let v_cb_c = _mm512_mulhrs_epi16(lu, v_cb_coeff);

        let l_gc0 = _mm512_mulhrs_epi16(lv, v_g_coeff_1);
        let l_gc1 = _mm512_mulhrs_epi16(lu, v_g_coeff_2);

        let (u_l, u_h) = avx512_zip_u_epi16(v_cb_c, v_cb_c);
        let (v_l, v_h) = avx512_zip_u_epi16(v_cr_c, v_cr_c);

        let l_g = _mm512_add_epi16(l_gc0, l_gc1);

        let (g_l, g_h) = avx512_zip_u_epi16(l_g, l_g);

        let y_10 = _mm512_expand8_unordered_to_10(y_values);

        let y_high = _mm512_mulhrs_epi16(y_10.1, v_luma_coeff);

        let r_high = _mm512_add_epi16(y_high, v_h);
        let b_high = _mm512_add_epi16(y_high, u_h);
        let g_high = _mm512_sub_epi16(y_high, g_h);

        let y_low = _mm512_mulhrs_epi16(y_10.0, v_luma_coeff);

        let r_low = _mm512_add_epi16(y_low, v_l);
        let b_low = _mm512_add_epi16(y_low, u_l);
        let g_low = _mm512_sub_epi16(y_low, g_l);

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
        uv_x += 32;
    }

    ProcessedOffset { cx, ux: uv_x }
}
