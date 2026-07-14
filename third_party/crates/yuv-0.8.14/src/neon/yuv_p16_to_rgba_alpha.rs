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

use std::arch::aarch64::*;

use crate::internals::ProcessedOffset;
use crate::neon::utils::{
    neon_store_half_rgb8, vfrommsbq_u16, vld_s16_endian, vldq_s16_endian, vpackq_n_shift16,
};
use crate::yuv_support::{
    CbCrInverseTransform, YuvBytesPacking, YuvChromaRange, YuvChromaSubsampling, YuvEndianness,
    YuvSourceChannels,
};

pub(crate) unsafe fn neon_yuv_p16_to_rgba_alpha_row<
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
    a_ld_ptr: &[u16],
    rgba: &mut [u8],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
    start_cx: usize,
    start_ux: usize,
) -> ProcessedOffset {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    assert!(
        destination_channels == YuvSourceChannels::Rgba
            || destination_channels == YuvSourceChannels::Bgra,
        "Cannot call YUV p16 to Rgb8 with alpha without real alpha"
    );
    let channels = destination_channels.get_channels_count();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();
    let _endianness: YuvEndianness = ENDIANNESS.into();
    let bytes_position: YuvBytesPacking = BYTES_POSITION.into();
    let dst_ptr = rgba.as_mut_ptr();

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

    let mut cx = start_cx;
    let mut ux = start_ux;

    while cx + 8 <= width as usize {
        let mut a_values_l = vld1q_u16(a_ld_ptr.get_unchecked(cx..).as_ptr());

        #[cfg(all(feature = "big_endian", target_endian = "little"))]
        if _endianness == YuvEndianness::BigEndian {
            a_values_l = vreinterpretq_u16_u8(vrev16q_u8(vreinterpretq_u8_u16(a_values_l)));
        }

        if bytes_position == YuvBytesPacking::MostSignificantBytes {
            a_values_l = vfrommsbq_u16::<BIT_DEPTH>(a_values_l);
        }

        let y_values: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        ));

        let u_high: int16x4_t;
        let v_high: int16x4_t;
        let u_low: int16x4_t;
        let v_low: int16x4_t;

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut u_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut v_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
            );

            u_values_l = vsubq_s16(u_values_l, uv_corr);
            v_values_l = vsubq_s16(v_values_l, uv_corr);

            u_high = vget_high_s16(u_values_l);
            u_low = vget_low_s16(u_values_l);
            v_high = vget_high_s16(v_values_l);
            v_low = vget_low_s16(v_values_l);
        } else {
            let mut u_values_l = vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut v_values_l = vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
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

        let v_alpha = vpackq_n_shift16::<BIT_DEPTH>(a_values_l);

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
                ux += 4;
            }
            YuvChromaSubsampling::Yuv444 => {
                ux += 8;
            }
        }
    }

    ProcessedOffset { cx, ux }
}
