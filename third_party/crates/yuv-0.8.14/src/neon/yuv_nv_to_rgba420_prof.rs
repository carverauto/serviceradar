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
use crate::neon::utils::*;
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvNVOrder, YuvSourceChannels};
use std::arch::aarch64::*;

pub(crate) unsafe fn neon_yuv_nv_to_rgba_row420_prof<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane0: &[u8],
    y_plane1: &[u8],
    uv_plane: &[u8],
    rgba0: &mut [u8],
    rgba1: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let order: YuvNVOrder = UV_ORDER.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let uv_ptr = uv_plane.as_ptr();

    let y_corr = vdupq_n_u8(range.bias_y as u8);
    let uv_corr = vdup_n_u8(range.bias_uv as u8);

    // CbCoeff is almost always overflowing using 14 bits of precision, so we dividing it into 2 parts
    // to avoid overflow
    // y_value + cb_coef * cb_value instead will be used:
    // y_value + (cb_coef - i16::MAX) * cb_value + i16::MAX * cb_value

    let weights_arr: [i16; 8] = [
        transform.y_coef as i16,
        transform.cr_coef as i16,
        (transform.cb_coef - i16::MAX as i32) as i16,
        i16::MAX,
        -transform.g_coeff_1 as i16,
        -transform.g_coeff_2 as i16,
        0,
        0,
    ];

    const PRECISION: i32 = 15;

    let b_y = vdupq_n_s32(1 << (PRECISION - 1));

    let v_weights = vld1q_s16(weights_arr.as_ptr());

    let v_alpha = vdupq_n_u8(255u8);

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 16 <= width {
        let vl0 = vld1q_u8(y_plane0.get_unchecked(cx..).as_ptr());
        let vl1 = vld1q_u8(y_plane1.get_unchecked(cx..).as_ptr());

        let mut uv_values = vld2_u8(uv_ptr.add(ux));

        let y_values0 = vqsubq_u8(vl0, y_corr);
        let y_values1 = vqsubq_u8(vl1, y_corr);

        if order == YuvNVOrder::VU {
            uv_values = uint8x8x2_t(uv_values.1, uv_values.0);
        }

        uv_values.0 = vsub_u8(uv_values.0, uv_corr);
        uv_values.1 = vsub_u8(uv_values.1, uv_corr);

        let u_high_u8 = vreinterpret_s8_u8(vzip2_u8(uv_values.0, uv_values.0));
        let v_high_u8 = vreinterpret_s8_u8(vzip2_u8(uv_values.1, uv_values.1));
        let u_low_u8 = vreinterpret_s8_u8(vzip1_u8(uv_values.0, uv_values.0));
        let v_low_u8 = vreinterpret_s8_u8(vzip1_u8(uv_values.1, uv_values.1));

        let uhw = vmovl_s8(u_high_u8);
        let vhw = vmovl_s8(v_high_u8);
        let yhw0 = vreinterpretq_s16_u16(vmovl_high_u8(y_values0));
        let yhw1 = vreinterpretq_s16_u16(vmovl_high_u8(y_values1));

        let y_high0 = vqdmalq_laneq_s16::<0>(b_y, yhw0, v_weights);
        let y_high1 = vqdmalq_laneq_s16::<0>(b_y, yhw1, v_weights);

        let g_coeff_hi = vqdweight_laneq_x2::<4, 5>(vhw, uhw, v_weights);

        let r_high0 = vqddotl_laneq_s16::<PRECISION, 1>(y_high0, vhw, v_weights);
        let b_high0 = vqddotl_overflow_laneq_s16::<PRECISION, 2, 3>(y_high0, uhw, v_weights);
        let g_high0 = vaddn_dot::<PRECISION>(y_high0, g_coeff_hi);

        let r_high1 = vqddotl_laneq_s16::<PRECISION, 1>(y_high1, vhw, v_weights);
        let b_high1 = vqddotl_overflow_laneq_s16::<PRECISION, 2, 3>(y_high1, uhw, v_weights);
        let g_high1 = vaddn_dot::<PRECISION>(y_high1, g_coeff_hi);

        let ulw = vmovl_s8(u_low_u8);
        let vlw = vmovl_s8(v_low_u8);
        let ylw0 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values0)));
        let ylw1 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values1)));

        let y_low0 = vqdmalq_laneq_s16::<0>(b_y, ylw0, v_weights);
        let y_low1 = vqdmalq_laneq_s16::<0>(b_y, ylw1, v_weights);

        let g_coeff_lo = vqdweight_laneq_x2::<4, 5>(vlw, ulw, v_weights);

        let r_low0 = vqddotl_laneq_s16::<PRECISION, 1>(y_low0, vlw, v_weights);
        let b_low0 = vqddotl_overflow_laneq_s16::<PRECISION, 2, 3>(y_low0, ulw, v_weights);
        let g_low0 = vaddn_dot::<PRECISION>(y_low0, g_coeff_lo);

        let r_low1 = vqddotl_laneq_s16::<PRECISION, 1>(y_low1, vlw, v_weights);
        let b_low1 = vqddotl_overflow_laneq_s16::<PRECISION, 2, 3>(y_low1, ulw, v_weights);
        let g_low1 = vaddn_dot::<PRECISION>(y_low1, g_coeff_lo);

        let r_values0 = vcombine_u8(vqmovun_s16(r_low0), vqmovun_s16(r_high0));
        let g_values0 = vcombine_u8(vqmovun_s16(g_low0), vqmovun_s16(g_high0));
        let b_values0 = vcombine_u8(vqmovun_s16(b_low0), vqmovun_s16(b_high0));

        let r_values1 = vcombine_u8(vqmovun_s16(r_low1), vqmovun_s16(r_high1));
        let g_values1 = vcombine_u8(vqmovun_s16(g_low1), vqmovun_s16(g_high1));
        let b_values1 = vcombine_u8(vqmovun_s16(b_low1), vqmovun_s16(b_high1));

        let dst_shift = cx * channels;

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );
        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values1,
            g_values1,
            b_values1,
            v_alpha,
        );

        cx += 16;
        ux += 16;
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 16);

        let mut dst_buffer0: [u8; 16 * 4] = [0; 16 * 4];
        let mut dst_buffer1: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer0: [u8; 16] = [0; 16];
        let mut y_buffer1: [u8; 16] = [0; 16];
        let mut uv_buffer: [u8; 16 * 2] = [0; 16 * 2];

        std::ptr::copy_nonoverlapping(
            y_plane0.get_unchecked(cx..).as_ptr(),
            y_buffer0.as_mut_ptr().cast(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            y_plane1.get_unchecked(cx..).as_ptr(),
            y_buffer1.as_mut_ptr().cast(),
            diff,
        );

        let hv = diff.div_ceil(2) * 2;

        std::ptr::copy_nonoverlapping(
            uv_plane.get_unchecked(ux..).as_ptr(),
            uv_buffer.as_mut_ptr().cast(),
            hv,
        );

        let vl0 = vld1q_u8(y_buffer0.as_ptr().cast());
        let vl1 = vld1q_u8(y_buffer1.as_ptr().cast());

        let mut uv_values = vld2_u8(uv_buffer.as_ptr().cast());

        let y_values0 = vqsubq_u8(vl0, y_corr);
        let y_values1 = vqsubq_u8(vl1, y_corr);

        if order == YuvNVOrder::VU {
            uv_values = uint8x8x2_t(uv_values.1, uv_values.0);
        }

        uv_values.0 = vsub_u8(uv_values.0, uv_corr);
        uv_values.1 = vsub_u8(uv_values.1, uv_corr);

        let u_high_u8 = vreinterpret_s8_u8(vzip2_u8(uv_values.0, uv_values.0));
        let v_high_u8 = vreinterpret_s8_u8(vzip2_u8(uv_values.1, uv_values.1));
        let u_low_u8 = vreinterpret_s8_u8(vzip1_u8(uv_values.0, uv_values.0));
        let v_low_u8 = vreinterpret_s8_u8(vzip1_u8(uv_values.1, uv_values.1));

        let uhw = vmovl_s8(u_high_u8);
        let vhw = vmovl_s8(v_high_u8);
        let yhw0 = vreinterpretq_s16_u16(vmovl_high_u8(y_values0));
        let yhw1 = vreinterpretq_s16_u16(vmovl_high_u8(y_values1));

        let y_high0 = vqdmalq_laneq_s16::<0>(b_y, yhw0, v_weights);
        let y_high1 = vqdmalq_laneq_s16::<0>(b_y, yhw1, v_weights);

        let g_coeff_hi = vqdweight_laneq_x2::<4, 5>(vhw, uhw, v_weights);

        let r_high0 = vqddotl_laneq_s16::<PRECISION, 1>(y_high0, vhw, v_weights);
        let b_high0 = vqddotl_overflow_laneq_s16::<PRECISION, 2, 3>(y_high0, uhw, v_weights);
        let g_high0 = vaddn_dot::<PRECISION>(y_high0, g_coeff_hi);

        let r_high1 = vqddotl_laneq_s16::<PRECISION, 1>(y_high1, vhw, v_weights);
        let b_high1 = vqddotl_overflow_laneq_s16::<PRECISION, 2, 3>(y_high1, uhw, v_weights);
        let g_high1 = vaddn_dot::<PRECISION>(y_high1, g_coeff_hi);

        let ulw = vmovl_s8(u_low_u8);
        let vlw = vmovl_s8(v_low_u8);
        let ylw0 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values0)));
        let ylw1 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values1)));

        let y_low0 = vqdmalq_laneq_s16::<0>(b_y, ylw0, v_weights);
        let y_low1 = vqdmalq_laneq_s16::<0>(b_y, ylw1, v_weights);

        let g_coeff_lo = vqdweight_laneq_x2::<4, 5>(vlw, ulw, v_weights);

        let r_low0 = vqddotl_laneq_s16::<PRECISION, 1>(y_low0, vlw, v_weights);
        let b_low0 = vqddotl_overflow_laneq_s16::<PRECISION, 2, 3>(y_low0, ulw, v_weights);
        let g_low0 = vaddn_dot::<PRECISION>(y_low0, g_coeff_lo);

        let r_low1 = vqddotl_laneq_s16::<PRECISION, 1>(y_low1, vlw, v_weights);
        let b_low1 = vqddotl_overflow_laneq_s16::<PRECISION, 2, 3>(y_low1, ulw, v_weights);
        let g_low1 = vaddn_dot::<PRECISION>(y_low1, g_coeff_lo);

        let r_values0 = vcombine_u8(vqmovun_s16(r_low0), vqmovun_s16(r_high0));
        let g_values0 = vcombine_u8(vqmovun_s16(g_low0), vqmovun_s16(g_high0));
        let b_values0 = vcombine_u8(vqmovun_s16(b_low0), vqmovun_s16(b_high0));

        let r_values1 = vcombine_u8(vqmovun_s16(r_low1), vqmovun_s16(r_high1));
        let g_values1 = vcombine_u8(vqmovun_s16(g_low1), vqmovun_s16(g_high1));
        let b_values1 = vcombine_u8(vqmovun_s16(b_low1), vqmovun_s16(b_high1));

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer0.as_mut_ptr().cast(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );
        neon_store_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer1.as_mut_ptr().cast(),
            r_values1,
            g_values1,
            b_values1,
            v_alpha,
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer0.as_mut_ptr().cast(),
            rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        std::ptr::copy_nonoverlapping(
            dst_buffer1.as_mut_ptr().cast(),
            rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        ux += hv;
    }

    ProcessedOffset { cx, ux }
}
