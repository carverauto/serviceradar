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
    _mm_load_deinterleave_half_rgb_for_yuv, _mm_load_deinterleave_rgb_for_yuv,
    sse_pairwise_avg_epi8_j,
};
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_rgba_to_yuv_row420<const ORIGIN_CHANNELS: u8, const PRECISION: i32>(
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
        sse_rgba_to_yuv_row_impl420::<ORIGIN_CHANNELS, PRECISION>(
            transform, range, y_plane0, y_plane1, u_plane, v_plane, rgba0, rgba1, start_cx,
            start_ux, width,
        )
    }
}

#[inline(always)]
unsafe fn encode_8_part<const ORIGIN_CHANNELS: u8, const PRECISION: i32>(
    src0: &[u8],
    src1: &[u8],
    y_dst0: &mut [u8],
    y_dst1: &mut [u8],
    u_dst: &mut [u8],
    v_dst: &mut [u8],
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
) {
    let (r_values0, g_values0, b_values0) =
        _mm_load_deinterleave_half_rgb_for_yuv::<ORIGIN_CHANNELS>(src0.as_ptr());
    let (r_values1, g_values1, b_values1) =
        _mm_load_deinterleave_half_rgb_for_yuv::<ORIGIN_CHANNELS>(src1.as_ptr());

    const V_S: i32 = 4;
    const A_E: i32 = 2;
    let y_bias = _mm_set1_epi16(range.bias_y as i16 * (1 << A_E));
    let uv_bias = _mm_set1_epi16(range.bias_uv as i16 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let v_yr = _mm_set1_epi16(transform.yr as i16);
    let v_yg = _mm_set1_epi16(transform.yg as i16);
    let v_yb = _mm_set1_epi16(transform.yb as i16);

    let r0_lo16 = _mm_srli_epi16::<V_S>(_mm_unpacklo_epi8(r_values0, r_values0));
    let g0_lo16 = _mm_srli_epi16::<V_S>(_mm_unpacklo_epi8(g_values0, g_values0));
    let b0_lo16 = _mm_srli_epi16::<V_S>(_mm_unpacklo_epi8(b_values0, b_values0));

    let y0_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(
        y_bias,
        _mm_add_epi16(
            _mm_add_epi16(
                _mm_mulhrs_epi16(r0_lo16, v_yr),
                _mm_mulhrs_epi16(g0_lo16, v_yg),
            ),
            _mm_mulhrs_epi16(b0_lo16, v_yb),
        ),
    ));

    let y0_yuv = _mm_packus_epi16(y0_l, _mm_setzero_si128());
    _mm_storeu_si64(y_dst0.as_mut_ptr(), y0_yuv);

    let r1_lo = _mm_srli_epi16::<V_S>(_mm_unpacklo_epi8(r_values1, r_values1));
    let g1_lo = _mm_srli_epi16::<V_S>(_mm_unpacklo_epi8(g_values1, g_values1));
    let b1_lo = _mm_srli_epi16::<V_S>(_mm_unpacklo_epi8(b_values1, b_values1));

    let y1_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(
        y_bias,
        _mm_add_epi16(
            _mm_add_epi16(_mm_mulhrs_epi16(r1_lo, v_yr), _mm_mulhrs_epi16(g1_lo, v_yg)),
            _mm_mulhrs_epi16(b1_lo, v_yb),
        ),
    ));

    let y1_yuv = _mm_packus_epi16(y1_l, _mm_setzero_si128());

    _mm_storeu_si64(y_dst1.as_mut_ptr(), y1_yuv);

    let r1 = sse_pairwise_avg_epi8_j(_mm_avg_epu8(r_values0, r_values1), 1 << (16 - V_S - 8 - 1));
    let g1 = sse_pairwise_avg_epi8_j(_mm_avg_epu8(g_values0, g_values1), 1 << (16 - V_S - 8 - 1));
    let b1 = sse_pairwise_avg_epi8_j(_mm_avg_epu8(b_values0, b_values1), 1 << (16 - V_S - 8 - 1));

    let v_cb_r = _mm_set1_epi16(transform.cb_r as i16);
    let v_cb_g = _mm_set1_epi16(transform.cb_g as i16);
    let v_cb_b = _mm_set1_epi16(transform.cb_b as i16);
    let v_cr_r = _mm_set1_epi16(transform.cr_r as i16);
    let v_cr_g = _mm_set1_epi16(transform.cr_g as i16);
    let v_cr_b = _mm_set1_epi16(transform.cr_b as i16);

    let cbk = _mm_srli_epi16::<A_E>(_mm_add_epi16(
        uv_bias,
        _mm_add_epi16(
            _mm_add_epi16(_mm_mulhrs_epi16(r1, v_cb_r), _mm_mulhrs_epi16(g1, v_cb_g)),
            _mm_mulhrs_epi16(b1, v_cb_b),
        ),
    ));

    let crk = _mm_srli_epi16::<A_E>(_mm_add_epi16(
        uv_bias,
        _mm_add_epi16(
            _mm_add_epi16(_mm_mulhrs_epi16(r1, v_cr_r), _mm_mulhrs_epi16(g1, v_cr_g)),
            _mm_mulhrs_epi16(b1, v_cr_b),
        ),
    ));

    let cb = _mm_packus_epi16(cbk, cbk);
    let cr = _mm_packus_epi16(crk, crk);

    _mm_storeu_si32(u_dst.as_mut_ptr(), cb);
    _mm_storeu_si32(v_dst.as_mut_ptr(), cr);
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_rgba_to_yuv_row_impl420<const ORIGIN_CHANNELS: u8, const PRECISION: i32>(
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

    let u_ptr = u_plane.as_mut_ptr();
    let v_ptr = v_plane.as_mut_ptr();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    const V_S: i32 = 4;
    const A_E: i32 = 2;
    let y_bias = _mm_set1_epi16(range.bias_y as i16 * (1 << A_E));
    let uv_bias = _mm_set1_epi16(range.bias_uv as i16 * (1 << A_E) + (1 << (A_E - 1)) - 1);
    let v_yr = _mm_set1_epi16(transform.yr as i16);
    let v_yg = _mm_set1_epi16(transform.yg as i16);
    let v_yb = _mm_set1_epi16(transform.yb as i16);

    while cx + 16 < width {
        let px = cx * channels;

        let row_start0 = rgba0.get_unchecked(px..).as_ptr();
        let (r_values0, g_values0, b_values0) =
            _mm_load_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(row_start0);

        let r0lw = _mm_unpacklo_epi8(r_values0, r_values0);
        let r0hw = _mm_unpackhi_epi8(r_values0, r_values0);
        let g0lw = _mm_unpacklo_epi8(g_values0, g_values0);
        let g0hw = _mm_unpackhi_epi8(g_values0, g_values0);
        let b0lw = _mm_unpacklo_epi8(b_values0, b_values0);
        let b0hw = _mm_unpackhi_epi8(b_values0, b_values0);

        let r0_lo16 = _mm_srli_epi16::<V_S>(r0lw);
        let r0_hi16 = _mm_srli_epi16::<V_S>(r0hw);
        let g0_lo16 = _mm_srli_epi16::<V_S>(g0lw);
        let g0_hi16 = _mm_srli_epi16::<V_S>(g0hw);
        let b0_lo16 = _mm_srli_epi16::<V_S>(b0lw);
        let b0_hi16 = _mm_srli_epi16::<V_S>(b0hw);

        let y0_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(
            y_bias,
            _mm_add_epi16(
                _mm_add_epi16(
                    _mm_mulhrs_epi16(r0_lo16, v_yr),
                    _mm_mulhrs_epi16(g0_lo16, v_yg),
                ),
                _mm_mulhrs_epi16(b0_lo16, v_yb),
            ),
        ));

        let y0_h = _mm_srli_epi16::<A_E>(_mm_add_epi16(
            y_bias,
            _mm_add_epi16(
                _mm_add_epi16(
                    _mm_mulhrs_epi16(r0_hi16, v_yr),
                    _mm_mulhrs_epi16(g0_hi16, v_yg),
                ),
                _mm_mulhrs_epi16(b0_hi16, v_yb),
            ),
        ));

        let y0_yuv = _mm_packus_epi16(y0_l, y0_h);
        _mm_storeu_si128(
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr() as *mut __m128i,
            y0_yuv,
        );

        let row_start1 = rgba1.get_unchecked(px..).as_ptr();
        let (r_values1, g_values1, b_values1) =
            _mm_load_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(row_start1);

        let r1lw = _mm_unpacklo_epi8(r_values1, r_values1);
        let r1hw = _mm_unpackhi_epi8(r_values1, r_values1);
        let g1lw = _mm_unpacklo_epi8(g_values1, g_values1);
        let g1hw = _mm_unpackhi_epi8(g_values1, g_values1);
        let b1lw = _mm_unpacklo_epi8(b_values1, b_values1);
        let b1hw = _mm_unpackhi_epi8(b_values1, b_values1);

        let r1_lo = _mm_srli_epi16::<V_S>(r1lw);
        let r1_hi = _mm_srli_epi16::<V_S>(r1hw);
        let g1_lo = _mm_srli_epi16::<V_S>(g1lw);
        let g1_hi = _mm_srli_epi16::<V_S>(g1hw);
        let b1_lo = _mm_srli_epi16::<V_S>(b1lw);
        let b1_hi = _mm_srli_epi16::<V_S>(b1hw);

        let y1_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(
            y_bias,
            _mm_add_epi16(
                _mm_add_epi16(_mm_mulhrs_epi16(r1_lo, v_yr), _mm_mulhrs_epi16(g1_lo, v_yg)),
                _mm_mulhrs_epi16(b1_lo, v_yb),
            ),
        ));

        let y1_h = _mm_srli_epi16::<A_E>(_mm_add_epi16(
            y_bias,
            _mm_add_epi16(
                _mm_add_epi16(_mm_mulhrs_epi16(r1_hi, v_yr), _mm_mulhrs_epi16(g1_hi, v_yg)),
                _mm_mulhrs_epi16(b1_hi, v_yb),
            ),
        ));

        let y1_yuv = _mm_packus_epi16(y1_l, y1_h);
        _mm_storeu_si128(
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr() as *mut __m128i,
            y1_yuv,
        );

        let r_avg = _mm_avg_epu8(r_values0, r_values1);
        let g_avg = _mm_avg_epu8(g_values0, g_values1);
        let b_avg = _mm_avg_epu8(b_values0, b_values1);

        let r1 = sse_pairwise_avg_epi8_j(r_avg, 1 << (16 - V_S - 8 - 1));
        let g1 = sse_pairwise_avg_epi8_j(g_avg, 1 << (16 - V_S - 8 - 1));
        let b1 = sse_pairwise_avg_epi8_j(b_avg, 1 << (16 - V_S - 8 - 1));

        let v_cb_r = _mm_set1_epi16(transform.cb_r as i16);
        let v_cb_g = _mm_set1_epi16(transform.cb_g as i16);
        let v_cb_b = _mm_set1_epi16(transform.cb_b as i16);
        let v_cr_r = _mm_set1_epi16(transform.cr_r as i16);
        let v_cr_g = _mm_set1_epi16(transform.cr_g as i16);
        let v_cr_b = _mm_set1_epi16(transform.cr_b as i16);

        let cbrc = _mm_mulhrs_epi16(r1, v_cb_r);
        let crrc = _mm_mulhrs_epi16(r1, v_cr_r);
        let cbgc = _mm_mulhrs_epi16(g1, v_cb_g);
        let crgc = _mm_mulhrs_epi16(g1, v_cr_g);
        let cbbc = _mm_mulhrs_epi16(b1, v_cb_b);
        let crbc = _mm_mulhrs_epi16(b1, v_cr_b);

        let cbo = _mm_add_epi16(cbrc, cbgc);
        let cro = _mm_add_epi16(crrc, crgc);

        let cbl = _mm_add_epi16(cbo, cbbc);
        let crl = _mm_add_epi16(cro, crbc);

        let cbk = _mm_srli_epi16::<A_E>(_mm_add_epi16(uv_bias, cbl));
        let crk = _mm_srli_epi16::<A_E>(_mm_add_epi16(uv_bias, crl));

        let cb = _mm_packus_epi16(cbk, cbk);
        let cr = _mm_packus_epi16(crk, crk);

        _mm_storeu_si64(u_ptr.add(uv_x), cb);
        _mm_storeu_si64(v_ptr.add(uv_x), cr);

        uv_x += 8;
        cx += 16;
    }

    while cx + 8 < width {
        encode_8_part::<ORIGIN_CHANNELS, PRECISION>(
            rgba0.get_unchecked(cx * channels..),
            rgba1.get_unchecked(cx * channels..),
            y_plane0.get_unchecked_mut(cx..),
            y_plane1.get_unchecked_mut(cx..),
            u_plane.get_unchecked_mut(uv_x..),
            v_plane.get_unchecked_mut(uv_x..),
            transform,
            range,
        );

        uv_x += 4;
        cx += 8;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 8);

        let mut src_buffer0: [u8; 8 * 4] = [0; 8 * 4];
        let mut src_buffer1: [u8; 8 * 4] = [0; 8 * 4];
        let mut y_buffer0: [u8; 8] = [0; 8];
        let mut y_buffer1: [u8; 8] = [0; 8];
        let mut u_buffer: [u8; 8] = [0; 8];
        let mut v_buffer: [u8; 8] = [0; 8];

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

        encode_8_part::<ORIGIN_CHANNELS, PRECISION>(
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
