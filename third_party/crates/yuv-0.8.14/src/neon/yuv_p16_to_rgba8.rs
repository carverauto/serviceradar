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

use crate::neon::utils::{neon_store_half_rgb8, vld_s16_endian, vldq_s16_endian, vpackq_n_shift16};
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
use std::arch::aarch64::*;

pub(crate) fn neon_yuv_p16_to_rgba_row<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_ld_ptr: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    rgba: &mut [u8],
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    unsafe {
        neon_yuv_p16_to_rgba_row_impl::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            BIT_DEPTH,
            PRECISION,
        >(y_ld_ptr, u_ld_ptr, v_ld_ptr, rgba, range, transform)
    }
}

#[target_feature(enable = "neon")]
unsafe fn neon_yuv_p16_to_rgba_row_impl<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const BIT_DEPTH: usize,
    const PRECISION: i32,
>(
    y_ld_ptr: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    rgba: &mut [u8],
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    let y_corr = vdupq_n_u16(range.bias_y as u16);
    let uv_corr = vdupq_n_s16(range.bias_uv as i16);

    let weights_arr: [i16; 8] = [
        transform.y_coef as i16,
        transform.cr_coef as i16,
        transform.cb_coef as i16,
        -transform.g_coeff_1 as i16,
        -transform.g_coeff_2 as i16,
        0,
        0,
        0,
    ];

    let v_weights = vld1q_s16(weights_arr.as_ptr());

    let v_alpha = vdup_n_u8(255u8);

    let y_chunks = y_ld_ptr.chunks_exact(8);

    // For chroma, chunk size depends on subsampling
    let uv_chunk_size = match chroma_subsampling {
        YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => 4,
        YuvChromaSubsampling::Yuv444 => 8,
    };

    let u_chunks = u_ld_ptr.chunks_exact(uv_chunk_size);
    let v_chunks = v_ld_ptr.chunks_exact(uv_chunk_size);

    let dst_chunks = rgba.chunks_exact_mut(8 * channels);

    let remainder_y = y_chunks.remainder();
    let remainder_u = u_chunks.remainder();
    let remainder_v = v_chunks.remainder();

    for (((y_chunk, u_chunk), v_chunk), dst_chunk) in
        y_chunks.zip(u_chunks).zip(v_chunks).zip(dst_chunks)
    {
        let y_values: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_chunk.as_ptr(),
            )),
            y_corr,
        ));

        let u_high: int16x4_t;
        let v_high: int16x4_t;
        let u_low: int16x4_t;
        let v_low: int16x4_t;

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut u_values_l =
                vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(u_chunk.as_ptr());
            let mut v_values_l =
                vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(v_chunk.as_ptr());

            u_values_l = vsubq_s16(u_values_l, uv_corr);
            v_values_l = vsubq_s16(v_values_l, uv_corr);

            u_high = vget_high_s16(u_values_l);
            u_low = vget_low_s16(u_values_l);
            v_high = vget_high_s16(v_values_l);
            v_low = vget_low_s16(v_values_l);
        } else {
            let mut u_values_l =
                vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(u_chunk.as_ptr());
            let mut v_values_l =
                vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(v_chunk.as_ptr());
            u_values_l = vsub_s16(u_values_l, vget_low_s16(uv_corr));
            v_values_l = vsub_s16(v_values_l, vget_low_s16(uv_corr));

            u_high = vzip2_s16(u_values_l, u_values_l);
            v_high = vzip2_s16(v_values_l, v_values_l);

            u_low = vzip1_s16(u_values_l, u_values_l);
            v_low = vzip1_s16(v_values_l, v_values_l);
        }

        let y_high = vmull_high_laneq_s16::<0>(y_values, v_weights);
        let y_low = vmull_laneq_s16::<0>(vget_low_s16(y_values), v_weights);

        let rh0 = vmlal_laneq_s16::<1>(y_high, v_high, v_weights);
        let bh0 = vmlal_laneq_s16::<2>(y_high, u_high, v_weights);
        let gh0 = vmlal_laneq_s16::<3>(y_high, v_high, v_weights);
        let rl0 = vmlal_laneq_s16::<1>(y_low, v_low, v_weights);
        let bl0 = vmlal_laneq_s16::<2>(y_low, u_low, v_weights);
        let gl0 = vmlal_laneq_s16::<3>(y_low, v_low, v_weights);

        let r_high = vqrshrun_n_s32::<PRECISION>(rh0);
        let b_high = vqrshrun_n_s32::<PRECISION>(bh0);
        let g_high = vqrshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(gh0, u_high, v_weights));

        let r_low = vqrshrun_n_s32::<PRECISION>(rl0);
        let b_low = vqrshrun_n_s32::<PRECISION>(bl0);
        let g_low = vqrshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(gl0, u_low, v_weights));

        let r_values = vpackq_n_shift16::<BIT_DEPTH>(vcombine_u16(r_low, r_high));
        let g_values = vpackq_n_shift16::<BIT_DEPTH>(vcombine_u16(g_low, g_high));
        let b_values = vpackq_n_shift16::<BIT_DEPTH>(vcombine_u16(b_low, b_high));

        neon_store_half_rgb8::<DESTINATION_CHANNELS>(
            dst_chunk.as_mut_ptr(),
            r_values,
            g_values,
            b_values,
            v_alpha,
        );
    }

    let dst_chunks = rgba.chunks_exact_mut(8 * channels).into_remainder();

    if !remainder_y.is_empty() {
        let diff = remainder_y.len();
        assert!(diff <= 8);

        let mut y_buffer: [u16; 8] = [0; 8];
        let mut u_buffer: [u16; 8] = [0; 8];
        let mut v_buffer: [u16; 8] = [0; 8];

        let mut rgba: [u8; 8 * 4] = [0; 8 * 4];
        let (cut_rgba, _) = rgba.split_at_mut(channels * 8);

        y_buffer[..diff].copy_from_slice(remainder_y);
        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let uv_size = diff.div_ceil(2);
                u_buffer[..uv_size].copy_from_slice(remainder_u);
                v_buffer[..uv_size].copy_from_slice(remainder_v);
            }
            YuvChromaSubsampling::Yuv444 => {
                u_buffer[..diff].copy_from_slice(remainder_u);
                v_buffer[..diff].copy_from_slice(remainder_v);
            }
        }

        neon_yuv_p16_to_rgba_row_impl::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            BIT_DEPTH,
            PRECISION,
        >(&y_buffer, &u_buffer, &v_buffer, cut_rgba, range, transform);

        dst_chunks.copy_from_slice(&cut_rgba[..dst_chunks.len()]);
    }
}
