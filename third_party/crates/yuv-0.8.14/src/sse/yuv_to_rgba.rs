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
    _mm_expand8_hi_to_10, _mm_expand8_lo_to_10, _mm_store_interleave_half_rgb_for_yuv,
    _mm_store_interleave_rgb_for_yuv, _xx_load_si64,
};
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_yuv_to_rgba_row<const DESTINATION_CHANNELS: u8, const SAMPLING: u8>(
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
        sse_yuv_to_rgba_row_impl::<DESTINATION_CHANNELS, SAMPLING>(
            range, transform, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_yuv_to_rgba_row_impl<const DESTINATION_CHANNELS: u8, const SAMPLING: u8>(
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
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    let y_ptr = y_plane.as_ptr();
    let u_ptr = u_plane.as_ptr();
    let v_ptr = v_plane.as_ptr();
    let rgba_ptr = rgba.as_mut_ptr();

    let y_corr = _mm_set1_epi8(range.bias_y as i8);
    let uv_corr = _mm_set1_epi16(((range.bias_uv as i16) << 2) | ((range.bias_uv as i16) >> 6));
    let v_luma_coeff = _mm_set1_epi16(transform.y_coef as i16);
    let v_cr_coeff = _mm_set1_epi16(transform.cr_coef as i16);
    let v_cb_coeff = _mm_set1_epi16(transform.cb_coef as i16);
    let v_g_coeff_1 = _mm_set1_epi16(transform.g_coeff_1 as i16);
    let v_g_coeff_2 = _mm_set1_epi16(transform.g_coeff_2 as i16);

    let zeros = _mm_setzero_si128();

    while cx + 16 < width {
        let y_values = _mm_subs_epu8(_mm_loadu_si128(y_ptr.add(cx) as *const __m128i), y_corr);

        let (u_high_u16, v_high_u16, u_low_u16, v_low_u16);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let reshuffle = _mm_setr_epi8(0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7);
                let u_values = _mm_shuffle_epi8(_xx_load_si64(u_ptr.add(uv_x)), reshuffle);
                let v_values = _mm_shuffle_epi8(_xx_load_si64(v_ptr.add(uv_x)), reshuffle);

                u_high_u16 = _mm_srli_epi16::<6>(_mm_unpackhi_epi8(u_values, u_values));
                v_high_u16 = _mm_srli_epi16::<6>(_mm_unpackhi_epi8(v_values, v_values));
                u_low_u16 = _mm_srli_epi16::<6>(_mm_unpacklo_epi8(u_values, u_values));
                v_low_u16 = _mm_srli_epi16::<6>(_mm_unpacklo_epi8(v_values, v_values));
            }
            YuvChromaSubsampling::Yuv444 => {
                let u_values = _mm_loadu_si128(u_ptr.add(uv_x) as *const __m128i);
                let v_values = _mm_loadu_si128(v_ptr.add(uv_x) as *const __m128i);

                u_high_u16 = _mm_srli_epi16::<6>(_mm_unpackhi_epi8(u_values, u_values));
                v_high_u16 = _mm_srli_epi16::<6>(_mm_unpackhi_epi8(v_values, v_values));
                u_low_u16 = _mm_srli_epi16::<6>(_mm_unpacklo_epi8(u_values, u_values));
                v_low_u16 = _mm_srli_epi16::<6>(_mm_unpacklo_epi8(v_values, v_values));
            }
        }

        let u_high = _mm_sub_epi16(u_high_u16, uv_corr);
        let v_high = _mm_sub_epi16(v_high_u16, uv_corr);
        let y_high = _mm_mulhrs_epi16(_mm_expand8_hi_to_10(y_values), v_luma_coeff);

        let r_high = _mm_add_epi16(y_high, _mm_mulhrs_epi16(v_high, v_cr_coeff));
        let b_high = _mm_add_epi16(y_high, _mm_mulhrs_epi16(u_high, v_cb_coeff));
        let g_high = _mm_sub_epi16(
            y_high,
            _mm_add_epi16(
                _mm_mulhrs_epi16(v_high, v_g_coeff_1),
                _mm_mulhrs_epi16(u_high, v_g_coeff_2),
            ),
        );

        let u_low = _mm_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm_sub_epi16(v_low_u16, uv_corr);
        let y_low = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values), v_luma_coeff);

        let r_low = _mm_add_epi16(y_low, _mm_mulhrs_epi16(v_low, v_cr_coeff));
        let b_low = _mm_add_epi16(y_low, _mm_mulhrs_epi16(u_low, v_cb_coeff));
        let g_low = _mm_sub_epi16(
            y_low,
            _mm_add_epi16(
                _mm_mulhrs_epi16(v_low, v_g_coeff_1),
                _mm_mulhrs_epi16(u_low, v_g_coeff_2),
            ),
        );

        let r_values = _mm_packus_epi16(r_low, r_high);
        let g_values = _mm_packus_epi16(g_low, g_high);
        let b_values = _mm_packus_epi16(b_low, b_high);

        let dst_shift = cx * channels;

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 16;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                uv_x += 8;
            }
            YuvChromaSubsampling::Yuv444 => {
                uv_x += 16;
            }
        }
    }

    while cx + 8 < width {
        let y_values = _mm_subs_epi8(_xx_load_si64(y_ptr.add(cx)), y_corr);

        let (u_low_u16, v_low_u16);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let reshuffle = _mm_setr_epi8(0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7);
                let u_values = _mm_shuffle_epi8(_mm_loadu_si32(u_ptr.add(uv_x)), reshuffle);
                let v_values = _mm_shuffle_epi8(_mm_loadu_si32(v_ptr.add(uv_x)), reshuffle);

                u_low_u16 = _mm_srli_epi16::<6>(_mm_unpacklo_epi8(u_values, u_values));
                v_low_u16 = _mm_srli_epi16::<6>(_mm_unpacklo_epi8(v_values, v_values));
            }
            YuvChromaSubsampling::Yuv444 => {
                let u_values = _xx_load_si64(u_ptr.add(uv_x));
                let v_values = _xx_load_si64(v_ptr.add(uv_x));

                u_low_u16 = _mm_srli_epi16::<6>(_mm_unpacklo_epi8(u_values, u_values));
                v_low_u16 = _mm_srli_epi16::<6>(_mm_unpacklo_epi8(v_values, v_values));
            }
        }

        let u_low = _mm_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm_sub_epi16(v_low_u16, uv_corr);
        let y_low = _mm_mulhrs_epi16(_mm_expand8_lo_to_10(y_values), v_luma_coeff);

        let r_low = _mm_add_epi16(y_low, _mm_mulhrs_epi16(v_low, v_cr_coeff));
        let b_low = _mm_add_epi16(y_low, _mm_mulhrs_epi16(u_low, v_cb_coeff));
        let g_low = _mm_sub_epi16(
            y_low,
            _mm_add_epi16(
                _mm_mulhrs_epi16(v_low, v_g_coeff_1),
                _mm_mulhrs_epi16(u_low, v_g_coeff_2),
            ),
        );

        let r_values = _mm_packus_epi16(r_low, zeros);
        let g_values = _mm_packus_epi16(g_low, zeros);
        let b_values = _mm_packus_epi16(b_low, zeros);

        let dst_shift = cx * channels;

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_half_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 8;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                uv_x += 4;
            }
            YuvChromaSubsampling::Yuv444 => {
                uv_x += 8;
            }
        }
    }

    ProcessedOffset { cx, ux: uv_x }
}
