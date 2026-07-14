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
    _mm512_expand8_unordered_to_10, avx512_store_rgba_for_yuv_u8, avx512_unzip_epi8,
    avx512_zip_epi8,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvNVOrder, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx512_yuv_nv_to_rgba<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
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
            avx512_yuv_nv_to_rgba_bmi_impl::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING>(
                range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
            )
        } else {
            avx512_yuv_nv_to_rgba_def_impl::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING>(
                range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
            )
        }
    }
}

#[target_feature(enable = "avx512bw", enable = "avx512f", enable = "avx512vbmi")]
unsafe fn avx512_yuv_nv_to_rgba_bmi_impl<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
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
    avx512_yuv_nv_to_rgba_impl::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, true>(
        range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512f")]
unsafe fn avx512_yuv_nv_to_rgba_def_impl<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
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
    avx512_yuv_nv_to_rgba_impl::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING, false>(
        range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
    )
}

#[inline(always)]
unsafe fn avx512_yuv_nv_to_rgba_impl<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
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
    let chroma_subsampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();
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

    while cx + 64 < width {
        let y_vl0 = _mm512_loadu_si512(y_ptr.add(cx) as *const _);

        let (u_high_u8, v_high_u8, u_low_u8, v_low_u8);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let uv_values = _mm512_loadu_si512(uv_ptr.add(uv_x) as *const _);

                let (u_values0, v_values0) =
                    avx512_unzip_epi8::<HAS_VBMI>(uv_values, _mm512_setzero_si512());

                let (mut u_values, _) = avx512_zip_epi8::<HAS_VBMI>(u_values0, u_values0);
                let (mut v_values, _) = avx512_zip_epi8::<HAS_VBMI>(v_values0, v_values0);

                if order == YuvNVOrder::VU {
                    std::mem::swap(&mut u_values, &mut v_values);
                }

                let uh = _mm512_unpackhi_epi8(u_values, u_values);
                let vh = _mm512_unpackhi_epi8(v_values, v_values);
                let ul = _mm512_unpacklo_epi8(u_values, u_values);
                let vl = _mm512_unpacklo_epi8(v_values, v_values);

                u_high_u8 = _mm512_srli_epi16::<6>(uh);
                v_high_u8 = _mm512_srli_epi16::<6>(vh);
                u_low_u8 = _mm512_srli_epi16::<6>(ul);
                v_low_u8 = _mm512_srli_epi16::<6>(vl);
            }
            YuvChromaSubsampling::Yuv444 => {
                let offset = uv_x;
                let v_str = uv_ptr.add(offset);
                let uv_values_l = _mm512_loadu_si512(v_str as *const _);
                let uv_values_h = _mm512_loadu_si512(v_str.add(64) as *const _);

                let (mut u_values, mut v_values) =
                    avx512_unzip_epi8::<HAS_VBMI>(uv_values_l, uv_values_h);
                if order == YuvNVOrder::VU {
                    std::mem::swap(&mut u_values, &mut v_values);
                }

                let uh = _mm512_unpackhi_epi8(u_values, u_values);
                let vh = _mm512_unpackhi_epi8(v_values, v_values);
                let ul = _mm512_unpacklo_epi8(u_values, u_values);
                let vl = _mm512_unpacklo_epi8(v_values, v_values);

                u_high_u8 = _mm512_srli_epi16::<6>(uh);
                v_high_u8 = _mm512_srli_epi16::<6>(vh);
                u_low_u8 = _mm512_srli_epi16::<6>(ul);
                v_low_u8 = _mm512_srli_epi16::<6>(vl);
            }
        }

        let y_values = _mm512_subs_epu8(y_vl0, y_corr);

        let y10 = _mm512_expand8_unordered_to_10(y_values);

        let u_high = _mm512_sub_epi16(u_high_u8, uv_corr);
        let v_high = _mm512_sub_epi16(v_high_u8, uv_corr);
        let y_high = _mm512_mulhrs_epi16(y10.1, v_luma_coeff);

        let r_hc = _mm512_mulhrs_epi16(v_high, v_cr_coeff);
        let b_hc = _mm512_mulhrs_epi16(u_high, v_cb_coeff);
        let g_h0 = _mm512_mulhrs_epi16(v_high, v_g_coeff_1);
        let g_h1 = _mm512_mulhrs_epi16(u_high, v_g_coeff_2);

        let r_high = _mm512_add_epi16(y_high, r_hc);
        let b_high = _mm512_add_epi16(y_high, b_hc);
        let g_high = _mm512_sub_epi16(y_high, _mm512_add_epi16(g_h0, g_h1));

        let u_low = _mm512_sub_epi16(u_low_u8, uv_corr);
        let v_low = _mm512_sub_epi16(v_low_u8, uv_corr);
        let y_low = _mm512_mulhrs_epi16(y10.0, v_luma_coeff);
        let r_lc = _mm512_mulhrs_epi16(v_low, v_cr_coeff);
        let b_lc = _mm512_mulhrs_epi16(u_low, v_cb_coeff);
        let g_lc0 = _mm512_mulhrs_epi16(v_low, v_g_coeff_1);
        let g_lc1 = _mm512_mulhrs_epi16(u_low, v_g_coeff_2);

        let r_low = _mm512_add_epi16(y_low, r_lc);
        let b_low = _mm512_add_epi16(y_low, b_lc);
        let g_low = _mm512_sub_epi16(y_low, _mm512_add_epi16(g_lc0, g_lc1));

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

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                uv_x += 64;
            }
            YuvChromaSubsampling::Yuv444 => {
                uv_x += 128;
            }
        }
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 64);

        let mut dst_buffer: [u8; 64 * 4] = [0; 64 * 4];
        let mut y_buffer: [u8; 64] = [0; 64];
        let mut uv_buffer: [u8; 64 * 2] = [0; 64 * 2];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr(),
            diff,
        );

        let hv = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2) * 2,
            YuvChromaSubsampling::Yuv444 => diff * 2,
        };

        std::ptr::copy_nonoverlapping(
            uv_plane.get_unchecked(uv_x..).as_ptr(),
            uv_buffer.as_mut_ptr(),
            hv,
        );

        let y_vl0 = _mm512_loadu_si512(y_buffer.as_ptr() as *const _);

        let (u_high_u8, v_high_u8, u_low_u8, v_low_u8);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let uv_values = _mm512_loadu_si512(uv_buffer.as_ptr() as *const _);

                let (u_values0, v_values0) =
                    avx512_unzip_epi8::<HAS_VBMI>(uv_values, _mm512_setzero_si512());

                let (mut u_values, _) = avx512_zip_epi8::<HAS_VBMI>(u_values0, u_values0);
                let (mut v_values, _) = avx512_zip_epi8::<HAS_VBMI>(v_values0, v_values0);

                if order == YuvNVOrder::VU {
                    std::mem::swap(&mut u_values, &mut v_values);
                }

                let uh = _mm512_unpackhi_epi8(u_values, u_values);
                let vh = _mm512_unpackhi_epi8(v_values, v_values);
                let ul = _mm512_unpacklo_epi8(u_values, u_values);
                let vl = _mm512_unpacklo_epi8(v_values, v_values);

                u_high_u8 = _mm512_srli_epi16::<6>(uh);
                v_high_u8 = _mm512_srli_epi16::<6>(vh);
                u_low_u8 = _mm512_srli_epi16::<6>(ul);
                v_low_u8 = _mm512_srli_epi16::<6>(vl);
            }
            YuvChromaSubsampling::Yuv444 => {
                let uv_values_l = _mm512_loadu_si512(uv_buffer.as_ptr() as *const _);
                let uv_values_h = _mm512_loadu_si512(uv_buffer.as_ptr().add(64) as *const _);

                let (mut u_values, mut v_values) =
                    avx512_unzip_epi8::<HAS_VBMI>(uv_values_l, uv_values_h);
                if order == YuvNVOrder::VU {
                    std::mem::swap(&mut u_values, &mut v_values);
                }

                let uh = _mm512_unpackhi_epi8(u_values, u_values);
                let vh = _mm512_unpackhi_epi8(v_values, v_values);
                let ul = _mm512_unpacklo_epi8(u_values, u_values);
                let vl = _mm512_unpacklo_epi8(v_values, v_values);

                u_high_u8 = _mm512_srli_epi16::<6>(uh);
                v_high_u8 = _mm512_srli_epi16::<6>(vh);
                u_low_u8 = _mm512_srli_epi16::<6>(ul);
                v_low_u8 = _mm512_srli_epi16::<6>(vl);
            }
        }

        let y_values = _mm512_subs_epu8(y_vl0, y_corr);

        let y10 = _mm512_expand8_unordered_to_10(y_values);

        let u_high = _mm512_sub_epi16(u_high_u8, uv_corr);
        let v_high = _mm512_sub_epi16(v_high_u8, uv_corr);
        let y_high = _mm512_mulhrs_epi16(y10.1, v_luma_coeff);

        let r_hc = _mm512_mulhrs_epi16(v_high, v_cr_coeff);
        let b_hc = _mm512_mulhrs_epi16(u_high, v_cb_coeff);
        let g_h0 = _mm512_mulhrs_epi16(v_high, v_g_coeff_1);
        let g_h1 = _mm512_mulhrs_epi16(u_high, v_g_coeff_2);

        let r_high = _mm512_add_epi16(y_high, r_hc);
        let b_high = _mm512_add_epi16(y_high, b_hc);
        let g_high = _mm512_sub_epi16(y_high, _mm512_add_epi16(g_h0, g_h1));

        let u_low = _mm512_sub_epi16(u_low_u8, uv_corr);
        let v_low = _mm512_sub_epi16(v_low_u8, uv_corr);
        let y_low = _mm512_mulhrs_epi16(y10.0, v_luma_coeff);
        let r_lc = _mm512_mulhrs_epi16(v_low, v_cr_coeff);
        let b_lc = _mm512_mulhrs_epi16(u_low, v_cb_coeff);
        let g_lc0 = _mm512_mulhrs_epi16(v_low, v_g_coeff_1);
        let g_lc1 = _mm512_mulhrs_epi16(u_low, v_g_coeff_2);

        let r_low = _mm512_add_epi16(y_low, r_lc);
        let b_low = _mm512_add_epi16(y_low, b_lc);
        let g_low = _mm512_sub_epi16(y_low, _mm512_add_epi16(g_lc0, g_lc1));

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
