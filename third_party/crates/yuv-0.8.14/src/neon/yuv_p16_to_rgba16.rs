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
use crate::yuv_support::{
    CbCrInverseTransform, YuvChromaRange, YuvChromaSubsampling, YuvSourceChannels,
};
use std::arch::aarch64::*;

pub(crate) fn neon_yuv_p16_to_rgba16_row<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    rgba: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    unsafe {
        neon_yuv_p16_to_rgba16_row_impl::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >(y_ld_ptr, u_ld_ptr, v_ld_ptr, rgba, width, range, transform)
    }
}

#[target_feature(enable = "neon")]
unsafe fn neon_yuv_p16_to_rgba16_row_impl<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    rgba: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    let y_corr = vdupq_n_u16(range.bias_y as u16);
    let uv_corr = vdupq_n_u16(range.bias_uv as u16);

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

    let v_alpha = vdupq_n_u16(((1u32 << BIT_DEPTH) - 1u32) as u16);

    let base_val = vdupq_n_u32(1 << (PRECISION - 1));

    let mut cx = 0usize;
    let mut ux = 0usize;

    while cx + 16 <= width as usize {
        let y_values0 = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        );
        let y_values1 = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr.get_unchecked((cx + 8)..).as_ptr(),
            )),
            y_corr,
        );

        let u_values0: int16x8_t;
        let v_values0: int16x8_t;
        let u_values1: int16x8_t;
        let v_values1: int16x8_t;

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut u_values_l0 = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut v_values_l0 = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut u_values_l1 = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked((ux + 8)..).as_ptr(),
            );
            let mut v_values_l1 = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked((ux + 8)..).as_ptr(),
            );

            u_values_l0 =
                vreinterpretq_s16_u16(vsubq_u16(vreinterpretq_u16_s16(u_values_l0), uv_corr));
            v_values_l0 =
                vreinterpretq_s16_u16(vsubq_u16(vreinterpretq_u16_s16(v_values_l0), uv_corr));
            u_values_l1 =
                vreinterpretq_s16_u16(vsubq_u16(vreinterpretq_u16_s16(u_values_l1), uv_corr));
            v_values_l1 =
                vreinterpretq_s16_u16(vsubq_u16(vreinterpretq_u16_s16(v_values_l1), uv_corr));

            u_values0 = u_values_l0;
            v_values0 = v_values_l0;
            u_values1 = u_values_l1;
            v_values1 = v_values_l1;
        } else {
            let mut u_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut v_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            u_values_l =
                vreinterpretq_s16_u16(vsubq_u16(vreinterpretq_u16_s16(u_values_l), uv_corr));
            v_values_l =
                vreinterpretq_s16_u16(vsubq_u16(vreinterpretq_u16_s16(v_values_l), uv_corr));

            let u_high = vzip2q_s16(u_values_l, u_values_l);
            let v_high = vzip2q_s16(v_values_l, v_values_l);

            let u_low = vzip1q_s16(u_values_l, u_values_l);
            let v_low = vzip1q_s16(v_values_l, v_values_l);

            u_values0 = u_low;
            v_values0 = v_low;

            u_values1 = u_high;
            v_values1 = v_high;
        }

        let y_high0 = vreinterpretq_s32_u32(vmlal_high_laneq_u16::<0>(
            base_val,
            y_values0,
            vreinterpretq_u16_s16(v_weights),
        ));
        let y_high1 = vreinterpretq_s32_u32(vmlal_high_laneq_u16::<0>(
            base_val,
            y_values1,
            vreinterpretq_u16_s16(v_weights),
        ));

        let rh0 = vmlal_high_laneq_s16::<1>(y_high0, v_values0, v_weights);
        let bh0 = vmlal_high_laneq_s16::<2>(y_high0, u_values0, v_weights);
        let gh0 = vmlal_high_laneq_s16::<3>(y_high0, v_values0, v_weights);

        let rh1 = vmlal_high_laneq_s16::<1>(y_high1, v_values1, v_weights);
        let bh1 = vmlal_high_laneq_s16::<2>(y_high1, u_values1, v_weights);
        let gh1 = vmlal_high_laneq_s16::<3>(y_high1, v_values1, v_weights);

        let r_high0 = vqshrun_n_s32::<PRECISION>(rh0);
        let b_high0 = vqshrun_n_s32::<PRECISION>(bh0);
        let g_high0 =
            vqshrun_n_s32::<PRECISION>(vmlal_high_laneq_s16::<4>(gh0, u_values0, v_weights));

        let r_high1 = vqshrun_n_s32::<PRECISION>(rh1);
        let b_high1 = vqshrun_n_s32::<PRECISION>(bh1);
        let g_high1 =
            vqshrun_n_s32::<PRECISION>(vmlal_high_laneq_s16::<4>(gh1, u_values1, v_weights));

        let y_low0 = vreinterpretq_s32_u32(vmlal_laneq_u16::<0>(
            base_val,
            vget_low_u16(y_values0),
            vreinterpretq_u16_s16(v_weights),
        ));
        let y_low1 = vreinterpretq_s32_u32(vmlal_laneq_u16::<0>(
            base_val,
            vget_low_u16(y_values1),
            vreinterpretq_u16_s16(v_weights),
        ));

        let rl0 = vmlal_laneq_s16::<1>(y_low0, vget_low_s16(v_values0), v_weights);
        let bl0 = vmlal_laneq_s16::<2>(y_low0, vget_low_s16(u_values0), v_weights);
        let gl0 = vmlal_laneq_s16::<3>(y_low0, vget_low_s16(v_values0), v_weights);
        let rl1 = vmlal_laneq_s16::<1>(y_low1, vget_low_s16(v_values1), v_weights);
        let bl1 = vmlal_laneq_s16::<2>(y_low1, vget_low_s16(u_values1), v_weights);
        let gl1 = vmlal_laneq_s16::<3>(y_low1, vget_low_s16(v_values1), v_weights);

        let r_low0 = vqshrun_n_s32::<PRECISION>(rl0);
        let b_low0 = vqshrun_n_s32::<PRECISION>(bl0);
        let g_low0 = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(
            gl0,
            vget_low_s16(u_values0),
            v_weights,
        ));

        let r_low1 = vqshrun_n_s32::<PRECISION>(rl1);
        let b_low1 = vqshrun_n_s32::<PRECISION>(bl1);
        let g_low1 = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(
            gl1,
            vget_low_s16(u_values1),
            v_weights,
        ));

        let r_values0 = if BIT_DEPTH == 16 {
            vcombine_u16(r_low0, r_high0)
        } else {
            vminq_u16(vcombine_u16(r_low0, r_high0), v_alpha)
        };
        let g_values0 = if BIT_DEPTH == 16 {
            vcombine_u16(g_low0, g_high0)
        } else {
            vminq_u16(vcombine_u16(g_low0, g_high0), v_alpha)
        };
        let b_values0 = if BIT_DEPTH == 16 {
            vcombine_u16(b_low0, b_high0)
        } else {
            vminq_u16(vcombine_u16(b_low0, b_high0), v_alpha)
        };

        let r_values1 = if BIT_DEPTH == 16 {
            vcombine_u16(r_low1, r_high1)
        } else {
            vminq_u16(vcombine_u16(r_low1, r_high1), v_alpha)
        };
        let g_values1 = if BIT_DEPTH == 16 {
            vcombine_u16(g_low1, g_high1)
        } else {
            vminq_u16(vcombine_u16(g_low1, g_high1), v_alpha)
        };
        let b_values1 = if BIT_DEPTH == 16 {
            vcombine_u16(b_low1, b_high1)
        } else {
            vminq_u16(vcombine_u16(b_low1, b_high1), v_alpha)
        };

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut((cx + 8) * channels..).as_mut_ptr(),
            r_values1,
            g_values1,
            b_values1,
            v_alpha,
        );

        cx += 16;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                ux += 8;
            }
            YuvChromaSubsampling::Yuv444 => {
                ux += 16;
            }
        }
    }

    while cx + 8 <= width as usize {
        let y_values = vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        );

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

            u_values_l =
                vreinterpretq_s16_u16(vsubq_u16(vreinterpretq_u16_s16(u_values_l), uv_corr));
            v_values_l =
                vreinterpretq_s16_u16(vsubq_u16(vreinterpretq_u16_s16(v_values_l), uv_corr));

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
            u_values_l = vreinterpret_s16_u16(vsub_u16(
                vreinterpret_u16_s16(u_values_l),
                vget_low_u16(uv_corr),
            ));
            v_values_l = vreinterpret_s16_u16(vsub_u16(
                vreinterpret_u16_s16(v_values_l),
                vget_low_u16(uv_corr),
            ));

            u_high = vzip2_s16(u_values_l, u_values_l);
            v_high = vzip2_s16(v_values_l, v_values_l);

            u_low = vzip1_s16(u_values_l, u_values_l);
            v_low = vzip1_s16(v_values_l, v_values_l);
        }

        let y_high = vreinterpretq_s32_u32(vmlal_high_laneq_u16::<0>(
            base_val,
            y_values,
            vreinterpretq_u16_s16(v_weights),
        ));
        let y_low = vreinterpretq_s32_u32(vmlal_laneq_u16::<0>(
            base_val,
            vget_low_u16(y_values),
            vreinterpretq_u16_s16(v_weights),
        ));

        let rh = vmlal_laneq_s16::<1>(y_high, v_high, v_weights);
        let bh = vmlal_laneq_s16::<2>(y_high, u_high, v_weights);
        let gh = vmlal_laneq_s16::<3>(y_high, v_high, v_weights);
        let rl = vmlal_laneq_s16::<1>(y_low, v_low, v_weights);
        let bl = vmlal_laneq_s16::<2>(y_low, u_low, v_weights);
        let gl = vmlal_laneq_s16::<3>(y_low, v_low, v_weights);

        let r_high = vqshrun_n_s32::<PRECISION>(rh);
        let b_high = vqshrun_n_s32::<PRECISION>(bh);
        let g_high = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(gh, u_high, v_weights));

        let r_low = vqshrun_n_s32::<PRECISION>(rl);
        let b_low = vqshrun_n_s32::<PRECISION>(bl);
        let g_low = vqshrun_n_s32::<PRECISION>(vmlal_laneq_s16::<4>(gl, u_low, v_weights));

        let r_values = if BIT_DEPTH == 16 {
            vcombine_u16(r_low, r_high)
        } else {
            vminq_u16(vcombine_u16(r_low, r_high), v_alpha)
        };
        let g_values = if BIT_DEPTH == 16 {
            vcombine_u16(g_low, g_high)
        } else {
            vminq_u16(vcombine_u16(g_low, g_high), v_alpha)
        };
        let b_values = if BIT_DEPTH == 16 {
            vcombine_u16(b_low, b_high)
        } else {
            vminq_u16(vcombine_u16(b_low, b_high), v_alpha)
        };

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut(cx * channels..).as_mut_ptr(),
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

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 8);

        let mut y_buffer: [u16; 8] = [0; 8];
        let mut u_buffer: [u16; 8] = [0; 8];
        let mut v_buffer: [u16; 8] = [0; 8];

        let mut wh_rgba: [u16; 8 * 4] = [0; 8 * 4];
        let (cut_rgba, _) = wh_rgba.split_at_mut(channels * 8);

        y_buffer[..diff].copy_from_slice(&y_ld_ptr[cx..cx + diff]);
        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let uv_size = diff.div_ceil(2);
                u_buffer[..uv_size].copy_from_slice(&u_ld_ptr[ux..ux + uv_size]);
                v_buffer[..uv_size].copy_from_slice(&v_ld_ptr[ux..ux + uv_size]);
            }
            YuvChromaSubsampling::Yuv444 => {
                u_buffer[..diff].copy_from_slice(&u_ld_ptr[ux..ux + diff]);
                v_buffer[..diff].copy_from_slice(&v_ld_ptr[ux..ux + diff]);
            }
        }

        neon_yuv_p16_to_rgba16_row_impl::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >(
            &y_buffer, &u_buffer, &v_buffer, cut_rgba, 8, range, transform,
        );

        let rgba_dst = &mut rgba[cx * channels..cx * channels + channels * diff];
        rgba_dst.copy_from_slice(&cut_rgba[..rgba_dst.len()]);
    }
}

#[cfg(feature = "rdm")]
pub(crate) fn neon_yuv_p16_to_rgba16_row_rdm<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    rgba: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    unsafe {
        neon_yuv_p16_to_rgba16_row_rdm_impl::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >(y_ld_ptr, u_ld_ptr, v_ld_ptr, rgba, width, range, transform);
    }
}

#[cfg(feature = "rdm")]
#[target_feature(enable = "rdm")]
unsafe fn neon_yuv_p16_to_rgba16_row_rdm_impl<
    const DESTINATION_CHANNELS: u8,
    const SAMPLING: u8,
    const ENDIANNESS: u8,
    const BYTES_POSITION: u8,
    const PRECISION: i32,
    const BIT_DEPTH: usize,
>(
    y_ld_ptr: &[u16],
    u_ld_ptr: &[u16],
    v_ld_ptr: &[u16],
    rgba: &mut [u16],
    width: u32,
    range: &YuvChromaRange,
    transform: &CbCrInverseTransform<i32>,
) {
    let destination_channels: YuvSourceChannels = DESTINATION_CHANNELS.into();
    let channels = destination_channels.get_channels_count();
    let chroma_subsampling: YuvChromaSubsampling = SAMPLING.into();

    const SCALE: i32 = 2;

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

    let v_alpha = vdupq_n_u16((1 << BIT_DEPTH) - 1);
    let zeros = vdupq_n_s16(0);

    let mut cx = 0usize;
    let mut ux = 0usize;

    while cx + 16 <= width as usize {
        let y_values0: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        ));
        let y_values1: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr.get_unchecked((cx + 8)..).as_ptr(),
            )),
            y_corr,
        ));

        let u_values0: int16x8_t;
        let v_values0: int16x8_t;
        let u_values1: int16x8_t;
        let v_values1: int16x8_t;

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut u_values_l0 = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut v_values_l0 = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut u_values_l1 = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked((ux + 8)..).as_ptr(),
            );
            let mut v_values_l1 = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked((ux + 8)..).as_ptr(),
            );

            u_values_l0 = vsubq_s16(u_values_l0, uv_corr);
            v_values_l0 = vsubq_s16(v_values_l0, uv_corr);
            u_values_l1 = vsubq_s16(u_values_l1, uv_corr);
            v_values_l1 = vsubq_s16(v_values_l1, uv_corr);

            u_values0 = vshlq_n_s16::<SCALE>(u_values_l0);
            v_values0 = vshlq_n_s16::<SCALE>(v_values_l0);
            u_values1 = vshlq_n_s16::<SCALE>(u_values_l1);
            v_values1 = vshlq_n_s16::<SCALE>(v_values_l1);
        } else {
            let mut u_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut v_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            u_values_l = vsubq_s16(u_values_l, uv_corr);
            v_values_l = vsubq_s16(v_values_l, uv_corr);

            let u_high = vzip2q_s16(u_values_l, u_values_l);
            let v_high = vzip2q_s16(v_values_l, v_values_l);

            let u_low = vzip1q_s16(u_values_l, u_values_l);
            let v_low = vzip1q_s16(v_values_l, v_values_l);

            u_values0 = vshlq_n_s16::<SCALE>(u_low);
            v_values0 = vshlq_n_s16::<SCALE>(v_low);

            u_values1 = vshlq_n_s16::<SCALE>(u_high);
            v_values1 = vshlq_n_s16::<SCALE>(v_high);
        }

        let y_high0 =
            vqrdmulhq_laneq_s16::<0>(vexpand_high_bp_by_2::<BIT_DEPTH>(y_values0), v_weights);
        let y_high1 =
            vqrdmulhq_laneq_s16::<0>(vexpand_high_bp_by_2::<BIT_DEPTH>(y_values1), v_weights);

        let r_vals0 = vqrdmlahq_laneq_s16::<1>(y_high0, v_values0, v_weights);
        let b_vals0 = vqrdmlahq_laneq_s16::<2>(y_high0, u_values0, v_weights);
        let r_vals1 = vqrdmlahq_laneq_s16::<1>(y_high1, v_values1, v_weights);
        let b_vals1 = vqrdmlahq_laneq_s16::<2>(y_high1, u_values1, v_weights);

        let gc0 = vqrdmlahq_laneq_s16::<3>(y_high0, v_values0, v_weights);
        let gc1 = vqrdmlahq_laneq_s16::<3>(y_high1, v_values1, v_weights);

        let g_vals0 = vqrdmlahq_laneq_s16::<4>(gc0, u_values0, v_weights);
        let g_vals1 = vqrdmlahq_laneq_s16::<4>(gc1, u_values1, v_weights);

        let r_values0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(r_vals0, zeros)), v_alpha);
        let g_values0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(g_vals0, zeros)), v_alpha);
        let b_values0 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(b_vals0, zeros)), v_alpha);

        let r_values1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(r_vals1, zeros)), v_alpha);
        let g_values1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(g_vals1, zeros)), v_alpha);
        let b_values1 = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(b_vals1, zeros)), v_alpha);

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut(cx * channels..).as_mut_ptr(),
            r_values0,
            g_values0,
            b_values0,
            v_alpha,
        );

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut((cx + 8) * channels..).as_mut_ptr(),
            r_values1,
            g_values1,
            b_values1,
            v_alpha,
        );

        cx += 16;

        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                ux += 8;
            }
            YuvChromaSubsampling::Yuv444 => {
                ux += 16;
            }
        }
    }

    while cx + 8 <= width as usize {
        let y_values: int16x8_t = vreinterpretq_s16_u16(vqsubq_u16(
            vreinterpretq_u16_s16(vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                y_ld_ptr.get_unchecked(cx..).as_ptr(),
            )),
            y_corr,
        ));

        let u_values: int16x8_t;
        let v_values: int16x8_t;

        if chroma_subsampling == YuvChromaSubsampling::Yuv444 {
            let mut u_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut v_values_l = vldq_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
            );

            u_values_l = vsubq_s16(u_values_l, uv_corr);
            v_values_l = vsubq_s16(v_values_l, uv_corr);

            u_values = vshlq_n_s16::<SCALE>(u_values_l);
            v_values = vshlq_n_s16::<SCALE>(v_values_l);
        } else {
            let mut u_values_l = vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                u_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            let mut v_values_l = vld_s16_endian::<ENDIANNESS, BYTES_POSITION, BIT_DEPTH>(
                v_ld_ptr.get_unchecked(ux..).as_ptr(),
            );
            u_values_l = vsub_s16(u_values_l, vget_low_s16(uv_corr));
            v_values_l = vsub_s16(v_values_l, vget_low_s16(uv_corr));

            let u_high = vzip2_s16(u_values_l, u_values_l);
            let v_high = vzip2_s16(v_values_l, v_values_l);

            let u_low = vzip1_s16(u_values_l, u_values_l);
            let v_low = vzip1_s16(v_values_l, v_values_l);

            u_values = vshlq_n_s16::<SCALE>(vcombine_s16(u_low, u_high));
            v_values = vshlq_n_s16::<SCALE>(vcombine_s16(v_low, v_high));
        }

        let y_high =
            vqrdmulhq_laneq_s16::<0>(vexpand_high_bp_by_2::<BIT_DEPTH>(y_values), v_weights);

        let r_vals = vqrdmlahq_laneq_s16::<1>(y_high, v_values, v_weights);
        let b_vals = vqrdmlahq_laneq_s16::<2>(y_high, u_values, v_weights);
        let g_vals = vqrdmlahq_laneq_s16::<4>(
            vqrdmlahq_laneq_s16::<3>(y_high, v_values, v_weights),
            u_values,
            v_weights,
        );

        let r_values = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(r_vals, zeros)), v_alpha);
        let g_values = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(g_vals, zeros)), v_alpha);
        let b_values = vminq_u16(vreinterpretq_u16_s16(vmaxq_s16(b_vals, zeros)), v_alpha);

        neon_store_rgb16::<DESTINATION_CHANNELS>(
            rgba.get_unchecked_mut(cx * channels..).as_mut_ptr(),
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

    if cx < width as usize {
        let diff = width as usize - cx;
        assert!(diff <= 8);

        let mut y_buffer: [u16; 8] = [0; 8];
        let mut u_buffer: [u16; 8] = [0; 8];
        let mut v_buffer: [u16; 8] = [0; 8];

        let mut wh_rgba: [u16; 8 * 4] = [0; 8 * 4];
        let (cut_rgba, _) = wh_rgba.split_at_mut(channels * 8);

        y_buffer[..diff].copy_from_slice(&y_ld_ptr[cx..cx + diff]);
        match chroma_subsampling {
            YuvChromaSubsampling::Yuv420 | YuvChromaSubsampling::Yuv422 => {
                let uv_size = diff.div_ceil(2);
                u_buffer[..uv_size].copy_from_slice(&u_ld_ptr[ux..ux + uv_size]);
                v_buffer[..uv_size].copy_from_slice(&v_ld_ptr[ux..ux + uv_size]);
            }
            YuvChromaSubsampling::Yuv444 => {
                u_buffer[..diff].copy_from_slice(&u_ld_ptr[ux..ux + diff]);
                v_buffer[..diff].copy_from_slice(&v_ld_ptr[ux..ux + diff]);
            }
        }

        neon_yuv_p16_to_rgba16_row_rdm_impl::<
            DESTINATION_CHANNELS,
            SAMPLING,
            ENDIANNESS,
            BYTES_POSITION,
            PRECISION,
            BIT_DEPTH,
        >(
            &y_buffer, &u_buffer, &v_buffer, cut_rgba, 8, range, transform,
        );

        let rgba_dst = &mut rgba[cx * channels..cx * channels + channels * diff];
        rgba_dst.copy_from_slice(&cut_rgba[..rgba_dst.len()]);
    }
}
