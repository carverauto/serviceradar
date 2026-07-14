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

// PRECISION is always expected to be 6 bits
pub(crate) unsafe fn neon_yuv_nv_to_rgba_fast_row420<
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
    let y_coeff = vdupq_n_u8(transform.y_coef as u8);
    let cr_coeff = vdup_n_s8(transform.cr_coef as i8);
    let cb_coeff = vdup_n_s8(transform.cb_coef as i8);
    let g_coeff_1 = vdup_n_s8(-transform.g_coeff_1 as i8);
    let g_coeff_2 = vdup_n_s8(-transform.g_coeff_2 as i8);

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

        let yhw0 = vreinterpretq_s16_u16(vmull_high_u8(y_values0, y_coeff));
        let yhw1 = vreinterpretq_s16_u16(vmull_high_u8(y_values1, y_coeff));
        let ylw0 = vreinterpretq_s16_u16(vmull_u8(vget_low_u8(y_values0), vget_low_u8(y_coeff)));
        let ylw1 = vreinterpretq_s16_u16(vmull_u8(vget_low_u8(y_values1), vget_low_u8(y_coeff)));

        let u_high = vreinterpret_s8_u8(vzip2_u8(uv_values.0, uv_values.0));
        let v_high = vreinterpret_s8_u8(vzip2_u8(uv_values.1, uv_values.1));
        let u_low = vreinterpret_s8_u8(vzip1_u8(uv_values.0, uv_values.0));
        let v_low = vreinterpret_s8_u8(vzip1_u8(uv_values.1, uv_values.1));

        let g_c_hi0 = vmlal_s8(yhw0, v_high, g_coeff_1);
        let g_c_lo0 = vmlal_s8(ylw0, v_low, g_coeff_1);
        let r_high0 = vmlal_s8(yhw0, v_high, cr_coeff);
        let r_low0 = vmlal_s8(ylw0, v_low, cr_coeff);
        let g_low0 = vmlal_s8(g_c_lo0, u_low, g_coeff_2);
        let g_high0 = vmlal_s8(g_c_hi0, u_high, g_coeff_2);
        let b_high0 = vmlal_s8(yhw0, u_high, cb_coeff);
        let b_low0 = vmlal_s8(ylw0, u_low, cb_coeff);

        let r_values0 = vcombine_u8(vqrshrun_n_s16::<6>(r_low0), vqrshrun_n_s16::<6>(r_high0));
        let g_values0 = vcombine_u8(vqrshrun_n_s16::<6>(g_low0), vqrshrun_n_s16::<6>(g_high0));
        let b_values0 = vcombine_u8(vqrshrun_n_s16::<6>(b_low0), vqrshrun_n_s16::<6>(b_high0));

        let g_c_hi1 = vmlal_s8(yhw1, v_high, g_coeff_1);
        let g_c_lo1 = vmlal_s8(ylw1, v_low, g_coeff_1);
        let r_high1 = vmlal_s8(yhw1, v_high, cr_coeff);
        let r_low1 = vmlal_s8(ylw1, v_low, cr_coeff);
        let b_high1 = vmlal_s8(yhw1, u_high, cb_coeff);
        let g_high1 = vmlal_s8(g_c_hi1, u_high, g_coeff_2);
        let b_low1 = vmlal_s8(ylw1, u_low, cb_coeff);
        let g_low1 = vmlal_s8(g_c_lo1, u_low, g_coeff_2);

        let r_values1 = vcombine_u8(vqrshrun_n_s16::<6>(r_low1), vqrshrun_n_s16::<6>(r_high1));
        let g_values1 = vcombine_u8(vqrshrun_n_s16::<6>(g_low1), vqrshrun_n_s16::<6>(g_high1));
        let b_values1 = vcombine_u8(vqrshrun_n_s16::<6>(b_low1), vqrshrun_n_s16::<6>(b_high1));

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

        let yhw0 = vreinterpretq_s16_u16(vmull_high_u8(y_values0, y_coeff));
        let yhw1 = vreinterpretq_s16_u16(vmull_high_u8(y_values1, y_coeff));
        let ylw0 = vreinterpretq_s16_u16(vmull_u8(vget_low_u8(y_values0), vget_low_u8(y_coeff)));
        let ylw1 = vreinterpretq_s16_u16(vmull_u8(vget_low_u8(y_values1), vget_low_u8(y_coeff)));

        let u_high = vreinterpret_s8_u8(vzip2_u8(uv_values.0, uv_values.0));
        let v_high = vreinterpret_s8_u8(vzip2_u8(uv_values.1, uv_values.1));
        let u_low = vreinterpret_s8_u8(vzip1_u8(uv_values.0, uv_values.0));
        let v_low = vreinterpret_s8_u8(vzip1_u8(uv_values.1, uv_values.1));

        let g_c_hi0 = vmlal_s8(yhw0, v_high, g_coeff_1);
        let g_c_lo0 = vmlal_s8(ylw0, v_low, g_coeff_1);
        let r_high0 = vmlal_s8(yhw0, v_high, cr_coeff);
        let r_low0 = vmlal_s8(ylw0, v_low, cr_coeff);
        let g_low0 = vmlal_s8(g_c_lo0, u_low, g_coeff_2);
        let g_high0 = vmlal_s8(g_c_hi0, u_high, g_coeff_2);
        let b_high0 = vmlal_s8(yhw0, u_high, cb_coeff);
        let b_low0 = vmlal_s8(ylw0, u_low, cb_coeff);

        let r_values0 = vcombine_u8(vqrshrun_n_s16::<6>(r_low0), vqrshrun_n_s16::<6>(r_high0));
        let g_values0 = vcombine_u8(vqrshrun_n_s16::<6>(g_low0), vqrshrun_n_s16::<6>(g_high0));
        let b_values0 = vcombine_u8(vqrshrun_n_s16::<6>(b_low0), vqrshrun_n_s16::<6>(b_high0));

        let g_c_hi1 = vmlal_s8(yhw1, v_high, g_coeff_1);
        let g_c_lo1 = vmlal_s8(ylw1, v_low, g_coeff_1);
        let r_high1 = vmlal_s8(yhw1, v_high, cr_coeff);
        let r_low1 = vmlal_s8(ylw1, v_low, cr_coeff);
        let b_high1 = vmlal_s8(yhw1, u_high, cb_coeff);
        let g_high1 = vmlal_s8(g_c_hi1, u_high, g_coeff_2);
        let b_low1 = vmlal_s8(ylw1, u_low, cb_coeff);
        let g_low1 = vmlal_s8(g_c_lo1, u_low, g_coeff_2);

        let r_values1 = vcombine_u8(vqrshrun_n_s16::<6>(r_low1), vqrshrun_n_s16::<6>(r_high1));
        let g_values1 = vcombine_u8(vqrshrun_n_s16::<6>(g_low1), vqrshrun_n_s16::<6>(g_high1));
        let b_values1 = vcombine_u8(vqrshrun_n_s16::<6>(b_low1), vqrshrun_n_s16::<6>(b_high1));

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
