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
    _mm256_load_deinterleave_rgb_for_yuv, avx2_pack_u16, avx_pairwise_avg_epi16_epi8_j,
};
use crate::internals::ProcessedOffset;
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// This is special path for 2 rows of 4:2:0 to reuse variables instead of computing them
pub(crate) fn avx2_rgba_to_yuv420<const ORIGIN_CHANNELS: u8, const PRECISION: i32>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    unsafe {
        avx2_rgba_to_yuv_impl420::<ORIGIN_CHANNELS, PRECISION>(
            transform, range, y_plane0, y_plane1, u_plane, v_plane, rgba0, rgba1, start_cx,
            start_ux, width,
        )
    }
}

#[inline(always)]
unsafe fn encode_32_part<const ORIGIN_CHANNELS: u8, const PRECISION: i32>(
    src0: &[u8],
    src1: &[u8],
    y_dst0: &mut [u8],
    y_dst1: &mut [u8],
    u_dst: &mut [u8],
    v_dst: &mut [u8],
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
) {
    const V_S: i32 = 4;
    const A_E: i32 = 2;

    let (r_values0, g_values0, b_values0) =
        _mm256_load_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(src0.as_ptr());

    let (r_values1, g_values1, b_values1) =
        _mm256_load_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(src1.as_ptr());

    let rl0 = _mm256_unpacklo_epi8(r_values0, r_values0);
    let rh0 = _mm256_unpackhi_epi8(r_values0, r_values0);
    let gl0 = _mm256_unpacklo_epi8(g_values0, g_values0);
    let gh0 = _mm256_unpackhi_epi8(g_values0, g_values0);
    let bl0 = _mm256_unpacklo_epi8(b_values0, b_values0);
    let bh0 = _mm256_unpackhi_epi8(b_values0, b_values0);

    let r0_low = _mm256_srli_epi16::<V_S>(rl0);
    let r0_high = _mm256_srli_epi16::<V_S>(rh0);
    let g0_low = _mm256_srli_epi16::<V_S>(gl0);
    let g0_high = _mm256_srli_epi16::<V_S>(gh0);
    let b0_low = _mm256_srli_epi16::<V_S>(bl0);
    let b0_high = _mm256_srli_epi16::<V_S>(bh0);

    let y_bias = _mm256_set1_epi16(range.bias_y as i16 * (1 << A_E));
    let v_yr = _mm256_set1_epi16(transform.yr as i16);
    let v_yg = _mm256_set1_epi16(transform.yg as i16);
    let v_yb = _mm256_set1_epi16(transform.yb as i16);

    let y0_l_r = _mm256_mulhrs_epi16(r0_low, v_yr);
    let y0_h_r = _mm256_mulhrs_epi16(r0_high, v_yr);
    let y0_l_g = _mm256_mulhrs_epi16(g0_low, v_yg);
    let y0_h_g = _mm256_mulhrs_epi16(g0_high, v_yg);
    let y0_l_b = _mm256_mulhrs_epi16(b0_low, v_yb);
    let y0_h_b = _mm256_mulhrs_epi16(b0_high, v_yb);

    let y0_l_s = _mm256_add_epi16(y0_l_r, y0_l_g);
    let y0_h_s = _mm256_add_epi16(y0_h_r, y0_h_g);

    let y0_l_k = _mm256_add_epi16(y0_l_s, y0_l_b);
    let y0_h_k = _mm256_add_epi16(y0_h_s, y0_h_b);

    let y0_l_m = _mm256_add_epi16(y_bias, y0_l_k);
    let y0_h_m = _mm256_add_epi16(y_bias, y0_h_k);

    let y0_l = _mm256_srli_epi16::<A_E>(y0_l_m);
    let y0_h = _mm256_srli_epi16::<A_E>(y0_h_m);

    let y0_yuv = _mm256_packus_epi16(y0_l, y0_h);

    let rl1 = _mm256_unpacklo_epi8(r_values1, r_values1);
    let rh1 = _mm256_unpackhi_epi8(r_values1, r_values1);
    let gl1 = _mm256_unpacklo_epi8(g_values1, g_values1);
    let gh1 = _mm256_unpackhi_epi8(g_values1, g_values1);
    let bl1 = _mm256_unpacklo_epi8(b_values1, b_values1);
    let bh1 = _mm256_unpackhi_epi8(b_values1, b_values1);

    let r1_low = _mm256_srli_epi16::<V_S>(rl1);
    let r1_high = _mm256_srli_epi16::<V_S>(rh1);
    let g1_low = _mm256_srli_epi16::<V_S>(gl1);
    let g1_high = _mm256_srli_epi16::<V_S>(gh1);
    let b1_low = _mm256_srli_epi16::<V_S>(bl1);
    let b1_high = _mm256_srli_epi16::<V_S>(bh1);

    let r1_l_v_yr = _mm256_mulhrs_epi16(r1_low, v_yr);
    let r1_h_v_yr = _mm256_mulhrs_epi16(r1_high, v_yr);
    let r1_l_v_yg = _mm256_mulhrs_epi16(g1_low, v_yg);
    let r1_h_v_yg = _mm256_mulhrs_epi16(g1_high, v_yg);
    let r1_l_v_yb = _mm256_mulhrs_epi16(b1_low, v_yb);
    let r1_h_v_yb = _mm256_mulhrs_epi16(b1_high, v_yb);

    let y1_s0_l = _mm256_add_epi16(r1_l_v_yr, r1_l_v_yg);
    let y1_s0_h = _mm256_add_epi16(r1_h_v_yr, r1_h_v_yg);

    let y1_v0_l = _mm256_add_epi16(y1_s0_l, r1_l_v_yb);
    let y1_v0_h = _mm256_add_epi16(y1_s0_h, r1_h_v_yb);

    let y1_v0_k_l = _mm256_add_epi16(y_bias, y1_v0_l);
    let y1_v0_k_h = _mm256_add_epi16(y_bias, y1_v0_h);

    let y1_l = _mm256_srli_epi16::<A_E>(y1_v0_k_l);
    let y1_h = _mm256_srli_epi16::<A_E>(y1_v0_k_h);

    let y1_yuv = _mm256_packus_epi16(y1_l, y1_h);

    _mm256_storeu_si256(y_dst0.as_mut_ptr() as *mut __m256i, y0_yuv);
    _mm256_storeu_si256(y_dst1.as_mut_ptr() as *mut __m256i, y1_yuv);

    let r_avg = _mm256_avg_epu8(r_values0, r_values1);
    let g_avg = _mm256_avg_epu8(g_values0, g_values1);
    let b_avg = _mm256_avg_epu8(b_values0, b_values1);

    let r_uv = avx_pairwise_avg_epi16_epi8_j(r_avg, 1 << (16 - V_S - 8 - 1));
    let g_uv = avx_pairwise_avg_epi16_epi8_j(g_avg, 1 << (16 - V_S - 8 - 1));
    let b_uv = avx_pairwise_avg_epi16_epi8_j(b_avg, 1 << (16 - V_S - 8 - 1));

    let uv_bias = _mm256_set1_epi16(range.bias_uv as i16 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let v_cb_r = _mm256_set1_epi16(transform.cb_r as i16);
    let v_cb_g = _mm256_set1_epi16(transform.cb_g as i16);
    let v_cb_b = _mm256_set1_epi16(transform.cb_b as i16);
    let v_cr_r = _mm256_set1_epi16(transform.cr_r as i16);
    let v_cr_g = _mm256_set1_epi16(transform.cr_g as i16);
    let v_cr_b = _mm256_set1_epi16(transform.cr_b as i16);

    let cb_r = _mm256_mulhrs_epi16(r_uv, v_cb_r);
    let cr_r = _mm256_mulhrs_epi16(r_uv, v_cr_r);
    let cb_g = _mm256_mulhrs_epi16(g_uv, v_cb_g);
    let cr_g = _mm256_mulhrs_epi16(g_uv, v_cr_g);
    let cb_b = _mm256_mulhrs_epi16(b_uv, v_cb_b);
    let cr_b = _mm256_mulhrs_epi16(b_uv, v_cr_b);

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

#[target_feature(enable = "avx2")]
unsafe fn avx2_rgba_to_yuv_impl420<const ORIGIN_CHANNELS: u8, const PRECISION: i32>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    u_plane: &mut [u8],
    v_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    while cx + 32 <= width {
        encode_32_part::<ORIGIN_CHANNELS, PRECISION>(
            rgba0.get_unchecked(cx * channels..),
            rgba1.get_unchecked(cx * channels..),
            y_plane0.get_unchecked_mut(cx..),
            y_plane1.get_unchecked_mut(cx..),
            u_plane.get_unchecked_mut(uv_x..),
            v_plane.get_unchecked_mut(uv_x..),
            transform,
            range,
        );

        uv_x += 16;
        cx += 32;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 32);

        let mut src_buffer0: [u8; 32 * 4] = [0; 32 * 4];
        let mut src_buffer1: [u8; 32 * 4] = [0; 32 * 4];
        let mut y_buffer0: [u8; 32] = [0; 32];
        let mut y_buffer1: [u8; 32] = [0; 32];
        let mut u_buffer: [u8; 32] = [0; 32];
        let mut v_buffer: [u8; 32] = [0; 32];

        std::ptr::copy_nonoverlapping(
            rgba0.get_unchecked(cx * channels..).as_ptr(),
            src_buffer0.as_mut_ptr().cast(),
            diff * channels,
        );
        std::ptr::copy_nonoverlapping(
            rgba1.get_unchecked(cx * channels..).as_ptr(),
            src_buffer1.as_mut_ptr().cast(),
            diff * channels,
        );

        // Replicate last item to one more position for subsampling
        if diff % 2 != 0 {
            let lst = (width - 1) * channels;
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

        encode_32_part::<ORIGIN_CHANNELS, PRECISION>(
            src_buffer0.as_slice(),
            src_buffer1.as_slice(),
            y_buffer0.as_mut_slice(),
            y_buffer1.as_mut_slice(),
            u_buffer.as_mut_slice(),
            v_buffer.as_mut_slice(),
            transform,
            range,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_ptr().cast(),
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );
        std::ptr::copy_nonoverlapping(
            y_buffer1.as_ptr().cast(),
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        cx += diff;

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

    ProcessedOffset { cx, ux: uv_x }
}
