/*
 * Copyright (c) Radzivon Bartoshyk, 11/2024. All rights reserved.
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
use crate::sse::_mm_store_interleave_rgb_for_yuv;
use crate::yuv_support::YuvSourceChannels;
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn sse_yuv_to_rgba_row_full<const DESTINATION_CHANNELS: u8>(
    g_plane: &[u8],
    b_plane: &[u8],
    r_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) -> usize {
    unsafe {
        sse_yuv_to_rgba_row_full_impl::<DESTINATION_CHANNELS>(
            g_plane, b_plane, r_plane, rgba, start_cx, width,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_yuv_to_rgba_row_full_impl<const DESTINATION_CHANNELS: u8>(
    g_plane: &[u8],
    b_plane: &[u8],
    r_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) -> usize {
    let mut cx = start_cx;

    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();

    let v_alpha = _mm_set1_epi8(255u8 as i8);

    while cx + 16 < width {
        let g_values = _mm_loadu_si128(g_plane.get_unchecked(cx..).as_ptr() as *const _);
        let b_values = _mm_loadu_si128(b_plane.get_unchecked(cx..).as_ptr() as *const _);
        let r_values = _mm_loadu_si128(r_plane.get_unchecked(cx..).as_ptr() as *const _);

        let dst_shift = cx * destination_channels.get_channels_count();
        let rgba_ptr = rgba.get_unchecked_mut(dst_shift..);

        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.as_mut_ptr(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 16;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 16);

        let mut g_buffer: [u8; 16] = [0; 16];
        let mut b_buffer: [u8; 16] = [0; 16];
        let mut r_buffer: [u8; 16] = [0; 16];
        let mut dst_buffer: [u8; 16 * 4] = [0; 16 * 4];

        std::ptr::copy_nonoverlapping(
            g_plane.get_unchecked(cx..).as_ptr(),
            g_buffer.as_mut_ptr().cast(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            b_plane.get_unchecked(cx..).as_ptr(),
            b_buffer.as_mut_ptr().cast(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            r_plane.get_unchecked(cx..).as_ptr(),
            r_buffer.as_mut_ptr().cast(),
            diff,
        );

        let g_values = _mm_loadu_si128(g_buffer.as_ptr() as *const _);
        let b_values = _mm_loadu_si128(b_buffer.as_ptr() as *const _);
        let r_values = _mm_loadu_si128(r_buffer.as_ptr() as *const _);

        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        let dst_shift = cx * destination_channels.get_channels_count();
        let rgba_ptr = rgba.get_unchecked_mut(dst_shift..);
        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr().cast(),
            rgba_ptr.as_mut_ptr(),
            diff * destination_channels.get_channels_count(),
        );

        cx += diff;
    }

    cx
}

pub(crate) fn sse_yuv_to_rgba_row_limited<const DESTINATION_CHANNELS: u8>(
    g_plane: &[u8],
    b_plane: &[u8],
    r_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
    y_bias: i32,
    y_coeff: i32,
) -> usize {
    unsafe {
        sse_yuv_to_rgba_row_limited_impl::<DESTINATION_CHANNELS>(
            g_plane, b_plane, r_plane, rgba, start_cx, width, y_bias, y_coeff,
        )
    }
}

#[target_feature(enable = "sse4.1")]
unsafe fn sse_yuv_to_rgba_row_limited_impl<const DESTINATION_CHANNELS: u8>(
    g_plane: &[u8],
    b_plane: &[u8],
    r_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
    y_bias: i32,
    y_coeff: i32,
) -> usize {
    let mut cx = start_cx;

    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();

    let v_alpha = _mm_set1_epi8(255u8 as i8);

    let vy_coeff = _mm_set1_epi16(y_coeff as i16);
    let vy_bias = _mm_set1_epi8(y_bias as i8);

    while cx + 16 < width {
        let g_vl0 = _mm_loadu_si128(g_plane.get_unchecked(cx..).as_ptr() as *const _);
        let b_vl0 = _mm_loadu_si128(b_plane.get_unchecked(cx..).as_ptr() as *const _);
        let r_vl0 = _mm_loadu_si128(r_plane.get_unchecked(cx..).as_ptr() as *const _);

        let g_values0 = _mm_subs_epu8(g_vl0, vy_bias);
        let b_values0 = _mm_subs_epu8(b_vl0, vy_bias);
        let r_values0 = _mm_subs_epu8(r_vl0, vy_bias);

        let rlhs = _mm_unpackhi_epi8(r_values0, r_values0);
        let glhs = _mm_unpackhi_epi8(g_values0, g_values0);
        let blhs = _mm_unpackhi_epi8(b_values0, b_values0);

        let rlls = _mm_unpacklo_epi8(r_values0, r_values0);
        let glls = _mm_unpacklo_epi8(g_values0, g_values0);
        let blls = _mm_unpacklo_epi8(b_values0, b_values0);

        let rl_hi = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(rlhs), vy_coeff);
        let gl_hi = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(glhs), vy_coeff);
        let bl_hi = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(blhs), vy_coeff);

        let rl_lo = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(rlls), vy_coeff);
        let gl_lo = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(glls), vy_coeff);
        let bl_lo = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(blls), vy_coeff);

        let r_values = _mm_packus_epi16(rl_lo, rl_hi);
        let g_values = _mm_packus_epi16(gl_lo, gl_hi);
        let b_values = _mm_packus_epi16(bl_lo, bl_hi);

        let dst_shift = cx * destination_channels.get_channels_count();
        let rgba_ptr = rgba.get_unchecked_mut(dst_shift..);

        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.as_mut_ptr(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 16;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 16);

        let mut g_buffer: [u8; 16] = [0; 16];
        let mut b_buffer: [u8; 16] = [0; 16];
        let mut r_buffer: [u8; 16] = [0; 16];
        let mut dst_buffer: [u8; 16 * 4] = [0; 16 * 4];

        std::ptr::copy_nonoverlapping(
            g_plane.get_unchecked(cx..).as_ptr(),
            g_buffer.as_mut_ptr().cast(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            b_plane.get_unchecked(cx..).as_ptr(),
            b_buffer.as_mut_ptr().cast(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            r_plane.get_unchecked(cx..).as_ptr(),
            r_buffer.as_mut_ptr().cast(),
            diff,
        );

        let g_vl0 = _mm_loadu_si128(g_buffer.as_ptr() as *const _);
        let b_vl0 = _mm_loadu_si128(b_buffer.as_ptr() as *const _);
        let r_vl0 = _mm_loadu_si128(r_buffer.as_ptr() as *const _);

        let g_values0 = _mm_subs_epu8(g_vl0, vy_bias);
        let b_values0 = _mm_subs_epu8(b_vl0, vy_bias);
        let r_values0 = _mm_subs_epu8(r_vl0, vy_bias);

        let rlhs = _mm_unpackhi_epi8(r_values0, r_values0);
        let glhs = _mm_unpackhi_epi8(g_values0, g_values0);
        let blhs = _mm_unpackhi_epi8(b_values0, b_values0);

        let rlls = _mm_unpacklo_epi8(r_values0, r_values0);
        let glls = _mm_unpacklo_epi8(g_values0, g_values0);
        let blls = _mm_unpacklo_epi8(b_values0, b_values0);

        let rl_hi = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(rlhs), vy_coeff);
        let gl_hi = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(glhs), vy_coeff);
        let bl_hi = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(blhs), vy_coeff);

        let rl_lo = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(rlls), vy_coeff);
        let gl_lo = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(glls), vy_coeff);
        let bl_lo = _mm_mulhrs_epi16(_mm_srli_epi16::<6>(blls), vy_coeff);

        let r_values = _mm_packus_epi16(rl_lo, rl_hi);
        let g_values = _mm_packus_epi16(gl_lo, gl_hi);
        let b_values = _mm_packus_epi16(bl_lo, bl_hi);

        _mm_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        let dst_shift = cx * destination_channels.get_channels_count();
        let rgba_ptr = rgba.get_unchecked_mut(dst_shift..);
        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr().cast(),
            rgba_ptr.as_mut_ptr(),
            diff * destination_channels.get_channels_count(),
        );

        cx += diff;
    }

    cx
}
