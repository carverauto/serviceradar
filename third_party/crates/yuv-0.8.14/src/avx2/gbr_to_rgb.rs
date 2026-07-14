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
use crate::avx2::avx2_utils::{
    _mm256_expand8_unordered_to_10, _mm256_store_interleave_rgb_for_yuv,
};
use crate::yuv_support::YuvSourceChannels;
#[cfg(target_arch = "x86")]
use std::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

pub(crate) fn avx_yuv_to_rgba_row_full<const DESTINATION_CHANNELS: u8>(
    g_plane: &[u8],
    b_plane: &[u8],
    r_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) -> usize {
    unsafe {
        avx_yuv_to_rgba_row_full_impl::<DESTINATION_CHANNELS>(
            g_plane, b_plane, r_plane, rgba, start_cx, width,
        )
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx_yuv_to_rgba_row_full_impl<const DESTINATION_CHANNELS: u8>(
    g_plane: &[u8],
    b_plane: &[u8],
    r_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) -> usize {
    let mut cx = start_cx;

    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();

    let v_alpha = _mm256_set1_epi8(255u8 as i8);

    while cx + 32 <= width {
        let g_values = _mm256_loadu_si256(g_plane.get_unchecked(cx..).as_ptr() as *const _);
        let b_values = _mm256_loadu_si256(b_plane.get_unchecked(cx..).as_ptr() as *const _);
        let r_values = _mm256_loadu_si256(r_plane.get_unchecked(cx..).as_ptr() as *const _);

        let dst_shift = cx * destination_channels.get_channels_count();
        let rgba_ptr = rgba.get_unchecked_mut(dst_shift..);

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.as_mut_ptr(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 32;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 32);

        let mut g_buffer: [u8; 32] = [0; 32];
        let mut b_buffer: [u8; 32] = [0; 32];
        let mut r_buffer: [u8; 32] = [0; 32];
        let mut dst_buffer: [u8; 32 * 4] = [0; 32 * 4];

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

        let g_values = _mm256_loadu_si256(g_buffer.as_ptr() as *const _);
        let b_values = _mm256_loadu_si256(b_buffer.as_ptr() as *const _);
        let r_values = _mm256_loadu_si256(r_buffer.as_ptr() as *const _);

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        let dst_shift = cx * destination_channels.get_channels_count();
        let rgba_ptr = rgba.get_unchecked_mut(dst_shift..);
        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr(),
            rgba_ptr.as_mut_ptr().cast(),
            diff * destination_channels.get_channels_count(),
        );

        cx += diff;
    }

    cx
}

pub(crate) fn avx_yuv_to_rgba_row_limited<const DESTINATION_CHANNELS: u8>(
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
        avx_yuv_to_rgba_row_limited_impl::<DESTINATION_CHANNELS>(
            g_plane, b_plane, r_plane, rgba, start_cx, width, y_bias, y_coeff,
        )
    }
}

#[target_feature(enable = "avx2")]
unsafe fn avx_yuv_to_rgba_row_limited_impl<const DESTINATION_CHANNELS: u8>(
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

    let v_alpha = _mm256_set1_epi8(255u8 as i8);

    let vy_coeff = _mm256_set1_epi16(y_coeff as i16);
    let vy_bias = _mm256_set1_epi8(y_bias as i8);

    while cx + 32 <= width {
        let g0 = _mm256_loadu_si256(g_plane.get_unchecked(cx..).as_ptr() as *const _);
        let b0 = _mm256_loadu_si256(b_plane.get_unchecked(cx..).as_ptr() as *const _);
        let r0 = _mm256_loadu_si256(r_plane.get_unchecked(cx..).as_ptr() as *const _);

        let g_values0 = _mm256_subs_epu8(g0, vy_bias);
        let b_values0 = _mm256_subs_epu8(b0, vy_bias);
        let r_values0 = _mm256_subs_epu8(r0, vy_bias);

        let (r_y_lo, r_y_hi) = _mm256_expand8_unordered_to_10(r_values0);
        let (g_y_lo, g_y_hi) = _mm256_expand8_unordered_to_10(g_values0);
        let (b_y_lo, b_y_hi) = _mm256_expand8_unordered_to_10(b_values0);

        let rl_hi = _mm256_mulhrs_epi16(r_y_hi, vy_coeff);
        let gl_hi = _mm256_mulhrs_epi16(g_y_hi, vy_coeff);
        let bl_hi = _mm256_mulhrs_epi16(b_y_hi, vy_coeff);

        let rl_lo = _mm256_mulhrs_epi16(r_y_lo, vy_coeff);
        let gl_lo = _mm256_mulhrs_epi16(g_y_lo, vy_coeff);
        let bl_lo = _mm256_mulhrs_epi16(b_y_lo, vy_coeff);

        let r_values = _mm256_packus_epi16(rl_lo, rl_hi);
        let g_values = _mm256_packus_epi16(gl_lo, gl_hi);
        let b_values = _mm256_packus_epi16(bl_lo, bl_hi);

        let dst_shift = cx * destination_channels.get_channels_count();
        let rgba_ptr = rgba.get_unchecked_mut(dst_shift..);

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            rgba_ptr.as_mut_ptr(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 32;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 32);

        let mut g_buffer: [u8; 32] = [0; 32];
        let mut b_buffer: [u8; 32] = [0; 32];
        let mut r_buffer: [u8; 32] = [0; 32];
        let mut dst_buffer: [u8; 32 * 4] = [0; 32 * 4];

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

        let g0 = _mm256_loadu_si256(g_buffer.as_ptr() as *const _);
        let b0 = _mm256_loadu_si256(b_buffer.as_ptr() as *const _);
        let r0 = _mm256_loadu_si256(r_buffer.as_ptr() as *const _);

        let g_values0 = _mm256_subs_epu8(g0, vy_bias);
        let b_values0 = _mm256_subs_epu8(b0, vy_bias);
        let r_values0 = _mm256_subs_epu8(r0, vy_bias);

        let (r_y_lo, r_y_hi) = _mm256_expand8_unordered_to_10(r_values0);
        let (g_y_lo, g_y_hi) = _mm256_expand8_unordered_to_10(g_values0);
        let (b_y_lo, b_y_hi) = _mm256_expand8_unordered_to_10(b_values0);

        let rl_hi = _mm256_mulhrs_epi16(r_y_hi, vy_coeff);
        let gl_hi = _mm256_mulhrs_epi16(g_y_hi, vy_coeff);
        let bl_hi = _mm256_mulhrs_epi16(b_y_hi, vy_coeff);

        let rl_lo = _mm256_mulhrs_epi16(r_y_lo, vy_coeff);
        let gl_lo = _mm256_mulhrs_epi16(g_y_lo, vy_coeff);
        let bl_lo = _mm256_mulhrs_epi16(b_y_lo, vy_coeff);

        let r_values = _mm256_packus_epi16(rl_lo, rl_hi);
        let g_values = _mm256_packus_epi16(gl_lo, gl_hi);
        let b_values = _mm256_packus_epi16(bl_lo, bl_hi);

        _mm256_store_interleave_rgb_for_yuv::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        let dst_shift = cx * destination_channels.get_channels_count();
        let rgba_ptr = rgba.get_unchecked_mut(dst_shift..);
        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr(),
            rgba_ptr.as_mut_ptr().cast(),
            diff * destination_channels.get_channels_count(),
        );

        cx += diff;
    }

    cx
}
