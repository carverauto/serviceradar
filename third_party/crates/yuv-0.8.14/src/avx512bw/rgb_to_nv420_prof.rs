/*
 * Copyright (c) Radzivon Bartoshyk, 01/2025. All rights reserved.
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
    _mm512_affine_dot, avx512_load_rgb_u8, avx512_pack_u16, avx512_pairwise_avg_epi16_epi8_j,
    avx512_zip_epi16, avx512_zip_epi8,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvNVOrder, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is special path for 2 rows of BiPlanar 4:2:0 to reuse variables instead of computing them
pub(crate) fn avx512_rgba_to_nv420_prof<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const HAS_VBMI: bool,
>(
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    uv_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    unsafe {
        if std::arch::is_x86_feature_detected!("avx512vnni") {
            if HAS_VBMI {
                return avx512_rgba_to_nv_prof_dot_vbmi::<ORIGIN_CHANNELS, UV_ORDER>(
                    y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx,
                    start_ux,
                );
            } else {
                return avx512_rgba_to_nv_prof_dot::<ORIGIN_CHANNELS, UV_ORDER>(
                    y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx,
                    start_ux,
                );
            }
        }
        if HAS_VBMI {
            avx512_rgba_to_nv_prof_def_vbmi::<ORIGIN_CHANNELS, UV_ORDER>(
                y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx,
                start_ux,
            )
        } else {
            avx512_rgba_to_nv_prof_def::<ORIGIN_CHANNELS, UV_ORDER>(
                y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx,
                start_ux,
            )
        }
    }
}

#[inline(always)]
unsafe fn encode_64_part<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const PRECISION: u32,
    const HAS_DOT: bool,
    const HAS_VBMI: bool,
>(
    src0: &[u8],
    src1: &[u8],
    y_dst0: &mut [u8],
    y_dst1: &mut [u8],
    uv_dst: &mut [u8],
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
) {
    let order: YuvNVOrder = UV_ORDER.into();

    let rounding_const_y = (1 << (PRECISION - 1)) - 1;
    let y_bias = _mm512_set1_epi32(range.bias_y as i32 * (1 << PRECISION) + rounding_const_y);
    let v_yr_yg = _mm512_set1_epi32(transform._interleaved_yr_yg());
    let v_yb = _mm512_set1_epi32(transform.yb);

    let precision_uv = PRECISION + 1;
    let rounding_const_uv = (1 << (precision_uv - 1)) - 1;

    let uv_bias = _mm512_set1_epi32(range.bias_uv as i32 * (1 << precision_uv) + rounding_const_uv);
    let v_cb_r_g = _mm512_set1_epi32(transform._interleaved_cbr_cbg());
    let v_cb_b = _mm512_set1_epi32(transform.cb_b);
    let v_cr_r_g = _mm512_set1_epi32(transform._interleaved_crr_crg());
    let v_cr_b = _mm512_set1_epi32(transform.cr_b);

    let (r_values0, g_values0, b_values0) =
        avx512_load_rgb_u8::<ORIGIN_CHANNELS, HAS_VBMI>(src0.as_ptr());
    let (r_values1, g_values1, b_values1) =
        avx512_load_rgb_u8::<ORIGIN_CHANNELS, HAS_VBMI>(src1.as_ptr());

    let rl0 = _mm512_unpacklo_epi8(r_values0, _mm512_setzero_si512());
    let gl0 = _mm512_unpacklo_epi8(g_values0, _mm512_setzero_si512());
    let bl0 = _mm512_unpacklo_epi8(b_values0, _mm512_setzero_si512());

    let (rl_gl0, rl_gl1) = avx512_zip_epi16(rl0, gl0);
    let (b_lo0, b_lo1) = avx512_zip_epi16(bl0, _mm512_setzero_si512());

    let y00_vl = _mm512_affine_dot::<PRECISION, HAS_DOT>(
        y_bias, rl_gl0, rl_gl1, b_lo0, b_lo1, v_yr_yg, v_yb,
    );

    let rh0 = _mm512_unpackhi_epi8(r_values0, _mm512_setzero_si512());
    let gh0 = _mm512_unpackhi_epi8(g_values0, _mm512_setzero_si512());
    let bh0 = _mm512_unpackhi_epi8(b_values0, _mm512_setzero_si512());

    let (rl_gh0, rl_gh1) = avx512_zip_epi16(rh0, gh0);
    let (b_h0, b_h1) = avx512_zip_epi16(bh0, _mm512_setzero_si512());

    let y01_vl =
        _mm512_affine_dot::<PRECISION, HAS_DOT>(y_bias, rl_gh0, rl_gh1, b_h0, b_h1, v_yr_yg, v_yb);

    let y0_values = _mm512_packus_epi16(y00_vl, y01_vl);
    _mm512_storeu_si512(y_dst0.as_mut_ptr() as *mut _, y0_values);

    let rl1 = _mm512_unpacklo_epi8(r_values1, _mm512_setzero_si512());
    let gl1 = _mm512_unpacklo_epi8(g_values1, _mm512_setzero_si512());
    let bl1 = _mm512_unpacklo_epi8(b_values1, _mm512_setzero_si512());

    let (rl_gl01, rl_gl11) = avx512_zip_epi16(rl1, gl1);
    let (b_lo10, b_lo11) = avx512_zip_epi16(bl1, _mm512_setzero_si512());

    let y10_vl = _mm512_affine_dot::<PRECISION, HAS_DOT>(
        y_bias, rl_gl01, rl_gl11, b_lo10, b_lo11, v_yr_yg, v_yb,
    );

    let rh1 = _mm512_unpackhi_epi8(r_values1, _mm512_setzero_si512());
    let gh1 = _mm512_unpackhi_epi8(g_values1, _mm512_setzero_si512());
    let bh1 = _mm512_unpackhi_epi8(b_values1, _mm512_setzero_si512());

    let (rl_gh11, rl_gh110) = avx512_zip_epi16(rh1, gh1);
    let (b_h11, b_h111) = avx512_zip_epi16(bh1, _mm512_setzero_si512());

    let y11_vl = _mm512_affine_dot::<PRECISION, HAS_DOT>(
        y_bias, rl_gh11, rl_gh110, b_h11, b_h111, v_yr_yg, v_yb,
    );

    let y0_values = _mm512_packus_epi16(y10_vl, y11_vl);
    _mm512_storeu_si512(y_dst1.as_mut_ptr() as *mut _, y0_values);

    let r_avg = _mm512_avg_epu8(r_values0, r_values1);
    let g_avg = _mm512_avg_epu8(g_values0, g_values1);
    let b_avg = _mm512_avg_epu8(b_values0, b_values1);

    let r1 = avx512_pairwise_avg_epi16_epi8_j(r_avg, 1);
    let g1 = avx512_pairwise_avg_epi16_epi8_j(g_avg, 1);
    let b1 = avx512_pairwise_avg_epi16_epi8_j(b_avg, 1);

    let (rhv0, rhv1) = avx512_zip_epi16(r1, g1);
    let (bhv0, bhv1) = avx512_zip_epi16(b1, _mm512_setzero_si512());

    let cb_s = _mm512_affine_dot::<16, HAS_DOT>(uv_bias, rhv0, rhv1, bhv0, bhv1, v_cb_r_g, v_cb_b);

    let cr_s = _mm512_affine_dot::<16, HAS_DOT>(uv_bias, rhv0, rhv1, bhv0, bhv1, v_cr_r_g, v_cr_b);

    let cb = avx512_pack_u16(cb_s, cb_s);
    let cr = avx512_pack_u16(cr_s, cr_s);

    let (row0, _) = match order {
        YuvNVOrder::UV => avx512_zip_epi8::<HAS_VBMI>(cb, cr),
        YuvNVOrder::VU => avx512_zip_epi8::<HAS_VBMI>(cr, cb),
    };

    _mm512_storeu_si512(uv_dst.as_mut_ptr() as *mut _, row0);
}

#[target_feature(enable = "avx512bw")]
unsafe fn avx512_rgba_to_nv_prof_def<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    uv_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    avx512_rgba_to_nv_prof_impl::<ORIGIN_CHANNELS, UV_ORDER, false, false>(
        y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx, start_ux,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512vbmi")]
unsafe fn avx512_rgba_to_nv_prof_def_vbmi<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    uv_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    avx512_rgba_to_nv_prof_impl::<ORIGIN_CHANNELS, UV_ORDER, false, true>(
        y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx, start_ux,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512vnni")]
unsafe fn avx512_rgba_to_nv_prof_dot<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    uv_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    avx512_rgba_to_nv_prof_impl::<ORIGIN_CHANNELS, UV_ORDER, true, false>(
        y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx, start_ux,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512vnni", enable = "avx512vbmi")]
unsafe fn avx512_rgba_to_nv_prof_dot_vbmi<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    uv_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    avx512_rgba_to_nv_prof_impl::<ORIGIN_CHANNELS, UV_ORDER, true, true>(
        y_plane0, y_plane1, uv_plane, rgba0, rgba1, width, range, transform, start_cx, start_ux,
    )
}

#[inline(always)]
unsafe fn avx512_rgba_to_nv_prof_impl<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const HAS_DOT: bool,
    const HAS_VBMI: bool,
>(
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    uv_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    const PRECISION: u32 = 15;

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    while cx + 64 < width as usize {
        let px = cx * channels;

        encode_64_part::<ORIGIN_CHANNELS, UV_ORDER, PRECISION, HAS_DOT, HAS_VBMI>(
            rgba0.get_unchecked(px..),
            rgba1.get_unchecked(px..),
            y_plane0.get_unchecked_mut(cx..),
            y_plane1.get_unchecked_mut(cx..),
            uv_plane.get_unchecked_mut(uv_x..),
            range,
            transform,
        );

        uv_x += 64;
        cx += 64;
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 64);

        let mut src_buffer0: [u8; 64 * 4] = [0; 64 * 4];
        let mut src_buffer1: [u8; 64 * 4] = [0; 64 * 4];
        let mut y_buffer0: [u8; 64] = [0; 64];
        let mut y_buffer1: [u8; 64] = [0; 64];
        let mut uv_buffer: [u8; 64 * 2] = [0; 64 * 2];

        std::ptr::copy_nonoverlapping(
            rgba0.get_unchecked(cx * channels..).as_ptr(),
            src_buffer0.as_mut_ptr(),
            diff * channels,
        );

        std::ptr::copy_nonoverlapping(
            rgba1.get_unchecked(cx * channels..).as_ptr(),
            src_buffer1.as_mut_ptr(),
            diff * channels,
        );

        // Replicate last item to one more position for subsampling
        if diff % 2 != 0 {
            let lst = (width as usize - 1) * channels;
            let last_items0 = rgba0.get_unchecked(lst..(lst + channels));
            let last_items1 = rgba1.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst0 = src_buffer0.get_unchecked_mut(dvb..(dvb + channels));
            let dst1 = src_buffer1.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst0.iter_mut().zip(last_items0) {
                *dst = *src;
            }
            for (dst, src) in dst1.iter_mut().zip(last_items1) {
                *dst = *src;
            }
        }

        encode_64_part::<ORIGIN_CHANNELS, UV_ORDER, PRECISION, HAS_DOT, HAS_VBMI>(
            src_buffer0.as_slice(),
            src_buffer1.as_slice(),
            y_buffer0.as_mut_slice(),
            y_buffer1.as_mut_slice(),
            uv_buffer.as_mut_slice(),
            range,
            transform,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_mut_ptr(),
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer1.as_mut_ptr(),
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        let ux_size = diff.div_ceil(2) * 2;

        std::ptr::copy_nonoverlapping(
            uv_buffer.as_mut_ptr(),
            uv_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
            ux_size,
        );

        cx += diff;
        uv_x += ux_size;
    }

    ProcessedOffset { cx, ux: uv_x }
}
