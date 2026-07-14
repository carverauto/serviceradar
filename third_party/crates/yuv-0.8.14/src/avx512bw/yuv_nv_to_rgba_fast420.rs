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

use crate::avx512bw::avx512_utils::avx512_store_rgba_for_yuv_u8;
use crate::internals::ProcessedOffset;
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvNVOrder, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is an exceptional path for doubled row with 4:2:0 subsampling only.
pub(crate) fn avx512_yuv_nv_to_rgba_fast420<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const HAS_VBMI: bool,
>(
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
        if HAS_VBMI {
            avx512_yuv_nv_to_rgba_fast420_vbmi::<UV_ORDER, DESTINATION_CHANNELS>(
                range, transform, y_plane0, y_plane1, uv_plane, rgba0, rgba1, start_cx, start_ux,
                width,
            )
        } else {
            avx512_yuv_nv_to_rgba_fast420_::<UV_ORDER, DESTINATION_CHANNELS>(
                range, transform, y_plane0, y_plane1, uv_plane, rgba0, rgba1, start_cx, start_ux,
                width,
            )
        }
    }
}

#[target_feature(enable = "avx512bw")]
unsafe fn avx512_yuv_nv_to_rgba_fast420_<const UV_ORDER: u8, const DESTINATION_CHANNELS: u8>(
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
    avx512_yuv_nv_to_rgba_impl_fast420::<UV_ORDER, DESTINATION_CHANNELS, false>(
        range, transform, y_plane0, y_plane1, uv_plane, rgba0, rgba1, start_cx, start_ux, width,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512vbmi")]
unsafe fn avx512_yuv_nv_to_rgba_fast420_vbmi<const UV_ORDER: u8, const DESTINATION_CHANNELS: u8>(
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
    avx512_yuv_nv_to_rgba_impl_fast420::<UV_ORDER, DESTINATION_CHANNELS, true>(
        range, transform, y_plane0, y_plane1, uv_plane, rgba0, rgba1, start_cx, start_ux, width,
    )
}

#[target_feature(enable = "avx2")]
unsafe fn avx512_yuv_nv_to_rgba_impl_fast420<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const HAS_VBMI: bool,
>(
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

    let y_corr = _mm512_set1_epi8(range.bias_y as i8);
    let uv_corr = _mm512_set1_epi8(range.bias_uv as i8);
    let v_y_c = _mm512_set1_epi8(transform.y_coef as i8);
    let v_cr = if order == YuvNVOrder::VU {
        _mm512_set1_epi16(transform.cr_coef as i16)
    } else {
        _mm512_set1_epi16(((transform.cr_coef as u16) << 8) as i16)
    };
    let v_cb = if order == YuvNVOrder::VU {
        _mm512_set1_epi16(((transform.cb_coef as u16) << 8) as i16)
    } else {
        _mm512_set1_epi16(transform.cb_coef as i16)
    };
    let v_g_coeffs = if order == YuvNVOrder::VU {
        _mm512_set1_epi16(
            (((transform.g_coeff_2 as u16) << 8) | (transform.g_coeff_1 as u16)) as i16,
        )
    } else {
        _mm512_set1_epi16(
            (((transform.g_coeff_1 as u16) << 8) | (transform.g_coeff_2 as u16)) as i16,
        )
    };

    while cx + 64 < width {
        let y_vl0 = _mm512_loadu_si512(y_plane0.get_unchecked(cx..).as_ptr() as *const _);
        let y_vl1 = _mm512_loadu_si512(y_plane1.get_unchecked(cx..).as_ptr() as *const _);
        let mut uv_values_ = _mm512_loadu_si512(uv_ptr.add(uv_x) as *const _);
        let y_values0 = _mm512_subs_epu8(y_vl0, y_corr);
        let y_values1 = _mm512_subs_epu8(y_vl1, y_corr);
        uv_values_ = _mm512_sub_epi8(uv_values_, uv_corr);

        let y_his0 = _mm512_unpackhi_epi8(y_values0, _mm512_setzero_si512());
        let y_his1 = _mm512_unpackhi_epi8(y_values1, _mm512_setzero_si512());

        let b_c_values = _mm512_maddubs_epi16(v_cb, uv_values_);
        let r_c_values = _mm512_maddubs_epi16(v_cr, uv_values_);
        let g_c_values = _mm512_maddubs_epi16(v_g_coeffs, uv_values_);

        let y_g0 = _mm512_maddubs_epi16(y_his0, v_y_c);
        let y_g1 = _mm512_maddubs_epi16(y_his1, v_y_c);

        let g_c_hi = _mm512_unpackhi_epi16(g_c_values, g_c_values);
        let g_c_lo = _mm512_unpacklo_epi16(g_c_values, g_c_values);
        let b_c_hi = _mm512_unpackhi_epi16(b_c_values, b_c_values);
        let b_c_lo = _mm512_unpacklo_epi16(b_c_values, b_c_values);
        let r_c_hi = _mm512_unpackhi_epi16(r_c_values, r_c_values);
        let r_c_lo = _mm512_unpacklo_epi16(r_c_values, r_c_values);

        let mut r_high0 = _mm512_add_epi16(y_g0, r_c_hi);
        let mut b_high0 = _mm512_add_epi16(y_g0, b_c_hi);
        let mut g_high0 = _mm512_sub_epi16(y_g0, g_c_hi);

        let mut r_high1 = _mm512_add_epi16(y_g1, r_c_hi);
        let mut b_high1 = _mm512_add_epi16(y_g1, b_c_hi);
        let mut g_high1 = _mm512_sub_epi16(y_g1, g_c_hi);

        let y_lo0 = _mm512_unpacklo_epi8(y_values0, _mm512_setzero_si512());
        let y_lo1 = _mm512_unpacklo_epi8(y_values1, _mm512_setzero_si512());

        let y_gl0 = _mm512_maddubs_epi16(y_lo0, v_y_c);
        let y_gl1 = _mm512_maddubs_epi16(y_lo1, v_y_c);

        let mut r_low0 = _mm512_add_epi16(y_gl0, r_c_lo);
        let mut b_low0 = _mm512_add_epi16(y_gl0, b_c_lo);
        let mut g_low0 = _mm512_sub_epi16(y_gl0, g_c_lo);

        let mut r_low1 = _mm512_add_epi16(y_gl1, r_c_lo);
        let mut b_low1 = _mm512_add_epi16(y_gl1, b_c_lo);
        let mut g_low1 = _mm512_sub_epi16(y_gl1, g_c_lo);

        r_low0 = _mm512_srai_epi16::<6>(r_low0);
        b_low0 = _mm512_srai_epi16::<6>(b_low0);
        g_low0 = _mm512_srai_epi16::<6>(g_low0);

        r_low1 = _mm512_srai_epi16::<6>(r_low1);
        b_low1 = _mm512_srai_epi16::<6>(b_low1);
        g_low1 = _mm512_srai_epi16::<6>(g_low1);

        r_high0 = _mm512_srai_epi16::<6>(r_high0);
        g_high0 = _mm512_srai_epi16::<6>(g_high0);
        b_high0 = _mm512_srai_epi16::<6>(b_high0);

        r_high1 = _mm512_srai_epi16::<6>(r_high1);
        g_high1 = _mm512_srai_epi16::<6>(g_high1);
        b_high1 = _mm512_srai_epi16::<6>(b_high1);

        let r_values0 = _mm512_packus_epi16(r_low0, r_high0);
        let g_values0 = _mm512_packus_epi16(g_low0, g_high0);
        let b_values0 = _mm512_packus_epi16(b_low0, b_high0);

        let r_values1 = _mm512_packus_epi16(r_low1, r_high1);
        let g_values1 = _mm512_packus_epi16(g_low1, g_high1);
        let b_values1 = _mm512_packus_epi16(b_low1, b_high1);

        let dst_shift = cx * channels;

        let v_alpha = _mm512_set1_epi8(255u8 as i8);

        avx512_store_rgba_for_yuv_u8::<DESTINATION_CHANNELS, HAS_VBMI>(
            rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );
        avx512_store_rgba_for_yuv_u8::<DESTINATION_CHANNELS, HAS_VBMI>(
            rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values1,
            g_values1,
            b_values1,
            v_alpha,
        );

        cx += 64;
        uv_x += 64;
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 64);

        let mut dst_buffer0: [u8; 64 * 4] = [0; 64 * 4];
        let mut dst_buffer1: [u8; 64 * 4] = [0; 64 * 4];
        let mut y_buffer0: [u8; 64] = [0; 64];
        let mut y_buffer1: [u8; 64] = [0; 64];
        let mut uv_buffer: [u8; 64 * 2] = [0; 64 * 2];

        std::ptr::copy_nonoverlapping(
            y_plane0.get_unchecked(cx..).as_ptr(),
            y_buffer0.as_mut_ptr(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            y_plane1.get_unchecked(cx..).as_ptr(),
            y_buffer1.as_mut_ptr(),
            diff,
        );

        let hv = diff.div_ceil(2) * 2;

        std::ptr::copy_nonoverlapping(
            uv_plane.get_unchecked(uv_x..).as_ptr(),
            uv_buffer.as_mut_ptr(),
            hv,
        );

        let y_vl0 = _mm512_loadu_si512(y_buffer0.as_ptr() as *const _);
        let y_vl1 = _mm512_loadu_si512(y_buffer1.as_ptr() as *const _);
        let mut uv_values_ = _mm512_loadu_si512(uv_buffer.as_ptr() as *const _);
        let y_values0 = _mm512_subs_epu8(y_vl0, y_corr);
        let y_values1 = _mm512_subs_epu8(y_vl1, y_corr);
        uv_values_ = _mm512_sub_epi8(uv_values_, uv_corr);

        let y_his0 = _mm512_unpackhi_epi8(y_values0, _mm512_setzero_si512());
        let y_his1 = _mm512_unpackhi_epi8(y_values1, _mm512_setzero_si512());

        let b_c_values = _mm512_maddubs_epi16(v_cb, uv_values_);
        let r_c_values = _mm512_maddubs_epi16(v_cr, uv_values_);
        let g_c_values = _mm512_maddubs_epi16(v_g_coeffs, uv_values_);

        let y_g0 = _mm512_maddubs_epi16(y_his0, v_y_c);
        let y_g1 = _mm512_maddubs_epi16(y_his1, v_y_c);

        let g_c_hi = _mm512_unpackhi_epi16(g_c_values, g_c_values);
        let g_c_lo = _mm512_unpacklo_epi16(g_c_values, g_c_values);
        let b_c_hi = _mm512_unpackhi_epi16(b_c_values, b_c_values);
        let b_c_lo = _mm512_unpacklo_epi16(b_c_values, b_c_values);
        let r_c_hi = _mm512_unpackhi_epi16(r_c_values, r_c_values);
        let r_c_lo = _mm512_unpacklo_epi16(r_c_values, r_c_values);

        let mut r_high0 = _mm512_add_epi16(y_g0, r_c_hi);
        let mut b_high0 = _mm512_add_epi16(y_g0, b_c_hi);
        let mut g_high0 = _mm512_sub_epi16(y_g0, g_c_hi);

        let mut r_high1 = _mm512_add_epi16(y_g1, r_c_hi);
        let mut b_high1 = _mm512_add_epi16(y_g1, b_c_hi);
        let mut g_high1 = _mm512_sub_epi16(y_g1, g_c_hi);

        let y_lo0 = _mm512_unpacklo_epi8(y_values0, _mm512_setzero_si512());
        let y_lo1 = _mm512_unpacklo_epi8(y_values1, _mm512_setzero_si512());

        let y_gl0 = _mm512_maddubs_epi16(y_lo0, v_y_c);
        let y_gl1 = _mm512_maddubs_epi16(y_lo1, v_y_c);

        let mut r_low0 = _mm512_add_epi16(y_gl0, r_c_lo);
        let mut b_low0 = _mm512_add_epi16(y_gl0, b_c_lo);
        let mut g_low0 = _mm512_sub_epi16(y_gl0, g_c_lo);

        let mut r_low1 = _mm512_add_epi16(y_gl1, r_c_lo);
        let mut b_low1 = _mm512_add_epi16(y_gl1, b_c_lo);
        let mut g_low1 = _mm512_sub_epi16(y_gl1, g_c_lo);

        r_low0 = _mm512_srai_epi16::<6>(r_low0);
        b_low0 = _mm512_srai_epi16::<6>(b_low0);
        g_low0 = _mm512_srai_epi16::<6>(g_low0);

        r_low1 = _mm512_srai_epi16::<6>(r_low1);
        b_low1 = _mm512_srai_epi16::<6>(b_low1);
        g_low1 = _mm512_srai_epi16::<6>(g_low1);

        r_high0 = _mm512_srai_epi16::<6>(r_high0);
        g_high0 = _mm512_srai_epi16::<6>(g_high0);
        b_high0 = _mm512_srai_epi16::<6>(b_high0);

        r_high1 = _mm512_srai_epi16::<6>(r_high1);
        g_high1 = _mm512_srai_epi16::<6>(g_high1);
        b_high1 = _mm512_srai_epi16::<6>(b_high1);

        let r_values0 = _mm512_packus_epi16(r_low0, r_high0);
        let g_values0 = _mm512_packus_epi16(g_low0, g_high0);
        let b_values0 = _mm512_packus_epi16(b_low0, b_high0);

        let r_values1 = _mm512_packus_epi16(r_low1, r_high1);
        let g_values1 = _mm512_packus_epi16(g_low1, g_high1);
        let b_values1 = _mm512_packus_epi16(b_low1, b_high1);

        let v_alpha = _mm512_set1_epi8(255u8 as i8);

        avx512_store_rgba_for_yuv_u8::<DESTINATION_CHANNELS, HAS_VBMI>(
            dst_buffer0.as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );
        avx512_store_rgba_for_yuv_u8::<DESTINATION_CHANNELS, HAS_VBMI>(
            dst_buffer1.as_mut_ptr(),
            r_values1,
            g_values1,
            b_values1,
            v_alpha,
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer0.as_mut_ptr(),
            rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        std::ptr::copy_nonoverlapping(
            dst_buffer1.as_mut_ptr(),
            rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        uv_x += hv;
    }

    ProcessedOffset { cx, ux: uv_x }
}
