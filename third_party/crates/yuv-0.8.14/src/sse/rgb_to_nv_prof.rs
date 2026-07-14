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
    _mm_affine_uv_dot, _mm_interleave_epi16, _mm_load_deinterleave_rgb_for_yuv,
    sse_pairwise_avg_epi8_j,
};
use crate::yuv_support::{
    CbCrForwardTransform, YuvChromaRange, YuvChromaSubsampling, YuvNVOrder, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_rgba_to_nv_prof<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
>(
    y_plane: &mut [u8],
    uv_plane: &mut [u8],
    rgba: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    unsafe {
        sse_rgba_to_nv_impl::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>(
            y_plane, uv_plane, rgba, width, range, transform, start_cx, start_ux,
        )
    }
}

#[inline(always)]
unsafe fn encode_16_part<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
>(
    src: &[u8],
    y_dst: &mut [u8],
    uv_dst: &mut [u8],
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
) {
    let order: YuvNVOrder = UV_ORDER.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    let rounding_const_y = (1 << (PRECISION - 1)) - 1;
    let y_bias = _mm_set1_epi32(range.bias_y as i32 * (1 << PRECISION) + rounding_const_y);
    let v_yr_yg = _mm_set1_epi32(transform._interleaved_yr_yg());
    let v_yb = _mm_set1_epi32(transform.yb);

    let precision_uv = match chroma_subsampling {
        YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => PRECISION + 1,
        YuvChromaSubsampling::Yuv444 => PRECISION,
    };
    let rounding_const_uv = (1 << (precision_uv - 1)) - 1;

    let uv_bias = _mm_set1_epi32(range.bias_uv as i32 * (1 << precision_uv) + rounding_const_uv);
    let v_cb_r_g = _mm_set1_epi32(transform._interleaved_cbr_cbg());
    let v_cb_b = _mm_set1_epi32(transform.cb_b);
    let v_cr_r_g = _mm_set1_epi32(transform._interleaved_crr_crg());
    let v_cr_b = _mm_set1_epi32(transform.cr_b);

    let (r_values, g_values, b_values) =
        _mm_load_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(src.as_ptr());

    let rl0 = _mm_unpacklo_epi8(r_values, _mm_setzero_si128());
    let gl0 = _mm_unpacklo_epi8(g_values, _mm_setzero_si128());
    let bl0 = _mm_unpacklo_epi8(b_values, _mm_setzero_si128());

    let (rl_gl0, rl_gl1) = _mm_interleave_epi16(rl0, gl0);
    let (b_lo0, b_lo1) = _mm_interleave_epi16(bl0, _mm_setzero_si128());

    let y00_vl =
        _mm_affine_uv_dot::<PRECISION>(y_bias, rl_gl0, rl_gl1, b_lo0, b_lo1, v_yr_yg, v_yb);

    let rh0 = _mm_unpackhi_epi8(r_values, _mm_setzero_si128());
    let gh0 = _mm_unpackhi_epi8(g_values, _mm_setzero_si128());
    let bh0 = _mm_unpackhi_epi8(b_values, _mm_setzero_si128());

    let (rl_gh0, rl_gh1) = _mm_interleave_epi16(rh0, gh0);
    let (b_h0, b_h1) = _mm_interleave_epi16(bh0, _mm_setzero_si128());

    let y01_vl = _mm_affine_uv_dot::<PRECISION>(y_bias, rl_gh0, rl_gh1, b_h0, b_h1, v_yr_yg, v_yb);

    let y0_values = _mm_packus_epi16(y00_vl, y01_vl);
    _mm_storeu_si128(y_dst.as_mut_ptr() as *mut _, y0_values);

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let cb_l =
            _mm_affine_uv_dot::<PRECISION>(uv_bias, rl_gl0, rl_gl1, b_lo0, b_lo1, v_cb_r_g, v_cb_b);
        let cb_h =
            _mm_affine_uv_dot::<PRECISION>(uv_bias, rl_gh0, rl_gh1, b_h0, b_h1, v_cb_r_g, v_cb_b);
        let cr_l =
            _mm_affine_uv_dot::<PRECISION>(uv_bias, rl_gl0, rl_gl1, b_lo0, b_lo1, v_cr_r_g, v_cr_b);
        let cr_h =
            _mm_affine_uv_dot::<PRECISION>(uv_bias, rl_gh0, rl_gh1, b_h0, b_h1, v_cr_r_g, v_cr_b);

        let mut cb = _mm_packus_epi16(cb_l, cb_h);
        let mut cr = _mm_packus_epi16(cr_l, cr_h);
        if order == YuvNVOrder::VU {
            std::mem::swap(&mut cb, &mut cr);
        }

        let row0 = _mm_unpacklo_epi8(cb, cr);
        let row1 = _mm_unpackhi_epi8(cb, cr);

        _mm_storeu_si128(uv_dst.as_mut_ptr() as *mut _, row0);
        _mm_storeu_si128(uv_dst.as_mut_ptr().add(16) as *mut _, row1);
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
        || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
    {
        let r1 = sse_pairwise_avg_epi8_j(r_values, 1);
        let g1 = sse_pairwise_avg_epi8_j(g_values, 1);
        let b1 = sse_pairwise_avg_epi8_j(b_values, 1);

        let (rhv0, rhv1) = _mm_interleave_epi16(r1, g1);
        let (bhv0, bhv1) = _mm_interleave_epi16(b1, _mm_setzero_si128());

        let cb_s = _mm_affine_uv_dot::<16>(uv_bias, rhv0, rhv1, bhv0, bhv1, v_cb_r_g, v_cb_b);
        let cr_s = _mm_affine_uv_dot::<16>(uv_bias, rhv0, rhv1, bhv0, bhv1, v_cr_r_g, v_cr_b);

        let cb = _mm_packus_epi16(cb_s, cb_s);
        let cr = _mm_packus_epi16(cr_s, cr_s);

        let row0 = match order {
            YuvNVOrder::UV => _mm_unpacklo_epi8(cb, cr),
            YuvNVOrder::VU => _mm_unpacklo_epi8(cr, cb),
        };

        _mm_storeu_si128(uv_dst.as_mut_ptr() as *mut _, row0);
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_rgba_to_nv_impl<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
>(
    y_plane: &mut [u8],
    uv_plane: &mut [u8],
    rgba: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    while cx + 16 < width as usize {
        let px = cx * channels;

        encode_16_part::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>(
            rgba.get_unchecked(px..),
            y_plane.get_unchecked_mut(cx..),
            uv_plane.get_unchecked_mut(uv_x..),
            range,
            transform,
        );

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            uv_x += 32;
        } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
            || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
        {
            uv_x += 16;
        }

        cx += 16;
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 16);

        let mut src_buffer: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer0: [u8; 16] = [0; 16];
        let mut uv_buffer: [u8; 16 * 2] = [0; 16 * 2];

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

        // Replicate last item to one more position for subsampling
        if chroma_subsampling != YuvChromaSubsampling::Yuv444 && diff % 2 != 0 {
            let lst = (width as usize - 1) * channels;
            let last_items = rgba.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst = src_buffer.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst.iter_mut().zip(last_items) {
                *dst = *src;
            }
        }

        encode_16_part::<ORIGIN_CHANNELS, UV_ORDER, SAMPLING, PRECISION>(
            src_buffer.as_slice(),
            y_buffer0.as_mut_slice(),
            uv_buffer.as_mut_slice(),
            range,
            transform,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        let ux_size = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2) * 2,
            YuvChromaSubsampling::Yuv444 => diff * 2,
        };

        std::ptr::copy_nonoverlapping(
            uv_buffer.as_ptr().cast(),
            uv_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
            ux_size,
        );

        cx += diff;
        uv_x += ux_size;
    }

    ProcessedOffset { cx, ux: uv_x }
}
