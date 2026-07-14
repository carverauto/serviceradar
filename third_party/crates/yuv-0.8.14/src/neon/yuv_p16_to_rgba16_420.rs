/*
 * Copyright (c) Radzivon Bartoshyk, 04/2026. All rights reserved.
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

use crate::neon::utils::*;
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvSourceChannels};
use std::arch::aarch64::*;

pub(crate) fn neon_yuv_p16_to_rgba16_row420<
    const DESTINATION_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr0: &[u16],
    y_ld_ptr1: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    rgba0: &mut [u16],
    rgba1: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    unsafe {
        neon_yuv_p16_to_rgba16_row420_impl::<
            DESTINATION_CHANNELS,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >(
            y_ld_ptr0, y_ld_ptr1, u_ld_ptr, v_ld_ptr, rgba0, rgba1, width, range, transform,
        )
    }
}

#[target_feature(enable = "neon")]
unsafe fn neon_yuv_p16_to_rgba16_row420_impl<
    const DESTINATION_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr0: &[u16],
    y_ld_ptr1: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    rgba0: &mut [u16],
    rgba1: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let y_corr = vdupq_n_u16(range.bias_y as u16);
    let uv_corr = vdupq_n_u16(range.bias_uv as u16);

    let weights_arr: [i16; 8] = [
        transform.y_coef as i16,
        transform.cr_coef as i16,
        transform.cb_coef as i16,
        -transform.g_coeff_1 as i16,
        -transform.g_coeff_2 as i16,
        0,
        0,
        0,
    ];

    let v_weights = vld1q_s16(weights_arr.as_ptr());

    let v_alpha = vdupq_n_u16(((1u32 << BIT_DEPTH) - 1u32) as u16);

    let base_val = vdupq_n_u32(1 << (PRECISION - 1));

    let mut cx = 0usize;
    let mut ux = 0usize;

    while cx + 16 <= width as usize {
        // --- load and expand chroma (shared for both rows) ---
        let mut u_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
            u_ld_ptr.get_unchecked(ux..).as_ptr(),
        );
        let mut v_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
            v_ld_ptr.get_unchecked(ux..).as_ptr(),
        );
        u_values_l = vreinterpretq_s16_u16(vsubq_u16(vreinterpretq_u16_s16(u_values_l), uv_corr));
        v_values_l = vreinterpretq_s16_u16(vsubq_u16(vreinterpretq_u16_s16(v_values_l), uv_corr));

        let u_values0 = vzip1q_s16(u_values_l, u_values_l);
        let v_values0 = vzip1q_s16(v_values_l, v_values_l);
        let u_values1 = vzip2q_s16(u_values_l, u_values_l);
        let v_values1 = vzip2q_s16(v_values_l, v_values_l);

        // --- row 0 ---
        let y_values0_r0 = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr0.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        );
        let y_values1_r0 = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr0.get_unchecked((cx + 8)..).as_ptr(),
            )),
            y_corr,
        );

        let y_high0_r0 = vreinterpretq_s32_u32(vmlal_high_laneq_u16::<0>(
            base_val,
            y_values0_r0,
            vreinterpretq_u16_s16(v_weights),
        ));
        let y_high1_r0 = vreinterpretq_s32_u32(vmlal_high_laneq_u16::<0>(
            base_val,
            y_values1_r0,
            vreinterpretq_u16_s16(v_weights),
        ));

        let rh0_r0 = vmlal_high_laneq_s16::<1>(y_high0_r0, v_values0, v_weights);
        let bh0_r0 = vmlal_high_laneq_s16::<2>(y_high0_r0, u_values0, v_weights);
        let gh0_r0 = vmlal_high_laneq_s16::<3>(y_high0_r0, v_values0, v_weights);
        let rh1_r0 = vmlal_high_laneq_s16::<1>(y_high1_r0, v_values1, v_weights);
        let bh1_r0 = vmlal_high_laneq_s16::<2>(y_high1_r0, u_values1, v_weights);
        let gh1_r0 = vmlal_high_laneq_s16::<3>(y_high1_r0, v_values1, v_weights);

        let r_high0_r0 = vqshrun_n_s32::<PRECISION>(rh0_r0);
        let b_high0_r0 = vqshrun_n_s32::<PRECISION>(bh0_r0);
        let g_high0_r0 =
            vqshrun_n_s32::<PRECISION>(vmlal_high_laneq_s16::<4>(gh0_r0, u_values0, v_weights));
        let r_high1_r0 = vqshrun_n_s32::<PRECISION>(rh1_r0);
        let b_high1_r0 = vqshrun_n_s32::<PRECISION>(bh1_r0);
        let g_high1_r0 =
            vqshrun_n_s32::<PRECISION>(vmlal_high_laneq_s16::<4>(gh1_r0, u_values1, v_weights));

        let y_low0_r0 = vreinterpretq_s32_u32(vmlal_laneq_u16::<0>(
            base_val,
            vget_low_u16(y_values0_r0),
            vreinterpretq_u16_s16(v_weights),
        ));
        let y_low1_r0 = vreinterpretq_s32_u32(vmlal_laneq_u16::<0>(
            base_val,
            vget_low_u16(y_values1_r0),
            vreinterpretq_u16_s16(v_weights),
        ));

        let rl0_r0 = vmlal_laneq_s16::<1>(y_low0_r0, vget_low_s16(v_values0), v_weights);
        let bl0_r0 = vmlal_laneq_s16::<2>(y_low0_r0, vget_low_s16(u_values0), v_weights);
        let gl0_r0 = vmlal_laneq_s16::<3>(y_low0_r0, vget_low_s16(v_values0), v_weights);
        let rl1_r0 = vmlal_laneq_s16::<1>(y_low1_r0, vget_low_s16(v_values1), v_weights);
        let bl1_r0 = vmlal_laneq_s16::<2>(y_low1_r0, vget_low_s16(u_values1), v_weights);
        let gl1_r0 = vmlal_laneq_s16::<3>(y_low1_r0, vget_low_s16(v_values1), v_weights);

        let r_low0_r0 = vqshrun_n_s32::<PRECISION>(rl0_r0);
        let b_low0_r0 = vqshrun_n_s32::<PRECISION>(bl0_r0);
        let g_low0_r0 = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(
            gl0_r0,
            vget_low_s16(u_values0),
            v_weights,
        ));
        let r_low1_r0 = vqshrun_n_s32::<PRECISION>(rl1_r0);
        let b_low1_r0 = vqshrun_n_s32::<PRECISION>(bl1_r0);
        let g_low1_r0 = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(
            gl1_r0,
            vget_low_s16(u_values1),
            v_weights,
        ));

        let r_values0_r0 = if BIT_DEPTH == 16 {
            vcombine_u16(r_low0_r0, r_high0_r0)
        } else {
            vminq_u16(vcombine_u16(r_low0_r0, r_high0_r0), v_alpha)
        };
        let g_values0_r0 = if BIT_DEPTH == 16 {
            vcombine_u16(g_low0_r0, g_high0_r0)
        } else {
            vminq_u16(vcombine_u16(g_low0_r0, g_high0_r0), v_alpha)
        };
        let b_values0_r0 = if BIT_DEPTH == 16 {
            vcombine_u16(b_low0_r0, b_high0_r0)
        } else {
            vminq_u16(vcombine_u16(b_low0_r0, b_high0_r0), v_alpha)
        };
        let r_values1_r0 = if BIT_DEPTH == 16 {
            vcombine_u16(r_low1_r0, r_high1_r0)
        } else {
            vminq_u16(vcombine_u16(r_low1_r0, r_high1_r0), v_alpha)
        };
        let g_values1_r0 = if BIT_DEPTH == 16 {
            vcombine_u16(g_low1_r0, g_high1_r0)
        } else {
            vminq_u16(vcombine_u16(g_low1_r0, g_high1_r0), v_alpha)
        };
        let b_values1_r0 = if BIT_DEPTH == 16 {
            vcombine_u16(b_low1_r0, b_high1_r0)
        } else {
            vminq_u16(vcombine_u16(b_low1_r0, b_high1_r0), v_alpha)
        };

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values0_r0,
            g_values0_r0,
            b_values0_r0,
            v_alpha,
        );
        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut((cx + 8) * channels..).as_mut_ptr(),
            r_values1_r0,
            g_values1_r0,
            b_values1_r0,
            v_alpha,
        );

        // --- row 1 (same chroma u_values0/1, v_values0/1) ---
        let y_values0_r1 = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr1.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        );
        let y_values1_r1 = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr1.get_unchecked((cx + 8)..).as_ptr(),
            )),
            y_corr,
        );

        let y_high0_r1 = vreinterpretq_s32_u32(vmlal_high_laneq_u16::<0>(
            base_val,
            y_values0_r1,
            vreinterpretq_u16_s16(v_weights),
        ));
        let y_high1_r1 = vreinterpretq_s32_u32(vmlal_high_laneq_u16::<0>(
            base_val,
            y_values1_r1,
            vreinterpretq_u16_s16(v_weights),
        ));

        let rh0_r1 = vmlal_high_laneq_s16::<1>(y_high0_r1, v_values0, v_weights);
        let bh0_r1 = vmlal_high_laneq_s16::<2>(y_high0_r1, u_values0, v_weights);
        let gh0_r1 = vmlal_high_laneq_s16::<3>(y_high0_r1, v_values0, v_weights);
        let rh1_r1 = vmlal_high_laneq_s16::<1>(y_high1_r1, v_values1, v_weights);
        let bh1_r1 = vmlal_high_laneq_s16::<2>(y_high1_r1, u_values1, v_weights);
        let gh1_r1 = vmlal_high_laneq_s16::<3>(y_high1_r1, v_values1, v_weights);

        let r_high0_r1 = vqshrun_n_s32::<PRECISION>(rh0_r1);
        let b_high0_r1 = vqshrun_n_s32::<PRECISION>(bh0_r1);
        let g_high0_r1 =
            vqshrun_n_s32::<PRECISION>(vmlal_high_laneq_s16::<4>(gh0_r1, u_values0, v_weights));
        let r_high1_r1 = vqshrun_n_s32::<PRECISION>(rh1_r1);
        let b_high1_r1 = vqshrun_n_s32::<PRECISION>(bh1_r1);
        let g_high1_r1 =
            vqshrun_n_s32::<PRECISION>(vmlal_high_laneq_s16::<4>(gh1_r1, u_values1, v_weights));

        let y_low0_r1 = vreinterpretq_s32_u32(vmlal_laneq_u16::<0>(
            base_val,
            vget_low_u16(y_values0_r1),
            vreinterpretq_u16_s16(v_weights),
        ));
        let y_low1_r1 = vreinterpretq_s32_u32(vmlal_laneq_u16::<0>(
            base_val,
            vget_low_u16(y_values1_r1),
            vreinterpretq_u16_s16(v_weights),
        ));

        let rl0_r1 = vmlal_laneq_s16::<1>(y_low0_r1, vget_low_s16(v_values0), v_weights);
        let bl0_r1 = vmlal_laneq_s16::<2>(y_low0_r1, vget_low_s16(u_values0), v_weights);
        let gl0_r1 = vmlal_laneq_s16::<3>(y_low0_r1, vget_low_s16(v_values0), v_weights);
        let rl1_r1 = vmlal_laneq_s16::<1>(y_low1_r1, vget_low_s16(v_values1), v_weights);
        let bl1_r1 = vmlal_laneq_s16::<2>(y_low1_r1, vget_low_s16(u_values1), v_weights);
        let gl1_r1 = vmlal_laneq_s16::<3>(y_low1_r1, vget_low_s16(v_values1), v_weights);

        let r_low0_r1 = vqshrun_n_s32::<PRECISION>(rl0_r1);
        let b_low0_r1 = vqshrun_n_s32::<PRECISION>(bl0_r1);
        let g_low0_r1 = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(
            gl0_r1,
            vget_low_s16(u_values0),
            v_weights,
        ));
        let r_low1_r1 = vqshrun_n_s32::<PRECISION>(rl1_r1);
        let b_low1_r1 = vqshrun_n_s32::<PRECISION>(bl1_r1);
        let g_low1_r1 = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(
            gl1_r1,
            vget_low_s16(u_values1),
            v_weights,
        ));

        let r_values0_r1 = if BIT_DEPTH == 16 {
            vcombine_u16(r_low0_r1, r_high0_r1)
        } else {
            vminq_u16(vcombine_u16(r_low0_r1, r_high0_r1), v_alpha)
        };
        let g_values0_r1 = if BIT_DEPTH == 16 {
            vcombine_u16(g_low0_r1, g_high0_r1)
        } else {
            vminq_u16(vcombine_u16(g_low0_r1, g_high0_r1), v_alpha)
        };
        let b_values0_r1 = if BIT_DEPTH == 16 {
            vcombine_u16(b_low0_r1, b_high0_r1)
        } else {
            vminq_u16(vcombine_u16(b_low0_r1, b_high0_r1), v_alpha)
        };
        let r_values1_r1 = if BIT_DEPTH == 16 {
            vcombine_u16(r_low1_r1, r_high1_r1)
        } else {
            vminq_u16(vcombine_u16(r_low1_r1, r_high1_r1), v_alpha)
        };
        let g_values1_r1 = if BIT_DEPTH == 16 {
            vcombine_u16(g_low1_r1, g_high1_r1)
        } else {
            vminq_u16(vcombine_u16(g_low1_r1, g_high1_r1), v_alpha)
        };
        let b_values1_r1 = if BIT_DEPTH == 16 {
            vcombine_u16(b_low1_r1, b_high1_r1)
        } else {
            vminq_u16(vcombine_u16(b_low1_r1, b_high1_r1), v_alpha)
        };

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values0_r1,
            g_values0_r1,
            b_values0_r1,
            v_alpha,
        );
        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut((cx + 8) * channels..).as_mut_ptr(),
            r_values1_r1,
            g_values1_r1,
            b_values1_r1,
            v_alpha,
        );

        cx += 16;
        ux += 8;
    }

    while cx + 8 <= width as usize {
        // --- load and expand chroma (shared for both rows) ---
        let mut u_values_l = vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
            u_ld_ptr.get_unchecked(ux..).as_ptr(),
        );
        let mut v_values_l = vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
            v_ld_ptr.get_unchecked(ux..).as_ptr(),
        );
        u_values_l = vreinterpret_s16_u16(vsub_u16(
            vreinterpret_u16_s16(u_values_l),
            vget_low_u16(uv_corr),
        ));
        v_values_l = vreinterpret_s16_u16(vsub_u16(
            vreinterpret_u16_s16(v_values_l),
            vget_low_u16(uv_corr),
        ));

        let u_high = vzip2_s16(u_values_l, u_values_l);
        let v_high = vzip2_s16(v_values_l, v_values_l);
        let u_low = vzip1_s16(u_values_l, u_values_l);
        let v_low = vzip1_s16(v_values_l, v_values_l);

        // --- row 0 ---
        let y_values_r0 = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr0.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        );

        let y_high_r0 = vreinterpretq_s32_u32(vmlal_high_laneq_u16::<0>(
            base_val,
            y_values_r0,
            vreinterpretq_u16_s16(v_weights),
        ));
        let y_low_r0 = vreinterpretq_s32_u32(vmlal_laneq_u16::<0>(
            base_val,
            vget_low_u16(y_values_r0),
            vreinterpretq_u16_s16(v_weights),
        ));

        let rh_r0 = vmlal_laneq_s16::<1>(y_high_r0, v_high, v_weights);
        let bh_r0 = vmlal_laneq_s16::<2>(y_high_r0, u_high, v_weights);
        let gh_r0 = vmlal_laneq_s16::<3>(y_high_r0, v_high, v_weights);
        let rl_r0 = vmlal_laneq_s16::<1>(y_low_r0, v_low, v_weights);
        let bl_r0 = vmlal_laneq_s16::<2>(y_low_r0, u_low, v_weights);
        let gl_r0 = vmlal_laneq_s16::<3>(y_low_r0, v_low, v_weights);

        let r_high_r0 = vqshrun_n_s32::<PRECISION>(rh_r0);
        let b_high_r0 = vqshrun_n_s32::<PRECISION>(bh_r0);
        let g_high_r0 = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(gh_r0, u_high, v_weights));
        let r_low_r0 = vqshrun_n_s32::<PRECISION>(rl_r0);
        let b_low_r0 = vqshrun_n_s32::<PRECISION>(bl_r0);
        let g_low_r0 = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(gl_r0, u_low, v_weights));

        let r_values_r0 = if BIT_DEPTH == 16 {
            vcombine_u16(r_low_r0, r_high_r0)
        } else {
            vminq_u16(vcombine_u16(r_low_r0, r_high_r0), v_alpha)
        };
        let g_values_r0 = if BIT_DEPTH == 16 {
            vcombine_u16(g_low_r0, g_high_r0)
        } else {
            vminq_u16(vcombine_u16(g_low_r0, g_high_r0), v_alpha)
        };
        let b_values_r0 = if BIT_DEPTH == 16 {
            vcombine_u16(b_low_r0, b_high_r0)
        } else {
            vminq_u16(vcombine_u16(b_low_r0, b_high_r0), v_alpha)
        };

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values_r0,
            g_values_r0,
            b_values_r0,
            v_alpha,
        );

        // --- row 1 (same chroma u_low/high, v_low/high) ---
        let y_values_r1 = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr1.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        );

        let y_high_r1 = vreinterpretq_s32_u32(vmlal_high_laneq_u16::<0>(
            base_val,
            y_values_r1,
            vreinterpretq_u16_s16(v_weights),
        ));
        let y_low_r1 = vreinterpretq_s32_u32(vmlal_laneq_u16::<0>(
            base_val,
            vget_low_u16(y_values_r1),
            vreinterpretq_u16_s16(v_weights),
        ));

        let rh_r1 = vmlal_laneq_s16::<1>(y_high_r1, v_high, v_weights);
        let bh_r1 = vmlal_laneq_s16::<2>(y_high_r1, u_high, v_weights);
        let gh_r1 = vmlal_laneq_s16::<3>(y_high_r1, v_high, v_weights);
        let rl_r1 = vmlal_laneq_s16::<1>(y_low_r1, v_low, v_weights);
        let bl_r1 = vmlal_laneq_s16::<2>(y_low_r1, u_low, v_weights);
        let gl_r1 = vmlal_laneq_s16::<3>(y_low_r1, v_low, v_weights);

        let r_high_r1 = vqshrun_n_s32::<PRECISION>(rh_r1);
        let b_high_r1 = vqshrun_n_s32::<PRECISION>(bh_r1);
        let g_high_r1 = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(gh_r1, u_high, v_weights));
        let r_low_r1 = vqshrun_n_s32::<PRECISION>(rl_r1);
        let b_low_r1 = vqshrun_n_s32::<PRECISION>(bl_r1);
        let g_low_r1 = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(gl_r1, u_low, v_weights));

        let r_values_r1 = if BIT_DEPTH == 16 {
            vcombine_u16(r_low_r1, r_high_r1)
        } else {
            vminq_u16(vcombine_u16(r_low_r1, r_high_r1), v_alpha)
        };
        let g_values_r1 = if BIT_DEPTH == 16 {
            vcombine_u16(g_low_r1, g_high_r1)
        } else {
            vminq_u16(vcombine_u16(g_low_r1, g_high_r1), v_alpha)
        };
        let b_values_r1 = if BIT_DEPTH == 16 {
            vcombine_u16(b_low_r1, b_high_r1)
        } else {
            vminq_u16(vcombine_u16(b_low_r1, b_high_r1), v_alpha)
        };

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values_r1,
            g_values_r1,
            b_values_r1,
            v_alpha,
        );

        cx += 8;
        ux += 4;
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 8);

        let uv_size = diff.div_ceil(2);

        let mut y_buffer0: [u16; 8] = [0; 8];
        let mut y_buffer1: [u16; 8] = [0; 8];
        let mut u_buffer: [u16; 8] = [0; 8];
        let mut v_buffer: [u16; 8] = [0; 8];

        y_buffer0[..diff].copy_from_slice(&y_ld_ptr0[cx..cx + diff]);
        y_buffer1[..diff].copy_from_slice(&y_ld_ptr1[cx..cx + diff]);
        u_buffer[..uv_size].copy_from_slice(&u_ld_ptr[ux..ux + uv_size]);
        v_buffer[..uv_size].copy_from_slice(&v_ld_ptr[ux..ux + uv_size]);

        let mut wh_rgba0: [u16; 8 * 4] = [0; 8 * 4];
        let mut wh_rgba1: [u16; 8 * 4] = [0; 8 * 4];
        let (cut_rgba0, _) = wh_rgba0.split_at_mut(channels * 8);
        let (cut_rgba1, _) = wh_rgba1.split_at_mut(channels * 8);

        neon_yuv_p16_to_rgba16_row420_impl::<
            DESTINATION_CHANNELS,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >(
            &y_buffer0, &y_buffer1, &u_buffer, &v_buffer, cut_rgba0, cut_rgba1, 8, range, transform,
        );

        rgba0[cx * channels..cx * channels + channels * diff]
            .copy_from_slice(&cut_rgba0[..channels * diff]);
        rgba1[cx * channels..cx * channels + channels * diff]
            .copy_from_slice(&cut_rgba1[..channels * diff]);
    }
}
#[cfg(feature = "rdm")]
pub(crate) fn neon_yuv_p16_to_rgba16_row420_rdm<
    const DESTINATION_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr0: &[u16],
    y_ld_ptr1: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    rgba0: &mut [u16],
    rgba1: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    unsafe {
        neon_yuv_p16_to_rgba16_row420_rdm_impl::<
            DESTINATION_CHANNELS,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >(
            y_ld_ptr0, y_ld_ptr1, u_ld_ptr, v_ld_ptr, rgba0, rgba1, width, range, transform,
        );
    }
}

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
unsafe fn neon_yuv_p16_to_rgba16_row420_rdm_impl<
    const DESTINATION_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr0: &[u16],
    y_ld_ptr1: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    rgba0: &mut [u16],
    rgba1: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    const SCALE: i32 = 2;

    let y_corr = vdupq_n_u16(range.bias_y as u16);
    let uv_corr = vdupq_n_s16(range.bias_uv as i16);

    let weights_arr: [i16; 8] = [
        transform.y_coef as i16,
        transform.cr_coef as i16,
        transform.cb_coef as i16,
        -transform.g_coeff_1 as i16,
        -transform.g_coeff_2 as i16,
        0,
        0,
        0,
    ];

    let v_weights = vld1q_s16(weights_arr.as_ptr());
    let v_alpha = vdupq_n_u16((1 << BIT_DEPTH) - 1);
    let zeros = vdupq_n_s16(0);

    let mut cx = 0usize;
    let mut ux = 0usize;

    while cx + 16 <= width as usize {
        let mut u_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
            u_ld_ptr.get_unchecked(ux..).as_ptr(),
        );
        let mut v_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
            v_ld_ptr.get_unchecked(ux..).as_ptr(),
        );
        u_values_l = vsubq_s16(u_values_l, uv_corr);
        v_values_l = vsubq_s16(v_values_l, uv_corr);

        let u_values0 = vshlq_n_s16::<SCALE>(vzip1q_s16(u_values_l, u_values_l));
        let v_values0 = vshlq_n_s16::<SCALE>(vzip1q_s16(v_values_l, v_values_l));
        let u_values1 = vshlq_n_s16::<SCALE>(vzip2q_s16(u_values_l, u_values_l));
        let v_values1 = vshlq_n_s16::<SCALE>(vzip2q_s16(v_values_l, v_values_l));

        // --- row 0 ---
        let y_values0_r0: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr0.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        ));
        let y_values1_r0: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr0.get_unchecked((cx + 8)..).as_ptr(),
            )),
            y_corr,
        ));

        let y_high0_r0 =
            vqrdmulhq_laneq_s16::<0>(vexpand_high_bp_by_2::<BIT_DEPTH>(y_values0_r0), v_weights);
        let y_high1_r0 =
            vqrdmulhq_laneq_s16::<0>(vexpand_high_bp_by_2::<BIT_DEPTH>(y_values1_r0), v_weights);

        let r_vals0_r0 = vqrdmlahq_laneq_s16::<1>(y_high0_r0, v_values0, v_weights);
        let b_vals0_r0 = vqrdmlahq_laneq_s16::<2>(y_high0_r0, u_values0, v_weights);
        let g_vals0_r0 = vqrdmlahq_laneq_s16::<4>(
            vqrdmlahq_laneq_s16::<3>(y_high0_r0, v_values0, v_weights),
            u_values0,
            v_weights,
        );
        let r_vals1_r0 = vqrdmlahq_laneq_s16::<1>(y_high1_r0, v_values1, v_weights);
        let b_vals1_r0 = vqrdmlahq_laneq_s16::<2>(y_high1_r0, u_values1, v_weights);
        let g_vals1_r0 = vqrdmlahq_laneq_s16::<4>(
            vqrdmlahq_laneq_s16::<3>(y_high1_r0, v_values1, v_weights),
            u_values1,
            v_weights,
        );

        let r_values0_r0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(r_vals0_r0, zeros)), v_alpha);
        let g_values0_r0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(g_vals0_r0, zeros)), v_alpha);
        let b_values0_r0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(b_vals0_r0, zeros)), v_alpha);
        let r_values1_r0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(r_vals1_r0, zeros)), v_alpha);
        let g_values1_r0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(g_vals1_r0, zeros)), v_alpha);
        let b_values1_r0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(b_vals1_r0, zeros)), v_alpha);

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values0_r0,
            g_values0_r0,
            b_values0_r0,
            v_alpha,
        );
        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut((cx + 8) * channels..).as_mut_ptr(),
            r_values1_r0,
            g_values1_r0,
            b_values1_r0,
            v_alpha,
        );

        // --- row 1 (same chroma u_values0/1, v_values0/1) ---
        let y_values0_r1: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr1.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        ));
        let y_values1_r1: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr1.get_unchecked((cx + 8)..).as_ptr(),
            )),
            y_corr,
        ));

        let y_high0_r1 =
            vqrdmulhq_laneq_s16::<0>(vexpand_high_bp_by_2::<BIT_DEPTH>(y_values0_r1), v_weights);
        let y_high1_r1 =
            vqrdmulhq_laneq_s16::<0>(vexpand_high_bp_by_2::<BIT_DEPTH>(y_values1_r1), v_weights);

        let r_vals0_r1 = vqrdmlahq_laneq_s16::<1>(y_high0_r1, v_values0, v_weights);
        let b_vals0_r1 = vqrdmlahq_laneq_s16::<2>(y_high0_r1, u_values0, v_weights);
        let g_vals0_r1 = vqrdmlahq_laneq_s16::<4>(
            vqrdmlahq_laneq_s16::<3>(y_high0_r1, v_values0, v_weights),
            u_values0,
            v_weights,
        );
        let r_vals1_r1 = vqrdmlahq_laneq_s16::<1>(y_high1_r1, v_values1, v_weights);
        let b_vals1_r1 = vqrdmlahq_laneq_s16::<2>(y_high1_r1, u_values1, v_weights);
        let g_vals1_r1 = vqrdmlahq_laneq_s16::<4>(
            vqrdmlahq_laneq_s16::<3>(y_high1_r1, v_values1, v_weights),
            u_values1,
            v_weights,
        );

        let r_values0_r1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(r_vals0_r1, zeros)), v_alpha);
        let g_values0_r1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(g_vals0_r1, zeros)), v_alpha);
        let b_values0_r1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(b_vals0_r1, zeros)), v_alpha);
        let r_values1_r1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(r_vals1_r1, zeros)), v_alpha);
        let g_values1_r1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(g_vals1_r1, zeros)), v_alpha);
        let b_values1_r1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(b_vals1_r1, zeros)), v_alpha);

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values0_r1,
            g_values0_r1,
            b_values0_r1,
            v_alpha,
        );
        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut((cx + 8) * channels..).as_mut_ptr(),
            r_values1_r1,
            g_values1_r1,
            b_values1_r1,
            v_alpha,
        );

        cx += 16;
        ux += 8;
    }

    while cx + 8 <= width as usize {
        let mut u_values_l = vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
            u_ld_ptr.get_unchecked(ux..).as_ptr(),
        );
        let mut v_values_l = vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
            v_ld_ptr.get_unchecked(ux..).as_ptr(),
        );
        u_values_l = vsub_s16(u_values_l, vget_low_s16(uv_corr));
        v_values_l = vsub_s16(v_values_l, vget_low_s16(uv_corr));

        let u_values = vshlq_n_s16::<SCALE>(vcombine_s16(
            vzip1_s16(u_values_l, u_values_l),
            vzip2_s16(u_values_l, u_values_l),
        ));
        let v_values = vshlq_n_s16::<SCALE>(vcombine_s16(
            vzip1_s16(v_values_l, v_values_l),
            vzip2_s16(v_values_l, v_values_l),
        ));

        // --- row 0 ---
        let y_values_r0: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr0.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        ));

        let y_high_r0 =
            vqrdmulhq_laneq_s16::<0>(vexpand_high_bp_by_2::<BIT_DEPTH>(y_values_r0), v_weights);

        let r_vals_r0 = vqrdmlahq_laneq_s16::<1>(y_high_r0, v_values, v_weights);
        let b_vals_r0 = vqrdmlahq_laneq_s16::<2>(y_high_r0, u_values, v_weights);
        let g_vals_r0 = vqrdmlahq_laneq_s16::<4>(
            vqrdmlahq_laneq_s16::<3>(y_high_r0, v_values, v_weights),
            u_values,
            v_weights,
        );

        let r_values_r0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(r_vals_r0, zeros)), v_alpha);
        let g_values_r0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(g_vals_r0, zeros)), v_alpha);
        let b_values_r0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(b_vals_r0, zeros)), v_alpha);

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values_r0,
            g_values_r0,
            b_values_r0,
            v_alpha,
        );

        let y_values_r1: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr1.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        ));

        let y_high_r1 =
            vqrdmulhq_laneq_s16::<0>(vexpand_high_bp_by_2::<BIT_DEPTH>(y_values_r1), v_weights);

        let r_vals_r1 = vqrdmlahq_laneq_s16::<1>(y_high_r1, v_values, v_weights);
        let b_vals_r1 = vqrdmlahq_laneq_s16::<2>(y_high_r1, u_values, v_weights);
        let g_vals_r1 = vqrdmlahq_laneq_s16::<4>(
            vqrdmlahq_laneq_s16::<3>(y_high_r1, v_values, v_weights),
            u_values,
            v_weights,
        );

        let r_values_r1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(r_vals_r1, zeros)), v_alpha);
        let g_values_r1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(g_vals_r1, zeros)), v_alpha);
        let b_values_r1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(b_vals_r1, zeros)), v_alpha);

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values_r1,
            g_values_r1,
            b_values_r1,
            v_alpha,
        );

        cx += 8;
        ux += 4;
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 8);

        let uv_size = diff.div_ceil(2);

        let mut y_buffer0: [u16; 8] = [0; 8];
        let mut y_buffer1: [u16; 8] = [0; 8];
        let mut u_buffer: [u16; 8] = [0; 8];
        let mut v_buffer: [u16; 8] = [0; 8];

        y_buffer0[..diff].copy_from_slice(&y_ld_ptr0[cx..cx + diff]);
        y_buffer1[..diff].copy_from_slice(&y_ld_ptr1[cx..cx + diff]);
        u_buffer[..uv_size].copy_from_slice(&u_ld_ptr[ux..ux + uv_size]);
        v_buffer[..uv_size].copy_from_slice(&v_ld_ptr[ux..ux + uv_size]);

        let mut wh_rgba0: [u16; 8 * 4] = [0; 8 * 4];
        let mut wh_rgba1: [u16; 8 * 4] = [0; 8 * 4];
        let (cut_rgba0, _) = wh_rgba0.split_at_mut(channels * 8);
        let (cut_rgba1, _) = wh_rgba1.split_at_mut(channels * 8);

        neon_yuv_p16_to_rgba16_row420_rdm_impl::<
            DESTINATION_CHANNELS,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >(
            &y_buffer0, &y_buffer1, &u_buffer, &v_buffer, cut_rgba0, cut_rgba1, 8, range, transform,
        );

        rgba0[cx * channels..cx * channels + channels * diff]
            .copy_from_slice(&cut_rgba0[..channels * diff]);
        rgba1[cx * channels..cx * channels + channels * diff]
            .copy_from_slice(&cut_rgba1[..channels * diff]);
    }
}
