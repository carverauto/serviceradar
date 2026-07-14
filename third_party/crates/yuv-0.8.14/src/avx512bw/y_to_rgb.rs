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

use crate::avx512bw::avx512_utils::{_mm512_expand8_unordered_to_10, avx512_store_rgba_for_yuv_u8};
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvSourceChannels};
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx512_y_to_rgb_row<const DESTINATION_CHANNELS: u8, const HAS_VBMI: bool>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) {
    unsafe {
        if HAS_VBMI {
            avx512_y_to_rgb_bmi_row::<DESTINATION_CHANNELS>(
                range, transform, y_plane, rgba, start_cx, width,
            )
        } else {
            avx512_y_to_rgb_def_row::<DESTINATION_CHANNELS>(
                range, transform, y_plane, rgba, start_cx, width,
            )
        }
    }
}

#[target_feature(enable = "avx512bw", enable = "avx512f")]
unsafe fn avx512_y_to_rgb_def_row<const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) {
    avx512_y_to_rgb_row_impl::<DESTINATION_CHANNELS, false>(
        range, transform, y_plane, rgba, start_cx, width,
    )
}

#[target_feature(enable = "avx512bw", enable = "avx512f", enable = "avx512vbmi")]
unsafe fn avx512_y_to_rgb_bmi_row<const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) {
    avx512_y_to_rgb_row_impl::<DESTINATION_CHANNELS, true>(
        range, transform, y_plane, rgba, start_cx, width,
    )
}

#[inline(always)]
unsafe fn avx512_y_to_rgb_row_impl<const DESTINATION_CHANNELS: u8, const HAS_VBMI: bool>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = start_cx;
    let y_ptr = y_plane.as_ptr();
    let rgba_ptr = rgba.as_mut_ptr();

    let y_corr = _mm512_set1_epi8(range.bias_y as i8);
    let v_luma_coeff = _mm512_set1_epi16(transform.y_coef as i16);
    let v_alpha = _mm512_set1_epi8(255u8 as i8);

    while cx + 64 < width {
        let y_s = _mm512_subs_epi8(_mm512_loadu_si512(y_ptr.add(cx) as *const _), y_corr);

        let y10 = _mm512_expand8_unordered_to_10(y_s);

        let y_high = _mm512_mulhrs_epi16(y10.1, v_luma_coeff);

        let r_high = y_high;

        let y_low = _mm512_mulhrs_epi16(y10.0, v_luma_coeff);

        let r_low = y_low;

        let r_values = _mm512_packus_epi16(r_low, r_high);

        let dst_shift = cx * channels;

        avx512_store_rgba_for_yuv_u8::<DESTINATION_CHANNELS, HAS_VBMI>(
            rgba_ptr.add(dst_shift),
            r_values,
            r_values,
            r_values,
            v_alpha,
        );

        cx += 64;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 64);

        let mut y_buffer: [u8; 64] = [0; 64];
        let mut dst_buffer: [u8; 64 * 4] = [0; 64 * 4];
        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr(),
            diff,
        );

        let y_s = _mm512_subs_epi8(_mm512_loadu_si512(y_buffer.as_ptr() as *const _), y_corr);

        let y10 = _mm512_expand8_unordered_to_10(y_s);

        let y_high = _mm512_mulhrs_epi16(y10.1, v_luma_coeff);

        let r_high = y_high;

        let y_low = _mm512_mulhrs_epi16(y10.0, v_luma_coeff);

        let r_low = y_low;

        let r_values = _mm512_packus_epi16(r_low, r_high);

        avx512_store_rgba_for_yuv_u8::<DESTINATION_CHANNELS, HAS_VBMI>(
            dst_buffer.as_mut_ptr(),
            r_values,
            r_values,
            r_values,
            v_alpha,
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr(),
            rgba_ptr.add(dst_shift),
            diff * channels,
        );
    }
}
