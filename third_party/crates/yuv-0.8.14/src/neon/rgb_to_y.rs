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

use crate::neon::utils::{neon_vld_h_rgb_for_yuv, neon_vld_rgb_for_yuv};
use crate::yuv_support::{CbCrForwardTransform, YuvChromaRange, YuvSourceChannels};
use std::arch::aarch64::*;

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
/// Special path for YUV 4:0:0 for aarch64 with RDM available
pub(crate) unsafe fn neon_rgb_to_y_rdm<const ORIGIN_CHANNELS: u8>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: *mut u8,
    rgba: &[u8],
    start_cx: usize,
    width: usize,
) -> usize {
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    let y_ptr = y_plane;
    let rgba_ptr = rgba.as_ptr();

    let weights_arr: [i16; 4] = [
        transform.yr as i16,
        transform.yg as i16,
        transform.yb as i16,
        0i16,
    ];
    let v_weights = vld1_s16(weights_arr.as_ptr());

    const V_SCALE: i32 = 4;
    const A_E: i32 = 2;
    let y_bias = vdupq_n_s16(range.bias_y as i16 * (1 << A_E));

    let mut cx = start_cx;

    while cx + 16 <= width {
        let (r_values_u8, g_values_u8, b_values_u8) =
            neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(rgba_ptr.add(cx * channels));

        let r_high = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(r_values_u8));
        let g_high = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(g_values_u8));
        let b_high = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(b_values_u8));

        let r_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(r_values_u8)));
        let g_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(g_values_u8)));
        let b_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(b_values_u8)));

        let mut y_high = vqrdmlahq_lane_s16::<0>(y_bias, r_high, v_weights);
        let mut y_low = vqrdmlahq_lane_s16::<0>(y_bias, r_low, v_weights);
        y_high = vqrdmlahq_lane_s16::<1>(y_high, g_high, v_weights);
        y_low = vqrdmlahq_lane_s16::<1>(y_low, g_low, v_weights);
        y_high = vqrdmlahq_lane_s16::<2>(y_high, b_high, v_weights);
        y_low = vqrdmlahq_lane_s16::<2>(y_low, b_low, v_weights);

        let y_high = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_high));
        let y_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_low));

        let y = vcombine_u8(y_low, y_high);
        vst1q_u8(y_ptr.add(cx), y);

        cx += 16;
    }

    while cx + 8 <= width {
        let (r_values_u8, g_values_u8, b_values_u8) =
            neon_vld_h_rgb_for_yuv::<ORIGIN_CHANNELS>(rgba_ptr.add(cx * channels));

        let r_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(r_values_u8));
        let g_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(g_values_u8));
        let b_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(b_values_u8));

        let mut y_low = vqrdmlahq_lane_s16::<0>(y_bias, r_low, v_weights);
        y_low = vqrdmlahq_lane_s16::<1>(y_low, g_low, v_weights);
        y_low = vqrdmlahq_lane_s16::<2>(y_low, b_low, v_weights);

        let y_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_low));

        vst1_u8(y_ptr.add(cx), y_low);

        cx += 8;
    }

    cx
}

pub(crate) unsafe fn neon_rgb_to_y_row<const ORIGIN_CHANNELS: u8, const PRECISION: i32>(
    transform: &CbCrForwardTransform<i32>,
    range: &YuvChromaRange,
    y_plane: *mut u8,
    rgba: &[u8],
    start_cx: usize,
    width: usize,
) -> usize {
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    let bias_y = range.bias_y as i32;

    let y_ptr = y_plane;
    let rgba_ptr = rgba.as_ptr();

    let y_bias = vdupq_n_s32(bias_y);
    let weights_arr: [i16; 4] = [
        transform.yr as i16,
        transform.yg as i16,
        transform.yb as i16,
        0i16,
    ];
    let v_weights = vld1_s16(weights_arr.as_ptr());

    let mut cx = start_cx;

    while cx + 16 < width {
        let (r_values_u8, g_values_u8, b_values_u8) =
            neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(rgba_ptr.add(cx * channels));

        let r_high = vreinterpretq_s16_u16(vmovl_high_u8(r_values_u8));
        let g_high = vreinterpretq_s16_u16(vmovl_high_u8(g_values_u8));
        let b_high = vreinterpretq_s16_u16(vmovl_high_u8(b_values_u8));

        let r_h_low = vget_low_s16(r_high);
        let g_h_low = vget_low_s16(g_high);
        let b_h_low = vget_low_s16(b_high);

        let r_low = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(r_values_u8)));
        let g_low = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(g_values_u8)));
        let b_low = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(b_values_u8)));

        let r_l_low = vget_low_s16(r_low);
        let g_l_low = vget_low_s16(g_low);
        let b_l_low = vget_low_s16(b_low);

        let mut y_h_high = vmlal_high_lane_s16::<0>(y_bias, r_high, v_weights);
        let mut y_h_low = vmlal_lane_s16::<0>(y_bias, r_h_low, v_weights);
        let mut y_l_high = vmlal_high_lane_s16::<0>(y_bias, r_low, v_weights);
        let mut y_l_low = vmlal_lane_s16::<0>(y_bias, r_l_low, v_weights);

        y_h_high = vmlal_high_lane_s16::<1>(y_h_high, g_high, v_weights);
        y_h_low = vmlal_lane_s16::<1>(y_h_low, g_h_low, v_weights);
        y_l_high = vmlal_high_lane_s16::<1>(y_l_high, g_low, v_weights);
        y_l_low = vmlal_lane_s16::<1>(y_l_low, g_l_low, v_weights);

        y_h_high = vmlal_high_lane_s16::<2>(y_h_high, b_high, v_weights);
        y_h_low = vmlal_lane_s16::<2>(y_h_low, b_h_low, v_weights);
        y_l_high = vmlal_high_lane_s16::<2>(y_l_high, b_low, v_weights);
        y_l_low = vmlal_lane_s16::<2>(y_l_low, b_l_low, v_weights);

        let y_high = vreinterpretq_u16_s16(vcombine_s16(
            vshrn_n_s32::<PRECISION>(y_h_low),
            vshrn_n_s32::<PRECISION>(y_h_high),
        ));

        let y_low = vreinterpretq_u16_s16(vcombine_s16(
            vshrn_n_s32::<PRECISION>(y_l_low),
            vshrn_n_s32::<PRECISION>(y_l_high),
        ));

        let y = vcombine_u8(vmovn_u16(y_low), vmovn_u16(y_high));
        vst1q_u8(y_ptr.add(cx), y);

        cx += 16;
    }

    while cx + 8 < width {
        let (r_values_u8, g_values_u8, b_values_u8) =
            neon_vld_h_rgb_for_yuv::<ORIGIN_CHANNELS>(rgba_ptr.add(cx * channels));

        let r_low = vreinterpretq_s16_u16(vmovl_u8(r_values_u8));
        let g_low = vreinterpretq_s16_u16(vmovl_u8(g_values_u8));
        let b_low = vreinterpretq_s16_u16(vmovl_u8(b_values_u8));

        let r_l_low = vget_low_s16(r_low);
        let g_l_low = vget_low_s16(g_low);
        let b_l_low = vget_low_s16(b_low);

        let mut y_l_high = vmlal_high_lane_s16::<0>(y_bias, r_low, v_weights);
        let mut y_l_low = vmlal_lane_s16::<0>(y_bias, r_l_low, v_weights);
        y_l_high = vmlal_high_lane_s16::<1>(y_l_high, g_low, v_weights);
        y_l_low = vmlal_lane_s16::<1>(y_l_low, g_l_low, v_weights);
        y_l_high = vmlal_high_lane_s16::<2>(y_l_high, b_low, v_weights);
        y_l_low = vmlal_lane_s16::<2>(y_l_low, b_l_low, v_weights);

        let y_low = vreinterpretq_u16_s16(vcombine_s16(
            vshrn_n_s32::<PRECISION>(y_l_low),
            vshrn_n_s32::<PRECISION>(y_l_high),
        ));

        vst1_u8(y_ptr.add(cx), vmovn_u16(y_low));

        cx += 8;
    }

    cx
}
