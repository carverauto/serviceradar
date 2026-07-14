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
use crate::sse::_mm_store_interleave_rgb_for_yuv;
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvNVOrder, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is common NV row conversion to RGBx, supports any subsampling
pub(crate) fn sse_yuv_nv_to_rgba_fast<
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
    unsafe {
        sse_yuv_nv_to_rgba_fast_impl::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING>(
            range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_yuv_nv_to_rgba_fast_impl<
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
    let order: YuvNVOrder = UV_ORDER.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let chroma_subsampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    let y_ptr = y_plane.as_ptr();
    let uv_ptr = uv_plane.as_ptr();
    let rgba_ptr = rgba.as_mut_ptr();

    let y_corr = _mm_set1_epi8(range.bias_y as i8);
    let uv_corr = _mm_set1_epi8(range.bias_uv as i8);
    let v_y_c = _mm_set1_epi8(transform.y_coef as i8);
    let v_cr = if order == YuvNVOrder::VU {
        _mm_set1_epi16(transform.cr_coef as i16)
    } else {
        _mm_set1_epi16(((transform.cr_coef as u16) << 8) as i16)
    };
    let v_cb = if order == YuvNVOrder::VU {
        _mm_set1_epi16(((transform.cb_coef as u16) << 8) as i16)
    } else {
        _mm_set1_epi16(transform.cb_coef as i16)
    };
    let v_g_coeffs = if order == YuvNVOrder::VU {
        _mm_set1_epi16((((transform.g_coeff_2 as u16) << 8) | (transform.g_coeff_1 as u16)) as i16)
    } else {
        _mm_set1_epi16((((transform.g_coeff_1 as u16) << 8) | (transform.g_coeff_2 as u16)) as i16)
    };

    while cx + 16 < width {
        let y_vl0 = _mm_loadu_si128(y_ptr.add(cx) as *const __m128i);

        let (g_c_hi, g_c_lo, b_c_hi, b_c_lo, r_c_hi, r_c_lo);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut uv_values_ = _mm_loadu_si128(uv_ptr.add(uv_x) as *const __m128i);

                uv_values_ = _mm_sub_epi8(uv_values_, uv_corr);

                let b_c_values = _mm_maddubs_epi16(v_cb, uv_values_);
                let r_c_values = _mm_maddubs_epi16(v_cr, uv_values_);
                let g_c_values = _mm_maddubs_epi16(v_g_coeffs, uv_values_);

                g_c_hi = _mm_unpackhi_epi16(g_c_values, g_c_values);
                g_c_lo = _mm_unpacklo_epi16(g_c_values, g_c_values);
                b_c_hi = _mm_unpackhi_epi16(b_c_values, b_c_values);
                b_c_lo = _mm_unpacklo_epi16(b_c_values, b_c_values);
                r_c_hi = _mm_unpackhi_epi16(r_c_values, r_c_values);
                r_c_lo = _mm_unpacklo_epi16(r_c_values, r_c_values);
            }
            YuvChromaSubsampling::Yuv444 => {
                let uv_source_ptr = uv_ptr.add(uv_x);
                let mut uv0 = _mm_loadu_si128(uv_source_ptr as *const __m128i);
                let mut uv1 = _mm_loadu_si128(uv_source_ptr.add(16) as *const __m128i);
                uv0 = _mm_sub_epi8(uv0, uv_corr);
                uv1 = _mm_sub_epi8(uv1, uv_corr);

                b_c_lo = _mm_maddubs_epi16(v_cb, uv0);
                r_c_lo = _mm_maddubs_epi16(v_cr, uv0);
                g_c_lo = _mm_maddubs_epi16(v_g_coeffs, uv0);

                b_c_hi = _mm_maddubs_epi16(v_cb, uv1);
                r_c_hi = _mm_maddubs_epi16(v_cr, uv1);
                g_c_hi = _mm_maddubs_epi16(v_g_coeffs, uv1);
            }
        }

        let y_values = _mm_subs_epu8(y_vl0, y_corr);

        let y_hi = _mm_unpackhi_epi8(y_values, _mm_setzero_si128());
        let y_lo = _mm_unpacklo_epi8(y_values, _mm_setzero_si128());
        let y_gh = _mm_maddubs_epi16(y_hi, v_y_c);
        let y_gl = _mm_maddubs_epi16(y_lo, v_y_c);

        let mut r_high0 = _mm_add_epi16(y_gh, r_c_hi);
        let mut b_high0 = _mm_add_epi16(y_gh, b_c_hi);
        let mut g_high0 = _mm_sub_epi16(y_gh, g_c_hi);

        let mut r_low0 = _mm_add_epi16(y_gl, r_c_lo);
        let mut b_low0 = _mm_add_epi16(y_gl, b_c_lo);
        let mut g_low0 = _mm_sub_epi16(y_gl, g_c_lo);

        r_low0 = _mm_srai_epi16::<6>(r_low0);
        b_low0 = _mm_srai_epi16::<6>(b_low0);
        g_low0 = _mm_srai_epi16::<6>(g_low0);

        r_high0 = _mm_srai_epi16::<6>(r_high0);
        g_high0 = _mm_srai_epi16::<6>(g_high0);
        b_high0 = _mm_srai_epi16::<6>(b_high0);

        let r_values = _mm_packus_epi16(r_low0, r_high0);
        let g_values = _mm_packus_epi16(g_low0, g_high0);
        let b_values = _mm_packus_epi16(b_low0, b_high0);

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
                uv_x += 16;
            }
            YuvChromaSubsampling::Yuv444 => {
                uv_x += 32;
            }
        }
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 16);

        let mut dst_buffer: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer: [u8; 16] = [0; 16];
        let mut uv_buffer: [u8; 16 * 2] = [0; 16 * 2];

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

        let y_vl0 = _mm_loadu_si128(y_buffer.as_ptr() as *const __m128i);

        let (g_c_hi, g_c_lo, b_c_hi, b_c_lo, r_c_hi, r_c_lo);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut uv_values_ = _mm_loadu_si128(uv_buffer.as_ptr() as *const __m128i);

                uv_values_ = _mm_sub_epi8(uv_values_, uv_corr);

                let b_c_values = _mm_maddubs_epi16(v_cb, uv_values_);
                let r_c_values = _mm_maddubs_epi16(v_cr, uv_values_);
                let g_c_values = _mm_maddubs_epi16(v_g_coeffs, uv_values_);

                g_c_hi = _mm_unpackhi_epi16(g_c_values, g_c_values);
                g_c_lo = _mm_unpacklo_epi16(g_c_values, g_c_values);
                b_c_hi = _mm_unpackhi_epi16(b_c_values, b_c_values);
                b_c_lo = _mm_unpacklo_epi16(b_c_values, b_c_values);
                r_c_hi = _mm_unpackhi_epi16(r_c_values, r_c_values);
                r_c_lo = _mm_unpacklo_epi16(r_c_values, r_c_values);
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut uv0 = _mm_loadu_si128(uv_buffer.as_ptr() as *const __m128i);
                let mut uv1 = _mm_loadu_si128(uv_buffer.as_ptr().add(16) as *const __m128i);
                uv0 = _mm_sub_epi8(uv0, uv_corr);
                uv1 = _mm_sub_epi8(uv1, uv_corr);

                b_c_lo = _mm_maddubs_epi16(v_cb, uv0);
                r_c_lo = _mm_maddubs_epi16(v_cr, uv0);
                g_c_lo = _mm_maddubs_epi16(v_g_coeffs, uv0);

                b_c_hi = _mm_maddubs_epi16(v_cb, uv1);
                r_c_hi = _mm_maddubs_epi16(v_cr, uv1);
                g_c_hi = _mm_maddubs_epi16(v_g_coeffs, uv1);
            }
        }

        let y_values = _mm_subs_epu8(y_vl0, y_corr);

        let y_hi = _mm_unpackhi_epi8(y_values, _mm_setzero_si128());
        let y_lo = _mm_unpacklo_epi8(y_values, _mm_setzero_si128());
        let y_gh = _mm_maddubs_epi16(y_hi, v_y_c);
        let y_gl = _mm_maddubs_epi16(y_lo, v_y_c);

        let mut r_high0 = _mm_add_epi16(y_gh, r_c_hi);
        let mut b_high0 = _mm_add_epi16(y_gh, b_c_hi);
        let mut g_high0 = _mm_sub_epi16(y_gh, g_c_hi);

        let mut r_low0 = _mm_add_epi16(y_gl, r_c_lo);
        let mut b_low0 = _mm_add_epi16(y_gl, b_c_lo);
        let mut g_low0 = _mm_sub_epi16(y_gl, g_c_lo);

        r_low0 = _mm_srai_epi16::<6>(r_low0);
        b_low0 = _mm_srai_epi16::<6>(b_low0);
        g_low0 = _mm_srai_epi16::<6>(g_low0);

        r_high0 = _mm_srai_epi16::<6>(r_high0);
        g_high0 = _mm_srai_epi16::<6>(g_high0);
        b_high0 = _mm_srai_epi16::<6>(b_high0);

        let r_values = _mm_packus_epi16(r_low0, r_high0);
        let g_values = _mm_packus_epi16(g_low0, g_high0);
        let b_values = _mm_packus_epi16(b_low0, b_high0);

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
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
