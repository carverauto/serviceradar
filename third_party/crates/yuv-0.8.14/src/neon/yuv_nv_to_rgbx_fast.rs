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
use crate::YuvChromaSubsampling;
use std::arch::aarch64::*;

// PRECISION is always expected to be 6 bits
pub(crate) unsafe fn neon_yuv_nv_to_rgba_fast_row<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    uv_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let order: YuvNVOrder = UV_ORDER.into();
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let sampling: YuvChromaSubsampling = SAMPLING.into();
    let channels = destination_channels.get_channels_count();

    let uv_ptr = uv_plane.as_ptr();

    let y_corr = vdupq_n_u8(range.bias_y as u8);
    let uv_corr = vdupq_n_u8(range.bias_uv as u8);
    let y_coeff = vdupq_n_u8(transform.y_coef as u8);
    let cr_coeff = vdup_n_s8(transform.cr_coef as i8);
    let cb_coeff = vdup_n_s8(transform.cb_coef as i8);
    let g_coeff_1 = vdup_n_s8(-transform.g_coeff_1 as i8);
    let g_coeff_2 = vdup_n_s8(-transform.g_coeff_2 as i8);

    let v_alpha = vdupq_n_u8(255u8);

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 16 <= width {
        let vl0 = vld1q_u8(y_plane.get_unchecked(cx..).as_ptr());

        let y_values0 = vqsubq_u8(vl0, y_corr);
        let (u_high, v_high, u_low, v_low);

        match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut uv_values = vld2_u8(uv_ptr.add(ux));

                if order == YuvNVOrder::VU {
                    uv_values = uint8x8x2_t(uv_values.1, uv_values.0);
                }

                uv_values.0 = vsub_u8(uv_values.0, vget_low_u8(uv_corr));
                uv_values.1 = vsub_u8(uv_values.1, vget_low_u8(uv_corr));

                u_high = vreinterpret_s8_u8(vzip2_u8(uv_values.0, uv_values.0));
                v_high = vreinterpret_s8_u8(vzip2_u8(uv_values.1, uv_values.1));
                u_low = vreinterpret_s8_u8(vzip1_u8(uv_values.0, uv_values.0));
                v_low = vreinterpret_s8_u8(vzip1_u8(uv_values.1, uv_values.1));
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut uv_values = vld2q_u8(uv_ptr.add(ux));

                if order == YuvNVOrder::VU {
                    uv_values = uint8x16x2_t(uv_values.1, uv_values.0);
                }

                uv_values.0 = vsubq_u8(uv_values.0, uv_corr);
                uv_values.1 = vsubq_u8(uv_values.1, uv_corr);

                u_high = vreinterpret_s8_u8(vget_high_u8(uv_values.0));
                v_high = vreinterpret_s8_u8(vget_high_u8(uv_values.1));
                u_low = vreinterpret_s8_u8(vget_low_u8(uv_values.0));
                v_low = vreinterpret_s8_u8(vget_low_u8(uv_values.1));
            }
        }

        let yhw0 = vreinterpretq_s16_u16(vmull_high_u8(y_values0, y_coeff));
        let ylw0 = vreinterpretq_s16_u16(vmull_u8(vget_low_u8(y_values0), vget_low_u8(y_coeff)));

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

        let dst_shift = cx * channels;

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );

        cx += 16;
        ux += match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => 16,
            YuvChromaSubsampling::Yuv444 => 32,
        };
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 16);

        let mut dst_buffer0: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer0: [u8; 16] = [0; 16];
        let mut uv_buffer: [u8; 16 * 2] = [0; 16 * 2];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer0.as_mut_ptr().cast(),
            diff,
        );

        let hv = match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2) * 2,
            YuvChromaSubsampling::Yuv444 => diff * 2,
        };

        std::ptr::copy_nonoverlapping(
            uv_plane.get_unchecked(ux..).as_ptr(),
            uv_buffer.as_mut_ptr().cast(),
            hv,
        );

        let vl0 = vld1q_u8(y_buffer0.as_ptr().cast());

        let y_values0 = vqsubq_u8(vl0, y_corr);
        let (u_high, v_high, u_low, v_low);

        match sampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut uv_values = vld2_u8(uv_buffer.as_ptr().cast());

                if order == YuvNVOrder::VU {
                    uv_values = uint8x8x2_t(uv_values.1, uv_values.0);
                }

                uv_values.0 = vsub_u8(uv_values.0, vget_low_u8(uv_corr));
                uv_values.1 = vsub_u8(uv_values.1, vget_low_u8(uv_corr));

                u_high = vreinterpret_s8_u8(vzip2_u8(uv_values.0, uv_values.0));
                v_high = vreinterpret_s8_u8(vzip2_u8(uv_values.1, uv_values.1));
                u_low = vreinterpret_s8_u8(vzip1_u8(uv_values.0, uv_values.0));
                v_low = vreinterpret_s8_u8(vzip1_u8(uv_values.1, uv_values.1));
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut uv_values = vld2q_u8(uv_buffer.as_ptr().cast());

                if order == YuvNVOrder::VU {
                    uv_values = uint8x16x2_t(uv_values.1, uv_values.0);
                }

                uv_values.0 = vsubq_u8(uv_values.0, uv_corr);
                uv_values.1 = vsubq_u8(uv_values.1, uv_corr);

                u_high = vreinterpret_s8_u8(vget_high_u8(uv_values.0));
                v_high = vreinterpret_s8_u8(vget_high_u8(uv_values.1));
                u_low = vreinterpret_s8_u8(vget_low_u8(uv_values.0));
                v_low = vreinterpret_s8_u8(vget_low_u8(uv_values.1));
            }
        }

        let yhw0 = vreinterpretq_s16_u16(vmull_high_u8(y_values0, y_coeff));
        let ylw0 = vreinterpretq_s16_u16(vmull_u8(vget_low_u8(y_values0), vget_low_u8(y_coeff)));

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

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer0.as_mut_ptr().cast(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer0.as_mut_ptr().cast(),
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        ux += hv;
    }

    ProcessedOffset { cx, ux }
}
