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
use crate::yuv_support::{CbCrInverseTransform, YuvChromaRange, YuvSourceChannels};
use std::arch::aarch64::*;

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
/// Special path for Planar YUV 4:2:0 for aarch64 with RDM available
pub(crate) unsafe fn neon_yuv_to_rgba_row_rdm420<const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane0: &[u8],
    y_plane1: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba0: &mut [u8],
    rgba1: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    neon_yuv_to_rgba_row420_impl::<DESTINATION_CHANNELS, true>(
        range, transform, y_plane0, y_plane1, u_plane, v_plane, rgba0, rgba1, start_cx, start_ux,
        width,
    )
}

pub(crate) unsafe fn neon_yuv_to_rgba_row420<const DESTINATION_CHANNELS: u8>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane0: &[u8],
    y_plane1: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba0: &mut [u8],
    rgba1: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    neon_yuv_to_rgba_row420_impl::<DESTINATION_CHANNELS, false>(
        range, transform, y_plane0, y_plane1, u_plane, v_plane, rgba0, rgba1, start_cx, start_ux,
        width,
    )
}

#[inline(always)]
unsafe fn neon_yuv_to_rgba_row420_impl<const DESTINATION_CHANNELS: u8, const R: bool>(
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    y_plane0: &[u8],
    y_plane1: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    rgba0: &mut [u8],
    rgba1: &mut [u8],
    start_cx: usize,
    start_ux: usize,
    width: usize,
) -> ProcessedOffset {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();

    let mut cx = start_cx;
    let mut uv_x = start_ux;

    let u_ptr = u_plane.as_ptr();
    let v_ptr = v_plane.as_ptr();

    const SCALE: i32 = 2;

    let y_corr = vdupq_n_u8(range.bias_y as u8);
    let uv_corr = vdupq_n_u8(range.bias_uv as u8);
    let v_alpha = vdupq_n_u8(255u8);

    let weights_arr: [i16; 8] = [
        transform.y_coef as i16,
        transform.cr_coef as i16,
        transform.cb_coef as i16,
        transform.g_coeff_1 as i16,
        transform.g_coeff_2 as i16,
        0,
        0,
        0,
    ];

    let v_weights = vld1q_s16(weights_arr.as_ptr());

    while cx + 16 <= width {
        let vl0 = vld1q_u8(y_plane0.get_unchecked(cx..).as_ptr());
        let vl1 = vld1q_u8(y_plane1.get_unchecked(cx..).as_ptr());

        let mut u_values = vld1_u8(u_ptr.add(uv_x));
        let mut v_values = vld1_u8(v_ptr.add(uv_x));

        u_values = vsub_u8(u_values, vget_low_u8(uv_corr));
        v_values = vsub_u8(v_values, vget_low_u8(uv_corr));

        let y_values0 = vqsubq_u8(vl0, y_corr);
        let y_values1 = vqsubq_u8(vl1, y_corr);

        let u_high_u8 = vreinterpret_s8_u8(vzip2_u8(u_values, u_values));
        let v_high_u8 = vreinterpret_s8_u8(vzip2_u8(v_values, v_values));
        let u_low_u8 = vreinterpret_s8_u8(vzip1_u8(u_values, u_values));
        let v_low_u8 = vreinterpret_s8_u8(vzip1_u8(v_values, v_values));

        let u_high = vshll_n_s8::<SCALE>(u_high_u8);
        let v_high = vshll_n_s8::<SCALE>(v_high_u8);

        let y_v_shl0 = vexpand_high_8_to_10(y_values0);
        let y_v_shl1 = vexpand_high_8_to_10(y_values1);
        let y_high0 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl0), v_weights);
        let y_high1 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl1), v_weights);

        let g_coeff_hi = xqdmlahq_laneq_s16::<4, R>(
            xqdmulhq_laneq_s16::<3, R>(v_high, v_weights),
            u_high,
            v_weights,
        );

        let rhc0 = xqdmlahq_laneq_s16::<1, R>(y_high0, v_high, v_weights);
        let bhc0 = xqdmlahq_laneq_s16::<2, R>(y_high0, u_high, v_weights);
        let ghc0 = vsubq_s16(y_high0, g_coeff_hi);

        let rhc1 = xqdmlahq_laneq_s16::<1, R>(y_high1, v_high, v_weights);
        let bhc1 = xqdmlahq_laneq_s16::<2, R>(y_high1, u_high, v_weights);
        let ghc1 = vsubq_s16(y_high1, g_coeff_hi);

        let r_high0 = vqmovun_s16(rhc0);
        let b_high0 = vqmovun_s16(bhc0);
        let g_high0 = vqmovun_s16(ghc0);

        let r_high1 = vqmovun_s16(rhc1);
        let b_high1 = vqmovun_s16(bhc1);
        let g_high1 = vqmovun_s16(ghc1);

        let u_low = vshll_n_s8::<SCALE>(u_low_u8);
        let v_low = vshll_n_s8::<SCALE>(v_low_u8);

        let y_v_shl0 = vexpand8_to_10(vget_low_u8(y_values0));
        let y_v_shl1 = vexpand8_to_10(vget_low_u8(y_values1));
        let y_low0 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl0), v_weights);
        let y_low1 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl1), v_weights);

        let g_coeff_lo = xqdmlahq_laneq_s16::<4, R>(
            xqdmulhq_laneq_s16::<3, R>(v_low, v_weights),
            u_low,
            v_weights,
        );

        let rlc0 = xqdmlahq_laneq_s16::<1, R>(y_low0, v_low, v_weights);
        let blc0 = xqdmlahq_laneq_s16::<2, R>(y_low0, u_low, v_weights);
        let glc0 = vsubq_s16(y_low0, g_coeff_lo);

        let rlc1 = xqdmlahq_laneq_s16::<1, R>(y_low1, v_low, v_weights);
        let blc1 = xqdmlahq_laneq_s16::<2, R>(y_low1, u_low, v_weights);
        let glc1 = vsubq_s16(y_low1, g_coeff_lo);

        let r_low0 = vqmovun_s16(rlc0);
        let b_low0 = vqmovun_s16(blc0);
        let g_low0 = vqmovun_s16(glc0);

        let r_low1 = vqmovun_s16(rlc1);
        let b_low1 = vqmovun_s16(blc1);
        let g_low1 = vqmovun_s16(glc1);

        let r_values0 = vcombine_u8(r_low0, r_high0);
        let g_values0 = vcombine_u8(g_low0, g_high0);
        let b_values0 = vcombine_u8(b_low0, b_high0);

        let r_values1 = vcombine_u8(r_low1, r_high1);
        let g_values1 = vcombine_u8(g_low1, g_high1);
        let b_values1 = vcombine_u8(b_low1, b_high1);

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
        uv_x += 8;
    }

    while cx + 8 <= width {
        let vl0 = vld1_u8(y_plane0.get_unchecked(cx..).as_ptr());
        let vl1 = vld1_u8(y_plane1.get_unchecked(cx..).as_ptr());

        let mut u_values = vreinterpret_u8_u32(vld1_dup_u32(u_ptr.add(uv_x) as *const u32));
        let mut v_values = vreinterpret_u8_u32(vld1_dup_u32(v_ptr.add(uv_x) as *const u32));

        u_values = vsub_u8(u_values, vget_low_u8(uv_corr));
        v_values = vsub_u8(v_values, vget_low_u8(uv_corr));

        let y_values0 = vqsub_u8(vl0, vget_low_u8(y_corr));
        let y_values1 = vqsub_u8(vl1, vget_low_u8(y_corr));

        let u_low_u8 = vreinterpret_s8_u8(vzip1_u8(u_values, u_values));
        let v_low_u8 = vreinterpret_s8_u8(vzip1_u8(v_values, v_values));

        let u_low = vshll_n_s8::<SCALE>(u_low_u8);
        let v_low = vshll_n_s8::<SCALE>(v_low_u8);
        let y_v_shl0 = vexpand8_to_10(y_values0);
        let y_v_shl1 = vexpand8_to_10(y_values1);
        let y_low0 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl0), v_weights);
        let y_low1 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl1), v_weights);

        let gcl = xqdmulhq_laneq_s16::<3, R>(v_low, v_weights);
        let r0l = xqdmlahq_laneq_s16::<1, R>(y_low0, v_low, v_weights);
        let b0l = xqdmlahq_laneq_s16::<2, R>(y_low0, u_low, v_weights);
        let g_coeff_lo = xqdmlahq_laneq_s16::<4, R>(gcl, u_low, v_weights);
        let r1l = xqdmlahq_laneq_s16::<1, R>(y_low1, v_low, v_weights);
        let b1l = xqdmlahq_laneq_s16::<2, R>(y_low1, u_low, v_weights);

        let r0 = vqmovun_s16(r0l);
        let b0 = vqmovun_s16(b0l);
        let g0 = vqmovun_s16(vsubq_s16(y_low0, g_coeff_lo));

        let r1 = vqmovun_s16(r1l);
        let b1 = vqmovun_s16(b1l);
        let g1 = vqmovun_s16(vsubq_s16(y_low1, g_coeff_lo));

        let dst_shift = cx * channels;

        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r0,
            g0,
            b0,
            vget_low_u8(v_alpha),
        );
        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r1,
            g1,
            b1,
            vget_low_u8(v_alpha),
        );

        cx += 8;
        uv_x += 4;
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 8);

        let mut dst_buffer0: [u8; 8 * 4] = [0; 8 * 4];
        let mut dst_buffer1: [u8; 8 * 4] = [0; 8 * 4];
        let mut y_buffer0: [u8; 8] = [0; 8];
        let mut y_buffer1: [u8; 8] = [0; 8];
        let mut u_buffer: [u8; 8] = [0; 8];
        let mut v_buffer: [u8; 8] = [0; 8];

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

        let half_div = diff.div_ceil(2);

        std::ptr::copy_nonoverlapping(
            u_plane.get_unchecked(uv_x..).as_ptr(),
            u_buffer.as_mut_ptr().cast(),
            half_div,
        );

        std::ptr::copy_nonoverlapping(
            v_plane.get_unchecked(uv_x..).as_ptr(),
            v_buffer.as_mut_ptr().cast(),
            half_div,
        );

        let vl0 = vld1_u8(y_buffer0.as_ptr().cast());
        let vl1 = vld1_u8(y_buffer1.as_ptr().cast());

        let mut u_values = vreinterpret_u8_u32(vld1_dup_u32(u_buffer.as_ptr() as *const u32));
        let mut v_values = vreinterpret_u8_u32(vld1_dup_u32(v_buffer.as_ptr() as *const u32));

        u_values = vsub_u8(u_values, vget_low_u8(uv_corr));
        v_values = vsub_u8(v_values, vget_low_u8(uv_corr));

        let y_values0 = vqsub_u8(vl0, vget_low_u8(y_corr));
        let y_values1 = vqsub_u8(vl1, vget_low_u8(y_corr));

        let u_low_u8 = vreinterpret_s8_u8(vzip1_u8(u_values, u_values));
        let v_low_u8 = vreinterpret_s8_u8(vzip1_u8(v_values, v_values));

        let u_low = vshll_n_s8::<SCALE>(u_low_u8);
        let v_low = vshll_n_s8::<SCALE>(v_low_u8);
        let y_v_shl0 = vexpand8_to_10(y_values0);
        let y_v_shl1 = vexpand8_to_10(y_values1);
        let y_low0 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl0), v_weights);
        let y_low1 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl1), v_weights);

        let gcl = xqdmulhq_laneq_s16::<3, R>(v_low, v_weights);
        let r0l = xqdmlahq_laneq_s16::<1, R>(y_low0, v_low, v_weights);
        let b0l = xqdmlahq_laneq_s16::<2, R>(y_low0, u_low, v_weights);
        let g_coeff_lo = xqdmlahq_laneq_s16::<4, R>(gcl, u_low, v_weights);
        let r1l = xqdmlahq_laneq_s16::<1, R>(y_low1, v_low, v_weights);
        let b1l = xqdmlahq_laneq_s16::<2, R>(y_low1, u_low, v_weights);

        let r0 = vqmovun_s16(r0l);
        let b0 = vqmovun_s16(b0l);
        let g0 = vqmovun_s16(vsubq_s16(y_low0, g_coeff_lo));

        let r1 = vqmovun_s16(r1l);
        let b1 = vqmovun_s16(b1l);
        let g1 = vqmovun_s16(vsubq_s16(y_low1, g_coeff_lo));

        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer0.as_mut_ptr().cast(),
            r0,
            g0,
            b0,
            vget_low_u8(v_alpha),
        );
        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer1.as_mut_ptr().cast(),
            r1,
            g1,
            b1,
            vget_low_u8(v_alpha),
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
        uv_x += half_div;
    }

    ProcessedOffset { cx, ux: uv_x }
}
