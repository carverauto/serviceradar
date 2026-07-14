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

use crate::avx2::avx2_utils::{
    _mm256_load_deinterleave_rgb_for_yuv, _mm256_sqrdmlah_dot, avx2_pack_u16,
    avx_pairwise_avg_epi16_epi8_j,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{
    CbCrForwardTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx2_rgba_to_yuv<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    unsafe {
        avx2_rgba_to_yuv_impl::<ORIGIN_CHANNELS, SAMPLING, PRECISION>(
            transform, range, y_plane, u_plane, v_plane, rgba, start_cx, start_ux, width,
        )
    }
}

#[inline(always)]
unsafe fn encode_32_part<const ORIGIN_CHANNELS: u8, const SAMPLING: u8, const PRECISION: i32>(
    src: &[u8],
    y_dst: &mut [u8],
    u_dst: &mut [u8],
    v_dst: &mut [u8],
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
) {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    const V_S: i32 = 4;
    const A_E: i32 = 2;

    let (r_values, g_values, b_values) =
        _mm256_load_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(src.as_ptr());

    let rl = _mm256_unpacklo_epi8(r_values, r_values);
    let rh = _mm256_unpackhi_epi8(r_values, r_values);
    let gl = _mm256_unpacklo_epi8(g_values, g_values);
    let gh = _mm256_unpackhi_epi8(g_values, g_values);
    let bl = _mm256_unpacklo_epi8(b_values, b_values);
    let bh = _mm256_unpackhi_epi8(b_values, b_values);

    let r_low = _mm256_srli_epi16::<V_S>(rl);
    let r_high = _mm256_srli_epi16::<V_S>(rh);
    let g_low = _mm256_srli_epi16::<V_S>(gl);
    let g_high = _mm256_srli_epi16::<V_S>(gh);
    let b_low = _mm256_srli_epi16::<V_S>(bl);
    let b_high = _mm256_srli_epi16::<V_S>(bh);

    let y_bias = _mm256_set1_epi16(range.bias_y as i16 * (1 << A_E));
    let v_yr = _mm256_set1_epi16(transform.yr as i16);
    let v_yg = _mm256_set1_epi16(transform.yg as i16);
    let v_yb = _mm256_set1_epi16(transform.yb as i16);

    let y0_yuv = _mm256_sqrdmlah_dot::<A_E>(
        r_low, r_high, g_low, g_high, b_low, b_high, y_bias, v_yr, v_yg, v_yb,
    );

    _mm256_storeu_si256(y_dst.as_mut_ptr() as *mut __m256i, y0_yuv);

    let uv_bias = _mm256_set1_epi16(range.bias_uv as i16 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let v_cb_r = _mm256_set1_epi16(transform.cb_r as i16);
    let v_cb_g = _mm256_set1_epi16(transform.cb_g as i16);
    let v_cb_b = _mm256_set1_epi16(transform.cb_b as i16);
    let v_cr_r = _mm256_set1_epi16(transform.cr_r as i16);
    let v_cr_g = _mm256_set1_epi16(transform.cr_g as i16);
    let v_cr_b = _mm256_set1_epi16(transform.cr_b as i16);

    if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
        let cb = _mm256_sqrdmlah_dot::<A_E>(
            r_low, r_high, g_low, g_high, b_low, b_high, uv_bias, v_cb_r, v_cb_g, v_cb_b,
        );
        let cr = _mm256_sqrdmlah_dot::<A_E>(
            r_low, r_high, g_low, g_high, b_low, b_high, uv_bias, v_cr_r, v_cr_g, v_cr_b,
        );

        _mm256_storeu_si256(u_dst.as_mut_ptr() as *mut __m256i, cb);
        _mm256_storeu_si256(v_dst.as_mut_ptr() as *mut __m256i, cr);
    } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
        || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
    {
        let r1 = avx_pairwise_avg_epi16_epi8_j(r_values, 1 << (16 - V_S - 8 - 1));
        let g1 = avx_pairwise_avg_epi16_epi8_j(g_values, 1 << (16 - V_S - 8 - 1));
        let b1 = avx_pairwise_avg_epi16_epi8_j(b_values, 1 << (16 - V_S - 8 - 1));

        let cb_r = _mm256_mulhrs_epi16(r1, v_cb_r);
        let cr_r = _mm256_mulhrs_epi16(r1, v_cr_r);
        let cb_g = _mm256_mulhrs_epi16(g1, v_cb_g);
        let cr_g = _mm256_mulhrs_epi16(g1, v_cr_g);
        let cb_b = _mm256_mulhrs_epi16(b1, v_cb_b);
        let cr_b = _mm256_mulhrs_epi16(b1, v_cr_b);

        let cb_s0 = _mm256_add_epi16(cb_r, cb_g);
        let cr_s0 = _mm256_add_epi16(cr_r, cr_g);

        let cb_s1 = _mm256_add_epi16(cb_s0, cb_b);
        let cr_s1 = _mm256_add_epi16(cr_s0, cr_b);

        let cb_s2 = _mm256_add_epi16(uv_bias, cb_s1);
        let cr_s2 = _mm256_add_epi16(uv_bias, cr_s1);

        let cb = _mm256_srli_epi16::<A_E>(cb_s2);
        let cr = _mm256_srli_epi16::<A_E>(cr_s2);

        let cb = avx2_pack_u16(cb, cb);
        let cr = avx2_pack_u16(cr, cr);

        _mm_storeu_si128(
            u_dst.as_mut_ptr() as *mut _ as *mut __m128i,
            _mm256_castsi256_si128(cb),
        );
        _mm_storeu_si128(
            v_dst.as_mut_ptr() as *mut _ as *mut __m128i,
            _mm256_castsi256_si128(cr),
        );
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx2_rgba_to_yuv_impl<
    const ORIGIN_CHANNELS: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    while cx + 32 <= width {
        let px = cx * channels;

        encode_32_part::<ORIGIN_CHANNELS, SAMPLING, PRECISION>(
            rgba.get_unchecked(px..),
            y_plane.get_unchecked_mut(cx..),
            u_plane.get_unchecked_mut(uv_x..),
            v_plane.get_unchecked_mut(uv_x..),
            transform,
            range,
        );

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            uv_x += 32;
        } else if chroma_subsampling == YuvChromaSubsampling::Yuv422
            || (chroma_subsampling == YuvChromaSubsampling::Yuv420)
        {
            uv_x += 16;
        }

        cx += 32;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 32);

        let mut src_buffer: [u8; 32 * 4] = [0; 32 * 4];
        let mut y_buffer: [u8; 32] = [0; 32];
        let mut u_buffer: [u8; 32] = [0; 32];
        let mut v_buffer: [u8; 32] = [0; 32];

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

        // Replicate last item to one more position for subsampling
        if chroma_subsampling != YuvChromaSubsampling::Yuv444 && diff % 2 != 0 {
            let lst = (width - 1) * channels;
            let last_items = rgba.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst = src_buffer.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst.iter_mut().zip(last_items) {
                *dst = *src;
            }
        }

        encode_32_part::<ORIGIN_CHANNELS, SAMPLING, PRECISION>(
            src_buffer.as_slice(),
            y_buffer.as_mut_slice(),
            u_buffer.as_mut_slice(),
            v_buffer.as_mut_slice(),
            transform,
            range,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;
        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr().cast(),
                u_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                diff,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr().cast(),
                v_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                diff,
            );

            uv_x += diff;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let hv = diff.div_ceil(2);
            std::ptr::copy_nonoverlapping(
                u_buffer.as_ptr().cast(),
                u_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                hv,
            );
            std::ptr::copy_nonoverlapping(
                v_buffer.as_ptr().cast(),
                v_plane.get_unchecked_mut(uv_x..).as_mut_ptr(),
                hv,
            );

            uv_x += hv;
        }
    }

    ProcessedOffset { cx, ux: uv_x }
}
