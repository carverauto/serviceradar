/*
 * Copyright (c) Radzivon Bartoshyk, 6/2025. All rights reserved.
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
use crate::neon::utils::{neon_store_half_rgb8, neon_store_rgb8, xvld1_4u8};
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvSourceChannels};
use std::arch::aarch64::*;

pub(crate) fn neon_bilinear_interpolate_1_row_rgba<const DESTINATION_CHANNELS: u8, const Q: i32>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba: &mut [u8],
    width: u32,
) {
    unsafe {
        let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
        let channels = dst_chans.get_channels_count();

        let mut x = 0usize;
        let mut cx = 0usize;

        let weights_arr: [i16; 8] = [
            transform.y_coef,
            transform.cr_coef,
            transform.cb_coef,
            -transform.g_coeff_1,
            -transform.g_coeff_2,
            0,
            0,
            0,
        ];

        let y_corr = vdupq_n_u8(range.bias_y as u8);
        let uv_corr = vdupq_n_s16(range.bias_uv as i16);
        let v_alpha = vdupq_n_u8(255u8);

        let rnd = vdupq_n_s32(1i32 << (Q - 1));

        let v_weights = vld1q_s16(weights_arr.as_ptr());

        while x + 17 <= width as usize {
            let mut y_value = vld1q_u8(y_plane.get_unchecked(x..).as_ptr().cast());
            let u_value0 = vld1_u8(u_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value1 = vld1_u8(u_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value0 = vld1_u8(v_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value1 = vld1_u8(v_plane.get_unchecked(cx + 1..).as_ptr().cast());

            y_value = vqsubq_u8(y_value, y_corr);

            let uu0 = vmlal_u8(vmovl_u8(u_value1), u_value0, vdup_n_u8(3));
            let vv0 = vmlal_u8(vmovl_u8(v_value1), v_value0, vdup_n_u8(3));

            let y_value_lo = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_value)));
            let y_value_hi = vreinterpretq_s16_u16(vmovl_high_u8(y_value));

            let uu1 = vmlal_u8(vmovl_u8(u_value0), u_value1, vdup_n_u8(3));
            let vv1 = vmlal_u8(vmovl_u8(v_value0), v_value1, vdup_n_u8(3));

            let uuz0 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(uu0)), uv_corr);
            let vvz0 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(vv0)), uv_corr);
            let uuz1 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(uu1)), uv_corr);
            let vvz1 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(vv1)), uv_corr);

            let y0_value = vmlal_laneq_s16::<0>(rnd, vget_low_s16(y_value_lo), v_weights);
            let y1_value = vmlal_high_laneq_s16::<0>(rnd, y_value_lo, v_weights);

            let uu0 = vzip1q_s16(uuz0, uuz1);
            let vv0 = vzip1q_s16(vvz0, vvz1);
            let uu1 = vzip2q_s16(uuz0, uuz1);
            let vv1 = vzip2q_s16(vvz0, vvz1);

            let y2_value = vmlal_laneq_s16::<0>(rnd, vget_low_s16(y_value_hi), v_weights);
            let y3_value = vmlal_high_laneq_s16::<0>(rnd, y_value_hi, v_weights);

            let r0 = vmlal_laneq_s16::<1>(y0_value, vget_low_s16(vv0), v_weights);
            let r1 = vmlal_high_laneq_s16::<1>(y1_value, vv0, v_weights);
            let r2 = vmlal_laneq_s16::<1>(y2_value, vget_low_s16(vv1), v_weights);
            let r3 = vmlal_high_laneq_s16::<1>(y3_value, vv1, v_weights);

            let b0 = vmlal_laneq_s16::<2>(y0_value, vget_low_s16(uu0), v_weights);
            let b1 = vmlal_high_laneq_s16::<2>(y1_value, uu0, v_weights);
            let b2 = vmlal_laneq_s16::<2>(y2_value, vget_low_s16(uu1), v_weights);
            let b3 = vmlal_high_laneq_s16::<2>(y3_value, uu1, v_weights);

            let mut g0 = vmlal_laneq_s16::<3>(y0_value, vget_low_s16(vv0), v_weights);
            let mut g1 = vmlal_high_laneq_s16::<3>(y1_value, vv0, v_weights);
            let mut g2 = vmlal_laneq_s16::<3>(y2_value, vget_low_s16(vv1), v_weights);
            let mut g3 = vmlal_high_laneq_s16::<3>(y3_value, vv1, v_weights);

            let r01 = vcombine_u16(vqshrun_n_s32::<Q>(r0), vqshrun_n_s32::<Q>(r1));
            let r23 = vcombine_u16(vqshrun_n_s32::<Q>(r2), vqshrun_n_s32::<Q>(r3));

            let b01 = vcombine_u16(vqshrun_n_s32::<Q>(b0), vqshrun_n_s32::<Q>(b1));
            let b23 = vcombine_u16(vqshrun_n_s32::<Q>(b2), vqshrun_n_s32::<Q>(b3));

            g0 = vmlal_laneq_s16::<4>(g0, vget_low_s16(uu0), v_weights);
            g1 = vmlal_high_laneq_s16::<4>(g1, uu0, v_weights);
            g2 = vmlal_laneq_s16::<4>(g2, vget_low_s16(uu1), v_weights);
            g3 = vmlal_high_laneq_s16::<4>(g3, uu1, v_weights);

            let g01 = vcombine_u16(vqshrun_n_s32::<Q>(g0), vqshrun_n_s32::<Q>(g1));
            let g23 = vcombine_u16(vqshrun_n_s32::<Q>(g2), vqshrun_n_s32::<Q>(g3));

            let r_values = vcombine_u8(vqmovn_u16(r01), vqmovn_u16(r23));
            let b_values = vcombine_u8(vqmovn_u16(b01), vqmovn_u16(b23));
            let g_values = vcombine_u8(vqmovn_u16(g01), vqmovn_u16(g23));

            let dst_shift = x * channels;

            neon_store_rgb8::<DESTINATION_CHANNELS>(
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr().cast(),
                r_values,
                g_values,
                b_values,
                v_alpha,
            );

            x += 16;
            cx += 8;
        }

        while x + 9 < width as usize {
            let mut y_value = vld1_u8(y_plane.get_unchecked(x..).as_ptr().cast());
            let u_value0 = vreinterpret_u8_u32(vld1_lane_u32::<0>(
                u_plane.get_unchecked(cx..).as_ptr().cast(),
                vdup_n_u32(0),
            ));
            let u_value1 = vreinterpret_u8_u32(vld1_lane_u32::<0>(
                u_plane.get_unchecked(cx + 1..).as_ptr().cast(),
                vdup_n_u32(0),
            ));
            let v_value0 = vreinterpret_u8_u32(vld1_lane_u32::<0>(
                v_plane.get_unchecked(cx..).as_ptr().cast(),
                vdup_n_u32(0),
            ));
            let v_value1 = vreinterpret_u8_u32(vld1_lane_u32::<0>(
                v_plane.get_unchecked(cx + 1..).as_ptr().cast(),
                vdup_n_u32(0),
            ));

            y_value = vqsub_u8(y_value, vget_low_u8(y_corr));

            let uu0 = vmlal_u8(vmovl_u8(u_value1), u_value0, vdup_n_u8(3));
            let vv0 = vmlal_u8(vmovl_u8(v_value1), v_value0, vdup_n_u8(3));

            let y_value_lo = vreinterpretq_s16_u16(vmovl_u8(y_value));

            let uu1 = vmlal_u8(vmovl_u8(u_value0), u_value1, vdup_n_u8(3));
            let vv1 = vmlal_u8(vmovl_u8(v_value0), v_value1, vdup_n_u8(3));

            let uuz0 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(uu0)), uv_corr);
            let vvz0 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(vv0)), uv_corr);
            let uuz1 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(uu1)), uv_corr);
            let vvz1 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(vv1)), uv_corr);

            let y0_value = vmlal_laneq_s16::<0>(rnd, vget_low_s16(y_value_lo), v_weights);
            let y1_value = vmlal_high_laneq_s16::<0>(rnd, y_value_lo, v_weights);

            let uu0 = vzip1q_s16(uuz0, uuz1);
            let vv0 = vzip1q_s16(vvz0, vvz1);

            let r0 = vmlal_laneq_s16::<1>(y0_value, vget_low_s16(vv0), v_weights);
            let r1 = vmlal_high_laneq_s16::<1>(y1_value, vv0, v_weights);

            let b0 = vmlal_laneq_s16::<2>(y0_value, vget_low_s16(uu0), v_weights);
            let b1 = vmlal_high_laneq_s16::<2>(y1_value, uu0, v_weights);

            let mut g0 = vmlal_laneq_s16::<3>(y0_value, vget_low_s16(vv0), v_weights);
            let mut g1 = vmlal_high_laneq_s16::<3>(y1_value, vv0, v_weights);

            let r01 = vcombine_u16(vqshrun_n_s32::<Q>(r0), vqshrun_n_s32::<Q>(r1));
            let b01 = vcombine_u16(vqshrun_n_s32::<Q>(b0), vqshrun_n_s32::<Q>(b1));

            g0 = vmlal_laneq_s16::<4>(g0, vget_low_s16(uu0), v_weights);
            g1 = vmlal_high_laneq_s16::<4>(g1, uu0, v_weights);

            let g01 = vcombine_u16(vqshrun_n_s32::<Q>(g0), vqshrun_n_s32::<Q>(g1));

            let r_values = vqmovn_u16(r01);
            let b_values = vqmovn_u16(b01);
            let g_values = vqmovn_u16(g01);

            let dst_shift = x * channels;

            neon_store_half_rgb8::<DESTINATION_CHANNELS>(
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr().cast(),
                r_values,
                g_values,
                b_values,
                vget_low_u8(v_alpha),
            );

            x += 8;
            cx += 4;
        }

        if x < width as usize {
            let mut y_store: [u8; 17] = [0; 17];
            let mut u_store: [u8; 17] = [0; 17];
            let mut v_store: [u8; 17] = [0; 17];
            let mut rgba_store: [u8; 16 * 4] = [0; 16 * 4];

            let diff = width as usize - x;
            assert!(diff <= 16);

            std::ptr::copy_nonoverlapping(
                y_plane.get_unchecked(x..).as_ptr(),
                y_store.as_mut_ptr().cast(),
                diff,
            );

            let ux_diff = diff.div_ceil(2);

            std::ptr::copy_nonoverlapping(
                u_plane.get_unchecked(cx..).as_ptr(),
                u_store.as_mut_ptr().cast(),
                ux_diff,
            );

            u_store[ux_diff] = *u_plane.last().unwrap();
            v_store[ux_diff] = *v_plane.last().unwrap();

            std::ptr::copy_nonoverlapping(
                v_plane.get_unchecked(cx..).as_ptr(),
                v_store.as_mut_ptr().cast(),
                ux_diff,
            );

            let mut y_value = vld1q_u8(y_store.as_ptr().cast());
            let u_value0 = vld1_u8(u_store.as_ptr().cast());
            let u_value1 = vld1_u8(u_store.get_unchecked(1..).as_ptr().cast());
            let v_value0 = vld1_u8(v_store.as_ptr().cast());
            let v_value1 = vld1_u8(v_store.get_unchecked(1..).as_ptr().cast());

            y_value = vqsubq_u8(y_value, y_corr);

            let uu0 = vmlal_u8(vmovl_u8(u_value1), u_value0, vdup_n_u8(3));
            let vv0 = vmlal_u8(vmovl_u8(v_value1), v_value0, vdup_n_u8(3));

            let y_value_lo = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_value)));
            let y_value_hi = vreinterpretq_s16_u16(vmovl_high_u8(y_value));

            let uu1 = vmlal_u8(vmovl_u8(u_value0), u_value1, vdup_n_u8(3));
            let vv1 = vmlal_u8(vmovl_u8(v_value0), v_value1, vdup_n_u8(3));

            let uuz0 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(uu0)), uv_corr);
            let vvz0 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(vv0)), uv_corr);
            let uuz1 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(uu1)), uv_corr);
            let vvz1 = vsubq_s16(vreinterpretq_s16_u16(vrshrq_n_u16::<2>(vv1)), uv_corr);

            let y0_value = vmlal_laneq_s16::<0>(rnd, vget_low_s16(y_value_lo), v_weights);
            let y1_value = vmlal_high_laneq_s16::<0>(rnd, y_value_lo, v_weights);

            let uu0 = vzip1q_s16(uuz0, uuz1);
            let vv0 = vzip1q_s16(vvz0, vvz1);
            let uu1 = vzip2q_s16(uuz0, uuz1);
            let vv1 = vzip2q_s16(vvz0, vvz1);

            let y2_value = vmlal_laneq_s16::<0>(rnd, vget_low_s16(y_value_hi), v_weights);
            let y3_value = vmlal_high_laneq_s16::<0>(rnd, y_value_hi, v_weights);

            let r0 = vmlal_laneq_s16::<1>(y0_value, vget_low_s16(vv0), v_weights);
            let r1 = vmlal_high_laneq_s16::<1>(y1_value, vv0, v_weights);
            let r2 = vmlal_laneq_s16::<1>(y2_value, vget_low_s16(vv1), v_weights);
            let r3 = vmlal_high_laneq_s16::<1>(y3_value, vv1, v_weights);

            let b0 = vmlal_laneq_s16::<2>(y0_value, vget_low_s16(uu0), v_weights);
            let b1 = vmlal_high_laneq_s16::<2>(y1_value, uu0, v_weights);
            let b2 = vmlal_laneq_s16::<2>(y2_value, vget_low_s16(uu1), v_weights);
            let b3 = vmlal_high_laneq_s16::<2>(y3_value, uu1, v_weights);

            let mut g0 = vmlal_laneq_s16::<3>(y0_value, vget_low_s16(vv0), v_weights);
            let mut g1 = vmlal_high_laneq_s16::<3>(y1_value, vv0, v_weights);
            let mut g2 = vmlal_laneq_s16::<3>(y2_value, vget_low_s16(vv1), v_weights);
            let mut g3 = vmlal_high_laneq_s16::<3>(y3_value, vv1, v_weights);

            let r01 = vcombine_u16(vqshrun_n_s32::<Q>(r0), vqshrun_n_s32::<Q>(r1));
            let r23 = vcombine_u16(vqshrun_n_s32::<Q>(r2), vqshrun_n_s32::<Q>(r3));

            let b01 = vcombine_u16(vqshrun_n_s32::<Q>(b0), vqshrun_n_s32::<Q>(b1));
            let b23 = vcombine_u16(vqshrun_n_s32::<Q>(b2), vqshrun_n_s32::<Q>(b3));

            g0 = vmlal_laneq_s16::<4>(g0, vget_low_s16(uu0), v_weights);
            g1 = vmlal_high_laneq_s16::<4>(g1, uu0, v_weights);
            g2 = vmlal_laneq_s16::<4>(g2, vget_low_s16(uu1), v_weights);
            g3 = vmlal_high_laneq_s16::<4>(g3, uu1, v_weights);

            let g01 = vcombine_u16(vqshrun_n_s32::<Q>(g0), vqshrun_n_s32::<Q>(g1));
            let g23 = vcombine_u16(vqshrun_n_s32::<Q>(g2), vqshrun_n_s32::<Q>(g3));

            let r_values = vcombine_u8(vqmovn_u16(r01), vqmovn_u16(r23));
            let b_values = vcombine_u8(vqmovn_u16(b01), vqmovn_u16(b23));
            let g_values = vcombine_u8(vqmovn_u16(g01), vqmovn_u16(g23));

            neon_store_rgb8::<DESTINATION_CHANNELS>(
                rgba_store.as_mut_ptr().cast(),
                r_values,
                g_values,
                b_values,
                v_alpha,
            );

            let dst_shift = x * channels;
            std::ptr::copy_nonoverlapping(
                rgba_store.as_ptr().cast(),
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
                diff * channels,
            );
        }
    }
}

struct InterRow0 {
    u_value_x0_y0: uint8x8_t,
    u_value_x1_y0: uint8x8_t,
    v_value_x0_y0: uint8x8_t,
    v_value_x1_y0: uint8x8_t,
}

struct InterRow1 {
    u_value_x0_y1: uint8x8_t,
    u_value_x1_y1: uint8x8_t,
    v_value_x0_y1: uint8x8_t,
    v_value_x1_y1: uint8x8_t,
}

#[inline(always)]
fn inter4(row0: InterRow0, row1: InterRow1) -> (int16x8_t, int16x8_t) {
    unsafe {
        let t_left = vdupq_n_u8(9);
        let t_right = vdupq_n_u8(3);
        let mut uu0 = vmull_u8(row0.u_value_x0_y0, vget_low_u8(t_left));
        let mut vv0 = vmull_u8(row0.v_value_x0_y0, vget_low_u8(t_left));

        uu0 = vmlal_u8(uu0, row0.u_value_x1_y0, vget_low_u8(t_right));
        vv0 = vmlal_u8(vv0, row0.v_value_x1_y0, vget_low_u8(t_right));

        uu0 = vmlal_u8(uu0, row1.u_value_x0_y1, vget_low_u8(t_right));
        vv0 = vmlal_u8(vv0, row1.v_value_x0_y1, vget_low_u8(t_right));

        uu0 = vaddw_u8(uu0, row1.u_value_x1_y1);
        vv0 = vaddw_u8(vv0, row1.v_value_x1_y1);

        let uuz0 = vreinterpretq_s16_u16(vrshrq_n_u16::<4>(uu0));
        let vvz0 = vreinterpretq_s16_u16(vrshrq_n_u16::<4>(vv0));
        (uuz0, vvz0)
    }
}

#[inline(always)]
fn inter4_far(row0: InterRow0, row1: InterRow1) -> (int16x8_t, int16x8_t) {
    unsafe {
        let t_left = vdupq_n_u8(9);
        let t_right = vdupq_n_u8(3);
        let mut uu0 = vmull_u8(row0.u_value_x0_y0, vget_low_u8(t_left));
        let mut vv0 = vmull_u8(row0.v_value_x0_y0, vget_low_u8(t_left));

        uu0 = vmlal_u8(uu0, row0.u_value_x1_y0, vget_low_u8(t_right));
        vv0 = vmlal_u8(vv0, row0.v_value_x1_y0, vget_low_u8(t_right));

        uu0 = vmlal_u8(uu0, row1.u_value_x0_y1, vget_low_u8(t_right));
        vv0 = vmlal_u8(vv0, row1.v_value_x0_y1, vget_low_u8(t_right));

        uu0 = vaddw_u8(uu0, row1.u_value_x1_y1);
        vv0 = vaddw_u8(vv0, row1.v_value_x1_y1);

        let uuz0 = vreinterpretq_s16_u16(vrshrq_n_u16::<4>(uu0));
        let vvz0 = vreinterpretq_s16_u16(vrshrq_n_u16::<4>(vv0));
        (uuz0, vvz0)
    }
}

pub(crate) fn neon_bilinear_interpolate_2_rows_rgba<
    const DESTINATION_CHANNELS: u8,
    const Q: i32,
>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i16>,
    y_plane: &[u8],
    u0_plane: &[u8],
    u1_plane: &[u8],
    v0_plane: &[u8],
    v1_plane: &[u8],
    rgba: &mut [u8],
    width: u32,
) {
    unsafe {
        let dst_chans: YuvSourceChannels = DESTINATION_CHANNELS.into();
        let channels = dst_chans.get_channels_count();

        let mut x = 0usize;
        let mut cx = 0usize;

        let weights_arr: [i16; 8] = [
            transform.y_coef,
            transform.cr_coef,
            transform.cb_coef,
            -transform.g_coeff_1,
            -transform.g_coeff_2,
            0,
            0,
            0,
        ];

        let y_corr = vdupq_n_u8(range.bias_y as u8);
        let uv_corr = vdupq_n_s16(range.bias_uv as i16);
        let v_alpha = vdupq_n_u8(255u8);

        let v_weights = vld1q_s16(weights_arr.as_ptr());

        while x + 17 <= width as usize {
            let mut y_value = vld1q_u8(y_plane.get_unchecked(x..).as_ptr().cast());

            let u_value_x0_y0 = vld1_u8(u0_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value_x1_y0 = vld1_u8(u0_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value_x0_y0 = vld1_u8(v0_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value_x1_y0 = vld1_u8(v0_plane.get_unchecked(cx + 1..).as_ptr().cast());

            let u_value_x0_y1 = vld1_u8(u1_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value_x1_y1 = vld1_u8(u1_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value_x0_y1 = vld1_u8(v1_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value_x1_y1 = vld1_u8(v1_plane.get_unchecked(cx + 1..).as_ptr().cast());

            y_value = vqsubq_u8(y_value, y_corr);

            let y_value_lo = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_value)));
            let y_value_hi = vreinterpretq_s16_u16(vmovl_high_u8(y_value));

            let (uu0, vv0) = inter4(
                InterRow0 {
                    u_value_x0_y0,
                    u_value_x1_y0,
                    v_value_x0_y0,
                    v_value_x1_y0,
                },
                InterRow1 {
                    u_value_x0_y1,
                    u_value_x1_y1,
                    v_value_x0_y1,
                    v_value_x1_y1,
                },
            );

            let (uu1, vv1) = inter4_far(
                InterRow0 {
                    u_value_x0_y0: u_value_x1_y0,
                    u_value_x1_y0: u_value_x0_y0,
                    v_value_x0_y0: v_value_x1_y0,
                    v_value_x1_y0: v_value_x0_y0,
                },
                InterRow1 {
                    u_value_x0_y1: u_value_x1_y1,
                    u_value_x1_y1: u_value_x0_y1,
                    v_value_x0_y1: v_value_x1_y1,
                    v_value_x1_y1: v_value_x0_y1,
                },
            );

            let uuz0 = vsubq_s16(uu0, uv_corr);
            let vvz0 = vsubq_s16(vv0, uv_corr);
            let uuz1 = vsubq_s16(uu1, uv_corr);
            let vvz1 = vsubq_s16(vv1, uv_corr);

            let y0_value = vmull_laneq_s16::<0>(vget_low_s16(y_value_lo), v_weights);
            let y1_value = vmull_high_laneq_s16::<0>(y_value_lo, v_weights);

            let uu0 = vzip1q_s16(uuz0, uuz1);
            let vv0 = vzip1q_s16(vvz0, vvz1);
            let uu1 = vzip2q_s16(uuz0, uuz1);
            let vv1 = vzip2q_s16(vvz0, vvz1);

            let y2_value = vmull_laneq_s16::<0>(vget_low_s16(y_value_hi), v_weights);
            let y3_value = vmull_high_laneq_s16::<0>(y_value_hi, v_weights);

            let r0 = vmlal_laneq_s16::<1>(y0_value, vget_low_s16(vv0), v_weights);
            let r1 = vmlal_high_laneq_s16::<1>(y1_value, vv0, v_weights);
            let r2 = vmlal_laneq_s16::<1>(y2_value, vget_low_s16(vv1), v_weights);
            let r3 = vmlal_high_laneq_s16::<1>(y3_value, vv1, v_weights);

            let b0 = vmlal_laneq_s16::<2>(y0_value, vget_low_s16(uu0), v_weights);
            let b1 = vmlal_high_laneq_s16::<2>(y1_value, uu0, v_weights);
            let b2 = vmlal_laneq_s16::<2>(y2_value, vget_low_s16(uu1), v_weights);
            let b3 = vmlal_high_laneq_s16::<2>(y3_value, uu1, v_weights);

            let mut g0 = vmlal_laneq_s16::<3>(y0_value, vget_low_s16(vv0), v_weights);
            let mut g1 = vmlal_high_laneq_s16::<3>(y1_value, vv0, v_weights);
            let mut g2 = vmlal_laneq_s16::<3>(y2_value, vget_low_s16(vv1), v_weights);
            let mut g3 = vmlal_high_laneq_s16::<3>(y3_value, vv1, v_weights);

            let r01 = vcombine_u16(vqrshrun_n_s32::<Q>(r0), vqrshrun_n_s32::<Q>(r1));
            let r23 = vcombine_u16(vqrshrun_n_s32::<Q>(r2), vqrshrun_n_s32::<Q>(r3));

            let b01 = vcombine_u16(vqrshrun_n_s32::<Q>(b0), vqrshrun_n_s32::<Q>(b1));
            let b23 = vcombine_u16(vqrshrun_n_s32::<Q>(b2), vqrshrun_n_s32::<Q>(b3));

            g0 = vmlal_laneq_s16::<4>(g0, vget_low_s16(uu0), v_weights);
            g1 = vmlal_high_laneq_s16::<4>(g1, uu0, v_weights);
            g2 = vmlal_laneq_s16::<4>(g2, vget_low_s16(uu1), v_weights);
            g3 = vmlal_high_laneq_s16::<4>(g3, uu1, v_weights);

            let g01 = vcombine_u16(vqrshrun_n_s32::<Q>(g0), vqrshrun_n_s32::<Q>(g1));
            let g23 = vcombine_u16(vqrshrun_n_s32::<Q>(g2), vqrshrun_n_s32::<Q>(g3));

            let r_values = vcombine_u8(vqmovn_u16(r01), vqmovn_u16(r23));
            let b_values = vcombine_u8(vqmovn_u16(b01), vqmovn_u16(b23));
            let g_values = vcombine_u8(vqmovn_u16(g01), vqmovn_u16(g23));

            let dst_shift = x * channels;

            neon_store_rgb8::<DESTINATION_CHANNELS>(
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr().cast(),
                r_values,
                g_values,
                b_values,
                v_alpha,
            );

            x += 16;
            cx += 8;
        }

        while x + 9 < width as usize {
            let mut y_value = vld1_u8(y_plane.get_unchecked(x..).as_ptr().cast());

            let u_value_x0_y0 = xvld1_4u8(u0_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value_x1_y0 = xvld1_4u8(u0_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value_x0_y0 = xvld1_4u8(v0_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value_x1_y0 = xvld1_4u8(v0_plane.get_unchecked(cx + 1..).as_ptr().cast());

            let u_value_x0_y1 = xvld1_4u8(u1_plane.get_unchecked(cx..).as_ptr().cast());
            let u_value_x1_y1 = xvld1_4u8(u1_plane.get_unchecked(cx + 1..).as_ptr().cast());
            let v_value_x0_y1 = xvld1_4u8(v1_plane.get_unchecked(cx..).as_ptr().cast());
            let v_value_x1_y1 = xvld1_4u8(v1_plane.get_unchecked(cx + 1..).as_ptr().cast());

            y_value = vqsub_u8(y_value, vget_low_u8(y_corr));

            let y_value_lo = vreinterpretq_s16_u16(vmovl_u8(y_value));

            let (uu0, vv0) = inter4(
                InterRow0 {
                    u_value_x0_y0,
                    u_value_x1_y0,
                    v_value_x0_y0,
                    v_value_x1_y0,
                },
                InterRow1 {
                    u_value_x0_y1,
                    u_value_x1_y1,
                    v_value_x0_y1,
                    v_value_x1_y1,
                },
            );

            let (uu1, vv1) = inter4_far(
                InterRow0 {
                    u_value_x0_y0: u_value_x1_y0,
                    u_value_x1_y0: u_value_x0_y0,
                    v_value_x0_y0: v_value_x1_y0,
                    v_value_x1_y0: v_value_x0_y0,
                },
                InterRow1 {
                    u_value_x0_y1: u_value_x1_y1,
                    u_value_x1_y1: u_value_x0_y1,
                    v_value_x0_y1: v_value_x1_y1,
                    v_value_x1_y1: v_value_x0_y1,
                },
            );

            let uuz0 = vsubq_s16(uu0, uv_corr);
            let vvz0 = vsubq_s16(vv0, uv_corr);
            let uuz1 = vsubq_s16(uu1, uv_corr);
            let vvz1 = vsubq_s16(vv1, uv_corr);

            let y0_value = vmull_laneq_s16::<0>(vget_low_s16(y_value_lo), v_weights);
            let y1_value = vmull_high_laneq_s16::<0>(y_value_lo, v_weights);

            let uu0 = vzip1q_s16(uuz0, uuz1);
            let vv0 = vzip1q_s16(vvz0, vvz1);

            let r0 = vmlal_laneq_s16::<1>(y0_value, vget_low_s16(vv0), v_weights);
            let r1 = vmlal_high_laneq_s16::<1>(y1_value, vv0, v_weights);

            let b0 = vmlal_laneq_s16::<2>(y0_value, vget_low_s16(uu0), v_weights);
            let b1 = vmlal_high_laneq_s16::<2>(y1_value, uu0, v_weights);

            let mut g0 = vmlal_laneq_s16::<3>(y0_value, vget_low_s16(vv0), v_weights);
            let mut g1 = vmlal_high_laneq_s16::<3>(y1_value, vv0, v_weights);

            let r01 = vcombine_u16(vqrshrun_n_s32::<Q>(r0), vqrshrun_n_s32::<Q>(r1));

            let b01 = vcombine_u16(vqrshrun_n_s32::<Q>(b0), vqrshrun_n_s32::<Q>(b1));

            g0 = vmlal_laneq_s16::<4>(g0, vget_low_s16(uu0), v_weights);
            g1 = vmlal_high_laneq_s16::<4>(g1, uu0, v_weights);

            let g01 = vcombine_u16(vqrshrun_n_s32::<Q>(g0), vqrshrun_n_s32::<Q>(g1));

            let r_values = vqmovn_u16(r01);
            let b_values = vqmovn_u16(b01);
            let g_values = vqmovn_u16(g01);

            let dst_shift = x * channels;

            neon_store_half_rgb8::<DESTINATION_CHANNELS>(
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr().cast(),
                r_values,
                g_values,
                b_values,
                vget_low_u8(v_alpha),
            );

            x += 8;
            cx += 4;
        }

        if x < width as usize {
            let mut y_store: [u8; 17] = [0; 17];
            let mut u0_store: [u8; 17] = [0; 17];
            let mut u1_store: [u8; 17] = [0; 17];
            let mut v0_store: [u8; 17] = [0; 17];
            let mut v1_store: [u8; 17] = [0; 17];
            let mut rgba_store: [u8; 16 * 4] = [0; 16 * 4];

            let diff = width as usize - x;
            assert!(diff <= 16);

            std::ptr::copy_nonoverlapping(
                y_plane.get_unchecked(x..).as_ptr(),
                y_store.as_mut_ptr().cast(),
                diff,
            );

            let ux_diff = diff.div_ceil(2);

            std::ptr::copy_nonoverlapping(
                u0_plane.get_unchecked(cx..).as_ptr(),
                u0_store.as_mut_ptr().cast(),
                ux_diff,
            );

            std::ptr::copy_nonoverlapping(
                u1_plane.get_unchecked(cx..).as_ptr(),
                u1_store.as_mut_ptr().cast(),
                ux_diff,
            );

            u0_store[ux_diff] = *u0_plane.last().unwrap();
            u1_store[ux_diff] = *u1_plane.last().unwrap();

            std::ptr::copy_nonoverlapping(
                v0_plane.get_unchecked(cx..).as_ptr(),
                v0_store.as_mut_ptr().cast(),
                ux_diff,
            );

            std::ptr::copy_nonoverlapping(
                v1_plane.get_unchecked(cx..).as_ptr(),
                v1_store.as_mut_ptr().cast(),
                ux_diff,
            );

            v0_store[ux_diff] = *v0_plane.last().unwrap();
            v1_store[ux_diff] = *v1_plane.last().unwrap();

            let mut y_value = vld1q_u8(y_store.as_ptr().cast());

            let u_value_x0_y0 = vld1_u8(u0_store.as_ptr().cast());
            let u_value_x1_y0 = vld1_u8(u0_store.get_unchecked(1..).as_ptr().cast());
            let v_value_x0_y0 = vld1_u8(v0_store.as_ptr().cast());
            let v_value_x1_y0 = vld1_u8(v0_store.get_unchecked(1..).as_ptr().cast());

            let u_value_x0_y1 = vld1_u8(u1_store.as_ptr().cast());
            let u_value_x1_y1 = vld1_u8(u1_store.get_unchecked(1..).as_ptr().cast());
            let v_value_x0_y1 = vld1_u8(v1_store.as_ptr().cast());
            let v_value_x1_y1 = vld1_u8(v1_store.get_unchecked(1..).as_ptr().cast());

            y_value = vqsubq_u8(y_value, y_corr);

            let (uu0, vv0) = inter4(
                InterRow0 {
                    u_value_x0_y0,
                    u_value_x1_y0,
                    v_value_x0_y0,
                    v_value_x1_y0,
                },
                InterRow1 {
                    u_value_x0_y1,
                    u_value_x1_y1,
                    v_value_x0_y1,
                    v_value_x1_y1,
                },
            );

            let (uu1, vv1) = inter4_far(
                InterRow0 {
                    u_value_x0_y0: u_value_x1_y0,
                    u_value_x1_y0: u_value_x0_y0,
                    v_value_x0_y0: v_value_x1_y0,
                    v_value_x1_y0: v_value_x0_y0,
                },
                InterRow1 {
                    u_value_x0_y1: u_value_x1_y1,
                    u_value_x1_y1: u_value_x0_y1,
                    v_value_x0_y1: v_value_x1_y1,
                    v_value_x1_y1: v_value_x0_y1,
                },
            );

            let uuz0 = vsubq_s16(uu0, uv_corr);
            let vvz0 = vsubq_s16(vv0, uv_corr);
            let uuz1 = vsubq_s16(uu1, uv_corr);
            let vvz1 = vsubq_s16(vv1, uv_corr);

            let y_value_lo = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_value)));
            let y_value_hi = vreinterpretq_s16_u16(vmovl_high_u8(y_value));

            let y0_value = vmull_laneq_s16::<0>(vget_low_s16(y_value_lo), v_weights);
            let y1_value = vmull_high_laneq_s16::<0>(y_value_lo, v_weights);

            let uu0 = vzip1q_s16(uuz0, uuz1);
            let vv0 = vzip1q_s16(vvz0, vvz1);
            let uu1 = vzip2q_s16(uuz0, uuz1);
            let vv1 = vzip2q_s16(vvz0, vvz1);

            let y2_value = vmull_laneq_s16::<0>(vget_low_s16(y_value_hi), v_weights);
            let y3_value = vmull_high_laneq_s16::<0>(y_value_hi, v_weights);

            let r0 = vmlal_laneq_s16::<1>(y0_value, vget_low_s16(vv0), v_weights);
            let r1 = vmlal_high_laneq_s16::<1>(y1_value, vv0, v_weights);
            let r2 = vmlal_laneq_s16::<1>(y2_value, vget_low_s16(vv1), v_weights);
            let r3 = vmlal_high_laneq_s16::<1>(y3_value, vv1, v_weights);

            let b0 = vmlal_laneq_s16::<2>(y0_value, vget_low_s16(uu0), v_weights);
            let b1 = vmlal_high_laneq_s16::<2>(y1_value, uu0, v_weights);
            let b2 = vmlal_laneq_s16::<2>(y2_value, vget_low_s16(uu1), v_weights);
            let b3 = vmlal_high_laneq_s16::<2>(y3_value, uu1, v_weights);

            let mut g0 = vmlal_laneq_s16::<3>(y0_value, vget_low_s16(vv0), v_weights);
            let mut g1 = vmlal_high_laneq_s16::<3>(y1_value, vv0, v_weights);
            let mut g2 = vmlal_laneq_s16::<3>(y2_value, vget_low_s16(vv1), v_weights);
            let mut g3 = vmlal_high_laneq_s16::<3>(y3_value, vv1, v_weights);

            let r01 = vcombine_u16(vqrshrun_n_s32::<Q>(r0), vqrshrun_n_s32::<Q>(r1));
            let r23 = vcombine_u16(vqrshrun_n_s32::<Q>(r2), vqrshrun_n_s32::<Q>(r3));

            let b01 = vcombine_u16(vqrshrun_n_s32::<Q>(b0), vqrshrun_n_s32::<Q>(b1));
            let b23 = vcombine_u16(vqrshrun_n_s32::<Q>(b2), vqrshrun_n_s32::<Q>(b3));

            g0 = vmlal_laneq_s16::<4>(g0, vget_low_s16(uu0), v_weights);
            g1 = vmlal_high_laneq_s16::<4>(g1, uu0, v_weights);
            g2 = vmlal_laneq_s16::<4>(g2, vget_low_s16(uu1), v_weights);
            g3 = vmlal_high_laneq_s16::<4>(g3, uu1, v_weights);

            let g01 = vcombine_u16(vqrshrun_n_s32::<Q>(g0), vqrshrun_n_s32::<Q>(g1));
            let g23 = vcombine_u16(vqrshrun_n_s32::<Q>(g2), vqrshrun_n_s32::<Q>(g3));

            let r_values = vcombine_u8(vqmovn_u16(r01), vqmovn_u16(r23));
            let b_values = vcombine_u8(vqmovn_u16(b01), vqmovn_u16(b23));
            let g_values = vcombine_u8(vqmovn_u16(g01), vqmovn_u16(g23));

            let dst_shift = x * channels;

            neon_store_rgb8::<DESTINATION_CHANNELS>(
                rgba_store.as_mut_ptr().cast(),
                r_values,
                g_values,
                b_values,
                v_alpha,
            );

            std::ptr::copy_nonoverlapping(
                rgba_store.as_ptr().cast(),
                rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
                diff * channels,
            );
        }
    }
}
