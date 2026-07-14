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
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx2_yuv_to_rgba_alpha<const DESTINATION_CHANNELS: u8, const SAMPLING: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    a_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
    use_premultiply: bool,
) -> ProcessedOffset {
    unsafe {
        avx2_yuv_to_rgba_alpha_impl::<DESTINATION_CHANNELS, SAMPLING>(
            range,
            transform,
            y_plane,
            u_plane,
            v_plane,
            a_plane,
            rgba,
            start_cx,
            start_ux,
            width,
            use_premultiply,
        )
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx2_yuv_to_rgba_alpha_impl<const DESTINATION_CHANNELS: u8, const SAMPLING: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    a_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
    use_premultiply: bool,
) -> ProcessedOffset {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;
    let y_ptr = y_plane.as_ptr();
    let u_ptr = u_plane.as_ptr();
    let v_ptr = v_plane.as_ptr();
    let a_ptr = a_plane.as_ptr();
    let rgba_ptr = rgba.as_mut_ptr();

    let y_corr = _mm256_set1_epi8(range.bias_y as i8);
    let uv_corr = _mm256_set1_epi16(((range.bias_uv as i16) << 2) | ((range.bias_uv as i16) >> 6));
    let v_luma_coeff = _mm256_set1_epi16(transform.y_coef as i16);
    let v_cr_coeff = _mm256_set1_epi16(transform.cr_coef as i16);
    let v_cb_coeff = _mm256_set1_epi16(transform.cb_coef as i16);
    let v_g_coeff_1 = _mm256_set1_epi16(transform.g_coeff_1 as i16);
    let v_g_coeff_2 = _mm256_set1_epi16(transform.g_coeff_2 as i16);

    while cx + 32 <= width {
        let y_values =
            _mm256_subs_epu8(_mm256_loadu_si256(y_ptr.add(cx) as *const __m256i), y_corr);

        let a_values = _mm256_loadu_si256(a_ptr.add(cx) as *const __m256i);

        let (u_high_u16, v_high_u16, u_low_u16, v_low_u16);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let u_values = _mm_loadu_si128(u_ptr.add(uv_x) as *const __m128i);
                let v_values = _mm_loadu_si128(v_ptr.add(uv_x) as *const __m128i);

                let u_vl = _mm256_set_m128i(
                    _mm_unpackhi_epi8(u_values, u_values),
                    _mm_unpacklo_epi8(u_values, u_values),
                );
                let v_vl = _mm256_set_m128i(
                    _mm_unpackhi_epi8(v_values, v_values),
                    _mm_unpacklo_epi8(v_values, v_values),
                );

                u_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(u_vl, u_vl));
                v_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(v_vl, v_vl));
                u_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(u_vl, u_vl));
                v_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(v_vl, v_vl));
            }
            YuvChromaSubsampling::Yuv444 => {
                let u_values = _mm256_loadu_si256(u_ptr.add(uv_x) as *const __m256i);
                let v_values = _mm256_loadu_si256(v_ptr.add(uv_x) as *const __m256i);

                u_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(u_values, u_values));
                v_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(v_values, v_values));
                u_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(u_values, u_values));
                v_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(v_values, v_values));
            }
        }

        let y0_10 = _mm256_expand8_unordered_to_10(y_values);

        let u_high = _mm256_sub_epi16(u_high_u16, uv_corr);
        let v_high = _mm256_sub_epi16(v_high_u16, uv_corr);
        let y_high = _mm256_mulhrs_epi16(y0_10.1, v_luma_coeff);

        let rhc = _mm256_mulhrs_epi16(v_high, v_cr_coeff);
        let bhc = _mm256_mulhrs_epi16(u_high, v_cb_coeff);
        let ghc0 = _mm256_mulhrs_epi16(v_high, v_g_coeff_1);
        let ghc1 = _mm256_mulhrs_epi16(u_high, v_g_coeff_2);

        let r_high = _mm256_add_epi16(y_high, rhc);
        let b_high = _mm256_add_epi16(y_high, bhc);
        let g_high = _mm256_sub_epi16(y_high, _mm256_add_epi16(ghc0, ghc1));

        let u_low = _mm256_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm256_sub_epi16(v_low_u16, uv_corr);
        let y_low = _mm256_mulhrs_epi16(y0_10.0, v_luma_coeff);

        let rlc = _mm256_mulhrs_epi16(v_low, v_cr_coeff);
        let blc = _mm256_mulhrs_epi16(u_low, v_cb_coeff);
        let glc0 = _mm256_mulhrs_epi16(v_low, v_g_coeff_1);
        let glc1 = _mm256_mulhrs_epi16(u_low, v_g_coeff_2);

        let r_low = _mm256_add_epi16(y_low, rlc);
        let b_low = _mm256_add_epi16(y_low, blc);
        let g_low = _mm256_sub_epi16(y_low, _mm256_add_epi16(glc0, glc1));

        let mut r_values = _mm256_packus_epi16(r_low, r_high);
        let mut g_values = _mm256_packus_epi16(g_low, g_high);
        let mut b_values = _mm256_packus_epi16(b_low, b_high);

        if use_premultiply {
            let r_low = _mm256_unpacklo_epi8(r_values, _mm256_setzero_si256());
            let r_high = _mm256_unpackhi_epi8(r_values, _mm256_setzero_si256());
            let g_low = _mm256_unpacklo_epi8(g_values, _mm256_setzero_si256());
            let g_high = _mm256_unpackhi_epi8(g_values, _mm256_setzero_si256());
            let b_low = _mm256_unpacklo_epi8(b_values, _mm256_setzero_si256());
            let b_high = _mm256_unpackhi_epi8(b_values, _mm256_setzero_si256());

            let a_high = _mm256_unpackhi_epi8(a_values, _mm256_setzero_si256());
            let a_low = _mm256_unpacklo_epi8(a_values, _mm256_setzero_si256());

            let (r_l, r_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(r_low, a_low),
                _mm256_mullo_epi16(r_high, a_high),
            );
            let (g_l, g_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(g_low, a_low),
                _mm256_mullo_epi16(g_high, a_high),
            );
            let (b_l, b_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(b_low, a_low),
                _mm256_mullo_epi16(b_high, a_high),
            );

            r_values = _mm256_packus_epi16(r_l, r_h);
            g_values = _mm256_packus_epi16(g_l, g_h);
            b_values = _mm256_packus_epi16(b_l, b_h);
        } else {
            r_values = _mm256_packus_epi16(r_low, r_high);
            g_values = _mm256_packus_epi16(g_low, g_high);
            b_values = _mm256_packus_epi16(b_low, b_high);
        }

        let dst_shift = cx * channels;

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            a_values,
        );

        cx += 32;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                uv_x += 16;
            }
            YuvChromaSubsampling::Yuv444 => {
                uv_x += 32;
            }
        }
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 32);

        let mut dst_buffer: [u8; 32 * 4] = [0; 32 * 4];
        let mut y_buffer: [u8; 32] = [0; 32];
        let mut u_buffer: [u8; 32] = [0; 32];
        let mut v_buffer: [u8; 32] = [0; 32];
        let mut a_buffer: [u8; 32] = [0; 32];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr().cast(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            a_plane.get_unchecked(cx..).as_ptr(),
            a_buffer.as_mut_ptr().cast(),
            diff,
        );

        let ux_diff = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2),
            YuvChromaSubsampling::Yuv444 => diff,
        };

        std::ptr::copy_nonoverlapping(
            u_plane.get_unchecked(uv_x..).as_ptr(),
            u_buffer.as_mut_ptr().cast(),
            ux_diff,
        );

        std::ptr::copy_nonoverlapping(
            v_plane.get_unchecked(uv_x..).as_ptr(),
            v_buffer.as_mut_ptr().cast(),
            ux_diff,
        );

        let y_values = _mm256_subs_epu8(
            _mm256_loadu_si256(y_buffer.as_ptr() as *const __m256i),
            y_corr,
        );

        let a_values = _mm256_loadu_si256(a_buffer.as_ptr() as *const __m256i);

        let (u_high_u16, v_high_u16, u_low_u16, v_low_u16);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let u_values = _mm_loadu_si128(u_buffer.as_ptr() as *const __m128i);
                let v_values = _mm_loadu_si128(v_buffer.as_ptr() as *const __m128i);

                let u_vl = _mm256_set_m128i(
                    _mm_unpackhi_epi8(u_values, u_values),
                    _mm_unpacklo_epi8(u_values, u_values),
                );
                let v_vl = _mm256_set_m128i(
                    _mm_unpackhi_epi8(v_values, v_values),
                    _mm_unpacklo_epi8(v_values, v_values),
                );

                u_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(u_vl, u_vl));
                v_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(v_vl, v_vl));
                u_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(u_vl, u_vl));
                v_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(v_vl, v_vl));
            }
            YuvChromaSubsampling::Yuv444 => {
                let u_values = _mm256_loadu_si256(u_buffer.as_ptr() as *const __m256i);
                let v_values = _mm256_loadu_si256(v_buffer.as_ptr() as *const __m256i);

                u_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(u_values, u_values));
                v_high_u16 = _mm256_srli_epi16::<6>(_mm256_unpackhi_epi8(v_values, v_values));
                u_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(u_values, u_values));
                v_low_u16 = _mm256_srli_epi16::<6>(_mm256_unpacklo_epi8(v_values, v_values));
            }
        }

        let y0_10 = _mm256_expand8_unordered_to_10(y_values);

        let u_high = _mm256_sub_epi16(u_high_u16, uv_corr);
        let v_high = _mm256_sub_epi16(v_high_u16, uv_corr);
        let y_high = _mm256_mulhrs_epi16(y0_10.1, v_luma_coeff);

        let rhc = _mm256_mulhrs_epi16(v_high, v_cr_coeff);
        let bhc = _mm256_mulhrs_epi16(u_high, v_cb_coeff);
        let ghc0 = _mm256_mulhrs_epi16(v_high, v_g_coeff_1);
        let ghc1 = _mm256_mulhrs_epi16(u_high, v_g_coeff_2);

        let mut r_high = _mm256_add_epi16(y_high, rhc);
        let mut b_high = _mm256_add_epi16(y_high, bhc);
        let mut g_high = _mm256_sub_epi16(y_high, _mm256_add_epi16(ghc0, ghc1));

        let u_low = _mm256_sub_epi16(u_low_u16, uv_corr);
        let v_low = _mm256_sub_epi16(v_low_u16, uv_corr);
        let y_low = _mm256_mulhrs_epi16(y0_10.0, v_luma_coeff);

        let rlc = _mm256_mulhrs_epi16(v_low, v_cr_coeff);
        let blc = _mm256_mulhrs_epi16(u_low, v_cb_coeff);
        let glc0 = _mm256_mulhrs_epi16(v_low, v_g_coeff_1);
        let glc1 = _mm256_mulhrs_epi16(u_low, v_g_coeff_2);

        let mut r_low = _mm256_add_epi16(y_low, rlc);
        let mut b_low = _mm256_add_epi16(y_low, blc);
        let mut g_low = _mm256_sub_epi16(y_low, _mm256_add_epi16(glc0, glc1));

        let (r_values, g_values, b_values);

        if use_premultiply {
            r_high = _mm256_max_epi16(r_high, _mm256_setzero_si256());
            b_high = _mm256_max_epi16(b_high, _mm256_setzero_si256());
            g_high = _mm256_max_epi16(g_high, _mm256_setzero_si256());

            r_low = _mm256_max_epi16(r_low, _mm256_setzero_si256());
            b_low = _mm256_max_epi16(b_low, _mm256_setzero_si256());
            g_low = _mm256_max_epi16(g_low, _mm256_setzero_si256());

            let a_high = _mm256_unpackhi_epi8(a_values, _mm256_setzero_si256());
            let a_low = _mm256_unpacklo_epi8(a_values, _mm256_setzero_si256());

            let (r_l, r_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(r_low, a_low),
                _mm256_mullo_epi16(r_high, a_high),
            );
            let (g_l, g_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(g_low, a_low),
                _mm256_mullo_epi16(g_high, a_high),
            );
            let (b_l, b_h) = avx2_div_by255_x2(
                _mm256_mullo_epi16(b_low, a_low),
                _mm256_mullo_epi16(b_high, a_high),
            );

            r_values = _mm256_packus_epi16(r_l, r_h);
            g_values = _mm256_packus_epi16(g_l, g_h);
            b_values = _mm256_packus_epi16(b_l, b_h);
        } else {
            r_values = _mm256_packus_epi16(r_low, r_high);
            g_values = _mm256_packus_epi16(g_low, g_high);
            b_values = _mm256_packus_epi16(b_low, b_high);
        }

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            a_values,
        );

        let dst_shift = cx * channels;
        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr().cast(),
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        uv_x += ux_diff;
    }

    ProcessedOffset { cx, ux: uv_x }
}
