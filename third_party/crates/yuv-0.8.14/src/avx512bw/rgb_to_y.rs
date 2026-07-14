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

use crate::avx512bw::avx512_utils::avx512_load_rgb_u8;
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx512_row_rgb_to_y<const ORIGIN_CHANNELS: u8, const HAS_VBMI: bool>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    width: usize,
) -> usize {
    unsafe {
        if HAS_VBMI {
            avx512_row_rgb_to_y_bmi_impl::<ORIGIN_CHANNELS>(
                transform, range, y_plane, rgba, start_cx, width,
            )
        } else {
            avx512_row_rgb_to_y_def_impl::<ORIGIN_CHANNELS>(
                transform, range, y_plane, rgba, start_cx, width,
            )
        }
    }
}

#[target_feature(enable = "avx512bw", enable = "avx512f")]
unsafe fn avx512_row_rgb_to_y_def_impl<const ORIGIN_CHANNELS: u8>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    width: usize,
) -> usize {
    avx512_row_rgb_to_y_impl::<ORIGIN_CHANNELS, false>(
        transform, range, y_plane, rgba, start_cx, width,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512f", enable = "avx512vbmi")]
unsafe fn avx512_row_rgb_to_y_bmi_impl<const ORIGIN_CHANNELS: u8>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: &mut [u8],
    rgba: &[u8],
    start_cx: usize,
    width: usize,
) -> usize {
    avx512_row_rgb_to_y_impl::<ORIGIN_CHANNELS, true>(
        transform, range, y_plane, rgba, start_cx, width,
    )
}

#[inline(always)]
unsafe fn avx512_row_rgb_to_y_impl<const ORIGIN_CHANNELS: u8, const HAS_VBMI: bool>(
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

    const V_S: u32 = 4;
    const A_E: u32 = 2;
    let y_bias = _mm512_set1_epi16(range.bias_y as i16 * (1 << A_E));
    let v_yr = _mm512_set1_epi16(transform.yr as i16);
    let v_yg = _mm512_set1_epi16(transform.yg as i16);
    let v_yb = _mm512_set1_epi16(transform.yb as i16);

    while cx + 64 < width {
        let px = cx * channels;

        let (r_values, g_values, b_values) =
            avx512_load_rgb_u8::<ORIGIN_CHANNELS, HAS_VBMI>(rgba.get_unchecked(px..).as_ptr());

        let rlw = _mm512_unpacklo_epi8(r_values, r_values);
        let rhw = _mm512_unpackhi_epi8(r_values, r_values);
        let glw = _mm512_unpacklo_epi8(g_values, g_values);
        let ghw = _mm512_unpackhi_epi8(g_values, g_values);
        let blw = _mm512_unpacklo_epi8(b_values, b_values);
        let bhw = _mm512_unpackhi_epi8(b_values, b_values);

        let r_low = _mm512_srli_epi16::<V_S>(rlw);
        let r_high = _mm512_srli_epi16::<V_S>(rhw);
        let g_low = _mm512_srli_epi16::<V_S>(glw);
        let g_high = _mm512_srli_epi16::<V_S>(ghw);
        let b_low = _mm512_srli_epi16::<V_S>(blw);
        let b_high = _mm512_srli_epi16::<V_S>(bhw);

        let rly = _mm512_mulhrs_epi16(r_low, v_yr);
        let gly = _mm512_mulhrs_epi16(g_low, v_yg);
        let bly = _mm512_mulhrs_epi16(b_low, v_yb);
        let rhy = _mm512_mulhrs_epi16(r_high, v_yr);
        let ghy = _mm512_mulhrs_epi16(g_high, v_yg);
        let bhy = _mm512_mulhrs_epi16(b_high, v_yb);

        let ylc = _mm512_add_epi16(rly, gly);
        let yhc = _mm512_add_epi16(rhy, ghy);

        let ylw = _mm512_add_epi16(ylc, bly);
        let yhw = _mm512_add_epi16(yhc, bhy);

        let y_l = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(y_bias, ylw));
        let y_h = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(y_bias, yhw));

        let y_yuv = _mm512_packus_epi16(y_l, y_h);

        _mm512_storeu_si512(
            y_plane.get_unchecked_mut(cx..).as_mut_ptr() as *mut _,
            y_yuv,
        );

        cx += 64;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 64);
        let mut src_buffer: [u8; 64 * 4] = [0; 64 * 4];
        let mut y_buffer: [u8; 64] = [0; 64];

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr(),
            diff * channels,
        );

        let (r_values, g_values, b_values) =
            avx512_load_rgb_u8::<ORIGIN_CHANNELS, HAS_VBMI>(src_buffer.as_ptr());

        let rlw = _mm512_unpacklo_epi8(r_values, r_values);
        let rhw = _mm512_unpackhi_epi8(r_values, r_values);
        let glw = _mm512_unpacklo_epi8(g_values, g_values);
        let ghw = _mm512_unpackhi_epi8(g_values, g_values);
        let blw = _mm512_unpacklo_epi8(b_values, b_values);
        let bhw = _mm512_unpackhi_epi8(b_values, b_values);

        let r_low = _mm512_srli_epi16::<V_S>(rlw);
        let r_high = _mm512_srli_epi16::<V_S>(rhw);
        let g_low = _mm512_srli_epi16::<V_S>(glw);
        let g_high = _mm512_srli_epi16::<V_S>(ghw);
        let b_low = _mm512_srli_epi16::<V_S>(blw);
        let b_high = _mm512_srli_epi16::<V_S>(bhw);

        let rly = _mm512_mulhrs_epi16(r_low, v_yr);
        let gly = _mm512_mulhrs_epi16(g_low, v_yg);
        let bly = _mm512_mulhrs_epi16(b_low, v_yb);
        let rhy = _mm512_mulhrs_epi16(r_high, v_yr);
        let ghy = _mm512_mulhrs_epi16(g_high, v_yg);
        let bhy = _mm512_mulhrs_epi16(b_high, v_yb);

        let ylc = _mm512_add_epi16(rly, gly);
        let yhc = _mm512_add_epi16(rhy, ghy);

        let ylw = _mm512_add_epi16(ylc, bly);
        let yhw = _mm512_add_epi16(yhc, bhy);

        let y_l = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(y_bias, ylw));
        let y_h = _mm512_srli_epi16::<A_E>(_mm512_add_epi16(y_bias, yhw));

        let y_yuv = _mm512_packus_epi16(y_l, y_h);

        _mm512_storeu_si512(y_buffer.as_mut_ptr() as *mut _, y_yuv);

        std::ptr::copy_nonoverlapping(
            y_buffer.as_ptr(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );
        cx += diff;
    }

    cx
}
