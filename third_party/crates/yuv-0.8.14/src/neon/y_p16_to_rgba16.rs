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
use crate::neon::utils::{neon_store_rgb16, vldq_s16_endian};
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvSourceChannels};
use std::arch::aarch64::*;

pub(crate) unsafe fn neon_y_p16_to_rgba16_row<
    const DESTINATION_CHANNELS: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr: &[u16],
    rgba: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    start_cx: usize,
) -> ProcessedOffset {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();
    let dst_ptr = rgba;

    let y_corr = vdupq_n_u16(range.bias_y as u16);
    let v_luma_coeff = vdupq_n_u16(transform.y_coef as u16);
    let v_alpha = vdupq_n_u16((1 << BIT_DEPTH) - 1);
    let v_max_values = vdupq_n_u16((1 << BIT_DEPTH) - 1);
    let rnd_base = vdupq_n_u32(1 << (PRECISION - 1));

    let mut cx = start_cx;

    while cx + 8 < width as usize {
        let y_values = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        );

        let y_high = vmlal_high_u16(rnd_base, y_values, v_luma_coeff);
        let y_low = vmlal_u16(rnd_base, vget_low_u16(y_values), vget_low_u16(v_luma_coeff));

        let r_high = vqshrn_n_u32::<PRECISION>(y_high);
        let r_low = vqshrn_n_u32::<PRECISION>(y_low);

        let r_values = if BIT_DEPTH != 16 {
            vminq_u16(vcombine_u16(r_low, r_high), v_max_values)
        } else {
            vcombine_u16(r_low, r_high)
        };

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            dst_ptr.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values,
            r_values,
            r_values,
            v_alpha,
        );

        cx += 8;
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 8);

        let mut y_buffer: [u16; 8] = [0; 8];
        let mut dst_buffer: [u16; 8 * 4] = [0; 8 * 4];

        std::ptr::copy_nonoverlapping(
            y_ld_ptr.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr().cast(),
            diff,
        );

        let y_values = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_buffer.as_ptr().cast(),
            )),
            y_corr,
        );

        let y_high = vmlal_high_u16(rnd_base, y_values, v_luma_coeff);
        let y_low = vmlal_u16(rnd_base, vget_low_u16(y_values), vget_low_u16(v_luma_coeff));

        let r_high = vqshrn_n_u32::<PRECISION>(y_high);
        let r_low = vqshrn_n_u32::<PRECISION>(y_low);

        let r_values = if BIT_DEPTH != 16 {
            vminq_u16(vcombine_u16(r_low, r_high), v_max_values)
        } else {
            vcombine_u16(r_low, r_high)
        };

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            r_values,
            r_values,
            v_alpha,
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr().cast(),
            dst_ptr.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
    }

    ProcessedOffset { cx, ux: 0 }
}
