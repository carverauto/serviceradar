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
use crate::neon::utils::{neon_store_rgb8, vmullnq_s16};
use crate::yuv_support::YuvSourceChannels;
use std::arch::aarch64::*;

#[cfg(feature = "rdm")]
pub(crate) fn yuv_to_rgba_row_limited_rdm<const DESTINATION_CHANNELS: u8>(
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
        yuv_to_rgba_row_limited_impl_rdm::<DESTINATION_CHANNELS>(
            g_plane, b_plane, r_plane, rgba, start_cx, width, y_bias, y_coeff,
        )
    }
}

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
unsafe fn yuv_to_rgba_row_limited_impl_rdm<const DESTINATION_CHANNELS: u8>(
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

    let v_alpha = vdupq_n_u8(255u8);

    const V_SCALE: i32 = 2;

    let vy_coeff = vdupq_n_s16(y_coeff as i16);
    let vy_bias = vdupq_n_u8(y_bias as u8);

    while cx + 16 <= width {
        let g0 = vld1q_u8(g_plane.get_unchecked(cx..).as_ptr() as *const _);
        let b0 = vld1q_u8(b_plane.get_unchecked(cx..).as_ptr() as *const _);
        let r0 = vld1q_u8(r_plane.get_unchecked(cx..).as_ptr() as *const _);

        let g_values0 = vqsubq_u8(g0, vy_bias);
        let b_values0 = vqsubq_u8(b0, vy_bias);
        let r_values0 = vqsubq_u8(r0, vy_bias);

        let rllo0 = vshll_n_u8::<V_SCALE>(vget_low_u8(r_values0));
        let gllo0 = vshll_n_u8::<V_SCALE>(vget_low_u8(g_values0));
        let bllo0 = vshll_n_u8::<V_SCALE>(vget_low_u8(b_values0));
        let rlhi0 = vshll_high_n_u8::<V_SCALE>(r_values0);
        let glhi0 = vshll_high_n_u8::<V_SCALE>(g_values0);
        let blhi0 = vshll_high_n_u8::<V_SCALE>(b_values0);

        let rl_lo = vqrdmulhq_s16(vreinterpretq_s16_u16(rllo0), vy_coeff);
        let gl_lo = vqrdmulhq_s16(vreinterpretq_s16_u16(gllo0), vy_coeff);
        let bl_lo = vqrdmulhq_s16(vreinterpretq_s16_u16(bllo0), vy_coeff);

        let rl_hi = vqrdmulhq_s16(vreinterpretq_s16_u16(rlhi0), vy_coeff);
        let gl_hi = vqrdmulhq_s16(vreinterpretq_s16_u16(glhi0), vy_coeff);
        let bl_hi = vqrdmulhq_s16(vreinterpretq_s16_u16(blhi0), vy_coeff);

        let r_values = vcombine_u8(vqmovun_s16(rl_lo), vqmovun_s16(rl_hi));
        let g_values = vcombine_u8(vqmovun_s16(gl_lo), vqmovun_s16(gl_hi));
        let b_values = vcombine_u8(vqmovun_s16(bl_lo), vqmovun_s16(bl_hi));

        let dst_shift = cx * destination_channels.get_channels_count();
        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
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

        let g0 = vld1q_u8(g_buffer.as_ptr() as *const _);
        let b0 = vld1q_u8(b_buffer.as_ptr() as *const _);
        let r0 = vld1q_u8(r_buffer.as_ptr() as *const _);

        let g_values0 = vqsubq_u8(g0, vy_bias);
        let b_values0 = vqsubq_u8(b0, vy_bias);
        let r_values0 = vqsubq_u8(r0, vy_bias);

        let rllo0 = vshll_n_u8::<V_SCALE>(vget_low_u8(r_values0));
        let gllo0 = vshll_n_u8::<V_SCALE>(vget_low_u8(g_values0));
        let bllo0 = vshll_n_u8::<V_SCALE>(vget_low_u8(b_values0));
        let rlhi0 = vshll_high_n_u8::<V_SCALE>(r_values0);
        let glhi0 = vshll_high_n_u8::<V_SCALE>(g_values0);
        let blhi0 = vshll_high_n_u8::<V_SCALE>(b_values0);

        let rl_lo = vqrdmulhq_s16(vreinterpretq_s16_u16(rllo0), vy_coeff);
        let gl_lo = vqrdmulhq_s16(vreinterpretq_s16_u16(gllo0), vy_coeff);
        let bl_lo = vqrdmulhq_s16(vreinterpretq_s16_u16(bllo0), vy_coeff);

        let rl_hi = vqrdmulhq_s16(vreinterpretq_s16_u16(rlhi0), vy_coeff);
        let gl_hi = vqrdmulhq_s16(vreinterpretq_s16_u16(glhi0), vy_coeff);
        let bl_hi = vqrdmulhq_s16(vreinterpretq_s16_u16(blhi0), vy_coeff);

        let r_values = vcombine_u8(vqmovun_s16(rl_lo), vqmovun_s16(rl_hi));
        let g_values = vcombine_u8(vqmovun_s16(gl_lo), vqmovun_s16(gl_hi));
        let b_values = vcombine_u8(vqmovun_s16(bl_lo), vqmovun_s16(bl_hi));

        neon_store_rgb8::<DESTINATION_CHANNELS>(
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

pub(crate) fn yuv_to_rgba_row_limited<const DESTINATION_CHANNELS: u8, const PRECISION: i32>(
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
        let mut cx = start_cx;

        let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();

        let v_alpha = vdupq_n_u8(255u8);

        let vy_coeff = vdupq_n_u16(y_coeff as u16);
        let vy_bias = vdupq_n_u8(y_bias as u8);

        while cx + 16 <= width {
            let g0 = vld1q_u8(g_plane.get_unchecked(cx..).as_ptr() as *const _);
            let b0 = vld1q_u8(b_plane.get_unchecked(cx..).as_ptr() as *const _);
            let r0 = vld1q_u8(r_plane.get_unchecked(cx..).as_ptr() as *const _);

            let g_values0 = vqsubq_u8(g0, vy_bias);
            let b_values0 = vqsubq_u8(b0, vy_bias);
            let r_values0 = vqsubq_u8(r0, vy_bias);

            let rl0 = vmovl_u8(vget_low_u8(r_values0));
            let gl0 = vmovl_u8(vget_low_u8(g_values0));
            let bl0 = vmovl_u8(vget_low_u8(b_values0));
            let rh0 = vmovl_high_u8(r_values0);
            let gh0 = vmovl_high_u8(g_values0);
            let bh0 = vmovl_high_u8(b_values0);

            let rl_lo = vmullnq_s16::<PRECISION>(rl0, vy_coeff);
            let gl_lo = vmullnq_s16::<PRECISION>(gl0, vy_coeff);
            let bl_lo = vmullnq_s16::<PRECISION>(bl0, vy_coeff);

            let rl_hi = vmullnq_s16::<PRECISION>(rh0, vy_coeff);
            let gl_hi = vmullnq_s16::<PRECISION>(gh0, vy_coeff);
            let bl_hi = vmullnq_s16::<PRECISION>(bh0, vy_coeff);

            let r_values = vcombine_u8(vqmovn_u16(rl_lo), vqmovn_u16(rl_hi));
            let g_values = vcombine_u8(vqmovn_u16(gl_lo), vqmovn_u16(gl_hi));
            let b_values = vcombine_u8(vqmovn_u16(bl_lo), vqmovn_u16(bl_hi));

            let dst_shift = cx * destination_channels.get_channels_count();

            neon_store_rgb8::<DESTINATION_CHANNELS>(
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
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

            let g0 = vld1q_u8(g_buffer.as_ptr() as *const _);
            let b0 = vld1q_u8(b_buffer.as_ptr() as *const _);
            let r0 = vld1q_u8(r_buffer.as_ptr() as *const _);

            let g_values0 = vqsubq_u8(g0, vy_bias);
            let b_values0 = vqsubq_u8(b0, vy_bias);
            let r_values0 = vqsubq_u8(r0, vy_bias);

            let rl0 = vmovl_u8(vget_low_u8(r_values0));
            let gl0 = vmovl_u8(vget_low_u8(g_values0));
            let bl0 = vmovl_u8(vget_low_u8(b_values0));
            let rh0 = vmovl_high_u8(r_values0);
            let gh0 = vmovl_high_u8(g_values0);
            let bh0 = vmovl_high_u8(b_values0);

            let rl_lo = vmullnq_s16::<PRECISION>(rl0, vy_coeff);
            let gl_lo = vmullnq_s16::<PRECISION>(gl0, vy_coeff);
            let bl_lo = vmullnq_s16::<PRECISION>(bl0, vy_coeff);

            let rl_hi = vmullnq_s16::<PRECISION>(rh0, vy_coeff);
            let gl_hi = vmullnq_s16::<PRECISION>(gh0, vy_coeff);
            let bl_hi = vmullnq_s16::<PRECISION>(bh0, vy_coeff);

            let r_values = vcombine_u8(vqmovn_u16(rl_lo), vqmovn_u16(rl_hi));
            let g_values = vcombine_u8(vqmovn_u16(gl_lo), vqmovn_u16(gl_hi));
            let b_values = vcombine_u8(vqmovn_u16(bl_lo), vqmovn_u16(bl_hi));

            neon_store_rgb8::<DESTINATION_CHANNELS>(
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
}

pub(crate) fn yuv_to_rgba_row_full<const DESTINATION_CHANNELS: u8>(
    g_plane: &[u8],
    b_plane: &[u8],
    r_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) -> usize {
    unsafe {
        let mut cx = start_cx;

        let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();

        let v_alpha = vdupq_n_u8(255u8);

        while cx + 16 < width {
            let g_values = vld1q_u8(g_plane.get_unchecked(cx..).as_ptr() as *const _);
            let b_values = vld1q_u8(b_plane.get_unchecked(cx..).as_ptr() as *const _);
            let r_values = vld1q_u8(r_plane.get_unchecked(cx..).as_ptr() as *const _);

            let dst_shift = cx * destination_channels.get_channels_count();

            neon_store_rgb8::<DESTINATION_CHANNELS>(
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
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

            let g_values = vld1q_u8(g_buffer.as_ptr() as *const _);
            let b_values = vld1q_u8(b_buffer.as_ptr() as *const _);
            let r_values = vld1q_u8(r_buffer.as_ptr() as *const _);

            neon_store_rgb8::<DESTINATION_CHANNELS>(
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
}
