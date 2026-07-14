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
use crate::sse::{_mm_mul_add_epi16, _mm_mul_sub_epi16, _mm_store_interleave_rgb_for_yuv};
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvNVOrder, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_yuv_nv_to_rgba_row_prof<
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
        sse_yuv_nv_to_rgba_row_impl_prof::<UV_ORDER, DESTINATION_CHANNELS, YUV_CHROMA_SAMPLING>(
            range, transform, y_plane, uv_plane, rgba, start_cx, start_ux, width,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_yuv_nv_to_rgba_row_impl_prof<
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

    const PRECISION: i32 = 14;

    let y_corr = _mm_set1_epi8(range.bias_y as i8);
    let uv_corr = _mm_set1_epi8(range.bias_uv as i8);
    let v_luma_coeff = _mm_set1_epi16(transform.y_coef as i16);
    let v_cr_coeff = if order == YuvNVOrder::VU {
        _mm_set1_epi32(transform.cr_coef as u32 as i32)
    } else {
        _mm_set1_epi32(((transform.cr_coef as u32) << 16) as i32)
    };
    let v_cb_part = ((transform.cb_coef - i16::MAX as i32) as u32) << 16;
    let v_cb_coeff = _mm_set1_epi32((v_cb_part | (i16::MAX as u32)) as i32);
    let g_trn1 = transform.g_coeff_1;
    let g_trn2 = transform.g_coeff_2;
    let v_g_coeff_1 = if order == YuvNVOrder::VU {
        _mm_set1_epi32((((g_trn2 as u32) << 16) | (g_trn1 as u32)) as i32)
    } else {
        _mm_set1_epi32((((g_trn1 as u32) << 16) | (g_trn2 as u32)) as i32)
    };
    let base_y = _mm_set1_epi32(1 << (PRECISION - 1));

    while cx + 16 < width {
        let y_vl = _mm_loadu_si128(y_ptr.add(cx) as *const _);

        let (uv_lo, uv_hi);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut uv_values = _mm_loadu_si128(uv_ptr.add(uv_x) as *const _);
                uv_values = _mm_sub_epi8(uv_values, uv_corr);
                (uv_lo, uv_hi) = (
                    _mm_unpacklo_epi16(uv_values, uv_values),
                    _mm_unpackhi_epi16(uv_values, uv_values),
                );
            }
            YuvChromaSubsampling::Yuv444 => {
                let offset = uv_x;
                let src_ptr = uv_ptr.add(offset);
                let mut row0 = _mm_loadu_si128(src_ptr as *const _);
                let mut row1 = _mm_loadu_si128(src_ptr.add(16) as *const _);
                row0 = _mm_sub_epi8(row0, uv_corr);
                row1 = _mm_sub_epi8(row1, uv_corr);
                uv_lo = row0;
                uv_hi = row1;
            }
        }

        let y_values = _mm_subs_epu8(y_vl, y_corr);

        let y_vl0_lo = _mm_unpacklo_epi8(y_values, _mm_setzero_si128());
        let y_vl0_hi = _mm_unpackhi_epi8(y_values, _mm_setzero_si128());

        let y_vl0_lo0 = _mm_unpacklo_epi16(y_vl0_lo, _mm_setzero_si128());
        let y_vl0_lo1 = _mm_unpackhi_epi16(y_vl0_lo, _mm_setzero_si128());

        let y_vl0_hi0 = _mm_unpacklo_epi16(y_vl0_hi, _mm_setzero_si128());
        let y_vl0_hi1 = _mm_unpackhi_epi16(y_vl0_hi, _mm_setzero_si128());

        let y_vl0_lo = _mm_mul_add_epi16(base_y, y_vl0_lo0, v_luma_coeff);
        let y_vl0_lo1 = _mm_mul_add_epi16(base_y, y_vl0_lo1, v_luma_coeff);
        let y_vl0_hi = _mm_mul_add_epi16(base_y, y_vl0_hi0, v_luma_coeff);
        let y_vl0_hi1 = _mm_mul_add_epi16(base_y, y_vl0_hi1, v_luma_coeff);

        let uvll = _mm_cvtepi8_epi16(uv_lo);
        let uvlh = _mm_cvtepi8_epi16(_mm_srli_si128::<8>(uv_lo));
        let uvhl = _mm_cvtepi8_epi16(uv_hi);
        let uvhh = _mm_cvtepi8_epi16(_mm_srli_si128::<8>(uv_hi));

        let mut g_low00_ll = _mm_mul_sub_epi16(y_vl0_lo, uvll, v_g_coeff_1);
        let mut g_low01_ll = _mm_mul_sub_epi16(y_vl0_lo1, uvlh, v_g_coeff_1);
        let mut g_low00_hl = _mm_mul_sub_epi16(y_vl0_hi, uvhl, v_g_coeff_1);
        let mut g_low01_hl = _mm_mul_sub_epi16(y_vl0_hi1, uvhh, v_g_coeff_1);

        g_low00_ll = _mm_srai_epi32::<PRECISION>(g_low00_ll);
        g_low01_ll = _mm_srai_epi32::<PRECISION>(g_low01_ll);
        g_low00_hl = _mm_srai_epi32::<PRECISION>(g_low00_hl);
        g_low01_hl = _mm_srai_epi32::<PRECISION>(g_low01_hl);

        let g_low0_l = _mm_packus_epi32(g_low00_ll, g_low01_ll);
        let g_low0_h = _mm_packus_epi32(g_low00_hl, g_low01_hl);

        let g_values0 = _mm_packus_epi16(g_low0_l, g_low0_h);

        let mut r_low00_ll = _mm_mul_add_epi16(y_vl0_lo, uvll, v_cr_coeff);
        let mut r_low01_ll = _mm_mul_add_epi16(y_vl0_lo1, uvlh, v_cr_coeff);
        let mut r_low00_hl = _mm_mul_add_epi16(y_vl0_hi, uvhl, v_cr_coeff);
        let mut r_low01_hl = _mm_mul_add_epi16(y_vl0_hi1, uvhh, v_cr_coeff);

        r_low00_ll = _mm_srai_epi32::<PRECISION>(r_low00_ll);
        r_low01_ll = _mm_srai_epi32::<PRECISION>(r_low01_ll);
        r_low00_hl = _mm_srai_epi32::<PRECISION>(r_low00_hl);
        r_low01_hl = _mm_srai_epi32::<PRECISION>(r_low01_hl);

        let r_low0_l = _mm_packus_epi32(r_low00_ll, r_low01_ll);
        let r_low0_h = _mm_packus_epi32(r_low00_hl, r_low01_hl);

        let r_values0 = _mm_packus_epi16(r_low0_l, r_low0_h);

        let (uull, uulh, uuhl, uuhh) = if order == YuvNVOrder::VU {
            let sh = _mm_setr_epi8(2, 3, 2, 3, 6, 7, 6, 7, 10, 11, 10, 11, 14, 15, 14, 15);
            (
                _mm_shuffle_epi8(uvll, sh),
                _mm_shuffle_epi8(uvlh, sh),
                _mm_shuffle_epi8(uvhl, sh),
                _mm_shuffle_epi8(uvhh, sh),
            )
        } else {
            let sh = _mm_setr_epi8(0, 1, 0, 1, 4, 5, 4, 5, 8, 9, 8, 9, 12, 13, 12, 13);
            (
                _mm_shuffle_epi8(uvll, sh),
                _mm_shuffle_epi8(uvlh, sh),
                _mm_shuffle_epi8(uvhl, sh),
                _mm_shuffle_epi8(uvhh, sh),
            )
        };

        let mut b_low00_ll = _mm_mul_add_epi16(y_vl0_lo, uull, v_cb_coeff);
        let mut b_low01_ll = _mm_mul_add_epi16(y_vl0_lo1, uulh, v_cb_coeff);
        let mut b_low00_hl = _mm_mul_add_epi16(y_vl0_hi, uuhl, v_cb_coeff);
        let mut b_low01_hl = _mm_mul_add_epi16(y_vl0_hi1, uuhh, v_cb_coeff);

        b_low00_ll = _mm_srai_epi32::<PRECISION>(b_low00_ll);
        b_low01_ll = _mm_srai_epi32::<PRECISION>(b_low01_ll);
        b_low00_hl = _mm_srai_epi32::<PRECISION>(b_low00_hl);
        b_low01_hl = _mm_srai_epi32::<PRECISION>(b_low01_hl);

        let b_low0_l = _mm_packus_epi32(b_low00_ll, b_low01_ll);
        let b_low0_h = _mm_packus_epi32(b_low00_hl, b_low01_hl);

        let b_values0 = _mm_packus_epi16(b_low0_l, b_low0_h);

        let dst_shift = cx * channels;

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
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

        assert!(diff <= 32);

        let mut dst_buffer: [u8; 32 * 4] = [0; 32 * 4];
        let mut y_buffer: [u8; 32] = [0; 32];
        let mut uv_buffer: [u8; 32 * 2] = [0; 32 * 2];

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

        let y_vl = _mm_loadu_si128(y_buffer.as_ptr() as *const _);

        let (uv_lo, uv_hi);

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut uv_values = _mm_loadu_si128(uv_buffer.as_ptr() as *const _);
                uv_values = _mm_sub_epi8(uv_values, uv_corr);
                (uv_lo, uv_hi) = (
                    _mm_unpacklo_epi16(uv_values, uv_values),
                    _mm_unpackhi_epi16(uv_values, uv_values),
                );
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut row0 = _mm_loadu_si128(uv_buffer.as_ptr() as *const _);
                let mut row1 = _mm_loadu_si128(uv_buffer.as_ptr().add(16) as *const _);
                row0 = _mm_sub_epi8(row0, uv_corr);
                row1 = _mm_sub_epi8(row1, uv_corr);
                uv_lo = row0;
                uv_hi = row1;
            }
        }

        let y_values = _mm_subs_epu8(y_vl, y_corr);

        let y_vl0_lo = _mm_unpacklo_epi8(y_values, _mm_setzero_si128());
        let y_vl0_hi = _mm_unpackhi_epi8(y_values, _mm_setzero_si128());

        let y_vl0_lo0 = _mm_unpacklo_epi16(y_vl0_lo, _mm_setzero_si128());
        let y_vl0_lo1 = _mm_unpackhi_epi16(y_vl0_lo, _mm_setzero_si128());

        let y_vl0_hi0 = _mm_unpacklo_epi16(y_vl0_hi, _mm_setzero_si128());
        let y_vl0_hi1 = _mm_unpackhi_epi16(y_vl0_hi, _mm_setzero_si128());

        let y_vl0_lo = _mm_mul_add_epi16(base_y, y_vl0_lo0, v_luma_coeff);
        let y_vl0_lo1 = _mm_mul_add_epi16(base_y, y_vl0_lo1, v_luma_coeff);
        let y_vl0_hi = _mm_mul_add_epi16(base_y, y_vl0_hi0, v_luma_coeff);
        let y_vl0_hi1 = _mm_mul_add_epi16(base_y, y_vl0_hi1, v_luma_coeff);

        let uvll = _mm_cvtepi8_epi16(uv_lo);
        let uvlh = _mm_cvtepi8_epi16(_mm_srli_si128::<8>(uv_lo));
        let uvhl = _mm_cvtepi8_epi16(uv_hi);
        let uvhh = _mm_cvtepi8_epi16(_mm_srli_si128::<8>(uv_hi));

        let mut g_low00_ll = _mm_mul_sub_epi16(y_vl0_lo, uvll, v_g_coeff_1);
        let mut g_low01_ll = _mm_mul_sub_epi16(y_vl0_lo1, uvlh, v_g_coeff_1);
        let mut g_low00_hl = _mm_mul_sub_epi16(y_vl0_hi, uvhl, v_g_coeff_1);
        let mut g_low01_hl = _mm_mul_sub_epi16(y_vl0_hi1, uvhh, v_g_coeff_1);

        g_low00_ll = _mm_srai_epi32::<PRECISION>(g_low00_ll);
        g_low01_ll = _mm_srai_epi32::<PRECISION>(g_low01_ll);
        g_low00_hl = _mm_srai_epi32::<PRECISION>(g_low00_hl);
        g_low01_hl = _mm_srai_epi32::<PRECISION>(g_low01_hl);

        let g_low0_l = _mm_packus_epi32(g_low00_ll, g_low01_ll);
        let g_low0_h = _mm_packus_epi32(g_low00_hl, g_low01_hl);

        let g_values0 = _mm_packus_epi16(g_low0_l, g_low0_h);

        let mut r_low00_ll = _mm_mul_add_epi16(y_vl0_lo, uvll, v_cr_coeff);
        let mut r_low01_ll = _mm_mul_add_epi16(y_vl0_lo1, uvlh, v_cr_coeff);
        let mut r_low00_hl = _mm_mul_add_epi16(y_vl0_hi, uvhl, v_cr_coeff);
        let mut r_low01_hl = _mm_mul_add_epi16(y_vl0_hi1, uvhh, v_cr_coeff);

        r_low00_ll = _mm_srai_epi32::<PRECISION>(r_low00_ll);
        r_low01_ll = _mm_srai_epi32::<PRECISION>(r_low01_ll);
        r_low00_hl = _mm_srai_epi32::<PRECISION>(r_low00_hl);
        r_low01_hl = _mm_srai_epi32::<PRECISION>(r_low01_hl);

        let r_low0_l = _mm_packus_epi32(r_low00_ll, r_low01_ll);
        let r_low0_h = _mm_packus_epi32(r_low00_hl, r_low01_hl);

        let r_values0 = _mm_packus_epi16(r_low0_l, r_low0_h);

        let (uull, uulh, uuhl, uuhh) = if order == YuvNVOrder::VU {
            let sh = _mm_setr_epi8(2, 3, 2, 3, 6, 7, 6, 7, 10, 11, 10, 11, 14, 15, 14, 15);
            (
                _mm_shuffle_epi8(uvll, sh),
                _mm_shuffle_epi8(uvlh, sh),
                _mm_shuffle_epi8(uvhl, sh),
                _mm_shuffle_epi8(uvhh, sh),
            )
        } else {
            let sh = _mm_setr_epi8(0, 1, 0, 1, 4, 5, 4, 5, 8, 9, 8, 9, 12, 13, 12, 13);
            (
                _mm_shuffle_epi8(uvll, sh),
                _mm_shuffle_epi8(uvlh, sh),
                _mm_shuffle_epi8(uvhl, sh),
                _mm_shuffle_epi8(uvhh, sh),
            )
        };

        let mut b_low00_ll = _mm_mul_add_epi16(y_vl0_lo, uull, v_cb_coeff);
        let mut b_low01_ll = _mm_mul_add_epi16(y_vl0_lo1, uulh, v_cb_coeff);
        let mut b_low00_hl = _mm_mul_add_epi16(y_vl0_hi, uuhl, v_cb_coeff);
        let mut b_low01_hl = _mm_mul_add_epi16(y_vl0_hi1, uuhh, v_cb_coeff);

        b_low00_ll = _mm_srai_epi32::<PRECISION>(b_low00_ll);
        b_low01_ll = _mm_srai_epi32::<PRECISION>(b_low01_ll);
        b_low00_hl = _mm_srai_epi32::<PRECISION>(b_low00_hl);
        b_low01_hl = _mm_srai_epi32::<PRECISION>(b_low01_hl);

        let b_low0_l = _mm_packus_epi32(b_low00_ll, b_low01_ll);
        let b_low0_h = _mm_packus_epi32(b_low00_hl, b_low01_hl);

        let b_values0 = _mm_packus_epi16(b_low0_l, b_low0_h);

        let v_alpha = _mm_set1_epi8(255u8 as i8);

        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
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
