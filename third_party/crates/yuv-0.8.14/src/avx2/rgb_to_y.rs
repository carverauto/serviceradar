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

use crate::avx2::avx2_utils::{_mm256_load_deinterleave_rgb_for_yuv, _mm256_sqrdmlah_dot};
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx2_rgb_to_y_row<const ORIGIN_CHANNELS: u8, const PRECISION: i32>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    width: usize,
) -> usize {
    unsafe {
        avx2_rgb_to_y_row_impl::<ORIGIN_CHANNELS, PRECISION>(
            transform, range, y_plane, rgba, start_cx, width,
        )
    }
}

#[target_feature(enable = "avx2")]
pub(crate) unsafe fn avx2_rgb_to_y_row_impl<const CN: u8, const PRECISION: i32>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    width: usize,
) -> usize {
    let source_channels: YuvSourceChannels = CN.into();
    let channels = source_channels.get_channels_count();

    let y_ptr = y_plane.as_mut_ptr();

    let mut cx = start_cx;

    const V_S: i32 = 4;
    const A_E: i32 = 2;
    let y_bias = _mm256_set1_epi16(range.bias_y as i16 * (1 << A_E));
    let v_yr = _mm256_set1_epi16(transform.yr as i16);
    let v_yg = _mm256_set1_epi16(transform.yg as i16);
    let v_yb = _mm256_set1_epi16(transform.yb as i16);

    while cx + 32 <= width {
        let px = cx * channels;
        let (r_values, g_values, b_values) =
            _mm256_load_deinterleave_rgb_for_yuv::<CN>(rgba.get_unchecked(px..).as_ptr());

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

        let y0_yuv = _mm256_sqrdmlah_dot::<A_E>(
            r_low, r_high, g_low, g_high, b_low, b_high, y_bias, v_yr, v_yg, v_yb,
        );

        _mm256_storeu_si256(y_ptr.add(cx) as *mut _, y0_yuv);

        cx += 32;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 32);
        let mut src_buffer: [u8; 32 * 4] = [0; 32 * 4];
        let mut y_buffer: [u8; 32] = [0; 32];

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

        let (r_values, g_values, b_values) =
            _mm256_load_deinterleave_rgb_for_yuv::<CN>(src_buffer.as_ptr().cast());

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

        let y0_yuv = _mm256_sqrdmlah_dot::<A_E>(
            r_low, r_high, g_low, g_high, b_low, b_high, y_bias, v_yr, v_yg, v_yb,
        );

        _mm256_storeu_si256(y_buffer.as_mut_ptr() as *mut _, y0_yuv);

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );
        cx += diff;
    }

    cx
}
