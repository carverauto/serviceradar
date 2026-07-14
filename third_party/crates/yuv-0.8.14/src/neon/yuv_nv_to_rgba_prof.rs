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
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvNVOrder, YuvSourceChannels,
};
use std::arch::aarch64::*;

pub(crate) unsafe fn neon_yuv_nv_to_rgba_row_prof<
    const UV_ORDER: u8,
    const DESTINATION_CHANNELS: u8,
    const YUV_CHROMA_SAMPLING: u8,
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
    let chroma_subsampling: YuvChromaSubsampling = YUV_CHROMA_SAMPLING.into();
    let channels = destination_channels.get_channels_count();

    let y_ptr = y_plane.as_ptr();
    let uv_ptr = uv_plane.as_ptr();
    let bgra_ptr = rgba.as_mut_ptr();

    let y_corr = vdupq_n_u8(range.bias_y as u8);
    let uv_corr = vdupq_n_u8(range.bias_uv as u8);

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
        let y_vl = vld1q_u8(y_ptr.add(cx));

        let u_high_s8: int8x8_t;
        let v_high_s8: int8x8_t;
        let u_low_s8: int8x8_t;
        let v_low_s8: int8x8_t;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut uv_values = vld2_u8(uv_ptr.add(ux));
                if order == YuvNVOrder::VU {
                    uv_values = uint8x8x2_t(uv_values.1, uv_values.0);
                }

                uv_values.0 = vsub_u8(uv_values.0, vget_low_u8(uv_corr));
                uv_values.1 = vsub_u8(uv_values.1, vget_low_u8(uv_corr));

                u_high_s8 = vreinterpret_s8_u8(vzip2_u8(uv_values.0, uv_values.0));
                v_high_s8 = vreinterpret_s8_u8(vzip2_u8(uv_values.1, uv_values.1));
                u_low_s8 = vreinterpret_s8_u8(vzip1_u8(uv_values.0, uv_values.0));
                v_low_s8 = vreinterpret_s8_u8(vzip1_u8(uv_values.1, uv_values.1));
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut uv_values = vld2q_u8(uv_ptr.add(ux));
                if order == YuvNVOrder::VU {
                    uv_values = uint8x16x2_t(uv_values.1, uv_values.0);
                }

                uv_values.0 = vsubq_u8(uv_values.0, uv_corr);
                uv_values.1 = vsubq_u8(uv_values.1, uv_corr);

                u_high_s8 = vreinterpret_s8_u8(vget_high_u8(uv_values.0));
                v_high_s8 = vreinterpret_s8_u8(vget_high_u8(uv_values.1));
                u_low_s8 = vreinterpret_s8_u8(vget_low_u8(uv_values.0));
                v_low_s8 = vreinterpret_s8_u8(vget_low_u8(uv_values.1));
            }
        }

        let y_values = vqsubq_u8(y_vl, y_corr);

        let u_high = vmovl_s8(u_high_s8);
        let v_high = vmovl_s8(v_high_s8);
        let u_low = vmovl_s8(u_low_s8);
        let v_low = vmovl_s8(v_low_s8);
        let y_high = vqdmalq_laneq_s16::<0>(
            b_y,
            vreinterpretq_s16_u16(vmovl_high_u8(y_values)),
            v_weights,
        );
        let y_low = vqdmalq_laneq_s16::<0>(
            b_y,
            vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values))),
            v_weights,
        );

        let mut g_hi1 = vqdmlal_high_laneq_s16::<4>(y_high.1, v_high, v_weights);
        let mut g_hi0 = vqdmlal_laneq_s16::<4>(y_high.0, vget_low_s16(v_high), v_weights);
        let mut g_lo1 = vqdmlal_high_laneq_s16::<4>(y_low.1, v_low, v_weights);
        let mut g_lo0 = vqdmlal_laneq_s16::<4>(y_low.0, vget_low_s16(v_low), v_weights);
        let r_hi1 = vqdmlal_high_laneq_s16::<1>(y_high.1, v_high, v_weights);
        let r_hi0 = vqdmlal_laneq_s16::<1>(y_high.0, vget_low_s16(v_high), v_weights);
        let r_lo1 = vqdmlal_high_laneq_s16::<1>(y_low.1, v_low, v_weights);
        let r_lo0 = vqdmlal_laneq_s16::<1>(y_low.0, vget_low_s16(v_low), v_weights);
        let mut b_hi1 = vqdmlal_high_laneq_s16::<2>(y_high.1, u_high, v_weights);
        let mut b_hi0 = vqdmlal_laneq_s16::<2>(y_high.0, vget_low_s16(u_high), v_weights);
        let mut b_lo1 = vqdmlal_high_laneq_s16::<2>(y_low.1, u_low, v_weights);
        let mut b_lo0 = vqdmlal_laneq_s16::<2>(y_low.0, vget_low_s16(u_low), v_weights);
        g_hi1 = vqdmlal_high_laneq_s16::<5>(g_hi1, u_high, v_weights);
        g_hi0 = vqdmlal_laneq_s16::<5>(g_hi0, vget_low_s16(u_high), v_weights);
        g_lo1 = vqdmlal_high_laneq_s16::<5>(g_lo1, u_low, v_weights);
        g_lo0 = vqdmlal_laneq_s16::<5>(g_lo0, vget_low_s16(u_low), v_weights);

        let r_high = vcombine_s16(
            vshrn_n_s32::<PRECISION>(r_hi0),
            vshrn_n_s32::<PRECISION>(r_hi1),
        );
        let r_low = vcombine_s16(
            vshrn_n_s32::<PRECISION>(r_lo0),
            vshrn_n_s32::<PRECISION>(r_lo1),
        );
        let g_high = vcombine_s16(
            vshrn_n_s32::<PRECISION>(g_hi0),
            vshrn_n_s32::<PRECISION>(g_hi1),
        );
        let g_low = vcombine_s16(
            vshrn_n_s32::<PRECISION>(g_lo0),
            vshrn_n_s32::<PRECISION>(g_lo1),
        );

        b_hi1 = vqdmlal_high_laneq_s16::<3>(b_hi1, u_high, v_weights);
        b_hi0 = vqdmlal_laneq_s16::<3>(b_hi0, vget_low_s16(u_high), v_weights);
        b_lo1 = vqdmlal_high_laneq_s16::<3>(b_lo1, u_low, v_weights);
        b_lo0 = vqdmlal_laneq_s16::<3>(b_lo0, vget_low_s16(u_low), v_weights);

        let b_high = vcombine_s16(
            vshrn_n_s32::<PRECISION>(b_hi0),
            vshrn_n_s32::<PRECISION>(b_hi1),
        );
        let b_low = vcombine_s16(
            vshrn_n_s32::<PRECISION>(b_lo0),
            vshrn_n_s32::<PRECISION>(b_lo1),
        );

        let r_values = vcombine_u8(vqmovun_s16(r_low), vqmovun_s16(r_high));
        let g_values = vcombine_u8(vqmovun_s16(g_low), vqmovun_s16(g_high));
        let b_values = vcombine_u8(vqmovun_s16(b_low), vqmovun_s16(b_high));

        let dst_shift = cx * channels;

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            bgra_ptr.add(dst_shift),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 16;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                ux += 16;
            }
            YuvChromaSubsampling::Yuv444 => {
                ux += 32;
            }
        }
    }

    if cx < width {
        let diff = width - cx;

        assert!(diff <= 16);

        let mut dst_buffer: [u8; 16 * 4] = [0; 16 * 4];
        let mut y_buffer: [u8; 16] = [0; 16];
        let mut uv_buffer: [u8; 16 * 2] = [0; 16 * 2];

        std::ptr::copy_nonoverlapping(
            y_plane.get_unchecked(cx..).as_ptr(),
            y_buffer.as_mut_ptr().cast(),
            diff,
        );

        let ux_size = match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => diff.div_ceil(2) * 2,
            YuvChromaSubsampling::Yuv444 => diff * 2,
        };

        std::ptr::copy_nonoverlapping(
            uv_plane.get_unchecked(ux..).as_ptr(),
            uv_buffer.as_mut_ptr().cast(),
            ux_size,
        );

        let y_vl = vld1q_u8(y_buffer.as_ptr().cast());

        let u_high_s8: int8x8_t;
        let v_high_s8: int8x8_t;
        let u_low_s8: int8x8_t;
        let v_low_s8: int8x8_t;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let mut uv_values = vld2_u8(uv_buffer.as_ptr().cast());
                if order == YuvNVOrder::VU {
                    uv_values = uint8x8x2_t(uv_values.1, uv_values.0);
                }

                uv_values.0 = vsub_u8(uv_values.0, vget_low_u8(uv_corr));
                uv_values.1 = vsub_u8(uv_values.1, vget_low_u8(uv_corr));

                u_high_s8 = vreinterpret_s8_u8(vzip2_u8(uv_values.0, uv_values.0));
                v_high_s8 = vreinterpret_s8_u8(vzip2_u8(uv_values.1, uv_values.1));
                u_low_s8 = vreinterpret_s8_u8(vzip1_u8(uv_values.0, uv_values.0));
                v_low_s8 = vreinterpret_s8_u8(vzip1_u8(uv_values.1, uv_values.1));
            }
            YuvChromaSubsampling::Yuv444 => {
                let mut uv_values = vld2q_u8(uv_buffer.as_ptr().cast());
                if order == YuvNVOrder::VU {
                    uv_values = uint8x16x2_t(uv_values.1, uv_values.0);
                }

                uv_values.0 = vsubq_u8(uv_values.0, uv_corr);
                uv_values.1 = vsubq_u8(uv_values.1, uv_corr);

                u_high_s8 = vreinterpret_s8_u8(vget_high_u8(uv_values.0));
                v_high_s8 = vreinterpret_s8_u8(vget_high_u8(uv_values.1));
                u_low_s8 = vreinterpret_s8_u8(vget_low_u8(uv_values.0));
                v_low_s8 = vreinterpret_s8_u8(vget_low_u8(uv_values.1));
            }
        }

        let y_values = vqsubq_u8(y_vl, y_corr);

        let u_high = vmovl_s8(u_high_s8);
        let v_high = vmovl_s8(v_high_s8);
        let u_low = vmovl_s8(u_low_s8);
        let v_low = vmovl_s8(v_low_s8);
        let yhw = vreinterpretq_s16_u16(vmovl_high_u8(y_values));
        let ylw = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_values)));
        let y_high = vqdmalq_laneq_s16::<0>(b_y, yhw, v_weights);
        let y_low = vqdmalq_laneq_s16::<0>(b_y, ylw, v_weights);

        let mut g_hi1 = vqdmlal_high_laneq_s16::<4>(y_high.1, v_high, v_weights);
        let mut g_hi0 = vqdmlal_laneq_s16::<4>(y_high.0, vget_low_s16(v_high), v_weights);
        let mut g_lo1 = vqdmlal_high_laneq_s16::<4>(y_low.1, v_low, v_weights);
        let mut g_lo0 = vqdmlal_laneq_s16::<4>(y_low.0, vget_low_s16(v_low), v_weights);

        let r_hi1 = vqdmlal_high_laneq_s16::<1>(y_high.1, v_high, v_weights);
        let r_hi0 = vqdmlal_laneq_s16::<1>(y_high.0, vget_low_s16(v_high), v_weights);
        let r_lo1 = vqdmlal_high_laneq_s16::<1>(y_low.1, v_low, v_weights);
        let r_lo0 = vqdmlal_laneq_s16::<1>(y_low.0, vget_low_s16(v_low), v_weights);

        let mut b_hi1 = vqdmlal_high_laneq_s16::<2>(y_high.1, u_high, v_weights);
        let mut b_hi0 = vqdmlal_laneq_s16::<2>(y_high.0, vget_low_s16(u_high), v_weights);
        let mut b_lo1 = vqdmlal_high_laneq_s16::<2>(y_low.1, u_low, v_weights);
        let mut b_lo0 = vqdmlal_laneq_s16::<2>(y_low.0, vget_low_s16(u_low), v_weights);

        g_hi1 = vqdmlal_high_laneq_s16::<5>(g_hi1, u_high, v_weights);
        g_hi0 = vqdmlal_laneq_s16::<5>(g_hi0, vget_low_s16(u_high), v_weights);
        g_lo1 = vqdmlal_high_laneq_s16::<5>(g_lo1, u_low, v_weights);
        g_lo0 = vqdmlal_laneq_s16::<5>(g_lo0, vget_low_s16(u_low), v_weights);

        let r_high = vcombine_s16(
            vshrn_n_s32::<PRECISION>(r_hi0),
            vshrn_n_s32::<PRECISION>(r_hi1),
        );
        let r_low = vcombine_s16(
            vshrn_n_s32::<PRECISION>(r_lo0),
            vshrn_n_s32::<PRECISION>(r_lo1),
        );

        b_hi1 = vqdmlal_high_laneq_s16::<3>(b_hi1, u_high, v_weights);
        b_hi0 = vqdmlal_laneq_s16::<3>(b_hi0, vget_low_s16(u_high), v_weights);
        b_lo1 = vqdmlal_high_laneq_s16::<3>(b_lo1, u_low, v_weights);
        b_lo0 = vqdmlal_laneq_s16::<3>(b_lo0, vget_low_s16(u_low), v_weights);

        let g_high = vcombine_s16(
            vshrn_n_s32::<PRECISION>(g_hi0),
            vshrn_n_s32::<PRECISION>(g_hi1),
        );
        let g_low = vcombine_s16(
            vshrn_n_s32::<PRECISION>(g_lo0),
            vshrn_n_s32::<PRECISION>(g_lo1),
        );

        let b_high = vcombine_s16(
            vshrn_n_s32::<PRECISION>(b_hi0),
            vshrn_n_s32::<PRECISION>(b_hi1),
        );
        let b_low = vcombine_s16(
            vshrn_n_s32::<PRECISION>(b_lo0),
            vshrn_n_s32::<PRECISION>(b_lo1),
        );

        let r_values = vcombine_u8(vqmovun_s16(r_low), vqmovun_s16(r_high));
        let g_values = vcombine_u8(vqmovun_s16(g_low), vqmovun_s16(g_high));
        let b_values = vcombine_u8(vqmovun_s16(b_low), vqmovun_s16(b_high));

        neon_store_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        let dst_shift = cx * channels;
        std::ptr::copy_nonoverlapping(
            dst_buffer.as_mut_ptr().cast(),
            rgba.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        ux += ux_size;
    }

    ProcessedOffset { cx, ux }
}
