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
use crate::neon::utils::neon_vld_rgb_for_yuv;
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvNVOrder, YuvSourceChannels};
use std::arch::aarch64::*;

#[inline]
#[target_feature(enable = "rdm")]
#[cfg(feature = "rdm")]
unsafe fn encode_16_part_rdm<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
    src0: &[u8],
    src1: &[u8],
    y_dst0: &mut [u8],
    y_dst1: &mut [u8],
    uv_dst: &mut [u8],
    y_bias: int16x8_t,
    uv_bias: int16x8_t,
    v_weights: int16x8_t,
    v_cr_b: int16x8_t,
) {
    let order: YuvNVOrder = UV_ORDER.into();
    const V_SCALE: i32 = 4;
    const V_HALF_SCALE: i32 = V_SCALE - 2;
    const A_E: i32 = 2;

    let (r_values0, g_values0, b_values0) = neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src0.as_ptr());
    let (r_values1, g_values1, b_values1) = neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src1.as_ptr());

    let r_high0 = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(r_values0));
    let g_high0 = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(g_values0));
    let b_high0 = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(b_values0));

    let r_high1 = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(r_values1));
    let g_high1 = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(g_values1));
    let b_high1 = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(b_values1));

    let mut y_high0 = vqrdmlahq_laneq_s16::<0>(y_bias, r_high0, v_weights);
    let mut y_high1 = vqrdmlahq_laneq_s16::<0>(y_bias, r_high1, v_weights);
    y_high0 = vqrdmlahq_laneq_s16::<1>(y_high0, g_high0, v_weights);
    y_high1 = vqrdmlahq_laneq_s16::<1>(y_high1, g_high1, v_weights);
    y_high0 = vqrdmlahq_laneq_s16::<2>(y_high0, b_high0, v_weights);
    y_high1 = vqrdmlahq_laneq_s16::<2>(y_high1, b_high1, v_weights);

    let y0_high = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_high0));
    let y1_high = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_high1));

    let r_low0 = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(r_values0)));
    let g_low0 = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(g_values0)));
    let b_low0 = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(b_values0)));

    let r_low1 = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(r_values1)));
    let g_low1 = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(g_values1)));
    let b_low1 = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(b_values1)));

    let mut y_low0 = vqrdmlahq_laneq_s16::<0>(y_bias, r_low0, v_weights);
    let mut y_low1 = vqrdmlahq_laneq_s16::<0>(y_bias, r_low1, v_weights);
    y_low0 = vqrdmlahq_laneq_s16::<1>(y_low0, g_low0, v_weights);
    y_low1 = vqrdmlahq_laneq_s16::<1>(y_low1, g_low1, v_weights);
    y_low0 = vqrdmlahq_laneq_s16::<2>(y_low0, b_low0, v_weights);
    y_low1 = vqrdmlahq_laneq_s16::<2>(y_low1, b_low1, v_weights);

    let y0_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_low0));
    let y1_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_low1));

    let y0 = vcombine_u8(y0_low, y0_high);
    vst1q_u8(y_dst0.as_mut_ptr(), y0);
    let y1 = vcombine_u8(y1_low, y1_high);
    vst1q_u8(y_dst1.as_mut_ptr(), y1);

    let r1l = vpaddlq_u8(r_values0);
    let r1h = vpaddlq_u8(r_values1);
    let g1l = vpaddlq_u8(g_values0);
    let g1h = vpaddlq_u8(g_values1);
    let b1l = vpaddlq_u8(b_values0);
    let b1h = vpaddlq_u8(b_values1);
    let r1hv = vaddq_u16(r1l, r1h);
    let g1hv = vaddq_u16(g1l, g1h);
    let b1hv = vaddq_u16(b1l, b1h);

    let r1 = vreinterpretq_s16_u16(vshlq_n_u16::<V_HALF_SCALE>(r1hv));
    let g1 = vreinterpretq_s16_u16(vshlq_n_u16::<V_HALF_SCALE>(g1hv));
    let b1 = vreinterpretq_s16_u16(vshlq_n_u16::<V_HALF_SCALE>(b1hv));

    let mut cbl = vqrdmlahq_laneq_s16::<3>(uv_bias, r1, v_weights);
    let mut crl = vqrdmlahq_laneq_s16::<6>(uv_bias, r1, v_weights);
    cbl = vqrdmlahq_laneq_s16::<4>(cbl, g1, v_weights);
    crl = vqrdmlahq_laneq_s16::<7>(crl, g1, v_weights);
    cbl = vqrdmlahq_laneq_s16::<5>(cbl, b1, v_weights);
    crl = vqrdmlahq_laneq_s16::<0>(crl, b1, v_cr_b);

    let cb = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(cbl));
    let cr = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(crl));

    match order {
        YuvNVOrder::UV => {
            let store: uint8x8x2_t = uint8x8x2_t(cb, cr);
            vst2_u8(uv_dst.as_mut_ptr(), store);
        }
        YuvNVOrder::VU => {
            let store: uint8x8x2_t = uint8x8x2_t(cr, cb);
            vst2_u8(uv_dst.as_mut_ptr(), store);
        }
    }
}

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
/// Special path for BiPlanar YUV 4:2:0 for aarch64 with RDM available
pub(crate) unsafe fn neon_rgbx_to_nv_row_rdm420<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    uv_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    const A_E: i32 = 2;
    let y_bias = vdupq_n_s16(range.bias_y as i16 * (1 << A_E));
    let uv_bias = vdupq_n_s16(range.bias_uv as i16 * (1 << A_E) + (1 << (A_E - 1)) - 1);

    let weights_arr: [i16; 8] = [
        transform.yr as i16,
        transform.yg as i16,
        transform.yb as i16,
        transform.cb_r as i16,
        transform.cb_g as i16,
        transform.cb_b as i16,
        transform.cr_r as i16,
        transform.cr_g as i16,
    ];
    let v_weights = vld1q_s16(weights_arr.as_ptr());
    let v_cr_b = vdupq_n_s16(transform.cr_b as i16);

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 16 <= width as usize {
        encode_16_part_rdm::<ORIGIN_CHANNELS, UV_ORDER>(
            rgba0.get_unchecked(cx * channels..),
            rgba1.get_unchecked(cx * channels..),
            y_plane0.get_unchecked_mut(cx..),
            y_plane1.get_unchecked_mut(cx..),
            uv_plane.get_unchecked_mut(ux..),
            y_bias,
            uv_bias,
            v_weights,
            v_cr_b,
        );

        ux += 16;
        cx += 16;
    }

    if cx < width as usize {
        let diff = width as usize - cx;

        assert!(diff <= 16);

        let mut src_buffer0: [u8; 16 * 4] = [0; 16 * 4];
        let mut src_buffer1: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer0: [u8; 16] = [0; 16];
        let mut y_buffer1: [u8; 16] = [0; 16];
        let mut uv_buffer: [u8; 16 * 2] = [0; 16 * 2];

        // Replicate last item to one more position for subsampling
        if diff % 2 != 0 {
            let lst = (width as usize - 1) * channels;
            let last_items0 = rgba0.get_unchecked(lst..(lst + channels));
            let last_items1 = rgba1.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst0 = src_buffer0.get_unchecked_mut(dvb..(dvb + channels));
            let dst1 = src_buffer1.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst0.iter_mut().zip(last_items0) {
                *dst = *src;
            }
            for (dst, src) in dst1.iter_mut().zip(last_items1) {
                *dst = *src;
            }
        }

        std::ptr::copy_nonoverlapping(
            rgba0.get_unchecked(cx * channels..).as_ptr(),
            src_buffer0.as_mut_ptr().cast(),
            diff * channels,
        );

        std::ptr::copy_nonoverlapping(
            rgba1.get_unchecked(cx * channels..).as_ptr(),
            src_buffer1.as_mut_ptr().cast(),
            diff * channels,
        );

        encode_16_part_rdm::<ORIGIN_CHANNELS, UV_ORDER>(
            src_buffer0.as_slice(),
            src_buffer1.as_slice(),
            y_buffer0.as_mut_slice(),
            y_buffer1.as_mut_slice(),
            uv_buffer.as_mut_slice(),
            y_bias,
            uv_bias,
            v_weights,
            v_cr_b,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_mut_ptr().cast(),
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer1.as_mut_ptr().cast(),
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            uv_buffer.as_mut_ptr().cast(),
            uv_plane.get_unchecked_mut(ux..).as_mut_ptr(),
            diff.div_ceil(2) * 2,
        );

        cx += diff;
        ux += diff.div_ceil(2) * 2;
    }

    ProcessedOffset { cx, ux }
}

pub(crate) unsafe fn neon_rgbx_to_nv_row420<const ORIGIN_CHANNELS: u8, const UV_ORDER: u8>(
    y_plane0: &mut [u8],
    y_plane1: &mut [u8],
    uv_plane: &mut [u8],
    rgba0: &[u8],
    rgba1: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    let order: YuvNVOrder = UV_ORDER.into();
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    const PRECISION: i32 = 13;

    let rounding_const_bias: i32 = (1 << (PRECISION - 1)) - 1;
    let bias_y = range.bias_y as i32 * (1 << PRECISION) + rounding_const_bias;
    let bias_uv = range.bias_uv as i32 * (1 << PRECISION) + rounding_const_bias;

    let y_bias = vdupq_n_s32(bias_y);
    let uv_bias = vdupq_n_s32(bias_uv);

    let weights_arr: [i16; 8] = [
        transform.yr as i16,
        transform.yg as i16,
        transform.yb as i16,
        transform.cb_r as i16,
        transform.cb_g as i16,
        transform.cb_b as i16,
        transform.cr_r as i16,
        transform.cr_g as i16,
    ];
    let v_weights = vld1q_s16(weights_arr.as_ptr());
    let v_cr_b = vdupq_n_s16(transform.cr_b as i16);

    let mut cx = start_cx;
    let mut ux = start_ux;

    let encode_16_part =
        |src0: &[u8], src1: &[u8], y_dst0: &mut [u8], y_dst1: &mut [u8], uv_dst: &mut [u8]| {
            let (r_values_0, g_values_0, b_values_0) =
                neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src0.as_ptr());
            let (r_values_1, g_values_1, b_values_1) =
                neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src1.as_ptr());

            let r_high0 = vreinterpretq_s16_u16(vmovl_high_u8(r_values_0));
            let g_high0 = vreinterpretq_s16_u16(vmovl_high_u8(g_values_0));
            let b_high0 = vreinterpretq_s16_u16(vmovl_high_u8(b_values_0));

            let r_high1 = vreinterpretq_s16_u16(vmovl_high_u8(r_values_1));
            let g_high1 = vreinterpretq_s16_u16(vmovl_high_u8(g_values_1));
            let b_high1 = vreinterpretq_s16_u16(vmovl_high_u8(b_values_1));

            let mut y0_h_high = vmlal_high_laneq_s16::<0>(y_bias, r_high0, v_weights);
            let mut y0_h_low = vmlal_laneq_s16::<0>(y_bias, vget_low_s16(r_high0), v_weights);
            y0_h_high = vmlal_high_laneq_s16::<1>(y0_h_high, g_high0, v_weights);
            y0_h_low = vmlal_laneq_s16::<1>(y0_h_low, vget_low_s16(g_high0), v_weights);
            y0_h_high = vmlal_high_laneq_s16::<2>(y0_h_high, b_high0, v_weights);
            y0_h_low = vmlal_laneq_s16::<2>(y0_h_low, vget_low_s16(b_high0), v_weights);

            let mut y_h_high = vmlal_high_laneq_s16::<0>(y_bias, r_high1, v_weights);
            let mut y_h_low = vmlal_laneq_s16::<0>(y_bias, vget_low_s16(r_high1), v_weights);
            y_h_high = vmlal_high_laneq_s16::<1>(y_h_high, g_high1, v_weights);
            y_h_low = vmlal_laneq_s16::<1>(y_h_low, vget_low_s16(g_high1), v_weights);
            y_h_high = vmlal_high_laneq_s16::<2>(y_h_high, b_high1, v_weights);
            y_h_low = vmlal_laneq_s16::<2>(y_h_low, vget_low_s16(b_high1), v_weights);

            let y_high0 = vreinterpretq_u16_s16(vcombine_s16(
                vshrn_n_s32::<PRECISION>(y0_h_low),
                vshrn_n_s32::<PRECISION>(y0_h_high),
            ));

            let y_high1 = vreinterpretq_u16_s16(vcombine_s16(
                vshrn_n_s32::<PRECISION>(y_h_low),
                vshrn_n_s32::<PRECISION>(y_h_high),
            ));

            let r_low0 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(r_values_0)));
            let g_low0 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(g_values_0)));
            let b_low0 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(b_values_0)));

            let r_low1 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(r_values_1)));
            let g_low1 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(g_values_1)));
            let b_low1 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(b_values_1)));

            let mut y0_l_high = vmlal_high_laneq_s16::<0>(y_bias, r_low0, v_weights);
            let mut y0_l_low = vmlal_laneq_s16::<0>(y_bias, vget_low_s16(r_low0), v_weights);
            y0_l_high = vmlal_high_laneq_s16::<1>(y0_l_high, g_low0, v_weights);
            y0_l_low = vmlal_laneq_s16::<1>(y0_l_low, vget_low_s16(g_low0), v_weights);
            y0_l_high = vmlal_high_laneq_s16::<2>(y0_l_high, b_low0, v_weights);
            y0_l_low = vmlal_laneq_s16::<2>(y0_l_low, vget_low_s16(b_low0), v_weights);

            let mut y_l_high = vmlal_high_laneq_s16::<0>(y_bias, r_low1, v_weights);
            let mut y_l_low = vmlal_laneq_s16::<0>(y_bias, vget_low_s16(r_low1), v_weights);
            y_l_high = vmlal_high_laneq_s16::<1>(y_l_high, g_low1, v_weights);
            y_l_low = vmlal_laneq_s16::<1>(y_l_low, vget_low_s16(g_low1), v_weights);
            y_l_high = vmlal_high_laneq_s16::<2>(y_l_high, b_low1, v_weights);
            y_l_low = vmlal_laneq_s16::<2>(y_l_low, vget_low_s16(b_low1), v_weights);

            let y_low0 = vreinterpretq_u16_s16(vcombine_s16(
                vshrn_n_s32::<PRECISION>(y0_l_low),
                vshrn_n_s32::<PRECISION>(y0_l_high),
            ));

            let y_low1 = vreinterpretq_u16_s16(vcombine_s16(
                vshrn_n_s32::<PRECISION>(y_l_low),
                vshrn_n_s32::<PRECISION>(y_l_high),
            ));

            let y0 = vcombine_u8(vmovn_u16(y_low0), vmovn_u16(y_high0));
            let y1 = vcombine_u8(vmovn_u16(y_low1), vmovn_u16(y_high1));
            vst1q_u8(y_dst0.as_mut_ptr(), y0);
            vst1q_u8(y_dst1.as_mut_ptr(), y1);

            let r1l = vpaddlq_u8(r_values_0);
            let r1h = vpaddlq_u8(r_values_1);
            let g1l = vpaddlq_u8(g_values_0);
            let g1h = vpaddlq_u8(g_values_1);
            let b1l = vpaddlq_u8(b_values_0);
            let b1h = vpaddlq_u8(b_values_1);

            let r1hv = vrhaddq_u16(r1l, r1h);
            let g1hv = vrhaddq_u16(g1l, g1h);
            let b1hv = vrhaddq_u16(b1l, b1h);

            let r1 = vreinterpretq_s16_u16(vrshrq_n_u16::<1>(r1hv));
            let g1 = vreinterpretq_s16_u16(vrshrq_n_u16::<1>(g1hv));
            let b1 = vreinterpretq_s16_u16(vrshrq_n_u16::<1>(b1hv));

            let mut cb_h = vmlal_high_laneq_s16::<3>(uv_bias, r1, v_weights);
            let mut cb_l = vmlal_laneq_s16::<3>(uv_bias, vget_low_s16(r1), v_weights);
            let mut cr_h = vmlal_high_laneq_s16::<6>(uv_bias, r1, v_weights);
            let mut cr_l = vmlal_laneq_s16::<6>(uv_bias, vget_low_s16(r1), v_weights);

            cb_h = vmlal_high_laneq_s16::<4>(cb_h, g1, v_weights);
            cb_l = vmlal_laneq_s16::<4>(cb_l, vget_low_s16(g1), v_weights);
            cr_h = vmlal_high_laneq_s16::<7>(cr_h, g1, v_weights);
            cr_l = vmlal_laneq_s16::<7>(cr_l, vget_low_s16(g1), v_weights);

            cb_h = vmlal_high_laneq_s16::<5>(cb_h, b1, v_weights);
            cb_l = vmlal_laneq_s16::<5>(cb_l, vget_low_s16(b1), v_weights);
            cr_h = vmlal_high_laneq_s16::<0>(cr_h, b1, v_cr_b);
            cr_l = vmlal_laneq_s16::<0>(cr_l, vget_low_s16(b1), v_cr_b);

            let cb_l0 = vshrn_n_s32::<PRECISION>(cb_l);
            let cb_l1 = vshrn_n_s32::<PRECISION>(cb_h);
            let cr_l0 = vshrn_n_s32::<PRECISION>(cr_l);
            let cr_l1 = vshrn_n_s32::<PRECISION>(cr_h);

            let cb = vmovn_u16(vreinterpretq_u16_s16(vcombine_s16(cb_l0, cb_l1)));
            let cr = vmovn_u16(vreinterpretq_u16_s16(vcombine_s16(cr_l0, cr_l1)));

            match order {
                YuvNVOrder::UV => {
                    let store: uint8x8x2_t = uint8x8x2_t(cb, cr);
                    vst2_u8(uv_dst.as_mut_ptr(), store);
                }
                YuvNVOrder::VU => {
                    let store: uint8x8x2_t = uint8x8x2_t(cr, cb);
                    vst2_u8(uv_dst.as_mut_ptr(), store);
                }
            }
        };

    while cx + 16 <= width as usize {
        encode_16_part(
            rgba0.get_unchecked(cx * channels..),
            rgba1.get_unchecked(cx * channels..),
            y_plane0.get_unchecked_mut(cx..),
            y_plane1.get_unchecked_mut(cx..),
            uv_plane.get_unchecked_mut(ux..),
        );

        ux += 16;
        cx += 16;
    }

    if cx < width as usize {
        let diff = width as usize - cx;

        assert!(diff <= 16);

        let mut src_buffer0: [u8; 16 * 4] = [0; 16 * 4];
        let mut src_buffer1: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer0: [u8; 16] = [0; 16];
        let mut y_buffer1: [u8; 16] = [0; 16];
        let mut uv_buffer: [u8; 16 * 2] = [0; 16 * 2];

        // Replicate last item to one more position for subsampling
        if diff % 2 != 0 {
            let lst = (width as usize - 1) * channels;
            let last_items0 = rgba0.get_unchecked(lst..(lst + channels));
            let last_items1 = rgba1.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst0 = src_buffer0.get_unchecked_mut(dvb..(dvb + channels));
            let dst1 = src_buffer1.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst0.iter_mut().zip(last_items0) {
                *dst = *src;
            }
            for (dst, src) in dst1.iter_mut().zip(last_items1) {
                *dst = *src;
            }
        }

        std::ptr::copy_nonoverlapping(
            rgba0.get_unchecked(cx * channels..).as_ptr(),
            src_buffer0.as_mut_ptr().cast(),
            diff * channels,
        );

        std::ptr::copy_nonoverlapping(
            rgba1.get_unchecked(cx * channels..).as_ptr(),
            src_buffer1.as_mut_ptr().cast(),
            diff * channels,
        );

        encode_16_part(
            src_buffer0.as_slice(),
            src_buffer1.as_slice(),
            y_buffer0.as_mut_slice(),
            y_buffer1.as_mut_slice(),
            uv_buffer.as_mut_slice(),
        );

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_mut_ptr().cast(),
            y_plane0.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            y_buffer1.as_mut_ptr().cast(),
            y_plane1.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        std::ptr::copy_nonoverlapping(
            uv_buffer.as_mut_ptr().cast(),
            uv_plane.get_unchecked_mut(ux..).as_mut_ptr(),
            diff.div_ceil(2) * 2,
        );

        cx += diff;
        ux += diff;
    }

    ProcessedOffset { cx, ux }
}
