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

use crate::neon::utils::*;
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvSourceChannels};
use std::arch::aarch64::*;

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
pub(crate) unsafe fn neon_y_to_rgb_row_rdm<const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) {
    neon_y_to_rgb_row_impl::<DESTINATION_CHANNELS, true>(
        range, transform, y_plane, rgba, start_cx, width,
    )
}

pub(crate) unsafe fn neon_y_to_rgb_row<const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) {
    neon_y_to_rgb_row_impl::<DESTINATION_CHANNELS, false>(
        range, transform, y_plane, rgba, start_cx, width,
    )
}

#[inline(always)]
unsafe fn neon_y_to_rgb_row_impl<const DESTINATION_CHANNELS: u8, const R: bool>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane: &[u8],
    rgba: &mut [u8],
    start_cx: usize,
    width: usize,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let rgba_ptr = rgba.as_mut_ptr();

    let y_corr = vdupq_n_u8(range.bias_y as u8);
    let v_alpha = vdupq_n_u8(255u8);

    let mut cx = start_cx;

    while cx + 32 <= width {
        let y_vals = xvld1q_u8_x2(y_plane.get_unchecked(cx..).as_ptr());
        let y_values0 = vqsubq_u8(y_vals.0, y_corr);
        let y_values1 = vqsubq_u8(y_vals.1, y_corr);

        let yh0 = vexpand_high_8_to_10(y_values0);
        let yl0 = vexpand8_to_10(vget_low_u8(y_values0));
        let yh1 = vexpand_high_8_to_10(y_values1);
        let yl1 = vexpand8_to_10(vget_low_u8(y_values1));

        let y_high0 = xqdmulhq_n_s16::<R>(vreinterpretq_s16_u16(yh0), transform.y_coef as i16);
        let y_low0 = xqdmulhq_n_s16::<R>(vreinterpretq_s16_u16(yl0), transform.y_coef as i16);
        let y_high1 = xqdmulhq_n_s16::<R>(vreinterpretq_s16_u16(yh1), transform.y_coef as i16);
        let y_low1 = xqdmulhq_n_s16::<R>(vreinterpretq_s16_u16(yl1), transform.y_coef as i16);

        let r_high0 = vqmovun_s16(y_high0);
        let r_high1 = vqmovun_s16(y_high1);

        let r_low0 = vqmovun_s16(y_low0);
        let r_low1 = vqmovun_s16(y_low1);

        let r_values0 = vcombine_u8(r_low0, r_high0);
        let r_values1 = vcombine_u8(r_low1, r_high1);

        let dst_shift = cx * channels;

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_values0,
            r_values0,
            r_values0,
            v_alpha,
        );

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift + channels * 16),
            r_values1,
            r_values1,
            r_values1,
            v_alpha,
        );

        cx += 32;
    }

    while cx + 16 <= width {
        let y_values = vqsubq_u8(vld1q_u8(y_plane.get_unchecked(cx..).as_ptr()), y_corr);

        let yh = vexpand_high_8_to_10(y_values);
        let yl = vexpand8_to_10(vget_low_u8(y_values));

        let y_high = xqdmulhq_n_s16::<R>(vreinterpretq_s16_u16(yh), transform.y_coef as i16);
        let y_low = xqdmulhq_n_s16::<R>(vreinterpretq_s16_u16(yl), transform.y_coef as i16);

        let r_high = vqmovun_s16(y_high);

        let r_low = vqmovun_s16(y_low);

        let r_values = vcombine_u8(r_low, r_high);

        let dst_shift = cx * channels;

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_values,
            r_values,
            r_values,
            v_alpha,
        );

        cx += 16;
    }

    while cx + 8 <= width {
        let y_values = vqsub_u8(
            vld1_u8(y_plane.get_unchecked(cx..).as_ptr()),
            vget_low_u8(y_corr),
        );

        let y_high = xqdmulhq_n_s16::<R>(
            vreinterpretq_s16_u16(vexpand8_to_10(y_values)),
            transform.y_coef as i16,
        );

        let r_vl = vqmovun_s16(y_high);

        let dst_shift = cx * channels;

        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            rgba_ptr.add(dst_shift),
            r_vl,
            r_vl,
            r_vl,
            vget_low_u8(v_alpha),
        );

        cx += 8;
    }

    if cx < width {
        let diff = width - cx;
        assert!(diff <= 8);

        let mut y_buffer: [u8; 8] = [0; 8];
        let mut dst_buffer: [u8; 8 * 4] = [0; 8 * 4];
        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr().cast(),
            diff,
        );

        let y_values = vqsub_u8(vld1_u8(y_buffer.as_ptr().cast()), vget_low_u8(y_corr));

        let y_high = xqdmulhq_n_s16::<R>(
            vreinterpretq_s16_u16(vexpand8_to_10(y_values)),
            transform.y_coef as i16,
        );

        let r_vl = vqmovun_s16(y_high);

        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_vl,
            r_vl,
            r_vl,
            vget_low_u8(v_alpha),
        );

        let dst_shift = cx * channels;

        std::ptr::copy_nonoverlapping(
            dst_buffer.as_ptr().cast(),
            rgba_ptr.add(dst_shift),
            diff * channels,
        );
    }
}
