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
use crate::neon::utils::{neon_store_half_rgb8, vldq_s16_endian, vpackuq_n_shift16};
use crate::neon::yuv_nv_p10_to_rgba::deinterleave_10_bit_uv;
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
use std::arch::aarch64::*;

pub(crate) unsafe fn neon_yuv_nv12_p10_to_rgba_row_prof<
    const DESTINATION_CHANNELS: u8,
    const NV_ORDER: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
>(
    y_plane: &[u16],
    uv_plane: &[u16],
    bgra: &mut [u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let dst_ptr = bgra.as_mut_ptr();

    let bias_y = range.bias_y as i32;
    let bias_uv = range.bias_uv as i32;

    let y_corr = vdupq_n_u16(bias_y as u16);
    let uv_corr_q = vdupq_n_s16(bias_uv as i16);

    const PRECISION: i32 = 15;

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

    let v_weights = vld1q_s16(weights_arr.as_ptr());

    let v_alpha = vdup_n_u8(255u8);

    let base_val = vdupq_n_s32(1 << (PRECISION - 1));

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 8 <= width as usize {
        let y_vl = vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
            y_plane.get_unchecked(cx..).as_ptr(),
        ));

        let y_values: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(y_vl, y_corr));

        let (u_low, v_low, u_high, v_high) =
            deinterleave_10_bit_uv::<NV_ORDER, SAMPLING, ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                uv_plane.get_unchecked(ux..),
                uv_corr_q,
            );

        let y_high = vqdmlal_high_laneq_s16::<0>(base_val, y_values, v_weights);
        let y_low = vqdmlal_laneq_s16::<0>(base_val, vget_low_s16(y_values), v_weights);

        let mut bh = vqdmlal_laneq_s16::<2>(y_high, u_high, v_weights);
        let rh = vqdmlal_laneq_s16::<1>(y_high, v_high, v_weights);
        let gh = vqdmlal_laneq_s16::<4>(y_high, v_high, v_weights);
        bh = vqdmlal_laneq_s16::<3>(bh, u_high, v_weights);
        let mut bl = vqdmlal_laneq_s16::<2>(y_low, u_low, v_weights);
        let rl = vqdmlal_laneq_s16::<1>(y_low, v_low, v_weights);
        let gl = vqdmlal_laneq_s16::<4>(y_low, v_low, v_weights);
        bl = vqdmlal_laneq_s16::<3>(bl, u_low, v_weights);
        let ghi = vqdmlal_laneq_s16::<5>(gh, u_high, v_weights);

        let r_high = vshrn_n_s32::<PRECISION>(rh);
        let b_high = vshrn_n_s32::<PRECISION>(bh);
        let g_high = vshrn_n_s32::<PRECISION>(ghi);

        let glv = vqdmlal_laneq_s16::<5>(gl, u_low, v_weights);

        let r_low = vshrn_n_s32::<PRECISION>(rl);
        let b_low = vshrn_n_s32::<PRECISION>(bl);
        let g_low = vshrn_n_s32::<PRECISION>(glv);

        let r_values = vpackuq_n_shift16::<BIT_DEPTH>(vcombine_s16(r_low, r_high));
        let g_values = vpackuq_n_shift16::<BIT_DEPTH>(vcombine_s16(g_low, g_high));
        let b_values = vpackuq_n_shift16::<BIT_DEPTH>(vcombine_s16(b_low, b_high));

        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            dst_ptr.add(cx * channels),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        cx += 8;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                ux += 8;
            }
            YuvChromaSubsampling::Yuv444 => {
                ux += 16;
            }
        }
    }

    if cx < width as usize {
        let diff = width as usize - cx;

        assert!(diff <= 8);

        let mut dst_buffer: [u8; 8 * 4] = [0; 8 * 4];
        let mut y_buffer: [u16; 8] = [0; 8];
        let mut uv_buffer: [u16; 8 * 2] = [0; 8 * 2];

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

        let y_vl = vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
            y_buffer.as_ptr().cast(),
        ));

        let (u_low, v_low, u_high, v_high) =
            deinterleave_10_bit_uv::<NV_ORDER, SAMPLING, ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                uv_buffer.as_slice(),
                uv_corr_q,
            );

        let y_values: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(y_vl, y_corr));

        let y_high = vqdmlal_high_laneq_s16::<0>(base_val, y_values, v_weights);
        let y_low = vqdmlal_laneq_s16::<0>(base_val, vget_low_s16(y_values), v_weights);

        let mut bh = vqdmlal_laneq_s16::<2>(y_high, u_high, v_weights);
        let rh = vqdmlal_laneq_s16::<1>(y_high, v_high, v_weights);
        let gh = vqdmlal_laneq_s16::<4>(y_high, v_high, v_weights);
        bh = vqdmlal_laneq_s16::<3>(bh, u_high, v_weights);
        let mut bl = vqdmlal_laneq_s16::<2>(y_low, u_low, v_weights);
        let rl = vqdmlal_laneq_s16::<1>(y_low, v_low, v_weights);
        let gl = vqdmlal_laneq_s16::<4>(y_low, v_low, v_weights);
        bl = vqdmlal_laneq_s16::<3>(bl, u_low, v_weights);
        let ghi = vqdmlal_laneq_s16::<5>(gh, u_high, v_weights);

        let r_high = vshrn_n_s32::<PRECISION>(rh);
        let b_high = vshrn_n_s32::<PRECISION>(bh);
        let g_high = vshrn_n_s32::<PRECISION>(ghi);

        let glv = vqdmlal_laneq_s16::<5>(gl, u_low, v_weights);

        let r_low = vshrn_n_s32::<PRECISION>(rl);
        let b_low = vshrn_n_s32::<PRECISION>(bl);
        let g_low = vshrn_n_s32::<PRECISION>(glv);

        let r_values = vpackuq_n_shift16::<BIT_DEPTH>(vcombine_s16(r_low, r_high));
        let g_values = vpackuq_n_shift16::<BIT_DEPTH>(vcombine_s16(g_low, g_high));
        let b_values = vpackuq_n_shift16::<BIT_DEPTH>(vcombine_s16(b_low, b_high));

        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            dst_buffer.as_mut_ptr().cast(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );

        let dst_shift = cx * channels;
        std::ptr::copy_nonoverlapping(
            dst_buffer.as_mut_ptr().cast(),
            bgra.get_unchecked_mut(dst_shift..).as_mut_ptr(),
            diff * channels,
        );

        cx += diff;
        ux += ux_size;
    }

    ProcessedOffset { cx, ux }
}
