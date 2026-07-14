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

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
/// Special path for BiPlanar YUV 4:2:0 for aarch64 with RDM available
pub(crate) unsafe fn neon_yuv_nv_to_rgba_row_rdm420<
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
    neon_yuv_nv_to_rgba_row_h_impl::<UV_ORDER, DESTINATION_CHANNELS, true>(
        range, transform, y_plane0, y_plane1, uv_plane, rgba0, rgba1, start_cx, start_ux, width,
    )
}

pub(crate) unsafe fn neon_yuv_nv_to_rgba_row420<
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
    neon_yuv_nv_to_rgba_row_h_impl::<UV_ORDER, DESTINATION_CHANNELS, false>(
        range, transform, y_plane0, y_plane1, uv_plane, rgba0, rgba1, start_cx, start_ux, width,
    )
}

#[inline(always)]
unsafe fn neon_yuv_nv_to_rgba_row_h_impl<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const R: bool,
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

    const SCALE: i32 = 2;

    let y_corr = vdupq_n_u8(range.bias_y as u8);
    let uv_corr = vdupq_n_u8(range.bias_uv as u8);
    let v_alpha = vdupq_n_u8(255u8);

    let mut cx = start_cx;
    let mut ux = start_ux;

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

    while cx + 32 <= width {
        let y_values_0 = xvld1q_u8_x2(y_plane0.get_unchecked(cx..).as_ptr());
        let y_values_1 = xvld1q_u8_x2(y_plane1.get_unchecked(cx..).as_ptr());
        let mut uv_values = vld2q_u8(uv_ptr.add(ux));

        uv_values.0 = vsubq_u8(uv_values.0, uv_corr);
        uv_values.1 = vsubq_u8(uv_values.1, uv_corr);

        let y_values00 = vqsubq_u8(y_values_0.0, y_corr);
        let y_values01 = vqsubq_u8(y_values_0.1, y_corr);
        let y_values10 = vqsubq_u8(y_values_1.0, y_corr);
        let y_values11 = vqsubq_u8(y_values_1.1, y_corr);

        if order == YuvNVOrder::VU {
            uv_values = uint8x16x2_t(uv_values.1, uv_values.0);
        }

        let u_high_u8 = vreinterpretq_s8_u8(vzip2q_u8(uv_values.0, uv_values.0));
        let v_high_u8 = vreinterpretq_s8_u8(vzip2q_u8(uv_values.1, uv_values.1));

        let u_low_u8 = vreinterpretq_s8_u8(vzip1q_u8(uv_values.0, uv_values.0));
        let v_low_u8 = vreinterpretq_s8_u8(vzip1q_u8(uv_values.1, uv_values.1));

        let uhw00 = vshll_high_n_s8::<SCALE>(u_low_u8);
        let vhw00 = vshll_high_n_s8::<SCALE>(v_low_u8);

        let y_v_shl00 = vexpand_high_8_to_10(y_values00);
        let y_v_shl10 = vexpand_high_8_to_10(y_values10);

        let y_high00 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl00), v_weights);
        let y_high10 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl10), v_weights);

        let g_coeff_hi00 = xqdmlahq_laneq_s16::<4, R>(
            xqdmulhq_laneq_s16::<3, R>(vhw00, v_weights),
            uhw00,
            v_weights,
        );

        let rh00 = xqdmlahq_laneq_s16::<1, R>(y_high00, vhw00, v_weights);
        let bh00 = xqdmlahq_laneq_s16::<2, R>(y_high00, uhw00, v_weights);
        let gh00 = vsubq_s16(y_high00, g_coeff_hi00);
        let rh10 = xqdmlahq_laneq_s16::<1, R>(y_high10, vhw00, v_weights);
        let bh10 = xqdmlahq_laneq_s16::<2, R>(y_high10, uhw00, v_weights);
        let gh10 = vsubq_s16(y_high10, g_coeff_hi00);

        let r_high00 = vqmovun_s16(rh00);
        let b_high00 = vqmovun_s16(bh00);
        let g_high00 = vqmovun_s16(gh00);

        let r_high10 = vqmovun_s16(rh10);
        let b_high10 = vqmovun_s16(bh10);
        let g_high10 = vqmovun_s16(gh10);

        let uw0 = vshll_n_s8::<SCALE>(vget_low_s8(u_low_u8));
        let vw0 = vshll_n_s8::<SCALE>(vget_low_s8(v_low_u8));

        let y_v_shl00 = vexpand8_to_10(vget_low_u8(y_values00));
        let y_v_shl10 = vexpand8_to_10(vget_low_u8(y_values10));

        let y_low00 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl00), v_weights);
        let y_low10 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl10), v_weights);

        let g_coeff_lo00 =
            xqdmlahq_laneq_s16::<4, R>(xqdmulhq_laneq_s16::<3, R>(vw0, v_weights), uw0, v_weights);

        let rl00 = xqdmlahq_laneq_s16::<1, R>(y_low00, vw0, v_weights);
        let bl00 = xqdmlahq_laneq_s16::<2, R>(y_low00, uw0, v_weights);
        let gl00 = vsubq_s16(y_low00, g_coeff_lo00);
        let rl10 = xqdmlahq_laneq_s16::<1, R>(y_low10, vw0, v_weights);
        let bl10 = xqdmlahq_laneq_s16::<2, R>(y_low10, uw0, v_weights);
        let gl10 = vsubq_s16(y_low10, g_coeff_lo00);

        let r_low00 = vqmovun_s16(rl00);
        let b_low00 = vqmovun_s16(bl00);
        let g_low00 = vqmovun_s16(gl00);

        let r_low10 = vqmovun_s16(rl10);
        let b_low10 = vqmovun_s16(bl10);
        let g_low10 = vqmovun_s16(gl10);

        let r_values0 = vcombine_u8(r_low00, r_high00);
        let g_values0 = vcombine_u8(g_low00, g_high00);
        let b_values0 = vcombine_u8(b_low00, b_high00);

        let r_values1 = vcombine_u8(r_low10, r_high10);
        let g_values1 = vcombine_u8(g_low10, g_high10);
        let b_values1 = vcombine_u8(b_low10, b_high10);

        let u_high01 = vshll_high_n_s8::<SCALE>(u_high_u8);
        let v_high01 = vshll_high_n_s8::<SCALE>(v_high_u8);

        let y_v_shl01 = vexpand_high_8_to_10(y_values01);
        let y_v_shl11 = vexpand_high_8_to_10(y_values11);

        let y_high01 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl01), v_weights);
        let y_high11 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl11), v_weights);

        let g_coeff_hi01 = xqdmlahq_laneq_s16::<4, R>(
            xqdmulhq_laneq_s16::<3, R>(v_high01, v_weights),
            u_high01,
            v_weights,
        );

        let rh01 = xqdmlahq_laneq_s16::<1, R>(y_high01, v_high01, v_weights);
        let bh01 = xqdmlahq_laneq_s16::<2, R>(y_high01, u_high01, v_weights);
        let gh01 = vsubq_s16(y_high01, g_coeff_hi01);
        let rh11 = xqdmlahq_laneq_s16::<1, R>(y_high11, v_high01, v_weights);
        let bh11 = xqdmlahq_laneq_s16::<2, R>(y_high11, u_high01, v_weights);
        let gh11 = vsubq_s16(y_high11, g_coeff_hi01);

        let r_high01 = vqmovun_s16(rh01);
        let b_high01 = vqmovun_s16(bh01);
        let g_high01 = vqmovun_s16(gh01);

        let r_high11 = vqmovun_s16(rh11);
        let b_high11 = vqmovun_s16(bh11);
        let g_high11 = vqmovun_s16(gh11);

        let u_low01 = vshll_n_s8::<SCALE>(vget_low_s8(u_high_u8));
        let v_low01 = vshll_n_s8::<SCALE>(vget_low_s8(v_high_u8));

        let y_v_shl01 = vexpand8_to_10(vget_low_u8(y_values01));
        let y_v_shl11 = vexpand8_to_10(vget_low_u8(y_values11));

        let y_low01 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl01), v_weights);
        let y_low11 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl11), v_weights);

        let g_coeff_lo01 = xqdmlahq_laneq_s16::<4, R>(
            xqdmulhq_laneq_s16::<3, R>(v_low01, v_weights),
            u_low01,
            v_weights,
        );

        let rl01 = xqdmlahq_laneq_s16::<1, R>(y_low01, v_low01, v_weights);
        let bl01 = xqdmlahq_laneq_s16::<2, R>(y_low01, u_low01, v_weights);
        let gl01 = vsubq_s16(y_low01, g_coeff_lo01);
        let rl11 = xqdmlahq_laneq_s16::<1, R>(y_low11, v_low01, v_weights);
        let bl11 = xqdmlahq_laneq_s16::<2, R>(y_low11, u_low01, v_weights);
        let gl11 = vsubq_s16(y_low11, g_coeff_lo01);

        let r_low01 = vqmovun_s16(rl01);
        let b_low01 = vqmovun_s16(bl01);
        let g_low01 = vqmovun_s16(gl01);

        let r_low11 = vqmovun_s16(rl11);
        let b_low11 = vqmovun_s16(bl11);
        let g_low11 = vqmovun_s16(gl11);

        let r_values01 = vcombine_u8(r_low01, r_high01);
        let g_values01 = vcombine_u8(g_low01, g_high01);
        let b_values01 = vcombine_u8(b_low01, b_high01);

        let r_values11 = vcombine_u8(r_low11, r_high11);
        let g_values11 = vcombine_u8(g_low11, g_high11);
        let b_values11 = vcombine_u8(b_low11, b_high11);

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

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba0
                .get_unchecked_mut((dst_shift + channels * 16)..)
                .as_mut_ptr(),
            r_values01,
            g_values01,
            b_values01,
            v_alpha,
        );

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            rgba1
                .get_unchecked_mut((dst_shift + channels * 16)..)
                .as_mut_ptr(),
            r_values11,
            g_values11,
            b_values11,
            v_alpha,
        );

        cx += 32;
        ux += 32;
    }

    while cx + 16 <= width {
        let vl0 = vld1q_u8(y_plane0.get_unchecked(cx..).as_ptr());
        let vl1 = vld1q_u8(y_plane1.get_unchecked(cx..).as_ptr());
        let mut uv_values = vld2_u8(uv_ptr.add(ux));

        let y_values0 = vqsubq_u8(vl0, y_corr);
        let y_values1 = vqsubq_u8(vl1, y_corr);
        if order == YuvNVOrder::VU {
            uv_values = uint8x8x2_t(uv_values.1, uv_values.0);
        }

        uv_values.0 = vsub_u8(uv_values.0, vget_low_u8(uv_corr));
        uv_values.1 = vsub_u8(uv_values.1, vget_low_u8(uv_corr));

        let u_high_u8 = vreinterpret_s8_u8(vzip2_u8(uv_values.0, uv_values.0));
        let v_high_u8 = vreinterpret_s8_u8(vzip2_u8(uv_values.1, uv_values.1));
        let u_low_u8 = vreinterpret_s8_u8(vzip1_u8(uv_values.0, uv_values.0));
        let v_low_u8 = vreinterpret_s8_u8(vzip1_u8(uv_values.1, uv_values.1));

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

        let r_high0 = vqmovun_s16(xqdmlahq_laneq_s16::<1, R>(y_high0, v_high, v_weights));
        let b_high0 = vqmovun_s16(xqdmlahq_laneq_s16::<2, R>(y_high0, u_high, v_weights));
        let g_high0 = vqmovun_s16(vsubq_s16(y_high0, g_coeff_hi));

        let r_high1 = vqmovun_s16(xqdmlahq_laneq_s16::<1, R>(y_high1, v_high, v_weights));
        let b_high1 = vqmovun_s16(xqdmlahq_laneq_s16::<2, R>(y_high1, u_high, v_weights));
        let g_high1 = vqmovun_s16(vsubq_s16(y_high1, g_coeff_hi));

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

        let r_low0 = vqmovun_s16(xqdmlahq_laneq_s16::<1, R>(y_low0, v_low, v_weights));
        let b_low0 = vqmovun_s16(xqdmlahq_laneq_s16::<2, R>(y_low0, u_low, v_weights));
        let g_low0 = vqmovun_s16(vsubq_s16(y_low0, g_coeff_lo));

        let r_low1 = vqmovun_s16(xqdmlahq_laneq_s16::<1, R>(y_low1, v_low, v_weights));
        let b_low1 = vqmovun_s16(xqdmlahq_laneq_s16::<2, R>(y_low1, u_low, v_weights));
        let g_low1 = vqmovun_s16(vsubq_s16(y_low1, g_coeff_lo));

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
        ux += 16;
    }

    let shuffle_u = vld1_u8([0, 0, 2, 2, 4, 4, 6, 6].as_ptr());
    let shuffle_v = vld1_u8([1, 1, 3, 3, 5, 5, 7, 7].as_ptr());

    while cx + 8 < width {
        let dst_shift = cx * channels;

        let vl0 = vld1_u8(y_plane0.get_unchecked(cx..).as_ptr());
        let vl1 = vld1_u8(y_plane1.get_unchecked(cx..).as_ptr());
        let y_values0 = vqsub_u8(vl0, vget_low_u8(y_corr));
        let y_values1 = vqsub_u8(vl1, vget_low_u8(y_corr));

        let mut u_low_u8: int8x8_t;
        let mut v_low_u8: int8x8_t;

        let mut uv_values = vld1_u8(uv_plane.get_unchecked(ux..).as_ptr());

        uv_values = vsub_u8(uv_values, vget_low_u8(uv_corr));

        u_low_u8 = vreinterpret_s8_u8(vtbl1_u8(uv_values, shuffle_u));
        v_low_u8 = vreinterpret_s8_u8(vtbl1_u8(uv_values, shuffle_v));

        if order == YuvNVOrder::VU {
            std::mem::swap(&mut u_low_u8, &mut v_low_u8);
        }

        let u_low = vshll_n_s8::<SCALE>(u_low_u8);
        let v_low = vshll_n_s8::<SCALE>(v_low_u8);
        let y_v_shl0 = vexpand8_to_10(y_values0);
        let y_v_shl1 = vexpand8_to_10(y_values1);
        let y_low0 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl0), v_weights);
        let y_low1 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl1), v_weights);

        let g_coeff_lo = xqdmlahq_laneq_s16::<4, R>(
            xqdmulhq_laneq_s16::<3, R>(v_low, v_weights),
            u_low,
            v_weights,
        );

        let r_low0 = vqmovun_s16(xqdmlahq_laneq_s16::<1, R>(y_low0, v_low, v_weights));
        let b_low0 = vqmovun_s16(xqdmlahq_laneq_s16::<2, R>(y_low0, u_low, v_weights));
        let g_low0 = vqmovun_s16(vsubq_s16(y_low0, g_coeff_lo));

        let r_low1 = vqmovun_s16(xqdmlahq_laneq_s16::<1, R>(y_low1, v_low, v_weights));
        let b_low1 = vqmovun_s16(xqdmlahq_laneq_s16::<2, R>(y_low1, u_low, v_weights));
        let g_low1 = vqmovun_s16(vsubq_s16(y_low1, g_coeff_lo));

        let r_values0 = r_low0;
        let g_values0 = g_low0;
        let b_values0 = b_low0;

        let r_values1 = r_low1;
        let g_values1 = g_low1;
        let b_values1 = b_low1;

        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            rgba0.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
            vget_low_u8(v_alpha),
        );
        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            rgba1.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            r_values1,
            g_values1,
            b_values1,
            vget_low_u8(v_alpha),
        );

        cx += 8;
        ux += 8;
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 8);

        let mut dst_buffer0: [u8; 8 * 4] = [0; 8 * 4];
        let mut dst_buffer1: [u8; 8 * 4] = [0; 8 * 4];
        let mut y_buffer0: [u8; 8] = [0; 8];
        let mut y_buffer1: [u8; 8] = [0; 8];
        let mut uv_buffer: [u8; 8] = [0; 8];

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

        let vl0 = vld1_u8(y_buffer0.as_ptr().cast());
        let vl1 = vld1_u8(y_buffer1.as_ptr().cast());
        let y_values0 = vqsub_u8(vl0, vget_low_u8(y_corr));
        let y_values1 = vqsub_u8(vl1, vget_low_u8(y_corr));

        let mut u_low_u8: int8x8_t;
        let mut v_low_u8: int8x8_t;

        let mut uv_values = vld1_u8(uv_buffer.as_ptr().cast());

        uv_values = vsub_u8(uv_values, vget_low_u8(uv_corr));

        u_low_u8 = vreinterpret_s8_u8(vtbl1_u8(uv_values, shuffle_u));
        v_low_u8 = vreinterpret_s8_u8(vtbl1_u8(uv_values, shuffle_v));

        if order == YuvNVOrder::VU {
            std::mem::swap(&mut u_low_u8, &mut v_low_u8);
        }

        let u_low = vshll_n_s8::<SCALE>(u_low_u8);
        let v_low = vshll_n_s8::<SCALE>(v_low_u8);
        let y_v_shl0 = vexpand8_to_10(y_values0);
        let y_v_shl1 = vexpand8_to_10(y_values1);
        let y_low0 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl0), v_weights);
        let y_low1 = xqdmulhq_laneq_s16::<0, R>(vreinterpretq_s16_u16(y_v_shl1), v_weights);

        let g_coeff_lo = xqdmlahq_laneq_s16::<4, R>(
            xqdmulhq_laneq_s16::<3, R>(v_low, v_weights),
            u_low,
            v_weights,
        );

        let r_low0 = vqmovun_s16(xqdmlahq_laneq_s16::<1, R>(y_low0, v_low, v_weights));
        let b_low0 = vqmovun_s16(xqdmlahq_laneq_s16::<2, R>(y_low0, u_low, v_weights));
        let g_low0 = vqmovun_s16(vsubq_s16(y_low0, g_coeff_lo));

        let r_low1 = vqmovun_s16(xqdmlahq_laneq_s16::<1, R>(y_low1, v_low, v_weights));
        let b_low1 = vqmovun_s16(xqdmlahq_laneq_s16::<2, R>(y_low1, u_low, v_weights));
        let g_low1 = vqmovun_s16(vsubq_s16(y_low1, g_coeff_lo));

        let r_values0 = r_low0;
        let g_values0 = g_low0;
        let b_values0 = b_low0;

        let r_values1 = r_low1;
        let g_values1 = g_low1;
        let b_values1 = b_low1;

        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer0.as_mut_ptr().cast(),
            r_values0,
            g_values0,
            b_values0,
            vget_low_u8(v_alpha),
        );
        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer1.as_mut_ptr().cast(),
            r_values1,
            g_values1,
            b_values1,
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
        ux += hv;
    }

    ProcessedOffset { cx, ux }
}
