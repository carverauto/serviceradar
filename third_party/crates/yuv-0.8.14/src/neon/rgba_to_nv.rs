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
use crate::yuv_support::{
    CbCrForwardTransform, YuvChromaRange, YuvChromaSubsampling, YuvNVOrder, YuvSourceChannels,
};
use std::arch::aarch64::*;

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
pub(crate) unsafe fn neon_rgbx_to_nv_row_rdm<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
>(
    y_plane: &mut [u8],
    uv_plane: &mut [u8],
    rgba: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    let order: YuvNVOrder = UV_ORDER.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

    let bias_uv = range.bias_uv as i16;

    let y_ptr = y_plane.as_mut_ptr();
    let uv_ptr = uv_plane.as_mut_ptr();
    let rgba_ptr = rgba.as_ptr();

    const V_SCALE: i32 = 4;
    const V_HALF_SCALE: i32 = V_SCALE - 1;
    const A_E: i32 = 2;
    let y_bias = vdupq_n_s16(range.bias_y as i16 * (1 << A_E));
    let uv_bias = vdupq_n_s16(bias_uv * (1 << A_E) + (1 << (A_E - 1)) - 1);

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
        let (r_values0, g_values0, b_values0) =
            neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(rgba_ptr.add(cx * channels));

        let r_high = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(r_values0));
        let g_high = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(g_values0));
        let b_high = vreinterpretq_s16_u16(vshll_high_n_u8::<V_SCALE>(b_values0));

        let r_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(r_values0)));
        let g_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(g_values0)));
        let b_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(vget_low_u8(b_values0)));

        let mut y_high = vqrdmlahq_laneq_s16::<0>(y_bias, r_high, v_weights);
        let mut y_low = vqrdmlahq_laneq_s16::<0>(y_bias, r_low, v_weights);
        y_high = vqrdmlahq_laneq_s16::<1>(y_high, g_high, v_weights);
        y_low = vqrdmlahq_laneq_s16::<1>(y_low, g_low, v_weights);
        y_high = vqrdmlahq_laneq_s16::<2>(y_high, b_high, v_weights);
        y_low = vqrdmlahq_laneq_s16::<2>(y_low, b_low, v_weights);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut cb_high = vqrdmlahq_laneq_s16::<3>(uv_bias, r_high, v_weights);
            let mut cr_high = vqrdmlahq_laneq_s16::<6>(uv_bias, r_high, v_weights);
            cb_high = vqrdmlahq_laneq_s16::<4>(cb_high, g_high, v_weights);
            cr_high = vqrdmlahq_laneq_s16::<7>(cr_high, g_high, v_weights);
            cb_high = vqrdmlahq_laneq_s16::<5>(cb_high, b_high, v_weights);
            cr_high = vqrdmlahq_laneq_s16::<0>(cr_high, b_high, v_cr_b);

            let mut cb_low = vqrdmlahq_laneq_s16::<3>(uv_bias, r_low, v_weights);
            let mut cr_low = vqrdmlahq_laneq_s16::<6>(uv_bias, r_low, v_weights);
            cb_low = vqrdmlahq_laneq_s16::<4>(cb_low, g_low, v_weights);
            cr_low = vqrdmlahq_laneq_s16::<7>(cr_low, g_low, v_weights);
            cb_low = vqrdmlahq_laneq_s16::<5>(cb_low, b_low, v_weights);
            cr_low = vqrdmlahq_laneq_s16::<0>(cr_low, b_low, v_cr_b);

            let cb_high = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(cb_high));
            let cr_high = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(cr_high));

            let cb_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(cb_low));
            let cr_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(cr_low));

            let cb = vcombine_u8(cb_low, cb_high);
            let cr = vcombine_u8(cr_low, cr_high);

            match order {
                YuvNVOrder::UV => {
                    let store: uint8x16x2_t = uint8x16x2_t(cb, cr);
                    vst2q_u8(uv_ptr.add(ux), store);
                }
                YuvNVOrder::VU => {
                    let store: uint8x16x2_t = uint8x16x2_t(cr, cb);
                    vst2q_u8(uv_ptr.add(ux), store);
                }
            }

            ux += 32;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let r1 = vreinterpretq_s16_u16(vshlq_n_u16::<V_HALF_SCALE>(vpaddlq_u8(r_values0)));
            let g1 = vreinterpretq_s16_u16(vshlq_n_u16::<V_HALF_SCALE>(vpaddlq_u8(g_values0)));
            let b1 = vreinterpretq_s16_u16(vshlq_n_u16::<V_HALF_SCALE>(vpaddlq_u8(b_values0)));

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
                    vst2_u8(uv_ptr.add(ux), store);
                }
                YuvNVOrder::VU => {
                    let store: uint8x8x2_t = uint8x8x2_t(cr, cb);
                    vst2_u8(uv_ptr.add(ux), store);
                }
            }
            ux += 16;
        }

        let y_high = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_high));
        let y_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_low));

        let y = vcombine_u8(y_low, y_high);
        vst1q_u8(y_ptr.add(cx), y);

        cx += 16;
    }

    while cx + 8 <= width as usize {
        let src = rgba.get_unchecked(cx * channels..);
        let y_dst = y_plane.get_unchecked_mut(cx..);
        let uv_dst = uv_plane.get_unchecked_mut(ux..);

        let (r_values0, g_values0, b_values0) =
            neon_vld_h_rgb_for_yuv::<ORIGIN_CHANNELS>(src.as_ptr());

        let r_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(r_values0));
        let g_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(g_values0));
        let b_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(b_values0));

        let mut y_low = vqrdmlahq_laneq_s16::<0>(y_bias, r_low, v_weights);
        y_low = vqrdmlahq_laneq_s16::<1>(y_low, g_low, v_weights);
        y_low = vqrdmlahq_laneq_s16::<2>(y_low, b_low, v_weights);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut cb_low = vqrdmlahq_laneq_s16::<3>(uv_bias, r_low, v_weights);
            let mut cr_low = vqrdmlahq_laneq_s16::<6>(uv_bias, r_low, v_weights);
            cb_low = vqrdmlahq_laneq_s16::<4>(cb_low, g_low, v_weights);
            cr_low = vqrdmlahq_laneq_s16::<7>(cr_low, g_low, v_weights);
            cb_low = vqrdmlahq_laneq_s16::<5>(cb_low, b_low, v_weights);
            cr_low = vqrdmlahq_laneq_s16::<0>(cr_low, b_low, v_cr_b);

            let cb_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(cb_low));
            let cr_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(cr_low));

            let cb = cb_low;
            let cr = cr_low;

            match order {
                YuvNVOrder::UV => {
                    let store = uint8x8x2_t(cb, cr);
                    vst2_u8(uv_dst.as_mut_ptr(), store);
                }
                YuvNVOrder::VU => {
                    let store = uint8x8x2_t(cr, cb);
                    vst2_u8(uv_dst.as_mut_ptr(), store);
                }
            }
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let r1 = vreinterpret_s16_u16(vshl_n_u16::<V_HALF_SCALE>(vpaddl_u8(r_values0)));
            let g1 = vreinterpret_s16_u16(vshl_n_u16::<V_HALF_SCALE>(vpaddl_u8(g_values0)));
            let b1 = vreinterpret_s16_u16(vshl_n_u16::<V_HALF_SCALE>(vpaddl_u8(b_values0)));

            let mut cbl = vqrdmlah_laneq_s16::<3>(vget_low_s16(uv_bias), r1, v_weights);
            let mut crl = vqrdmlah_laneq_s16::<6>(vget_low_s16(uv_bias), r1, v_weights);
            cbl = vqrdmlah_laneq_s16::<4>(cbl, g1, v_weights);
            crl = vqrdmlah_laneq_s16::<7>(crl, g1, v_weights);
            cbl = vqrdmlah_laneq_s16::<5>(cbl, b1, v_weights);
            crl = vqrdmlah_laneq_s16::<0>(crl, b1, v_cr_b);

            let cb = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(vcombine_s16(cbl, cbl)));
            let cr = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(vcombine_s16(crl, crl)));

            match order {
                YuvNVOrder::UV => {
                    let store = vzip1_u8(cb, cr);
                    vst1_u8(uv_dst.as_mut_ptr(), store);
                }
                YuvNVOrder::VU => {
                    let store = vzip1_u8(cr, cb);
                    vst1_u8(uv_dst.as_mut_ptr(), store);
                }
            }
        }

        let y_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_low));
        vst1_u8(y_dst.as_mut_ptr(), y_low);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            ux += 16;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            ux += 8;
        }

        cx += 8;
    }

    if cx < width as usize {
        let diff = width as usize - cx;

        assert!(diff <= 8);

        let mut src_buffer: [u8; 8 * 4] = [0; 8 * 4];
        let mut y_buffer0: [u8; 8] = [0; 8];
        let mut uv_buffer: [u8; 8 * 2] = [0; 8 * 2];

        // Replicate last item to one more position for subsampling
        if chroma_subsampling != YuvChromaSubsampling::Yuv444 && diff % 2 != 0 {
            let lst = (width as usize - 1) * channels;
            let last_items = rgba.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst = src_buffer.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst.iter_mut().zip(last_items) {
                *dst = *src;
            }
        }

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

        let src = src_buffer;

        let (r_values0, g_values0, b_values0) =
            neon_vld_h_rgb_for_yuv::<ORIGIN_CHANNELS>(src.as_ptr().cast());

        let r_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(r_values0));
        let g_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(g_values0));
        let b_low = vreinterpretq_s16_u16(vshll_n_u8::<V_SCALE>(b_values0));

        let mut y_low = vqrdmlahq_laneq_s16::<0>(y_bias, r_low, v_weights);
        y_low = vqrdmlahq_laneq_s16::<1>(y_low, g_low, v_weights);
        y_low = vqrdmlahq_laneq_s16::<2>(y_low, b_low, v_weights);

        let y_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(y_low));
        vst1_u8(y_buffer0.as_mut_ptr().cast(), y_low);

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut cb_low = vqrdmlahq_laneq_s16::<3>(uv_bias, r_low, v_weights);
            let mut cr_low = vqrdmlahq_laneq_s16::<6>(uv_bias, r_low, v_weights);
            cb_low = vqrdmlahq_laneq_s16::<4>(cb_low, g_low, v_weights);
            cr_low = vqrdmlahq_laneq_s16::<7>(cr_low, g_low, v_weights);
            cb_low = vqrdmlahq_laneq_s16::<5>(cb_low, b_low, v_weights);
            cr_low = vqrdmlahq_laneq_s16::<0>(cr_low, b_low, v_cr_b);

            let cb_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(cb_low));
            let cr_low = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(cr_low));

            let cb = cb_low;
            let cr = cr_low;

            match order {
                YuvNVOrder::UV => {
                    let store = uint8x8x2_t(cb, cr);
                    vst2_u8(uv_buffer.as_mut_ptr().cast(), store);
                }
                YuvNVOrder::VU => {
                    let store = uint8x8x2_t(cr, cb);
                    vst2_u8(uv_buffer.as_mut_ptr().cast(), store);
                }
            }
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let r1 = vreinterpret_s16_u16(vshl_n_u16::<V_HALF_SCALE>(vpaddl_u8(r_values0)));
            let g1 = vreinterpret_s16_u16(vshl_n_u16::<V_HALF_SCALE>(vpaddl_u8(g_values0)));
            let b1 = vreinterpret_s16_u16(vshl_n_u16::<V_HALF_SCALE>(vpaddl_u8(b_values0)));

            let mut cbl = vqrdmlah_laneq_s16::<3>(vget_low_s16(uv_bias), r1, v_weights);
            let mut crl = vqrdmlah_laneq_s16::<6>(vget_low_s16(uv_bias), r1, v_weights);
            cbl = vqrdmlah_laneq_s16::<4>(cbl, g1, v_weights);
            crl = vqrdmlah_laneq_s16::<7>(crl, g1, v_weights);
            cbl = vqrdmlah_laneq_s16::<5>(cbl, b1, v_weights);
            crl = vqrdmlah_laneq_s16::<0>(crl, b1, v_cr_b);

            let cb = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(vcombine_s16(cbl, cbl)));
            let cr = vqshrn_n_u16::<A_E>(vreinterpretq_u16_s16(vcombine_s16(crl, crl)));

            match order {
                YuvNVOrder::UV => {
                    let store = vzip1_u8(cb, cr);
                    vst1_u8(uv_buffer.as_mut_ptr().cast(), store);
                }
                YuvNVOrder::VU => {
                    let store = vzip1_u8(cr, cb);
                    vst1_u8(uv_buffer.as_mut_ptr().cast(), store);
                }
            }
        }

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_mut_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        let ux_size = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2) * 2,
            YuvChromaSubsampling::Yuv444 => diff * 2,
        };

        std::ptr::copy_nonoverlapping(
            uv_buffer.as_mut_ptr().cast(),
            uv_plane.get_unchecked_mut(ux..).as_mut_ptr(),
            ux_size,
        );

        cx += diff;
        ux += ux_size;
    }

    ProcessedOffset { cx, ux }
}

pub(crate) unsafe fn neon_rgbx_to_nv_row<
    const ORIGIN_CHANNELS: u8,
    const UV_ORDER: u8,
    const SAMPLING: u8,
    const PRECISION: i32,
>(
    y_plane: &mut [u8],
    uv_plane: &mut [u8],
    rgba: &[u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrForwardTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    let order: YuvNVOrder = UV_ORDER.into();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let source_channels: YuvSourceChannels = ORIGIN_CHANNELS.into();
    let channels = source_channels.get_channels_count();

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

    let encode_16_part = |src: &[u8], y_dst: &mut [u8], uv_dst: &mut [u8]| {
        let (r_values0, g_values0, b_values0) =
            neon_vld_rgb_for_yuv::<ORIGIN_CHANNELS>(src.as_ptr());

        let r_high = vreinterpretq_s16_u16(vmovl_high_u8(r_values0));
        let g_high = vreinterpretq_s16_u16(vmovl_high_u8(g_values0));
        let b_high = vreinterpretq_s16_u16(vmovl_high_u8(b_values0));

        let y_high = vdotl_laneq_u16_x3::<PRECISION, 0, 1, 2>(
            vreinterpretq_u32_s32(y_bias),
            vreinterpretq_u16_s16(r_high),
            vreinterpretq_u16_s16(g_high),
            vreinterpretq_u16_s16(b_high),
            vreinterpretq_u16_s16(v_weights),
        );

        let r_low = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(r_values0)));
        let g_low = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(g_values0)));
        let b_low = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(b_values0)));

        let y_low = vdotl_laneq_u16_x3::<PRECISION, 0, 1, 2>(
            vreinterpretq_u32_s32(y_bias),
            vreinterpretq_u16_s16(r_low),
            vreinterpretq_u16_s16(g_low),
            vreinterpretq_u16_s16(b_low),
            vreinterpretq_u16_s16(v_weights),
        );

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut cb_h_high = vmlal_high_laneq_s16::<3>(uv_bias, r_high, v_weights);
            let mut cb_h_low = vmlal_laneq_s16::<3>(uv_bias, vget_low_s16(r_high), v_weights);
            let mut cr_h_high = vmlal_high_laneq_s16::<6>(uv_bias, r_high, v_weights);
            let mut cr_h_low = vmlal_laneq_s16::<6>(uv_bias, vget_low_s16(r_high), v_weights);
            let mut cb_l_high = vmlal_high_laneq_s16::<3>(uv_bias, r_low, v_weights);
            let mut cb_l_low = vmlal_laneq_s16::<3>(uv_bias, vget_low_s16(r_low), v_weights);
            let mut cr_l_high = vmlal_high_laneq_s16::<6>(uv_bias, r_low, v_weights);
            let mut cr_l_low = vmlal_laneq_s16::<6>(uv_bias, vget_low_s16(r_low), v_weights);

            cb_h_high = vmlal_high_laneq_s16::<4>(cb_h_high, g_high, v_weights);
            cb_h_low = vmlal_laneq_s16::<4>(cb_h_low, vget_low_s16(g_high), v_weights);
            cr_h_high = vmlal_high_laneq_s16::<7>(cr_h_high, g_high, v_weights);
            cr_h_low = vmlal_laneq_s16::<7>(cr_h_low, vget_low_s16(g_high), v_weights);
            cb_l_high = vmlal_high_laneq_s16::<4>(cb_l_high, g_low, v_weights);
            cb_l_low = vmlal_laneq_s16::<4>(cb_l_low, vget_low_s16(g_low), v_weights);
            cr_l_high = vmlal_high_laneq_s16::<7>(cr_l_high, g_low, v_weights);
            cr_l_low = vmlal_laneq_s16::<7>(cr_l_low, vget_low_s16(g_low), v_weights);

            cb_h_high = vmlal_high_laneq_s16::<5>(cb_h_high, b_high, v_weights);
            cb_h_low = vmlal_laneq_s16::<5>(cb_h_low, vget_low_s16(b_high), v_weights);
            cr_h_high = vmlal_high_laneq_s16::<0>(cr_h_high, b_high, v_cr_b);
            cr_h_low = vmlal_laneq_s16::<0>(cr_h_low, vget_low_s16(b_high), v_cr_b);
            cb_l_high = vmlal_high_laneq_s16::<5>(cb_l_high, b_low, v_weights);
            cb_l_low = vmlal_laneq_s16::<5>(cb_l_low, vget_low_s16(b_low), v_weights);
            cr_l_high = vmlal_high_laneq_s16::<0>(cr_l_high, b_low, v_cr_b);
            cr_l_low = vmlal_laneq_s16::<0>(cr_l_low, vget_low_s16(b_low), v_cr_b);

            let cb_high = vreinterpretq_u16_s16(vcombine_s16(
                vshrn_n_s32::<PRECISION>(cb_h_low),
                vshrn_n_s32::<PRECISION>(cb_h_high),
            ));

            let cr_high = vreinterpretq_u16_s16(vcombine_s16(
                vshrn_n_s32::<PRECISION>(cr_h_low),
                vshrn_n_s32::<PRECISION>(cr_h_high),
            ));
            let cb_low = vreinterpretq_u16_s16(vcombine_s16(
                vshrn_n_s32::<PRECISION>(cb_l_low),
                vshrn_n_s32::<PRECISION>(cb_l_high),
            ));

            let cr_low = vreinterpretq_u16_s16(vcombine_s16(
                vshrn_n_s32::<PRECISION>(cr_l_low),
                vshrn_n_s32::<PRECISION>(cr_l_high),
            ));
            let cb = vcombine_u8(vmovn_u16(cb_low), vmovn_u16(cb_high));
            let cr = vcombine_u8(vmovn_u16(cr_low), vmovn_u16(cr_high));

            match order {
                YuvNVOrder::UV => {
                    let store: uint8x16x2_t = uint8x16x2_t(cb, cr);
                    vst2q_u8(uv_dst.as_mut_ptr(), store);
                }
                YuvNVOrder::VU => {
                    let store: uint8x16x2_t = uint8x16x2_t(cr, cb);
                    vst2q_u8(uv_dst.as_mut_ptr(), store);
                }
            }
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            let r_avg = vpaddlq_u8(r_values0);
            let g_avg = vpaddlq_u8(g_values0);
            let b_avg = vpaddlq_u8(b_values0);

            let r1 = vreinterpretq_s16_u16(vrshrq_n_u16::<1>(r_avg));
            let g1 = vreinterpretq_s16_u16(vrshrq_n_u16::<1>(g_avg));
            let b1 = vreinterpretq_s16_u16(vrshrq_n_u16::<1>(b_avg));

            let mut cb_h = vmlal_high_laneq_s16::<3>(uv_bias, r1, v_weights);
            let mut cr_h = vmlal_high_laneq_s16::<6>(uv_bias, r1, v_weights);
            let mut cb_l = vmlal_laneq_s16::<3>(uv_bias, vget_low_s16(r1), v_weights);
            let mut cr_l = vmlal_laneq_s16::<6>(uv_bias, vget_low_s16(r1), v_weights);

            cb_h = vmlal_high_laneq_s16::<4>(cb_h, g1, v_weights);
            cb_l = vmlal_laneq_s16::<4>(cb_l, vget_low_s16(g1), v_weights);
            cr_h = vmlal_high_laneq_s16::<7>(cr_h, g1, v_weights);
            cr_l = vmlal_laneq_s16::<7>(cr_l, vget_low_s16(g1), v_weights);

            cb_h = vmlal_high_laneq_s16::<5>(cb_h, b1, v_weights);
            cb_l = vmlal_laneq_s16::<5>(cb_l, vget_low_s16(b1), v_weights);
            cr_h = vmlal_high_laneq_s16::<0>(cr_h, b1, v_cr_b);
            cr_l = vmlal_laneq_s16::<0>(cr_l, vget_low_s16(b1), v_cr_b);

            let cb = vmovn_u16(vreinterpretq_u16_s16(vcombine_s16(
                vshrn_n_s32::<PRECISION>(cb_l),
                vshrn_n_s32::<PRECISION>(cb_h),
            )));

            let cr = vmovn_u16(vreinterpretq_u16_s16(vcombine_s16(
                vshrn_n_s32::<PRECISION>(cr_l),
                vshrn_n_s32::<PRECISION>(cr_h),
            )));

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

        let y = vcombine_u8(vmovn_u16(y_low), vmovn_u16(y_high));
        vst1q_u8(y_dst.as_mut_ptr(), y);
    };

    while cx + 16 <= width as usize {
        encode_16_part(
            rgba.get_unchecked(cx * channels..),
            y_plane.get_unchecked_mut(cx..),
            uv_plane.get_unchecked_mut(ux..),
        );

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            ux += 32;
        } else if (chroma_subsampling == YuvChromaSubsampling::Yuv420)
            || (chroma_subsampling == YuvChromaSubsampling::Yuv422)
        {
            ux += 16;
        }

        cx += 16;
    }

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 16);

        let mut src_buffer: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer0: [u8; 16] = [0; 16];
        let mut uv_buffer: [u8; 16 * 2] = [0; 16 * 2];

        // Replicate last item to one more position for subsampling
        if chroma_subsampling != YuvChromaSubsampling::Yuv444 && diff % 2 != 0 {
            let lst = (width as usize - 1) * channels;
            let last_items = rgba.get_unchecked(lst..(lst + channels));
            let dvb = diff * channels;
            let dst = src_buffer.get_unchecked_mut(dvb..(dvb + channels));
            for (dst, src) in dst.iter_mut().zip(last_items) {
                *dst = *src;
            }
        }

        std::ptr::copy_nonoverlapping(
            rgba.get_unchecked(cx * channels..).as_ptr(),
            src_buffer.as_mut_ptr().cast(),
            diff * channels,
        );

        encode_16_part(
            src_buffer.as_slice(),
            y_buffer0.as_mut_slice(),
            uv_buffer.as_mut_slice(),
        );

        std::ptr::copy_nonoverlapping(
            y_buffer0.as_mut_ptr().cast(),
            y_plane.get_unchecked_mut(cx..).as_mut_ptr(),
            diff,
        );

        let ux_size = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2) * 2,
            YuvChromaSubsampling::Yuv444 => diff * 2,
        };

        std::ptr::copy_nonoverlapping(
            uv_buffer.as_mut_ptr().cast(),
            uv_plane.get_unchecked_mut(ux..).as_mut_ptr(),
            ux_size,
        );

        cx += diff;
        ux += ux_size;
    }

    ProcessedOffset { cx, ux }
}
