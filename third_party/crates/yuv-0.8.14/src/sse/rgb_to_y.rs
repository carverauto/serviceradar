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

use crate::sse::{_mm_load_deinterleave_half_rgb_for_yuv, _mm_load_deinterleave_rgb_for_yuv};
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_rgb_to_y<const ORIGIN_CHANNELS: u8, const PRECISION: i32>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    width: usize,
) -> usize {
    unsafe {
        sse_rgb_to_y_impl::<ORIGIN_CHANNELS, PRECISION>(
            transform, range, y_plane, rgba, start_cx, width,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_rgb_to_y_impl<const ORIGIN_CHANNELS: u8, const PRECISION: i32>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    width: usize,
) -> usize {
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    let mut cx = start_cx;

    const V_S: i32 = 4;
    const A_E: i32 = 2;
    let y_bias = _mm_set1_epi16(range.bias_y as i16 * (1 << A_E));
    let v_yr = _mm_set1_epi16(transform.yr as i16);
    let v_yg = _mm_set1_epi16(transform.yg as i16);
    let v_yb = _mm_set1_epi16(transform.yb as i16);

    while cx + 16 < width {
        let px = cx * channels;
        let (r_values, g_values, b_values) =
            _mm_load_deinterleave_rgb_for_yuv::<ORIGIN_CHANNELS>(rgba.get_unchecked(px..).as_ptr());

        let rl = _mm_unpacklo_epi8(r_values, r_values);
        let rh = _mm_unpackhi_epi8(r_values, r_values);
        let gl = _mm_unpacklo_epi8(g_values, g_values);
        let gh = _mm_unpackhi_epi8(g_values, g_values);
        let bl = _mm_unpacklo_epi8(b_values, b_values);
        let bh = _mm_unpackhi_epi8(b_values, b_values);

        let r_low = _mm_srli_epi16::<V_S>(rl);
        let r_high = _mm_srli_epi16::<V_S>(rh);
        let g_low = _mm_srli_epi16::<V_S>(gl);
        let g_high = _mm_srli_epi16::<V_S>(gh);
        let b_low = _mm_srli_epi16::<V_S>(bl);
        let b_high = _mm_srli_epi16::<V_S>(bh);

        let rlc = _mm_mulhrs_epi16(r_low, v_yr);
        let glc = _mm_mulhrs_epi16(g_low, v_yg);
        let blc = _mm_mulhrs_epi16(b_low, v_yb);
        let rhc = _mm_mulhrs_epi16(r_high, v_yr);
        let ghc = _mm_mulhrs_epi16(g_high, v_yg);
        let bhc = _mm_mulhrs_epi16(b_high, v_yb);

        let ylc = _mm_add_epi16(rlc, glc);
        let yhc = _mm_add_epi16(rhc, ghc);

        let y_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(y_bias, _mm_add_epi16(ylc, blc)));

        let y_h = _mm_srli_epi16::<A_E>(_mm_add_epi16(y_bias, _mm_add_epi16(yhc, bhc)));

        let y_yuv = _mm_packus_epi16(y_l, y_h);

        _mm_storeu_si128(
            y_plane.get_unchecked_mut(cx..).as_mut_ptr() as *mut __m128i,
            y_yuv,
        );

        cx += 16;
    }

    while cx + 8 < width {
        let px = cx * channels;

        let (r_values, g_values, b_values) = _mm_load_deinterleave_half_rgb_for_yuv::<
            ORIGIN_CHANNELS,
        >(rgba.get_unchecked(px..).as_ptr());

        let rw = _mm_unpacklo_epi8(r_values, r_values);
        let gw = _mm_unpacklo_epi8(g_values, g_values);
        let bw = _mm_unpacklo_epi8(b_values, b_values);

        let r_low = _mm_srli_epi16::<V_S>(rw);
        let g_low = _mm_srli_epi16::<V_S>(gw);
        let b_low = _mm_srli_epi16::<V_S>(bw);

        let rlc = _mm_mulhrs_epi16(r_low, v_yr);
        let glc = _mm_mulhrs_epi16(g_low, v_yg);
        let blc = _mm_mulhrs_epi16(b_low, v_yb);

        let y_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(
            y_bias,
            _mm_add_epi16(_mm_add_epi16(rlc, glc), blc),
        ));

        let y_yuv = _mm_packus_epi16(y_l, _mm_setzero_si128());
        _mm_storeu_si64(y_plane.get_unchecked_mut(cx..).as_mut_ptr(), y_yuv);

        cx += 8;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 8);
        let mut src_buffer: [u8; 8 * 4] = [0; 8 * 4];
        let mut y_buffer: [u8; 8] = [0; 8];

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

        let (r_values, g_values, b_values) =
            _mm_load_deinterleave_half_rgb_for_yuv::<ORIGIN_CHANNELS>(src_buffer.as_ptr().cast());

        let rw = _mm_unpacklo_epi8(r_values, r_values);
        let gw = _mm_unpacklo_epi8(g_values, g_values);
        let bw = _mm_unpacklo_epi8(b_values, b_values);

        let r_low = _mm_srli_epi16::<V_S>(rw);
        let g_low = _mm_srli_epi16::<V_S>(gw);
        let b_low = _mm_srli_epi16::<V_S>(bw);

        let rlc = _mm_mulhrs_epi16(r_low, v_yr);
        let glc = _mm_mulhrs_epi16(g_low, v_yg);
        let blc = _mm_mulhrs_epi16(b_low, v_yb);

        let y_l = _mm_srli_epi16::<A_E>(_mm_add_epi16(
            y_bias,
            _mm_add_epi16(_mm_add_epi16(rlc, glc), blc),
        ));

        let y_yuv = _mm_packus_epi16(y_l, _mm_setzero_si128());
        _mm_storeu_si64(y_buffer.as_mut_ptr().cast(), y_yuv);

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );
        cx += diff;
    }

    cx
}
